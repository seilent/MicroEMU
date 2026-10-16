#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
data="${repo}/data"
registry="${data}/usr/lib/microos/sessions.d/microemu.conf"
session="${data}/usr/share/gamescope-session-plus/sessions.d/microemu"
hotkeys="${data}/usr/lib/microos/hotkeys.d"
units="${data}/usr/lib/systemd/user"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

value() { sed -n "s/^$1=//p" "$2"; }

[[ "$(cat "${registry}")" == $'LABEL=MicroEMU\nDESKTOP=microemu.desktop\nUNIT=gamescope-session-plus@microemu.service\nSTOP=unit\nDEFAULT=yes\nGAME_SCOPE=microemu-game.scope' ]] \
    || fail "sessions.d/microemu.conf: $(cat "${registry}")"
[[ "$(value GAME_SCOPE "${registry}")" =~ ^[a-z0-9][a-z0-9@._-]*\.scope$ ]] || fail "GAME_SCOPE does not match hotkeyd's rule"
desktop=$(value DESKTOP "${registry}")
[[ -f "${data}/usr/share/wayland-sessions/${desktop}" ]] || fail "${desktop} not shipped"
grep -qx 'Exec=gamescope-session-plus microemu' "${data}/usr/share/wayland-sessions/${desktop}" || fail "${desktop} does not start the microemu client"

[[ "$(cat "${hotkeys}/microemu.conf")" == $'lc hold unit microemu-lc.service\nvolup press volume up\nvoldown press volume down' ]] \
    || fail "hotkeys.d/microemu.conf: $(cat "${hotkeys}/microemu.conf")"
[[ "$(cat "${hotkeys}/steam.conf.d/50-microemu.conf")" == 'lc hold switch microemu confirm-in-game' ]] || fail "steam.conf.d row"
[[ "$(cat "${hotkeys}/microdap.conf.d/50-microemu.conf")" == 'lc hold switch microemu' ]] || fail "microdap.conf.d row"
[[ -f "${units}/microemu-lc.service" ]] || fail "microemu-lc.service not shipped"
grep -qx 'ExecStart=/usr/libexec/microemu/microemu-lc' "${units}/microemu-lc.service" || fail "microemu-lc.service ExecStart"
grep -qx 'Type=oneshot' "${units}/microemu-lc.service" || fail "microemu-lc.service is not a oneshot"

mkdir -p "${T}/bin"
cat > "${T}/microset" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${T_STATE}/microset"
[[ "$*" == "get microemu.orientation" ]] || exit 2
[[ -e "${T_STATE}/orientation" ]] || exit 5
cat "${T_STATE}/orientation"
STUB
chmod 0755 "${T}/microset"
for case in none:unset landscape:unset landscape-flipped:left; do
    rm -f "${T}/orientation" "${T}/microset.log"
    [[ "${case%%:*}" == none ]] || echo "${case%%:*}" > "${T}/orientation"
    got=$(
        unset CLIENTCMD GAMESCOPE_BIN ORIENTATION
        export T_STATE="${T}" MICROEMU_MICROSET="${T}/microset"
        set -a
        . "${session}"
        set +a
        [[ "${CLIENTCMD}" == /usr/libexec/microemu/microemu-client && -x "${data}${CLIENTCMD}" ]] || echo "client ${CLIENTCMD}"
        [[ "${GAMESCOPE_BIN}" == /usr/libexec/microemu/microemu-gamescope && -x "${data}${GAMESCOPE_BIN}" ]] || echo "gamescope ${GAMESCOPE_BIN}"
        echo "${ORIENTATION:-unset}"
    )
    [[ "${got}" == "${case#*:}" ]] || fail "sessions.d/microemu with ${case%%:*}: ${got}"
done
grep -q short_session_recover "${session}" && fail "sessions.d/microemu defines short_session_recover"

for file in "${units}"/*.service "${units}"/*.d/*.conf; do
    for exe in $(grep -oE '^Exec[A-Za-z]*=-?/[^ ]+' "${file}" | sed -E 's/^[^=]+=-?//'); do
        case "${exe}" in
            /usr/libexec/microemu/*) [[ -x "${data}${exe}" ]] || fail "$(basename "${file}"): ${exe} not shipped" ;;
            *) fail "$(basename "${file}"): ${exe} is not microemu's" ;;
        esac
    done
done
grep -qx 'Wants=microemu-pad.service' "${units}/gamescope-session-plus@microemu.service.d/20-microemu-pad.conf" || fail "session does not want microemu-pad"
grep -qx 'BindsTo=gamescope-session-plus@microemu.service' "${units}/microemu-pad.service" || fail "microemu-pad not bound to the session"
grep -qx 'After=gamescope-session-plus@microemu.service steamos-manager.service' "${units}/microemu-pad.service" || fail "microemu-pad not ordered after the session"
stop="${units}/gamescope-session-plus@microemu.service.d/30-microemu-stop.conf"
for line in 'ExecStop=-/usr/libexec/microemu/microemu-stop' 'ExecStopPost=-/usr/libexec/microemu/microemu-game-stop' \
    'TimeoutStopSec=25' 'TimeoutStopFailureMode=terminate'; do
    grep -qx "${line}" "${stop}" || fail "30-microemu-stop.conf lacks ${line}"
done

leftover=$(grep -rIl -i -E 'armada|session-control|/run/armada|lepton|EPOCHREALTIME|date \+%s|androidgames|microemu-play' "${data}" || true)
[[ -z "${leftover}" ]] || fail "Armada, Android or wall clock names in data/: ${leftover}"
grep -rIl -E 'set-default-sink' "${data}" && fail "data/ sets the default sink"
[[ -z "$(find "${data}" -path '*/etc/*' -o -name 'extension-release*' -o -name '*.raw')" ]] || fail "sysext or /etc files in data/"
[[ -z "$(find "${data}" -mindepth 1 -maxdepth 1 ! -name usr)" ]] || fail "data/ holds more than usr/"

mkdir -p "${T}/gs"
printf '#!/usr/bin/bash\nprintf "%%s\\n" "$@" > "%s"\n' "${T}/args" > "${T}/gs/gamescope"
chmod 0755 "${T}/gs/gamescope"
MICROEMU_GAMESCOPE="${T}/gs/gamescope" "${data}/usr/libexec/microemu/microemu-gamescope" \
    --xwayland-count 2 --steam -R "/run/user/1000/a b" -T stats --steam-like
[[ "$(cat "${T}/args")" == $'--xwayland-count\n2\n-R\n/run/user/1000/a b\n-T\nstats\n--steam-like' ]] \
    || fail "microemu-gamescope args: $(tr '\n' ' ' < "${T}/args")"
MICROEMU_GAMESCOPE="${T}/gs/gamescope" "${data}/usr/libexec/microemu/microemu-gamescope" --help
[[ "$(cat "${T}/args")" == --help ]] || fail "microemu-gamescope --help: $(cat "${T}/args")"

if (( failures )); then
    echo "session-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "session-test: ok"
