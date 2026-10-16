#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
wrapper="${repo}/data/usr/libexec/microemu/bin/retroarch"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_RETROARCH_CONFIG="${T}/config/microemu/retroarch/retroarch.cfg"
export MICROEMU_RETROARCH_DATA="${T}/data/microemu/retroarch"
export MICROEMU_RETROARCH_SHARE="${repo}/data/usr/share/microemu/retroarch"
share="${MICROEMU_RETROARCH_SHARE}"
confdir="$(dirname "${MICROEMU_RETROARCH_CONFIG}")"

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user is-active --quiet gamescope-session-plus@microemu.service") [[ "$(cat "${STATE}/session")" == active ]] ;;
    "--user reset-failed microemu-game.scope") exit 0 ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/systemd-run" <<'STUB'
#!/usr/bin/bash
echo "systemd-run" >> "${STATE}/calls"
printf '%s\n' "$@" > "${STATE}/argv"
printf '%s\n' "${LD_LIBRARY_PATH-unset}" > "${STATE}/ld"
cat "${MICROEMU_RUNTIME_DIR}/launching" > "${STATE}/marker-at-run" 2>/dev/null || echo none > "${STATE}/marker-at-run"
exit "$(cat "${STATE}/rc")"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
cat > "${T}/bin/reconcile" <<'STUB'
#!/usr/bin/bash
echo "reconcile $*" >> "${STATE}/calls"
exit "$(cat "${STATE}/reconcile_rc" 2>/dev/null || echo 0)"
STUB
cat > "${T}/bin/game-free" <<'STUB'
#!/usr/bin/bash
echo "game-free" >> "${STATE}/calls"
[[ ! -e "${STATE}/game_free_sleep" ]] || /usr/bin/sleep "$(cat "${STATE}/game_free_sleep")"
exit "$(cat "${STATE}/game_free_rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_FREE="${T}/bin/game-free"
export MICROEMU_RECONCILE="${T}/bin/reconcile"
export MICROEMU_OPENH264_DIR=/var/lib/microos/openh264
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${T}/config" "${T}/data"
    mkdir -p "${STATE}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    echo "$1" > "${STATE}/session"
    echo "${2:-0}" > "${STATE}/rc"
}

run() {
    rc=0
    LD_LIBRARY_PATH=/appimage/usr/lib "${wrapper}" "$@" 2> "${STATE}/stderr" || rc=$?
}

ran() { grep -qx systemd-run "${STATE}/calls"; }

mgba=/usr/lib64/libretro/mgba_libretro.so

reset active
run -L "${mgba}" "/home/micro/ROMs/gba/Some Game (USA).gba"
[[ "${rc}" == 0 ]] || fail "launch exit ${rc}: $(cat "${STATE}/stderr")"
expected="--user
--scope
--collect
--expand-environment=no
--unit=microemu-game
--property=BindsTo=gamescope-session-plus@microemu.service
--property=After=gamescope-session-plus@microemu.service
--property=TimeoutStopSec=5
--
/usr/bin/retroarch
-c
${MICROEMU_RETROARCH_CONFIG}
--appendconfig
/usr/share/microemu/retroarch/microemu.cfg
-L
${mgba}
/home/micro/ROMs/gba/Some Game (USA).gba"
[[ "$(cat "${STATE}/argv")" == "${expected}" ]] || fail "launch argv: $(cat "${STATE}/argv")"
[[ "$(cat "${STATE}/ld")" == /appimage/usr/lib ]] || fail "launch: LD_LIBRARY_PATH changed: $(cat "${STATE}/ld")"
[[ "$(cat "${STATE}/calls")" == "systemctl --user is-active --quiet gamescope-session-plus@microemu.service
game-free
reconcile retroarch ${confdir}
systemd-run" ]] \
    || fail "launch: calls $(cat "${STATE}/calls")"
[[ -f "${MICROEMU_RETROARCH_CONFIG}" ]] || fail "launch: config not created"
for dir in saves states system screenshots; do
    [[ -d "${MICROEMU_RETROARCH_DATA}/${dir}" ]] || fail "launch: ${dir} directory not created"
done

reset active
mkdir -p "$(dirname "${MICROEMU_RETROARCH_CONFIG}")"
echo 'video_driver = "gl"' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == 'video_driver = "gl"' ]] || fail "existing config overwritten"

reset active
echo 4 > "${STATE}/reconcile_rc"
run -L "${mgba}" /rom.gba
[[ "${rc}" == 0 ]] && ran || fail "a failed reconcile stopped the launch: exit ${rc}"
grep -qx "reconcile failed" "${STATE}/log" || fail "a failed reconcile not logged"

reset active
mkdir -p "${confdir}/config/Gambatte"
echo 'gambatte_gb_colorization = "disabled"' > "${confdir}/config/Gambatte/Gambatte.opt"
run -L "${mgba}" /rom.gba
[[ "$(cat "${confdir}/config/Gambatte/Gambatte.opt")" == 'gambatte_gb_colorization = "disabled"' ]] || fail "a user Gambatte.opt was replaced"
cmp -s "${confdir}/config/mGBA/mGBA.opt" "${share}/config/mGBA/mGBA.opt" || fail "mGBA.opt not copied"
cmp -s "${confdir}/config/Game & Watch/Game & Watch.cfg" "${share}/config/Game & Watch/Game & Watch.cfg" || fail "Game & Watch.cfg not copied"
[[ "$(cd "${confdir}/config" && find . -type f | wc -l)" == "$(cd "${share}/config" && find . -type f | wc -l)" ]] || fail "core files: $(cd "${confdir}/config" && find . -type f)"
remaps="${MICROEMU_RETROARCH_DATA}/remaps"
for core in mGBA Gambatte Nestopia "Beetle VB" "Game & Watch"; do
    [[ "$(cat "${remaps}/${core}/${core}.rmp")" == $'input_player1_btn_a = "0"\ninput_player1_btn_b = "8"' ]] || fail "${core}: no A and B swap remap"
done
[[ "$(cat "${remaps}/bsnes-mercury/bsnes-mercury.rmp")" == $'input_player1_btn_a = "0"\ninput_player1_btn_b = "8"\ninput_player1_btn_x = "1"\ninput_player1_btn_y = "9"' ]] || fail "bsnes-mercury: no A B X Y swap remap"
[[ "$(cd "${remaps}" && find . -type f | wc -l)" == 6 ]] || fail "remaps: $(cd "${remaps}" && find . -type f)"
copy_line=$(grep -n '^copy_missing "${SHARE}/remaps"' "${wrapper}" | cut -d: -f1)
free_line=$(grep -n '^"${GAME_FREE}"' "${wrapper}" | cut -d: -f1)
reconcile_line=$(grep -n '^"${RECONCILE}" retroarch' "${wrapper}" | cut -d: -f1)
(( copy_line < free_line && free_line < reconcile_line )) || fail "core files copied ${copy_line}, scope wait ${free_line}, reconcile ${reconcile_line}: wrong order"
[[ ! -e "${share}/defaults" ]] || fail "the defaults table is shipped next to the reconcile"

reset active
mkdir -p "${MICROEMU_RETROARCH_DATA}/remaps/mGBA"
echo 'input_player1_btn_a = "8"' > "${MICROEMU_RETROARCH_DATA}/remaps/mGBA/mGBA.rmp"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_DATA}/remaps/mGBA/mGBA.rmp")" == 'input_player1_btn_a = "8"' ]] || fail "a user mGBA remap was replaced"
[[ -f "${MICROEMU_RETROARCH_DATA}/remaps/Gambatte/Gambatte.rmp" ]] || fail "a missing remap beside a user one was not copied"
find "${share}/config" -type f ! -name '*.opt' ! -name '*.cfg' | grep -q . && fail "a shipped core file is neither .opt nor .cfg"
for core in Gambatte mGBA Nestopia "Stella 2014" ProSystem Handy "Beetle NeoPop" "Beetle PCE Fast" "Beetle VB" "Beetle WonderSwan" "Game & Watch"; do
    grep -qx 'run_ahead_enabled = "true"' "${share}/config/${core}/${core}.cfg" && grep -qx 'rewind_enable = "true"' "${share}/config/${core}/${core}.cfg" \
        || fail "${core}: no run ahead and rewind override"
done
grep -qx 'rewind_enable = "true"' "${share}/config/bsnes-mercury/bsnes-mercury.cfg" || fail "bsnes-mercury: no rewind override"
grep -q '^run_ahead' "${share}/config/bsnes-mercury/bsnes-mercury.cfg" && fail "bsnes-mercury: run ahead set on a core without deterministic states"
for dir in remaps playlists logs/runtime thumbnails downloads cache; do
    [[ -d "${MICROEMU_RETROARCH_DATA}/${dir}" ]] || fail "${dir} directory not created"
done

reset active
rc=0
HOME="${T}/home" MICROEMU_RETROARCH_CONFIG='' MICROEMU_RETROARCH_DATA="${T}/home/.local/share/microemu/retroarch" "${wrapper}" -L "${mgba}" /rom.gba 2> "${STATE}/stderr" || rc=$?
[[ -f "${T}/home/.config/microemu/retroarch/retroarch.cfg" && -d "${T}/home/.config/microemu/retroarch/config/Gambatte" ]] || fail "default config root: $(find "${T}/home" -maxdepth 4)"
cfg="${share}/microemu.cfg"
grep -qxF 'rgui_config_directory = "~/.config/microemu/retroarch/config"' "${cfg}" || fail "microemu.cfg: config dir is not the wrapper's"
grep -qxF 'video_shader_dir = "/usr/share/microemu/retroarch/shaders"' "${cfg}" || fail "microemu.cfg: no shader dir"
for key in input_remapping_directory:remaps playlist_directory:playlists log_dir:logs runtime_log_directory:logs/runtime thumbnails_directory:thumbnails core_assets_directory:downloads cache_directory:cache savefile_directory:saves; do
    grep -qxF "${key%%:*} = \"~/.local/share/microemu/retroarch/${key#*:}\"" "${cfg}" || fail "microemu.cfg: ${key%%:*} not under ~/.local/share/microemu/retroarch"
done
grep -q '^video_driver' "${cfg}" && fail "microemu.cfg forces a video driver"
grep -qxF 'video_fullscreen = "true"' "${cfg}" || fail "microemu.cfg: not fullscreen"
grep -qxF 'desktop_menu_enable = "false"' "${cfg}" || fail "microemu.cfg: the Qt companion is not off"
grep -qxF '#reference "../../shaders_slang/retro crisis/1080p Flat/RC GDV-NTSC - NES - Clean.slangp"' "${share}/shaders/presets/Nestopia/Nestopia.slangp" || fail "Nestopia preset is not Retro Crisis NES Clean"
grep -qxF '#reference "../../shaders_slang/retro crisis/1080p Flat/RC GDV-NTSC - SNES - Clean.slangp"' "${share}/shaders/presets/bsnes-mercury/bsnes-mercury.slangp" || fail "bsnes-mercury preset is not Retro Crisis SNES Clean"

reset active
echo 1 > "${STATE}/game_free_rc"
run -L "${mgba}" /rom.gba
[[ "${rc}" == 1 ]] || fail "scope still stopping: exit ${rc}"
ran && fail "scope still stopping: systemd-run called"
grep -qx "microemu-game.scope is still stopping" "${STATE}/log" || fail "scope still stopping: no log line"
for core in Nestopia bsnes-mercury; do
    [[ -f "${share}/shaders/presets/${core}/${core}.slangp" ]] || fail "${core}: no shader preset"
done
[[ "$(cd "${share}/shaders/presets" && find . -type f | wc -l)" == 2 ]] || fail "presets: $(cd "${share}/shaders/presets" && find . -type f)"

reset active 3
run -L "${mgba}" /rom.gba
[[ "${rc}" == 3 ]] || fail "exit code ${rc}, expected 3"

reset inactive
run -L "${mgba}" /rom.gba
[[ "${rc}" == 1 ]] || fail "outside microemu exit ${rc}, expected 1"
ran && fail "outside microemu: systemd-run called"
grep -qx "gamescope-session-plus@microemu.service is not active, refusing" "${STATE}/log" || fail "outside microemu: no log line"

for core in /usr/lib64/libretro/../../../tmp/x_libretro.so /tmp/mgba_libretro.so /usr/lib64/libretro/mgba.so \
    "/usr/lib64/libretro/mgba_libretro.so;id" /usr/lib64/libretro/sub/mgba_libretro.so; do
    reset active
    run -L "${core}" /rom.gba
    [[ "${rc}" == 1 ]] || fail "core ${core} exit ${rc}, expected 1"
    ran && fail "core ${core}: systemd-run called"
done

for case in "-L${mgba} /rom.gba" "--libretro=${mgba} /rom.gba" "-L ${mgba} -c /tmp/x.cfg /rom.gba" \
    "-L ${mgba} --config=/tmp/x.cfg /rom.gba" "-L ${mgba} --appendconfig /tmp/x.cfg /rom.gba" "-L ${mgba} -L ${mgba} /rom.gba" \
    "/rom.gba" "-L" "-L ${mgba} -vL /tmp/x_libretro.so /rom.gba" "-L ${mgba} -fc /tmp/x.cfg /rom.gba" "-vc /tmp/x.cfg -L ${mgba} /rom.gba" \
    "-L ${mgba} -Lc /rom.gba" "-L ${mgba} --conf=/tmp/x.cfg /rom.gba" "-L ${mgba} --appendc=/tmp/x.cfg /rom.gba" \
    "--libr ${mgba} /rom.gba" "-L ${mgba} /rom.gba --verbose" "-L ${mgba} -v /rom.gba" "-L ${mgba} rom.gba" "-L ${mgba} --conf=/x"; do
    reset active
    read -r -a argv <<<"${case}"
    run "${argv[@]}"
    [[ "${rc}" == 1 ]] || fail "args '${case}' exit ${rc}, expected 1"
    ran && fail "args '${case}': systemd-run called"
done

grep -qxF 'input_driver = "udev"' "${cfg}" || fail "microemu.cfg: input_driver is not udev"
grep -qxF 'input_menu_toggle = "nul"' "${cfg}" || fail "microemu.cfg: the menu still has a keyboard key (RC)"
grep -qxF 'input_menu_toggle_gamepad_combo = "2"' "${cfg}" || fail "microemu.cfg: the menu is not on L3 + R3"
grep -qi 'f15' "${cfg}" && fail "microemu.cfg names F15"
grep -qxF 'libretro_info_path = "/usr/share/libretro/info"' "${cfg}" || fail "microemu.cfg: info path is not Fedora's"
grep -qxF 'joypad_autoconfig_dir = "/usr/share/libretro/autoconfig"' "${cfg}" || fail "microemu.cfg: autoconfig dir is not Fedora's"
reset active
run -L "${mgba}" /rom.gba
grep -q '^--appendconfig' "${STATE}/argv" && [[ "$(grep -c -- '--appendconfig' "${STATE}/argv")" == 1 ]] || fail "not exactly one --appendconfig"

for case in "/var/lib/microos/openh264:/appimage/usr/lib|/appimage/usr/lib" "/a:/var/lib/microos/openh264:/b|/a:/b" \
    "/var/lib/microos/openh264|unset" "/var/lib/microos/openhx|/var/lib/microos/openhx"; do
    reset active
    rc=0
    LD_LIBRARY_PATH="${case%|*}" "${wrapper}" -L "${mgba}" /rom.gba 2> "${STATE}/stderr" || rc=$?
    [[ "$(cat "${STATE}/ld")" == "${case#*|}" ]] || fail "openh264 strip of ${case%|*}: $(cat "${STATE}/ld"), expected ${case#*|}"
done

reset active
"${wrapper}" -L "${mgba}" /rom.gba 2> "${STATE}/stderr" &
wpid=$!
wait "${wpid}" || true
[[ "$(cat "${STATE}/marker-at-run")" == "${wpid}" ]] || fail "launch marker during systemd-run: $(cat "${STATE}/marker-at-run"), expected ${wpid}"
[[ ! -e "${MICROEMU_RUNTIME_DIR}/launching" ]] || fail "launch marker left after the game"

reset active
echo 2 > "${STATE}/game_free_sleep"
"${wrapper}" -L "${mgba}" /rom.gba 2> "${STATE}/stderr" &
wpid=$!
for _ in $(seq 1 100); do grep -qx game-free "${STATE}/calls" && break; sleep 0.02; done
[[ "$(cat "${MICROEMU_RUNTIME_DIR}/launching" 2>/dev/null)" == "${wpid}" ]] || fail "no launch marker during the scope wait"
kill -TERM "${wpid}"
rc=0
wait "${wpid}" || rc=$?
[[ "${rc}" == 143 ]] || fail "TERM in the launch window: exit ${rc}"
[[ ! -e "${MICROEMU_RUNTIME_DIR}/launching" ]] || fail "TERM in the launch window: marker left"
rm -f "${STATE}/game_free_sleep"
sleep 2.2
ran && fail "TERM in the launch window: the game started"

reset active
echo 1 > "${STATE}/game_free_rc"
run -L "${mgba}" /rom.gba
[[ ! -e "${MICROEMU_RUNTIME_DIR}/launching" ]] || fail "refused launch: marker left"

if (( failures )); then
    echo "retroarch-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "retroarch-test: ok"
