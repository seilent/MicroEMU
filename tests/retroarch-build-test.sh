#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
script="${repo}/build/retroarch.sh"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
cat > "${T}/bin/rpm2cpio" <<'STUB'
#!/usr/bin/bash
cat "$1"
STUB
chmod 0755 "${T}/bin/rpm2cpio"
export PATH="${T}/bin:${PATH}"
export MICROEMU_KOJI_URL="file://${T}/koji"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

cores="mednafen_ngp mednafen_pce_fast mednafen_vb mednafen_wswan bsnes_mercury_performance gambatte gw handy mgba
nestopia pcsx_rearmed prosystem stella2014"

package() {
    local name=$1 tree="${T}/tree/$1" rpm dir
    rpm="${name}-1.0-1.fc44.aarch64.rpm"
    dir="${T}/koji/${name}/1.0/1.fc44/aarch64"
    mkdir -p "${dir}"
    (cd "${tree}" && find . | cpio -o -H newc --quiet) > "${dir}/${rpm}"
    printf '%s 1.0 1.fc44 %s\n' "${name}" "$(sha256sum "${dir}/${rpm}" | cut -d' ' -f1)"
}

build_tree() {
    local drop=${1:-} core
    rm -rf "${T}/tree" "${T}/koji"
    mkdir -p "${T}/tree/retroarch/usr/bin" "${T}/tree/retroarch/usr/share/libretro/info" \
        "${T}/tree/retroarch/usr/share/libretro/autoconfig/udev" "${T}/tree/retroarch/usr/share/licenses/retroarch" \
        "${T}/tree/mbedtls/usr/lib64" "${T}/tree/mbedtls/usr/share/licenses/mbedtls" \
        "${T}/tree/cores/usr/lib64/libretro" "${T}/tree/cores/usr/share/licenses/cores"
    printf '#!/bin/sh\n' > "${T}/tree/retroarch/usr/bin/retroarch"
    chmod 0755 "${T}/tree/retroarch/usr/bin/retroarch"
    echo pad > "${T}/tree/retroarch/usr/share/libretro/autoconfig/udev/Microsoft X-Box 360 pad.cfg"
    echo gpl > "${T}/tree/retroarch/usr/share/licenses/retroarch/COPYING"
    echo extra > "${T}/tree/retroarch/usr/share/licenses/retroarch/NOTICE"
    echo apache > "${T}/tree/mbedtls/usr/share/licenses/mbedtls/LICENSE"
    echo gpl > "${T}/tree/cores/usr/share/licenses/cores/COPYING"
    for so in libmbedtls.so.3.6.7 libmbedcrypto.so.3.6.7 libmbedx509.so.3.6.7; do
        echo lib > "${T}/tree/mbedtls/usr/lib64/${so}"
    done
    ln -s libmbedtls.so.3.6.7 "${T}/tree/mbedtls/usr/lib64/libmbedtls.so.21"
    ln -s libmbedcrypto.so.3.6.7 "${T}/tree/mbedtls/usr/lib64/libmbedcrypto.so.16"
    ln -s libmbedx509.so.3.6.7 "${T}/tree/mbedtls/usr/lib64/libmbedx509.so.7"
    for core in ${cores}; do
        echo core > "${T}/tree/cores/usr/lib64/libretro/${core}_libretro.so"
        echo info > "${T}/tree/retroarch/usr/share/libretro/info/${core}_libretro.info"
    done
    echo other > "${T}/tree/retroarch/usr/share/libretro/info/snes9x_libretro.info"
    case "${drop}" in
        soname) rm "${T}/tree/mbedtls/usr/lib64/libmbedx509.so.7" ;;
        core) rm "${T}/tree/cores/usr/lib64/libretro/gw_libretro.so" ;;
        info) rm "${T}/tree/retroarch/usr/share/libretro/info/mgba_libretro.info" ;;
        license) rm -r "${T}/tree/mbedtls/usr/share/licenses" ;;
        autoconfig) rm -r "${T}/tree/retroarch/usr/share/libretro/autoconfig" ;;
    esac
    MICROEMU_RETROARCH_RPMS=$(package retroarch; package mbedtls; package cores)
    export MICROEMU_RETROARCH_RPMS
}

cache="${T}/cache"
dist="${T}/dist"

run() {
    rc=0
    rm -rf "${dist}"
    out=$(bash "${script}" "${cache}" "${dist}" 2>"${T}/err") || rc=$?
    err=$(cat "${T}/err")
}

leftover() {
    [[ -z "$(find "${dist}" -maxdepth 1 -name '.retroarch.*' 2>/dev/null)" ]] || fail "$1: work directory left in dist"
}

build_tree
run
[[ "${rc}" == 0 ]] || fail "fresh exit ${rc}: ${err}"
[[ -x "${dist}/usr/lib/microemu/retroarch/bin/retroarch" ]] || fail "fresh: retroarch missing"
[[ -L "${dist}/usr/lib/microemu/retroarch/lib64/libmbedtls.so.21" && -f "${dist}/usr/lib/microemu/retroarch/lib64/libmbedtls.so.3.6.7" ]] \
    || fail "fresh: mbedtls soname link or library missing"
[[ "$(find "${dist}/usr/lib64/libretro" -name '*_libretro.so' | wc -l)" == 13 ]] || fail "fresh: core count"
[[ "$(find "${dist}/usr/share/microemu/retroarch/info" -name '*.info' | wc -l)" == 13 ]] || fail "fresh: info count, other cores copied"
[[ -f "${dist}/usr/share/microemu/retroarch/autoconfig/udev/Microsoft X-Box 360 pad.cfg" ]] || fail "fresh: autoconfig missing"
[[ -f "${dist}/usr/share/licenses/microemu/retroarch/COPYING" && -f "${dist}/usr/share/licenses/microemu/retroarch/NOTICE" ]] \
    || fail "fresh: not every retroarch license file copied"
[[ -f "${dist}/usr/share/licenses/microemu/mbedtls/LICENSE" && -f "${dist}/usr/share/licenses/microemu/cores/COPYING" ]] \
    || fail "fresh: per rpm license directories missing"
[[ "${out}" == *"RETROARCH_VERSION=1.0-1.fc44"* ]] || fail "fresh: version not from the retroarch row: ${out}"
[[ "${out}" == *"RETROARCH_CORES=13"* ]] || fail "fresh: core count line: ${out}"
leftover fresh

rm -rf "${T}/koji"
run
[[ "${rc}" == 0 ]] || fail "cache hit exit ${rc}: ${err}"

build_tree
rm -rf "${cache}"
MICROEMU_RETROARCH_RPMS=$(sed '1s/ [0-9a-f]*$/ 0000000000000000000000000000000000000000000000000000000000000000/' <<<"${MICROEMU_RETROARCH_RPMS}") run
[[ "${rc}" == 1 && "${err}" == *"sha256 mismatch for retroarch-1.0-1.fc44.aarch64.rpm"* ]] || fail "sha mismatch exit ${rc}: ${err}"
[[ -z "$(find "${cache}" -name '*.part')" && ! -e "${cache}/retroarch-1.0-1.fc44.aarch64.rpm" ]] || fail "sha mismatch: asset kept"

rm -rf "${cache}"
MICROEMU_KOJI_URL="file://${T}/nowhere" run
[[ "${rc}" == 1 && "${err}" == *"download failed: file://${T}/nowhere/retroarch/"* ]] || fail "unreachable exit ${rc}: ${err}"
[[ -z "$(find "${cache}" -name '*.part')" ]] || fail "unreachable: partial download kept"

for drop in soname core info license autoconfig; do
    build_tree "${drop}"
    rm -rf "${cache}"
    run
    [[ "${rc}" == 1 ]] || fail "missing ${drop} exit ${rc}, expected 1"
    case "${drop}" in
        soname) expected="libmbedx509.so.7 missing in the mbedtls rpm" ;;
        core) expected="gw_libretro.so missing in the core rpms" ;;
        info) expected="mgba_libretro.info missing in the retroarch rpm" ;;
        license) expected="no license file in mbedtls-1.0-1.fc44.aarch64.rpm" ;;
        autoconfig) expected="usr/share/libretro/autoconfig/udev missing in the retroarch rpm" ;;
    esac
    [[ "${err}" == *"${expected}"* ]] || fail "missing ${drop}: ${err}"
    leftover "missing ${drop}"
done

if (( failures )); then
    echo "retroarch-build-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "retroarch-build-test: ok"
