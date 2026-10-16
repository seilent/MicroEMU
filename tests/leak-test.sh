#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
libexec="${repo}/data/usr/libexec/microemu"
wrapper="${libexec}/bin/retroarch"
reconcile="${libexec}/microemu-reconcile"
export MICROEMU_SCHEMA="${repo}/data/usr/share/microset/schema.d/50-microemu.json"
export PYTHONDONTWRITEBYTECODE=1

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/real"
export STATE="${T}/state"
export MICROEMU_RETROARCH_CONFIG="${T}/home/.config/microemu/retroarch/retroarch.cfg"
export MICROEMU_RETROARCH_DATA="${T}/home/.local/share/microemu/retroarch"
export MICROEMU_RETROARCH_SHARE="${repo}/data/usr/share/microemu/retroarch"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_WRITTEN="${T}/home/.local/state/microemu/written.json"
export MICROEMU_PINNED="${T}/home/.local/state/microemu/pinned-keys"
export MICROEMU_MICROSET="${T}/bin/microset"
export MICROEMU_GAME_FREE="${T}/real/microemu-game-free"
export MICROEMU_RECONCILE="${reconcile}"
export MICROEMU_GAME_FREE_POLL_S=0.05
confdir=$(dirname "${MICROEMU_RETROARCH_CONFIG}")
cfg="${MICROEMU_RETROARCH_CONFIG}"
card="${T}/card"
ln -s "${libexec}/microemu-game-running" "${T}/real/microemu-game-running"
ln -s "${libexec}/microemu-game-free" "${T}/real/microemu-game-free"

cat > "${T}/bin/microset" <<'STUB'
#!/usr/bin/python3
import json
import os
import sys

state = os.environ["STATE"]
keys = json.load(open(os.environ["MICROEMU_SCHEMA"]))["keys"]
path = os.path.join(state, "stored.json")
stored = json.load(open(path)) if os.path.exists(path) else {}
hidden = open(os.path.join(state, "hidden")).read().split() if os.path.exists(os.path.join(state, "hidden")) else []
with open(os.path.join(state, "microset"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1] == "list":
    for k in sorted(keys):
        if k.startswith(sys.argv[2]) and k not in hidden:
            v = stored.get(k, keys[k]["default"])
            print(f"{k}\t{('true' if v else 'false') if isinstance(v, bool) else v}")
elif sys.argv[1] == "set":
    v = sys.argv[3]
    stored[sys.argv[2]] = {"true": True, "false": False}.get(v, v) if keys[sys.argv[2]]["type"] == "b" else v
    json.dump(stored, open(path, "w"))
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "--user is-active --quiet gamescope-session-plus@microemu.service") exit 0 ;;
    "--user show -P ActiveState microemu-game.scope") cat "${STATE}/scope" ;;
    "--user reset-failed microemu-game.scope") exit 0 ;;
    *) exit 99 ;;
esac
STUB
cat > "${T}/bin/systemd-run" <<'STUB'
#!/usr/bin/bash
while [[ "$1" != -c ]]; do shift; done
cat "${STATE}/ra_append" >> "$2"
if [[ -e "${STATE}/ra_hang" ]]; then
    echo "$$" > "${STATE}/ra_pid"
    exec /usr/bin/sleep 30
fi
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/real:${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

write_pick() {
    mkdir -p "${MICROEMU_RUNTIME_DIR}"
    case "$1" in
        names) printf '%s\n' layout=names "root=${card}" "roms=${card}/ROMs" "bios=${card}/BIOS/retroarch" "saves=${card}/Saves" \
            "states=${card}/States" "screenshots=${card}/Screenshots" "media=${card}/Media" saves_in_content=false ;;
        rocknix) printf '%s\n' layout=rocknix "root=${card}" "roms=${card}/roms" "bios=${card}/roms/bios" saves= \
            "states=${card}/roms/savestates" "screenshots=${card}/roms/screenshots" "media=${card}/roms/downloaded_media" \
            saves_in_content=true ;;
    esac > "${MICROEMU_RUNTIME_DIR}/paths"
}

reset() {
    rm -rf "${STATE}" "${T:?}/home" "${card}" "${T:?}/run"
    mkdir -p "${STATE}" "${card}/roms/gba" "${card}/ROMs/gba"
    : > "${card}/roms/gba/x.gba"
    : > "${card}/ROMs/gba/x.gba"
    : > "${STATE}/calls"
    : > "${STATE}/log"
    : > "${STATE}/microset"
    echo inactive > "${STATE}/scope"
    printf 'sort_savefiles_enable = "false"\nsort_savestates_enable = "false"\n' > "${STATE}/ra_append"
}

launch() {
    write_pick "$1"
    rc=0
    "${wrapper}" -L /usr/lib64/libretro/mgba_libretro.so "${card}/$2/gba/x.gba" 2> "${STATE}/stderr" || rc=$?
}

killed_launch() {
    : > "${STATE}/ra_hang"
    write_pick rocknix
    "${wrapper}" -L /usr/lib64/libretro/mgba_libretro.so "${card}/roms/gba/x.gba" 2> "${STATE}/stderr" &
    local wpid=$! n
    for (( n = 0; n < 200; n++ )); do
        [[ ! -s "${STATE}/ra_pid" ]] || break
        sleep 0.02
    done
    kill -TERM "${wpid}"
    rc=0
    wait "${wpid}" || rc=$?
    kill "$(cat "${STATE}/ra_pid")" 2>/dev/null || true
    rm -f "${STATE}/ra_hang" "${STATE}/ra_pid"
}

value() { sed -nE "s/^$1 = \"(.*)\"$/\\1/p" "${cfg}" | tail -n 1; }
lines() { grep -c "^$1" "${cfg}" || true; }
sets() { grep -c '^set ' "${STATE}/microset" || true; }
game() { "${reconcile}" retroarch "${confdir}" 2>> "${STATE}/stderr"; }

reset
killed_launch
[[ "${rc}" == 143 ]] || fail "killed rocknix: exit ${rc}"
[[ "$(cat "${MICROEMU_PINNED}" 2>&1)" == $'sort_savefiles_enable=true\nsort_savestates_enable=true' ]] || fail "killed rocknix: record $(cat "${MICROEMU_PINNED}" 2>&1)"
[[ "$(value sort_savefiles_enable) $(value sort_savestates_enable)" == "false false" ]] || fail "killed rocknix: the stub did not leak: $(cat "${cfg}")"
/usr/bin/sleep 30 &
marker=$!
echo "${marker}" > "${MICROEMU_RUNTIME_DIR}/launching"
[[ "$(microemu-game-running)" == "launch ${marker}" ]] || fail "live marker: microemu-game-running says $(microemu-game-running)"
before=$(sets)
game
[[ "$(value sort_savefiles_enable) $(value sort_savestates_enable)" == "true true" ]] || fail "replay with a live marker: $(cat "${cfg}")"
[[ "$(lines sort_savefiles_enable) $(lines sort_savestates_enable)" == "1 1" ]] || fail "replay: duplicate lines $(cat "${cfg}")"
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "replay with a live marker and the scope inactive: record kept"
[[ "$(sets)" == "${before}" ]] || fail "replay: microset set called: $(cat "${STATE}/microset")"
kill "${marker}"
wait "${marker}" 2>/dev/null || true
rm -f "${MICROEMU_RUNTIME_DIR}/launching"

reset
killed_launch
echo active > "${STATE}/scope"
game
[[ "$(value sort_savefiles_enable) $(value sort_savestates_enable)" == "true true" ]] || fail "scope active: not written back: $(cat "${cfg}")"
[[ -e "${MICROEMU_PINNED}" ]] || fail "scope active: record dropped"
grep -q 'record kept while microemu-game.scope is active' "${STATE}/log" || fail "scope active: no log: $(cat "${STATE}/log")"
echo inactive > "${STATE}/scope"
game
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "scope inactive after active: record kept"

reset
launch rocknix roms
[[ "${rc}" == 0 ]] || fail "normal rocknix exit: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(value sort_savefiles_enable) $(value sort_savestates_enable)" == "true true" ]] || fail "normal rocknix exit: not restored: $(cat "${cfg}")"
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "normal rocknix exit: record left"
[[ "$(sets)" == 0 ]] || fail "normal rocknix exit: microset set called: $(cat "${STATE}/microset")"

reset
killed_launch
printf 'sort_savefiles_enable = "false"\n' > "${STATE}/ra_append"
launch names ROMs
[[ "${rc}" == 0 ]] || fail "names after killed rocknix: exit ${rc}: $(cat "${STATE}/stderr")"
grep -qx 'set microemu.retroarch.sort_savefiles_enable false' "${STATE}/microset" || fail "names RGUI change: not sent to MicroSET: $(cat "${STATE}/microset")"
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "names RGUI change: a record left"
: > "${STATE}/ra_append"
launch names ROMs
[[ "$(value sort_savefiles_enable)" == false ]] || fail "names RGUI change: replaced at the next launch: $(cat "${cfg}")"
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "names RGUI change: a record at the next launch"

reset
printf 'microemu.retroarch.sort_savefiles_enable\nmicroemu.retroarch.sort_savestates_enable\n' > "${STATE}/hidden"
: > "${STATE}/ra_hang"
write_pick rocknix
"${wrapper}" -L /usr/lib64/libretro/mgba_libretro.so "${card}/roms/gba/x.gba" 2> "${STATE}/stderr" &
wpid=$!
for (( n = 0; n < 200; n++ )); do
    [[ ! -s "${STATE}/ra_pid" ]] || break
    sleep 0.02
done
[[ "$(cat "${MICROEMU_PINNED}" 2>&1)" == $'sort_savefiles_enable\nsort_savestates_enable' ]] || fail "fresh config: record $(cat "${MICROEMU_PINNED}" 2>&1)"
[[ "$(value sort_savefiles_enable) $(value sort_savestates_enable)" == "false false" ]] || fail "fresh config: the stub did not append: $(cat "${cfg}")"
kill "$(cat "${STATE}/ra_pid")"
rc=0
wait "${wpid}" || rc=$?
[[ "${rc}" == 143 ]] || fail "fresh config: wrapper exit ${rc}, expected the game's 143"
grep -q '^sort_savefiles_enable\|^sort_savestates_enable' "${cfg}" && fail "fresh config: lines left after the reconcile: $(cat "${cfg}")"
grep -q '= ""' "${cfg}" && fail "fresh config: an empty value written"
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "fresh config: record left"
rm -f "${STATE}/ra_hang" "${STATE}/ra_pid"

reset
launch names ROMs
[[ ! -e "${MICROEMU_PINNED}" ]] || fail "names launch: a record written"

if (( failures )); then
    echo "leak-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "leak-test: ok"
