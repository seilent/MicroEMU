#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
reset_cmd="${repo}/sysext/usr/bin/microemu-play-reset"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}"; rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_PLAY_CONTEXT="${T}/contexts/microemu-play"
export MICROEMU_ANDROID_DATA="${T}/data"

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
cat "${STATE}/unit"
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/calls"
case "$1 $2" in
    "container exists") [[ -e "${STATE}/exists_rc" ]] && exit "$(cat "${STATE}/exists_rc")"; [[ -e "${STATE}/container" ]] ;;
    "unshare chmod") shift 2; chmod "$@" ;;
    "unshare rm") shift 2; rm "$@" ;;
    *) exit 99 ;;
esac
STUB
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    [[ ! -d "${T}/contexts" ]] || chmod -R u+w "${T}/contexts"
    rm -rf "${STATE}" "${T}/contexts" "${MICROEMU_ANDROID_DATA}"
    mkdir -p "${STATE}" "${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system" "${MICROEMU_ANDROID_DATA}/sideload"
    : > "${STATE}/calls"
    echo "$1" > "${STATE}/unit"
    echo xml > "${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system/packages.xml"
    chmod 0500 "${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system"
    echo state > "${MICROEMU_ANDROID_DATA}/sideload/com.example"
    echo com.example > "${MICROEMU_ANDROID_DATA}/prune"
    echo log > "${MICROEMU_ANDROID_DATA}/boot.log"
}

run() {
    rc=0
    "${reset_cmd}" > "${STATE}/out" 2>&1 || rc=$?
}

for state in active activating deactivating; do
    reset "${state}"
    run
    [[ "${rc}" == 1 ]] || fail "unit ${state}: exit ${rc}"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" && -d "${MICROEMU_ANDROID_DATA}/sideload" ]] || fail "unit ${state}: something removed"
done

reset inactive
: > "${STATE}/container"
run
[[ "${rc}" == 1 ]] && grep -q "container lepton-microemu-play exists" "${STATE}/out" || fail "container present: exit ${rc}"
[[ -d "${MICROEMU_PLAY_CONTEXT}" ]] || fail "container present: context removed"

reset inactive
echo 125 > "${STATE}/exists_rc"
run
[[ "${rc}" == 1 ]] && grep -q "podman container exists failed (rc=125)" "${STATE}/out" || fail "podman error: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${MICROEMU_PLAY_CONTEXT}" ]] || fail "podman error: context removed"

reset inactive
run
[[ "${rc}" == 0 ]] || fail "reset exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${MICROEMU_PLAY_CONTEXT}" ]] || fail "context left"
[[ -d "${T}/contexts" ]] || fail "contexts directory removed"
[[ ! -e "${MICROEMU_ANDROID_DATA}/sideload" && ! -e "${MICROEMU_ANDROID_DATA}/prune" ]] || fail "sideload state left"
[[ -f "${MICROEMU_ANDROID_DATA}/boot.log" ]] || fail "boot log removed"
[[ "$(grep -n 'unshare chmod -R 700' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -n 'unshare rm -rf' "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "chmod not before rm: $(cat "${STATE}/calls")"

reset failed
chmod -R u+w "${T}/contexts"
rm -rf "${T}/contexts"
run
[[ "${rc}" == 0 ]] || fail "no context exit ${rc}"
grep -q unshare "${STATE}/calls" && fail "no context: unshare called"

if (( failures )); then
    echo "reset-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "reset-test: ok"
