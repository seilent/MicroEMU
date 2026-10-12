#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
work="${T}/repo"
export MICROEMU_BUILDER_ROOT="${T}/root"
mkdir -p "${T}/bin" "${MICROEMU_BUILDER_ROOT}/usr/lib"

cat > "${T}/bin/rpm" <<'EOF'
#!/usr/bin/bash
echo "glibc-2.43-1.fc44.aarch64"
EOF
chmod 0755 "${T}/bin/rpm"
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

ext="${work}/sysext/usr/lib/extension-release.d/extension-release.microemu"

reset() {
    rm -rf "${work}"
    mkdir -p "${work}/build"
    cp "${repo}/build/build.sh" "${repo}/build/base.env" "${work}/build/"
    cp -a "${repo}/sysext" "${work}/"
    printf '#!/usr/bin/bash\necho ESDE_VERSION=3.5.0\n' > "${work}/build/esde.sh"
    printf '#!/usr/bin/bash\necho RETROARCH_VERSION=1.22.0-20.fc44\n' > "${work}/build/retroarch.sh"
    printf '#!/usr/bin/bash\necho SLANG_SHADERS_COMMIT=abc\n' > "${work}/build/shaders.sh"
    printf '#!/usr/bin/bash\necho THEME=art-book-next-es-de\n' > "${work}/build/theme.sh"
    . "${repo}/build/base.env"
    printf 'ID=armada\nVERSION_ID="%s"\nIMAGE_VERSION="%s"\n' "${VERSION_ID}" "${IMAGE_VERSION}" \
        > "${MICROEMU_BUILDER_ROOT}/usr/lib/os-release"
    mkdir -p "${work}/dist"
    echo old > "${work}/dist/old"
}

run() {
    rc=0
    err=$(env MICROEMU_VERSION=test bash "${work}/build/build.sh" 2>&1 >/dev/null) || rc=$?
}

kept() {
    [[ -f "${work}/dist/old" ]] || fail "$1: dist removed"
    [[ ! -e "${work}/dist/usr" ]] || fail "$1: dist written"
}

reset
mkdir -p "${work}/sysext/usr/libexec/microemu/__pycache__"
: > "${work}/sysext/usr/libexec/microemu/__pycache__/microemu-pad-fuzz.cpython-314.pyc"
: > "${work}/sysext/usr/libexec/microemu/stray.pyc"
run
[[ "${rc}" == 0 ]] || fail "matching exit ${rc}: ${err}"
[[ -z "$(find "${work}/dist" \( -name __pycache__ -o -name '*.pyc' \))" ]] || fail "matching: bytecode shipped"
grep -q 'pyc\|__pycache__' "${work}/dist/usr/share/microemu/paths" && fail "matching: bytecode in the paths list"
[[ ! -e "${work}/dist/old" ]] || fail "matching: old dist kept"
[[ -f "${work}/dist/usr/lib/extension-release.d/extension-release.microemu" ]] || fail "matching: extension-release missing"
grep -qx "MICROEMU_VERSION=test" "${work}/dist/usr/share/microemu/build-manifest" || fail "matching: no version in the manifest"
grep -qx "ESDE_VERSION=3.5.0" "${work}/dist/usr/share/microemu/build-manifest" || fail "matching: no es-de lines in the manifest"
grep -qx "RETROARCH_VERSION=1.22.0-20.fc44" "${work}/dist/usr/share/microemu/build-manifest" || fail "matching: no retroarch lines in the manifest"
grep -qx "SLANG_SHADERS_COMMIT=abc" "${work}/dist/usr/share/microemu/build-manifest" || fail "matching: no shader lines in the manifest"
grep -qx "THEME=art-book-next-es-de" "${work}/dist/usr/share/microemu/build-manifest" || fail "matching: no theme lines in the manifest"
for path in /usr/lib/extension-release.d/extension-release.microemu /usr/share/microemu/paths /usr/share/microemu/build-manifest /usr/share/microemu/version; do
    grep -qx "${path}" "${work}/dist/usr/share/microemu/paths" || fail "matching: ${path} not in the paths list"
done
[[ "$(sort -u "${work}/dist/usr/share/microemu/paths" | wc -l)" == "$(wc -l < "${work}/dist/usr/share/microemu/paths")" ]] || fail "matching: duplicate paths"

reset
sed -i 's/^VERSION_ID=.*/VERSION_ID=45/' "${ext}"
run
[[ "${rc}" == 1 ]] || fail "extension VERSION_ID exit ${rc}, expected 1"
[[ "${err}" == *"extension-release.microemu VERSION_ID 45 differs from base.env"* ]] || fail "extension VERSION_ID message: ${err}"
kept "extension VERSION_ID"

reset
sed -i 's/^VERSION_ID=.*/VERSION_ID=45/' "${work}/build/base.env"
sed -i 's/^VERSION_ID=.*/VERSION_ID="45"/' "${MICROEMU_BUILDER_ROOT}/usr/lib/os-release"
run
[[ "${rc}" == 1 ]] || fail "base VERSION_ID exit ${rc}, expected 1"
[[ "${err}" == *"extension-release.microemu VERSION_ID 44 differs from base.env 45"* ]] || fail "base VERSION_ID message: ${err}"
kept "base VERSION_ID"

reset
sed -i 's/^ID=.*/ID=fedora/' "${ext}"
run
[[ "${rc}" == 1 ]] || fail "extension ID exit ${rc}, expected 1"
[[ "${err}" == *"extension-release.microemu ID fedora differs from the builder ID armada"* ]] || fail "extension ID message: ${err}"
kept "extension ID"

reset
sed -i 's/^IMAGE_VERSION=.*/IMAGE_VERSION="20990101.0000000"/' "${MICROEMU_BUILDER_ROOT}/usr/lib/os-release"
run
[[ "${rc}" == 1 ]] || fail "builder IMAGE_VERSION exit ${rc}, expected 1"
[[ "${err}" == *"builder IMAGE_VERSION 20990101.0000000 differs"* ]] || fail "builder IMAGE_VERSION message: ${err}"
kept "builder IMAGE_VERSION"

if (( failures )); then
    echo "build-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "build-test: ok"
