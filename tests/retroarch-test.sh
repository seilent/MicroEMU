#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
wrapper="${repo}/sysext/usr/libexec/microemu/bin/retroarch"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_RETROARCH_CONFIG="${T}/config/microemu/retroarch/retroarch.cfg"
export MICROEMU_RETROARCH_DATA="${T}/data/microemu/retroarch"
export MICROEMU_RETROARCH_SHARE="${repo}/sysext/usr/share/microemu/retroarch"
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
exit "$(cat "${STATE}/rc")"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
cat > "${T}/bin/game-free" <<'STUB'
#!/usr/bin/bash
echo "game-free" >> "${STATE}/calls"
exit "$(cat "${STATE}/game_free_rc" 2>/dev/null || echo 0)"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export MICROEMU_GAME_FREE="${T}/bin/game-free"

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
run -L "${mgba}" "/home/armada/ROMs/gba/Some Game (USA).gba"
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
/usr/bin/env
LD_LIBRARY_PATH=/usr/lib/microemu/retroarch/lib64
/usr/lib/microemu/retroarch/bin/retroarch
-c
${MICROEMU_RETROARCH_CONFIG}
--appendconfig
/usr/share/microemu/retroarch/microemu.cfg
-L
${mgba}
/home/armada/ROMs/gba/Some Game (USA).gba"
[[ "$(cat "${STATE}/argv")" == "${expected}" ]] || fail "launch argv: $(cat "${STATE}/argv")"
[[ "$(cat "${STATE}/ld")" == unset ]] || fail "launch: LD_LIBRARY_PATH reached systemd-run: $(cat "${STATE}/ld")"
[[ "$(cat "${STATE}/calls")" == $'systemctl --user is-active --quiet gamescope-session-plus@microemu.service\ngame-free\nsystemd-run' ]] \
    || fail "launch: calls $(cat "${STATE}/calls")"
[[ -f "${MICROEMU_RETROARCH_CONFIG}" ]] || fail "launch: config not created"
for dir in saves states system screenshots; do
    [[ -d "${MICROEMU_RETROARCH_DATA}/${dir}" ]] || fail "launch: ${dir} directory not created"
done

reset active
mkdir -p "$(dirname "${MICROEMU_RETROARCH_CONFIG}")"
echo 'video_driver = "gl"' > "${MICROEMU_RETROARCH_CONFIG}"
for v in 1 4 5 6; do : > "${confdir}/.defaults-${v}"; done
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == 'video_driver = "gl"' ]] || fail "existing config overwritten"

seeded='video_driver = "vulkan"
video_scale_integer = "false"
audio_block_frames = "192"
fps_show = "true"
sort_savefiles_enable = "true"
sort_savestates_enable = "true"
savestate_auto_index = "true"
savestate_auto_load = "true"
savestate_auto_save = "true"
savestate_max_keep = "10"
quit_on_close_content = "1"
quit_press_twice = "false"
menu_shader_pipeline = "1"
video_shader_enable = "true"
input_player1_analog_dpad_mode = "1"'

reset active
run -L "${mgba}" /rom.gba
[[ "${rc}" == 0 ]] || fail "defaults on a fresh config: exit ${rc}"
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == "${seeded}" ]] || fail "defaults on a fresh config: $(cat "${MICROEMU_RETROARCH_CONFIG}")"
[[ -e "${confdir}/.defaults-1" && -e "${confdir}/.defaults-4" && -e "${confdir}/.defaults-5" && -e "${confdir}/.defaults-6" ]] || fail "defaults markers: $(ls -a "${confdir}")"

reset active
mkdir -p "${confdir}"
printf 'aspect_ratio_index = "22"\nvideo_driver = "gl"\nvideo_scale_integer = "false"\naudio_block_frames = "0"\nfps_show = "false"\nsort_savefiles_enable = "true"\nsort_savestates_enable = "true"\nsavestate_auto_index = "false"\nsavestate_auto_load = "false"\nsavestate_auto_save = "false"\nsavestate_max_keep = "0"\nquit_on_close_content = "0"\nquit_press_twice = "true"\nmenu_shader_pipeline = "2"\nvideo_shader_enable = "false"\nvideo_threaded = "false"\n' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == "aspect_ratio_index = \"22\"
${seeded%$'\n'*}
video_threaded = \"false\"
${seeded##*$'\n'}" ]] || fail "defaults over RetroArch's own: $(cat "${MICROEMU_RETROARCH_CONFIG}")"

reset active
mkdir -p "${confdir}"
printf 'video_driver = "glcore"\nfps_show = "false"\nsavestate_max_keep = "5"\nquit_press_twice = "true"\n' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
grep -qx 'video_driver = "vulkan"' "${MICROEMU_RETROARCH_CONFIG}" || fail "glcore not moved to vulkan on a new config"
grep -qx 'savestate_max_keep = "5"' "${MICROEMU_RETROARCH_CONFIG}" || fail "a changed savestate_max_keep was replaced"
grep -qx 'fps_show = "true"' "${MICROEMU_RETROARCH_CONFIG}" || fail "a default fps_show was not set"
grep -qx 'quit_press_twice = "false"' "${MICROEMU_RETROARCH_CONFIG}" || fail "a default quit_press_twice was not set"
[[ "$(grep -c '^video_driver = ' "${MICROEMU_RETROARCH_CONFIG}")" == 1 ]] || fail "video_driver written twice"

reset active
mkdir -p "${confdir}" "${T}/dotfiles"
echo 'fps_show = "false"' > "${T}/dotfiles/retroarch.cfg"
ln -s "${T}/dotfiles/retroarch.cfg" "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
[[ -L "${MICROEMU_RETROARCH_CONFIG}" ]] || fail "a symlinked retroarch.cfg was replaced by a file"
grep -qx 'fps_show = "true"' "${T}/dotfiles/retroarch.cfg" || fail "defaults not written through the symlink"
[[ ! -e "${MICROEMU_RETROARCH_CONFIG}.new" ]] || fail "temp file left beside a symlinked config"
rm -rf "${T}/dotfiles"

reset active
mkdir -p "${confdir}"
: > "${confdir}/.defaults-1"
: > "${confdir}/.defaults-4"
: > "${confdir}/.defaults-5"
: > "${confdir}/.defaults-6"
echo 'fps_show = "false"' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == 'fps_show = "false"' ]] || fail "defaults applied again with the markers present"

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
grep -rq video_threaded "${confdir}" && fail "threaded video set on a new config: $(grep -r video_threaded "${confdir}")"
[[ ! -e "${confdir}/config/PCSX-ReARMed" ]] || fail "a PCSX-ReARMed override created on a new config"

reset active
mkdir -p "${confdir}/config/Nestopia" "${confdir}/config/bsnes-mercury" "${confdir}/config/PCSX-ReARMed"
: > "${confdir}/.defaults-1"
: > "${confdir}/.defaults-2"
: > "${confdir}/.defaults-3"
printf 'video_driver = "glcore"\naudio_block_frames = "0"\nfps_show = "false"\nsavestate_max_keep = "0"\nmenu_shader_pipeline = "2"\nvideo_threaded = "false"\n' > "${MICROEMU_RETROARCH_CONFIG}"
{ cat "${share}/config/Nestopia/Nestopia.cfg"; echo 'video_threaded = "true"'; } > "${confdir}/config/Nestopia/Nestopia.cfg"
{ cat "${share}/config/bsnes-mercury/bsnes-mercury.cfg"; echo 'video_threaded = "false"'; } > "${confdir}/config/bsnes-mercury/bsnes-mercury.cfg"
printf 'video_threaded = "true"\nvideo_smooth = "true"\n' > "${confdir}/config/PCSX-ReARMed/PCSX-ReARMed.cfg"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == $'video_driver = "vulkan"\naudio_block_frames = "192"\nfps_show = "false"\nsavestate_max_keep = "10"\nmenu_shader_pipeline = "1"\nvideo_threaded = "false"\ninput_player1_analog_dpad_mode = "1"' ]] \
    || fail "version 4 on the PM2 state: $(cat "${MICROEMU_RETROARCH_CONFIG}")"
[[ "$(tail -n 1 "${confdir}/config/Nestopia/Nestopia.cfg")" == 'video_threaded = "false"' && "$(grep -c '^video_threaded' "${confdir}/config/Nestopia/Nestopia.cfg")" == 1 ]] \
    || fail "version 4: Nestopia threaded video: $(cat "${confdir}/config/Nestopia/Nestopia.cfg")"
[[ "$(tail -n 1 "${confdir}/config/bsnes-mercury/bsnes-mercury.cfg")" == 'video_threaded = "false"' ]] || fail "version 4: a hand set bsnes-mercury value changed"
[[ "$(cat "${confdir}/config/PCSX-ReARMed/PCSX-ReARMed.cfg")" == $'video_threaded = "false"\nvideo_smooth = "true"' ]] || fail "version 4: PCSX override: $(cat "${confdir}/config/PCSX-ReARMed/PCSX-ReARMed.cfg")"
[[ -e "${confdir}/.defaults-4" ]] || fail "version 4 marker not written"

reset active
mkdir -p "${confdir}" "${MICROEMU_RETROARCH_DATA}/remaps/mGBA"
: > "${confdir}/.defaults-1"
: > "${confdir}/.defaults-4"
printf 'video_scale_integer = "true"\nfps_show = "false"\n' > "${MICROEMU_RETROARCH_CONFIG}"
echo 'input_player1_btn_a = "8"' > "${MICROEMU_RETROARCH_DATA}/remaps/mGBA/mGBA.rmp"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == $'video_scale_integer = "false"\nfps_show = "false"\ninput_player1_analog_dpad_mode = "1"' ]] || fail "versions 5 and 6: $(cat "${MICROEMU_RETROARCH_CONFIG}")"
[[ "$(cat "${MICROEMU_RETROARCH_DATA}/remaps/mGBA/mGBA.rmp")" == 'input_player1_btn_a = "8"' ]] || fail "a user mGBA remap was replaced"
[[ -f "${MICROEMU_RETROARCH_DATA}/remaps/Gambatte/Gambatte.rmp" ]] || fail "a missing remap beside a user one was not copied"

reset active
mkdir -p "${confdir}"
for v in 1 4 5; do : > "${confdir}/.defaults-${v}"; done
echo 'input_player1_analog_dpad_mode = "3"' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == 'input_player1_analog_dpad_mode = "3"' ]] || fail "version 6 replaced a hand set analog_dpad_mode"

reset active
mkdir -p "${confdir}"
: > "${confdir}/.defaults-1"
printf 'video_driver = "gl"\nsavestate_max_keep = "3"\naudio_block_frames = "512"\n' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" /rom.gba
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == $'video_driver = "gl"\nsavestate_max_keep = "3"\naudio_block_frames = "512"\ninput_player1_analog_dpad_mode = "1"' ]] || fail "version 4 replaced values set by hand: $(cat "${MICROEMU_RETROARCH_CONFIG}")"
[[ ! -e "${confdir}/config/Nestopia/Nestopia.cfg" || "$(grep -c video_threaded "${confdir}/config/Nestopia/Nestopia.cfg")" == 0 ]] || fail "version 4 added threaded video to an override"
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
for core in Gambatte mGBA Nestopia bsnes-mercury; do
    [[ -f "${share}/shaders/presets/${core}/${core}.slangp" ]] || fail "${core}: no shader preset"
done

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
    "-L ${mgba} -Lc /rom.gba"; do
    reset active
    read -r -a argv <<<"${case}"
    run "${argv[@]}"
    [[ "${rc}" == 1 ]] || fail "args '${case}' exit ${rc}, expected 1"
    ran && fail "args '${case}': systemd-run called"
done

reset active
run -L "${mgba}" -v --verbose -f /rom.gba
[[ "${rc}" == 0 ]] || fail "plain options refused: $(cat "${STATE}/stderr")"
[[ "$(tail -n 4 "${STATE}/argv")" == $'-v\n--verbose\n-f\n/rom.gba' ]] || fail "plain options not passed: $(cat "${STATE}/argv")"

grep -qxF 'input_driver = "udev"' "${repo}/sysext/usr/share/microemu/retroarch/microemu.cfg" || fail "microemu.cfg: input_driver is not udev"

if (( failures )); then
    echo "retroarch-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "retroarch-test: ok"
