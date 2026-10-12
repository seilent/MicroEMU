#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/sysext/usr/libexec/microemu"
run_script="${libexec}/microemu-play-run"
stop_script="${libexec}/microemu-play-stop"

T=$(mktemp -d)
prefix_dir=
trap 'rm -rf "${T}" ${prefix_dir:+"${prefix_dir}"}' EXIT
mkdir -p "${T}/bin" "${T}/lepton/images/rootfs/vendor/odm/etc"
export STATE="${T}/state"
export MICROEMU_LEPTON="${T}/bin/lepton"
export MICROEMU_LEPTON_DIR_CMD="${T}/bin/lepton-dir"
export MICROEMU_PAD_NODES="${T}/bin/pad-nodes"
export MICROEMU_PLAY_CONTEXT="${T}/contexts/microemu-play"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_ANDROID_DATA="${T}/data/android"
export MICROEMU_PLAY_POLL_S=0.05
export MICROEMU_STEAM_PIPE="${T}/steam.pipe"
export MICROEMU_ANDROID_OPTS="${repo}/sysext/usr/share/microemu/android/opts"
printf 'ro.odm.build.id=RQ3A\nro.product.odm.model=lepton\n' > "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop"
echo 3.0.5 > "${T}/lepton/version.txt"
echo 3.0.3 > "${T}/lepton/images/version.txt"
conf="${MICROEMU_RUNTIME_DIR}/lepton/containers.conf"
odm="${MICROEMU_RUNTIME_DIR}/lepton/odm-build.prop"

cat > "${T}/bin/lepton" <<'STUB'
#!/usr/bin/bash
echo "lepton $*" >> "${STATE}/events"
env > "${STATE}/env"
[[ -d "${MICROEMU_PLAY_CONTEXT}/internal" ]] && echo internal-present > "${STATE}/internal"
ps -o args= -p "${PPID}" > "${STATE}/parent"
while IFS= read -r step; do
    case "${step}" in
        sleep*) sleep "${step#sleep }" ;;
        exit*) exit "${step#exit }" ;;
        hold) sleep 6 & ;;
        steam-on) : > "${STATE}/steam" ;;
        steam-off) rm -f "${STATE}/steam" ;;
        rmpipe) rm -f "${MICROEMU_STEAM_PIPE}" ;;
        pipe*) timeout 2 bash -c 'printf "%s\n" "$1" > "$2"' _ "${step#pipe }" "${MICROEMU_STEAM_PIPE}" || echo "pipe blocked" >> "${STATE}/events" ;;
        *) echo "${step}"; echo "out ${step}" >> "${STATE}/events" ;;
    esac
done < "${STATE}/script"
STUB
cat > "${T}/bin/lepton-dir" <<STUB
#!/usr/bin/bash
[[ -e "\${STATE}/no-lepton-dir" ]] && exit 1
echo "${T}/lepton"
STUB
cat > "${T}/bin/pad-nodes" <<'STUB'
#!/usr/bin/bash
cat "${STATE}/nodes"
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/podman"
case "$*" in
    "container inspect -f {{.State.Running}} lepton-microemu-play") cat "${STATE}/running" ;;
    "exec lepton-microemu-play /system/bin/getprop sys.boot_completed") cat "${STATE}/booted" ;;
    "exec lepton-microemu-play /system/bin/pidof logd") echo 123 ;;
    "exec lepton-microemu-play /system/bin/logcat -b main -b system -b crash -v threadtime") cat "${STATE}/logcat" ;;
    "exec lepton-microemu-play /system/bin/sh -c "*)
        echo opts >> "${STATE}/events"
        n=$(( $(ls "${STATE}" | grep -c '^opts-script') + 1 ))
        printf '%s\n' "$5" > "${STATE}/opts-script-${n}"
        [[ ! -e "${STATE}/opts-sleep" ]] || sleep "$(cat "${STATE}/opts-sleep")"
        if [[ -e "${STATE}/opts-reply" ]]; then
            cat "${STATE}/opts-reply"
            exit 0
        fi
        printf '%s\n' "$5" | while read -r kind id pkg _; do
            id=${id//\'/}
            pkg=${pkg//\'/}
            case "${kind}" in
                s) echo "ok ${id}" ;;
                u) echo "undone ${id}" ;;
                p) if grep -qxF "${pkg}" "${STATE}/pkgs" 2>/dev/null; then echo "ok ${id}"; else echo "absent ${id}"; fi ;;
            esac
        done
        ;;
    "inspect -f {{ index .Config.Labels \"PREFIX\" }} lepton-microemu-play") cat "${STATE}/prefix" ;;
    "stop -t 1 lepton-microemu-play"|"rm -fi lepton-microemu-play") ;;
    "unshare rm -rf "*) [[ ! -e "${STATE}/unshare-fail" ]] || exit 1; rm -rf "${3}" ;;
    *) echo "podman: unexpected $*" >&2; exit 99 ;;
esac
STUB
cat > "${T}/bin/pgrep" <<'STUB'
#!/usr/bin/bash
[[ "$*" == "-x steam" ]] || exit 99
[[ -e "${STATE}/steam" ]]
STUB
cat > "${T}/bin/systemd-notify" <<'STUB'
#!/usr/bin/bash
echo "notify $*" >> "${STATE}/events"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROEMU_RUNTIME_DIR}"
    mkdir -p "${STATE}"
    : > "${STATE}/events"
    : > "${STATE}/podman"
    echo true > "${STATE}/running"
    echo 1 > "${STATE}/booted"
    printf 'I ActivityManager: start\n' > "${STATE}/logcat"
    printf '/dev/input/event10\n/dev/input/event12\n' > "${STATE}/nodes"
    printf '%s\n' "$1" | tr ';' '\n' > "${STATE}/script"
    rm -f "${MICROEMU_STEAM_PIPE}"
    mkfifo "${MICROEMU_STEAM_PIPE}"
}

run() {
    rc=0
    SteamAppId=1234 LD_LIBRARY_PATH=/appimage/lib "${run_script}" 2> "${STATE}/stderr" || rc=$?
}

events() { cat "${STATE}/events"; }

reset "starting;Boot complete!;sleep 0.5;logcat after boot;exit 3"
run
[[ "${rc}" == 3 ]] || fail "exit code ${rc}, expected lepton's 3: $(cat "${STATE}/stderr")"
for var in TERM=dumb APP_WANTS_FLATSCREEN=true GAMESCOPE_WAYLAND_DISPLAY=gamescope-0 \
    "STEAM_COMPAT_DATA_PATH=${MICROEMU_PLAY_CONTEXT}" LEPTON_NO_CLEANUP=true LEPTON_KEEP_CONTEXT=1 \
    "CONTAINERS_CONF_OVERRIDE=${conf}"; do
    grep -qx "${var}" "${STATE}/env" || fail "environment lacks ${var}"
done
grep -q '^SteamAppId=' "${STATE}/env" && fail "SteamAppId reached lepton"
grep -q '^LD_LIBRARY_PATH=' "${STATE}/env" && fail "LD_LIBRARY_PATH reached lepton"
[[ -s "${STATE}/internal" ]] || fail "internal/ not created before lepton start"
[[ "$(cat "${STATE}/parent")" == *"/microemu-play-run"* ]] || fail "lepton is not a child of microemu-play-run: $(cat "${STATE}/parent")"
grep -qx "lepton start microemu-play" "${STATE}/events" || fail "lepton not run as start microemu-play"
[[ "$(sed -n '1p' "${conf}")" == "[containers]" ]] || fail "conf header"
grep -qx 'annotations = \["run.oci.systemd.subgroup=app-steam-app1-1.scope"\]' "${conf}" || fail "annotation missing: $(cat "${conf}")"
expected_mounts="mounts = [\"type=bind,source=/dev/input/event10,destination=/dev/input/event10,rw\",\"type=bind,source=/dev/input/event12,destination=/dev/input/event12,rw\",\"type=bind,source=${odm},destination=/vendor/odm/etc/build.prop,ro\"]"
grep -qxF "${expected_mounts}" "${conf}" || fail "mounts: $(cat "${conf}")"
[[ "$(cat "${odm}")" == $'ro.odm.build.id=RQ3A\nro.product.odm.model=lepton\nro.sf.lcd_density=213\nqemu.hw.mainkeys=1\ndebug.mesa.tu.debug=noubwc\npm.dexopt.install=speed' ]] || fail "odm prop: $(cat "${odm}")"
expected_events="notify EXTEND_TIMEOUT_USEC=120000000
lepton start microemu-play
out starting
out Boot complete!
opts
notify --ready
out logcat after boot"
[[ "$(events)" == "${expected_events}" ]] || fail "events: $(events)"
grep -qx "starting" "${STATE}/stderr" || fail "boot output not in the journal"
grep -q "logcat after boot" "${STATE}/stderr" && fail "post boot output reached the journal"
[[ "$(cat "${MICROEMU_ANDROID_DATA}/lepton.log")" == $'logcat after boot\nmicroemu-play-run: lepton start exited with 3' ]] || fail "lepton.log: $(cat "${MICROEMU_ANDROID_DATA}/lepton.log")"
[[ "$(cat "${MICROEMU_PLAY_CONTEXT}/microemu-stamp")" == "3.0.5 3.0.3" ]] || fail "stamp not written"
[[ "$(cat "${MICROEMU_ANDROID_DATA}/boot.log")" == "I ActivityManager: start" ]] || fail "boot log: $(cat "${MICROEMU_ANDROID_DATA}/boot.log" 2>/dev/null)"
grep -q "lepton start exited with 3" "${STATE}/stderr" || fail "exit not logged"
opts="${MICROEMU_PLAY_CONTEXT}/microemu-opts"
script="${STATE}/opts-script-1"
for line in "s 'wifi-scan' 'settings' 'put' 'global' 'wifi_scan_always_enabled' '0'" \
    "s 'captive-portal' 'settings' 'put' 'global' 'captive_portal_mode' '0'" \
    "s 'idle-alarms' 'settings' 'put' 'global' 'alarm_manager_constants' 'allow_while_idle_short_time=10000,allow_while_idle_long_time=20000'" \
    "p 'printspooler' 'com.android.printspooler'" "p 'stk' 'com.android.stk'"; do
    grep -qxF "${line}" "${script}" || fail "opts: missing ${line}: $(cat "${script}")"
done
grep -qE "appops|set-standby-bucket|com\.google\.android\.gms|com\.android\.vending|trim-caches|use_freezer|use_fifo_ui|sensor_privacy|job_scheduler" "${script}" \
    && fail "opts: an excluded command was sent: $(cat "${script}")"
[[ "$(grep -c '^[spu] ' "${script}")" == 11 ]] || fail "opts: $(grep -c '^[spu] ' "${script}") commands, expected 11"
[[ "$(wc -l < "${opts}")" == 11 ]] || fail "opts stamp: $(cat "${opts}")"
grep -q "guest settings: 11 applied, 0 failed" "${STATE}/stderr" || fail "opts: no summary: $(cat "${STATE}/stderr")"

reset "Boot complete!;sleep 0.2;exit 0"
run
[[ ! -e "${STATE}/opts-script-1" ]] || fail "opts: sent again with every id applied: $(cat "${STATE}/opts-script-1")"

custom="${T}/opts"
{
    grep -v '^set ble-scan ' "${MICROEMU_ANDROID_OPTS}"
    echo "unset ble-scan settings delete global ble_scan_always_enabled"
    echo "set new-one settings put global microemu_test 1"
} > "${custom}"
reset "Boot complete!;sleep 0.2;exit 0"
MICROEMU_ANDROID_OPTS="${custom}" run
[[ "$(grep '^[spu] ' "${STATE}/opts-script-1")" == $'u \'ble-scan\' \'settings\' \'delete\' \'global\' \'ble_scan_always_enabled\'\ns \'new-one\' \'settings\' \'put\' \'global\' \'microemu_test\' \'1\'' ]] \
    || fail "opts change: $(grep '^[spu] ' "${STATE}/opts-script-1")"
grep -qx "ble-scan" "${opts}" && fail "opts change: undone id kept in the stamp"
grep -qx "new-one" "${opts}" || fail "opts change: new id not stamped"
reset "Boot complete!;sleep 0.2;exit 0"
MICROEMU_ANDROID_OPTS="${custom}" run
[[ ! -e "${STATE}/opts-script-1" ]] || fail "opts change: undo or new id run twice: $(cat "${STATE}/opts-script-1")"

rm -f "${opts}"
reset "Boot complete!;sleep 0.2;exit 0"
printf 'ok wifi-scan\nfail ble-scan\nabsent stk\n' > "${STATE}/opts-reply"
run
grep -q "guest setting ble-scan failed" "${STATE}/stderr" || fail "opts fail: not logged"
grep -qx "ble-scan" "${opts}" && fail "opts fail: failed id stamped"
grep -qx "stk" "${opts}" || fail "opts fail: absent package not stamped"
grep -q "android ready" "${STATE}/stderr" || fail "opts fail: not ready"
reset "Boot complete!;sleep 0.2;exit 0"
run
grep -qxF "s 'ble-scan' 'settings' 'put' 'global' 'ble_scan_always_enabled' '0'" "${STATE}/opts-script-1" || fail "opts fail: not retried"
grep -q "'wifi-scan'\|'stk'" "${STATE}/opts-script-1" && fail "opts fail: done ids retried"

rm -f "${opts}"
reset "Boot complete!;sleep 0.2;exit 0"
echo 5 > "${STATE}/opts-sleep"
start_ms=$(date +%s%3N)
MICROEMU_ANDROID_OPTS_TIMEOUT_S=1 run
(( $(date +%s%3N) - start_ms < 4000 )) || fail "opts timeout: the start waited for the guest"
grep -q "guest settings timed out after 1 s, the next start retries the rest" "${STATE}/stderr" || fail "opts timeout: not logged: $(cat "${STATE}/stderr")"
grep -q "android ready" "${STATE}/stderr" || fail "opts timeout: not ready"
[[ ! -s "${opts}" ]] || fail "opts timeout: ids stamped: $(cat "${opts}")"
grep -q "notify --ready" "${STATE}/events" || fail "opts timeout: no ready notify"

reset "Boot complete!;sleep 0.2;exit 0"
MICROEMU_ANDROID_OPTS="${T}/absent-opts" run
grep -q "absent-opts missing, no guest settings applied" "${STATE}/stderr" || fail "opts missing: no log"
grep -q "android ready" "${STATE}/stderr" || fail "opts missing: not ready"

reset "Boot complete!;exit 0"
run
grep -q EXTEND_TIMEOUT_USEC "${STATE}/events" && fail "same stamp extended the timeout"
grep -qx "notify --ready" "${STATE}/events" || fail "same stamp: no ready"

reset "Boot complete!;exit 0"
echo false > "${STATE}/running"
mkdir -p "${MICROEMU_ANDROID_DATA}"
echo "old boot" > "${MICROEMU_ANDROID_DATA}/boot.log"
run
[[ "${rc}" == 1 ]] || fail "dead container exit ${rc}"
grep -q "android exited during boot, see ${MICROEMU_ANDROID_DATA}/boot.log" "${STATE}/stderr" || fail "early exit not logged"
[[ ! -s "${MICROEMU_ANDROID_DATA}/boot.log" ]] || fail "boot.log not truncated: $(cat "${MICROEMU_ANDROID_DATA}/boot.log")"
grep -q "notify --ready" "${STATE}/events" && fail "ready sent for a dead container"
grep -q "Boot complete! but the container is not running or not booted" "${STATE}/stderr" || fail "dead container not logged"

reset "Boot complete!;exit 1"
echo 0 > "${STATE}/booted"
run
grep -q "notify --ready" "${STATE}/events" && fail "ready sent before sys.boot_completed"

reset "exit 0"
: > "${STATE}/nodes"
run
grep -qxF "mounts = [\"type=bind,source=${odm},destination=/vendor/odm/etc/build.prop,ro\"]" "${conf}" || fail "no pad: mounts $(cat "${conf}")"

reset "sleep 0.5;exit 1"
printf 'I x: ok\nE SystemServer: Signature|privileged permissions not in privapp-permissions whitelist: {x}\n' > "${STATE}/logcat"
run
grep -q "not in privapp-permissions whitelist" "${MICROEMU_ANDROID_DATA}/privapp-log" || fail "privapp flag not set"
grep -q "whitelist" "${MICROEMU_ANDROID_DATA}/boot.log" || fail "boot log lacks the whitelist line"
reset "exit 0"
run
grep -qx "ro.control_privapp_permissions=log" "${odm}" || fail "privapp flag not applied"
grep -q "privapp log mode" "${STATE}/stderr" || fail "privapp log mode not logged"
rm -f "${MICROEMU_ANDROID_DATA}/privapp-log"

reset "exit 0"
rm -f "${MICROEMU_LEPTON}.off"
mv "${MICROEMU_LEPTON}" "${MICROEMU_LEPTON}.off"
run
mv "${MICROEMU_LEPTON}.off" "${MICROEMU_LEPTON}"
[[ "${rc}" == 1 ]] || fail "lepton-armada missing exit ${rc}"
[[ "$(cat "${MICROEMU_RUNTIME_DIR}/play-start-failed")" == "${MICROEMU_LEPTON} missing" ]] || fail "refusal reason not written"
reset "Boot complete!;exit 0"
mkdir -p "${MICROEMU_RUNTIME_DIR}"
echo old > "${MICROEMU_RUNTIME_DIR}/play-start-failed"
run
[[ ! -e "${MICROEMU_RUNTIME_DIR}/play-start-failed" ]] || fail "refusal reason kept after a start"
reset "exit 0"
run
[[ "$(cat "${MICROEMU_RUNTIME_DIR}/play-start-failed")" == "android exited during boot, see ${MICROEMU_ANDROID_DATA}/boot.log" ]] || fail "early exit reason not written"
reset "exit 0"
: > "${STATE}/no-lepton-dir"
run
[[ "${rc}" == 1 ]] && grep -q "Steam's Lepton is not installed" "${STATE}/stderr" || fail "no Lepton install: exit ${rc}"
reset "exit 0"
mv "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop" "${T}/odm.off"
run
mv "${T}/odm.off" "${T}/lepton/images/rootfs/vendor/odm/etc/build.prop"
[[ "${rc}" == 1 ]] && grep -q "build.prop missing" "${STATE}/stderr" || fail "odm build.prop missing: exit ${rc}"

reset "pipe steam://open/games;Boot complete!;sleep 0.3;pipe steam://install/3029110;sleep 1.5;exit 0"
run
grep -qx "microemu-play-run: android asked to open steam://open/games" "${STATE}/stderr" || fail "pipe before boot not read: $(cat "${STATE}/stderr")"
grep -qx "microemu-play-run: android asked to open steam://install/3029110" "${STATE}/stderr" || fail "pipe after boot not read"
grep -q "pipe blocked" "${STATE}/events" && fail "a pipe write blocked"
timeout 1 bash -c 'echo late > "$1"' _ "${MICROEMU_STEAM_PIPE}" && fail "the pipe reader outlived microemu-play-run"

reset "pipe steam://open/games;exit 0"
: > "${STATE}/steam"
run
grep -q "android asked to open" "${STATE}/stderr" && fail "pipe read while Steam runs"
grep -q "pipe blocked" "${STATE}/events" || fail "the pipe had a reader while Steam runs"

reset "exit 0"
rm -f "${MICROEMU_STEAM_PIPE}"
start=$(date +%s%3N)
run
took=$(( $(date +%s%3N) - start ))
grep -q "no ${MICROEMU_STEAM_PIPE}, Steam links from Android are not read" "${STATE}/stderr" || fail "missing pipe not logged"
(( took < 3000 )) || fail "missing pipe: took ${took} ms"

reset "Boot complete!;hold;exit 4"
start=$(date +%s%3N)
run
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 4 ]] || fail "descendant holding the output: exit ${rc}"
(( took < 4000 )) || fail "descendant holding the output: took ${took} ms"
grep -q "lepton start exited with 4" "${STATE}/stderr" || fail "exit line not in the journal with a descendant holding the output"

reset "Boot complete!;sleep 1.5;exit 0"
SteamAppId=1234 "${run_script}" 2> "${STATE}/stderr" &
pid=$!
sleep 0.7
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
grep -q "stop requested, waiting for lepton start" "${STATE}/stderr" || fail "TERM not noted"
grep -q "lepton start exited with 0" "${STATE}/stderr" || fail "exit line lost on TERM: $(cat "${STATE}/stderr")"

reset "steam-on;sleep 1.2;rmpipe;sleep 0.3;steam-off;sleep 2.5;exit 0"
run
[[ ! -e "${MICROEMU_STEAM_PIPE}" ]] || fail "a file was created at the pipe path: $(ls -la "${MICROEMU_STEAM_PIPE}")"

reset "sleep 0.4;rmpipe;exit 0"
run
[[ ! -e "${MICROEMU_STEAM_PIPE}" ]] || fail "pipe removed under the reader: a file was created"

prefix_dir=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
reset "exit 0"
echo "${prefix_dir}" > "${STATE}/prefix"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ "$(sed 's/^podman //' "${STATE}/podman")" == $'inspect -f {{ index .Config.Labels "PREFIX" }} lepton-microemu-play\nstop -t 1 lepton-microemu-play\nrm -fi lepton-microemu-play' ]] \
    || fail "post calls: $(cat "${STATE}/podman")"
[[ ! -e "${prefix_dir}" ]] || fail "post: lepton prefix left"
reset "exit 0"
mkdir -p "${T}/keep"
echo "${T}/keep" > "${STATE}/prefix"
"${stop_script}" --post 2> "${STATE}/stderr"
[[ -d "${T}/keep" ]] || fail "post removed a prefix outside /tmp/lepton-context.*"
grep -q removed "${STATE}/stderr" && fail "post logged a removal it did not do"
stuck_dir=$(mktemp -d /tmp/lepton-context.XXXXXXXX)
mkdir -p "${stuck_dir}/sub"
: > "${stuck_dir}/sub/file"
chmod 0500 "${stuck_dir}/sub"
reset "exit 0"
echo "${stuck_dir}" > "${STATE}/prefix"
: > "${STATE}/unshare-fail"
"${stop_script}" --post 2> "${STATE}/stderr"
chmod 0700 "${stuck_dir}/sub"
rm -rf "${stuck_dir}"
grep -q "cannot remove ${stuck_dir}" "${STATE}/stderr" || fail "failed removal not logged: $(cat "${STATE}/stderr")"
grep -q "removed the leftover" "${STATE}/stderr" && fail "failed removal logged as removed"
reset "exit 0"
"${stop_script}"
[[ "$(cat "${STATE}/podman")" == "podman stop -t 1 lepton-microemu-play" ]] || fail "stop: $(cat "${STATE}/podman")"
rc=0
"${stop_script}" --bogus 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "unknown verb exit ${rc}"

unit="${repo}/sysext/usr/lib/systemd/user/microemu-play.service"
for line in BindsTo=gamescope-session-plus@microemu.service Type=notify NotifyAccess=all \
    'ExecStartPre=/usr/bin/podman rm -fi lepton-microemu-play' ExecStart=/usr/libexec/microemu/microemu-play-run \
    ExecStop=/usr/libexec/microemu/microemu-play-stop 'ExecStopPost=/usr/libexec/microemu/microemu-play-stop --post' \
    TimeoutStartSec=60 TimeoutStopSec=10 SuccessExitStatus=137; do
    grep -qxF "${line}" "${unit}" || fail "unit lacks ${line}"
done
grep -q '^After=' "${unit}" && fail "unit is ordered after something"

if (( failures )); then
    echo "play-unit-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "play-unit-test: ok"
