#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
client="${repo}/data/usr/libexec/microemu/microemu-client"
shipped="${repo}/data/usr/share/microemu/es-de/es_systems.xml"
export PYTHONDONTWRITEBYTECODE=1

mkdir() { /usr/bin/mkdir "$@"; }

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/share/themes"
export STATE="${T}/state"
export HOME="${T}/home"
export MICROEMU_ESDE="${T}/bin/es-de"
export MICROEMU_SYSTEMS_FILE="${shipped}"
export MICROEMU_THEMES_DIR="${T}/share/themes"
export MICROEMU_ESDE_APPDATA_DIR="${HOME}/.local/share/microemu/ES-DE"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_CONTENT_LINK="${T}/run/microos/content"
export MICROEMU_OSD="${T}/absent-osd"
export MICROEMU_GAME_STOP="${T}/bin/game-stop"
export MICROEMU_GAME_RUNNING="${T}/bin/game-running"
export MICROEMU_RECONCILE="${T}/bin/reconcile"
export MICROEMU_OPENH264_DIR="${T}/openh264"
export REAL_RECONCILE="${repo}/data/usr/libexec/microemu/microemu-reconcile"
media="${T}/media"

cat > "${T}/bin/es-de" <<'STUB'
#!/usr/bin/bash
n=$(( $(cat "${STATE}/runs" 2>/dev/null || echo 0) + 1 ))
echo "${n}" > "${STATE}/runs"
echo "es-de" >> "${STATE}/calls"
cp "${MICROEMU_RUNTIME_DIR}/paths" "${STATE}/paths.${n}" 2>/dev/null || true
cp "${ESDE_APPDATA_DIR}/settings/es_settings.xml" "${STATE}/es.${n}" 2>/dev/null || true
cp "${ESDE_APPDATA_DIR}/custom_systems/es_systems.xml" "${STATE}/systems.${n}" 2>/dev/null || true
[[ ! -e "${STATE}/hook.${n}" ]] || bash "${STATE}/hook.${n}"
[[ ! -e "${STATE}/ignore.${n}" ]] || trap '' TERM
if [[ -e "${STATE}/sleep.${n}" ]]; then
    /usr/bin/sleep "$(cat "${STATE}/sleep.${n}")" &
    [[ -e "${STATE}/ignore.${n}" ]] || trap '[[ ! -e "${STATE}/onterm.${n}" ]] || cp "${STATE}/onterm.${n}" "${STATE}/game_left"; kill $!; exit 143' TERM
    wait
fi
exit 0
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "list-jobs --no-legend microos-automount@*") [[ ! -e "${STATE}/jobs" ]] || echo "12 microos-automount@mmcblk0p1.service start running" ;;
    "list-units --no-legend --plain --state=activating microos-automount@*") ;;
    "--user show -p ActiveState --value gamescope-session-plus@microemu.service") cat "${STATE}/unit" ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/findmnt" <<'STUB'
#!/usr/bin/bash
echo "findmnt $*" >> "${STATE}/findmnt"
[[ "$*" == "-rno OPTIONS --mountpoint $(cat "${STATE}/mounted" 2>/dev/null)" ]] || exit 1
cat "${STATE}/opts"
[[ ! -e "${STATE}/stacked" ]] || cat "${STATE}/stacked"
STUB
cat > "${T}/bin/mkdir" <<'STUB'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${STATE}/mkdir"
exec /usr/bin/mkdir "$@"
STUB
cat > "${T}/bin/microos-session" <<'STUB'
#!/usr/bin/bash
echo "microos-session $*" >> "${STATE}/calls"
[[ "$1" != list ]] || printf 'steam\tSteam\tyes\n'
STUB
cat > "${T}/bin/sleep" <<'STUB'
#!/usr/bin/bash
echo "sleep $*" >> "${STATE}/calls"
[[ "$*" != 2 ]] || exec /usr/bin/sleep 0.05
STUB
cat > "${T}/bin/game-stop" <<'STUB'
#!/usr/bin/bash
STUB
cat > "${T}/bin/game-running" <<'STUB'
#!/usr/bin/bash
echo "game-running" >> "${STATE}/calls"
n=$(cat "${STATE}/game_left" 2>/dev/null || echo 0)
(( n > 0 )) || exit 1
echo $(( n - 1 )) > "${STATE}/game_left"
echo "scope active"
STUB
cat > "${T}/bin/reconcile" <<'STUB'
#!/usr/bin/bash
echo "reconcile $*" >> "${STATE}/calls"
[[ "$1" != paths ]] || exec "${REAL_RECONCILE}" "$@"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

cat > "${T}/fold.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *fold(const char *path, char *buf, size_t size)
{
    const char *at = path ? strstr(path, "/ROMs") : NULL;
    if (!at || (at[5] != '\0' && at[5] != '/'))
        return path;
    snprintf(buf, size, "%.*s/roms%s", (int)(at - path), path, at + 5);
    return buf;
}

#define WRAP(name, type) \
    int name(const char *path, type *st) \
    { \
        char buf[4096]; \
        int (*next)(const char *, type *) = dlsym(RTLD_NEXT, #name); \
        return next(fold(path, buf, sizeof buf), st); \
    }
WRAP(stat, struct stat)
WRAP(lstat, struct stat)
WRAP(stat64, struct stat64)
WRAP(lstat64, struct stat64)

int fstatat(int dir, const char *path, struct stat *st, int flags)
{
    char buf[4096];
    int (*next)(int, const char *, struct stat *, int) = dlsym(RTLD_NEXT, "fstatat");
    return next(dir, fold(path, buf, sizeof buf), st, flags);
}

int fstatat64(int dir, const char *path, struct stat64 *st, int flags)
{
    char buf[4096];
    int (*next)(int, const char *, struct stat64 *, int) = dlsym(RTLD_NEXT, "fstatat64");
    return next(dir, fold(path, buf, sizeof buf), st, flags);
}

int statx(int dir, const char *path, int flags, unsigned int mask, struct statx *st)
{
    char buf[4096];
    int (*next)(int, const char *, int, unsigned int, struct statx *) = dlsym(RTLD_NEXT, "statx");
    return next(dir, fold(path, buf, sizeof buf), flags, mask, st);
}

ssize_t readlink(const char *path, char *out, size_t size)
{
    char buf[4096];
    ssize_t (*next)(const char *, char *, size_t) = dlsym(RTLD_NEXT, "readlink");
    return next(fold(path, buf, sizeof buf), out, size);
}

ssize_t readlinkat(int dir, const char *path, char *out, size_t size)
{
    char buf[4096];
    ssize_t (*next)(int, const char *, char *, size_t) = dlsym(RTLD_NEXT, "readlinkat");
    return next(dir, fold(path, buf, sizeof buf), out, size);
}
C
cc -shared -fPIC -o "${T}/fold.so" "${T}/fold.c" -ldl

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${HOME}" "${T:?}/run" "${media}"
    mkdir -p "${STATE}" "${HOME}/ROMs" "${HOME}/BIOS/retroarch" "${T}/run/microos" "${media}"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    : > "${STATE}/mkdir"
    echo deactivating > "${STATE}/unit"
    echo "rw,nosuid,nodev,noatime" > "${STATE}/opts"
}

card() {
    card="${media}/${1:-e8ea5deb}"
    mkdir -p "${card}/steamapps"
    ln -sfn "${card}" "${MICROEMU_CONTENT_LINK}"
    printf '%s' "${card}" > "${STATE}/mounted"
}

run() {
    rc=0
    timeout 60 "${client}" 2> "${STATE}/stderr" || rc=$?
    [[ "${rc}" == 0 ]] || fail "client exit ${rc}: $(cat "${STATE}/stderr")"
}

paths_of() { cat "${STATE}/paths.${1:-1}" 2>/dev/null; }
internal() {
    printf '%s\n' layout=names "root=${HOME}" "roms=${HOME}/ROMs" "bios=${HOME}/BIOS/retroarch" "saves=${HOME}/Saves" \
        "states=${HOME}/States" "screenshots=${HOME}/Screenshots" "media=${HOME}/Media" saves_in_content=false
}
names() {
    printf '%s\n' layout=names "root=$1" "roms=$1/ROMs" "bios=$1/BIOS/retroarch" "saves=$1/Saves" "states=$1/States" \
        "screenshots=$1/Screenshots" "media=$1/Media" saves_in_content=false
}
setting() { sed -nE "s|^<(string\|bool) name=\"$2\" value=\"(.*)\" />$|\\2|p" "${STATE}/es.$1"; }
no_card_mkdir() { ! grep -qF "${media}" "${STATE}/mkdir" || fail "$1: mkdir on the card: $(grep -F "${media}" "${STATE}/mkdir")"; }
logged() { grep -c -F -- "$1" "${STATE}/log" || true; }
count() { grep -c -x -- "$1" "${STATE}/calls" || true; }

reset
card
mkdir -p "${card}/ROMs/gba" "${card}/BIOS/retroarch" "${card}/Music"
run
[[ "$(paths_of)" == "$(names "${card}")" ]] || fail "names: $(paths_of)"
[[ "$(setting 1 ROMDirectory) $(setting 1 MediaDirectory) $(setting 1 LegacyGamelistFileLocation)" == "${card}/ROMs ${card}/Media false" ]] \
    || fail "names: es_settings $(cat "${STATE}/es.1")"
grep -qx "findmnt -rno OPTIONS --mountpoint ${card}" "${STATE}/findmnt" || fail "names: findmnt argv $(cat "${STATE}/findmnt")"
no_card_mkdir names
[[ ! -e "${card}/Saves" && ! -e "${card}/Media" ]] || fail "names: the pick made a folder"

reset
card
mkdir -p "${card}/Emulation/roms/gba" "${card}/Emulation/bios" "${card}/Emulation/saves/retroarch"
ln -s /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/saves "${card}/Emulation/saves/retroarch/saves"
ln -s /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/states "${card}/Emulation/saves/retroarch/states"
run
[[ "$(paths_of)" == "$(printf '%s\n' layout=emudeck "root=${card}" "roms=${card}/Emulation/roms" "bios=${card}/Emulation/bios" \
    "saves=${card}/Emulation/saves/microemu/saves" "states=${card}/Emulation/saves/microemu/states" \
    "screenshots=${card}/Emulation/storage/retroarch/screenshots" "media=${card}/Emulation/tools/downloaded_media" \
    saves_in_content=false)" ]] || fail "emudeck: $(paths_of)"
[[ "$(setting 1 ROMDirectory) $(setting 1 LegacyGamelistFileLocation)" == "${card}/Emulation/roms false" ]] || fail "emudeck: es_settings $(cat "${STATE}/es.1")"
[[ "$(readlink "${card}/Emulation/saves/retroarch/saves")" == /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/saves &&
    "$(readlink "${card}/Emulation/saves/retroarch/states")" == /home/deck/.var/app/org.libretro.RetroArch/config/retroarch/states ]] \
    || fail "emudeck: EmuDeck's links changed"
no_card_mkdir emudeck

reset
card
mkdir -p "${card}/roms/gba" "${card}/roms/bios"
run
rocknix=$(printf '%s\n' layout=rocknix "root=${card}" "roms=${card}/roms" "bios=${card}/roms/bios" saves= \
    "states=${card}/roms/savestates" "screenshots=${card}/roms/screenshots" "media=${card}/roms/downloaded_media" saves_in_content=true)
[[ "$(paths_of)" == "${rocknix}" ]] || fail "rocknix: $(paths_of)"
[[ "$(setting 1 ROMDirectory) $(setting 1 MediaDirectory) $(setting 1 LegacyGamelistFileLocation)" == "${card}/roms ${card}/roms/downloaded_media true" ]] \
    || fail "rocknix: es_settings $(cat "${STATE}/es.1")"
no_card_mkdir rocknix

reset
card
mkdir -p "${card}/roms/gba"
run
[[ "$(grep '^bios=' "${STATE}/paths.1")" == "bios=${HOME}/BIOS/retroarch" ]] || fail "rocknix without roms/bios: $(paths_of)"
[[ "$(logged "${card}/roms/bios is missing or not a folder on the card, using ${HOME}/BIOS/retroarch")" == 1 ]] || fail "rocknix without roms/bios: log $(cat "${STATE}/log")"

reset
card
mkdir -p "${card}/ROMs/gba" "${card}/BIOS/retroarch" "${card}/elsewhere"
ln -s elsewhere "${card}/Media"
run
[[ "$(grep '^media=' "${STATE}/paths.1")" == "media=${HOME}/Media" ]] || fail "symlinked Media: $(paths_of)"
[[ "$(logged "${card}/Media is not a folder on the card, using ${HOME}/Media")" == 1 ]] || fail "symlinked Media: no log"

reset
card
mkdir -p "${card}/ROMs/gba" "${card}/Emulation/roms/gba"
run
[[ "$(grep '^layout=' "${STATE}/paths.1")" == layout=names ]] || fail "names and emudeck: $(paths_of)"
[[ "$(logged "${card} also has the emudeck layout, using names")" == 1 ]] || fail "names and emudeck: log $(cat "${STATE}/log")"

reset
card
mkdir -p "${card}/roms/gba" "${card}/roms/bios"
LD_PRELOAD="${T}/fold.so" bash -c '[[ -d "$1/ROMs" && -d "$1/ROMs/gba" && ! -L "$1/ROMs" && "$(realpath -e -- "$1/ROMs")" == "$1/ROMs" ]]' _ "${card}" \
    || fail "the stat stub does not make ROMs a directory"
LD_PRELOAD="${T}/fold.so" run
[[ "$(paths_of)" == "${rocknix}" ]] || fail "roms with ROMs stat true: $(paths_of)"

reset
card
run
[[ "$(paths_of)" == "$(internal)" ]] || fail "steamapps only: $(paths_of)"
[[ "$(logged "${card} has no ROMs, Emulation/roms or roms folder, using internal storage")" == 1 ]] || fail "steamapps only: log $(cat "${STATE}/log")"

for kind in symlink dangling outside; do
    reset
    card
    mkdir -p "${card}/real/gba" "${T}/outside/gba"
    case "${kind}" in
        symlink) ln -s real "${card}/ROMs" ;;
        dangling) ln -s missing "${card}/ROMs" ;;
        outside) ln -s "${T}/outside" "${card}/ROMs" ;;
    esac
    run
    [[ "$(paths_of)" == "$(internal)" ]] || fail "ROMs ${kind}: $(paths_of)"
    rm -rf "${T}/outside"
done

reset
card
mkdir -p "${card}/ROMs/gba"
echo "ro,nosuid,nodev,noatime" > "${STATE}/opts"
echo 0.5 > "${STATE}/sleep.1"
run
[[ "$(paths_of)" == "$(internal)" ]] || fail "ro card: $(paths_of)"
[[ "$(logged "is mounted read only")" == 1 && "$(logged "${card} is mounted read only, using internal storage")" == 1 ]] \
    || fail "ro card: $(logged "is mounted read only") log lines: $(cat "${STATE}/log")"
(( $(count "sleep 2") > 1 )) || fail "ro card: no re-pick ran"
no_card_mkdir "ro card"
[[ "$(cat "${STATE}/runs")" == 1 ]] || fail "ro card: es-de restarted"

reset
card
mkdir -p "${card}/ROMs/gba"
echo "ro,nosuid" > "${STATE}/stacked"
run
[[ "$(paths_of)" == "$(internal)" ]] || fail "ro mount stacked on top: $(paths_of)"
reset
card
mkdir -p "${card}/ROMs/gba" "${card}/BIOS/retroarch"
echo "ro,nosuid" > "${STATE}/opts"
echo "rw,nosuid" > "${STATE}/stacked"
run
[[ "$(grep '^layout=' "${STATE}/paths.1") $(grep '^root=' "${STATE}/paths.1")" == "layout=names root=${card}" ]] || fail "rw mount stacked on top: $(paths_of)"

reset
card
mkdir -p "${card}/ROMs/gba"
rm -f "${STATE}/mounted"
run
[[ "$(paths_of)" == "$(internal)" ]] || fail "card dir not mounted: $(paths_of)"

reset
run
[[ "$(paths_of)" == "$(internal)" ]] || fail "no link: $(paths_of)"
ln -s "${media}/gone" "${MICROEMU_CONTENT_LINK}"
run
[[ "$(paths_of 2)" == "$(internal)" ]] || fail "dangling link: $(paths_of 2)"

reset
card
mkdir -p "${card}/roms/gba" "${card}/roms/bios"
MICROEMU_TEST=1 MICROEMU_TEST_FOLDERS="rocknix gba gba-rocknix
emudeck nes nes-emudeck" run
diff <(sed 's#%MICROOS_SESSIONS%#'"${MICROEMU_RUNTIME_DIR}"'/microos#' "${shipped}") "${STATE}/systems.1" > "${STATE}/map.diff" || true
[[ "$(grep '^[<>]' "${STATE}/map.diff")" == "$(printf '%s\n' '<         <path>%ROMPATH%/gba</path>' '>         <path>%ROMPATH%/gba-rocknix</path>')" ]] \
    || fail "map: $(cat "${STATE}/map.diff")"
reset
card
mkdir -p "${card}/ROMs/gba"
MICROEMU_TEST=1 MICROEMU_TEST_FOLDERS="rocknix gba gba-rocknix" run
grep -q 'gba-rocknix' "${STATE}/systems.1" && fail "map: a rocknix row applied on a names card"
reset
card
mkdir -p "${card}/roms/gba"
MICROEMU_TEST_FOLDERS="rocknix gba gba-rocknix" run
grep -q 'gba-rocknix' "${STATE}/systems.1" && fail "map: a test row applied without MICROEMU_TEST"

reset
card 'a"b'
mkdir -p "${card}/ROMs/gba"
run
grep -q 'ROMDirectory: .* holds a quote or a line break, ES-DE paths not written' "${STATE}/log" || fail "unsafe card path: no Unsafe log: $(cat "${STATE}/log")"
grep -q 'name="ROMDirectory"' "${STATE}/es.1" 2>/dev/null && fail "unsafe card path: ROMDirectory written"

reset
: > "${STATE}/jobs"
run
[[ "$(count "sleep 0.5")" == 20 ]] || fail "boot wait with a job: $(count "sleep 0.5") polls"
[[ "$(logged "microos-automount still busy after 10 s, picking the storage now")" == 1 ]] || fail "boot wait with a job: no log"
[[ "$(grep -n -x es-de "${STATE}/calls" | cut -d: -f1)" -gt "$(grep -n -x 'sleep 0.5' "${STATE}/calls" | tail -n 1 | cut -d: -f1)" ]] \
    || fail "boot wait with a job: es-de before the wait ended"
reset
run
[[ "$(count "sleep 0.5")" == 0 ]] || fail "boot wait without a job: $(count "sleep 0.5") polls"
grep -qx 'systemctl list-jobs --no-legend microos-automount@\*' "${STATE}/calls" || fail "boot wait: list-jobs argv $(grep list- "${STATE}/calls")"
grep -E '^systemctl (--user )?list-' "${STATE}/calls" | grep -q -- --user && fail "boot wait: --user on a system unit query"

repick() {
    reset
    echo active > "${STATE}/unit"
    echo 30 > "${STATE}/sleep.1"
}
second_start() { grep -n -x es-de "${STATE}/calls" | sed -n 2p | cut -d: -f1; }
first_back() { grep -n -x 'microos-session back' "${STATE}/calls" | head -n 1 | cut -d: -f1; }
restarted() {
    [[ "$(cat "${STATE}/runs")" == 2 ]] || fail "$1: es-de ran $(cat "${STATE}/runs") times"
    [[ "$(logged "storage changed, restarting es-de")" == 1 && "$(logged "es-de exited with 143")" == 1 ]] || fail "$1: log $(cat "${STATE}/log")"
    [[ "$(count "microos-session back")" == 1 && "$(first_back)" -gt "$(second_start)" ]] || fail "$1: back calls $(cat "${STATE}/calls")"
    no_card_mkdir "$1"
}

repick
mkdir -p "${media}/e8ea5deb/ROMs/gba" "${media}/e8ea5deb/BIOS/retroarch"
printf '%s' "${media}/e8ea5deb" > "${STATE}/mounted"
printf 'ln -sfn %q %q\n' "${media}/e8ea5deb" "${MICROEMU_CONTENT_LINK}" > "${STATE}/hook.1"
run
restarted "link change"
[[ "$(paths_of 1)" == "$(internal)" && "$(paths_of 2)" == "$(names "${media}/e8ea5deb")" ]] || fail "link change: $(paths_of 1) then $(paths_of 2)"
[[ "$(setting 2 ROMDirectory)" == "${media}/e8ea5deb/ROMs" ]] || fail "link change: ROMDirectory not rewritten"

repick
card
mkdir -p "${card}/ROMs/gba"
printf 'mv %q %q\n' "${card}/ROMs" "${card}/roms" > "${STATE}/hook.1"
run
restarted "layout change"
[[ "$(grep '^layout=' "${STATE}/paths.2")" == layout=rocknix && "$(setting 2 LegacyGamelistFileLocation)" == true ]] || fail "layout change: $(paths_of 2)"

repick
card
mkdir -p "${card}/ROMs/gba"
printf 'echo ro,nosuid > %q\n' "${STATE}/opts" > "${STATE}/hook.1"
run
restarted "rw to ro"
[[ "$(paths_of 2)" == "$(internal)" ]] || fail "rw to ro: $(paths_of 2)"

repick
card
mkdir -p "${card}/ROMs/gba"
printf 'echo 6 > %q\nrm -f %q\n' "${STATE}/game_left" "${MICROEMU_CONTENT_LINK}" > "${STATE}/hook.1"
run
restarted "with a game"
[[ "$(sed -n "1,$(second_start)p" "${STATE}/calls" | grep -cx game-running)" -ge 7 ]] || fail "with a game: restarted while the game ran: $(cat "${STATE}/calls")"
[[ "$(count "sleep 1")" == 0 ]] || fail "with a game: waited after the stop"

repick
card
mkdir -p "${card}/ROMs/gba"
printf 'rm -f %q\n' "${MICROEMU_CONTENT_LINK}" > "${STATE}/hook.1"
echo 3 > "${STATE}/onterm.1"
run
restarted "game during the stop"
stop_line=$(grep -n -x 'game-running' "${STATE}/calls" | head -n 1 | cut -d: -f1)
[[ "$(sed -n "${stop_line},$(second_start)p" "${STATE}/calls" | grep -cx 'sleep 1')" == 3 ]] || fail "game during the stop: $(cat "${STATE}/calls")"

repick
card
mkdir -p "${card}/ROMs/gba"
printf 'rm -f %q\n' "${MICROEMU_CONTENT_LINK}" > "${STATE}/hook.1"
: > "${STATE}/ignore.1"
echo 5 > "${STATE}/sleep.1"
run
[[ "$(cat "${STATE}/runs")" == 2 ]] || fail "es-de ignoring TERM: es-de ran $(cat "${STATE}/runs") times"
[[ "$(logged "es-de still running 10 s after SIGTERM, killing it")" == 1 && "$(logged "es-de exited with 137")" == 1 ]] \
    || fail "es-de ignoring TERM: log $(cat "${STATE}/log")"
stop_line=$(grep -n -x 'game-running' "${STATE}/calls" | head -n 1 | cut -d: -f1)
[[ "$(sed -n "${stop_line},$(second_start)p" "${STATE}/calls" | grep -cx 'sleep 0.5')" -ge 20 ]] || fail "es-de ignoring TERM: not 20 polls"
[[ "$(count "microos-session back")" == 1 && "$(first_back)" -gt "$(second_start)" ]] || fail "es-de ignoring TERM: back calls"

repick
card
mkdir -p "${card}/ROMs/gba"
printf 'rm -f %q\n' "${MICROEMU_CONTENT_LINK}" > "${STATE}/hook.1"
run
[[ "$(logged "killing it")" == 0 ]] || fail "es-de stopping on TERM: killed"

repick
card
mkdir -p "${card}/ROMs/gba"
rm -f "${STATE}/sleep.1"
run
[[ "$(cat "${STATE}/runs")" == 1 && "$(count "microos-session back")" == 1 ]] || fail "es-de exit by itself: $(cat "${STATE}/calls")"
[[ "$(logged "storage changed")" == 0 ]] || fail "es-de exit by itself: a restart logged"

if (( failures )); then
    echo "layout-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "layout-test: ok"
