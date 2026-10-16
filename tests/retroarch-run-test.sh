#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microemu"
wrapper="${libexec}/bin/retroarch"
mgba=/usr/lib64/libretro/mgba_libretro.so
pcsx=/usr/lib64/libretro/pcsx_rearmed_libretro.so

for need in /usr/bin/retroarch "${mgba}" "${pcsx}"; do
    if [[ ! -e "${need}" ]]; then
        echo "retroarch-run-test: skipped, ${need} missing"
        exit 0
    fi
done
command -v xorriso >/dev/null || { echo "retroarch-run-test: skipped, xorriso missing"; exit 0; }

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export HOME="${T}/home"
export MICROEMU_RETROARCH_CONFIG="${HOME}/.config/microemu/retroarch/retroarch.cfg"
export MICROEMU_RETROARCH_DATA="${HOME}/.local/share/microemu/retroarch"
export MICROEMU_RETROARCH_SHARE="${repo}/data/usr/share/microemu/retroarch"
export MICROEMU_RETROARCH_APPEND="${T}/microemu.cfg"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_PINNED="${T}/pinned-keys"
export MICROEMU_GAME_FREE="${libexec}/microemu-game-free"
export MICROEMU_RECONCILE="${T}/bin/reconcile"
cfg="${MICROEMU_RETROARCH_CONFIG}"
card="${T}/card"

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
case "$*" in
    "--user is-active --quiet gamescope-session-plus@microemu.service") exit 0 ;;
    "--user show -P ActiveState microemu-game.scope") echo inactive ;;
    "--user reset-failed microemu-game.scope") exit 0 ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/systemd-run" <<'STUB'
#!/usr/bin/bash
while [[ "$1" != -- ]]; do shift; done
shift
read -r -a extra < "${STATE}/extra"
echo "$$" > "${STATE}/ra_pid"
exec "$@" --verbose "--max-frames=$(cat "${STATE}/frames")" "${extra[@]}" > "${STATE}/ra.log" 2>&1
STUB
cat > "${T}/bin/reconcile" <<'STUB'
#!/usr/bin/bash
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
sed -E 's/^(input_driver|input_joypad_driver) = .*/\1 = "null"/' "${repo}/data/usr/share/microemu/retroarch/microemu.cfg" > "${MICROEMU_RETROARCH_APPEND}"
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

python3 - "${T}/x.gba" <<'PY'
import sys
rom = bytearray(4096)
rom[0:4] = (0xEA00002E).to_bytes(4, "little")
rom[0xA0:0xAC] = b"MICROEMUTEST"
rom[0xB2] = 0x96
rom[0xC0:0xC4] = (0xEAFFFFFE).to_bytes(4, "little")
check = 0
for b in rom[0xA0:0xBD]:
    check = (check - b) & 0xFF
rom[0xBD] = (check - 0x19) & 0xFF
open(sys.argv[1], "wb").write(rom)
PY
mkdir -p "${T}/iso"
printf 'BOOT = cdrom:\\SLUS_000.01;1\r\nTCB = 4\r\nEVENT = 10\r\nSTACK = 801FFFF0\r\n' > "${T}/iso/SYSTEM.CNF"
head -c 4096 /dev/zero > "${T}/iso/SLUS_000.01"
xorriso -as mkisofs -quiet -V GAME -o "${T}/Game.iso" "${T}/iso" 2>/dev/null

reset() {
    rm -rf "${STATE}" "${HOME}" "${card}" "${T:?}/run" "${MICROEMU_PINNED}"
    mkdir -p "${STATE}" "$(dirname "${cfg}")" "${HOME}/BIOS/retroarch" "${MICROEMU_RUNTIME_DIR}"
    : > "${STATE}/extra"
    echo 120 > "${STATE}/frames"
    printf '%s\n' 'video_driver = "null"' 'audio_driver = "null"' 'microphone_driver = "null"' 'midi_driver = "null"' \
        'sort_savefiles_enable = "true"' 'sort_savestates_enable = "true"' 'savestate_auto_save = "true"' > "${cfg}"
}

layout() {
    local base
    case "$1" in
        names) base=${card}/ROMs; mkdir -p "${card}/BIOS/retroarch"
            printf '%s\n' layout=names "root=${card}" "roms=${base}" "bios=${card}/BIOS/retroarch" "saves=${card}/Saves" \
                "states=${card}/States" "screenshots=${card}/Screenshots" "media=${card}/Media" saves_in_content=false ;;
        emudeck) base=${card}/Emulation/roms; mkdir -p "${card}/Emulation/bios"
            printf '%s\n' layout=emudeck "root=${card}" "roms=${base}" "bios=${card}/Emulation/bios" \
                "saves=${card}/Emulation/saves/microemu/saves" "states=${card}/Emulation/saves/microemu/states" \
                "screenshots=${card}/Emulation/storage/retroarch/screenshots" "media=${card}/Emulation/tools/downloaded_media" \
                saves_in_content=false ;;
        rocknix) base=${card}/roms; mkdir -p "${card}/roms/bios"
            printf '%s\n' layout=rocknix "root=${card}" "roms=${base}" "bios=${card}/roms/bios" saves= \
                "states=${card}/roms/savestates" "screenshots=${card}/roms/screenshots" "media=${card}/roms/downloaded_media" \
                saves_in_content=true ;;
    esac > "${MICROEMU_RUNTIME_DIR}/paths"
    mkdir -p "${base}/gba" "${base}/psx/Game"
    cp "${T}/x.gba" "${base}/gba/x.gba"
    cp "${T}/Game.iso" "${base}/psx/Game/Game.iso"
    printf 'Game.iso\n' > "${base}/psx/Game/Game.m3u"
    roms=${base}
}

play() {
    rc=0
    "${wrapper}" -L "$1" "$2" 2> "${STATE}/stderr" || rc=$?
    [[ "${rc}" == 0 ]] || fail "$3: exit ${rc}: $(tail -n 5 "${STATE}/ra.log" 2>/dev/null) $(cat "${STATE}/stderr")"
}

logs() { grep -qF -- "$1" "${STATE}/ra.log" || fail "$2: no log line '$1'"; }

for name in names emudeck rocknix; do
    reset
    layout "${name}"
    case "${name}" in
        names) bios=${card}/BIOS/retroarch saves=${card}/Saves/mGBA states=${card}/States/mGBA
            psx_save=${card}/Saves/PCSX-ReARMed psx_state=${card}/States/PCSX-ReARMed ;;
        emudeck) bios=${card}/Emulation/bios saves=${card}/Emulation/saves/microemu/saves/mGBA
            states=${card}/Emulation/saves/microemu/states/mGBA psx_save=${card}/Emulation/saves/microemu/saves/PCSX-ReARMed
            psx_state=${card}/Emulation/saves/microemu/states/PCSX-ReARMed ;;
        rocknix) bios=${card}/roms/bios saves=${roms}/gba states=${card}/roms/savestates/gba
            psx_save=${roms}/psx/Game psx_state=${card}/roms/savestates/psx ;;
    esac
    play "${mgba}" "${roms}/gba/x.gba" "${name} gba"
    logs "GET_SYSTEM_DIRECTORY: \"${bios}\"" "${name} gba"
    [[ -f "${saves}/x.srm" ]] || fail "${name} gba: no ${saves}/x.srm: $(cd "${card}" && find . -name '*.srm')"
    [[ -f "${states}/x.state.auto" ]] || fail "${name} gba: no ${states}/x.state.auto: $(cd "${card}" && find . -name '*.state*')"
    [[ -z "$(find "${HOME}" -name '*.srm' -o -name '*.state*')" ]] || fail "${name} gba: a save on internal storage"
    if [[ "${name}" == rocknix ]]; then
        echo "retroarch-run-test: retroarch.cfg after the rocknix run: $(grep -E '^sort_save(file|state)s_enable' "${cfg}" | tr '\n' ' ')"
    fi
    play "${pcsx}" "${roms}/psx/Game/Game.m3u" "${name} nested psx"
    [[ -f "${psx_save}/Game.srm" ]] || fail "${name} nested psx: no ${psx_save}/Game.srm: $(cd "${card}" && find . -name '*.srm')"
    [[ -f "${psx_state}/Game.state.auto" ]] || fail "${name} nested psx: no ${psx_state}/Game.state.auto: $(cd "${card}" && find . -name '*.state*')"
done

reset
layout rocknix
play "${mgba}" "${roms}/gba/x.gba" "rocknix seed"
mv "${card}/roms/savestates/gba/x.state.auto" "${card}/roms/savestates/gba/x.state1"
rm -f "${card}/roms/savestates/gba/x.state.auto.png"
head -c "$(stat -c %s "${roms}/gba/x.srm")" /dev/urandom > "${STATE}/x.srm.seed"
cp "${STATE}/x.srm.seed" "${roms}/gba/x.srm"
echo "--entryslot 1" > "${STATE}/extra"
play "${mgba}" "${roms}/gba/x.gba" "rocknix existing saves"
grep -qF 'Skipping SRAM load' "${STATE}/ra.log" && fail "rocknix existing srm: not loaded"
cmp -s "${STATE}/x.srm.seed" "${roms}/gba/x.srm" || fail "rocknix existing srm: the saved SRAM is not the loaded one"
logs "Loading entry state from \"${card}/roms/savestates/gba/x.state1\" succeeded" "rocknix existing state1"

reset
layout names
echo 100000000 > "${STATE}/frames"
"${wrapper}" -L "${mgba}" "${roms}/gba/x.gba" 2> "${STATE}/stderr" &
wpid=$!
for (( n = 0; n < 100; n++ )); do
    ! grep -qF 'Saved config to' "${STATE}/ra.log" 2>/dev/null || break
    sleep 0.1
done
sed -i '/^savefile_directory/d' "${cfg}"
kill -TERM "$(cat "${STATE}/ra_pid")"
wait "${wpid}" || true
echo "retroarch-run-test: config after SIGTERM: $(grep -c '^savefile_directory' "${cfg}") savefile_directory lines (1 means saved on SIGTERM)"

if (( failures )); then
    echo "retroarch-run-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "retroarch-run-test: ok"
