#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
guard="${repo}/sysext/usr/libexec/microemu/microemu-guard"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_SHARE="${T}/share"
export MICROEMU_DRIFT="${T}/run/microemu/drift"
export MICROEMU_SESSION_CONTROL="${T}/bin/session-control"
export MICROEMU_SYSROOT="${T}/sysroot"
export MICROEMU_CMDLINE="${T}/cmdline"
export MICROEMU_EXTENSIONS_DIR="${T}/extensions"
deploy="${MICROEMU_SYSROOT}/ostree/deploy/default/deploy/abc.0"

cat > "${T}/bin/session-control" <<'STUB'
#!/usr/bin/bash
[[ "$*" == list-sessions ]] || exit 99
[[ "$(cat "${STATE}/sc_rc")" == 0 ]] || { echo "Unknown verb: list-sessions" >&2; exit 1; }
cat "${STATE}/sessions"
STUB
cat > "${T}/bin/logger" <<'STUB'
#!/usr/bin/bash
echo "$*" >> "${STATE}/log"
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROEMU_SHARE}" "${T}/run" "${MICROEMU_SYSROOT}" "${MICROEMU_EXTENSIONS_DIR}"
    mkdir -p "${STATE}" "${MICROEMU_SHARE}" "${deploy}/usr/lib" "${MICROEMU_EXTENSIONS_DIR}/microemu/usr/libexec/microemu"
    : > "${STATE}/log"
    echo 0 > "${STATE}/sc_rc"
    printf 'microdap\nmicroemu\n' > "${STATE}/sessions"
    printf '/usr/libexec/microemu/microemu-client\n/usr/share/microemu/paths\n/usr/lib/armada/sessions.d/microemu.conf\n' > "${MICROEMU_SHARE}/paths"
    : > "${deploy}/usr/lib/os-release"
    echo "BOOT_IMAGE=/vmlinuz root=UUID=x ostree=/ostree/boot.1/default/xyz/0 rw" > "${MICROEMU_CMDLINE}"
    mkdir -p "${MICROEMU_SYSROOT}/ostree/boot.1/default/xyz"
    ln -s ../../../deploy/default/deploy/abc.0 "${MICROEMU_SYSROOT}/ostree/boot.1/default/xyz/0"
}

run() {
    rc=0
    "${guard}" 2> "${STATE}/stderr" || rc=$?
}

drift() { cat "${MICROEMU_DRIFT}" 2>/dev/null || true; }

reset
mkdir -p "$(dirname "${MICROEMU_DRIFT}")"
echo stale > "${MICROEMU_DRIFT}"
run
[[ "${rc}" == 0 ]] || fail "clean exit ${rc}"
[[ ! -s "${MICROEMU_DRIFT}" ]] || fail "clean: drift $(drift)"
grep -q "booted deployment ${deploy}" "${STATE}/log" || fail "clean: deployment not logged: $(cat "${STATE}/log")"
grep -q "no drift" "${STATE}/log" || fail "clean: no summary line"

reset
echo 1 > "${STATE}/sc_rc"
run
[[ "${rc}" == 0 ]] || fail "no drop-in support exit ${rc}"
grep -q "session-control has no drop-in support" <<<"$(drift)" || fail "no drop-in support: drift $(drift)"
grep -q -- "-p user.warning -- session-control has no drop-in support" "${STATE}/log" || fail "no drop-in support: no warning line"

reset
printf 'microdap\n' > "${STATE}/sessions"
run
grep -q "does not name microemu" <<<"$(drift)" || fail "microemu not listed: drift $(drift)"

reset
printf 'microemu-old\n' > "${STATE}/sessions"
run
grep -q "does not name microemu" <<<"$(drift)" || fail "prefix match taken as microemu: drift $(drift)"

reset
mkdir -p "${deploy}/usr/lib/armada/sessions.d"
: > "${deploy}/usr/lib/armada/sessions.d/microemu.conf"
ln -s /nowhere "${deploy}/usr/share-link"
echo /usr/share-link >> "${MICROEMU_SHARE}/paths"
run
grep -qx "/usr/lib/armada/sessions.d/microemu.conf also exists in the booted image, microemu shadows it" <<<"$(drift)" \
    || fail "image collision: drift $(drift)"
grep -qx "/usr/share-link also exists in the booted image, microemu shadows it" <<<"$(drift)" || fail "dangling link collision: drift $(drift)"
[[ "$(grep -c . <<<"$(drift)")" == 2 ]] || fail "image collision: $(drift)"
grep -q "2 problem(s), listed in ${MICROEMU_DRIFT}" "${STATE}/log" || fail "image collision: no summary"

reset
mkdir -p "${MICROEMU_EXTENSIONS_DIR}/microdap/usr/libexec/microemu"
: > "${MICROEMU_EXTENSIONS_DIR}/microdap/usr/libexec/microemu/microemu-client"
: > "${MICROEMU_EXTENSIONS_DIR}/microemu/usr/libexec/microemu/microemu-client"
: > "${MICROEMU_EXTENSIONS_DIR}/other.raw"
run
[[ "$(drift)" == "/usr/libexec/microemu/microemu-client also shipped by the microdap extension" ]] || fail "extension collision: drift $(drift)"
grep -q "other.raw is an image, its paths are not checked" "${STATE}/log" || fail "raw extension not logged"

reset
echo "BOOT_IMAGE=/vmlinuz rw" > "${MICROEMU_CMDLINE}"
run
grep -q "cannot resolve the booted deployment" <<<"$(drift)" || fail "no ostree arg: drift $(drift)"

reset
rm -f "${deploy}/usr/lib/os-release"
mkdir -p "${deploy}/usr/libexec/microemu"
: > "${deploy}/usr/libexec/microemu/microemu-client"
run
[[ "$(drift)" == "cannot read the booted image tree ${deploy}, image collisions not checked" ]] || fail "no os-release: drift $(drift)"

reset
rm -f "${MICROEMU_SHARE}/paths"
run
[[ "${rc}" == 0 ]] || fail "no paths exit ${rc}"
grep -q "paths missing, collisions not checked" <<<"$(drift)" || fail "no paths: drift $(drift)"

if (( failures )); then
    echo "guard-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "guard-test: ok"
