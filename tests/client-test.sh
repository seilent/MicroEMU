#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
client="${repo}/sysext/usr/libexec/microemu/microemu-client"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/share"
export STATE="${T}/state"
export MICROEMU_ESDE="${T}/es-de"
export MICROEMU_SYSTEMS_FILE="${T}/share/es_systems.xml"
export MICROEMU_ESDE_APPDATA_DIR="${T}/home/.local/share/microemu/ES-DE"
: > "${MICROEMU_SYSTEMS_FILE}"
custom="${MICROEMU_ESDE_APPDATA_DIR}/custom_systems"

cat > "${T}/es-de.stub" <<'STUB'
#!/usr/bin/bash
echo "es-de" >> "${STATE}/calls"
printf '%s\n' "${ESDE_APPDATA_DIR:-unset}" > "${STATE}/appdata"
readlink "${ESDE_APPDATA_DIR}/custom_systems/es_systems.xml" > "${STATE}/link-at-start" 2>/dev/null || true
exit "$(cat "${STATE}/esde_rc")"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user show -p ActiveState --value gamescope-session-plus@microemu.service")
        cat "${STATE}/unit" ;;
    "start armada-session-switch@gamemode.service")
        rc=$(head -n 1 "${STATE}/start_rc")
        tail -n +2 "${STATE}/start_rc" > "${STATE}/start_rc.next"
        mv "${STATE}/start_rc.next" "${STATE}/start_rc"
        exit "${rc:-0}" ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/sleep" <<'STUB'
#!/usr/bin/bash
echo "sleep $*" >> "${STATE}/calls"
STUB
cat > "${T}/bin/microemu-game-stop" <<'STUB'
#!/usr/bin/bash
echo "microemu-game-stop" >> "${STATE}/calls"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"* "${T}/es-de.stub"
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_STOP="${T}/bin/microemu-game-stop"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${T:?}/home" "${MICROEMU_ESDE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    cp "${T}/es-de.stub" "${MICROEMU_ESDE}"
    echo "$1" > "${STATE}/unit"
    echo "${2:-0}" > "${STATE}/esde_rc"
    printf '%s\n' "${3:-0}" | tr ' ' '\n' > "${STATE}/start_rc"
}

run() {
    rc=0
    "${client}" 2> "${STATE}/stderr" || rc=$?
}

calls() { cat "${STATE}/calls"; }

count() { grep -c -- "$1" "${STATE}/calls" || true; }

switch="systemctl start armada-session-switch@gamemode.service"

reset deactivating
run
[[ "$(head -n 2 "${STATE}/calls")" == $'microemu-game-stop\nes-de' ]] || fail "game stop not run before es-de: $(calls)"
[[ "$(count "^microemu-game-stop$")" == 1 ]] || fail "game stop run $(count "^microemu-game-stop$") times"
[[ "$(cat "${STATE}/appdata")" == "${MICROEMU_ESDE_APPDATA_DIR}" ]] || fail "ESDE_APPDATA_DIR is $(cat "${STATE}/appdata")"
[[ "$(cat "${STATE}/link-at-start")" == "${MICROEMU_SYSTEMS_FILE}" ]] || fail "es_systems.xml not linked before es-de started"
[[ "$(count "^${switch}$")" == 0 ]] || fail "deactivating: switch called: $(calls)"
[[ "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "deactivating: no blocking sleep: $(calls)"

for kind in absent file link dir; do
    reset deactivating
    mkdir -p "${custom}"
    case "${kind}" in
        file) echo "<systemList/>" > "${custom}/es_systems.xml" ;;
        link) ln -s /nonexistent/es_systems.xml "${custom}/es_systems.xml" ;;
        dir) mkdir -p "${custom}/es_systems.xml/sub" ;;
    esac
    echo "<ruleList/>" > "${custom}/es_find_rules.xml"
    run
    [[ -L "${custom}/es_systems.xml" && "$(readlink "${custom}/es_systems.xml")" == "${MICROEMU_SYSTEMS_FILE}" ]] \
        || fail "${kind}: es_systems.xml is not a link to the shipped file"
    [[ ! -e "${custom}/es_find_rules.xml" ]] || fail "${kind}: es_find_rules.xml kept"
done

reset active 0
run
[[ "$(count "^${switch}$")" == 1 ]] || fail "active: $(count "^${switch}$") switch calls, expected 1: $(calls)"
[[ "$(count "no-block")" == 0 ]] || fail "active: the switch is not blocking: $(calls)"
[[ "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "active: no blocking sleep after the switch: $(calls)"
[[ "$(grep -n 'es-de' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -n "${switch}" "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "active: switch before es-de exited"

reset active 139
run
[[ "$(count "^${switch}$")" == 1 ]] || fail "crash: $(calls)"
grep -qx "es-de exited with 139" "${STATE}/log" || fail "crash: no exit log"

reset active 0 "1 1"
run
[[ "${rc}" == 1 ]] || fail "switch failing twice exit ${rc}, expected 1"
expected="microemu-game-stop
es-de
systemctl --user show -p ActiveState --value gamescope-session-plus@microemu.service
${switch}
sleep 2
${switch}"
[[ "$(calls)" == "${expected}" ]] || fail "switch failing twice: $(calls)"
grep -qx "armada-session-switch@gamemode.service failed twice, ending the session" "${STATE}/log" \
    || fail "switch failing twice: no log line"

reset active 0 "1 0"
run
[[ "${rc}" == 0 ]] || fail "switch failing once exit ${rc}"
[[ "$(count "^${switch}$")" == 2 ]] || fail "switch failing once: $(calls)"
[[ "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "switch failing once: no blocking sleep: $(calls)"

reset active
rm -f "${MICROEMU_ESDE}"
run
[[ "$(count "^es-de$")" == 0 ]] || fail "es-de missing: ran es-de"
[[ "$(count "^${switch}$")" == 1 ]] || fail "es-de missing: no switch: $(calls)"
grep -qx "${MICROEMU_ESDE} missing" "${STATE}/log" || fail "es-de missing: no log line"

reset deactivating
HOME="${T}/home" MICROEMU_ESDE_APPDATA_DIR='' run
[[ "$(cat "${STATE}/appdata")" == "${T}/home/.local/share/microemu/ES-DE" ]] || fail "default appdata is $(cat "${STATE}/appdata")"
[[ ! -e "${T}/home/ES-DE" ]] || fail "default appdata: ~/ES-DE created"

if (( failures )); then
    echo "client-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "client-test: ok"
