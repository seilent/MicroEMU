#!/usr/bin/bash
set -eu

export MICROEMU_TEST=1

export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
install_cmd="${repo}/sysext/usr/bin/microemu-gapps-install"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/zip11/system/product/etc/permissions" "${T}/zip14/system/product/etc/permissions" \
    "${T}/zip11/system/system_ext/priv-app/GoogleServicesFramework" "${T}/zip14/system/product/priv-app/Phonesky"
export STATE="${T}/state"
export MICROEMU_GAPPS="${T}/gapps"
export MICROEMU_GAPPS_CACHE="${T}/cache"
export MICROEMU_ANDROID_ROMS="${T}/roms"
export MICROEMU_PLAY_UPDATE="${T}/bin/update"
set_dir="${MICROEMU_GAPPS}/mtg11-20230922.vending-36.6.25"

echo gsf > "${T}/zip11/system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"
echo phonesky > "${T}/zip14/system/product/priv-app/Phonesky/Phonesky.apk"
cat > "${T}/zip11/system/product/etc/permissions/privapp-permissions-google-p.xml" <<'XML'
<permissions>
    <privapp-permissions package="com.google.android.gms">
        <permission name="a"/>
    </privapp-permissions>
    <privapp-permissions package="com.android.vending">
        <permission name="old"/>
    </privapp-permissions>
</permissions>
XML
cat > "${T}/zip14/system/product/etc/permissions/privapp-permissions-google-product.xml" <<'XML'
<permissions>
    <privapp-permissions package="com.android.vending">
        <permission name="old"/>
        <permission name="new"/>
    </privapp-permissions>
</permissions>
XML
(cd "${T}/zip11" && zip -q -r ../mtg11.zip system)
(cd "${T}/zip14" && zip -q -r ../mtg14.zip system)
sha() { sha256sum "$1" | cut -d' ' -f1; }
merged_sha=$(python3 - "${T}" <<'PY'
import hashlib, sys
t = sys.argv[1]
base = open(t + "/zip11/system/product/etc/permissions/privapp-permissions-google-p.xml").read()
donor = open(t + "/zip14/system/product/etc/permissions/privapp-permissions-google-product.xml").read()
start, end = base.index('    <privapp-permissions package="com.android.vending">'), base.index("</permissions>")
dstart, dend = donor.index('    <privapp-permissions package="com.android.vending">'), donor.index("</permissions>")
print(hashlib.sha256((base[:start] + donor[dstart:dend] + base[end:]).encode()).hexdigest())
PY
)
export MICROEMU_GAPPS_MTG11_SIZE MICROEMU_GAPPS_MTG11_SHA MICROEMU_GAPPS_MTG14_SIZE MICROEMU_GAPPS_MTG14_SHA
MICROEMU_GAPPS_MTG11_SIZE=$(stat -c %s "${T}/mtg11.zip")
MICROEMU_GAPPS_MTG11_SHA=$(sha "${T}/mtg11.zip")
MICROEMU_GAPPS_MTG14_SIZE=$(stat -c %s "${T}/mtg14.zip")
MICROEMU_GAPPS_MTG14_SHA=$(sha "${T}/mtg14.zip")
export MICROEMU_GAPPS_DONOR_SHA MICROEMU_GAPPS_MERGED_SOURCE_SHA MICROEMU_GAPPS_FILES
MICROEMU_GAPPS_DONOR_SHA=$(sha "${T}/zip14/system/product/etc/permissions/privapp-permissions-google-product.xml")
MICROEMU_GAPPS_MERGED_SOURCE_SHA=$(sha "${T}/zip11/system/product/etc/permissions/privapp-permissions-google-p.xml")
MICROEMU_GAPPS_FILES="
11 system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk $(sha "${T}/zip11/system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk")
14 system/product/priv-app/Phonesky/Phonesky.apk $(sha "${T}/zip14/system/product/priv-app/Phonesky/Phonesky.apk")
merged system/product/etc/permissions/privapp-permissions-google-p.xml ${merged_sha}
"

cat > "${T}/bin/curl" <<'STUB'
#!/usr/bin/bash
echo "curl $*" >> "${STATE}/curl"
out= url=
while (( $# )); do
    case "$1" in
        -o) out=$2; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
[[ -e "${STATE}/curl_fail" ]] && exit 22
case "${url}" in
    *11.0.0*) cp "${T_ZIP11}" "${out}" ;;
    *14.0.0*) cp "${T_ZIP14}" "${out}" ;;
esac
[[ ! -e "${STATE}/corrupt" ]] || echo x >> "${out}"
STUB
cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
case "$*" in
    *microemu-play-update.service*) cat "${STATE}/update_unit" ;;
    *) cat "${STATE}/unit" ;;
esac
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
case "$*" in
    *headless*) exit "$(cat "${STATE}/headless_rc")" ;;
    *) exit "$(cat "${STATE}/exists_rc")" ;;
esac
STUB
cat > "${T}/bin/update" <<'STUB'
#!/usr/bin/bash
echo "update $*" >> "${STATE}/update"
[[ -e "${MICROEMU_GAPPS}/current" ]] || echo "update before current" >> "${STATE}/update"
exit "$(cat "${STATE}/update_rc")"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"
export T_ZIP11="${T}/mtg11.zip" T_ZIP14="${T}/mtg14.zip"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    [[ ! -d "${MICROEMU_GAPPS}" ]] || chmod -R u+w "${MICROEMU_GAPPS}"
    rm -rf "${STATE}" "${MICROEMU_GAPPS}" "${MICROEMU_GAPPS_CACHE}" "${MICROEMU_ANDROID_ROMS}"
    mkdir -p "${STATE}"
    : > "${STATE}/curl"
    echo inactive > "${STATE}/unit"
    echo inactive > "${STATE}/update_unit"
    echo 1 > "${STATE}/exists_rc"
    echo 1 > "${STATE}/headless_rc"
    echo 0 > "${STATE}/update_rc"
    : > "${STATE}/update"
}

run() {
    rc=0
    "${install_cmd}" > "${STATE}/out" 2>&1 || rc=$?
}

reset
run
[[ "${rc}" == 0 ]] || fail "install exit ${rc}: $(cat "${STATE}/out")"
[[ "$(readlink "${MICROEMU_GAPPS}/current")" == mtg11-20230922.vending-36.6.25 ]] || fail "current not switched"
[[ "$(head -n 1 "${set_dir}/STAMP")" == "set=mtg11-20230922.vending-36.6.25" ]] || fail "STAMP header"
[[ "$(grep -c . "${set_dir}/STAMP")" == 4 ]] || fail "STAMP lines: $(cat "${set_dir}/STAMP")"
grep -qx "$(sha "${set_dir}/system/product/priv-app/Phonesky/Phonesky.apk") 9 system/product/priv-app/Phonesky/Phonesky.apk" "${set_dir}/STAMP" \
    || fail "STAMP Phonesky line: $(cat "${set_dir}/STAMP")"
grep -q 'name="new"' "${set_dir}/system/product/etc/permissions/privapp-permissions-google-p.xml" || fail "vending block not merged"
grep -q 'com.google.android.gms' "${set_dir}/system/product/etc/permissions/privapp-permissions-google-p.xml" || fail "merge lost other blocks"
[[ ! -w "${set_dir}/system/product/priv-app/Phonesky/Phonesky.apk" && ! -w "${set_dir}" ]] || fail "set is writable"
[[ ! -e "${MICROEMU_GAPPS}/mtg11-20230922.vending-36.6.25.tmp" ]] || fail ".tmp left"
[[ -z "$(ls -A "${MICROEMU_GAPPS_CACHE}")" ]] || fail "zips not deleted: $(ls -A "${MICROEMU_GAPPS_CACHE}")"
[[ "$(cat "${MICROEMU_ANDROID_ROMS}/Google Play.play")" == com.android.vending ]] || fail "Google Play.play not written"
[[ -f "${MICROEMU_ANDROID_ROMS}/Update Google Play.update" ]] || fail "Update Google Play.update not written"
[[ -e "${MICROEMU_GAPPS}/update-entry" ]] || fail "update entry marker not written"
[[ "$(cat "${STATE}/update")" == "update --setup" ]] || fail "update not run once in the foreground after current: $(cat "${STATE}/update")"
[[ "$(grep -c -- '--proto =https --proto-redir =https' "${STATE}/curl")" == 2 ]] || fail "curl not https only: $(cat "${STATE}/curl")"
stamp_mtime=$(stat -c %Y "${set_dir}/STAMP")
newest=$(find "${set_dir}" -type f -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2)
[[ "${newest}" == "${set_dir}/STAMP" ]] || fail "STAMP is not the last file written: ${newest}"

: > "${STATE}/curl"
run
[[ "${rc}" == 0 ]] || fail "rerun exit ${rc}"
[[ ! -s "${STATE}/curl" ]] || fail "rerun downloaded again"
grep -q "already installed" "${STATE}/out" || fail "rerun message"
rm -f "${MICROEMU_ANDROID_ROMS}/Update Google Play.update" "${MICROEMU_ANDROID_ROMS}/Google Play.play"
run
[[ ! -e "${MICROEMU_ANDROID_ROMS}/Update Google Play.update" ]] || fail "rerun wrote a deleted update entry"
[[ -f "${MICROEMU_ANDROID_ROMS}/Google Play.play" ]] || fail "rerun did not restore Google Play.play"
: > "${STATE}/curl"
[[ "$(stat -c %Y "${set_dir}/STAMP")" == "${stamp_mtime}" ]] || fail "rerun rewrote the set"

reset
mkdir -p "${MICROEMU_GAPPS}/mtg11-20230922.vending-36.6.25.tmp/system"
echo partial > "${MICROEMU_GAPPS}/mtg11-20230922.vending-36.6.25.tmp/system/half.apk"
chmod -R a-w "${MICROEMU_GAPPS}/mtg11-20230922.vending-36.6.25.tmp"
run
[[ "${rc}" == 0 ]] || fail "interrupted rerun exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${set_dir}/system/half.apk" ]] || fail "interrupted .tmp content carried over"

reset
: > "${STATE}/corrupt"
run
[[ "${rc}" == 1 ]] || fail "corrupt zip exit ${rc}"
grep -q "size differs" "${STATE}/out" || fail "corrupt zip message: $(cat "${STATE}/out")"
[[ ! -e "${MICROEMU_GAPPS}/current" && -z "$(ls -A "${MICROEMU_GAPPS_CACHE}")" ]] || fail "corrupt zip left state"

reset
MICROEMU_GAPPS_MTG11_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 ]] && grep -q "sha256 mismatch" "${STATE}/out" || fail "bad zip sha: exit ${rc}: $(cat "${STATE}/out")"

reset
MICROEMU_GAPPS_FILES="${MICROEMU_GAPPS_FILES/$(sha "${T}/zip14/system/product/priv-app/Phonesky/Phonesky.apk")/1111111111111111111111111111111111111111111111111111111111111111}" run
[[ "${rc}" == 1 ]] && grep -q "Phonesky.apk from MindTheGapps-14.0.0-arm64-20250203_200051.zip: sha256 mismatch" "${STATE}/out" || fail "bad file sha: exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${MICROEMU_GAPPS}/current" && ! -e "${set_dir}" ]] || fail "bad file sha installed something"

reset
: > "${STATE}/curl_fail"
run
[[ "${rc}" == 1 ]] && grep -q "download failed" "${STATE}/out" || fail "download failure: exit ${rc}"

reset
echo active > "${STATE}/unit"
run
[[ "${rc}" == 1 ]] && grep -q "running, refusing" "${STATE}/out" || fail "unit running: exit ${rc}"
reset
echo activating > "${STATE}/update_unit"
run
[[ "${rc}" == 1 ]] && grep -q "microemu-play-update.service is running, refusing" "${STATE}/out" || fail "update running: exit ${rc}"
reset
echo 0 > "${STATE}/exists_rc"
run
[[ "${rc}" == 1 ]] && grep -q "exists, refusing" "${STATE}/out" || fail "container present: exit ${rc}"
[[ ! -s "${STATE}/curl" ]] || fail "downloaded with the container present"
reset
echo 0 > "${STATE}/headless_rc"
run
[[ "${rc}" == 1 ]] && grep -q "container lepton-headless-microemu-play exists, refusing" "${STATE}/out" || fail "headless container present: exit ${rc}"
[[ ! -s "${STATE}/update" ]] || fail "update run with the headless container present"

reset
echo 1 > "${STATE}/update_rc"
run
[[ "${rc}" == 1 ]] && grep -q "Play services not updated, run microemu-gapps-install again" "${STATE}/out" || fail "update failure: exit ${rc}: $(cat "${STATE}/out")"
[[ -e "${MICROEMU_GAPPS}/current" ]] || fail "update failure removed the layer"
echo 0 > "${STATE}/update_rc"
: > "${STATE}/update"
run
[[ "${rc}" == 0 ]] && grep -q "already installed" "${STATE}/out" && [[ -s "${STATE}/update" ]] || fail "rerun after an update failure: exit ${rc}"

reset
MICROEMU_TEST='' run
[[ "${rc}" == 1 ]] || fail "overrides without MICROEMU_TEST: exit ${rc}"
grep -q "size differs from 194494611" "${STATE}/out" || fail "overrides honored without MICROEMU_TEST: $(cat "${STATE}/out")"

if (( failures )); then
    echo "gapps-install-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "gapps-install-test: ok"
