#!/usr/bin/bash
set -eu

export MICROEMU_TEST=1
export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
script="${repo}/build/shaders.sh"
audit="${repo}/build/shaders-audit"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

slang_paths=$(sed -n 's/^[0-9a-f]\{64\} \(.*\)$/\1/p' <(sed -n '/^SLANG_FILES="/,/^"/p' "${script}"))
rc_paths=$(sed -n 's/^[0-9a-f]\{64\} \(.*\)$/\1/p' <(sed -n '/^RC_FILES="/,/^"/p' "${script}"))

sources() {
    local path
    rm -rf "${T}/slang" "${T}/rc"
    while IFS= read -r path; do
        mkdir -p "$(dirname "${T}/slang/${path}")"
        case "${path}" in
            *.slangp) printf 'shaders = "1"\nshader0 = "%s"\n' "$(realpath -m --relative-to="$(dirname "/x/${path}")" /x/crt/shaders/guest/advanced/stock.slang)" > "${T}/slang/${path}" ;;
            *) printf '#version 450\n// %s\n' "${path}" > "${T}/slang/${path}" ;;
        esac
    done <<< "${slang_paths}"
    mkdir -p "${T}/rc/shaders/shaders_slang/retro crisis/4K Flat" "${T}/rc/shaders/shaders_slang/retro crisis/1080p Flat"
    for game in NES SNES; do
        printf 'shaders = "1"\nshader0 = "../../../shaders_slang/crt/shaders/guest/advanced/stock.slang"\n' \
            > "${T}/rc/shaders/shaders_slang/retro crisis/4K Flat/RC GDV-NTSC - ${game} - Clean.slangp"
        printf '#reference "../4K Flat/RC GDV-NTSC - %s - Clean.slangp"\n' "${game}" \
            > "${T}/rc/shaders/shaders_slang/retro crisis/1080p Flat/RC GDV-NTSC - ${game} - Clean.slangp"
    done
    rm -f "${T}/rc.zip"
    (cd "${T}/rc" && zip -qr "${T}/rc.zip" shaders)
    echo "GNU GENERAL PUBLIC LICENSE" > "${T}/LICENSE"
}

table() {
    local base=$1 list=$2 path
    while IFS= read -r path; do
        printf '%s %s\n' "$(sha256sum "${base}/${path}" | cut -d' ' -f1)" "${path}"
    done <<< "${list}"
}

pins() {
    export MICROEMU_SLANG_URL="file://${T}/slang"
    MICROEMU_SLANG_FILES=$(table "${T}/slang" "${slang_paths}")
    MICROEMU_RC_FILES=$(table "${T}/rc/shaders/shaders_slang" "${rc_paths}")
    export MICROEMU_SLANG_FILES MICROEMU_RC_FILES
    export MICROEMU_RC_URL="file://${T}/rc.zip"
    MICROEMU_RC_SHA=$(sha256sum "${T}/rc.zip" | cut -d' ' -f1)
    export MICROEMU_RC_SHA
    export MICROEMU_RC_LICENSE_URL="file://${T}/LICENSE"
    MICROEMU_RC_LICENSE_SHA=$(sha256sum "${T}/LICENSE" | cut -d' ' -f1)
    export MICROEMU_RC_LICENSE_SHA
}

reset() {
    rm -rf "${T}/dist" "${T}/cache"
    mkdir -p "${T}/dist/usr/share/microemu/retroarch"
    cp -a "${repo}/data/usr/share/microemu/retroarch/shaders" "${T}/dist/usr/share/microemu/retroarch/"
}

run() {
    rc=0
    bash "${script}" "${T}/cache" "${T}/dist" "${1:-${audit}}" > "${T}/out" 2> "${T}/err" || rc=$?
}

shaders="${T}/dist/usr/share/microemu/retroarch/shaders"

sources
pins
reset
run
[[ "${rc}" == 0 ]] || fail "build exit ${rc}: $(cat "${T}/err")"
while IFS= read -r path; do
    cmp -s "${T}/slang/${path}" "${shaders}/shaders_slang/${path}" || fail "${path} not installed"
done <<< "${slang_paths}"
while IFS= read -r path; do
    [[ -f "${shaders}/shaders_slang/${path}" ]] || fail "${path} not installed"
done <<< "${rc_paths}"
[[ ! -e "${shaders}/shaders_slang/__MACOSX" ]] || fail "__MACOSX installed"
[[ "$(find "${shaders}" -type f | wc -l)" == "$(( $(grep -c . <<< "${slang_paths}") + $(grep -c . <<< "${rc_paths}") + 2 ))" ]] \
    || fail "unexpected files: $(find "${shaders}" -type f)"
cmp -s "${audit}" "${T}/dist/usr/share/licenses/microemu/slang-shaders/AUDIT" || fail "audit not installed"
grep -q "GNU GENERAL PUBLIC LICENSE" "${T}/dist/usr/share/licenses/microemu/retro-crisis/LICENSE" || fail "Retro Crisis license not installed"
grep -qx "SLANG_SHADERS_COMMIT=e1d75632a205c70f14a4cc947c46d5abb7b3f7f1" "${T}/out" || fail "manifest lines: $(cat "${T}/out")"
while IFS= read -r path; do
    grep -qF " ${path} |" "${audit}" || fail "${path} missing in the audit"
done <<< "${slang_paths}"
for path in handheld/shaders/lcd-cgwg/lcd-grid-v2.slang handheld/shaders/pixel_transparency/pixel_transparency.slang; do
    grep -qxF "${path}" <<< "${slang_paths}" && fail "${path} has no license grant and is shipped"
    grep -rqF "$(basename "${path}")" "${repo}/data" && fail "$(basename "${path}") referenced from data/"
done

rm -rf "${T}/slang.off"
mv "${T}/slang" "${T}/slang.off"
mv "${T}/rc.zip" "${T}/rc.zip.off"
reset_keep_cache() { rm -rf "${T}/dist"; mkdir -p "${T}/dist/usr/share/microemu/retroarch"; cp -a "${repo}/data/usr/share/microemu/retroarch/shaders" "${T}/dist/usr/share/microemu/retroarch/"; }
reset_keep_cache
run
[[ "${rc}" == 0 ]] || fail "cached rebuild needed the network: $(cat "${T}/err")"
mv "${T}/slang.off" "${T}/slang"
mv "${T}/rc.zip.off" "${T}/rc.zip"

reset
echo changed >> "${T}/slang/reshade/shaders/LUT/multiLUT.slang"
run
[[ "${rc}" == 1 ]] && grep -q "sha256 mismatch" "${T}/err" || fail "changed slang file: exit ${rc}: $(cat "${T}/err")"
sources
pins

reset
MICROEMU_RC_SHA=0000 run
[[ "${rc}" == 1 ]] && grep -q "sha256 mismatch" "${T}/err" || fail "bad zip sha: exit ${rc}"

reset
grep -v "multiLUT" "${audit}" > "${T}/audit"
run "${T}/audit"
[[ "${rc}" == 1 ]] && grep -q "reshade/shaders/LUT/multiLUT.slang is not in" "${T}/err" || fail "file outside the audit: exit ${rc}: $(cat "${T}/err")"

reset
printf '#reference "../../shaders_slang/nowhere/missing.slangp"\n' > "${shaders}/presets/Nestopia/Nestopia.slangp"
run
[[ "${rc}" == 1 ]] && grep -q "references a missing file" "${T}/err" && grep -q "missing.slangp" "${T}/err" || fail "missing reference: exit ${rc}: $(cat "${T}/err")"

reset
MICROEMU_RC_FILES="${MICROEMU_RC_FILES}
$(printf '%064d' 0) retro crisis/4K Flat/RC GDV-NTSC - GB - Clean.slangp" run
[[ "${rc}" == 1 ]] && grep -q "missing in Retro.Crisis" "${T}/err" || fail "missing zip member: exit ${rc}: $(cat "${T}/err")"

reset
mkdir -p "${T}/nonet"
printf '#!/usr/bin/bash\nprintf "%%s\\n" "$@" >> "%s/curl-args"\nexit 22\n' "${T}" > "${T}/nonet/curl"
chmod 0755 "${T}/nonet/curl"
PATH="${T}/nonet:${PATH}" MICROEMU_TEST='' run
[[ "${rc}" == 1 ]] || fail "overrides honored without MICROEMU_TEST: exit ${rc}"
grep -q "^https://raw.githubusercontent.com/libretro/slang-shaders/e1d75632a205c70f14a4cc947c46d5abb7b3f7f1/" "${T}/curl-args" \
    || fail "pinned URL not used without MICROEMU_TEST: $(cat "${T}/curl-args" 2>/dev/null)"
[[ "$(grep -A1 -x -- --proto "${T}/curl-args" | sed -n 2p)" == "=https" ]] || fail "file URLs allowed without MICROEMU_TEST: $(cat "${T}/curl-args")"
grep -A1 -x -- --proto-redir "${T}/curl-args" | grep -qx "=https" || fail "redirects not limited to https"

if (( failures )); then
    echo "shaders-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "shaders-test: ok"
