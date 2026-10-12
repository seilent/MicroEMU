#!/usr/bin/bash
set -eu
export MICROEMU_TEST=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
script="${repo}/build/osd.sh"
rev=9a50ef366e750aabfab29e6915a2867607212971

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

src="${T}/src"
mkdir -p "${src}/_inc/images"
echo '<svg viewBox="0 0 24 24"><path d="M 1 1 Z"/></svg>' > "${src}/_inc/images/menu-icon-sound.svg"
printf '# Art Book Next\n\n### **Acknowledgments**\n* icons by someone\n\n## **License**\nCreative Commons CC-BY-NC-SA\n' \
    > "${src}/README.md"
export MICROEMU_OSD_BASE_URL="file://${src}"
MICROEMU_OSD_SVG_SHA=$(sha256sum "${src}/_inc/images/menu-icon-sound.svg" | cut -d' ' -f1)
MICROEMU_OSD_README_SHA=$(sha256sum "${src}/README.md" | cut -d' ' -f1)
export MICROEMU_OSD_SVG_SHA MICROEMU_OSD_README_SHA
cache="${T}/cache"
dist="${T}/dist"
svg="${dist}/usr/share/microemu/osd/speaker.svg"
license="${dist}/usr/share/licenses/microemu/art-book-next-speaker.txt"

run() {
    rc=0
    out=$(bash "${script}" "${cache}" "${dist}" 2>"${T}/err") || rc=$?
    err=$(cat "${T}/err")
}

run
[[ "${rc}" == 0 ]] || fail "fresh exit ${rc}: ${err}"
cmp -s "${svg}" "${src}/_inc/images/menu-icon-sound.svg" || fail "fresh: speaker.svg not installed"
[[ "$(stat -c %a "${svg}")" == 644 ]] || fail "fresh: speaker.svg mode $(stat -c %a "${svg}")"
[[ "$(head -n 1 "${license}")" == "speaker.svg is menu-icon-sound.svg from Art Book Next (Batocera Edition), https://github.com/anthonycaccese/art-book-next-es at ${rev}" ]] \
    || fail "fresh: license header $(head -n 1 "${license}")"
grep -qx '### \*\*Acknowledgments\*\*' "${license}" || fail "fresh: acknowledgments missing from the license file"
grep -qx 'Creative Commons CC-BY-NC-SA' "${license}" || fail "fresh: license text missing"
grep -q '^# Art Book Next' "${license}" && fail "fresh: README head copied into the license file"
[[ "${out}" == *"OSD_REV=${rev}"* && "${out}" == *"OSD_SVG_SHA256=${MICROEMU_OSD_SVG_SHA}"* ]] || fail "fresh: manifest lines ${out}"

mv "${src}" "${src}.away"
rm -rf "${dist}"
run
[[ "${rc}" == 0 && -f "${svg}" ]] || fail "cache hit exit ${rc}: ${err}"
mv "${src}.away" "${src}"

rm -rf "${cache}" "${dist}"
MICROEMU_OSD_SVG_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 && "${err}" == *"sha256 mismatch"* ]] || fail "sha mismatch exit ${rc}: ${err}"
[[ ! -e "${svg}" && -z "$(find "${cache}" -name '*.part')" ]] || fail "sha mismatch: something kept"

rm -rf "${cache}" "${dist}"
sed -i '/License/,$d' "${src}/README.md"
MICROEMU_OSD_README_SHA=$(sha256sum "${src}/README.md" | cut -d' ' -f1) run
[[ "${rc}" == 1 && "${err}" == *"no License section"* ]] || fail "no license exit ${rc}: ${err}"

rm -rf "${cache}" "${dist}"
MICROEMU_OSD_BASE_URL="file://${T}/absent" run
[[ "${rc}" == 1 && "${err}" == *"download failed"* ]] || fail "unreachable exit ${rc}: ${err}"

mkdir -p "${T}/nonet"
printf '#!/usr/bin/bash\nprintf "%%s\\n" "$@" >> "%s/curl-args"\nexit 7\n' "${T}" > "${T}/nonet/curl"
chmod 0755 "${T}/nonet/curl"
rm -rf "${cache}" "${dist}"
MICROEMU_TEST='' PATH="${T}/nonet:${PATH}" run
[[ "${rc}" == 1 ]] || fail "overrides honored without MICROEMU_TEST: exit ${rc}"
grep -qx "https://raw.githubusercontent.com/anthonycaccese/art-book-next-es/${rev}/_inc/images/menu-icon-sound.svg" "${T}/curl-args" \
    || fail "pinned URL not used without MICROEMU_TEST: $(cat "${T}/curl-args")"
[[ "$(grep -A1 -x -- --proto "${T}/curl-args" | sed -n 2p)" == "=https" ]] || fail "file URLs allowed without MICROEMU_TEST"
grep -A1 -x -- --proto-redir "${T}/curl-args" | grep -qx "=https" || fail "redirects not limited to https"

if (( failures )); then
    echo "osd-build-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "osd-build-test: ok"
