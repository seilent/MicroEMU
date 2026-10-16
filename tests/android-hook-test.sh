#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
hook="${repo}/android/data/usr/libexec/microemu/game-stop.d/50-android"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user show -P ActiveState microemu-play.service") cat "${STATE}/play" ;;
    "--user stop --no-block microemu-play.service") exit 0 ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/calls"
[[ ! -e "${STATE}/podman_hang" ]] || sleep 5
case "$*" in
    *"/system/bin/date "*) echo "10-12 05:00:00.000" ;;
    *"/system/bin/logcat "*)
        if [[ -e "${STATE}/otherstop" ]]; then
            echo "I/wm_on_stop_called(  640): [0,com.android.launcher3.uioverrides.QuickstepLauncher,STOP_ACTIVITY_ITEM]"
            echo "I/wm_on_stop_called( 1100): [0,com.uberspot.a2048x.MainActivity,STOP_ACTIVITY_ITEM]"
        fi
        if [[ -e "${STATE}/unitystop" ]]; then
            sleep 0.2
            echo "I/wm_on_stop_called( 1301): [0,com.unity3d.player.UnityPlayerActivity,STOP_ACTIVITY_ITEM]"
        fi
        if [[ -e "${STATE}/stopline" ]]; then
            sleep 0.2
            echo "I/wm_on_stop_called( 1301): [0,com.uberspot.a2048.MainActivity,STOP_ACTIVITY_ITEM]"
        fi
        sleep 5 ;;
esac
STUB
chmod 0755 "${T}/bin/systemctl" "${T}/bin/podman"
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

for state in active activating reloading inactive failed deactivating ""; do
    rm -rf "${STATE}" "${MICROEMU_RUNTIME_DIR}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    echo "${state}" > "${STATE}/play"
    rc=0
    start=$(date +%s%3N)
    "${hook}" || rc=$?
    took=$(( $(date +%s%3N) - start ))
    [[ "${rc}" == 0 ]] || fail "${state:-empty}: exit ${rc}"
    (( took < 2000 )) || fail "${state:-empty}: took ${took} ms"
    stops=$(grep -c '^systemctl --user stop --no-block microemu-play.service$' "${STATE}/calls" || true)
    case "${state}" in
        active|activating|reloading)
            [[ "${stops}" == 1 ]] || fail "${state}: no --no-block stop: $(cat "${STATE}/calls")"
            [[ -e "${MICROEMU_RUNTIME_DIR}/play-stop-requested" ]] || fail "${state}: no stop marker" ;;
        *)
            [[ "${stops}" == 0 ]] || fail "${state:-empty}: stopped an idle unit"
            [[ ! -e "${MICROEMU_RUNTIME_DIR}/play-stop-requested" ]] || fail "${state:-empty}: marker for an idle unit" ;;
    esac
    grep -q 'stop microemu-play.service$' "${STATE}/calls" && fail "${state:-empty}: blocking stop" || true
done

date_call="podman exec lepton-microemu-play /system/bin/date +%m-%d %H:%M:%S.000"
home="podman exec lepton-microemu-play /system/bin/am start -W -a android.intent.action.MAIN -c android.intent.category.HOME"
stopwait="podman exec lepton-microemu-play /system/bin/logcat -b events -v brief -T 10-12 05:00:00.000 -s wm_on_stop_called"
force="podman exec lepton-microemu-play /system/bin/am force-stop com.uberspot.a2048"
stop="systemctl --user stop --no-block microemu-play.service"

reset_case() {
    rm -rf "${STATE}" "${MICROEMU_RUNTIME_DIR}"
    mkdir -p "${STATE}" "${MICROEMU_RUNTIME_DIR}"
    : > "${STATE}/calls"
    echo "$1" > "${STATE}/play"
}

reset_case active
echo com.uberspot.a2048 > "${MICROEMU_RUNTIME_DIR}/play-pkg"
: > "${STATE}/stopline"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
[[ "$(grep -v 'show -P' "${STATE}/calls")" == "${date_call}"$'\n'"${home}"$'\n'"${stopwait}"$'\n'"${force}"$'\n'"${stop}" ]] || fail "lc order: $(cat "${STATE}/calls")"
(( took >= 150 && took < 900 )) || fail "lc path with the stop event took ${took} ms"

reset_case active
echo com.uberspot.a2048 > "${MICROEMU_RUNTIME_DIR}/play-pkg"
: > "${STATE}/otherstop"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
(( took >= 900 && took < 1800 )) || fail "lc path with only another package's stop took ${took} ms, expected the 1 s bound"

reset_case active
echo com.uberspot.a2048 > "${MICROEMU_RUNTIME_DIR}/play-pkg"
: > "${STATE}/otherstop"
: > "${STATE}/stopline"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
(( took >= 150 && took < 900 )) || fail "lc path with another stop first took ${took} ms, expected the game's stop at 0.2 s"

reset_case active
echo com.uberspot.a2048 > "${MICROEMU_RUNTIME_DIR}/play-pkg"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
(( took >= 900 && took < 1800 )) || fail "lc path without the stop event took ${took} ms, expected the 1 s bound"
grep -qxF "${force}" "${STATE}/calls" || fail "no stop event: force-stop skipped"
[[ -e "${MICROEMU_RUNTIME_DIR}/play-stop-requested" ]] || fail "lc path: no marker"

reset_case active
"${hook}"
grep -qxF "${home}" "${STATE}/calls" || fail "no pkg file: home not sent"
grep -q "logcat" "${STATE}/calls" && fail "no pkg file: waited for a stop without a package"
grep -q "force-stop" "${STATE}/calls" && fail "no pkg file: force-stop without a package"
grep -qxF "${stop}" "${STATE}/calls" || fail "no pkg file: unit not stopped"

reset_case active
echo 'bad pkg;rm' > "${MICROEMU_RUNTIME_DIR}/play-pkg"
"${hook}"
grep -q "force-stop" "${STATE}/calls" && fail "bad pkg file: force-stop ran"

reset_case activating
echo com.uberspot.a2048 > "${MICROEMU_RUNTIME_DIR}/play-pkg"
"${hook}"
grep -q '^podman' "${STATE}/calls" && fail "activating: guest commands during the boot"
grep -qxF "${stop}" "${STATE}/calls" || fail "activating: unit not stopped"

reset_case active
echo com.uberspot.a2048 > "${MICROEMU_RUNTIME_DIR}/play-pkg"
: > "${STATE}/podman_hang"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
(( took < 4800 )) || fail "hung guest: took ${took} ms, beyond the hook budget"
grep -qxF "${stop}" "${STATE}/calls" || fail "hung guest: unit not stopped"

reset_case active
echo com.example.unitygame > "${MICROEMU_RUNTIME_DIR}/play-pkg"
echo com.unity3d.player.UnityPlayerActivity > "${MICROEMU_RUNTIME_DIR}/play-activity"
: > "${STATE}/otherstop"
: > "${STATE}/unitystop"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
(( took >= 150 && took < 900 )) || fail "unity activity: took ${took} ms, expected its stop at 0.2 s"
grep -qxF "podman exec lepton-microemu-play /system/bin/am force-stop com.example.unitygame" "${STATE}/calls" || fail "unity activity: no force-stop"

reset_case active
echo com.android > "${MICROEMU_RUNTIME_DIR}/play-pkg"
echo com.android.Game > "${MICROEMU_RUNTIME_DIR}/play-activity"
: > "${STATE}/otherstop"
start=$(date +%s%3N)
"${hook}"
took=$(( $(date +%s%3N) - start ))
(( took >= 900 && took < 1800 )) || fail "com.android with only launcher3's stop: took ${took} ms, expected the full 1 s"

if (( failures )); then
    echo "android-hook-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "android-hook-test: ok"
