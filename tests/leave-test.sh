#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
leave="${repo}/sysext/usr/libexec/microemu/microemu-leave"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user is-active --quiet gamescope-session-plus@microemu.service")
        [[ "$(cat "${STATE}/session")" == active ]] ;;
    "--no-block start armada-session-switch@gamemode.service")
        [[ "$(cat "${STATE}/start_rc")" == 0 ]] ;;
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

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    echo "$1" > "${STATE}/session"
    echo "${2:-0}" > "${STATE}/start_rc"
}

run() {
    rc=0
    "${leave}" "$@" 2> "${STATE}/stderr" || rc=$?
}

count() { grep -c -- "$1" "${STATE}/calls" || true; }

start="systemctl --no-block start armada-session-switch@gamemode.service"

reset active
run session
[[ "${rc}" == 0 ]] || fail "in microemu exit ${rc}"
[[ "$(count "^${start}$")" == 1 ]] || fail "in microemu: $(cat "${STATE}/calls")"
[[ "$(count "start")" == 1 ]] || fail "in microemu started more than once: $(cat "${STATE}/calls")"
[[ "$(tail -n 1 "${STATE}/calls")" == "${start}" ]] || fail "in microemu: the start is not the last call"

reset inactive
run session
[[ "${rc}" == 0 ]] || fail "outside microemu exit ${rc}"
[[ "$(count "start")" == 0 ]] || fail "outside microemu started a switch: $(cat "${STATE}/calls")"
grep -qx "not in the microemu session, ignored" "${STATE}/log" || fail "outside microemu: no log line"

reset active 1
run session
[[ "${rc}" == 0 ]] || fail "failed start exit ${rc}"
grep -qx "armada-session-switch@gamemode.service did not start" "${STATE}/log" || fail "failed start: no log line"

for verb in "" bogus "session;id"; do
    reset active
    run "${verb}"
    [[ "${rc}" == 1 ]] || fail "verb '${verb}' exit ${rc}, expected 1"
    [[ ! -s "${STATE}/calls" ]] || fail "verb '${verb}' ran $(cat "${STATE}/calls")"
done

if (( failures )); then
    echo "leave-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "leave-test: ok"
