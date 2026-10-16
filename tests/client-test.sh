#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
client="${repo}/data/usr/libexec/microemu/microemu-client"
shipped="${repo}/data/usr/share/microemu/es-de/es_systems.xml"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/share"
export STATE="${T}/state"
export MICROEMU_ESDE="${T}/es-de"
export MICROEMU_SYSTEMS_FILE="${shipped}"
export MICROEMU_THEMES_DIR="${T}/share/themes"
mkdir -p "${MICROEMU_THEMES_DIR}/art-book-next-es-de"
: > "${MICROEMU_THEMES_DIR}/README"
export MICROEMU_ESDE_APPDATA_DIR="${T}/home/.local/share/microemu/ES-DE"
custom="${MICROEMU_ESDE_APPDATA_DIR}/custom_systems"
export MICROEMU_RUNTIME_DIR="${T}/run/a&b"
sessions="${MICROEMU_RUNTIME_DIR}/microos"
gamelist="${MICROEMU_ESDE_APPDATA_DIR}/gamelists/microos/gamelist.xml"

cat > "${T}/es-de.stub" <<'STUB'
#!/usr/bin/bash
echo "es-de" >> "${STATE}/calls"
printf '%s\n' "${ESDE_APPDATA_DIR:-unset}" > "${STATE}/appdata"
printf '%s\n' "${LD_LIBRARY_PATH-unset}" > "${STATE}/esde-ld"
cp "${ESDE_APPDATA_DIR}/custom_systems/es_systems.xml" "${STATE}/systems-at-start" 2>/dev/null || true
readlink "${ESDE_APPDATA_DIR}/themes/art-book-next-es-de" > "${STATE}/theme-at-start" 2>/dev/null || true
ls "${MICROEMU_RUNTIME_DIR}/microos" > "${STATE}/sessions-at-start" 2>/dev/null || true
[[ ! -e "${STATE}/esde-sleep" ]] || /usr/bin/sleep "$(cat "${STATE}/esde-sleep")"
exit "$(cat "${STATE}/esde_rc")"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user show -p ActiveState --value gamescope-session-plus@microemu.service")
        if [[ -s "${STATE}/unit_seq" ]]; then
            head -n 1 "${STATE}/unit_seq"
            [[ "$(wc -l < "${STATE}/unit_seq")" == 1 ]] || sed -i 1d "${STATE}/unit_seq"
        else
            cat "${STATE}/unit"
        fi
        ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/microos-session" <<'STUB'
#!/usr/bin/bash
echo "microos-session $*" >> "${STATE}/calls"
case "$1" in
    list)
        [[ ! -e "${STATE}/list_fail" ]] || exit 1
        printf 'steam\tSteam\tyes\nrecovery\tRecovery\tno\nmicrodap\tMicro<DAP> & "co"\tyes\n../x\tBad\tyes\nUpper\tBad\tyes\na b\tBad\tyes\nx;reboot\tBad\tyes\n-x\tBad\tyes\nx%%20y\tBad\tyes\nmicroemu\tMicroEMU\tyes\n'
        ;;
    back)
        rc=$(head -n 1 "${STATE}/back_rc")
        tail -n +2 "${STATE}/back_rc" > "${STATE}/back_rc.next"
        mv "${STATE}/back_rc.next" "${STATE}/back_rc"
        exit "${rc:-0}"
        ;;
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
cat > "${T}/bin/reconcile" <<'STUB'
#!/usr/bin/bash
echo "reconcile $*" >> "${STATE}/calls"
[[ -d "$2" ]] || echo "reconcile: no dir" >> "${STATE}/calls"
exit "$(cat "${STATE}/reconcile_rc" 2>/dev/null || echo 0)"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
cat > "${T}/osd" <<'STUB'
#!/usr/bin/bash
echo "osd GDK_BACKEND=${GDK_BACKEND:-unset}" >> "${STATE}/osd"
printf '%s\n' "${LD_LIBRARY_PATH-unset}" > "${STATE}/osd-ld"
[[ ! -e "${STATE}/osd-exit" ]] || exit "$(cat "${STATE}/osd-exit")"
exec /usr/bin/sleep 2
STUB
cat > "${T}/bin/game-running" <<'STUB'
#!/usr/bin/bash
echo "game-running" >> "${STATE}/calls"
n=$(cat "${STATE}/game_left" 2>/dev/null || echo 0)
(( n > 0 )) || exit 1
echo $(( n - 1 )) > "${STATE}/game_left"
echo "scope active"
STUB
chmod 0755 "${T}/bin/"* "${T}/es-de.stub" "${T}/osd"
export MICROEMU_OSD="${T}/osd"
export MICROEMU_RECONCILE="${T}/bin/reconcile"
export MICROEMU_GAME_RUNNING="${T}/bin/game-running"
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_STOP="${T}/bin/microemu-game-stop"
export MICROEMU_OPENH264_DIR="${T}/openh264"
unset LD_LIBRARY_PATH

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${T:?}/home" "${T:?}/run" "${MICROEMU_ESDE}"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    cp "${T}/es-de.stub" "${MICROEMU_ESDE}"
    echo "$1" > "${STATE}/unit"
    echo "${2:-0}" > "${STATE}/esde_rc"
    printf '%s\n' "${3:-0}" | tr ' ' '\n' > "${STATE}/back_rc"
}

run() {
    rc=0
    "${client}" 2> "${STATE}/stderr" || rc=$?
}

calls() { cat "${STATE}/calls"; }

count() { grep -c -- "$1" "${STATE}/calls" || true; }

back="microos-session back"

reset deactivating
run
expected="microemu-game-stop
reconcile esde ${MICROEMU_ESDE_APPDATA_DIR}/settings
microos-session list
es-de
game-running
systemctl --user show -p ActiveState --value gamescope-session-plus@microemu.service
sleep infinity"
[[ "$(calls)" == "${expected}" ]] || fail "deactivating: $(calls)"
[[ "$(cat "${STATE}/appdata")" == "${MICROEMU_ESDE_APPDATA_DIR}" ]] || fail "ESDE_APPDATA_DIR is $(cat "${STATE}/appdata")"
want=$(sed 's#%MICROOS_SESSIONS%#'"${T}"'/run/a\&amp;b/microos#' "${shipped}")
[[ "$(cat "${STATE}/systems-at-start")" == "${want}" ]] || fail "es_systems.xml at start: $(diff <(echo "${want}") "${STATE}/systems-at-start")"
grep -q '%MICROOS_SESSIONS%' "${STATE}/systems-at-start" && fail "placeholder left in es_systems.xml"
[[ "$(cat "${STATE}/sessions-at-start")" == $'microdap.session\nmicroemu.session\nsteam.session' ]] || fail "BOOT INTO entries at start: $(cat "${STATE}/sessions-at-start")"
grep -qF '<name>Micro&lt;DAP&gt; &amp; &quot;co&quot;</name>' "${gamelist}" || fail "gamelist label not escaped: $(cat "${gamelist}")"
grep -qF '<path>./steam.session</path>' "${gamelist}" && grep -qF '<name>Steam</name>' "${gamelist}" || fail "gamelist: no steam entry"
grep -q 'recovery\|Bad' "${gamelist}" && fail "gamelist: a non default or bad session listed"
[[ "$(find "${sessions}" -type f | wc -l)" == 3 && -z "$(find "${T}/run" -name '*.session' ! -path "${sessions}/*")" ]] || fail "bad session names: $(find "${T}/run" -name '*.session')"
{ echo '<wrap>'; sed 1d "${gamelist}"; echo '</wrap>'; } | xmllint --noout - || fail "gamelist is not well formed"

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
    [[ -f "${custom}/es_systems.xml" && ! -L "${custom}/es_systems.xml" ]] || fail "${kind}: es_systems.xml not a generated file"
    grep -q '<name>microos</name>' "${custom}/es_systems.xml" || fail "${kind}: generated file is not the shipped one"
    [[ ! -e "${custom}/es_find_rules.xml" ]] || fail "${kind}: es_find_rules.xml kept"
    [[ -z "$(find "${custom}" -name '.es_systems.*')" ]] || fail "${kind}: temp file left"
done

reset deactivating
mkdir -p "${sessions}"
: > "${sessions}/old.session"
: > "${STATE}/list_fail"
run
[[ -z "$(cat "${STATE}/sessions-at-start")" ]] || fail "list failing: entries $(cat "${STATE}/sessions-at-start")"
grep -qx "microos-session list failed, no BOOT INTO entries" "${STATE}/log" || fail "list failing: no log line"
[[ "$(count "^es-de$")" == 1 ]] || fail "list failing: es-de not started"

reset deactivating
echo 1 > "${STATE}/reconcile_rc"
run
grep -qx "reconcile failed" "${STATE}/log" || fail "reconcile failing: no log"
[[ "$(count "^es-de$")" == 1 ]] || fail "reconcile failing: es-de not started"

reset active 0
run
[[ "$(count "^${back}$")" == 1 ]] || fail "active: $(count "^${back}$") back calls, expected 1: $(calls)"
[[ "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "active: no blocking sleep after back: $(calls)"
[[ "$(grep -n '^es-de$' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -n "^${back}$" "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "active: back before es-de exited"

reset active 139
run
[[ "$(count "^${back}$")" == 1 ]] || fail "crash: $(calls)"
grep -qx "es-de exited with 139" "${STATE}/log" || fail "crash: no exit log"

reset active 139
echo 3 > "${STATE}/game_left"
run
[[ "$(count "^sleep 1$")" == 2 && "$(count "^${back}$")" == 1 ]] || fail "crash with a game: $(calls)"
[[ "$(grep -n "^${back}$" "${STATE}/calls" | cut -d: -f1)" -gt "$(grep -n '^game-running$' "${STATE}/calls" | tail -n 1 | cut -d: -f1)" ]] \
    || fail "crash with a game: back before the game ended"
grep -qx "es-de gone with a game (scope active), waiting for the game to end" "${STATE}/log" || fail "crash with a game: no log"

reset active 139
echo 1000 > "${STATE}/game_left"
printf 'active\ndeactivating\n' > "${STATE}/unit_seq"
run
[[ "$(count "^${back}$")" == 0 && "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "crash with a game, session stopping: $(calls)"

reset active 0 "1 1"
run
[[ "${rc}" == 1 ]] || fail "back failing twice exit ${rc}, expected 1"
[[ "$(count "^${back}$")" == 2 && "$(count "^sleep 2$")" == 1 ]] || fail "back failing twice: $(calls)"
grep -qx "microos-session back failed twice, ending the session" "${STATE}/log" || fail "back failing twice: no log line"

reset active 0 "1 0"
run
[[ "${rc}" == 0 ]] || fail "back failing once exit ${rc}"
[[ "$(count "^${back}$")" == 2 ]] || fail "back failing once: $(calls)"
[[ "$(tail -n 1 "${STATE}/calls")" == "sleep infinity" ]] || fail "back failing once: no blocking sleep: $(calls)"

reset active
rm -f "${MICROEMU_ESDE}"
run
[[ "$(count "^es-de$")" == 0 ]] || fail "es-de missing: ran es-de"
[[ "$(count "^${back}$")" == 1 ]] || fail "es-de missing: no back: $(calls)"
grep -qx "${MICROEMU_ESDE} missing" "${STATE}/log" || fail "es-de missing: no log line"

reset deactivating
HOME="${T}/home" MICROEMU_ESDE_APPDATA_DIR='' run
[[ "$(cat "${STATE}/appdata")" == "${T}/home/.local/share/microemu/ES-DE" ]] || fail "default appdata is $(cat "${STATE}/appdata")"
[[ ! -e "${T}/home/ES-DE" ]] || fail "default appdata: ~/ES-DE created"
grep -q "^reconcile esde ${T}/home/.local/share/microemu/ES-DE/settings$" "${STATE}/calls" || fail "default appdata: reconcile dir"

themes="${MICROEMU_ESDE_APPDATA_DIR}/themes"
reset deactivating
run
[[ "$(cat "${STATE}/theme-at-start")" == "${MICROEMU_THEMES_DIR}/art-book-next-es-de" ]] || fail "theme not linked before es-de started"
[[ ! -e "${themes}/README" ]] || fail "a file in the themes directory was linked"

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
run
[[ "$(cat "${STATE}/osd" 2>/dev/null)" == "osd GDK_BACKEND=x11" ]] || fail "osd: not started once with GDK_BACKEND=x11: $(cat "${STATE}/osd" 2>/dev/null)"
grep -q "microemu-osd exited" "${STATE}/log" && fail "osd: exit logged while it runs: $(cat "${STATE}/log")"

reset deactivating
echo 3 > "${STATE}/osd-exit"
echo 0.5 > "${STATE}/esde-sleep"
run
grep -qx "microemu-osd exited with 3" "${STATE}/log" || fail "osd exit: not logged: $(cat "${STATE}/log")"

reset deactivating
MICROEMU_OSD="${T}/absent-osd" run
grep -qx "${T}/absent-osd missing" "${STATE}/log" || fail "osd missing: no log line"
[[ "$(count "^es-de$")" == 1 ]] || fail "osd missing: es-de ran $(count "^es-de$") times"

reset deactivating
run
[[ "$(cat "${STATE}/esde-ld")" == unset ]] || fail "openh264 absent: es-de LD_LIBRARY_PATH $(cat "${STATE}/esde-ld")"

mkdir -p "${MICROEMU_OPENH264_DIR}"
: > "${MICROEMU_OPENH264_DIR}/libopenh264.so.2.6.0"
ln -s libopenh264.so.2.6.0 "${MICROEMU_OPENH264_DIR}/libopenh264.so.8"
reset deactivating
run
[[ "$(cat "${STATE}/esde-ld")" == "${MICROEMU_OPENH264_DIR}" ]] || fail "openh264 present: es-de LD_LIBRARY_PATH $(cat "${STATE}/esde-ld")"
[[ "$(cat "${STATE}/osd-ld")" == unset ]] || fail "openh264 present: the OSD got LD_LIBRARY_PATH $(cat "${STATE}/osd-ld")"

reset deactivating
LD_LIBRARY_PATH=/opt/x run
[[ "$(cat "${STATE}/esde-ld")" == "${MICROEMU_OPENH264_DIR}:/opt/x" ]] || fail "openh264 prepend: $(cat "${STATE}/esde-ld")"
[[ "$(cat "${STATE}/osd-ld")" == /opt/x ]] || fail "openh264 prepend: the OSD LD_LIBRARY_PATH $(cat "${STATE}/osd-ld")"

rm -f "${MICROEMU_OPENH264_DIR}/libopenh264.so.2.6.0"
reset deactivating
run
[[ "$(cat "${STATE}/esde-ld")" == unset ]] || fail "openh264 dangling link: es-de LD_LIBRARY_PATH $(cat "${STATE}/esde-ld")"
rm -rf "${MICROEMU_OPENH264_DIR}"

if (( failures )); then
    echo "client-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "client-test: ok"
