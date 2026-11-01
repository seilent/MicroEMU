#!/usr/bin/bash
set -eu
unset MICROEMU_STUB_CACHE

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
work="${T}/repo"
dest="${T}/root"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${work}" "${dest}"
    mkdir -p "${work}/build"
    cp "${repo}/build/install.sh" "${repo}/build/shaders-audit" "${work}/build/"
    cp -a "${repo}/data" "${repo}/android" "${work}/"
    printf '#!/usr/bin/bash\necho "shaders $*" >> "%s/calls"\necho SLANG_SHADERS_COMMIT=abc\n' "${T}" > "${work}/build/shaders.sh"
    printf '#!/usr/bin/bash\necho "theme $*" >> "%s/calls"\nmkdir -p "$2/usr/share/microemu/es-de/themes/x/_inc"\necho THEME=art-book-next-es-de\n' "${T}" > "${work}/build/theme.sh"
    printf '#!/usr/bin/bash\necho "osd $*" >> "%s/calls"\necho OSD_REV=abc\n' "${T}" > "${work}/build/osd.sh"
    printf '#!/usr/bin/bash\necho "stub $*" >> "%s/calls"\necho STUB_SHA256=abc\necho STUB_RC_SHA256=def\n' "${T}" > "${work}/build/stub.sh"
    : > "${T}/calls"
}

run() {
    rc=0
    err=$(umask 0002 && env MICROEMU_VERSION=test MICROEMU_CACHE="${T}/cache" bash "${work}/build/install.sh" "${dest}" 2>&1 >/dev/null) || rc=$?
}

reset
mkdir -p "${work}/data/usr/libexec/microemu/__pycache__"
: > "${work}/data/usr/libexec/microemu/__pycache__/microemu-osd.cpython-314.pyc"
run
[[ "${rc}" == 0 ]] || fail "install exit ${rc}: ${err}"
[[ -z "$(find "${dest}" \( -name __pycache__ -o -name '*.pyc' \))" ]] || fail "bytecode installed"
(cd "${repo}/data" && find . \( -type f -o -type l \) ! -path '*/__pycache__/*' | sort) > "${T}/want"
(cd "${dest}" && find . \( -type f -o -type l \) | grep -v '^./usr/share/microemu/\(version\|build-manifest\)$' | sort) > "${T}/got"
cmp -s "${T}/want" "${T}/got" || fail "installed files differ from data/: $(diff "${T}/want" "${T}/got")"
[[ -d "${dest}/usr/share/microemu/android/steam-empty" && -z "$(ls -A "${dest}/usr/share/microemu/android/steam-empty")" ]] || fail "steam-empty is not an empty dir"
[[ "$(stat -c %a "${dest}/usr/share/microemu/android/steam-empty")" == 755 ]] || fail "steam-empty is not 0755"
[[ "$(cat "${dest}/usr/share/microemu/version")" == test ]] || fail "version file"
[[ "$(cat "${dest}/usr/share/microemu/build-manifest")" == $'MICROEMU_VERSION=test\nSLANG_SHADERS_COMMIT=abc\nTHEME=art-book-next-es-de\nOSD_REV=abc\nSTUB_SHA256=abc\nSTUB_RC_SHA256=def' ]] \
    || fail "build manifest: $(cat "${dest}/usr/share/microemu/build-manifest")"
[[ "$(cat "${T}/calls")" == "shaders ${T}/cache/shaders ${dest} ${work}/build/shaders-audit
theme ${T}/cache/theme ${dest}
osd ${T}/cache/osd ${dest}
stub ${T}/cache/stub ${dest} ${work}/android/restrictions-stub" ]] || fail "asset scripts: $(cat "${T}/calls")"
odd=$(find "${dest}" -mindepth 1 -type d ! -perm 0755)
[[ -z "${odd}" ]] || fail "directories not 0755 under umask 0002: ${odd}"
[[ -x "${dest}/usr/libexec/microemu/microemu-client" && -x "${dest}/usr/libexec/microemu/microemu-reconcile" ]] || fail "scripts not executable"

reset
printf '#!/usr/bin/bash\nexit 3\n' > "${work}/build/theme.sh"
run
[[ "${rc}" != 0 ]] || fail "a failed asset script did not fail the install"
[[ ! -e "${dest}/usr/share/microemu/build-manifest" ]] || fail "manifest written after a failed asset script"

reset
printf '#!/usr/bin/bash\nexit 4\n' > "${work}/build/stub.sh"
run
[[ "${rc}" != 0 ]] || fail "a failed stub did not fail the install"
[[ ! -e "${dest}/usr/share/microemu/build-manifest" ]] || fail "manifest written after a failed stub"

reset
MICROEMU_STUB_CACHE="${T}/stub-cache" run
[[ "${rc}" == 0 ]] || fail "stub cache override exit ${rc}: ${err}"
[[ "$(tail -n 1 "${T}/calls")" == "stub ${T}/stub-cache ${dest} ${work}/android/restrictions-stub" ]] || fail "stub cache override: $(cat "${T}/calls")"

reset
rc=0
bash "${work}/build/install.sh" 2>/dev/null || rc=$?
[[ "${rc}" != 0 ]] || fail "no destdir accepted"

if (( failures )); then
    echo "install-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "install-test: ok"
