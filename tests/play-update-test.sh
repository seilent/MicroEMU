#!/usr/bin/bash
set -eu

export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
update="${repo}/android/data/usr/bin/microemu-play-update"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_PLAY_RUN="${T}/bin/play-run"
export MICROEMU_PLAY_CONTEXT="${T}/contexts/microemu-play"
export MICROEMU_GAPPS="${T}/gapps"
export MICROEMU_PLAY_UPDATE_POLL_S=0.1
export MICROEMU_PLAY_UPDATE_BOUND_S=5
export XDG_RUNTIME_DIR="${T}/run"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_GAMESCOPE="${T}/bin/gamescope"
export MICROEMU_HEADLESS_WAIT_S=3
export MICROEMU_DISPLAY_FILE="${repo}/android/data/usr/share/microemu/android/display"
export MICROEMU_ANDROID_DATA="${T}/data/android"
headless_dir="${MICROEMU_RUNTIME_DIR}/headless"
clear_marker="${MICROEMU_RUNTIME_DIR}/play-update-clear"
setup_marker="${MICROEMU_RUNTIME_DIR}/play-update-setup"
packages="${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system/packages.xml"

cat > "${T}/dumpsys-sample" <<'STUB'
dumpsys_sample() {
    local i
    echo "Active install sessions:"
    echo "  "
    for ((i = 1; i <= $1; i++)); do
        echo "  Session 117704590${i}: "
        echo "    userId=0 mOriginalInstallerUid=10017 mOriginalInstallerPackageName=com.android.vending "
        echo "    installerPackageName=com.android.vending installInitiatingPackageName=com.android.vending "
        echo "    stageDir=/data/app/vmdl117704590${i}.tmp stageCid=null "
        echo "    mode=1 installFlags=0x504012 installLocation=1 sizeBytes=217855337 appPackageName=${2:-com.google.android.gms}"
        echo "    mClientProgress=0.0 mProgress=0.0 mCommitted=false mSealed=false mPermissionsManuallyAccepted=false "
        echo "  "
    done
    echo "Finalized install sessions:"
    echo "  Session 555:"
    echo "    userId=0 appPackageName=com.google.android.gms "
    echo "  "
    echo "Historical install sessions:"
    echo "  Session 777:"
    echo "    userId=0 mCommitted=true "
}
STUB
cat > "${T}/bin/gamescope" <<'STUB'
#!/usr/bin/bash
echo "${0##*/} $* XDG=${XDG_RUNTIME_DIR}" >> "${STATE}/calls"
echo "$$" > "${STATE}/gamescope_pid"
ready=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[i]}" == -R ]] && ready=${args[i + 1]}
done
sleep "$(cat "${STATE}/gamescope_delay" 2>/dev/null || echo 0)"
if [[ ! -e "${STATE}/no_socket" ]]; then
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/gamescope-0"
    printf ':5 gamescope-0\n' > "${ready}"
fi
exec sleep 60
STUB
cat > "${T}/bin/play-run" <<'STUB'
#!/usr/bin/bash
echo "play-run $* display=${GAMESCOPE_WAYLAND_DISPLAY:-unset} XDG=${XDG_RUNTIME_DIR}" >> "${STATE}/calls"
. "${T_DUMPSYS_SAMPLE}"
echo "play-run $*" >> "${STATE}/calls"
packages="${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system/packages.xml"
while IFS= read -r step; do
    case "${step}" in
        sleep*) sleep "${step#sleep }" ;;
        exit*) exit "${step#exit }" ;;
        session*) read -r -a session_args <<<"${step#session }"; dumpsys_sample "${session_args[@]}" > "${STATE}/dumpsys" ;;
        write*)
            read -r _ gms vending <<<"${step}"
            mkdir -p "${packages%/*}"
            printf '<packages>\n<updated-package name="com.google.android.gms" version="204516046" />\n<package name="com.google.android.gms" version="%s" />\n<package name="com.android.vending" version="%s" />\n</packages>\n' \
                "${gms}" "${vending}" > "${packages}.new"
            mv "${packages}.new" "${packages}"
            ;;
    esac
done < "${STATE}/script"
until [[ -e "${STATE}/stopped" ]]; do sleep 0.05; done
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/calls"
case "$*" in
    "container exists lepton-microemu-play") exit "$(cat "${STATE}/exists_rc")" ;;
    "container exists lepton-headless-microemu-play") [[ ! -e "${STATE}/no_container" ]] ;;
    "stop -t "*" lepton-headless-microemu-play") : > "${STATE}/stopped" ;;
    "exec lepton-headless-microemu-play /system/bin/sync") ;;
    "exec lepton-headless-microemu-play /system/bin/getprop sys.boot_completed") [[ ! -e "${STATE}/getprop_slow" ]] || sleep 5; v=$(cat "${STATE}/booted"); echo "booted=${v}" >> "${STATE}/calls"; echo "${v}" ;;
    "exec lepton-headless-microemu-play /system/bin/dumpsys package installs") sleep "$(cat "${STATE}/dumpsys_sleep" 2>/dev/null || echo 0)"; cat "${STATE}/dumpsys" ;;
    "exec lepton-headless-microemu-play /system/bin/pm clear com.android.vending") exit "$(cat "${STATE}/clear_rc")" ;;
    "exec lepton-headless-microemu-play /system/bin/pidof dex2oat64 dex2oat32 dex2oat")
        if [[ -e "${STATE}/dex2oat_until" ]] && (( $(date +%s%N) / 1000000 < $(cat "${STATE}/dex2oat_until") )); then
            echo 4242
            exit 0
        fi
        exit 1 ;;
    "exec lepton-headless-microemu-play /system/bin/cmd_real package list packages -3") cat "${STATE}/third_party" 2>/dev/null; exit 0 ;;
    "exec lepton-headless-microemu-play /system/bin/cmd_real package compile -m speed "*)
        sleep "$(cat "${STATE}/compile_sleep" 2>/dev/null || echo 0)"
        [[ -e "${STATE}/compile_fail" ]] && { echo "Failure: dex2oat"; exit 1; }
        echo Success ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user show -P ActiveState microemu-play.service") cat "${STATE}/unit" ;;
    "--user show -P ActiveState microemu-play-update.service") cat "${STATE}/update_unit" ;;
    "--user show -P Result microemu-play-update.service") cat "${STATE}/result" ;;
    "--user start --no-block microemu-play-update.service"|"--user start microemu-play-update.service") exit "$(cat "${STATE}/start_rc")" ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/journalctl" <<'STUB'
#!/usr/bin/bash
echo "journalctl $*" >> "${STATE}/calls"
sleep 30
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export T_DUMPSYS_SAMPLE="${T}/dumpsys-sample"
. "${T_DUMPSYS_SAMPLE}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

write_packages() {
    mkdir -p "${packages%/*}"
    printf '<packages>\n<package name="com.google.android.gms" version="%s" />\n<package name="com.android.vending" version="%s" />\n</packages>\n' "$1" "$2" > "${packages}"
}

reset() {
    rm -rf "${STATE}" "${MICROEMU_PLAY_CONTEXT}" "${MICROEMU_GAPPS}" "${MICROEMU_RUNTIME_DIR}"
    mkdir -p "${STATE}" "${MICROEMU_GAPPS}/set"
    ln -s set "${MICROEMU_GAPPS}/current"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    echo inactive > "${STATE}/unit"
    echo 1 > "${STATE}/exists_rc"
    echo 0 > "${STATE}/start_rc"
    echo 1 > "${STATE}/booted"
    echo 0 > "${STATE}/clear_rc"
    echo inactive > "${STATE}/update_unit"
    echo success > "${STATE}/result"
    dumpsys_sample 0 > "${STATE}/dumpsys"
    printf '%s\n' "$1" | tr ';' '\n' > "${STATE}/script"
}

body() {
    rc=0
    local start
    start=$(date +%s%3N)
    "${update}" --body 2> "${STATE}/stderr" || rc=$?
    took=$(( $(date +%s%3N) - start ))
}

has() { grep -qxF -- "microemu-play-update: $1" "${STATE}/stderr" || fail "${case_name}: missing line: $1, got $(cat "${STATE}/stderr")"; }
called() { grep -qxF -- "$1" "${STATE}/calls" || fail "${case_name}: missing call: $1, got $(cat "${STATE}/calls")"; }

case_name="done"
reset "sleep 0.3;write 204516046 85343420;sleep 0.3;write 263737022 85343420"
write_packages 204516046 83662520
body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
called "play-run --headless display=microemu/headless/gamescope-0 XDG=${T}/run"
has "starting android headless, waiting for GMS above 204516046 and Play above 83662520, at most 0 min"
has "Play 83662520 to 85343420"
has "GMS 204516046 to 263737022"
grep -q "^microemu-play-update: done in 0 min [0-9]* s: GMS 263737022, Play 85343420$" "${STATE}/stderr" || fail "${case_name}: no done line: $(cat "${STATE}/stderr")"
[[ "$(grep '^podman' "${STATE}/calls" | grep -v 'getprop\|pidof')" == $'podman exec lepton-headless-microemu-play /system/bin/cmd_real package list packages -3\npodman exec lepton-headless-microemu-play /system/bin/cmd_real package compile -m speed com.google.android.gms\npodman exec lepton-headless-microemu-play /system/bin/cmd_real package compile -m speed com.android.vending\npodman exec lepton-headless-microemu-play /system/bin/sync\npodman container exists lepton-headless-microemu-play\npodman stop -t 5 lepton-headless-microemu-play' ]] \
    || fail "${case_name}: not the compile, then a sync and a graceful stop: $(cat "${STATE}/calls")"
[[ "$(cat "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")" == $'com.google.android.gms 263737022\ncom.android.vending 85343420' ]] || fail "${case_name}: compiled list: $(cat "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")"
(( took < 3000 )) || fail "${case_name}: took ${took} ms"

case_name="gms only"
reset "write 263737022 83662520"
write_packages 204516046 83662520
MICROEMU_PLAY_UPDATE_BOUND_S=1 body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
has "play services update not done after 0 min (GMS 263737022, Play 83662520)"
called "podman stop -t 5 lepton-headless-microemu-play"
(( took < 4000 )) || fail "${case_name}: took ${took} ms"

case_name="play only"
reset "write 204516046 85343420"
write_packages 204516046 83662520
MICROEMU_PLAY_UPDATE_BOUND_S=1 body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
has "play services update not done after 0 min (GMS 204516046, Play 85343420)"

case_name="bound"
reset ""
write_packages 204516046 83662520
MICROEMU_PLAY_UPDATE_BOUND_S=2 MICROEMU_PLAY_UPDATE_REPORT_S=1 body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
(( took >= 1000 && took < 5000 )) || fail "${case_name}: took ${took} ms for a 2 s bound"
grep -q "^microemu-play-update: waiting, 0 min (GMS 204516046, Play 83662520)$" "${STATE}/stderr" || fail "${case_name}: no progress line: $(cat "${STATE}/stderr")"
grep -q "sync" "${STATE}/calls" && fail "${case_name}: sync before a stop that is not done"
has "GMS unchanged: microemu-play-update --clear-play makes Play schedule it at once, and resets Play's own settings"
grep -q "pm clear" "${STATE}/calls" && fail "${case_name}: Play cleared without --clear-play"

case_name="gms only, no hint"
reset "write 263737022 83662520"
write_packages 204516046 83662520
MICROEMU_PLAY_UPDATE_BOUND_S=1 body
grep -q "GMS unchanged" "${STATE}/stderr" && fail "${case_name}: hint with GMS updated"

case_name="clear play"
reset "sleep 0.3;write 263737022 85343420"
write_packages 204516046 85343420
mkdir -p "${MICROEMU_RUNTIME_DIR}"
: > "${clear_marker}"
echo 0 > "${STATE}/booted"
( sleep 0.2; echo 1 > "${STATE}/booted.new"; mv "${STATE}/booted.new" "${STATE}/booted" ) &
body
wait
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(grep -c "pm clear com.android.vending" "${STATE}/calls")" == 1 ]] || fail "${case_name}: Play not cleared once: $(cat "${STATE}/calls")"
[[ "$(grep -n "getprop sys.boot_completed" "${STATE}/calls" | tail -n 1 | cut -d: -f1)" -lt "$(grep -n "pm clear" "${STATE}/calls" | cut -d: -f1)" ]] || fail "${case_name}: cleared before boot"
has "cleared Play's data, Play schedules its updates now"
[[ ! -e "${clear_marker}" ]] || fail "${case_name}: marker kept"
reset "sleep 0.3;write 263737022 85343420"
write_packages 204516046 85343420
mkdir -p "${MICROEMU_RUNTIME_DIR}"
: > "${clear_marker}"
echo 1 > "${STATE}/clear_rc"
body
has "pm clear com.android.vending failed"

case_name="maintenance, gms after play"
reset "sleep 0.3;session 1;write 263737022 85400000;sleep 2;write 263800000 85400000;session 0"
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=30 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
has "starting android headless (GMS 263737022, Play 85343420), done 1 s after the last change with no install session, or after 0 min without one"
has "Play 85343420 to 85400000"
has "install session active (1)"
has "GMS 263737022 to 263800000"
has "no install session"
grep -q "^microemu-play-update: done in 0 min [0-9]* s: GMS 263800000, Play 85400000$" "${STATE}/stderr" || fail "${case_name}: done not after the GMS change: $(cat "${STATE}/stderr")"
(( took >= 3000 && took < 7000 )) || fail "${case_name}: took ${took} ms, expected about 1 s after the GMS change at 2.3 s"
called "podman exec lepton-headless-microemu-play /system/bin/sync"

case_name="maintenance, change then quiet"
reset "sleep 0.3;write 263800000 85343420;sleep 0.6;write 263800000 85400000"
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=30 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
grep -q "^microemu-play-update: done in 0 min [0-9]* s: GMS 263800000, Play 85400000$" "${STATE}/stderr" || fail "${case_name}: no done line: $(cat "${STATE}/stderr")"
(( took >= 1500 && took < 5000 )) || fail "${case_name}: took ${took} ms, expected about 1 s after the second change"

case_name="maintenance, already current"
reset ""
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_QUIET_S=1 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
has "already current after 0 min: GMS 263737022, Play 85343420"
called "podman stop -t 5 lepton-headless-microemu-play"
(( took < 4000 )) || fail "${case_name}: took ${took} ms"
grep -q "not done" "${STATE}/stderr" && fail "${case_name}: logged as not done"

case_name="maintenance, session at the quiet bound"
reset "session 1"
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_QUIET_S=1 MICROEMU_PLAY_UPDATE_BOUND_S=3 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
grep -q "already current" "${STATE}/stderr" && fail "${case_name}: already current with a session"
has "stopped after 0 min with an install session active, run microemu-play-update again"
(( took >= 2500 )) || fail "${case_name}: ended at ${took} ms, before the bound"
grep -q "compile -m speed" "${STATE}/calls" && fail "${case_name}: compiled at the bound"

case_name="maintenance bound skips the compile"
reset "sleep 0.2;write 263737022 85343520"
write_packages 263737022 85343420
mkdir -p "${MICROEMU_PLAY_CONTEXT}"
printf 'com.google.android.gms 263737022\n' > "${MICROEMU_PLAY_CONTEXT}/microemu-compiled"
echo $(( $(date +%s%N) / 1000000 + 60000 )) > "${STATE}/dex2oat_until"
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=1 MICROEMU_PLAY_UPDATE_BOUND_S=2 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
has "stopped after 0 min: GMS 263737022, Play 85343520"
grep -q "package list packages -3\|compile -m speed" "${STATE}/calls" && fail "${case_name}: compiled at the bound"
[[ "$(cat "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")" == "com.google.android.gms 263737022" ]] || fail "${case_name}: compile stamp changed: $(cat "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")"
called "podman stop -t 5 lepton-headless-microemu-play"

case_name="setup bound skips the compile"
reset ""
write_packages 204516046 83662520
MICROEMU_PLAY_UPDATE_BOUND_S=1 body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
grep -q "package list packages -3\|compile -m speed" "${STATE}/calls" && fail "${case_name}: compiled at the bound"

case_name="maintenance, dumpsys unreadable"
reset ""
write_packages 263737022 85343420
: > "${STATE}/dumpsys"
MICROEMU_PLAY_UPDATE_QUIET_S=1 MICROEMU_PLAY_UPDATE_BOUND_S=2 body
grep -q "already current" "${STATE}/stderr" && fail "${case_name}: an unreadable session list counted as none"
has "install session active (unknown)"

case_name="maintenance, session ended without a gms update"
reset "sleep 0.2;session 1;sleep 0.6;session 0"
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=2 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
has "GMS install session ended without an update (GMS 263737022), Play backs off; microemu-play-update --clear-play schedules it at once"
grep -q "already current" "${STATE}/stderr" && fail "${case_name}: logged already current"
grep -q "package list packages -3\|compile -m speed" "${STATE}/calls" && fail "${case_name}: compiled on the session ended path"
[[ ! -s "${MICROEMU_PLAY_CONTEXT}/microemu-compiled" ]] || fail "${case_name}: compile stamp written"
reset "sleep 0.2;session 1 com.google.android.gms;write 263737022 85400000;sleep 0.6;session 0"
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=30 body
[[ "${rc}" == 0 ]] || fail "${case_name}, play only: exit ${rc}"
has "GMS install session ended without an update (GMS 263737022), Play backs off; microemu-play-update --clear-play schedules it at once"
grep -q "^microemu-play-update: done" "${STATE}/stderr" && fail "${case_name}, play only: logged done"
grep -q "compile -m speed" "${STATE}/calls" && fail "${case_name}, play only: compiled on the session ended path"

case_name="maintenance, play session"
reset "sleep 0.2;session 1 com.android.vending;write 263737022 85400000;sleep 0.6;session 0"
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=30 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
grep -q "^microemu-play-update: done in 0 min [0-9]* s: GMS 263737022, Play 85400000$" "${STATE}/stderr" || fail "${case_name}: not done: $(cat "${STATE}/stderr")"
grep -q "GMS install session ended" "${STATE}/stderr" && fail "${case_name}: a Play session counted as a GMS one"

case_name="maintenance, unknown poll then quiet"
reset "sleep 0.3;session 0"
write_packages 263737022 85343420
: > "${STATE}/dumpsys"
MICROEMU_PLAY_UPDATE_QUIET_S=2 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
has "install session active (unknown)"
has "already current after 0 min: GMS 263737022, Play 85343420"
grep -q "GMS install session ended" "${STATE}/stderr" && fail "${case_name}: an unknown poll counted as a GMS session"

case_name="maintenance, slow dumpsys interrupted"
reset ""
write_packages 263737022 85343420
echo 5 > "${STATE}/dumpsys_sleep"
start=$(date +%s%3N)
"${update}" --body 2> "${STATE}/stderr" &
pid=$!
sleep 0.6
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
took=$(( $(date +%s%3N) - start - 600 ))
[[ "${rc}" == 2 ]] || fail "${case_name}: exit ${rc}"
(( took < 1500 )) || fail "${case_name}: TERM took ${took} ms during a dumpsys"
[[ ! -e "${MICROEMU_RUNTIME_DIR}/play-update-dumpsys" ]] || fail "${case_name}: dumpsys file left"

case_name="session parse"
for n in "0 -" "1 com.google.android.gms" "3 com.google.android.gms" "1 com.android.vending" "2 com.google.android.gmsx"; do
    read -r count pkg <<<"${n}"
    expected_gms=0
    [[ "${pkg}" == com.google.android.gms && "${count}" != 0 ]] && expected_gms=1
    sessions_seen=$(bash -c '
        . "$1"
        n=$3
        pkg=$5
        podman() { dumpsys_sample "${n}" "${pkg}"; }
        timeout() { shift; "$@"; }
        CONTAINER=c
        DUMP=$4
        stopping=0
        eval "$(sed -n "/^read_sessions() {/,/^}/p" "$2")"
        read_sessions
        echo "${sessions} ${gms_session}"' _ "${T_DUMPSYS_SAMPLE}" "${update}" "${count}" "${T}/dump" "${pkg}")
    [[ "${sessions_seen}" == "${count} ${expected_gms}" ]] || fail "${case_name}: ${count} ${pkg} sessions read as ${sessions_seen}"
done

case_name="maintenance, quiet bound not reached"
reset ""
write_packages 263737022 85343420
MICROEMU_PLAY_UPDATE_QUIET_S=30 MICROEMU_PLAY_UPDATE_BOUND_S=1 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
has "stopped after 0 min: GMS 263737022, Play 85343420"

case_name="setup, already current"
reset ""
write_packages 263737022 85343420
mkdir -p "${MICROEMU_RUNTIME_DIR}"
: > "${setup_marker}"
MICROEMU_PLAY_UPDATE_QUIET_S=30 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
has "starting android headless, waiting for GMS above 204516046 and Play above 83662520, at most 0 min"
grep -q "^microemu-play-update: done in 0 min [0-9]* s: GMS 263737022, Play 85343420$" "${STATE}/stderr" || fail "${case_name}: not done at once: $(cat "${STATE}/stderr")"
(( took < 2000 )) || fail "${case_name}: took ${took} ms"
[[ ! -e "${setup_marker}" ]] || fail "${case_name}: marker kept"

case_name="body refuses with microemu-play running"
reset ""
write_packages 204516046 83662520
echo activating > "${STATE}/unit"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
has "microemu-play.service is running, refusing"
grep -q "play-run" "${STATE}/calls" && fail "${case_name}: android started"

case_name="fresh context"
reset "sleep 0.2;write 204516046 83662520;sleep 0.2;write 263737022 85343420"
body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
grep -q " 0 to " "${STATE}/stderr" && fail "${case_name}: a missing file logged as version 0"

case_name="android exits"
reset "exit 1"
write_packages 204516046 83662520
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
has "android exited before the update (GMS 204516046, Play 83662520)"
grep -q "^podman stop" "${STATE}/calls" && fail "${case_name}: stop after the exit"

case_name="interrupted"
reset ""
write_packages 204516046 83662520
start=$(date +%s%3N)
"${update}" --body 2> "${STATE}/stderr" &
pid=$!
sleep 0.5
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 2 ]] || fail "${case_name}: exit ${rc}"
has "stop requested, update interrupted (GMS 204516046, Play 83662520)"
called "podman stop -t 1 lepton-headless-microemu-play"
grep -q "sync" "${STATE}/calls" && fail "${case_name}: sync on an interruption"
(( took < 1500 )) || fail "${case_name}: took ${took} ms"

run() {
    rc=0
    "${update}" "$@" 2> "${STATE}/stderr" || rc=$?
}

for state in active activating deactivating; do
    case_name="refused, microemu-play ${state}"
    reset ""
    echo "${state}" > "${STATE}/unit"
    run --no-block
    [[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
    grep -qx "microemu-play.service is running, refusing" "${STATE}/log" || fail "${case_name}: no journal line"
    grep -q "start" "${STATE}/calls" && fail "${case_name}: unit started"
done

case_name="refused, container"
reset ""
echo 0 > "${STATE}/exists_rc"
run
[[ "${rc}" == 1 ]] && grep -qx "container lepton-microemu-play exists, refusing" "${STATE}/log" || fail "${case_name}: exit ${rc}"
grep -q "start" "${STATE}/calls" && fail "${case_name}: unit started"

case_name="refused, podman error"
reset ""
echo 125 > "${STATE}/exists_rc"
run
[[ "${rc}" == 1 ]] && grep -qx "podman container exists failed (rc=125), refusing" "${STATE}/log" || fail "${case_name}: exit ${rc}"

case_name="refused, layer off"
reset ""
rm "${MICROEMU_GAPPS}/current"
run --no-block
[[ "${rc}" == 1 ]] && grep -qx "the Google Play layer is off, run microemu-gapps-install" "${STATE}/log" || fail "${case_name}: exit ${rc}"
grep -q "start" "${STATE}/calls" && fail "${case_name}: unit started"

case_name="no block"
reset ""
start=$(date +%s%3N)
run --no-block
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
called "systemctl --user start --no-block microemu-play-update.service"
grep -q "journalctl" "${STATE}/calls" && fail "${case_name}: journal followed"
grep -qx "update started in the background, see journalctl --user -u microemu-play-update.service" "${STATE}/log" || fail "${case_name}: no journal line"
(( took < 1000 )) || fail "${case_name}: took ${took} ms"

case_name="foreground"
reset ""
start=$(date +%s%3N)
run
took=$(( $(date +%s%3N) - start ))
(( took < 5000 )) || fail "${case_name}: took ${took} ms, the journal follower held it"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
called "systemctl --user start microemu-play-update.service"
called "journalctl --user -f -n 0 -o cat -u microemu-play-update.service -t microemu-play-update"
pgrep -f "${T}/bin/journalctl" >/dev/null && fail "${case_name}: journal follower left running"

case_name="clear play option"
reset ""
run --no-block --clear-play
[[ "${rc}" == 0 && -e "${clear_marker}" ]] || fail "${case_name}: exit ${rc}, marker $(ls "${MICROEMU_RUNTIME_DIR}" 2>/dev/null)"
called "systemctl --user start --no-block microemu-play-update.service"
reset ""
echo 1 > "${STATE}/start_rc"
run --clear-play --no-block
[[ "${rc}" == 1 && ! -e "${clear_marker}" ]] || fail "${case_name}: failed start kept the marker"
reset ""
run --clear-play
[[ "${rc}" == 0 && ! -e "${clear_marker}" ]] || fail "${case_name}: foreground run kept the marker"
reset ""
echo active > "${STATE}/unit"
run --clear-play
[[ ! -e "${clear_marker}" ]] || fail "${case_name}: marker written on a refusal"

case_name="already running"
for state in active activating; do
    reset ""
    echo "${state}" > "${STATE}/update_unit"
    run --no-block --clear-play --setup
    [[ "${rc}" == 1 ]] && grep -qx "microemu-play-update.service already running" "${STATE}/log" || fail "${case_name} ${state}: exit ${rc}"
    [[ ! -e "${clear_marker}" && ! -e "${setup_marker}" ]] || fail "${case_name} ${state}: a marker written"
    grep -q " start " "${STATE}/calls" && fail "${case_name} ${state}: unit started"
done

case_name="setup option"
reset ""
run --no-block --setup
[[ "${rc}" == 0 && -e "${setup_marker}" ]] || fail "${case_name}: exit ${rc}, no marker"
reset ""
run --setup
[[ "${rc}" == 0 && ! -e "${setup_marker}" ]] || fail "${case_name}: foreground run kept the marker"
reset ""
echo active > "${STATE}/unit"
run --setup
[[ ! -e "${setup_marker}" ]] || fail "${case_name}: marker written on a refusal"

case_name="foreground, not done"
reset ""
echo 1 > "${STATE}/start_rc"
echo exit-code > "${STATE}/result"
run
[[ "${rc}" == 1 ]] && grep -qx "update not done (result exit-code), see journalctl --user -u microemu-play-update.service" "${STATE}/log" || fail "${case_name}: exit ${rc}: $(cat "${STATE}/log")"
reset ""
echo timeout > "${STATE}/result"
run
[[ "${rc}" == 1 ]] && grep -qx "update not done (result timeout), see journalctl --user -u microemu-play-update.service" "${STATE}/log" || fail "${case_name}, timeout with start rc 0: exit ${rc}"
reset ""
echo 1 > "${STATE}/start_rc"
echo success > "${STATE}/result"
run
[[ "${rc}" == 1 ]] && grep -qx "update not done (result stopped), see journalctl --user -u microemu-play-update.service" "${STATE}/log" || fail "${case_name}, stopped and reset by a launch: exit ${rc}: $(cat "${STATE}/log")"

case_name="bad option"
reset ""
run --bogus
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
[[ ! -s "${STATE}/calls" ]] || fail "${case_name}: calls $(cat "${STATE}/calls")"

gamescope_alive() { kill -0 "$(cat "${STATE}/gamescope_pid" 2>/dev/null || echo 0)" 2>/dev/null; }

case_name="headless gamescope"
reset "sleep 0.3;write 263737022 85343420"
write_packages 204516046 83662520
body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
called "gamescope --backend headless -W 960 -H 640 --expose-wayland -R ${headless_dir}/ready -- sleep infinity XDG=${headless_dir}"
has "headless gamescope on microemu/headless/gamescope-0"
called "play-run --headless display=microemu/headless/gamescope-0 XDG=${T}/run"
[[ "$(grep -n '^gamescope' "${STATE}/calls" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^play-run' "${STATE}/calls" | head -n 1 | cut -d: -f1)" ]] || fail "${case_name}: android started before gamescope"
gamescope_alive && fail "${case_name}: gamescope left running after done"
[[ ! -e "${headless_dir}" ]] || fail "${case_name}: ${headless_dir} left"

case_name="headless gamescope without a socket"
reset ""
: > "${STATE}/no_socket"
write_packages 204516046 83662520
MICROEMU_HEADLESS_WAIT_S=1 body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
has "headless gamescope did not start, see ${MICROEMU_ANDROID_DATA}/headless-gamescope.log"
grep -q '^play-run' "${STATE}/calls" && fail "${case_name}: android started"
gamescope_alive && fail "${case_name}: gamescope left running"
(( took < 3000 )) || fail "${case_name}: took ${took} ms"

case_name="headless gamescope on android exit"
reset "exit 1"
write_packages 204516046 83662520
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
gamescope_alive && fail "${case_name}: gamescope left running"

case_name="headless gamescope on TERM"
reset ""
write_packages 204516046 83662520
"${update}" --body 2> "${STATE}/stderr" &
pid=$!
sleep 0.6
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
[[ "${rc}" == 2 ]] || fail "${case_name}: exit ${rc}"
gamescope_alive && fail "${case_name}: gamescope left running"

case_name="TERM while gamescope starts"
reset ""
write_packages 204516046 83662520
echo 3 > "${STATE}/gamescope_delay"
MICROEMU_HEADLESS_WAIT_S=5 "${update}" --body 2> "${STATE}/stderr" &
pid=$!
sleep 0.5
start=$(date +%s%3N)
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 2 ]] || fail "${case_name}: exit ${rc}"
(( took < 1500 )) || fail "${case_name}: took ${took} ms"
grep -q '^play-run' "${STATE}/calls" && fail "${case_name}: android started"
gamescope_alive && fail "${case_name}: gamescope left running"

case_name="TERM during a slow getprop"
reset ""
write_packages 204516046 83662520
echo 0 > "${STATE}/booted"
: > "${STATE}/getprop_slow"
"${update}" --body 2> "${STATE}/stderr" &
pid=$!
sleep 1
start=$(date +%s%3N)
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 2 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
(( took < 1500 )) || fail "${case_name}: TERM took ${took} ms during a getprop"

case_name="TERM before the container exists"
reset "sleep 5"
write_packages 204516046 83662520
: > "${STATE}/no_container"
"${update}" --body 2> "${STATE}/stderr" &
pid=$!
sleep 0.6
start=$(date +%s%3N)
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
took=$(( $(date +%s%3N) - start ))
[[ "${rc}" == 2 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
(( took < 1500 )) || fail "${case_name}: took ${took} ms"
grep -q "podman stop" "${STATE}/calls" && fail "${case_name}: podman stop on a missing container"
pgrep -f "${T}/bin/play-run" >/dev/null && fail "${case_name}: microemu-play-run left running"

case_name="no poll before boot"
reset "sleep 0.6;write 263737022 85343420"
write_packages 263737022 85343420
echo 0 > "${STATE}/booted"
( sleep 0.5; echo 1 > "${STATE}/booted.new"; mv "${STATE}/booted.new" "${STATE}/booted" ) &
MICROEMU_PLAY_UPDATE_QUIET_S=30 MICROEMU_PLAY_UPDATE_BOUND_S=5 body
wait
first_boot=$(grep -n '^booted=1' "${STATE}/calls" | head -n 1 | cut -d: -f1)
first_dumpsys=$(grep -n 'dumpsys package installs' "${STATE}/calls" | head -n 1 | cut -d: -f1)
[[ -n "${first_boot}" && -n "${first_dumpsys}" ]] && (( first_dumpsys > first_boot )) || fail "${case_name}: dumpsys before boot: $(cat "${STATE}/calls")"
grep -q "install session active (unknown)" "${STATE}/stderr" && fail "${case_name}: unknown session logged before boot"

case_name="quiet timer from boot"
reset ""
write_packages 263737022 85343420
echo 0 > "${STATE}/booted"
( sleep 1; echo 1 > "${STATE}/booted.new"; mv "${STATE}/booted.new" "${STATE}/booted" ) &
MICROEMU_PLAY_UPDATE_QUIET_S=1 body
wait
has "already current after 0 min: GMS 263737022, Play 85343420"
(( took >= 2000 )) || fail "${case_name}: already current at ${took} ms, before 1 s after boot"

case_name="quiet follow"
reset ""
run
called "journalctl --user -f -n 0 -o cat -u microemu-play-update.service -t microemu-play-update"

case_name="setup waits for dex2oat"
reset "sleep 0.2;write 263737022 85343420"
write_packages 204516046 83662520
echo $(( $(date +%s%N) / 1000000 + 1500 )) > "${STATE}/dex2oat_until"
body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
has "dex2oat running"
(( took >= 1500 )) || fail "${case_name}: done at ${took} ms while dex2oat ran until 1500"

case_name="maintenance settle counts from dex2oat"
reset "sleep 0.2;write 263737022 85343520"
write_packages 263737022 85343420
echo $(( $(date +%s%N) / 1000000 + 1500 )) > "${STATE}/dex2oat_until"
MICROEMU_PLAY_UPDATE_SETTLE_S=1 MICROEMU_PLAY_UPDATE_QUIET_S=30 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
grep -q "^microemu-play-update: done in" "${STATE}/stderr" || fail "${case_name}: no done line: $(cat "${STATE}/stderr")"
(( took >= 2200 )) || fail "${case_name}: done at ${took} ms, without dex2oat it is about 1200, with it about 1 s after 1500"

case_name="compile only changed apps"
reset ""
write_packages 263737022 85343420
mkdir -p "${MICROEMU_PLAY_CONTEXT}"
printf 'com.google.android.gms 263737022\ncom.android.vending 85000000\n' > "${MICROEMU_PLAY_CONTEXT}/microemu-compiled"
printf 'package:com.example.game\npackage:com.example.absent\n' > "${STATE}/third_party"
python3 - "${packages}" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().replace("</packages>", '<package name="com.example.game" version="7" />\n</packages>')
open(path, "w").write(text)
PY
MICROEMU_PLAY_UPDATE_QUIET_S=1 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(grep -o 'compile -m speed .*' "${STATE}/calls")" == $'compile -m speed com.example.game\ncompile -m speed com.android.vending' ]] || fail "${case_name}: compiled $(grep -o 'compile -m speed .*' "${STATE}/calls")"
[[ "$(sort "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")" == $'com.android.vending 85343420\ncom.example.game 7\ncom.google.android.gms 263737022' ]] || fail "${case_name}: compiled list $(cat "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")"
has "compile: 2 apps changed, compiling with speed, at most 10 min"
has "compile: 2 apps done"

case_name="compile nothing changed"
reset ""
write_packages 263737022 85343420
mkdir -p "${MICROEMU_PLAY_CONTEXT}"
printf 'com.google.android.gms 263737022\ncom.android.vending 85343420\n' > "${MICROEMU_PLAY_CONTEXT}/microemu-compiled"
MICROEMU_PLAY_UPDATE_QUIET_S=1 body
grep -q "compile -m speed" "${STATE}/calls" && fail "${case_name}: compiled with no change"
has "compile: no app changed"

case_name="compile failure"
reset ""
write_packages 263737022 85343420
: > "${STATE}/compile_fail"
MICROEMU_PLAY_UPDATE_QUIET_S=1 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
has "compile com.google.android.gms failed"
[[ ! -s "${MICROEMU_PLAY_CONTEXT}/microemu-compiled" ]] || fail "${case_name}: failed apps recorded: $(cat "${MICROEMU_PLAY_CONTEXT}/microemu-compiled")"
called "podman stop -t 5 lepton-headless-microemu-play"

case_name="compile bound"
reset ""
write_packages 263737022 85343420
echo 3 > "${STATE}/compile_sleep"
MICROEMU_PLAY_UPDATE_QUIET_S=1 MICROEMU_PLAY_COMPILE_S=1 body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
grep -q "^microemu-play-update: compile stopped after 0 min at com.google.android.gms, 0 of 2 done" "${STATE}/stderr" || fail "${case_name}: no bound line: $(cat "${STATE}/stderr")"
(( took < 5000 )) || fail "${case_name}: took ${took} ms"
called "podman stop -t 5 lepton-headless-microemu-play"

case_name="TERM during the compile"
reset ""
write_packages 263737022 85343420
echo 10 > "${STATE}/compile_sleep"
start=$(date +%s%3N)
MICROEMU_PLAY_UPDATE_QUIET_S=1 "${update}" --body 2> "${STATE}/stderr" &
pid=$!
for _ in $(seq 1 60); do grep -q "compile -m speed" "${STATE}/calls" && break; sleep 0.1; done
t0=$(date +%s%3N)
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
took=$(( $(date +%s%3N) - t0 ))
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
has "stop requested during the compile, the update is kept"
called "podman stop -t 1 lepton-headless-microemu-play"
(( took < 2000 )) || fail "${case_name}: TERM took ${took} ms"

if (( failures )); then
    echo "play-update-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "play-update-test: ok"
