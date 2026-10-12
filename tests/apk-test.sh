#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
apk="${repo}/sysext/usr/libexec/microemu/microemu-apk"
watch="${repo}/sysext/usr/libexec/microemu/microemu-apk-watch"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/roms"
export STATE="${T}/state"
export HOME="${T}"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
marker="${MICROEMU_RUNTIME_DIR}/play-stop-requested"
export MICROEMU_LEPTON="${T}/bin/lepton"
export MICROEMU_SIDELOAD="${T}/bin/sideload"
export MICROEMU_APK_WATCH="${T}/bin/watch"
export MICROEMU_PAD_NODES="${T}/bin/pad-nodes"
export MICROEMU_PAD_FUZZ="${T}/bin/pad-fuzz"
export MICROEMU_GAPPS="${T}/gapps"
export MICROEMU_PLAY_UPDATE="${T}/bin/update"
rom="${T}/roms/2048 (F-Droid).apk"
: > "${rom}"

cat > "${T}/bin/lepton" <<'STUB'
#!/usr/bin/bash
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user is-active --quiet gamescope-session-plus@microemu.service") [[ "$(cat "${STATE}/session")" == active ]] ;;
    "--user start microemu-play.service")
        if [[ -e "${STATE}/cancel" ]]; then
            mkdir -p "${MICROEMU_RUNTIME_DIR}"
            : > "${MICROEMU_RUNTIME_DIR}/play-stop-requested"
        fi
        if [[ -e "${STATE}/reason" ]]; then
            mkdir -p "${MICROEMU_RUNTIME_DIR}"
            cp "${STATE}/reason" "${MICROEMU_RUNTIME_DIR}/play-start-failed"
        fi
        exit "$(cat "${STATE}/start_rc")" ;;
    "--user show -P Result microemu-play.service") cat "${STATE}/result" ;;
    "--user show -P ActiveState microemu-play.service") echo inactive ;;
    "--user show -P ActiveState microemu-play-update.service") cat "${STATE}/update_state" 2>/dev/null ;;
    "--user stop --no-block microemu-play.service")
        sleep "$(cat "${STATE}/stop_sleep" 2>/dev/null || echo 0)"
        echo "stop done" >> "${STATE}/calls" ;;
    "--user show -P SubState microemu-play.service") echo dead ;;
    *) exit 0 ;;
esac
STUB
cat > "${T}/bin/systemd-run" <<'STUB'
#!/usr/bin/bash
echo "systemd-run" >> "${STATE}/calls"
printf '%s\n' "$@" > "${STATE}/argv"
STUB
cat > "${T}/bin/update" <<'STUB'
#!/usr/bin/bash
echo "update $*" >> "${STATE}/calls"
STUB
cat > "${T}/bin/sideload" <<'STUB'
#!/usr/bin/bash
echo "sideload $1" >> "${STATE}/calls"
case "$1" in
    prepare) [[ "$(cat "${STATE}/prepare_rc")" == 0 ]] || exit 1; echo com.uberspot.a2048 ;;
    install) exit "$(cat "${STATE}/install_rc")" ;;
    installed) cat "${STATE}/installed" ;;
esac
STUB
cat > "${T}/bin/watch" <<'STUB'
#!/usr/bin/bash
echo "watch $*" >> "${STATE}/calls"
sleep "$(cat "${STATE}/watch_sleep")"
echo "watch done" >> "${STATE}/calls"
STUB
cat > "${T}/bin/pad-nodes" <<'STUB'
#!/usr/bin/bash
cat "${STATE}/nodes"
STUB
cat > "${T}/bin/pad-fuzz" <<'STUB'
#!/usr/bin/bash
echo "fuzz $*" >> "${STATE}/calls"
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/calls"
case "$*" in
    "container exists lepton-headless-microemu-play") [[ -e "${STATE}/stray" ]] ;;
    "rm -f lepton-headless-microemu-play") ;;
    *"resolve-activity --brief -c android.intent.category.LAUNCHER com.uberspot.a2048") cat "${STATE}/resolve" ;;
    *"resolve-activity --brief -c android.intent.category.LAUNCHER com.android.vending") echo com.android.vending/.AssetBrowserActivity ;;
    *"resolve-activity --brief -c android.intent.category.LAUNCHER com.example.playgame") echo com.example.playgame/.Main ;;
    *"am start -n "*) exit "$(cat "${STATE}/am_rc")" ;;
    "container inspect -f {{.State.Running}} lepton-microemu-play") cat "${STATE}/running" ;;
    *"/system/bin/date "*) [[ -e "${STATE}/dead" ]] && exit 125; echo "10-12 05:00:00.000" ;;
    *"dumpsys activity activities") cat "${STATE}/dumpsys" ;;
    *"/system/bin/logcat "*)
        [[ "$*" == *"-b events -v brief -T 10-12 05:00:00.000 -s wm_set_resumed_activity am_proc_died wm_on_stop_called" ]] || exit 99
        while IFS= read -r line; do
            case "${line}" in
                sleep*) sleep "${line#sleep }" ;;
                *) echo "${line}" ;;
            esac
        done < "${STATE}/logcat" ;;
    *"am force-stop "*) ;;
esac
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
cat > "${T}/bin/game-free" <<'STUB'
#!/usr/bin/bash
echo "game-free" >> "${STATE}/calls"
exit "$(cat "${STATE}/game_free_rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_FREE="${T}/bin/game-free"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    echo active > "${STATE}/session"
    echo 0 > "${STATE}/start_rc"
    echo success > "${STATE}/result"
    echo 0 > "${STATE}/prepare_rc"
    echo 0 > "${STATE}/install_rc"
    echo 0.2 > "${STATE}/watch_sleep"
    echo /dev/input/event10 > "${STATE}/nodes"
    printf 'priority=0 preferredOrder=0 match=0x108000\ncom.uberspot.a2048/.MainActivity\n' > "${STATE}/resolve"
    echo 0 > "${STATE}/am_rc"
    : > "${STATE}/installed"
    echo true > "${STATE}/running"
    echo "  mResumedActivity: ActivityRecord{1 u0 com.android.launcher3/.Launcher t1}" > "${STATE}/dumpsys"
    : > "${STATE}/logcat"
}

calls() { cat "${STATE}/calls"; }
count() { grep -cxF -- "$1" "${STATE}/calls" || true; }
logged() { grep -qxF -- "$1" "${STATE}/log" || fail "${case_name}: missing log line: $1, got $(cat "${STATE}/log")"; }

stop_blocking="systemctl --user stop microemu-play.service"
stop_noblock="systemctl --user stop --no-block microemu-play.service"

outer() {
    rc=0
    "${apk}" "$@" 2> "${STATE}/stderr" || rc=$?
}

body() {
    rc=0
    "${apk}" --body "${rom}" 2> "${STATE}/stderr" || rc=$?
}

case_name="outside microemu"
reset
echo inactive > "${STATE}/session"
outer "${rom}"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
grep -q systemd-run "${STATE}/calls" && fail "${case_name}: systemd-run called"
logged "gamescope-session-plus@microemu.service is not active, refusing"

case_name="lepton missing"
reset
mv "${MICROEMU_LEPTON}" "${MICROEMU_LEPTON}.off"
start=$(date +%s%3N)
outer "${rom}"
took=$(( $(date +%s%3N) - start ))
mv "${MICROEMU_LEPTON}.off" "${MICROEMU_LEPTON}"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
(( took < 2000 )) || fail "${case_name}: took ${took} ms"
logged "${MICROEMU_LEPTON} missing"
grep -q systemd-run "${STATE}/calls" && fail "${case_name}: systemd-run called"

case_name="not an apk"
reset
: > "${T}/roms/x.zip"
outer "${T}/roms/x.zip"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"

case_name="outside home"
reset
mkdir -p "${T}/elsewhere"
outside=$(mktemp -p "${T}/../" microemu-apk-test.XXXXXX.apk)
outer "${outside}"
rm -f "${outside}"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
grep -q "is outside ${HOME} and /run/media/" "${STATE}/log" || fail "${case_name}: no refusal line: $(cat "${STATE}/log")"
grep -q systemd-run "${STATE}/calls" && fail "${case_name}: systemd-run called"

case_name="link into home"
reset
ln -s "${rom}" "${T}/roms/link.apk"
outer "${T}/roms/link.apk"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
rm -f "${T}/roms/link.apk"

case_name="scope"
reset
outer "${rom}"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
expected="--user
--scope
--collect
--expand-environment=no
--unit=microemu-game
--property=BindsTo=gamescope-session-plus@microemu.service
--property=After=gamescope-session-plus@microemu.service
--property=TimeoutStopSec=5
--
${apk}
--body
${rom}"
[[ "$(cat "${STATE}/argv")" == "${expected}" ]] || fail "${case_name}: argv $(cat "${STATE}/argv")"
[[ "$(sed -n 2p "${STATE}/calls")" == "systemctl --user stop microemu-play-update.service" ]] || fail "${case_name}: update not stopped before the run: $(calls)"
[[ "$(sed -n 3p "${STATE}/calls")" == "systemctl --user reset-failed microemu-play-update.service" ]] || fail "${case_name}: interrupted update left failed: $(calls)"
[[ "$(sed -n 4p "${STATE}/calls")" == "podman container exists lepton-headless-microemu-play" ]] || fail "${case_name}: no headless container check before the run: $(calls)"
[[ "$(sed -n 5p "${STATE}/calls")" == "game-free" ]] || fail "${case_name}: scope not waited for before the run: $(calls)"
count "podman rm -f lepton-headless-microemu-play" | grep -qx 0 || fail "${case_name}: removed a headless container that was not there"

case_name="scope still stopping"
reset
echo 1 > "${STATE}/game_free_rc"
outer "${rom}"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
grep -qx systemd-run "${STATE}/calls" && fail "${case_name}: systemd-run called"
logged "microemu-game.scope is still stopping"
rm -f "${STATE}/game_free_rc"

case_name="stray headless container"
reset
: > "${STATE}/stray"
outer "${rom}"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
[[ "$(sed -n 5p "${STATE}/calls")" == "systemctl --user show -P ActiveState microemu-play-update.service" ]] || fail "${case_name}: unit state not read: $(calls)"
[[ "$(sed -n 6p "${STATE}/calls")" == "podman rm -f lepton-headless-microemu-play" ]] || fail "${case_name}: not removed before the run: $(calls)"
logged "removed a leftover lepton-headless-microemu-play"
grep -qx systemd-run "${STATE}/calls" || fail "${case_name}: game not started"
reset
: > "${STATE}/stray"
echo deactivating > "${STATE}/update_state"
outer "${rom}"
grep -qx "podman rm -f lepton-headless-microemu-play" "${STATE}/calls" && fail "${case_name}: removed while the update unit still runs"

case_name="update entry"
reset
: > "${T}/roms/Update Google Play.update"
outer "${T}/roms/Update Google Play.update"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
[[ "$(calls)" == $'systemctl --user is-active --quiet gamescope-session-plus@microemu.service\nupdate --no-block' ]] || fail "${case_name}: calls $(calls)"
reset
echo inactive > "${STATE}/session"
outer "${T}/roms/Update Google Play.update"
[[ "${rc}" == 1 ]] || fail "${case_name}: outside the session exit ${rc}"
grep -q "^update" "${STATE}/calls" && fail "${case_name}: update started outside the session"
rm -f "${T}/roms/Update Google Play.update"

case_name="normal game"
reset
body
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
expected="sideload prepare
systemctl --user is-active --quiet gamescope-session-plus@microemu.service
systemctl --user start microemu-play.service
fuzz /dev/input/event10
sideload install
podman exec lepton-microemu-play /system/bin/cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.uberspot.a2048
podman exec lepton-microemu-play /system/bin/date +%m-%d %H:%M:%S.000
podman exec lepton-microemu-play /system/bin/am start -n com.uberspot.a2048/.MainActivity
${stop_blocking}"
[[ "$(grep -v '^watch' "${STATE}/calls")" == "${expected}" ]] || fail "${case_name}: calls $(calls)"
[[ "$(grep -n '^watch done' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -nxF "${stop_blocking}" "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "${case_name}: unit stopped before the watcher ended"
[[ "$(grep -n '/system/bin/date ' "${STATE}/calls" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'am start -n' "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "${case_name}: the watcher's start time was not taken before am start"
grep -qxF "watch com.uberspot.a2048 com.uberspot.a2048.MainActivity 10-12 05:00:00.000" "${STATE}/calls" || fail "${case_name}: watcher arguments: $(calls)"

case_name="session gone before the start"
reset
echo inactive > "${STATE}/session"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "gamescope-session-plus@microemu.service is not active, refusing"
grep -qxF "systemctl --user start microemu-play.service" "${STATE}/calls" && fail "${case_name}: unit started"
[[ "$(tail -n 1 "${STATE}/calls")" == "${stop_blocking}" ]] || fail "${case_name}: trap did not stop the unit"

case_name="start canceled"
reset
echo 1 > "${STATE}/start_rc"
: > "${STATE}/cancel"
mkdir -p "${MICROEMU_RUNTIME_DIR}"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "android start canceled"
[[ "$(tail -n 1 "${STATE}/calls")" == "${stop_blocking}" ]] || fail "${case_name}: unit not stopped: $(calls)"

case_name="start refused with a reason"
reset
echo 1 > "${STATE}/start_rc"
echo exit-code > "${STATE}/result"
echo "Steam's Lepton is not installed" > "${STATE}/reason"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "android failed to start: Steam's Lepton is not installed"
grep -qxF "systemctl --user reset-failed microemu-play.service" "${STATE}/calls" || fail "${case_name}: unit not reset: $(calls)"

case_name="start refused"
reset
echo 1 > "${STATE}/start_rc"
mkdir -p "${MICROEMU_RUNTIME_DIR}"
: > "${marker}"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "android failed to start (start job failed: inactive/dead)"
grep -q "android start canceled" "${STATE}/log" && fail "${case_name}: stale marker read as a cancel"

case_name="start failed"
reset
echo 1 > "${STATE}/start_rc"
echo timeout > "${STATE}/result"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "android failed to start (timeout), see ~/.local/share/microemu/android/boot.log and journalctl --user -u microemu-play.service"
grep -qxF "systemctl --user reset-failed microemu-play.service" "${STATE}/calls" || fail "${case_name}: unit not reset"
[[ "$(tail -n 1 "${STATE}/calls")" == "${stop_blocking}" ]] || fail "${case_name}: unit not stopped"

case_name="no pad"
reset
: > "${STATE}/nodes"
body
logged "no InputPlumber xb360 pad node, starting without a pad"
grep -q '^fuzz' "${STATE}/calls" && fail "${case_name}: fuzz called"

for failing in prepare install; do
    case_name="${failing} fails"
    reset
    echo 1 > "${STATE}/${failing}_rc"
    body
    [[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
    [[ "$(tail -n 1 "${STATE}/calls")" == "${stop_blocking}" ]] || fail "${case_name}: unit not stopped: $(calls)"
    grep -q 'am start' "${STATE}/calls" && fail "${case_name}: game started"
done

case_name="no launcher component"
reset
printf 'No activity found\n' > "${STATE}/resolve"
echo 5 > "${STATE}/watch_sleep"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "com.uberspot.a2048 has no launcher activity"
[[ "$(tail -n 1 "${STATE}/calls")" == "${stop_blocking}" ]] || fail "${case_name}: unit not stopped: $(calls)"
grep -q "watch done" "${STATE}/calls" && fail "${case_name}: watcher left running to its end"

case_name="am start fails"
reset
echo 1 > "${STATE}/am_rc"
body
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "am start -n com.uberspot.a2048/.MainActivity failed"

case_name="signal"
reset
echo 5 > "${STATE}/watch_sleep"
"${apk}" --body "${rom}" 2>/dev/null &
pid=$!
for _ in $(seq 1 50); do grep -q 'am start' "${STATE}/calls" && break; sleep 0.05; done
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
[[ "${rc}" == 143 ]] || fail "${case_name}: exit ${rc}"
grep -qxF "${stop_noblock}" "${STATE}/calls" || fail "${case_name}: no --no-block stop: $(calls)"
[[ "$(count "${stop_blocking}")" == 0 ]] || fail "${case_name}: blocking stop on a signal"
[[ -e "${marker}" ]] || fail "${case_name}: no stop marker before the stop"

play_entry="${T}/roms/Play Game.play"
printf 'com.example.playgame\n' > "${play_entry}"

case_name="play layer off"
reset
rm -rf "${MICROEMU_GAPPS}"
body_play() { rc=0; "${apk}" --body "$1" 2> "${STATE}/stderr" || rc=$?; }
body_play "${play_entry}"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "the Google Play layer is off, run microemu-gapps-install"
grep -qxF "systemctl --user start microemu-play.service" "${STATE}/calls" && fail "${case_name}: unit started"

mkdir -p "${MICROEMU_GAPPS}/set"
ln -s set "${MICROEMU_GAPPS}/current"

case_name="play installed"
reset
echo "12 com.android.vending" > "${STATE}/installed"
body_play "${play_entry}"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx -e 'sideload prepare' -e 'sideload install' "${STATE}/calls" && fail "${case_name}: sideload ran for a .play"
grep -qxF "watch com.example.playgame com.example.playgame.Main 10-12 05:00:00.000" "${STATE}/calls" || fail "${case_name}: watcher not on the package and its activity: $(calls)"
[[ "$(cat "${MICROEMU_RUNTIME_DIR}/play-activity")" == com.example.playgame.Main ]] || fail "${case_name}: play-activity not expanded"
grep -qxF "podman exec lepton-microemu-play /system/bin/am start -n com.example.playgame/.Main" "${STATE}/calls" || fail "${case_name}: not started: $(calls)"

case_name="play not installed"
reset
body_play "${play_entry}"
[[ "${rc}" == 0 ]] || fail "${case_name}: exit ${rc}"
logged "com.example.playgame not installed, opening Google Play"
grep -qxF "watch com.android.vending com.android.vending.AssetBrowserActivity 10-12 05:00:00.000" "${STATE}/calls" || fail "${case_name}: watcher not on Play: $(calls)"
[[ "$(cat "${MICROEMU_RUNTIME_DIR}/play-activity")" == com.android.vending.AssetBrowserActivity ]] || fail "${case_name}: play-activity not Play's"
[[ "$(cat "${MICROEMU_RUNTIME_DIR}/play-pkg")" == com.android.vending ]] || fail "${case_name}: play-pkg is not the launched package"
grep -qxF "podman exec lepton-microemu-play /system/bin/am start -n com.android.vending/.AssetBrowserActivity" "${STATE}/calls" || fail "${case_name}: Play not opened: $(calls)"

case_name="play bad entry"
reset
printf 'not a package; rm -rf\n' > "${T}/roms/bad.play"
body_play "${T}/roms/bad.play"
[[ "${rc}" == 1 ]] || fail "${case_name}: exit ${rc}"
logged "${T}/roms/bad.play does not hold a package name"
rm -rf "${MICROEMU_GAPPS}"

case_name="term storm"
reset
echo 5 > "${STATE}/watch_sleep"
echo 0.6 > "${STATE}/stop_sleep"
rm -f "${marker}"
"${apk}" --body "${rom}" 2>/dev/null &
pid=$!
for _ in $(seq 1 50); do grep -q 'am start' "${STATE}/calls" && break; sleep 0.05; done
for _ in $(seq 1 30); do
    kill -TERM "${pid}" 2>/dev/null || true
    pkill -TERM -P "${pid}" 2>/dev/null || true
    sleep 0.03
done
rc=0
wait "${pid}" || rc=$?
grep -qxF "${stop_noblock}" "${STATE}/calls" || fail "${case_name}: no --no-block stop: $(calls)"
grep -qx "stop done" "${STATE}/calls" || fail "${case_name}: the stop was killed by the storm: $(calls)"
[[ -e "${marker}" ]] || fail "${case_name}: marker not written"

watch_run() {
    rc=0
    "${watch}" "${1:-com.uberspot.a2048}" "${2:-}" 2> "${STATE}/stderr" || rc=$?
}

resume_pkg="I/wm_set_resumed_activity(  221): [0,com.uberspot.a2048/.MainActivity,minimalResumeActivityLocked]"
resume_launcher="I/wm_set_resumed_activity(  221): [0,com.android.launcher3/.uioverrides.QuickstepLauncher,resumeTopActivityInnerLocked]"
died="I/am_proc_died(  221): [0,1297,com.uberspot.a2048,900,19]"
force="podman exec lepton-microemu-play /system/bin/am force-stop com.uberspot.a2048"

stopped="I/wm_on_stop_called( 1301): [0,com.uberspot.a2048.MainActivity,STOP_ACTIVITY_ITEM]"

case_name="watch launcher"
reset
printf '%s\n' "${resume_launcher}" "${resume_pkg}" "sleep 0.1" "${resume_launcher}" "sleep 0.3" "${stopped}" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run
took=$(( $(date +%s%3N) - start ))
logged "com.uberspot.a2048 launcher, ending the game"
[[ "$(count "${force}")" == 1 ]] || fail "${case_name}: no force-stop"
(( took >= 350 && took < 900 )) || fail "${case_name}: took ${took} ms, expected the stop event about 0.4 s in"

case_name="watch launcher without a stop event"
reset
printf '%s\n' "${resume_pkg}" "${resume_launcher}" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run
took=$(( $(date +%s%3N) - start ))
logged "com.uberspot.a2048 launcher, ending the game"
[[ "$(count "${force}")" == 1 ]] || fail "${case_name}: no force-stop"
(( took >= 900 && took < 1800 )) || fail "${case_name}: took ${took} ms, expected the 1 s bound"

case_name="watch another package's stop"
reset
other_stop="I/wm_on_stop_called( 1100): [0,com.uberspot.a2048x.MainActivity,STOP_ACTIVITY_ITEM]"
printf '%s\n' "${resume_pkg}" "${resume_launcher}" "${other_stop}" "sleep 0.4" "${stopped}" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run
took=$(( $(date +%s%3N) - start ))
(( took >= 350 && took < 900 )) || fail "${case_name}: took ${took} ms, expected the game's stop at about 0.4 s"

case_name="watch launcher3 stop before the game's"
reset
launcher_stop="I/wm_on_stop_called(  640): [0,com.android.launcher3.uioverrides.QuickstepLauncher,STOP_ACTIVITY_ITEM]"
printf '%s\n' "${resume_pkg}" "sleep 0.1" "${launcher_stop}" "sleep 0.1" "${resume_launcher}" "sleep 0.4" "${stopped}" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run
took=$(( $(date +%s%3N) - start ))
logged "com.uberspot.a2048 launcher, ending the game"
(( took >= 550 && took < 1100 )) || fail "${case_name}: took ${took} ms, expected the game's stop about 0.6 s in"

case_name="watch unity activity outside the package"
reset
printf '%s\n' "I/wm_set_resumed_activity(  221): [0,com.example.unitygame/com.unity3d.player.UnityPlayerActivity,minimalResumeActivityLocked]" \
    "${resume_launcher}" "sleep 0.3" "I/wm_on_stop_called( 1301): [0,com.unity3d.player.UnityPlayerActivity,STOP_ACTIVITY_ITEM]" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run com.example.unitygame com.unity3d.player.UnityPlayerActivity
took=$(( $(date +%s%3N) - start ))
logged "com.example.unitygame launcher, ending the game"
(( took >= 250 && took < 800 )) || fail "${case_name}: took ${took} ms, expected the stop at about 0.3 s"

case_name="watch com.android package with only launcher3's stop"
reset
printf '%s\n' "I/wm_set_resumed_activity(  221): [0,com.android/com.android.Game,minimalResumeActivityLocked]" \
    "${resume_launcher}" "I/wm_on_stop_called(  640): [0,com.android.launcher3.uioverrides.QuickstepLauncher,STOP_ACTIVITY_ITEM]" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run com.android com.android.Game
took=$(( $(date +%s%3N) - start ))
(( took >= 900 && took < 1800 )) || fail "${case_name}: took ${took} ms, expected the full 1 s wait"

for activity in com.foo.Main ""; do
    case_name="watch com.foo against com.foobar (activity '${activity}')"
    reset
    printf '%s\n' "I/wm_set_resumed_activity(  221): [0,com.foo/com.foo.Main,minimalResumeActivityLocked]" \
        "${resume_launcher}" "I/wm_on_stop_called( 1400): [0,com.foobar.Main,STOP_ACTIVITY_ITEM]" "sleep 5" > "${STATE}/logcat"
    start=$(date +%s%3N)
    watch_run com.foo "${activity}"
    took=$(( $(date +%s%3N) - start ))
    (( took >= 900 && took < 1800 )) || fail "${case_name}: took ${took} ms, expected the full 1 s wait"
done

case_name="watch stop before the launcher"
reset
printf '%s\n' "${resume_pkg}" "${stopped}" "${resume_launcher}" "sleep 5" > "${STATE}/logcat"
start=$(date +%s%3N)
watch_run
took=$(( $(date +%s%3N) - start ))
logged "com.uberspot.a2048 launcher, ending the game"
(( took < 600 )) || fail "${case_name}: took ${took} ms"

case_name="watch launcher before the game"
reset
printf '%s\n' "${resume_launcher}" > "${STATE}/logcat"
watch_run
logged "com.uberspot.a2048 eof, ending the game"

case_name="watch died"
reset
printf '%s\n' "${resume_pkg}" "${died}" "sleep 5" > "${STATE}/logcat"
watch_run
logged "com.uberspot.a2048 died, ending the game"
[[ "$(count "${force}")" == 1 ]] || fail "${case_name}: no force-stop"

case_name="watch died before the resume"
reset
printf '%s\n' "${died}" "sleep 5" > "${STATE}/logcat"
watch_run
logged "com.uberspot.a2048 died, ending the game"

case_name="watch eof"
reset
printf '%s\n' "${resume_pkg}" > "${STATE}/logcat"
watch_run
logged "com.uberspot.a2048 eof, ending the game"

case_name="watch eof with the container gone"
reset
echo false > "${STATE}/running"
watch_run
logged "com.uberspot.a2048 eof, ending the game"
[[ "$(count "${force}")" == 0 ]] || fail "${case_name}: force-stop on a dead container"

case_name="watch already resumed"
reset
echo "  mResumedActivity: ActivityRecord{2 u0 com.uberspot.a2048/.MainActivity t5}" > "${STATE}/dumpsys"
printf '%s\n' "${resume_launcher}" "sleep 5" > "${STATE}/logcat"
watch_run
logged "com.uberspot.a2048 launcher, ending the game"

case_name="watch dead container"
reset
: > "${STATE}/dead"
watch_run
logged "com.uberspot.a2048 eof, ending the game"

if (( failures )); then
    echo "apk-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "apk-test: ok"
