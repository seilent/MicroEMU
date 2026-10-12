#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
reset_cmd="${repo}/sysext/usr/bin/microemu-play-reset"

T=$(mktemp -d)
trap 'chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_PLAY_CONTEXT="${T}/contexts/microemu-play"
export MICROEMU_ANDROID_DATA="${T}/data"
export MICROEMU_GAPPS="${T}/gapps"
export MICROEMU_ANDROID_ROMS="${T}/roms"

cat > "${T}/bin/systemctl" <<'STUB'
#!/usr/bin/bash
case "$*" in
    *microemu-play-update.service*) cat "${STATE}/update_unit" ;;
    *) cat "${STATE}/unit" ;;
esac
STUB
cat > "${T}/bin/podman" <<'STUB'
#!/usr/bin/bash
echo "podman $*" >> "${STATE}/calls"
case "$1 $2" in
    "container exists") [[ -e "${STATE}/exists_rc" ]] && exit "$(cat "${STATE}/exists_rc")"; [[ -e "${STATE}/container-$3" ]] ;;
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
    echo "${2:-inactive}" > "${STATE}/update_unit"
    echo xml > "${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system/packages.xml"
    chmod 0500 "${MICROEMU_PLAY_CONTEXT}/baked/data_overlay/system"
    echo state > "${MICROEMU_ANDROID_DATA}/sideload/com.example"
    echo com.example > "${MICROEMU_ANDROID_DATA}/prune"
    echo log > "${MICROEMU_ANDROID_DATA}/boot.log"
    [[ ! -d "${MICROEMU_GAPPS}" ]] || chmod -R u+w "${MICROEMU_GAPPS}"
    rm -rf "${MICROEMU_GAPPS}" "${MICROEMU_ANDROID_ROMS}"
    mkdir -p "${MICROEMU_GAPPS}/set/system" "${MICROEMU_ANDROID_ROMS}"
    echo apk > "${MICROEMU_GAPPS}/set/system/Phonesky.apk"
    ln -s set "${MICROEMU_GAPPS}/current"
    chmod -R a-w "${MICROEMU_GAPPS}/set"
    echo com.android.vending > "${MICROEMU_ANDROID_ROMS}/Google Play.play"
    : > "${MICROEMU_ANDROID_ROMS}/Update Google Play.update"
    echo com.example.game > "${MICROEMU_ANDROID_ROMS}/Game.play"
}

run() {
    rc=0
    "${reset_cmd}" "$@" > "${STATE}/out" 2>&1 || rc=$?
}

for state in active activating deactivating; do
    reset "${state}"
    run
    [[ "${rc}" == 1 ]] || fail "unit ${state}: exit ${rc}"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" && -d "${MICROEMU_ANDROID_DATA}/sideload" ]] || fail "unit ${state}: something removed"
done

for state in active activating deactivating; do
    reset inactive "${state}"
    run
    [[ "${rc}" == 1 ]] && grep -q "microemu-play-update.service is running, refusing" "${STATE}/out" || fail "update ${state}: exit ${rc}"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" ]] || fail "update ${state}: context removed"
done

for container in lepton-microemu-play lepton-headless-microemu-play; do
    reset inactive
    : > "${STATE}/container-${container}"
    run
    [[ "${rc}" == 1 ]] && grep -q "container ${container} exists" "${STATE}/out" || fail "${container} present: exit ${rc}"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" ]] || fail "${container} present: context removed"
done

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
[[ -e "${MICROEMU_GAPPS}/current" && -f "${MICROEMU_ANDROID_ROMS}/Google Play.play" && -f "${MICROEMU_ANDROID_ROMS}/Update Google Play.update" && -f "${MICROEMU_ANDROID_ROMS}/Game.play" ]] \
    || fail "plain reset touched the gapps tree or .play entries"

[[ "$(grep -n 'unshare chmod -R 700' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -n 'unshare rm -rf' "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "chmod not before rm: $(cat "${STATE}/calls")"

reset inactive
run --gapps
[[ "${rc}" == 0 ]] || fail "reset --gapps exit ${rc}: $(cat "${STATE}/out")"
[[ ! -e "${MICROEMU_GAPPS}" ]] || fail "gapps tree left"
[[ ! -e "${MICROEMU_ANDROID_ROMS}/Google Play.play" ]] || fail "Google Play.play left"
[[ ! -e "${MICROEMU_ANDROID_ROMS}/Update Google Play.update" ]] || fail "Update Google Play.update left"
[[ -f "${MICROEMU_ANDROID_ROMS}/Game.play" ]] || fail "a game .play removed"
[[ ! -e "${MICROEMU_PLAY_CONTEXT}" ]] || fail "--gapps kept the context"

reset inactive
run --bogus
[[ "${rc}" == 1 ]] || fail "unknown option exit ${rc}"
[[ -e "${MICROEMU_PLAY_CONTEXT}" ]] || fail "unknown option removed the context"

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
