#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
script="${repo}/sysext/usr/libexec/microemu/microemu-game-free"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user show -P ActiveState microemu-game.scope")
        state=$(head -n 1 "${STATE}/states")
        [[ "$(grep -c . "${STATE}/states")" -gt 1 ]] && sed -i 1d "${STATE}/states"
        echo "${state}" ;;
    "--user reset-failed microemu-game.scope") exit 0 ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_FREE_POLL_S=0.05

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    printf '%s\n' "$@" > "${STATE}/states"
}

run() {
    rc=0
    start=$(date +%s%3N)
    "${script}" 2> "${STATE}/stderr" || rc=$?
    took=$(( $(date +%s%3N) - start ))
}

for state in inactive failed ""; do
    reset "${state}"
    run
    [[ "${rc}" == 0 ]] || fail "state '${state}': exit ${rc}"
    [[ "$(tail -n 1 "${STATE}/calls")" == "systemctl --user reset-failed microemu-game.scope" ]] || fail "state '${state}': no reset-failed"
done

reset active deactivating deactivating inactive
run
[[ "${rc}" == 0 ]] || fail "stopping scope: exit ${rc}"
[[ "$(grep -c 'show -P ActiveState' "${STATE}/calls")" == 4 ]] || fail "stopping scope: not polled until inactive: $(cat "${STATE}/calls")"
[[ "$(tail -n 1 "${STATE}/calls")" == "systemctl --user reset-failed microemu-game.scope" ]] || fail "stopping scope: no reset-failed after it ended"

reset deactivating
MICROEMU_GAME_FREE_S=1 run
[[ "${rc}" == 1 ]] || fail "stuck scope: exit ${rc}"
(( took >= 1000 && took < 3000 )) || fail "stuck scope: took ${took} ms for a 1 s bound"
grep -qx "microemu-game.scope still deactivating after 1 s" "${STATE}/log" || fail "stuck scope: no log line: $(cat "${STATE}/log")"
grep -q "reset-failed" "${STATE}/calls" && fail "stuck scope: reset-failed while still stopping"

if (( failures )); then
    echo "game-free-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "game-free-test: ok"
