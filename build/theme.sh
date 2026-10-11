#!/usr/bin/bash
set -euo pipefail

THEME_NAME=art-book-next-es-de
THEME_REV=d772d07109701d9bd7c9fda305bfef6601105ab8
THEME_URL="${MICROEMU_THEME_URL:-https://github.com/anthonycaccese/art-book-next-es-de/archive/${THEME_REV}.tar.gz}"
THEME_SHA="${MICROEMU_THEME_SHA:-430110584bafa614b7a3f4af1891c675e58de60e6658e3758d0724554f77ebd3}"
THEME_FILE="${THEME_NAME}-${THEME_REV}.tar.gz"

cache=$1
dist=$2
dest="${dist}/usr/share/microemu/es-de/themes/${THEME_NAME}"

fail() { echo "theme.sh: $*" >&2; exit 1; }

file="${cache}/${THEME_FILE}"
mkdir -p "${cache}"
if ! echo "${THEME_SHA}  ${file}" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL --retry 3 --connect-timeout 30 -o "${file}.part" "${THEME_URL}" || { rm -f "${file}.part"; fail "download failed: ${THEME_URL}"; }
    echo "${THEME_SHA}  ${file}.part" | sha256sum -c --status || { rm -f "${file}.part"; fail "sha256 mismatch for ${THEME_FILE}"; }
    mv "${file}.part" "${file}"
fi

mkdir -p "${dist}"
work=$(mktemp -d "${dist}/.theme.XXXXXX")
trap 'rm -rf "${work}"' EXIT

tar -xzf "${file}" -C "${work}" --no-same-owner || fail "cannot unpack ${THEME_FILE}"
root="${work}/${THEME_NAME}-${THEME_REV}"
for f in capabilities.xml theme.xml README.md; do
    [[ -f "${root}/${f}" ]] || fail "${f} missing in ${THEME_FILE}"
done
license=$(sed -n '/^## \*\*Credits\*\*/,$p' "${root}/README.md")
grep -q '^## \*\*License\*\*' <<<"${license}" || fail "no License section after Credits in the README of ${THEME_FILE}"

rm -rf "${dest}"
mkdir -p "$(dirname "${dest}")" "${dist}/usr/share/licenses/microemu"
mv "${root}" "${dest}"
{
    echo "Art Book Next (ES-DE Edition), https://github.com/anthonycaccese/art-book-next-es-de at ${THEME_REV}"
    echo
    printf '%s\n' "${license}"
} > "${dist}/usr/share/licenses/microemu/art-book-next.txt"

echo "THEME=${THEME_NAME}"
echo "THEME_REV=${THEME_REV}"
echo "THEME_SHA256=${THEME_SHA}"
echo "THEME_ASSET_BYTES=$(stat -c %s "${file}")"
echo "THEME_TREE_BYTES=$(du -sb "${dest}" | cut -f1)"
