#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
pad="${repo}/sysext/usr/libexec/microemu/microemu-pad"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export TREE="${T}/tree"
export FAILING="${T}/failing"

cat > "${T}/bin/busctl" <<'EOF'
#!/usr/bin/bash
for arg in "$@"; do
    if [[ "${arg}" == tree ]]; then
        cat "${TREE}"
        exit 0
    fi
done
echo "busctl $*" >> "${STATE}"
[[ ! -e "${FAILING}" || "$*" != *"$(cat "${FAILING}") "* ]]
EOF
cat > "${T}/bin/logger" <<'EOF'
#!/usr/bin/bash
echo "logger $*" >> "${STATE}"
EOF
chmod 0755 "${T}/bin/busctl" "${T}/bin/logger"
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    : > "${STATE}"
    : > "${TREE}"
}

run() {
    rc=0
    "${pad}" "$@" || rc=$?
}

count() {
    grep -c -- "$1" "${STATE}" || true
}

call="busctl --system call org.shadowblip.InputPlumber"
iface="org.shadowblip.Input.CompositeDevice SetTargetDevices as 2 xb360 keyboard"

reset
cat > "${TREE}" <<'EOF'
/org/shadowblip/InputPlumber
/org/shadowblip/InputPlumber/CompositeDevice0
/org/shadowblip/InputPlumber/CompositeDevice1
/org/shadowblip/InputPlumber/devices/source/event3
/org/shadowblip/InputPlumber/devices/target/gamepad0
/org/shadowblip/InputPlumber/devices/target/keyboard0
EOF
run xb360
[[ "${rc}" == 0 ]] || fail "xb360 exit ${rc}"
[[ "$(count "${call} /org/shadowblip/InputPlumber/CompositeDevice0 ${iface}")" == 1 ]] || fail "CompositeDevice0 not set: $(cat "${STATE}")"
[[ "$(count "${call} /org/shadowblip/InputPlumber/CompositeDevice1 ${iface}")" == 1 ]] || fail "CompositeDevice1 not set: $(cat "${STATE}")"
[[ "$(count "^busctl")" == 2 ]] || fail "expected 2 busctl calls: $(cat "${STATE}")"
[[ "$(count "^logger -t microemu-pad")" == 2 ]] || fail "expected 2 log lines: $(cat "${STATE}")"
[[ "$(count "devices/target")" == 0 ]] || fail "touched a non composite path: $(cat "${STATE}")"

reset
cat > "${TREE}" <<'EOF'
/org/shadowblip/InputPlumber
/org/shadowblip/InputPlumber/devices/target/gamepad0
EOF
run xb360
[[ "${rc}" == 0 ]] || fail "xb360 with no device exit ${rc}"
[[ "$(count "^busctl")" == 0 ]] || fail "xb360 with no device called busctl: $(cat "${STATE}")"
[[ "$(count "^logger -t microemu-pad no composite device")" == 1 ]] || fail "xb360 with no device did not log: $(cat "${STATE}")"

for verb in bogus "" "xb360;id" restore "xb360 --help"; do
    reset
    run "${verb}"
    [[ "${rc}" == 1 ]] || fail "verb '${verb}' exit ${rc}, expected 1"
    [[ -s "${STATE}" ]] && fail "verb '${verb}' ran $(cat "${STATE}")" || true
done

reset
run
[[ "${rc}" == 1 ]] || fail "no verb exit ${rc}, expected 1"

reset
cat > "${TREE}" <<'EOF'
/org/shadowblip/InputPlumber/CompositeDevice0
/org/shadowblip/InputPlumber/CompositeDevice1
EOF
echo /org/shadowblip/InputPlumber/CompositeDevice0 > "${FAILING}"
run xb360
rm -f "${FAILING}"
[[ "${rc}" == 0 ]] || fail "failing device exit ${rc}"
[[ "$(count "${call} /org/shadowblip/InputPlumber/CompositeDevice1 ${iface}")" == 1 ]] || fail "failing device stopped the loop: $(cat "${STATE}")"
[[ "$(count "^logger -t microemu-pad failed to set /org/shadowblip/InputPlumber/CompositeDevice0 target")" == 1 ]] || fail "failing device not logged: $(cat "${STATE}")"
[[ "$(count "^logger -t microemu-pad set /org/shadowblip/InputPlumber/CompositeDevice1 target")" == 1 ]] || fail "second device not logged: $(cat "${STATE}")"

if (( failures )); then
    echo "pad-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "pad-test: ok"
