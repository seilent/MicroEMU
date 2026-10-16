#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
lc="${repo}/data/usr/libexec/microemu/microemu-lc"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
[[ "$*" == "--user show -P ActiveState microemu-game.scope" ]] || exit 99
cat "${STATE}/scope"
STUB
cat > "${T}/bin/microos-session" <<'STUB'
#!/usr/bin/bash
echo "microos-session $*" >> "${STATE}/calls"
exit "$(cat "${STATE}/back_rc")"
STUB
cat > "${T}/bin/game-stop" <<'STUB'
#!/usr/bin/bash
echo "game-stop" >> "${STATE}/calls"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_STOP="${T}/bin/game-stop"
export MICROEMU_GAME_RUNNING="${repo}/data/usr/libexec/microemu/microemu-game-running"
export MICROEMU_RUNTIME_DIR="${T}/run"
mkdir -p "${MICROEMU_RUNTIME_DIR}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

run() {
    rm -rf "${STATE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    echo "$1" > "${STATE}/scope"
    echo "${2:-0}" > "${STATE}/back_rc"
    rc=0
    "${lc}" || rc=$?
}

for state in active activating deactivating reloading; do
    run "${state}"
    [[ "${rc}" == 0 ]] || fail "${state}: exit ${rc}"
    [[ "$(tail -n 1 "${STATE}/calls")" == game-stop ]] || fail "${state}: game not stopped: $(cat "${STATE}/calls")"
    grep -q microos-session "${STATE}/calls" && fail "${state}: left the session with a game running"
done
for state in inactive failed ""; do
    run "${state}"
    [[ "$(tail -n 1 "${STATE}/calls")" == "microos-session back" ]] || fail "'${state}': no back: $(cat "${STATE}/calls")"
    grep -q game-stop "${STATE}/calls" && fail "'${state}': game stop ran"
done
sleep 30 &
launcher=$!
echo "${launcher}" > "${MICROEMU_RUNTIME_DIR}/launching"
run inactive
[[ "$(tail -n 1 "${STATE}/calls")" == game-stop ]] || fail "launch window: game not stopped: $(cat "${STATE}/calls")"
grep -q microos-session "${STATE}/calls" && fail "launch window: left the session"
wait "${launcher}" 2>/dev/null && fail "launch window: the launcher was not sent TERM"
kill -0 "${launcher}" 2>/dev/null && fail "launch window: the launcher still runs"
run inactive
[[ "$(tail -n 1 "${STATE}/calls")" == "microos-session back" ]] || fail "stale launch marker counted as a game"
echo junk > "${MICROEMU_RUNTIME_DIR}/launching"
run inactive
[[ "$(tail -n 1 "${STATE}/calls")" == "microos-session back" ]] || fail "a bad launch marker counted as a game"
rm -f "${MICROEMU_RUNTIME_DIR}/launching"

run inactive 1
[[ "${rc}" == 0 ]] || fail "back failing: exit ${rc}"
grep -qx "microos-session back failed" "${STATE}/log" || fail "back failing: not logged"

if (( failures )); then
    echo "lc-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "lc-test: ok"
