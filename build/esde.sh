#!/usr/bin/bash
set -euo pipefail

ESDE_VERSION=3.5.0
ESDE_URL="${MICROEMU_ESDE_URL:-https://gitlab.com/es-de/emulationstation-de/-/package_files/357718204/download}"
ESDE_SHA="${MICROEMU_ESDE_SHA:-b6d34657842db89628d5bc42ed465b605108b45cb1d16b15332d6c9f60136a4b}"
ESDE_FILE="ES-DE_${ESDE_VERSION}_aarch64.AppImage"

cache=$1
dist=$2
dest="${dist}/usr/lib/microemu/es-de"

fail() { echo "esde.sh: $*" >&2; exit 1; }

file="${cache}/${ESDE_FILE}"
mkdir -p "${cache}"
if ! echo "${ESDE_SHA}  ${file}" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL --retry 3 --connect-timeout 30 -o "${file}.part" "${ESDE_URL}" || { rm -f "${file}.part"; fail "download failed: ${ESDE_URL}"; }
    echo "${ESDE_SHA}  ${file}.part" | sha256sum -c --status || { rm -f "${file}.part"; fail "sha256 mismatch for ${ESDE_FILE}"; }
    mv "${file}.part" "${file}"
fi

mkdir -p "${dist}"
work=$(mktemp -d "${dist}/.esde.XXXXXX")
trap 'rm -rf "${work}"' EXIT

[[ "$(od -An -t x1 -N 6 "${file}" | tr -d ' ')" == 7f454c460201 ]] || fail "${ESDE_FILE} is not a little endian ELF64 file"
shoff=$(od -An -t u8 -j 40 -N 8 "${file}")
shentsize=$(od -An -t u2 -j 58 -N 2 "${file}")
shnum=$(od -An -t u2 -j 60 -N 2 "${file}")
offset=$((shoff + shentsize * shnum))
[[ "$(dd if="${file}" bs=1 skip="${offset}" count=4 2>/dev/null)" == hsqs ]] || fail "no squashfs at offset ${offset} in ${ESDE_FILE}"
unsquashfs -q -n -o "${offset}" -d "${work}/root" "${file}" >/dev/null || fail "unsquashfs failed for ${ESDE_FILE}"
[[ -f "${work}/root/AppRun" && -x "${work}/root/AppRun" ]] || fail "AppRun missing in ${ESDE_FILE}"
[[ -f "${work}/root/usr/share/es-de/LICENSE" ]] || fail "usr/share/es-de/LICENSE missing in ${ESDE_FILE}"

rm -rf "${dest}"
mkdir -p "$(dirname "${dest}")" "${dist}/usr/share/licenses/microemu"
mv "${work}/root" "${dest}"
cp "${dest}/usr/share/es-de/LICENSE" "${dist}/usr/share/licenses/microemu/es-de.txt"

echo "ESDE_VERSION=${ESDE_VERSION}"
echo "ESDE_SHA256=${ESDE_SHA}"
echo "ESDE_ASSET_BYTES=$(stat -c %s "${file}")"
echo "ESDE_TREE_BYTES=$(du -sb "${dest}" | cut -f1)"
