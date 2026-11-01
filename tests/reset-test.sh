#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
reset_cmd="${repo}/android/data/usr/bin/microemu-play-reset"

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
    "ps -a")
        case "$*" in
            *label=lepton=true*) [[ "$(cat "${STATE}/ps_fail" 2>/dev/null)" != leptons ]] || exit 125 ;;
            *) [[ "$(cat "${STATE}/ps_fail" 2>/dev/null)" != users ]] || exit 125 ;;
        esac
        for f in "${STATE}"/container-*; do
            [[ -e "${f}" ]] || continue
            case "$*" in
                *label=lepton=true*) grep -qx lepton=true "${f}" && echo "${f##*/container-}" ;;
                *STEAM_COMPAT_DATA_PATH*) echo "${f##*/container-} $(sed -n 's/^STEAM_COMPAT_DATA_PATH=//p' "${f}")" ;;
            esac
        done
        exit 0
        ;;
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

export MICROEMU_PLAY_NAME=probe-lh-copy
reset inactive
printf 'lepton=true\nSTEAM_COMPAT_DATA_PATH=%s\n' "${MICROEMU_PLAY_CONTEXT}" > "${STATE}/container-lepton-microemu-play"
run
[[ "${rc}" == 1 ]] && grep -qx "microemu-play-reset: ${MICROEMU_PLAY_CONTEXT} is not a probe-lh-copy context, refusing" "${STATE}/out" \
    || fail "named on the microemu-play context: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${MICROEMU_PLAY_CONTEXT}" && -d "${MICROEMU_ANDROID_DATA}/sideload" && ! -s "${STATE}/calls" ]] \
    || fail "named on the microemu-play context: something removed or podman called"
real="${MICROEMU_PLAY_CONTEXT}"
export MICROEMU_PLAY_CONTEXT="${T}/contexts/probe-lh-copy"
reset inactive
mkdir -p "${real}/keep"
printf 'lepton=true\nSTEAM_COMPAT_DATA_PATH=%s\n' "${real}" > "${STATE}/container-lepton-microemu-play"
run
[[ "${rc}" == 1 ]] && grep -qx "microemu-play-reset: Lepton containers exist (lepton-microemu-play), ${MICROEMU_ANDROID_DATA}/sideload, ${MICROEMU_ANDROID_DATA}/prune and ${MICROEMU_GAPPS} are shared, refusing" "${STATE}/out" \
    || fail "named with the microemu-play container: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${MICROEMU_PLAY_CONTEXT}" && -d "${real}/keep" && -d "${MICROEMU_ANDROID_DATA}/sideload" ]] \
    || fail "named with the microemu-play container: something removed"
reset inactive
mkdir -p "${real}/keep"
run
[[ "${rc}" == 0 && ! -e "${MICROEMU_PLAY_CONTEXT}" && -d "${real}/keep" ]] || fail "named: exit ${rc}, not only its own context removed: $(cat "${STATE}/out")"
reset inactive
rm -rf "${T:?}/home" "${MICROEMU_ANDROID_DATA:?}/home"
default_ctx="${MICROEMU_ANDROID_DATA}/home/.local/share/lepton/contexts"
mkdir -p "${default_ctx}/probe-lh-copy" "${default_ctx}/microemu-play" "${T}/home/.local/share/lepton/contexts/probe-lh-copy"
rc=0
env -u MICROEMU_PLAY_CONTEXT HOME="${T}/home" "${reset_cmd}" > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && ! -e "${default_ctx}/probe-lh-copy" && -d "${default_ctx}/microemu-play" && ! -e "${T}/home/.local/share/lepton/contexts/probe-lh-copy" ]] \
    || fail "named, default context: exit ${rc}: $(ls "${default_ctx}" 2>/dev/null): $(ls "${T}/home/.local/share/lepton/contexts" 2>/dev/null): $(cat "${STATE}/out")"
reset inactive
rm -rf "${T:?}/home" "${MICROEMU_ANDROID_DATA:?}/home"
mkdir -p "${MICROEMU_ANDROID_DATA}/home/.local/share/lepton/contexts/microemu-play/internal" "${T}/home/.local/share/lepton/contexts/microemu-play/internal"
rc=0
env -u MICROEMU_PLAY_CONTEXT -u MICROEMU_PLAY_NAME HOME="${T}/home" "${reset_cmd}" > "${STATE}/out" 2>&1 || rc=$?
[[ "${rc}" == 0 && ! -e "${MICROEMU_ANDROID_DATA}/home/.local/share/lepton/contexts/microemu-play" && ! -e "${T}/home/.local/share/lepton/contexts/microemu-play" ]] \
    || fail "unnamed, both paths: exit ${rc}: $(cat "${STATE}/out")"
for container in lepton-probe-lh-copy lepton-headless-probe-lh-copy; do
    reset inactive
    : > "${STATE}/container-${container}"
    run
    [[ "${rc}" == 1 ]] && grep -q "container ${container} exists" "${STATE}/out" || fail "named ${container} present: exit ${rc}"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" ]] || fail "named ${container} present: context removed"
done
reset inactive
MICROEMU_PLAY_NAME=Bad run
[[ "${rc}" == 1 ]] && grep -qx "microemu-play-reset: bad MICROEMU_PLAY_NAME Bad" "${STATE}/out" || fail "bad name: exit ${rc}"
[[ -d "${MICROEMU_PLAY_CONTEXT}" && ! -s "${STATE}/calls" ]] || fail "bad name: context removed or podman called"
unset MICROEMU_PLAY_NAME
export MICROEMU_PLAY_CONTEXT="${real}"

for spelling in "${MICROEMU_PLAY_CONTEXT}" "${T}/contexts//microemu-play/"; do
    reset inactive
    printf 'STEAM_COMPAT_DATA_PATH=%s\n' "${spelling}" > "${STATE}/container-lepton-other"
    run
    [[ "${rc}" == 1 ]] && grep -qx "microemu-play-reset: container lepton-other uses ${MICROEMU_PLAY_CONTEXT}, refusing" "${STATE}/out" \
        || fail "another container on the context (${spelling}): exit ${rc}: $(cat "${STATE}/out")"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" ]] || fail "another container on the context (${spelling}): context removed"
done
reset inactive
echo lepton=true > "${STATE}/container-lepton-steamlaunch-1"
run
[[ "${rc}" == 1 ]] && grep -q "microemu-play-reset: Lepton containers exist (lepton-steamlaunch-1)" "${STATE}/out" \
    || fail "another Lepton container: exit ${rc}: $(cat "${STATE}/out")"
[[ -d "${MICROEMU_PLAY_CONTEXT}" && -d "${MICROEMU_ANDROID_DATA}/sideload" ]] || fail "another Lepton container: something removed"
for which in users leptons; do
    reset inactive
    echo "${which}" > "${STATE}/ps_fail"
    run
    [[ "${rc}" == 1 ]] && grep -qx "microemu-play-reset: podman ps failed, refusing" "${STATE}/out" || fail "podman ps error (${which}): exit ${rc}"
    [[ -d "${MICROEMU_PLAY_CONTEXT}" && -d "${MICROEMU_ANDROID_DATA}/sideload" ]] || fail "podman ps error (${which}): something removed"
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
