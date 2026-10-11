#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
esde="${repo}/build/esde.sh"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

appimage() {
    local out=$1 offset=$2 license=$3 apprun=${4:-1} tree="${T}/tree"
    rm -rf "${tree}" "${T}/sq.img"
    mkdir -p "${tree}/usr/bin" "${tree}/usr/share/es-de"
    printf '#!/bin/sh\necho es-de\n' > "${tree}/usr/bin/es-de"
    chmod 0755 "${tree}/usr/bin/es-de"
    [[ "${apprun}" == 0 ]] || ln -s usr/bin/es-de "${tree}/AppRun"
    [[ "${license}" == 0 ]] || echo "es-de license" > "${tree}/usr/share/es-de/LICENSE"
    mksquashfs "${tree}" "${T}/sq.img" -quiet -noappend -all-root >/dev/null
    python3 -c 'import struct, sys
h = bytearray(128)
h[0:6] = b"\x7fELF\x02\x01"
struct.pack_into("<Q", h, 40, 64)
struct.pack_into("<H", h, 58, int(sys.argv[2]))
struct.pack_into("<H", h, 60, 1)
open(sys.argv[1], "wb").write(h)' "${out}" "${offset}"
    cat "${T}/sq.img" >> "${out}"
}

mkdir -p "${T}/src"
src="${T}/src/es-de.AppImage"
appimage "${src}" 64 1
sha=$(sha256sum "${src}" | cut -d' ' -f1)
size=$(stat -c %s "${src}")
export MICROEMU_ESDE_URL="file://${src}"
export MICROEMU_ESDE_SHA="${sha}"
cache="${T}/cache"
dist="${T}/dist"
cached="${cache}/ES-DE_3.5.0_aarch64.AppImage"

run() {
    rc=0
    out=$(bash "${esde}" "${cache}" "${dist}" 2>"${T}/err") || rc=$?
    err=$(cat "${T}/err")
}

tree="${dist}/usr/lib/microemu/es-de"

leftover() {
    [[ -z "$(find "${dist}" -maxdepth 1 -name '.esde.*' 2>/dev/null)" ]] || fail "$1: work directory left in dist"
}

run
[[ "${rc}" == 0 ]] || fail "fresh exit ${rc}: ${err}"
[[ -L "${tree}/AppRun" && -x "${tree}/AppRun" ]] || fail "fresh: AppRun not an executable link"
[[ "$("${tree}/AppRun")" == es-de ]] || fail "fresh: AppRun does not run the binary"
[[ "$(cat "${dist}/usr/share/licenses/microemu/es-de.txt")" == "es-de license" ]] || fail "fresh: license not copied"
[[ -f "${cached}" ]] || fail "fresh: asset not cached"
[[ ! -e "${cached}.part" ]] || fail "fresh: .part left"
[[ "${out}" == *"ESDE_VERSION=3.5.0"* ]] || fail "fresh: no version line: ${out}"
[[ "${out}" == *"ESDE_SHA256=${sha}"* ]] || fail "fresh: no sha line: ${out}"
[[ "${out}" == *"ESDE_ASSET_BYTES=${size}"* ]] || fail "fresh: no size line: ${out}"
[[ "${out}" == *"ESDE_TREE_BYTES="* ]] || fail "fresh: no tree size line: ${out}"
leftover fresh

mv "${src}" "${src}.away"
echo stale > "${tree}/stale"
run
[[ "${rc}" == 0 ]] || fail "cache hit exit ${rc}: ${err}"
[[ -x "${tree}/AppRun" ]] || fail "cache hit: AppRun missing"
[[ ! -e "${tree}/stale" ]] || fail "cache hit: old tree not replaced"
mv "${src}.away" "${src}"

echo corrupt > "${cached}"
run
[[ "${rc}" == 0 ]] || fail "corrupt cache exit ${rc}: ${err}"
[[ "$(sha256sum "${cached}" | cut -d' ' -f1)" == "${sha}" ]] || fail "corrupt cache: not fetched again"

rm -rf "${cache}" "${dist}"
MICROEMU_ESDE_SHA=0000000000000000000000000000000000000000000000000000000000000000 run
[[ "${rc}" == 1 ]] || fail "sha mismatch exit ${rc}, expected 1"
[[ "${err}" == *"sha256 mismatch for ES-DE_3.5.0_aarch64.AppImage"* ]] || fail "sha mismatch message: ${err}"
[[ ! -e "${cached}" && ! -e "${cached}.part" ]] || fail "sha mismatch: asset kept in the cache"
[[ ! -e "${tree}" ]] || fail "sha mismatch: tree extracted"

rm -rf "${cache}" "${dist}"
bad="${T}/src/bad.AppImage"
appimage "${bad}" 32 1
MICROEMU_ESDE_URL="file://${bad}" MICROEMU_ESDE_SHA=$(sha256sum "${bad}" | cut -d' ' -f1) run
[[ "${rc}" == 1 ]] || fail "wrong offset exit ${rc}, expected 1"
[[ "${err}" == *"no squashfs at offset 96"* ]] || fail "wrong offset message: ${err}"
[[ ! -e "${tree}" ]] || fail "wrong offset: tree extracted"

rm -rf "${cache}" "${dist}"
nolicense="${T}/src/nolicense.AppImage"
appimage "${nolicense}" 64 0
MICROEMU_ESDE_URL="file://${nolicense}" MICROEMU_ESDE_SHA=$(sha256sum "${nolicense}" | cut -d' ' -f1) run
[[ "${rc}" == 1 ]] || fail "no license exit ${rc}, expected 1"
[[ "${err}" == *"usr/share/es-de/LICENSE missing"* ]] || fail "no license message: ${err}"
[[ ! -e "${tree}" ]] || fail "no license: tree extracted"
leftover "no license"

rm -rf "${cache}" "${dist}"
MICROEMU_ESDE_URL="file://${T}/src/absent.AppImage" run
[[ "${rc}" == 1 ]] || fail "unreachable exit ${rc}, expected 1"
[[ "${err}" == *"download failed: file://${T}/src/absent.AppImage"* ]] || fail "unreachable message: ${err}"
[[ ! -e "${cached}" && ! -e "${cached}.part" ]] || fail "unreachable: partial download kept"
[[ ! -e "${tree}" ]] || fail "unreachable: tree extracted"

rm -rf "${cache}" "${dist}"
notelf="${T}/src/notelf.AppImage"
appimage "${notelf}" 64 1
printf 'MZ' | dd of="${notelf}" bs=1 seek=0 conv=notrunc 2>/dev/null
MICROEMU_ESDE_URL="file://${notelf}" MICROEMU_ESDE_SHA=$(sha256sum "${notelf}" | cut -d' ' -f1) run
[[ "${rc}" == 1 ]] || fail "not elf exit ${rc}, expected 1"
[[ "${err}" == *"is not a little endian ELF64 file"* ]] || fail "not elf message: ${err}"
[[ ! -e "${tree}" ]] || fail "not elf: tree extracted"
leftover "not elf"

rm -rf "${cache}" "${dist}"
noapprun="${T}/src/noapprun.AppImage"
appimage "${noapprun}" 64 1 0
MICROEMU_ESDE_URL="file://${noapprun}" MICROEMU_ESDE_SHA=$(sha256sum "${noapprun}" | cut -d' ' -f1) run
[[ "${rc}" == 1 ]] || fail "no AppRun exit ${rc}, expected 1"
[[ "${err}" == *"AppRun missing in ES-DE_3.5.0_aarch64.AppImage"* ]] || fail "no AppRun message: ${err}"
[[ ! -e "${tree}" ]] || fail "no AppRun: tree extracted"
leftover "no AppRun"

if (( failures )); then
    echo "esde-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "esde-test: ok"
