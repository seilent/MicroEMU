#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
off="${repo}/build/device-off"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"
export STATE="${T}/state"
export MICROEMU_USER=armada
export MICROEMU_EUID=0
export MICROEMU_USER_UID=1000
export MICROEMU_USER_RUNTIME_DIR="${T}/run/user/1000"
export MICROEMU_EXTENSIONS_DIR="${T}/extensions"
export MICROEMU_RUN_DIR="${T}/run/microemu"
export MICROEMU_SDDM_CONF_DIR="${T}/sddm"
export AUTOLOGIN="${MICROEMU_SDDM_CONF_DIR}/zz-holo-autologin.conf"

cat > "${T}/bin/runuser" <<'EOF'
#!/usr/bin/bash
echo "runuser $*" >> "${STATE}/calls"
[[ "$1 $2 $3 $4" == "-u armada -- env" ]] || { echo "runuser: unexpected $*" >&2; exit 99; }
shift 4
[[ "$1" == "XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR}" ]] || { echo "runuser: unexpected env $1" >&2; exit 99; }
shift
case "$*" in
    "systemctl --user show -p ActiveState --value gamescope-session-plus@microemu.service")
        cat "${STATE}/microemu" ;;
    "systemctl --user stop microemu-hotkeyd.service microemu-pad.service microemu-guard.service microemu-play-update.service")
        exit 5 ;;
    "systemctl --user daemon-reload")
        exit 0 ;;
    "systemctl --user stop microemu-hotkeyd.service")
        exit 5 ;;
    "systemctl --user reset-failed microemu-hotkeyd.service microemu-play-update.service")
        exit 1 ;;
    *)
        echo "unexpected runuser command: $*" >&2; exit 99 ;;
esac
EOF

cat > "${T}/bin/systemctl" <<'EOF'
#!/usr/bin/bash
echo "systemctl $*" >> "${STATE}/calls"
case "$*" in
    "start --no-block armada-session-switch@gamemode.service")
        [[ "$(cat "${STATE}/start_rc")" == 0 ]] || exit 1 ;;
    "is-active --quiet user@1000.service")
        [[ "$(cat "${STATE}/manager")" == active ]] || exit 3 ;;
esac
exit 0
EOF

cat > "${T}/bin/systemd-sysext" <<'EOF'
#!/usr/bin/bash
echo "systemd-sysext $*" >> "${STATE}/calls"
EOF

cat > "${T}/bin/sleep" <<'EOF'
#!/usr/bin/bash
echo "sleep $*" >> "${STATE}/calls"
n=$(( $(cat "${STATE}/slept") + 1 ))
echo "${n}" > "${STATE}/slept"
if (( n == $(cat "${STATE}/activate_after") )); then
    echo active > "${STATE}/microemu"
fi
if (( n == $(cat "${STATE}/settle_after") )); then
    echo inactive > "${STATE}/microemu"
    printf '[Autologin]\nUser=armada\nSession=gamescope-wayland.desktop\n' > "${AUTOLOGIN}"
fi
EOF
chmod 0755 "${T}/bin/"*
export PATH="${T}/bin:${PATH}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${STATE}" "${MICROEMU_EXTENSIONS_DIR}" "${MICROEMU_RUN_DIR}" "${MICROEMU_SDDM_CONF_DIR}" "${MICROEMU_USER_RUNTIME_DIR}"
    mkdir -p "${STATE}" "${MICROEMU_EXTENSIONS_DIR}/microemu/usr" "${MICROEMU_EXTENSIONS_DIR}/microdap/usr" \
        "${MICROEMU_RUN_DIR}" "${MICROEMU_SDDM_CONF_DIR}" "${MICROEMU_USER_RUNTIME_DIR}/microemu"
    echo drift > "${MICROEMU_USER_RUNTIME_DIR}/microemu/drift"
    : > "${STATE}/calls"
    echo "$1" > "${STATE}/microemu"
    printf '[Autologin]\nUser=armada\nSession=%s\n' "$2" > "${AUTOLOGIN}"
    echo 0 > "${STATE}/start_rc"
    echo 3 > "${STATE}/settle_after"
    echo 0 > "${STATE}/slept"
    echo 0 > "${STATE}/activate_after"
    echo active > "${STATE}/manager"
}

run() {
    rc=0
    err=$(bash "${off}" 2>&1 >/dev/null) || rc=$?
}

count() {
    grep -c -- "$1" "${STATE}/calls" || true
}

calls() { cat "${STATE}/calls"; }

removed() {
    [[ ! -e "${MICROEMU_EXTENSIONS_DIR}/microemu" ]] || fail "$1: microemu extension left: $(calls)"
    [[ ! -e "${MICROEMU_RUN_DIR}" ]] || fail "$1: /run/microemu left"
    [[ ! -e "${MICROEMU_USER_RUNTIME_DIR}/microemu" ]] || fail "$1: \$XDG_RUNTIME_DIR/microemu left"
    [[ -d "${MICROEMU_USER_RUNTIME_DIR}" ]] || fail "$1: \$XDG_RUNTIME_DIR removed"
    [[ -d "${MICROEMU_EXTENSIONS_DIR}/microdap/usr" ]] || fail "$1: microdap extension removed"
    [[ "$(count "^systemd-sysext refresh$")" == 1 ]] || fail "$1: no refresh: $(calls)"
    [[ "$(count "^systemctl daemon-reload$")" == 1 ]] || fail "$1: no system daemon-reload: $(calls)"
    [[ "$(count "^runuser -u armada -- env XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR} systemctl --user daemon-reload$")" == 1 ]] \
        || fail "$1: no user daemon-reload as armada with XDG_RUNTIME_DIR: $(calls)"
    [[ "$(count "^systemctl restart polkit$")" == 1 ]] || fail "$1: no polkit restart: $(calls)"
    [[ "$(count "systemctl --user stop microemu-hotkeyd.service microemu-pad.service microemu-guard.service microemu-play-update.service$")" == 1 ]] \
        || fail "$1: user units not stopped: $(calls)"
    [[ "$(count "^runuser -u armada -- env XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR} systemctl --user stop microemu-hotkeyd.service microemu-pad.service microemu-guard.service microemu-play-update.service$")" == 1 ]] \
        || fail "$1: user stop not run as armada with XDG_RUNTIME_DIR: $(calls)"
    order=$(grep -n -e 'systemctl --user stop' -e '^systemd-sysext refresh$' -e '^systemctl daemon-reload$' \
        -e 'systemctl --user daemon-reload$' -e 'systemctl --user reset-failed' -e '^systemctl restart polkit$' \
        "${STATE}/calls" | cut -d: -f2-)
    expected="runuser -u armada -- env XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR} systemctl --user stop microemu-hotkeyd.service microemu-pad.service microemu-guard.service microemu-play-update.service
systemd-sysext refresh
systemctl daemon-reload
runuser -u armada -- env XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR} systemctl --user daemon-reload
runuser -u armada -- env XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR} systemctl --user stop microemu-hotkeyd.service
runuser -u armada -- env XDG_RUNTIME_DIR=${MICROEMU_USER_RUNTIME_DIR} systemctl --user reset-failed microemu-hotkeyd.service microemu-play-update.service
systemctl restart polkit"
    [[ "${order}" == "${expected}" ]] || fail "$1: order $(calls)"
}

kept() {
    [[ -d "${MICROEMU_EXTENSIONS_DIR}/microemu/usr" ]] || fail "$1: microemu extension removed"
    [[ -d "${MICROEMU_RUN_DIR}" ]] || fail "$1: /run/microemu removed"
    [[ -f "${MICROEMU_USER_RUNTIME_DIR}/microemu/drift" ]] || fail "$1: \$XDG_RUNTIME_DIR/microemu removed"
    [[ "$(count "^systemd-sysext")" == 0 ]] || fail "$1: sysext touched: $(calls)"
    [[ "$(count "daemon-reload")" == 0 ]] || fail "$1: daemon-reload ran: $(calls)"
    [[ "$(count "restart polkit")" == 0 ]] || fail "$1: polkit restarted: $(calls)"
    [[ "$(count "systemctl --user stop")" == 0 ]] || fail "$1: user units stopped: $(calls)"
}

reset inactive gamescope-wayland.desktop
run
[[ "${rc}" == 0 ]] || fail "game mode exit ${rc}: ${err}"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "game mode started a switch: $(calls)"
[[ "$(count "^sleep")" == 0 ]] || fail "game mode waited: $(calls)"
removed "game mode"
[[ "$(count "unmerge")" == 0 ]] || fail "game mode ran unmerge: $(calls)"

reset active microemu.desktop
run
[[ "${rc}" == 0 ]] || fail "microemu active exit ${rc}: ${err}"
[[ "$(count "^systemctl start --no-block armada-session-switch@gamemode.service$")" == 1 ]] \
    || fail "microemu active did not start the switch: $(calls)"
[[ "$(count "^sleep 1$")" == 3 ]] || fail "microemu active waited $(count "^sleep") times, expected 3: $(calls)"
[[ "$(grep -n 'armada-session-switch' "${STATE}/calls" | cut -d: -f1)" -lt "$(grep -n 'systemctl --user stop microemu-hotkeyd.service microemu-pad.service microemu-guard.service microemu-play-update.service' "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "microemu active stopped user units before the switch: $(calls)"
removed "microemu active"
[[ "$(count "unmerge")" == 0 ]] || fail "microemu active ran unmerge: $(calls)"

reset active microemu.desktop
echo 0 > "${STATE}/settle_after"
run
[[ "${rc}" == 1 ]] || fail "microemu stuck exit ${rc}, expected 1"
[[ "$(count "^sleep 1$")" == 60 ]] || fail "microemu stuck waited $(count "^sleep") times, expected 60"
[[ "${err}" == *"not inactive or failed, or autologin names microemu.desktop after 60 s, nothing changed"* ]] \
    || fail "microemu stuck message: ${err}"
kept "microemu stuck"
[[ "$(tail -n 1 "${STATE}/calls")" == *"systemctl --user show -p ActiveState"* ]] || fail "microemu stuck slept after the last check: $(calls)"

reset inactive microemu.desktop
echo 0 > "${STATE}/settle_after"
run
[[ "${rc}" == 1 ]] || fail "autologin microemu exit ${rc}, expected 1"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "autologin microemu started a switch: $(calls)"
[[ "$(count "^sleep 1$")" == 60 ]] || fail "autologin microemu waited $(count "^sleep") times, expected 60"
kept "autologin microemu"

reset active microemu.desktop
echo 1 > "${STATE}/start_rc"
run
[[ "${rc}" == 1 ]] || fail "switch start failure exit ${rc}, expected 1"
[[ "${err}" == *"armada-session-switch@gamemode.service did not start, nothing changed"* ]] \
    || fail "switch start failure message: ${err}"
[[ "$(count "^sleep")" == 0 ]] || fail "switch start failure waited: $(calls)"
kept "switch start failure"

reset inactive gamescope-wayland.desktop
rm -f "${AUTOLOGIN}"
run
[[ "${rc}" == 0 ]] || fail "no autologin file exit ${rc}: ${err}"
removed "no autologin file"

reset inactive gamescope-wayland.desktop
export MICROEMU_OFF_WAIT_S=5
echo active > "${STATE}/microemu"
echo 0 > "${STATE}/settle_after"
run
[[ "${rc}" == 1 ]] || fail "wait override exit ${rc}, expected 1"
[[ "$(count "^sleep 1$")" == 5 ]] || fail "wait override waited $(count "^sleep") times, expected 5"
kept "wait override"
unset MICROEMU_OFF_WAIT_S

reset activating microemu.desktop
run
[[ "${rc}" == 0 ]] || fail "microemu activating exit ${rc}: ${err}"
[[ "$(count "^systemctl start --no-block armada-session-switch@gamemode.service$")" == 1 ]] \
    || fail "microemu activating did not start the switch: $(calls)"
[[ "$(count "^sleep 1$")" == 3 ]] || fail "microemu activating waited $(count "^sleep") times, expected 3"
removed "microemu activating"

reset deactivating gamescope-wayland.desktop
run
[[ "${rc}" == 0 ]] || fail "microemu deactivating exit ${rc}: ${err}"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "microemu deactivating started a switch: $(calls)"
[[ "$(count "^sleep 1$")" == 3 ]] || fail "microemu deactivating waited $(count "^sleep") times, expected 3"
removed "microemu deactivating"

reset deactivating gamescope-wayland.desktop
echo 0 > "${STATE}/settle_after"
run
[[ "${rc}" == 1 ]] || fail "microemu stuck deactivating exit ${rc}, expected 1"
[[ "$(count "^sleep 1$")" == 60 ]] || fail "microemu stuck deactivating waited $(count "^sleep") times, expected 60"
kept "microemu stuck deactivating"

reset failed gamescope-wayland.desktop
run
[[ "${rc}" == 0 ]] || fail "microemu failed exit ${rc}: ${err}"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "microemu failed started a switch: $(calls)"
[[ "$(count "^sleep")" == 0 ]] || fail "microemu failed waited: $(calls)"
removed "microemu failed"

reset "" gamescope-wayland.desktop
echo inactive > "${STATE}/manager"
run
[[ "${rc}" == 0 ]] || fail "no user manager exit ${rc}: ${err}"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "no user manager started a switch: $(calls)"
[[ "$(count "^sleep")" == 0 ]] || fail "no user manager waited: $(calls)"
removed "no user manager"

reset "" microemu.desktop
echo inactive > "${STATE}/manager"
echo 0 > "${STATE}/settle_after"
MICROEMU_OFF_WAIT_S=2 run
[[ "${rc}" == 1 ]] || fail "no user manager with autologin microemu exit ${rc}, expected 1"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "no user manager with autologin microemu started a switch: $(calls)"
kept "no user manager with autologin microemu"

reset inactive gamescope-wayland.desktop
printf '[Autologin]\r\nUser=armada\r\nSession = microemu.desktop \r\n' > "${AUTOLOGIN}"
echo 0 > "${STATE}/settle_after"
MICROEMU_OFF_WAIT_S=2 run
[[ "${rc}" == 1 ]] || fail "autologin with spaces and CR exit ${rc}, expected 1"
kept "autologin with spaces and CR"

reset inactive gamescope-wayland.desktop
printf '[Autologin]\nSession=microemu.desktop.bak\n' > "${AUTOLOGIN}"
run
[[ "${rc}" == 0 ]] || fail "other session name exit ${rc}: ${err}"
removed "other session name"

reset inactive gamescope-wayland.desktop
MICROEMU_EUID=1000 run
[[ "${rc}" == 1 ]] || fail "not root exit ${rc}, expected 1"
[[ "${err}" == *"run as root"* ]] || fail "not root message: ${err}"
[[ ! -s "${STATE}/calls" ]] || fail "not root ran $(calls)"
kept "not root"

reset "" gamescope-wayland.desktop
echo 0 > "${STATE}/settle_after"
MICROEMU_OFF_WAIT_S=2 run
[[ "${rc}" == 1 ]] || fail "failed query with the manager up exit ${rc}, expected 1"
[[ "$(count "armada-session-switch")" == 0 ]] || fail "failed query started a switch: $(calls)"
kept "failed query with the manager up"

reset inactive microemu.desktop
echo 1 > "${STATE}/activate_after"
echo 4 > "${STATE}/settle_after"
run
[[ "${rc}" == 0 ]] || fail "late activation exit ${rc}: ${err}"
[[ "$(count "^systemctl start --no-block armada-session-switch@gamemode.service$")" == 1 ]] \
    || fail "late activation started the switch $(count "armada-session-switch") times, expected 1: $(calls)"
[[ "$(grep -n '^sleep 1$' "${STATE}/calls" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'armada-session-switch' "${STATE}/calls" | cut -d: -f1)" ]] \
    || fail "late activation started the switch before the session was active: $(calls)"
removed "late activation"

reset inactive gamescope-wayland.desktop
: > "${MICROEMU_EXTENSIONS_DIR}/microemu.raw"
: > "${MICROEMU_EXTENSIONS_DIR}/microdap.raw"
run
[[ "${rc}" == 0 ]] || fail "raw images exit ${rc}: ${err}"
[[ ! -e "${MICROEMU_EXTENSIONS_DIR}/microemu.raw" ]] || fail "raw images: microemu.raw left"
[[ -f "${MICROEMU_EXTENSIONS_DIR}/microdap.raw" ]] || fail "raw images: microdap.raw removed"
removed "raw images"

if (( failures )); then
    echo "device-off-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "device-off-test: ok"
