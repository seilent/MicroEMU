#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
daemon="${repo}/sysext/usr/libexec/microemu/microemu-hotkeyd"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"

cat > "${T}/bin/evtest" <<'EOF'
#!/usr/bin/bash
node=$(basename "$1")
script="${STATE}/script-${node}"
[[ -f "${script}" ]] || exec sleep 5
t0=$(date +%s%6N)
emit() {
    printf 'Event: time %d.%06d, type 1 (EV_KEY), code %d (%s), value %d\n' $(( $1 / 1000000 )) $(( $1 % 1000000 )) "$2" "$3" "$4"
}
now_u() { date +%s%6N; }
code() {
    case "$1" in
        f14) echo "184 KEY_F14" ;;
        up) echo "115 KEY_VOLUMEUP" ;;
        down) echo "114 KEY_VOLUMEDOWN" ;;
    esac
}
while read -r step; do
    case "${step}" in
        press@*) emit $(( t0 + ${step#press@} * 1000 )) 184 KEY_F14 1 ;;
        release@*) emit $(( t0 + ${step#release@} * 1000 )) 184 KEY_F14 0 ;;
        press) emit "$(now_u)" 184 KEY_F14 1 ;;
        release) emit "$(now_u)" 184 KEY_F14 0 ;;
        repeat) emit "$(now_u)" 184 KEY_F14 2 ;;
        up|down) read -r c n <<<"$(code "${step}")"; emit "$(now_u)" "${c}" "${n}" 1 ;;
        up-release|down-release) read -r c n <<<"$(code "${step%-release}")"; emit "$(now_u)" "${c}" "${n}" 0 ;;
        lock) : > "${STATE}/lock-held" ;;
        unlock) rm -f "${STATE}/lock-held" ;;
        session*) echo "${step#session }" > "${STATE}/session" ;;
        end) exit 0 ;;
        sleep*) sleep "${step#sleep }" ;;
    esac
done < "${script}"
sleep 0.3
EOF

cat > "${T}/bin/systemctl" <<'EOF'
#!/usr/bin/bash
case "$*" in
    "--user is-active --quiet gamescope-session-plus@microemu.service") [[ "$(cat "${STATE}/session")" == microemu ]] ;;
    "--user is-active --quiet gamescope-session-plus@steam.service") [[ "$(cat "${STATE}/session")" == game ]] ;;
    "--user is-active --quiet gamescope-session-plus@microdap.service") [[ "$(cat "${STATE}/session")" == microdap ]] ;;
    "--user is-active --quiet microemu-game.scope") [[ -e "${STATE}/game" ]] ;;
    "--user show -P ActiveState microemu-play.service") cat "${STATE}/play" 2>/dev/null || echo inactive ;;
    *) echo "systemctl $*" >> "${STATE}/calls" ;;
esac
EOF

cat > "${T}/bin/flock" <<'EOF'
#!/usr/bin/bash
echo "flock $*" >> "${STATE}/flock"
[[ "$*" == "-n -E 75 ${MICROEMU_SWITCH_LOCK} true" ]] || exit 99
[[ ! -e "${STATE}/flock-error" ]] || exit 1
[[ ! -e "${STATE}/lock-held" ]] || exit 75
EOF

cat > "${T}/bin/pgrep" <<'EOF'
#!/usr/bin/bash
case "$*" in
    *SteamLaunch*) [[ "$(cat "${STATE}/title")" == 1 ]] ;;
    *plasmashell*) [[ "$(cat "${STATE}/plasma")" == 1 ]] ;;
    *) exit 1 ;;
esac
EOF

cat > "${T}/bin/busctl" <<'EOF'
#!/usr/bin/bash
echo "busctl $*" >> "${STATE}/system"
case "$*" in
    *" tree "*) printf '%s\n' /org/shadowblip/InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0 ;;
esac
EOF

cat > "${T}/bin/wpctl" <<'EOF'
#!/usr/bin/bash
[[ -e "${STATE}/wpctl-running" ]] && echo overlap >> "${STATE}/wpctl-overlap"
: > "${STATE}/wpctl-running"
echo "wpctl $*" >> "${STATE}/calls"
sleep "$(cat "${STATE}/wpctl-sleep")"
rm -f "${STATE}/wpctl-running"
EOF

cat > "${T}/bin/microemu-leave" <<'EOF'
#!/usr/bin/bash
echo "microemu-leave $*" >> "${STATE}/calls"
EOF

cat > "${T}/bin/microemu-game-stop" <<'EOF'
#!/usr/bin/bash
echo "microemu-game-stop start" >> "${STATE}/calls"
sleep "$(cat "${STATE}/stop-sleep")"
rm -f "${STATE}/game"
echo "microemu-game-stop end" >> "${STATE}/calls"
EOF

cat > "${T}/bin/logger" <<'EOF'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
EOF

chmod 0755 "${T}"/bin/*
export PATH="${T}/bin:${PATH}"
export MICROEMU_HOTKEYD_LONG_MS=200
export MICROEMU_HOTKEYD_CONFIRM_MS=1000
export MICROEMU_HOTKEYD_DEVICE_WAIT_SEC=0
export MICROEMU_HOTKEYD_DEVICE_NAME=microemu-test-node
export MICROEMU_DEV_INPUT="${T}/nodev" MICROEMU_SYS_INPUT="${T}/nosys"
export MICROEMU_SWITCH_LOCK="${T}/session-switch.lock"
export MICROEMU_LEAVE="${T}/bin/microemu-leave"
export MICROEMU_GAME_STOP="${T}/bin/microemu-game-stop"
: > "${MICROEMU_SWITCH_LOCK}"

failures=0
case_name=
fail() {
    echo "FAIL ${case_name}: $*" >&2
    echo "--- log" >&2; cat "${STATE}/log" >&2
    echo "--- calls" >&2; cat "${STATE}/calls" >&2
    failures=$((failures + 1))
}

run_case() {
    case_name=$1
    rm -rf "${STATE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    : > "${STATE}/system"
    echo "$2" > "${STATE}/session"
    echo "${TITLE:-0}" > "${STATE}/title"
    echo "${PLASMA:-0}" > "${STATE}/plasma"
    echo "${WPCTL_SLEEP:-0}" > "${STATE}/wpctl-sleep"
    echo "${STOP_SLEEP:-0}" > "${STATE}/stop-sleep"
    [[ -z "${GAME:-}" ]] || : > "${STATE}/game"
    [[ -z "${PLAY:-}" ]] || echo "${PLAY}" > "${STATE}/play"
    [[ -z "${LOCKED:-}" ]] || : > "${STATE}/lock-held"
    [[ -z "${FLOCK_ERROR:-}" ]] || : > "${STATE}/flock-error"
    [[ -z "$3" ]] || printf '%s\n' "$3" | tr ';' '\n' > "${STATE}/script-event0"
    [[ -z "${4:-}" ]] || printf '%s\n' "$4" | tr ';' '\n' > "${STATE}/script-event1"
    [[ -z "${5:-}" ]] || printf '%s\n' "$5" | tr ';' '\n' > "${STATE}/script-event2"
    rc=0
    MICROEMU_HOTKEYD_DRY_RUN="${DRY:-0}" "${daemon}" 2> "${STATE}/stderr" || rc=$?
}

expect_call() { grep -qxF -- "$1" "${STATE}/calls" || fail "missing call: $1"; }
expect_calls() { [[ "$(grep -c . "${STATE}/calls" || true)" == "$1" ]] || fail "$(grep -c . "${STATE}/calls" || true) calls, expected $1"; }
expect_call_count() { [[ "$(grep -cxF -- "$1" "${STATE}/calls" || true)" == "$2" ]] || fail "$(grep -cxF -- "$1" "${STATE}/calls" || true) of '$1', expected $2"; }
expect_log() { grep -qF -- "$1" "${STATE}/log" || fail "missing log: $1"; }
expect_no_log() { grep -qF -- "$1" "${STATE}/log" && fail "unexpected log: $1" || true; }
expect_buzz() { grep -qF "Rumble d 1.0" "${STATE}/system" || fail "no buzz"; }
expect_no_buzz() { grep -qF Rumble "${STATE}/system" && fail "unexpected buzz" || true; }
expect_no_blocking_start() {
    grep -E '^systemctl (start|restart) ' "${STATE}/calls" && fail "a unit start without --no-block" || true
}

to_microemu="systemctl --no-block start armada-session-switch@microemu.service"
leave="microemu-leave session"

run_case "no device" game "press"
[[ "${rc}" == 0 ]] || fail "exit ${rc} without a device"
expect_log "microemu-test-node not found after 0 s"
expect_calls 0

mkdir -p "${T}/dev" "${T}/sys/event0/device" "${T}/sys/event1/device" "${T}/sys/event2/device"
: > "${T}/dev/event0"
: > "${T}/dev/event1"
: > "${T}/dev/event2"
echo microemu-test-node > "${T}/sys/event0/device/name"
echo gpio-keys > "${T}/sys/event1/device/name"
echo pm8941_resin > "${T}/sys/event2/device/name"
export MICROEMU_DEV_INPUT="${T}/dev" MICROEMU_SYS_INPUT="${T}/sys"

run_case "hold in game" game "press;sleep 0.4;release"
expect_call "${to_microemu}"
expect_calls 1
expect_buzz
expect_log "hold in game"
expect_no_blocking_start
expect_log "watching ${T}/dev/event0 for KEY_F14, hold 200 ms, volume ${T}/dev/event1 ${T}/dev/event2"

run_case "hold buzzes before release" game "press;sleep 0.5;session other;release"
expect_call "${to_microemu}"

run_case "tap in game" game "press;sleep 0.05;release"
expect_calls 0
expect_no_buzz

run_case "repeat events do not count" game "press;sleep 0.05;repeat;repeat;release"
expect_calls 0

run_case "release without press" game "release;sleep 0.3;release"
expect_calls 0
expect_no_buzz

run_case "late read hold by event time" game "sleep 0.3;press@0;release@300"
expect_call "${to_microemu}"
expect_calls 1

run_case "late read tap by event time" game "sleep 0.3;press@0;release@100"
expect_calls 0

TITLE=1 run_case "hold in game with title, single" game "press;sleep 0.4;release"
expect_calls 0
expect_no_buzz
expect_log "hold ignored, title running"

TITLE=1 run_case "hold in game with title, confirmed" game "press;sleep 0.4;release;sleep 0.2;press;sleep 0.4;release"
expect_call "${to_microemu}"
expect_calls 1

TITLE=1 run_case "hold in game with title, too late" game "press;sleep 0.4;release;sleep 1.2;press;sleep 0.4;release"
expect_calls 0

run_case "hold in microemu" microemu "press;sleep 0.4;release"
expect_call "${leave}"
expect_calls 1
expect_buzz

GAME=1 STOP_SLEEP=0.6 run_case "hold in microemu with a game" microemu "press;sleep 0.4;release;sleep 0.1;press;sleep 0.4;release;sleep 0.6;press@500;release@900;sleep 0.2"
expect_call "microemu-game-stop start"
expect_call "microemu-game-stop end"
expect_call_count "microemu-game-stop start" 1
expect_call_count "${leave}" 0
expect_buzz
expect_log "game stop running, press dropped"
expect_log "press during a game stop, dropped"
expect_log "game stop done"

GAME=1 STOP_SLEEP=0.6 run_case "game stop runs in the background" microemu "press;sleep 0.3;release;sleep 0.7" "sleep 0.35;up;up-release"
[[ "$(head -n 1 "${STATE}/calls")" == "microemu-game-stop start" ]] || fail "game stop not first"
[[ "$(sed -n 2p "${STATE}/calls")" == "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" ]] || fail "volume blocked by the game stop"
[[ "$(sed -n 3p "${STATE}/calls")" == "microemu-game-stop end" ]] || fail "game stop end not last"

GAME=1 STOP_SLEEP=0.3 run_case "hold after a game stop leaves" microemu "press;sleep 0.3;release;sleep 0.6;press;sleep 0.4;release"
expect_call_count "microemu-game-stop start" 1
expect_call "${leave}"

PLAY=active STOP_SLEEP=0.2 run_case "hold in microemu with android running" microemu "press;sleep 0.4;release;sleep 0.4"
expect_call "microemu-game-stop start"
expect_call_count "${leave}" 0

PLAY=activating STOP_SLEEP=0.2 run_case "hold in microemu during the android boot" microemu "press;sleep 0.4;release;sleep 0.4"
expect_call "microemu-game-stop start"
expect_call_count "${leave}" 0

PLAY=deactivating STOP_SLEEP=0.2 run_case "hold in microemu while android stops" microemu "press;sleep 0.4;release;sleep 0.4"
expect_call "microemu-game-stop start"
expect_call_count "${leave}" 0

PLAY=failed run_case "hold in microemu with android failed" microemu "press;sleep 0.4;release"
expect_call "${leave}"

run_case "hold in microdap" microdap "press;sleep 0.4;release"
expect_calls 0
expect_no_buzz
expect_log "hold in microdap, ignored"

PLASMA=1 run_case "hold in plasma" other "press;sleep 0.4;release"
expect_call "${to_microemu}"
expect_calls 1

run_case "hold in an unknown session" other "press;sleep 0.4;release"
expect_calls 0
expect_log "hold in an unknown session, ignored"

LOCKED=1 run_case "press while the lock is held" game "press;sleep 0.4;release"
expect_calls 0
expect_no_buzz
expect_log "press during a switch, dropped"

run_case "lock taken during the hold" game "press;sleep 0.05;lock;sleep 0.4;release"
expect_calls 0
expect_no_buzz
expect_log "switch in progress, hold dropped"

run_case "press timed before the switch end" game "press;sleep 0.05;lock;sleep 0.4;release;unlock;sleep 0.1;press@100;release@400;sleep 0.1;press;sleep 0.4;release"
expect_log "press during a switch, dropped"
expect_call_count "${to_microemu}" 1

FLOCK_ERROR=1 run_case "flock error" game "press;sleep 0.4;release"
expect_call "${to_microemu}"
expect_log "flock on ${MICROEMU_SWITCH_LOCK} failed (rc=1), lock taken as free"

lock="${MICROEMU_SWITCH_LOCK}"
export MICROEMU_SWITCH_LOCK="${T}/absent.lock"
LOCKED=1 run_case "missing lock file" game "press;sleep 0.4;release"
expect_call "${to_microemu}"
[[ ! -e "${STATE}/flock" ]] || fail "flock called without a lock file"
export MICROEMU_SWITCH_LOCK="${lock}"

DRY=1 run_case "dry run" game "press;sleep 0.4;release"
expect_calls 0
expect_log "would: ${to_microemu}"
expect_log "would: buzz 15"
expect_no_buzz

run_case "volume up in microemu" microemu "sleep 0.4" "up;sleep 0.05;up-release"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
expect_calls 1

run_case "volume down in microemu" microemu "sleep 0.4" "" "down;sleep 0.05;down-release"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-"
expect_calls 1

WPCTL_SLEEP=0.5 run_case "volume burst coalesced" microemu "sleep 1.4" "up;up-release;up;up-release;up;up-release;up;up-release"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 15%+"
expect_calls 2
[[ ! -e "${STATE}/wpctl-overlap" ]] || fail "two wpctl calls at once"

WPCTL_SLEEP=1.0 run_case "volume held repeat coalesced" microemu "sleep 2.0" "up;sleep 0.75;up-release"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
expect_calls 2
second=$(sed -n '2s/.*@DEFAULT_AUDIO_SINK@ \([0-9]*\)%+$/\1/p' "${STATE}/calls")
[[ "${second}" =~ ^(15|20|25)$ ]] || fail "repeat sum ${second}, expected 15 to 25"
[[ ! -e "${STATE}/wpctl-overlap" ]] || fail "two wpctl calls at once"

WPCTL_SLEEP=0.4 run_case "volume up and down net" microemu "sleep 1.2" "up;up-release" "sleep 0.15;down;down-release;down;down-release"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 10%-"
expect_calls 2

run_case "volume outside microemu" game "sleep 0.4" "up;sleep 0.6;up-release" "down;down-release"
expect_calls 0

run_case "volume stream end stops the repeat" microemu "sleep 1.2" "up;sleep 0.1;end"
expect_call "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
expect_calls 1
expect_log "volume stream ended"

DRY=1 run_case "volume dry run" microemu "sleep 0.4" "up;up-release"
expect_calls 0
expect_log "would: wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"

rm -f "${T}/dev/event2"
run_case "volume device missing" microemu "press;sleep 0.4;release"
expect_call "${leave}"
expect_log "volume device pm8941_resin not found"
: > "${T}/dev/event2"

run_case "key stream end exits" game "end"
[[ "${rc}" == 1 ]] || fail "exit ${rc} at the end of the key stream, expected 1"
expect_log "event stream ended"

[[ "$(grep -c 'DEVICE_WAIT_SEC:-15' "${daemon}")" == 1 ]] || fail "device wait default is not 15 s"
[[ "$(grep -c 'KEY:-KEY_F14' "${daemon}")" == 1 ]] || fail "key default is not KEY_F14"

if (( failures )); then
    echo "hotkeyd-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "hotkeyd-test: ok"
