#!/usr/bin/bash
set -eu

export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
sync="${repo}/android/data/usr/libexec/microemu/microemu-android-sync"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export MICROEMU_PLAY_CONTEXT="${T}/context"
export MICROEMU_ANDROID_ROMS="${T}/roms"
export MICROEMU_GAPPS="${T}/gapps"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
export MICROEMU_ANDROID_DATA="${T}/android"
seen="${MICROEMU_ANDROID_DATA}/play-installed"
reload="${MICROEMU_RUNTIME_DIR}/esde-reload"
data="${MICROEMU_PLAY_CONTEXT}/baked/data_overlay"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

fixture() {
    rm -rf "${T}/context" "${T}/roms" "${T}/gapps" "${MICROEMU_ANDROID_DATA}"
    mkdir -p "${data}/system" "${data}/data/com.android.launcher3/databases" "${MICROEMU_ANDROID_ROMS}"
    cat > "${data}/system/packages.xml" <<'XML'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<packages>
<package name="com.example.playgame" codePath="/data/app/x" publicFlags="944291398" version="12" installer="com.android.vending" />
<package name="com.example.another" codePath="/data/app/y" publicFlags="944291398" version="3" installer="com.android.vending" />
<package name="com.example.nolabel" codePath="/data/app/z" publicFlags="944291398" version="1" installer="com.android.vending" />
<package name="com.example.unicode" codePath="/data/app/q" publicFlags="944291398" version="1" installer="com.android.vending" />
<package name="com.uberspot.a2048" codePath="/data/app/w" publicFlags="944291398" version="25" />
<package name="com.example.system" codePath="/system/app/s" publicFlags="944291399" version="1" installer="com.android.vending" />
<package name="com.google.android.gms" codePath="/data/app/g" publicFlags="944291398" version="1" installer="com.android.vending" />
<package name="com.android.vending" codePath="/data/app/v" publicFlags="944291398" version="1" installer="com.android.vending" isOrphaned="true" />
<package name="com.example.updated" codePath="/data/app/u" publicFlags="944291398" version="2" installer="com.android.vending" />
<updated-package name="com.example.updated" codePath="/system/app/u" version="1" />
</packages>
XML
    python3 - "${data}/data/com.android.launcher3/databases/app_icons.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("create table icons(componentName text, profileId integer, lastUpdated integer, version integer, icon blob, icon_color integer, label text, system_state text, keywords text)")
rows = [
    ("com.example.playgame/VIEW_MY_DOWNLOADS", "A shortcut"),
    ("com.example.playgame/com.example.playgame.", "Bare"),
    ("com.example.playgame/com.example.playgame.widget.ScoreWidgetProvider", "A widget"),
    ("com.example.playgame/com.example.playgame.MainActivity", "Play Game: Deluxe/Edition"),
    ("com.example.another/.Main", "Another"),
    ("com.example.unicode/com.example.unicode.MainActivity", "Wi\u2011Fi\tTool"),
    ("com.uberspot.a2048/com.uberspot.a2048.MainActivity", "2048"),
    ("com.example.system/.Main", "System thing"),
    ("com.google.android.gms/.Main", "Google Play services"),
    ("com.android.vending/.AssetBrowserActivity", "Play Store"),
    ("com.example.updated/.Main", "Updated"),
]
for component, label in rows:
    db.execute("insert into icons(componentName, profileId, label) values (?, 0, ?)", (component, label))
db.commit()
PY
}

run() {
    rc=0
    "${sync}" 2> "${T}/err" || rc=$?
    err=$(cat "${T}/err")
}

fixture
printf 'com.example.another\n' > "${MICROEMU_ANDROID_ROMS}/My Another.play"
run
[[ "${rc}" == 0 ]] || fail "exit ${rc}: ${err}"
[[ "$(cat "${MICROEMU_ANDROID_ROMS}/Play Game Deluxe Edition.play" 2>/dev/null)" == com.example.playgame ]] \
    || fail "play game not written: $(ls "${MICROEMU_ANDROID_ROMS}")"
[[ "$(cat "${MICROEMU_ANDROID_ROMS}/Wi‑Fi Tool.play" 2>/dev/null)" == com.example.unicode ]] || fail "unicode label: $(ls "${MICROEMU_ANDROID_ROMS}")"
[[ "$(ls "${MICROEMU_ANDROID_ROMS}" | wc -l)" == 3 ]] || fail "unexpected entries: $(ls "${MICROEMU_ANDROID_ROMS}")"
[[ "$(cat "${MICROEMU_ANDROID_ROMS}/My Another.play")" == com.example.another ]] || fail "renamed entry rewritten"
[[ "${err}" == *"wrote Play Game Deluxe Edition.play for com.example.playgame"* ]] || fail "no log line: ${err}"
[[ -e "${reload}" ]] || fail "no es-de reload request after new entries"
rm -f "${reload}"
run
[[ ! -e "${reload}" ]] || fail "reload requested with nothing written"

python3 - "${data}/data/com.android.launcher3/databases/app_icons.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("insert into icons(componentName, profileId, label) values ('com.example.nolabel/.Main', 0, 'Play Game: Deluxe Edition')")
db.commit()
PY
run
[[ "$(cat "${MICROEMU_ANDROID_ROMS}/Play Game Deluxe Edition (com.example.nolabel).play" 2>/dev/null)" == com.example.nolabel ]] \
    || fail "label clash not disambiguated: $(ls "${MICROEMU_ANDROID_ROMS}")"
rm -f "${MICROEMU_ANDROID_ROMS}/Play Game Deluxe Edition.play"
mv "${MICROEMU_ANDROID_ROMS}/Play Game Deluxe Edition (com.example.nolabel).play" "${MICROEMU_ANDROID_ROMS}/Renamed.play"
run
[[ "$(cat "${MICROEMU_ANDROID_ROMS}/Play Game Deluxe Edition.play")" == com.example.playgame ]] || fail "deleted entry not written again"
[[ "$(ls "${MICROEMU_ANDROID_ROMS}" | wc -l)" == 4 ]] || fail "renamed entry written again: $(ls "${MICROEMU_ANDROID_ROMS}")"

fixture
rm -rf "${MICROEMU_ANDROID_ROMS}"
run
[[ "${rc}" == 0 && "${err}" == *"missing, no .play entries written"* ]] || fail "no roms dir: exit ${rc}: ${err}"
[[ ! -e "${MICROEMU_ANDROID_ROMS}" ]] || fail "roms dir created"

fixture
rm -f "${data}/system/packages.xml"
run
[[ "${rc}" == 0 && "${err}" == *"cannot read"* ]] || fail "no packages.xml: exit ${rc}: ${err}"

fixture
mkdir -p "${data}/data/com.google.android.gsf/databases"
python3 - "${data}/data/com.google.android.gsf/databases/gservices.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("create table main(name text primary key, value text)")
db.execute("insert into main values ('android_id', '4500457175410760153')")
db.commit()
PY
run
[[ "$(cat "${MICROEMU_GAPPS}/gsf-id")" == 4500457175410760153 ]] || fail "gsf id not written"
[[ "${err}" == *"GSF ID 4500457175410760153, register it at https://www.google.com/android/uncertified"* ]] || fail "gsf id not logged: ${err}"
run
[[ "${err}" != *"GSF ID"* ]] || fail "unchanged gsf id logged again"

fixture
python3 - "${data}" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1] + "/data/com.android.launcher3/databases/app_icons.db")
db.execute("update icons set label = ? where componentName like 'com.example.another/%'", ("\u6f22" * 120,))
db.execute("update icons set label = ? where componentName like 'com.example.unicode/%'", ('a?b*c"d<e>f|g',))
db.commit()
PY
mkdir -p "${MICROEMU_ANDROID_ROMS}/sub/deeper"
printf 'com.example.playgame\n' > "${MICROEMU_ANDROID_ROMS}/sub/deeper/Mine.play"
run
[[ "${rc}" == 0 ]] || fail "names: exit ${rc}: ${err}"
cjk=$(find "${MICROEMU_ANDROID_ROMS}" -maxdepth 1 -name '*.play' -newer "${data}/system/packages.xml" | grep -v 'a b c' | grep -v 'Mine' | head -n 1)
[[ -n "${cjk}" ]] || fail "cjk entry not written: $(ls "${MICROEMU_ANDROID_ROMS}")"
bytes=$(basename "${cjk}" .play | LC_ALL=C wc -c)
(( bytes <= 201 )) || fail "cjk name is ${bytes} bytes"
basename "${cjk}" | iconv -f UTF-8 -t UTF-8 >/dev/null || fail "cjk name cut inside a character"
[[ -e "${MICROEMU_ANDROID_ROMS}/a b c d e f g.play" ]] || fail "fat illegal characters kept: $(ls "${MICROEMU_ANDROID_ROMS}")"
[[ ! -e "${MICROEMU_ANDROID_ROMS}/Play Game Deluxe Edition.play" ]] || fail "a package held in a subdirectory was written again"

fixture
mkdir -p "${data}/data/com.google.android.gsf/databases"
python3 - "${data}/data/com.google.android.gsf/databases/gservices.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("create table main(name text primary key, value text)")
db.execute("insert into main values ('android_id', '42')")
db.commit()
PY
chmod 0555 "${MICROEMU_ANDROID_ROMS}"
run
chmod 0755 "${MICROEMU_ANDROID_ROMS}"
[[ "${rc}" == 0 ]] || fail "unwritable roms: exit ${rc}: ${err}"
[[ "${err}" == *"cannot write Play Game Deluxe Edition.play for com.example.playgame"* ]] || fail "unwritable roms: no log line: ${err}"
[[ "$(cat "${MICROEMU_GAPPS}/gsf-id")" == 42 ]] || fail "unwritable roms: gsf id not written first"

fixture
sed -i 's#^</packages>#<package name="com.example.gone" codePath="/data/app/g2" publicFlags="944291398" version="1" installer="com.android.vending" />\n</packages>#' "${data}/system/packages.xml"
mkdir -p "${MICROEMU_ANDROID_ROMS}/sub"
printf 'com.example.never\n' > "${MICROEMU_ANDROID_ROMS}/Never Installed.play"
run
grep -qx com.example.gone "${seen}" || fail "installed packages not recorded: $(cat "${seen}" 2>/dev/null)"
[[ -e "${MICROEMU_ANDROID_ROMS}/Never Installed.play" ]] || fail "a .play for a package never installed was removed"
sed -i '/name="com.example.gone"/d' "${data}/system/packages.xml"
printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/Princess Connect.play"
printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/sub/Moved.PLAY"
printf 'com.uberspot.a2048\n' > "${MICROEMU_ANDROID_ROMS}/Sideloaded.play"
printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/Other.update"
printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/Game.apk"
printf 'com.android.vending\n' > "${MICROEMU_ANDROID_ROMS}/Google Play.play"
printf 'com.android.vending\n' > "${MICROEMU_ANDROID_ROMS}/Store.play"
printf 'not a package\n' > "${MICROEMU_ANDROID_ROMS}/Odd.play"
rm -f "${reload}"
run
[[ ! -e "${MICROEMU_ANDROID_ROMS}/Princess Connect.play" && ! -e "${MICROEMU_ANDROID_ROMS}/sub/Moved.PLAY" ]] || fail "entry of an uninstalled package kept: $(ls -R "${MICROEMU_ANDROID_ROMS}")"
[[ "${err}" == *"removed Princess Connect.play, com.example.gone not installed"* ]] || fail "removal not logged: ${err}"
[[ -e "${reload}" ]] || fail "no es-de reload request after a removal"
for kept in Sideloaded.play Other.update Game.apk "Google Play.play" Store.play Odd.play "Never Installed.play"; do
    [[ -e "${MICROEMU_ANDROID_ROMS}/${kept}" ]] || fail "${kept} removed"
done
grep -qx com.example.gone "${seen}" && fail "an uninstalled package kept in ${seen}"
printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/Princess Connect.play"
run
[[ -e "${MICROEMU_ANDROID_ROMS}/Princess Connect.play" ]] || fail "a .play made after the uninstall was removed"
fixture
printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/Princess Connect.play"
run
[[ -e "${MICROEMU_ANDROID_ROMS}/Princess Connect.play" ]] || fail "first sync with no record removed an entry"
fixture
sed -i '/name="com.android.vending"/d' "${data}/system/packages.xml"
printf 'com.android.vending\n' > "${MICROEMU_ANDROID_ROMS}/Store.play"
mkdir -p "${MICROEMU_ANDROID_DATA}"
printf 'com.android.vending\n' > "${seen}"
run
[[ -e "${MICROEMU_ANDROID_ROMS}/Store.play" ]] || fail "a Play Store entry removed with vending missing from packages.xml"
for broken in garbage empty missing; do
    fixture
    printf 'com.example.gone\n' > "${MICROEMU_ANDROID_ROMS}/Princess Connect.play"
    mkdir -p "${MICROEMU_ANDROID_DATA}"
    printf 'com.example.gone\n' > "${seen}"
    case "${broken}" in
        garbage) echo '<packages><package name=' > "${data}/system/packages.xml" ;;
        empty) echo '<packages></packages>' > "${data}/system/packages.xml" ;;
        missing) rm -f "${data}/system/packages.xml" ;;
    esac
    rm -f "${reload}"
    run
    [[ -e "${MICROEMU_ANDROID_ROMS}/Princess Connect.play" ]] || fail "packages.xml ${broken}: entry removed"
    [[ "${err}" == *"no .play entry removed"* ]] || fail "packages.xml ${broken}: guard not logged: ${err}"
    [[ "$(cat "${seen}")" == com.example.gone ]] || fail "packages.xml ${broken}: record changed"
done

entry="${MICROEMU_ANDROID_ROMS}/Update Google Play.update"
fixture
run
[[ ! -e "${entry}" ]] || fail "update entry written with the layer off"
mkdir -p "${MICROEMU_GAPPS}/set"
ln -s set "${MICROEMU_GAPPS}/current"
rm -f "${reload}"
run
[[ -f "${entry}" ]] || fail "update entry not written with the layer on"
[[ -e "${MICROEMU_GAPPS}/update-entry" ]] || fail "update entry marker not written"
[[ -e "${reload}" ]] || fail "no es-de reload request after the update entry"
[[ "${err}" == *"wrote Update Google Play.update"* ]] || fail "update entry not logged: ${err}"
rm -f "${entry}" "${reload}"
run
[[ ! -e "${entry}" ]] || fail "deleted update entry written again"
rm -f "${MICROEMU_GAPPS}/update-entry"
mkdir -p "${MICROEMU_ANDROID_ROMS}/sub"
: > "${MICROEMU_ANDROID_ROMS}/sub/Mine.update"
run
[[ ! -e "${entry}" ]] || fail "update entry written next to an existing .update elsewhere"

if (( failures )); then
    echo "sync-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "sync-test: ok"
