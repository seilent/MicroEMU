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
export MICROEMU_PINNED="${T}/state-home/microemu/pinned-keys"
home="${T}/home"
card="${T}/card"
paths_cfg="${MICROEMU_RUNTIME_DIR}/retroarch-paths.cfg"

write_pick() {
    mkdir -p "${MICROEMU_RUNTIME_DIR}"
    case "$1" in
        names) printf '%s\n' layout=names "root=${home}" "roms=${home}/ROMs" "bios=${home}/BIOS/retroarch" "saves=${home}/Saves" \
            "states=${home}/States" "screenshots=${home}/Screenshots" "media=${home}/Media" saves_in_content=false ;;
        cardnames) printf '%s\n' layout=names "root=${card}" "roms=${card}/ROMs" "bios=${card}/BIOS/retroarch" "saves=${card}/Saves" \
            "states=${card}/States" "screenshots=${card}/Screenshots" "media=${card}/Media" saves_in_content=false ;;
        emudeck) printf '%s\n' layout=emudeck "root=${card}" "roms=${card}/Emulation/roms" "bios=${card}/Emulation/bios" \
            "saves=${card}/Emulation/saves/microemu/saves" "states=${card}/Emulation/saves/microemu/states" \
            "screenshots=${card}/Emulation/storage/retroarch/screenshots" "media=${card}/Emulation/tools/downloaded_media" \
            saves_in_content=false ;;
        rocknix) printf '%s\n' layout=rocknix "root=${card}" "roms=${card}/roms" "bios=${card}/roms/bios" saves= \
            "states=${card}/roms/savestates" "screenshots=${card}/roms/screenshots" "media=${card}/roms/downloaded_media" \
            saves_in_content=true ;;
    esac > "${MICROEMU_RUNTIME_DIR}/paths"
}

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${T}/config" "${T}/data" "${home}" "${card}" "${MICROEMU_RUNTIME_DIR}" "${T}/state-home"
    mkdir -p "${STATE}" "${home}/ROMs/gba" "${home}/BIOS/retroarch"
    : > "${rom}"
    write_pick names
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
rom="${home}/ROMs/gba/rom.gba"

reset active
: > "${home}/ROMs/gba/Some Game (USA).gba"
run -L "${mgba}" "${home}/ROMs/gba/Some Game (USA).gba"
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
/usr/share/microemu/retroarch/microemu.cfg|${paths_cfg}
-L
${mgba}
${home}/ROMs/gba/Some Game (USA).gba"
[[ "$(cat "${STATE}/argv")" == "${expected}" ]] || fail "launch argv: $(cat "${STATE}/argv")"
[[ "$(cat "${STATE}/ld")" == /appimage/usr/lib ]] || fail "launch: LD_LIBRARY_PATH changed: $(cat "${STATE}/ld")"
[[ "$(cat "${STATE}/calls")" == "systemctl --user is-active --quiet gamescope-session-plus@microemu.service
game-free
reconcile retroarch ${confdir}
systemd-run
game-free
reconcile retroarch ${confdir}" ]] \
    || fail "launch: calls $(cat "${STATE}/calls")"
[[ -f "${MICROEMU_RETROARCH_CONFIG}" ]] || fail "launch: config not created"
for dir in saves states system screenshots; do
    [[ ! -e "${MICROEMU_RETROARCH_DATA}/${dir}" ]] || fail "launch: ${dir} directory created under the data dir"
done
for dir in Saves States Screenshots; do
    [[ -d "${home}/${dir}" && ! -L "${home}/${dir}" ]] || fail "launch: ${home}/${dir} not created"
done
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "names launch: a pinned keys record written"

reset active
mkdir -p "$(dirname "${MICROEMU_RETROARCH_CONFIG}")"
echo 'video_driver = "gl"' > "${MICROEMU_RETROARCH_CONFIG}"
run -L "${mgba}" "${rom}"
[[ "$(cat "${MICROEMU_RETROARCH_CONFIG}")" == 'video_driver = "gl"' ]] || fail "existing config overwritten"

reset active
echo 4 > "${STATE}/reconcile_rc"
run -L "${mgba}" "${rom}"
[[ "${rc}" == 0 ]] && ran || fail "a failed reconcile stopped the launch: exit ${rc}"
grep -qx "reconcile failed" "${STATE}/log" || fail "a failed reconcile not logged"

reset active
mkdir -p "${confdir}/config/Gambatte"
echo 'gambatte_gb_colorization = "disabled"' > "${confdir}/config/Gambatte/Gambatte.opt"
run -L "${mgba}" "${rom}"
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
free_line=$(grep -n '^"${GAME_FREE}"' "${wrapper}" | head -n 1 | cut -d: -f1)
reconcile_line=$(grep -n '^"${RECONCILE}" retroarch' "${wrapper}" | head -n 1 | cut -d: -f1)
(( copy_line < free_line && free_line < reconcile_line )) || fail "core files copied ${copy_line}, scope wait ${free_line}, reconcile ${reconcile_line}: wrong order"
[[ ! -e "${share}/defaults" ]] || fail "the defaults table is shipped next to the reconcile"

reset active
mkdir -p "${MICROEMU_RETROARCH_DATA}/remaps/mGBA"
echo 'input_player1_btn_a = "8"' > "${MICROEMU_RETROARCH_DATA}/remaps/mGBA/mGBA.rmp"
run -L "${mgba}" "${rom}"
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
HOME="${T}/home" MICROEMU_RETROARCH_CONFIG='' MICROEMU_RETROARCH_DATA="${T}/home/.local/share/microemu/retroarch" "${wrapper}" -L "${mgba}" "${rom}" 2> "${STATE}/stderr" || rc=$?
[[ -f "${T}/home/.config/microemu/retroarch/retroarch.cfg" && -d "${T}/home/.config/microemu/retroarch/config/Gambatte" ]] || fail "default config root: $(find "${T}/home" -maxdepth 4)"
cfg="${share}/microemu.cfg"
grep -qxF 'rgui_config_directory = "~/.config/microemu/retroarch/config"' "${cfg}" || fail "microemu.cfg: config dir is not the wrapper's"
grep -qxF 'video_shader_dir = "/usr/share/microemu/retroarch/shaders"' "${cfg}" || fail "microemu.cfg: no shader dir"
for key in input_remapping_directory:remaps playlist_directory:playlists log_dir:logs runtime_log_directory:logs/runtime thumbnails_directory:thumbnails core_assets_directory:downloads cache_directory:cache; do
    grep -qxF "${key%%:*} = \"~/.local/share/microemu/retroarch/${key#*:}\"" "${cfg}" || fail "microemu.cfg: ${key%%:*} not under ~/.local/share/microemu/retroarch"
done
grep -q '^video_driver' "${cfg}" && fail "microemu.cfg forces a video driver"
grep -qxF 'video_fullscreen = "true"' "${cfg}" || fail "microemu.cfg: not fullscreen"
grep -qxF 'desktop_menu_enable = "false"' "${cfg}" || fail "microemu.cfg: the Qt companion is not off"
grep -qxF '#reference "../../shaders_slang/retro crisis/1080p Flat/RC GDV-NTSC - NES - Clean.slangp"' "${share}/shaders/presets/Nestopia/Nestopia.slangp" || fail "Nestopia preset is not Retro Crisis NES Clean"
grep -qxF '#reference "../../shaders_slang/retro crisis/1080p Flat/RC GDV-NTSC - SNES - Clean.slangp"' "${share}/shaders/presets/bsnes-mercury/bsnes-mercury.slangp" || fail "bsnes-mercury preset is not Retro Crisis SNES Clean"

reset active
echo 1 > "${STATE}/game_free_rc"
run -L "${mgba}" "${rom}"
[[ "${rc}" == 1 ]] || fail "scope still stopping: exit ${rc}"
ran && fail "scope still stopping: systemd-run called"
grep -qx "microemu-game.scope is still stopping" "${STATE}/log" || fail "scope still stopping: no log line"
for core in Nestopia bsnes-mercury; do
    [[ -f "${share}/shaders/presets/${core}/${core}.slangp" ]] || fail "${core}: no shader preset"
done
[[ "$(cd "${share}/shaders/presets" && find . -type f | wc -l)" == 2 ]] || fail "presets: $(cd "${share}/shaders/presets" && find . -type f)"

reset active 3
run -L "${mgba}" "${rom}"
[[ "${rc}" == 3 ]] || fail "exit code ${rc}, expected 3"

reset inactive
run -L "${mgba}" "${rom}"
[[ "${rc}" == 1 ]] || fail "outside microemu exit ${rc}, expected 1"
ran && fail "outside microemu: systemd-run called"
grep -qx "gamescope-session-plus@microemu.service is not active, refusing" "${STATE}/log" || fail "outside microemu: no log line"

for core in /usr/lib64/libretro/../../../tmp/x_libretro.so /tmp/mgba_libretro.so /usr/lib64/libretro/mgba.so \
    "/usr/lib64/libretro/mgba_libretro.so;id" /usr/lib64/libretro/sub/mgba_libretro.so; do
    reset active
    run -L "${core}" "${rom}"
    [[ "${rc}" == 1 ]] || fail "core ${core} exit ${rc}, expected 1"
    ran && fail "core ${core}: systemd-run called"
done

for case in "-L${mgba} ${rom}" "--libretro=${mgba} ${rom}" "-L ${mgba} -c /tmp/x.cfg ${rom}" \
    "-L ${mgba} --config=/tmp/x.cfg ${rom}" "-L ${mgba} --appendconfig /tmp/x.cfg ${rom}" "-L ${mgba} -L ${mgba} ${rom}" \
    "${rom}" "-L" "-L ${mgba} -vL /tmp/x_libretro.so ${rom}" "-L ${mgba} -fc /tmp/x.cfg ${rom}" "-vc /tmp/x.cfg -L ${mgba} ${rom}" \
    "-L ${mgba} -Lc ${rom}" "-L ${mgba} --conf=/tmp/x.cfg ${rom}" "-L ${mgba} --appendc=/tmp/x.cfg ${rom}" \
    "--libr ${mgba} ${rom}" "-L ${mgba} ${rom} --verbose" "-L ${mgba} -v ${rom}" "-L ${mgba} rom.gba" "-L ${mgba} --conf=/x"; do
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
run -L "${mgba}" "${rom}"
grep -q '^--appendconfig' "${STATE}/argv" && [[ "$(grep -c -- '--appendconfig' "${STATE}/argv")" == 1 ]] || fail "not exactly one --appendconfig"

for case in "/var/lib/microos/openh264:/appimage/usr/lib|/appimage/usr/lib" "/a:/var/lib/microos/openh264:/b|/a:/b" \
    "/var/lib/microos/openh264|unset" "/var/lib/microos/openhx|/var/lib/microos/openhx"; do
    reset active
    rc=0
    LD_LIBRARY_PATH="${case%|*}" "${wrapper}" -L "${mgba}" "${rom}" 2> "${STATE}/stderr" || rc=$?
    [[ "$(cat "${STATE}/ld")" == "${case#*|}" ]] || fail "openh264 strip of ${case%|*}: $(cat "${STATE}/ld"), expected ${case#*|}"
done

reset active
"${wrapper}" -L "${mgba}" "${rom}" 2> "${STATE}/stderr" &
wpid=$!
wait "${wpid}" || true
[[ "$(cat "${STATE}/marker-at-run")" == "${wpid}" ]] || fail "launch marker during systemd-run: $(cat "${STATE}/marker-at-run"), expected ${wpid}"
[[ ! -e "${MICROEMU_RUNTIME_DIR}/launching" ]] || fail "launch marker left after the game"

reset active
echo 2 > "${STATE}/game_free_sleep"
"${wrapper}" -L "${mgba}" "${rom}" 2> "${STATE}/stderr" &
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
run -L "${mgba}" "${rom}"
[[ ! -e "${MICROEMU_RUNTIME_DIR}/launching" ]] || fail "refused launch: marker left"

expect_cfg() {
    printf '%s\n' "savefile_directory=$1" "savestate_directory=$2" "system_directory=$3" "screenshot_directory=$4" \
        "savefiles_in_content_dir=$5" savestates_in_content_dir=false systemfiles_in_content_dir=false \
        screenshots_in_content_dir=false sort_savefiles_by_content_enable=false sort_savestates_by_content_enable=false \
        sort_screenshots_by_content_enable=false "${@:6}" | sort
}
got_cfg() { sed -nE 's/^([a-z_]+) = "(.*)"$/\1=\2/p' "${paths_cfg}" | sort; }

reset active
run -L "${mgba}" "${rom}"
[[ "$(got_cfg)" == "$(expect_cfg "${home}/Saves" "${home}/States" "${home}/BIOS/retroarch" "${home}/Screenshots" false)" ]] \
    || fail "internal names cfg: $(cat "${paths_cfg}")"
[[ "$(wc -l < "${paths_cfg}")" == 11 ]] || fail "internal names cfg: $(wc -l < "${paths_cfg}") lines"

reset active
mkdir -p "${card}/ROMs/gba" "${card}/BIOS/retroarch"
: > "${card}/ROMs/gba/x.gba"
write_pick cardnames
run -L "${mgba}" "${card}/ROMs/gba/x.gba"
[[ "${rc}" == 0 ]] || fail "card names: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(got_cfg)" == "$(expect_cfg "${card}/Saves" "${card}/States" "${card}/BIOS/retroarch" "${card}/Screenshots" false)" ]] \
    || fail "card names cfg: $(cat "${paths_cfg}")"
for dir in Saves States Screenshots; do
    [[ -d "${card}/${dir}" ]] || fail "card names: ${dir} not created on the card"
done
[[ ! -e "${home}/Saves" ]] || fail "card names: internal Saves created"

reset active
mkdir -p "${card}/Emulation/roms/gba" "${card}/Emulation/bios" "${card}/Emulation/saves/retroarch"
: > "${card}/Emulation/roms/gba/x.gba"
ln -s /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/saves "${card}/Emulation/saves/retroarch/saves"
ln -s /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/states "${card}/Emulation/saves/retroarch/states"
write_pick emudeck
run -L "${mgba}" "${card}/Emulation/roms/gba/x.gba"
[[ "${rc}" == 0 ]] || fail "emudeck: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(got_cfg)" == "$(expect_cfg "${card}/Emulation/saves/microemu/saves" "${card}/Emulation/saves/microemu/states" \
    "${card}/Emulation/bios" "${card}/Emulation/storage/retroarch/screenshots" false)" ]] || fail "emudeck cfg: $(cat "${paths_cfg}")"
for dir in saves/microemu/saves saves/microemu/states storage/retroarch/screenshots; do
    [[ -d "${card}/Emulation/${dir}" && ! -L "${card}/Emulation/${dir}" ]] || fail "emudeck: ${dir} not created"
done
[[ "$(readlink "${card}/Emulation/saves/retroarch/saves")" == /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/saves &&
    "$(readlink "${card}/Emulation/saves/retroarch/states")" == /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/states ]] \
    || fail "emudeck: EmuDeck's links changed"

reset active
mkdir -p "${card}/roms/gba" "${card}/roms/bios" "${confdir}"
: > "${card}/roms/gba/x.gba"
printf 'sort_savefiles_enable = "true"\nvideo_driver = "vulkan"\n' > "${MICROEMU_RETROARCH_CONFIG}"
write_pick rocknix
run -L "${mgba}" "${card}/roms/gba/x.gba"
[[ "${rc}" == 0 ]] || fail "rocknix: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(got_cfg)" == "$(expect_cfg "${card}/roms" "${card}/roms/savestates/gba" "${card}/roms/bios" "${card}/roms/screenshots" true \
    sort_savefiles_enable=false sort_savestates_enable=false)" ]] || fail "rocknix cfg: $(cat "${paths_cfg}")"
[[ "$(cd "${card}" && find . -type d | sort)" == "$(printf '%s\n' . ./roms ./roms/bios ./roms/gba ./roms/savestates ./roms/savestates/gba ./roms/screenshots)" ]] \
    || fail "rocknix: folders $(cd "${card}" && find . -type d | sort)"
[[ "$(cat "${MICROEMU_PINNED}" 2>/dev/null)" == $'sort_savefiles_enable=true\nsort_savestates_enable' ]] || fail "rocknix: record $(cat "${MICROEMU_PINNED}" 2>&1)"
[[ "$(grep -n '^reconcile' "${STATE}/calls" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^systemd-run' "${STATE}/calls" | cut -d: -f1)" ]] || fail "rocknix: calls $(cat "${STATE}/calls")"
printf 'sort_savefiles_enable=false\nsort_savestates_enable=false\n' > "${MICROEMU_PINNED}"
run -L "${mgba}" "${card}/roms/gba/x.gba"
[[ "$(cat "${MICROEMU_PINNED}")" == $'sort_savefiles_enable=false\nsort_savestates_enable=false' ]] || fail "rocknix: a present record replaced"

reset active
mkdir -p "${card}/roms/psx/Game" "${card}/roms/bios"
: > "${card}/roms/psx/Game/Game.m3u"
write_pick rocknix
run -L /usr/lib64/libretro/pcsx_rearmed_libretro.so "${card}/roms/psx/Game/Game.m3u"
[[ "${rc}" == 0 ]] || fail "rocknix nested: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx "savestate_directory = \"${card}/roms/savestates/psx\"" "${paths_cfg}" || fail "rocknix nested: $(grep savestate_directory "${paths_cfg}")"
[[ ! -e "${card}/roms/savestates/Game" ]] || fail "rocknix nested: state folder named after the game folder"

reset active
mkdir -p "${card}/roms/bios"
: > "${card}/roms/x.gba"
write_pick rocknix
run -L "${mgba}" "${card}/roms/x.gba"
[[ "${rc}" == 1 ]] && ! ran || fail "rocknix rom outside a system folder: exit ${rc}"

refused() {
    [[ "${rc}" == 1 ]] || fail "$1: exit ${rc}, expected 1"
    ran && fail "$1: systemd-run called"
    grep -q "$2" "${STATE}/log" || fail "$1: no log line: $(cat "${STATE}/log")"
}

reset active
rm -f "${MICROEMU_RUNTIME_DIR}/paths"
run -L "${mgba}" "${rom}"
refused "no paths file" "paths is missing, refusing"

reset active
printf 'layout=names\nroms=%s\n' "${home}/ROMs" > "${MICROEMU_RUNTIME_DIR}/paths"
run -L "${mgba}" "${rom}"
refused "incomplete paths file" "is incomplete, refusing"

reset active
: > "${home}/outside.gba"
run -L "${mgba}" "${home}/ROMs/gba/../../outside.gba"
refused "rom through .." "is not under ${home}/ROMs, refusing"

reset active
: > "${T}/elsewhere.gba"
ln -s "${T}/elsewhere.gba" "${home}/ROMs/gba/link.gba"
run -L "${mgba}" "${home}/ROMs/gba/link.gba"
refused "rom symlink out" "is not under ${home}/ROMs, refusing"
rm -f "${T}/elsewhere.gba"

for kind in symlink outside component file; do
    reset active
    mkdir -p "${card}/ROMs/gba" "${card}/other" "${T}/out"
    : > "${card}/ROMs/gba/x.gba"
    case "${kind}" in
        symlink) ln -s other "${card}/Saves" ;;
        outside) ln -s "${T}/out" "${card}/Saves" ;;
        component) mkdir -p "${card}/real/microemu"; mkdir -p "${card}/Emulation/roms/gba"; : > "${card}/Emulation/roms/gba/x.gba"
            ln -s ../real "${card}/Emulation/saves" ;;
        file) : > "${card}/Saves" ;;
    esac
    if [[ "${kind}" == component ]]; then
        write_pick emudeck
        run -L "${mgba}" "${card}/Emulation/roms/gba/x.gba"
    else
        write_pick cardnames
        run -L "${mgba}" "${card}/ROMs/gba/x.gba"
    fi
    refused "save folder ${kind}" "is not a folder under ${card} or cannot be made, refusing"
    [[ -z "$(ls -A "${T}/out")" && ! -e "${card}/real/microemu/saves" ]] || fail "save folder ${kind}: made through the link"
    rm -rf "${T}/out"
done

mkdir -p "${T}/failbin"
cat > "${T}/failbin/mkdir" <<STUB
#!/usr/bin/bash
echo "mkdir \$*" >> "\${STATE}/mkdir"
[[ "\$*" != *"${card}"* ]] || exit 1
exec /usr/bin/mkdir "\$@"
STUB
chmod 0755 "${T}/failbin/mkdir"
reset active
mkdir -p "${card}/ROMs/gba"
: > "${card}/ROMs/gba/x.gba"
write_pick cardnames
PATH="${T}/failbin:${PATH}" run -L "${mgba}" "${card}/ROMs/gba/x.gba"
refused "failing mkdir" "is not a folder under ${card} or cannot be made, refusing"
grep -q "mkdir -- ${card}/Saves" "${STATE}/mkdir" || fail "failing mkdir: the stub was not called: $(cat "${STATE}/mkdir" 2>&1)"

for key in savefile_directory savestate_directory system_directory screenshot_directory; do
    grep -q "^${key}" "${share}/microemu.cfg" && fail "microemu.cfg sets ${key}"
done
overrides=$(grep -rlE '^[[:blank:]]*([a-z_]+_directory|[a-z_]+_in_content_dir|sort_[a-z_]+)[[:blank:]]*=' "${share}/config" || true)
[[ -z "${overrides}" ]] || fail "a shipped override sets a dir, in content or sort key: ${overrides}"

if (( failures )); then
    echo "retroarch-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "retroarch-test: ok"
