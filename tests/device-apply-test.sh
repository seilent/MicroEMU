#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
apply="${repo}/build/device-apply"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_USER=armada
export MICROEMU_USER_UID=1000
export MICROEMU_EXTENSIONS_DIR="${T}/extensions"
export MICROEMU_STAGE_DIR="${T}/stage"

cat > "${T}/bin/runuser" <<'STUB'
#!/usr/bin/bash
echo "runuser $*" >> "${STATE}/calls"
[[ "$*" == "-u armada -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active gamescope-session-plus@steam.service" ]] \
    || { echo "runuser: unexpected $*" >&2; exit 99; }
cat "${STATE}/steam"
[[ "$(cat "${STATE}/steam")" == active ]]
STUB
for name in rsync systemctl systemd-sysext; do
    printf '#!/usr/bin/bash\necho "%s $*" >> "${STATE}/calls"\n' "${name}" > "${T}/bin/${name}"
done
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROEMU_EXTENSIONS_DIR}"
    mkdir -p "${STATE}" "${MICROEMU_EXTENSIONS_DIR}"
    : > "${STATE}/calls"
    echo "$1" > "${STATE}/steam"
}

run() {
    rc=0
    err=$(bash "${apply}" 2>&1 >/dev/null) || rc=$?
}

count() { grep -c -- "$1" "${STATE}/calls" || true; }

calls() { cat "${STATE}/calls"; }

untouched() {
    [[ "$(count "^rsync")" == 0 ]] || fail "$1: rsync ran: $(calls)"
    [[ "$(count "^systemd-sysext")" == 0 ]] || fail "$1: sysext touched: $(calls)"
    [[ ! -e "${MICROEMU_EXTENSIONS_DIR}/microemu" ]] || fail "$1: extension directory created"
}

reset active
run
[[ "${rc}" == 0 ]] || fail "game mode exit ${rc}: ${err}"
[[ "$(count "^rsync -a --delete --chown=root:root ${MICROEMU_STAGE_DIR}/ ${MICROEMU_EXTENSIONS_DIR}/microemu/$")" == 1 ]] \
    || fail "game mode: no root owned copy: $(calls)"
order=$(grep -e '^rsync' -e '^systemd-sysext refresh$' -e '^systemctl restart polkit$' "${STATE}/calls" | cut -d' ' -f1-2)
[[ "${order}" == $'rsync -a\nsystemd-sysext refresh\nsystemctl restart' ]] || fail "game mode order: $(calls)"

for state in inactive activating ""; do
    reset "${state}"
    run
    [[ "${rc}" == 1 ]] || fail "steam '${state}' exit ${rc}, expected 1"
    [[ "${err}" == *"game mode is not active"* ]] || fail "steam '${state}' message: ${err}"
    untouched "steam '${state}'"
done

reset inactive
MICROEMU_DEPLOY_ANY_SESSION=1 run
[[ "${rc}" == 0 ]] || fail "any session override exit ${rc}: ${err}"
[[ "$(count "^systemd-sysext refresh$")" == 1 ]] || fail "any session override: no refresh: $(calls)"

reset active
: > "${MICROEMU_EXTENSIONS_DIR}/microemu.raw"
run
[[ "${rc}" == 1 ]] || fail "raw installed exit ${rc}, expected 1"
[[ "${err}" == *"microemu.raw is installed, refusing to deploy the directory beside it"* ]] || fail "raw installed message: ${err}"
untouched "raw installed"

reset active
: > "${MICROEMU_EXTENSIONS_DIR}/microdap.raw"
run
[[ "${rc}" == 0 ]] || fail "microdap raw exit ${rc}: ${err}"

if (( failures )); then
    echo "device-apply-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "device-apply-test: ok"
