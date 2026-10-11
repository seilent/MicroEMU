#!/usr/bin/bash
set -euo pipefail

KOJI="${MICROEMU_KOJI_URL:-https://kojipkgs.fedoraproject.org/packages}"

PINS="
retroarch 1.22.0 20.fc44 301c745dd09d991e416e1fa82b36fc043181bd96d9490f5f17f63c41dec35cb3
mbedtls 3.6.7 1.fc44 86de481a46add50cd5e282c23ab60f3d00acc8547699a0b9ea671fda6c29675e
libretro-beetle-ngp 0 0.10.27.20251224git139fe34.fc44 ab5f91c3037a933860297a3fbd28ff47abfebd3ce782bf97877a32023e8a77b5
libretro-beetle-pce-fast 0 0.10.28.20251224git7e9b257.fc44 2bf8828614abfe80fd16fdaa5edd9d6feaf17a657ea4f4e6f1cf57bf7d7074f6
libretro-beetle-vb 0 0.10.26.20260129git8f837eb.fc44 d4cfdfbe85157a9725c86aaf425084e9ff840fbfe2f0206e147926581ce30c66
libretro-beetle-wswan 0 0.8.27.20240510git32bf70a.fc44 6c57dcbe3a21038e11b50b5ec923ce19d2505c9690db6aec86536901678d4e53
libretro-bsnes-mercury 0 0.12.26.20240513git60c204c.fc44 05bd071937647d83233996d763e7601188e225f28f055d41a42e197375546d45
libretro-gambatte 0 0.9.29.20240507git04486b4.fc44 19ccb2ddd1423e29c15caa37c5737bad5dab789a5467706f59967a432a30bdba
libretro-gw 0 7.23.20240512git0ecff52.fc44 08fc5ac53aa3bc8018b3d884c3b5b3907f6fd2af81a20ccb11ac1e492455c789
libretro-handy 0 0.10.24.20240514git65d6b86.fc44 d3145dc065147c1d3aac2be3d3d72836c9aebee11e797bcf8c12bfa1bc0ab232
libretro-mgba 0.1.1 0.9.28.20240513gitb256448.fc44 896e88f31deadd3db31f63b43ca8408d70beaff2682c036b22d9f2f940bd838c
libretro-nestopia 0 0.9.27.20240514gitb99ede3.fc44 9a6d77ccb02da43faa05d8052e161ee470b27e430f2336d85d6112c7e99df3da
libretro-pcsx-rearmed 15 0.17.20251216git8d91fbd.44.fc44 3f68f1272fcac55ba613bfc9b7aa9aead97186998686e84b68c8f862deceae9d
libretro-prosystem 0 0.10.27.20240514git4202ac5.fc44 f4f17902580dddeaaaad4c16125a002969e9d945292127d702a9add2c2a029bf
libretro-stella2014 0 0.7.23.20240514git8ab051e.fc44 90e30988ba5f1f182801bb8f59eb1ebf7ea5ca5aa8b4f29ad4491f4135f355ad
"
RPMS="${MICROEMU_RETROARCH_RPMS:-${PINS}}"

CORES="
mednafen_ngp_libretro.so
mednafen_pce_fast_libretro.so
mednafen_vb_libretro.so
mednafen_wswan_libretro.so
bsnes_mercury_performance_libretro.so
gambatte_libretro.so
gw_libretro.so
handy_libretro.so
mgba_libretro.so
nestopia_libretro.so
pcsx_rearmed_libretro.so
prosystem_libretro.so
stella2014_libretro.so
"

cache=$1
dist=$2

fail() { echo "retroarch.sh: $*" >&2; exit 1; }

fetch() {
    local url=$1 sha=$2 file=$3
    if echo "${sha}  ${file}" | sha256sum -c --status 2>/dev/null; then
        return 0
    fi
    curl -fsSL --retry 3 --connect-timeout 30 -o "${file}.part" "${url}" || { rm -f "${file}.part"; fail "download failed: ${url}"; }
    echo "${sha}  ${file}.part" | sha256sum -c --status || { rm -f "${file}.part"; fail "sha256 mismatch for $(basename "${file}")"; }
    mv "${file}.part" "${file}"
}

mkdir -p "${cache}" "${dist}"
work=$(mktemp -d "${dist}/.retroarch.XXXXXX")
trap 'rm -rf "${work}"' EXIT

lib="${dist}/usr/lib/microemu/retroarch"
share="${dist}/usr/share/microemu/retroarch"
licenses="${dist}/usr/share/licenses/microemu"
mkdir -p "${lib}/bin" "${lib}/lib64" "${dist}/usr/lib64/libretro" "${share}/info" "${share}/autoconfig" "${licenses}"

while read -r name version release sha; do
    [[ -n "${name}" ]] || continue
    rpm="${name}-${version}-${release}.aarch64.rpm"
    fetch "${KOJI}/${name}/${version}/${release}/aarch64/${rpm}" "${sha}" "${cache}/${rpm}"
    mkdir -p "${work}/${name}"
    rpm2cpio "${cache}/${rpm}" > "${work}/${name}.cpio" || fail "cannot unpack ${rpm}"
    (cd "${work}/${name}" && cpio -idm --quiet) < "${work}/${name}.cpio" || fail "cannot unpack ${rpm}"
    rm -f "${work}/${name}.cpio"
    [[ -n "$(find "${work}/${name}/usr/share/licenses" -type f 2>/dev/null)" ]] || fail "no license file in ${rpm}"
    mkdir -p "${licenses}/${name}"
    find "${work}/${name}/usr/share/licenses" -type f -exec cp {} "${licenses}/${name}/" \;
done <<< "${RPMS}"

ra="${work}/retroarch"
[[ -x "${ra}/usr/bin/retroarch" ]] || fail "usr/bin/retroarch missing in the retroarch rpm"
cp -a "${ra}/usr/bin/retroarch" "${lib}/bin/"
[[ -d "${ra}/usr/share/libretro/autoconfig/udev" ]] || fail "usr/share/libretro/autoconfig/udev missing in the retroarch rpm"
cp -a "${ra}/usr/share/libretro/autoconfig/udev" "${share}/autoconfig/"

for so in libmbedtls.so.21 libmbedcrypto.so.16 libmbedx509.so.7; do
    [[ -e "${work}/mbedtls/usr/lib64/${so}" ]] || fail "${so} missing in the mbedtls rpm"
done
cp -a "${work}"/mbedtls/usr/lib64/libmbed*.so.* "${lib}/lib64/"

for core in ${CORES}; do
    found=$(find "${work}" -path '*/usr/lib64/libretro/*' -name "${core}" | head -n 1)
    [[ -n "${found}" ]] || fail "${core} missing in the core rpms"
    cp -a "${found}" "${dist}/usr/lib64/libretro/"
    [[ -f "${ra}/usr/share/libretro/info/${core%.so}.info" ]] || fail "${core%.so}.info missing in the retroarch rpm"
    cp -a "${ra}/usr/share/libretro/info/${core%.so}.info" "${share}/info/"
done

echo "RETROARCH_VERSION=$(awk '$1 == "retroarch" { print $2 "-" $3 }' <<< "${RPMS}")"
echo "RETROARCH_CORES=$(wc -w <<< "${CORES}")"
