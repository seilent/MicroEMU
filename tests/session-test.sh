#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
sysext="${repo}/sysext"
dropin="${sysext}/usr/lib/armada/sessions.d/microemu.conf"
session="${sysext}/usr/share/gamescope-session-plus/sessions.d/microemu"
units="${sysext}/usr/lib/systemd/user"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

value() { sed -n "s/^$1=//p" "$2"; }

desktop=$(value DESKTOP "${dropin}")
unit=$(value UNIT "${dropin}")
[[ "${desktop}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.desktop$ ]] || fail "drop-in DESKTOP ${desktop} does not match the fork rule"
[[ "${unit}" =~ ^gamescope-session-plus@[a-z0-9][a-z0-9-]*\.service$ ]] || fail "drop-in UNIT ${unit} does not match the fork rule"
[[ "${unit}" == gamescope-session-plus@microemu.service ]] || fail "drop-in UNIT is ${unit}"
[[ -f "${sysext}/usr/share/wayland-sessions/${desktop}" ]] || fail "${desktop} not shipped"
[[ "$(grep -c . "${dropin}")" == 2 ]] || fail "drop-in has more than DESKTOP and UNIT"
grep -qx 'Exec=gamescope-session-plus microemu' "${sysext}/usr/share/wayland-sessions/${desktop}" || fail "${desktop} does not start the microemu client"

(
    unset CLIENTCMD GAMESCOPE_BIN ORIENTATION
    set -a
    . "${session}"
    set +a
    [[ "${CLIENTCMD}" == /usr/libexec/microemu/microemu-client && -x "${sysext}${CLIENTCMD}" ]] || exit 11
    [[ "${GAMESCOPE_BIN}" == /usr/libexec/microemu/microemu-gamescope && -x "${sysext}${GAMESCOPE_BIN}" ]] || exit 12
    [[ -z "${ORIENTATION:-}" ]] || exit 13
    [[ "$(declare -f short_session_recover)" == *"systemctl --no-block start armada-session-switch@gamemode.service"* ]] || exit 14
) || fail "sessions.d/microemu check $? failed (11 client, 12 gamescope, 13 orientation, 14 recover)"

for file in "${units}"/*.service "${units}"/*.d/*.conf; do
    for exe in $(grep -oE '^Exec[A-Za-z]*=-?/[^ ]+' "${file}" | sed -E 's/^[^=]+=-?//'); do
        [[ -x "${sysext}${exe}" ]] || fail "$(basename "${file}"): ${exe} not shipped"
    done
done
grep -qx 'Wants=microemu-pad.service' "${units}/gamescope-session-plus@microemu.service.d/20-microemu-pad.conf" || fail "session does not want microemu-pad"
grep -qx 'BindsTo=gamescope-session-plus@microemu.service' "${units}/microemu-pad.service" || fail "microemu-pad not bound to the session"
grep -qx 'After=gamescope-session-plus@microemu.service' "${units}/microemu-pad.service" || fail "microemu-pad not ordered after the session"
grep -qx 'Upholds=microemu-hotkeyd.service' "${units}/default.target.d/50-microemu.conf" || fail "default.target does not uphold microemu-hotkeyd"
grep -qx 'Restart=always' "${units}/microemu-hotkeyd.service" || fail "microemu-hotkeyd does not restart"
grep -qx 'RestartSec=10' "${units}/microemu-hotkeyd.service" || fail "microemu-hotkeyd restarts faster than every 10 s"
stop="${units}/gamescope-session-plus@microemu.service.d/30-microemu-stop.conf"
for line in 'ExecStop=-/usr/libexec/microemu/microemu-stop' 'ExecStopPost=-/usr/libexec/microemu/microemu-game-stop' \
    'TimeoutStopSec=25' 'TimeoutStopFailureMode=terminate'; do
    grep -qx "${line}" "${stop}" || fail "30-microemu-stop.conf lacks ${line}"
done

mkdir -p "${T}/bin"
printf '#!/usr/bin/bash\nprintf "%%s\\n" "$@" > "%s"\n' "${T}/args" > "${T}/bin/gamescope"
chmod 0755 "${T}/bin/gamescope"
MICROEMU_GAMESCOPE="${T}/bin/gamescope" "${sysext}/usr/libexec/microemu/microemu-gamescope" \
    --xwayland-count 2 --steam -R "/run/user/1000/a b" -T stats --steam-like
[[ "$(cat "${T}/args")" == $'--xwayland-count\n2\n-R\n/run/user/1000/a b\n-T\nstats\n--steam-like' ]] \
    || fail "microemu-gamescope args: $(tr '\n' ' ' < "${T}/args")"
MICROEMU_GAMESCOPE="${T}/bin/gamescope" "${sysext}/usr/libexec/microemu/microemu-gamescope" --help
[[ "$(cat "${T}/args")" == --help ]] || fail "microemu-gamescope --help: $(cat "${T}/args")"

if (( failures )); then
    echo "session-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "session-test: ok"
