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
export MICROEMU_THEMES_DIR="${T}/share/themes"
mkdir -p "${MICROEMU_THEMES_DIR}/art-book-next-es-de"
: > "${MICROEMU_THEMES_DIR}/README"
export MICROEMU_ESDE_APPDATA_DIR="${T}/home/.local/share/microemu/ES-DE"
: > "${MICROEMU_SYSTEMS_FILE}"
custom="${MICROEMU_ESDE_APPDATA_DIR}/custom_systems"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_CLIENT_POLL_S=0.05
reload_marker="${MICROEMU_RUNTIME_DIR}/esde-reload"

cat > "${T}/es-de.stub" <<'STUB'
#!/usr/bin/bash
echo "es-de" >> "${STATE}/calls"
printf '%s\n' "${ESDE_APPDATA_DIR:-unset}" > "${STATE}/appdata"
readlink "${ESDE_APPDATA_DIR}/custom_systems/es_systems.xml" > "${STATE}/link-at-start" 2>/dev/null || true
readlink "${ESDE_APPDATA_DIR}/themes/art-book-next-es-de" > "${STATE}/theme-at-start" 2>/dev/null || true
cp "${ESDE_APPDATA_DIR}/settings/es_settings.xml" "${STATE}/settings-at-start" 2>/dev/null || true
n=$(( $(cat "${STATE}/esde_runs" 2>/dev/null || echo 0) + 1 ))
echo "${n}" > "${STATE}/esde_runs"
cp "${ESDE_APPDATA_DIR}/settings/es_settings.xml" "${STATE}/settings-at-start-${n}" 2>/dev/null || true
[[ ! -e "${STATE}/pick-${n}" ]] || sed -i "s/value=\"androidgames\"/value=\"$(cat "${STATE}/pick-${n}")\"/" "${ESDE_APPDATA_DIR}/settings/es_settings.xml"
if [[ "$(cat "${STATE}/reload-on-run" 2>/dev/null)" == "${n}" ]]; then
    trap 'echo "es-de term scope=$([[ -e "${STATE}/scope" ]] && echo active || echo inactive)" >> "${STATE}/calls"; exit 0' TERM
    mkdir -p "${MICROEMU_RUNTIME_DIR}"
    : > "${MICROEMU_RUNTIME_DIR}/esde-reload"
    for _ in $(seq 1 100); do /usr/bin/sleep 0.05; done
    echo "es-de not terminated" >> "${STATE}/calls"
fi
exit "$(cat "${STATE}/esde_rc")"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user show -p ActiveState --value gamescope-session-plus@microemu.service")
        cat "${STATE}/unit" ;;
    "--user is-active --quiet microemu-game.scope") [[ -e "${STATE}/scope" ]] ;;
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

settings="${MICROEMU_ESDE_APPDATA_DIR}/settings/es_settings.xml"
themes="${MICROEMU_ESDE_APPDATA_DIR}/themes"
seeded='<?xml version="1.0"?>
<string name="Theme" value="art-book-next-es-de" />
<string name="ThemeColorScheme" value="dark-screenshots" />
<string name="ThemeVariant" value="gamelist-list-metadata-cover" />
<string name="ThemeFontSize" value="medium" />
<string name="ThemeAspectRatio" value="3:2" />
<string name="ApplicationUpdaterFrequency" value="never" />'

reset deactivating
run
[[ "$(cat "${STATE}/theme-at-start")" == "${MICROEMU_THEMES_DIR}/art-book-next-es-de" ]] || fail "theme not linked before es-de started"
[[ ! -e "${themes}/README" ]] || fail "a file in the themes directory was linked"
[[ "$(cat "${STATE}/settings-at-start")" == "${seeded}" ]] || fail "fresh settings: $(cat "${STATE}/settings-at-start")"

for kind in file link; do
    reset deactivating
    mkdir -p "${themes}"
    case "${kind}" in
        file) echo old > "${themes}/art-book-next-es-de" ;;
        link) ln -s /nonexistent "${themes}/art-book-next-es-de" ;;
    esac
    mkdir -p "${themes}/user-theme"
    run
    [[ "$(readlink "${themes}/art-book-next-es-de")" == "${MICROEMU_THEMES_DIR}/art-book-next-es-de" ]] || fail "theme over a ${kind} not replaced"
    [[ -d "${themes}/user-theme" ]] || fail "theme over a ${kind}: another theme removed"
done

reset deactivating
mkdir -p "${themes}/art-book-next-es-de"
echo mine > "${themes}/art-book-next-es-de/theme.xml"
run
[[ ! -L "${themes}/art-book-next-es-de" && "$(cat "${themes}/art-book-next-es-de/theme.xml")" == mine ]] || fail "user theme directory replaced"
grep -qx "${themes}/art-book-next-es-de is a directory, kept instead of the shipped art-book-next-es-de" "${STATE}/log" \
    || fail "user theme directory: no log line"

reset deactivating
mkdir -p "$(dirname "${settings}")"
printf '<?xml version="1.0"?>\n<bool name="VSync" value="true" />\n<string name="Theme" value="linear-es-de" />\n<string name="ThemeFontSize" value="large" />' > "${settings}"
run
expected='<?xml version="1.0"?>
<bool name="VSync" value="true" />
<string name="Theme" value="linear-es-de" />
<string name="ThemeFontSize" value="large" />
<string name="ThemeColorScheme" value="dark-screenshots" />
<string name="ThemeVariant" value="gamelist-list-metadata-cover" />
<string name="ThemeAspectRatio" value="3:2" />
<string name="ApplicationUpdaterFrequency" value="never" />'
[[ "$(cat "${settings}")" == "${expected}" ]] || fail "partial settings: $(cat "${settings}")"

reset deactivating
mkdir -p "$(dirname "${settings}")"
printf '%s\n' "${seeded}" | sed 's/dark-screenshots/oled-noir/; s/value="3:2"/value="automatic"/' > "${settings}"
cp "${settings}" "${T}/full"
run
cmp -s "${settings}" "${T}/full" || fail "full settings changed: $(cat "${settings}")"

startup_user='<?xml version="1.0"?>
<string name="StartupSystem" value="snes" />
<string name="Theme" value="art-book-next-es-de" />'
saved="${MICROEMU_ESDE_APPDATA_DIR}/settings/microemu-startup.saved"

reset active
mkdir -p "$(dirname "${settings}")"
printf '%s\n' "${startup_user}" > "${settings}"
echo 1 > "${STATE}/reload-on-run"
: > "${STATE}/scope"
( /usr/bin/sleep 0.4; rm -f "${STATE}/scope" ) &
run
wait
[[ "$(count "^es-de$")" == 2 ]] || fail "reload: es-de ran $(count "^es-de$") times: $(calls)"
grep -qx "es-de term scope=inactive" "${STATE}/calls" || fail "reload: es-de not terminated after the game scope ended: $(calls)"
grep -qx "new Android entries, restarting es-de" "${STATE}/log" || fail "reload: no log line"
grep -qx '<string name="StartupSystem" value="androidgames" />' "${STATE}/settings-at-start-2" \
    && grep -qx '<string name="StartupView" value="gamelist" />' "${STATE}/settings-at-start-2" || fail "reload: not started on the Android Games gamelist: $(cat "${STATE}/settings-at-start-2")"
grep -q 'name="StartupSystem" value="snes"' "${STATE}/settings-at-start-2" && fail "reload: the old startup system kept"
grep -qx '<string name="StartupSystem" value="snes" />' "${settings}" || fail "reload: startup system not restored: $(cat "${settings}")"
grep -q 'StartupView\|androidgames' "${settings}" && fail "reload: override left: $(cat "${settings}")"
[[ ! -e "${saved}" && ! -e "${reload_marker}" ]] || fail "reload: saved startup or marker left"
[[ "$(count "^${switch}$")" == 1 ]] || fail "reload: switch called $(count "^${switch}$") times: $(calls)"
[[ "$(grep -n '^es-de$' "${STATE}/calls" | tail -n 1 | cut -d: -f1)" -lt "$(grep -n "${switch}" "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "reload: switch before the second es-de"

reset active
mkdir -p "$(dirname "${settings}")"
printf '%s\n' "${startup_user}" > "${settings}"
echo 1 > "${STATE}/reload-on-run"
echo gba > "${STATE}/pick-2"
run
grep -qx '<string name="StartupSystem" value="gba" />' "${settings}" || fail "reload: a startup system picked after the reload was overwritten: $(cat "${settings}")"
[[ ! -e "${saved}" ]] || fail "reload with a new pick: saved startup left"

reset deactivating
echo 1 > "${STATE}/reload-on-run"
run
[[ "$(count "^es-de$")" == 1 ]] || fail "reload while deactivating: es-de ran $(count "^es-de$") times"
[[ "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "reload while deactivating: $(calls)"
[[ ! -e "${saved}" ]] || fail "reload while deactivating: saved startup left"

reset deactivating
mkdir -p "$(dirname "${settings}")"
printf '<?xml version="1.0"?>\n<string name="StartupSystem" value="androidgames" />\n<string name="StartupView" value="gamelist" />\n' > "${settings}"
printf '<string name="StartupSystem" value="snes" />\n' > "${saved}"
run
grep -qx '<string name="StartupSystem" value="snes" />' "${STATE}/settings-at-start-1" || fail "leftover override not restored before es-de: $(cat "${STATE}/settings-at-start-1")"
grep -q StartupView "${STATE}/settings-at-start-1" && fail "leftover override: StartupView kept"
[[ ! -e "${saved}" ]] || fail "leftover override: saved startup left"

reset deactivating
mkdir -p "${MICROEMU_RUNTIME_DIR}"
: > "${reload_marker}"
run
[[ "$(count "^es-de$")" == 1 ]] || fail "stale marker: es-de ran $(count "^es-de$") times"
[[ ! -e "${reload_marker}" ]] || fail "stale marker kept"
grep -q "restarting es-de" "${STATE}/log" && fail "stale marker restarted es-de"

if (( failures )); then
    echo "client-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "client-test: ok"
