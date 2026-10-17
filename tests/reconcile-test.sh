#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
reconcile="${repo}/data/usr/libexec/microemu/microemu-reconcile"
export MICROEMU_SCHEMA="${repo}/data/usr/share/microset/schema.d/50-microemu.json"
export PYTHONDONTWRITEBYTECODE=1

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_WRITTEN="${T}/home/.local/state/microemu/written.json"
export MICROEMU_MICROSET="${T}/bin/microset"
ra="${T}/home/.config/microemu/retroarch"
cfg="${ra}/retroarch.cfg"
settings="${T}/home/.local/share/microemu/ES-DE/settings"
es="${settings}/es_settings.xml"

cat > "${T}/bin/microset" <<'STUB'
#!/usr/bin/python3
import json
import os
import re
import sys

state = os.environ["STATE"]
if os.path.exists(os.path.join(state, "down")):
    print("microset: microsetd is not running", file=sys.stderr)
    sys.exit(5)
keys = json.load(open(os.environ["MICROEMU_SCHEMA"]))["keys"]
path = os.path.join(state, "stored.json")
stored = json.load(open(path)) if os.path.exists(path) else {}
with open(os.path.join(state, "microset"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")


def fmt(v):
    return ("true" if v else "false") if isinstance(v, bool) else str(v)


def parse(entry, text):
    t = entry["type"]
    if t == "b":
        v = {"true": True, "false": False}.get(text)
    elif t == "u":
        v = int(text) if re.fullmatch(r"[0-9]+", text) else None
    else:
        v = text
    if v is None:
        return None
    if "enum" in entry and v not in entry["enum"]:
        return None
    if "min" in entry and v < entry["min"] or "max" in entry and v > entry["max"]:
        return None
    if t == "s" and len(v) > entry.get("max_len", 256):
        return None
    return v


verb = sys.argv[1]
if verb == "list":
    for k in sorted(keys):
        if k.startswith(sys.argv[2]):
            print(f"{k}\t{fmt(stored.get(k, keys[k]['default']))}")
elif verb == "set":
    k, text = sys.argv[2], sys.argv[3]
    if k not in keys:
        sys.exit(2)
    v = parse(keys[k], text)
    if v is None:
        print(f"microset: {text} is not a value of type {keys[k]['type']}", file=sys.stderr)
        sys.exit(3)
    stored[k] = v
    json.dump(stored, open(path, "w"))
else:
    sys.exit(1)
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
shift 3
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${T:?}/home"
    mkdir -p "${STATE}"
    : > "${STATE}/log"
    : > "${STATE}/microset"
}

launch() {
    rc=0
    "${reconcile}" "$1" "$2" 2> "${STATE}/stderr" || rc=$?
}

game() { launch retroarch "${ra}"; }
esde() { launch esde "${settings}"; }
stored() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], "unset"))' "${STATE}/stored.json" "$1" 2>/dev/null || echo unset; }
written() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], "unset"); print(json.dumps(v))' "${MICROEMU_WRITTEN}" "$1"; }
sets() { grep -c '^set ' "${STATE}/microset" || true; }

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

reset
game
[[ "${rc}" == 0 ]] || fail "fresh: exit ${rc}: $(cat "${STATE}/stderr")"
[[ "$(sort "${cfg}")" == "$(sort <<< "${seeded}")" ]] || fail "fresh: retroarch.cfg $(cat "${cfg}")"
for core in bsnes-mercury Nestopia PCSX-ReARMed; do
    [[ "$(cat "${ra}/config/${core}/${core}.cfg")" == 'video_threaded = "false"' ]] || fail "fresh: ${core} override $(cat "${ra}/config/${core}/${core}.cfg" 2>&1)"
done
[[ "$(sets)" == 0 ]] || fail "fresh: Set called: $(cat "${STATE}/microset")"
[[ "$(written microemu.retroarch.fps_show)" == true && "$(written microemu.retroarch.savestate_max_keep)" == 10 ]] || fail "fresh: written.json $(cat "${MICROEMU_WRITTEN}")"
[[ "$(written microemu.esde.theme)" == '"unset"' ]] || fail "fresh: an ES-DE key written by the RetroArch launch"

esde
[[ "${rc}" == 0 ]] || fail "fresh es-de: exit ${rc}"
[[ "$(head -n 1 "${es}")" == '<?xml version="1.0"?>' ]] || fail "fresh es-de: no xml header"
for pair in Theme:art-book-next-es-de ThemeColorScheme:dark-screenshots ThemeVariant:gamelist-list-metadata-cover \
    ThemeFontSize:medium ThemeAspectRatio:3:2; do
    grep -qxF "<string name=\"${pair%%:*}\" value=\"${pair#*:}\" />" "${es}" || fail "fresh es-de: ${pair} missing: $(cat "${es}")"
done
[[ "$(written microemu.retroarch.fps_show)" == true ]] || fail "es-de launch dropped the RetroArch entries"

reset
game
sed -i 's/^fps_show = .*/fps_show = "false"/; s/^savestate_max_keep = .*/savestate_max_keep = "3.000000"/' "${cfg}"
printf 'aspect_ratio_index = "22"\n' >> "${cfg}"
game
[[ "$(stored microemu.retroarch.fps_show)" == False ]] || fail "menu edit: fps_show not in MicroSET: $(stored microemu.retroarch.fps_show)"
[[ "$(stored microemu.retroarch.savestate_max_keep)" == 3 ]] || fail "menu edit: savestate_max_keep from RetroArch's float format not set"
grep -qx 'fps_show = "false"' "${cfg}" || fail "menu edit reverted: $(grep fps_show "${cfg}")"
grep -qx 'aspect_ratio_index = "22"' "${cfg}" || fail "an unowned key dropped"
[[ "$(written microemu.retroarch.fps_show)" == false ]] || fail "menu edit: written.json not updated"
before=$(sets)
game
[[ "$(sets)" == "${before}" ]] || fail "a second launch with no change called Set"
grep -qx 'fps_show = "false"' "${cfg}" || fail "menu edit lost at the second launch"

reset
game
microset set microemu.retroarch.video_driver glcore
game
grep -qx 'video_driver = "glcore"' "${cfg}" || fail "MicroSET change not in the file: $(grep video_driver "${cfg}")"
[[ "$(grep -c '^video_driver' "${cfg}")" == 1 ]] || fail "video_driver written twice"
[[ "$(written microemu.retroarch.video_driver)" == '"glcore"' ]] || fail "MicroSET change not in written.json"

reset
game
microset set microemu.retroarch.video_driver glcore
sed -i 's/^video_driver = .*/video_driver = "gl"/' "${cfg}"
game
grep -qx 'video_driver = "gl"' "${cfg}" || fail "both changed: the file lost: $(grep video_driver "${cfg}")"
[[ "$(stored microemu.retroarch.video_driver)" == gl ]] || fail "both changed: MicroSET not set to the file value"
grep -q 'microemu.retroarch.video_driver: changed in the app (gl) and in MicroSET (glcore), the app wins' "${STATE}/log" || fail "both changed: no conflict log: $(cat "${STATE}/log")"

reset
game
sed -i 's/^savestate_max_keep = .*/savestate_max_keep = "5000"/' "${cfg}"
game
grep -qx 'savestate_max_keep = "5000"' "${cfg}" || fail "refused: the file value replaced"
[[ "$(written microemu.retroarch.savestate_max_keep)" == 10 ]] || fail "refused: written.json changed: $(written microemu.retroarch.savestate_max_keep)"
[[ "$(stored microemu.retroarch.savestate_max_keep)" == unset ]] || fail "refused: stored anyway"
grep -q 'microemu.retroarch.savestate_max_keep: 5000 from retroarch.cfg refused by MicroSET' "${STATE}/log" || fail "refused: no log: $(cat "${STATE}/log")"
: > "${STATE}/log"
game
grep -qx 'savestate_max_keep = "5000"' "${cfg}" || fail "refused: replaced at the next launch"
grep -q 'savestate_max_keep: 5000 from retroarch.cfg refused' "${STATE}/log" || fail "refused: not tried again at the next launch"

reset
game
sed -i '/^quit_press_twice/d' "${cfg}"
microset set microemu.retroarch.quit_press_twice true
game
grep -qx 'quit_press_twice = "true"' "${cfg}" || fail "a key gone from the file not written back"

reset
mkdir -p "${ra}"
printf 'fps_show = "false"\nvideo_driver = "gl"\nfps_show = "false"\n' > "${cfg}"
game
[[ "$(grep -c '^fps_show' "${cfg}")" == 1 ]] && grep -qx 'fps_show = "true"' "${cfg}" || fail "no written.json: MicroSET did not win: $(cat "${cfg}")"
grep -qx 'video_driver = "vulkan"' "${cfg}" || fail "no written.json: video_driver kept"
[[ "$(sets)" == 0 ]] || fail "no written.json: the file was read back into MicroSET"

reset
game
python3 - "${MICROEMU_WRITTEN}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["microemu.retroarch.input_player1_analog_dpad_mode"]
json.dump(d, open(sys.argv[1], "w"))
PY
sed -i 's/^input_player1_analog_dpad_mode = .*/input_player1_analog_dpad_mode = "3"/' "${cfg}"
game
grep -qx 'input_player1_analog_dpad_mode = "1"' "${cfg}" || fail "a fresh key did not get the schema default"
[[ "$(sets)" == 0 ]] || fail "a fresh key was read back into MicroSET"

reset
game
cp "${cfg}" "${STATE}/cfg.before"
cp "${MICROEMU_WRITTEN}" "${STATE}/written.before"
sed -i 's/^fps_show = .*/fps_show = "false"/' "${cfg}"
microset set microemu.retroarch.video_driver glcore
: > "${STATE}/down"
game
[[ "${rc}" == 0 ]] || fail "microsetd down: exit ${rc}"
grep -qx 'fps_show = "false"' "${cfg}" && grep -qx 'video_driver = "vulkan"' "${cfg}" || fail "microsetd down: the file changed"
cmp -s "${MICROEMU_WRITTEN}" "${STATE}/written.before" || fail "microsetd down: written.json changed"
grep -q 'microset list failed (5), files left as they are' "${STATE}/log" || fail "microsetd down: no log"
rm -f "${STATE}/down"

reset
mkdir -p "${ra}" "${T}/dot"
echo 'fps_show = "false"' > "${T}/dot/retroarch.cfg"
ln -s "${T}/dot/retroarch.cfg" "${cfg}"
game
[[ -L "${cfg}" ]] || fail "a symlinked retroarch.cfg was replaced"
grep -qx 'fps_show = "true"' "${T}/dot/retroarch.cfg" || fail "not written through the symlink"
rm -rf "${T}/dot"

reset
mkdir -p "${settings}"
printf '<?xml version="1.0"?>\n<bool name="ShowHelpPrompts" value="false" />\n<string name="Theme" value="art-book-next-es-de" />' > "${es}"
esde
sed -i 's|<string name="ThemeVariant" value="[^"]*" />|<string name="ThemeVariant" value="gamelist-grid-cover" />|' "${es}"
esde
[[ "$(stored microemu.esde.theme_variant)" == gamelist-grid-cover ]] || fail "es-de: menu edit read as $(stored microemu.esde.theme_variant)"
grep -qxF '<bool name="ShowHelpPrompts" value="false" />' "${es}" || fail "es-de: an unowned setting dropped"
[[ "$(grep -c 'name="Theme"' "${es}")" == 1 ]] || fail "es-de: Theme written twice"
microset set microemu.esde.theme_font_size large
esde
grep -qxF '<string name="ThemeFontSize" value="large" />' "${es}" || fail "es-de: a MicroSET value not written: $(grep ThemeFontSize "${es}")"
sed -i 's|<string name="ThemeColorScheme" value="[^"]*" />|<string name="ThemeColorScheme" value="dark\&quot;\&#10;x" />|' "${es}"
cp "${MICROEMU_WRITTEN}" "${STATE}/written.before"
before=$(sets)
esde
[[ "$(sets)" == "${before}" ]] || fail "es-de: a value with a quote was sent to MicroSET"
grep -qF 'value="dark&quot;&#10;x"' "${es}" || fail "es-de: the unsafe file value replaced"
grep -q 'microemu.esde.theme_color_scheme: .* holds a quote or a line break, skipped' "${STATE}/log" || fail "es-de: unsafe read not logged: $(cat "${STATE}/log")"
cmp -s "${MICROEMU_WRITTEN}" "${STATE}/written.before" || fail "es-de: written.json changed by an unsafe read"
python3 - "${STATE}/stored.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
d["microemu.esde.theme_aspect_ratio"] = '3:2" /><string name="x" value="y'
json.dump(d, open(sys.argv[1], "w"))
PY2
esde
grep -qxF '<string name="ThemeAspectRatio" value="3:2" />' "${es}" || fail "es-de: an unsafe MicroSET value written: $(grep -A1 ThemeAspectRatio "${es}")"
grep -q 'name="x"' "${es}" && fail "es-de: an unsafe MicroSET value added a setting"
grep -q 'microemu.esde.theme_aspect_ratio: .* holds a quote or a line break, not written' "${STATE}/log" || fail "es-de: unsafe write not logged"
[[ "$(written microemu.esde.theme_aspect_ratio)" == '"3:2"' ]] || fail "es-de: written.json took the unsafe value"
sed -i 's|<string name="Theme" value="[^"]*" />|<string name="Theme" value="my-theme" />|' "${es}"
esde
grep -qxF '<string name="Theme" value="my-theme" />' "${es}" || fail "es-de: a refused value replaced"
[[ "$(stored microemu.esde.theme)" == unset ]] || fail "es-de: an enum violation stored"
grep -q ApplicationUpdaterFrequency "${es}" && fail "es-de: the updater setting written"

reset
game
printf 'video_driver = "vulkan" libretro_directory = "/tmp"\n' >> "${cfg}"
sed -i '0,/^video_driver = "vulkan"$/{/^video_driver = "vulkan"$/d}' "${cfg}"
before=$(sets)
game
[[ "$(sets)" == "${before}" ]] || fail "retroarch: a value with a quote was sent to MicroSET"
grep -qxF 'video_driver = "vulkan" libretro_directory = "/tmp"' "${cfg}" || fail "retroarch: the unsafe file line replaced"
grep -q 'microemu.retroarch.video_driver: .* holds a quote or a line break, skipped' "${STATE}/log" || fail "retroarch: unsafe read not logged"
sed -i 's|^video_driver = .*|video_driver = "vulkan"|' "${cfg}"
python3 - "${STATE}/stored.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1])) if __import__("os").path.exists(sys.argv[1]) else {}
d["microemu.retroarch.video_driver"] = 'gl"\nlibretro_directory = "/tmp'
json.dump(d, open(sys.argv[1], "w"))
PY2
cp "${MICROEMU_WRITTEN}" "${STATE}/written.before"
game
grep -qx 'video_driver = "vulkan"' "${cfg}" || fail "retroarch: an unsafe MicroSET value written: $(grep -n 'video_driver\|libretro_directory' "${cfg}")"
grep -q '^libretro_directory' "${cfg}" && fail "retroarch: an unsafe MicroSET value added a key"
grep -q 'microemu.retroarch.video_driver: .* holds a quote or a line break, not written' "${STATE}/log" || fail "retroarch: unsafe write not logged"
cmp -s "${MICROEMU_WRITTEN}" "${STATE}/written.before" || fail "retroarch: written.json changed by an unsafe MicroSET value"

export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
picks="${MICROEMU_RUNTIME_DIR}/paths"
paths() { launch paths "${settings}"; }
pick() {
    mkdir -p "${MICROEMU_RUNTIME_DIR}"
    printf '%s\n' "layout=$1" "root=$2" "roms=$3" "bios=$2/b" "saves=" "states=$2/s" "screenshots=$2/x" "media=$4" \
        "saves_in_content=false" > "${picks}"
}

reset
mkdir -p "${settings}"
printf '<?xml version="1.0"?>\n<bool name="ShowHelpPrompts" value="false" />\n<string name="ROMDirectory" value="" />\n' > "${es}"
pick names /c /c/ROMs '/c/Media & co'
paths
[[ "${rc}" == 0 ]] || fail "paths: exit ${rc}: $(cat "${STATE}/log")"
grep -qxF '<string name="ROMDirectory" value="/c/ROMs" />' "${es}" || fail "paths: ROMDirectory $(grep ROMDirectory "${es}")"
[[ "$(grep -c ROMDirectory "${es}")" == 1 ]] || fail "paths: ROMDirectory written twice"
grep -qxF '<string name="MediaDirectory" value="/c/Media &amp; co" />' "${es}" || fail "paths: MediaDirectory $(grep MediaDirectory "${es}")"
grep -qxF '<bool name="LegacyGamelistFileLocation" value="false" />' "${es}" || fail "paths: legacy not false for names"
grep -qxF '<bool name="ShowHelpPrompts" value="false" />' "${es}" || fail "paths: an unowned setting dropped"
[[ ! -s "${STATE}/microset" ]] || fail "paths: microset called: $(cat "${STATE}/microset")"
pick emudeck /c /c/Emulation/roms /c/Emulation/tools/downloaded_media
paths
grep -qxF '<bool name="LegacyGamelistFileLocation" value="false" />' "${es}" || fail "paths: legacy not false for emudeck"
pick rocknix /c /c/roms /c/roms/downloaded_media
paths
grep -qxF '<bool name="LegacyGamelistFileLocation" value="true" />' "${es}" || fail "paths: legacy not true for rocknix"
grep -qxF '<string name="ROMDirectory" value="/c/roms" />' "${es}" || fail "paths: rocknix ROMDirectory"
[[ "$(grep -c LegacyGamelistFileLocation "${es}")" == 1 ]] || fail "paths: legacy written twice"

for bad in quote utf8; do
    reset
    pick names /c /c/ROMs /c/Media
    paths
    cp "${es}" "${STATE}/es.before"
    case "${bad}" in
        quote) pick names /c '/c/RO"Ms' /c/Media ;;
        utf8) pick names /c "/c/RO$(printf '\377')Ms" /c/Media ;;
    esac
    paths
    [[ "${rc}" == 1 ]] || fail "paths ${bad}: exit ${rc}"
    cmp -s "${es}" "${STATE}/es.before" || fail "paths ${bad}: es_settings.xml changed: $(cat "${es}")"
done
grep -q 'ROMDirectory: .* from paths is not valid UTF-8, ES-DE paths not written' "${STATE}/log" || fail "paths utf8: no Unsafe log: $(cat "${STATE}/log")"
reset
pick names /c /c/ROMs /c/Media
paths
pick names /c '/c/RO"Ms' /c/Media
paths
grep -q 'ROMDirectory: .* from paths holds a quote or a line break, ES-DE paths not written' "${STATE}/log" || fail "paths quote: no Unsafe log: $(cat "${STATE}/log")"

reset
rm -f "${picks}"
paths
[[ "${rc}" == 1 && ! -e "${es}" ]] || fail "paths without a paths file: exit ${rc}"
grep -q "${picks}: .*ES-DE paths not written" "${STATE}/log" || fail "paths without a paths file: no log"

reset
rc=0
"${reconcile}" bogus "${ra}" 2>/dev/null || rc=$?
[[ "${rc}" == 2 ]] || fail "bad mode exit ${rc}"

python3 - "${MICROEMU_SCHEMA}" <<'PY' || fail "schema check"
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["owner"] == "microemu"
for k, v in d["keys"].items():
    assert re.fullmatch(r"microemu(\.[A-Za-z0-9_]+)+", k), k
    assert v["type"] in ("s", "b", "u"), k
    if v["type"] == "s":
        assert v.get("enum") and all(re.fullmatch(r"[A-Za-z0-9_.:-]+", e) for e in v["enum"]), k
    assert v.get("group") == "emulation" and v.get("label"), k
    assert ("file" in v) == ("setting" in v), k
    assert isinstance(v["ui"]["order"], int), k
assert d["groups"] == {"emulation": {"label": "emulation", "order": 0}}, d["groups"]
assert sorted(v["ui"]["order"] for v in d["keys"].values()) == list(range(len(d["keys"])))
o = d["keys"]["microemu.orientation"]
assert o["enum"] == ["landscape", "landscape-flipped"] and o["default"] == "landscape"
files = {v["file"] for v in d["keys"].values() if "file" in v}
assert files == {"es_settings.xml", "retroarch.cfg", "config/bsnes-mercury/bsnes-mercury.cfg",
                 "config/Nestopia/Nestopia.cfg", "config/PCSX-ReARMed/PCSX-ReARMed.cfg"}, files
PY

if (( failures )); then
    echo "reconcile-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "reconcile-test: ok"
