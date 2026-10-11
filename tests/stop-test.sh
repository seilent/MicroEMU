#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/sysext/usr/libexec/microemu"

T=$(mktemp -d)
pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do
        kill -9 "${pid}" 2>/dev/null || true
    done
    rm -rf "${T}"
}
trap cleanup EXIT
mkdir -p "${T}/bin" "${T}/hang"
export STATE="${T}/state"
export MICROEMU_GAME_STOP_HOOKS="${T}/hooks"
export MICROEMU_PROC_DIR="${T}/proc"
export MICROEMU_ESDE_BIN=/usr/lib/microemu/es-de/usr/bin/es-de

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
[[ "$*" != "--user reset-failed microemu-game.scope" || ! -e "${STATE}/no-scope" ]] || exit 1
exit 0
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
cat > "${T}/hang/microemu-game-stop" <<'STUB'
#!/usr/bin/bash
echo "microemu-game-stop hang" >> "${STATE}/calls"
exec sleep 10
STUB
cat > "${T}/esde" <<'STUB'
#!/usr/bin/bash
n=0
trap 'n=$((n + 1)); echo "$(date +%s%3N)" >> "$1"; if (( $2 > 0 && n >= $2 )); then exit 0; fi' TERM
while :; do sleep 0.05; done
STUB
chmod 0755 "${T}/bin/"* "${T}/hang/"* "${T}/esde"
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_STOP="${libexec}/microemu-game-stop"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    local pid
    for pid in "${pids[@]}"; do
        kill -9 "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    pids=()
    rm -rf "${STATE}" "${MICROEMU_GAME_STOP_HOOKS}" "${MICROEMU_PROC_DIR}"
    mkdir -p "${STATE}" "${MICROEMU_GAME_STOP_HOOKS}" "${MICROEMU_PROC_DIR}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
}

hook() {
    printf '#!/usr/bin/bash\necho "hook %s" >> "${STATE}/calls"\n%s\n' "$1" "${2:-}" > "${MICROEMU_GAME_STOP_HOOKS}/$1"
    chmod 0755 "${MICROEMU_GAME_STOP_HOOKS}/$1"
}

proc() {
    local name=$1 exits_after=$2 exe=$3 cgroup=$4 pid
    "${T}/esde" "${STATE}/term-${name}" "${exits_after}" &
    pid=$!
    pids+=("${pid}")
    mkdir -p "${MICROEMU_PROC_DIR}/${pid}"
    ln -s "${exe}" "${MICROEMU_PROC_DIR}/${pid}/exe"
    echo "0::${cgroup}" > "${MICROEMU_PROC_DIR}/${pid}/cgroup"
    : > "${STATE}/term-${name}"
    printf '%s\n' "${pid}" > "${STATE}/pid-${name}"
}

run() {
    local start
    rc=0
    start=$(date +%s%3N)
    "${libexec}/microemu-stop" 2> "${STATE}/stderr" || rc=$?
    elapsed=$(( $(date +%s%3N) - start ))
}

terms() { grep -c . "${STATE}/term-$1" || true; }

session_cg=/user.slice/user-1000.slice/user@1000.service/app.slice/gamescope-session-plus@microemu.service
other_cg=/user.slice/user-1000.slice/user@1000.service/app.slice/gamescope-session-plus@steam.service

reset
hook 20-android
hook 10-first
proc esde 1 "${MICROEMU_ESDE_BIN}" "${session_cg}"
run
[[ "${rc}" == 0 ]] || fail "order exit ${rc}: $(cat "${STATE}/stderr")"
expected="hook 10-first
hook 20-android
systemctl --user reset-failed microemu-game.scope
systemctl --user stop microemu-game.scope
systemctl --user reset-failed microemu-game.scope"
[[ "$(cat "${STATE}/calls")" == "${expected}" ]] || fail "order: $(cat "${STATE}/calls")"
[[ "$(terms esde)" == 1 ]] || fail "order: es-de got $(terms esde) TERM, expected 1"
(( elapsed < 1500 )) || fail "order: took ${elapsed} ms"

reset
proc esde 1 "${MICROEMU_ESDE_BIN}" "${session_cg}"
proc other_esde 1 "${MICROEMU_ESDE_BIN}" "${other_cg}"
proc other_bin 1 /usr/bin/bash "${session_cg}"
proc nested 1 "${MICROEMU_ESDE_BIN}" "${session_cg}/app.scope"
run
[[ "$(terms other_esde)" == 0 ]] || fail "cgroup: es-de outside the microemu session got TERM"
[[ "$(terms other_bin)" == 0 ]] || fail "cgroup: another binary in the session got TERM"
[[ "$(( $(terms esde) + $(terms nested) ))" == 1 ]] || fail "cgroup: $(terms esde) + $(terms nested) TERMs to the session es-de, expected 1"

reset
proc esde 0 "${MICROEMU_ESDE_BIN}" "${session_cg}"
run
[[ "${rc}" == 0 ]] || fail "ignoring es-de exit ${rc}"
[[ "$(terms esde)" == 6 ]] || fail "ignoring es-de got $(terms esde) TERMs, expected 6"
first=$(head -n 1 "${STATE}/term-esde")
last=$(tail -n 1 "${STATE}/term-esde")
(( last - first >= 2300 && last - first <= 3200 )) || fail "ignoring es-de: TERMs spread over $((last - first)) ms"
(( elapsed >= 2800 && elapsed < 4500 )) || fail "ignoring es-de: took ${elapsed} ms"

reset
proc esde 3 "${MICROEMU_ESDE_BIN}" "${session_cg}"
run
[[ "$(terms esde)" == 3 ]] || fail "es-de exiting on the third TERM got $(terms esde)"
(( elapsed < 2500 )) || fail "es-de exiting on the third TERM: took ${elapsed} ms"

reset
: > "${STATE}/no-scope"
run
[[ "${rc}" == 0 ]] || fail "nothing running exit ${rc}"
[[ "$(grep -c "microemu-game.scope" "${STATE}/calls")" == 3 ]] || fail "nothing running: $(cat "${STATE}/calls")"
grep -q '^hook' "${STATE}/calls" && fail "nothing running: a hook ran"
(( elapsed < 1000 )) || fail "nothing running: took ${elapsed} ms"

reset
proc gone 1 "${MICROEMU_ESDE_BIN}" "${session_cg}"
kill -9 "$(cat "${STATE}/pid-gone")"
wait "$(cat "${STATE}/pid-gone")" 2>/dev/null || true
run
[[ "${rc}" == 0 ]] || fail "es-de already gone exit ${rc}"
(( elapsed < 1000 )) || fail "es-de already gone: took ${elapsed} ms"

reset
proc esde 1 "${MICROEMU_ESDE_BIN}" "${session_cg}"
MICROEMU_GAME_STOP="${T}/hang/microemu-game-stop" MICROEMU_STOP_BOUND_S=1 run
(( elapsed >= 900 && elapsed < 2000 )) || fail "hanging game stop: took ${elapsed} ms, expected the 1 s bound"
grep -qx "microemu-game-stop hang" "${STATE}/calls" || fail "hanging game stop: stub not run"
[[ "${rc}" != 0 ]] || fail "hanging game stop: exit 0, expected the timeout status"

reset
hook 10-fails "exit 3"
hook 20-after
mkdir -p "${MICROEMU_GAME_STOP_HOOKS}/30-dir"
printf '#!/usr/bin/bash\necho "hook plain" >> "${STATE}/calls"\n' > "${MICROEMU_GAME_STOP_HOOKS}/40-plain"
"${libexec}/microemu-game-stop"
[[ "$(grep '^hook' "${STATE}/calls")" == $'hook 10-fails\nhook 20-after' ]] || fail "hooks: $(cat "${STATE}/calls")"
grep -qx "10-fails failed (rc=3)" "${STATE}/log" || fail "hooks: failing hook not logged"
[[ "$(grep -c "microemu-game.scope" "${STATE}/calls")" == 3 ]] || fail "hooks: scope not stopped after a failing hook"

reset
hook 10-hang "exec sleep 10"
start=$(date +%s%3N)
MICROEMU_GAME_STOP_HOOKS_MS=1000 "${libexec}/microemu-game-stop"
took=$(( $(date +%s%3N) - start ))
(( took >= 900 && took < 2000 )) || fail "hanging hook: took ${took} ms, expected the 1 s bound"
[[ "$(grep -c "microemu-game.scope" "${STATE}/calls")" == 3 ]] || fail "hanging hook: scope not stopped"
grep -qx "10-hang failed (rc=124)" "${STATE}/log" || fail "hanging hook: not logged"

reset
hook 10-slow "sleep 0.7"
hook 20-cut "sleep 0.7"
hook 30-skipped
start=$(date +%s%3N)
MICROEMU_GAME_STOP_HOOKS_MS=1000 "${libexec}/microemu-game-stop"
took=$(( $(date +%s%3N) - start ))
(( took >= 900 && took < 1600 )) || fail "hook budget: took ${took} ms, expected about 1 s in total"
grep -qx "20-cut failed (rc=124)" "${STATE}/log" || fail "hook budget: the second hook not cut at the total budget"
grep -qx "hook budget spent, 30-skipped skipped" "${STATE}/log" || fail "hook budget: the third hook not skipped"
grep -qx "hook 30-skipped" "${STATE}/calls" && fail "hook budget: the third hook ran"
[[ "$(grep -c "microemu-game.scope" "${STATE}/calls")" == 3 ]] || fail "hook budget: scope not stopped"

reset
hook 10-stubborn "trap '' TERM; sleep 10"
start=$(date +%s%3N)
MICROEMU_GAME_STOP_HOOKS_MS=500 "${libexec}/microemu-game-stop"
took=$(( $(date +%s%3N) - start ))
(( took >= 1400 && took < 2500 )) || fail "TERM ignoring hook: took ${took} ms, expected the bound plus the 1 s kill"

reset
rm -rf "${MICROEMU_GAME_STOP_HOOKS}"
"${libexec}/microemu-game-stop"
[[ "$(grep -c "microemu-game.scope" "${STATE}/calls")" == 3 ]] || fail "no hook directory: scope not stopped"

if (( failures )); then
    echo "stop-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "stop-test: ok"
