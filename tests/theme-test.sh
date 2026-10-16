#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
theme="${repo}/build/theme.sh"
rev=d772d07109701d9bd7c9fda305bfef6601105ab8

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

tarball() {
    local out=$1 drop=${2:-} top="art-book-next-es-de-${rev}"
    rm -rf "${T}/src-tree"
    mkdir -p "${T}/src-tree/${top}/_inc"
    echo '<themeCapabilities/>' > "${T}/src-tree/${top}/capabilities.xml"
    echo '<theme/>' > "${T}/src-tree/${top}/theme.xml"
    echo 'font' > "${T}/src-tree/${top}/_inc/font.ttf"
    printf '# Art Book Next\n\n## **Credits**\n* fonts by someone\n\n## **License**\nCreative Commons CC-BY-NC-SA\n' \
        > "${T}/src-tree/${top}/README.md"
    case "${drop}" in
        capabilities) rm "${T}/src-tree/${top}/capabilities.xml" ;;
        license) sed -i '/License/,$d' "${T}/src-tree/${top}/README.md" ;;
    esac
    chmod 0775 "${T}/src-tree/${top}/_inc"
    chmod 0775 "${T}/src-tree/${top}/_inc/font.ttf"
    tar -czf "${out}" -C "${T}/src-tree" "${top}"
}

mkdir -p "${T}/src"
src="${T}/src/theme.tar.gz"
tarball "${src}"
export MICROEMU_THEME_URL="file://${src}"
MICROEMU_THEME_SHA=$(sha256sum "${src}" | cut -d' ' -f1)
export MICROEMU_THEME_SHA
cache="${T}/cache"
dist="${T}/dist"
cached="${cache}/art-book-next-es-de-${rev}.tar.gz"
tree="${dist}/usr/share/microemu/es-de/themes/art-book-next-es-de"
license="${dist}/usr/share/licenses/microemu/art-book-next.txt"

run() {
    rc=0
    out=$(bash "${theme}" "${cache}" "${dist}" 2>"${T}/err") || rc=$?
    err=$(cat "${T}/err")
}

leftover() {
    [[ -z "$(find "${dist}" -maxdepth 1 -name '.theme.*' 2>/dev/null)" ]] || fail "$1: work directory left in dist"
}

run
[[ "${rc}" == 0 ]] || fail "fresh exit ${rc}: ${err}"
[[ -f "${tree}/capabilities.xml" && -f "${tree}/theme.xml" && -f "${tree}/_inc/font.ttf" ]] || fail "fresh: tree incomplete"
[[ "$(stat -c %a "${tree}/_inc" "${tree}/_inc/font.ttf" "${tree}")" == $'755\n644\n755' ]] || fail "fresh: modes $(stat -c '%a %n' "${tree}/_inc" "${tree}/_inc/font.ttf" "${tree}")"
[[ "$(head -n 1 "${license}")" == "Art Book Next (ES-DE Edition), https://github.com/anthonycaccese/art-book-next-es-de at ${rev}" ]] \
    || fail "fresh: license header $(head -n 1 "${license}")"
grep -qx '## \*\*Credits\*\*' "${license}" || fail "fresh: credits missing from the license file"
grep -qx 'Creative Commons CC-BY-NC-SA' "${license}" || fail "fresh: license text missing"
grep -q '^# Art Book Next' "${license}" && fail "fresh: README head copied into the license file"
[[ "${out}" == *"THEME_SHA256=${MICROEMU_THEME_SHA}"* && "${out}" == *"THEME_ASSET_BYTES=$(stat -c %s "${src}")"* ]] || fail "fresh: manifest lines ${out}"
leftover fresh

mv "${src}" "${src}.away"
echo stale > "${tree}/stale"
run
[[ "${rc}" == 0 ]] || fail "cache hit exit ${rc}: ${err}"
[[ ! -e "${tree}/stale" ]] || fail "cache hit: old tree not replaced"
mv "${src}.away" "${src}"

rm -rf "${cache}" "${dist}"
MICROEMU_THEME_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 && "${err}" == *"sha256 mismatch"* ]] || fail "sha mismatch exit ${rc}: ${err}"
[[ ! -e "${cached}" && ! -e "${cached}.part" && ! -e "${tree}" ]] || fail "sha mismatch: something kept"

rm -rf "${cache}" "${dist}"
MICROEMU_THEME_URL="file://${T}/src/absent.tar.gz" run
[[ "${rc}" == 1 && "${err}" == *"download failed"* ]] || fail "unreachable exit ${rc}: ${err}"
[[ ! -e "${cached}.part" ]] || fail "unreachable: partial download kept"

for drop in capabilities license; do
    rm -rf "${cache}" "${dist}"
    bad="${T}/src/${drop}.tar.gz"
    tarball "${bad}" "${drop}"
    MICROEMU_THEME_URL="file://${bad}" MICROEMU_THEME_SHA=$(sha256sum "${bad}" | cut -d' ' -f1) run
    [[ "${rc}" == 1 ]] || fail "missing ${drop} exit ${rc}, expected 1"
    [[ ! -e "${tree}" ]] || fail "missing ${drop}: tree installed"
    leftover "missing ${drop}"
done

if (( failures )); then
    echo "theme-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "theme-test: ok"
