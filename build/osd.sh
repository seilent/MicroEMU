#!/usr/bin/bash
set -euo pipefail

OSD_REV=9a50ef366e750aabfab29e6915a2867607212971
OSD_BASE="https://raw.githubusercontent.com/anthonycaccese/art-book-next-es/${OSD_REV}"
SVG_SHA=f9bce5ce7813623232a0be20b848e11af895700d9180e546bb0067c4c2e01798
README_SHA=1893a06f9b86c4a5f46021bd8064d49262c8fea8e3f6b19c88a1a0a1d30e3399
PROTO="=https"

if [[ "${MICROEMU_TEST:-}" == 1 ]]; then
    OSD_BASE="${MICROEMU_OSD_BASE_URL:-${OSD_BASE}}"
    SVG_SHA="${MICROEMU_OSD_SVG_SHA:-${SVG_SHA}}"
    README_SHA="${MICROEMU_OSD_README_SHA:-${README_SHA}}"
    PROTO="=https,file"
fi

cache=$1
dist=$2

fail() { echo "osd.sh: $*" >&2; exit 1; }

fetch() {
    local path=$1 sha=$2 file="${cache}/${OSD_REV}-${1##*/}"
    if ! echo "${sha}  ${file}" | sha256sum -c --status 2>/dev/null; then
        curl --proto "${PROTO}" --proto-redir =https -fsSL --retry 3 --connect-timeout 30 -o "${file}.part" "${OSD_BASE}/${path}" \
            || { rm -f "${file}.part"; fail "download failed: ${OSD_BASE}/${path}"; }
        echo "${sha}  ${file}.part" | sha256sum -c --status || { rm -f "${file}.part"; fail "sha256 mismatch for ${path}"; }
        mv "${file}.part" "${file}"
    fi
    printf '%s\n' "${file}"
}

mkdir -p "${cache}"
svg=$(fetch _inc/images/menu-icon-sound.svg "${SVG_SHA}")
readme=$(fetch README.md "${README_SHA}")

license=$(sed -n '/^### \*\*Acknowledgments\*\*/,$p' "${readme}")
grep -q '^## \*\*License\*\*' <<<"${license}" || fail "no License section after Acknowledgments in the README at ${OSD_REV}"

mkdir -p "${dist}/usr/share/microemu/osd" "${dist}/usr/share/licenses/microemu"
install -m 0644 "${svg}" "${dist}/usr/share/microemu/osd/speaker.svg"
{
    echo "speaker.svg is menu-icon-sound.svg from Art Book Next (Batocera Edition), https://github.com/anthonycaccese/art-book-next-es at ${OSD_REV}"
    echo
    printf '%s\n' "${license}"
} > "${dist}/usr/share/licenses/microemu/art-book-next-speaker.txt"

echo "OSD_REV=${OSD_REV}"
echo "OSD_SVG_SHA256=${SVG_SHA}"
echo "OSD_README_SHA256=${README_SHA}"
