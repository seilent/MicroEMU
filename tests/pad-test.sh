#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
pad="${repo}/data/usr/libexec/microemu/microemu-pad"
unit="${repo}/data/usr/lib/systemd/user/microemu-pad.service"
export PYTHONDONTWRITEBYTECODE=1

T=$(mktemp -d)
pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill "${pid}" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "${T}"
}
trap cleanup EXIT

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

cat > "${T}/inputplumber" <<'EOF'
#!/usr/bin/python3
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

ROOT = "/org/shadowblip/InputPlumber"
COMPOSITE = "org.shadowblip.Input.CompositeDevice"
OM = "org.freedesktop.DBus.ObjectManager"
XML = f"""
<node>
  <interface name="{OM}">
    <method name="GetManagedObjects"><arg type="a{{oa{{sa{{sv}}}}}}" direction="out"/></method>
    <signal name="InterfacesAdded"><arg type="o"/><arg type="a{{sa{{sv}}}}"/></signal>
  </interface>
  <interface name="{COMPOSITE}">
    <method name="SetTargetDevices"><arg type="as" direction="in"/></method>
  </interface>
  <interface name="test.Stub">
    <method name="AddDevice"><arg type="u" direction="in"/></method>
    <method name="AddOther"/>
  </interface>
</node>
"""
address, log, devices = sys.argv[1], sys.argv[2], [int(n) for n in sys.argv[3].split(",") if n]
info = {i.name: i for i in Gio.DBusNodeInfo.new_for_xml(XML).interfaces}
bus = Gio.DBusConnection.new_for_address_sync(
    address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)


def record(line):
    with open(log, "a") as f:
        f.write(line + "\n")


def path(n):
    return f"{ROOT}/CompositeDevice{n}"


def method(conn, _sender, obj, _iface, name, params, invocation):
    if name == "GetManagedObjects":
        objs = {path(n): {COMPOSITE: {}} for n in devices}
        objs[f"{ROOT}/devices/target/gamepad0"] = {"org.shadowblip.Input.Gamepad": {}}
        invocation.return_value(GLib.Variant("(a{oa{sa{sv}}})", (objs,)))
    elif name == "SetTargetDevices":
        record(f"set {obj} {' '.join(params.unpack()[0])}")
        invocation.return_value(None)
    elif name == "AddDevice":
        n = params.unpack()[0]
        devices.append(n)
        register(path(n))
        conn.emit_signal(None, ROOT, OM, "InterfacesAdded", GLib.Variant("(oa{sa{sv}})", (path(n), {COMPOSITE: {}})))
        invocation.return_value(None)
    elif name == "AddOther":
        conn.emit_signal(None, ROOT, OM, "InterfacesAdded",
                         GLib.Variant("(oa{sa{sv}})", (f"{ROOT}/devices/target/gamepad1", {"org.shadowblip.Input.Gamepad": {}})))
        invocation.return_value(None)


def register(obj):
    bus.register_object(obj, info[COMPOSITE], method, None, None)


bus.register_object(ROOT, info[OM], method, None, None)
bus.register_object(ROOT, info["test.Stub"], method, None, None)
for n in devices:
    register(path(n))


def acquired(*_):
    record("owned")


Gio.bus_own_name_on_connection(bus, "org.shadowblip.InputPlumber", Gio.BusNameOwnerFlags.NONE, acquired, None)
GLib.MainLoop().run()
EOF
chmod 0755 "${T}/inputplumber"

cat > "${T}/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=${T}/bus</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
dbus-daemon --config-file="${T}/bus.conf" --nofork --nopidfile &
pids+=($!)
export MICROEMU_PAD_BUS="unix:path=${T}/bus"
for _ in $(seq 1 100); do [[ -S "${T}/bus" ]] && break; sleep 0.05; done
[[ -S "${T}/bus" ]] || { echo "pad-test: no bus" >&2; exit 1; }

log="${T}/log"
: > "${log}"

wait_for() {
    local want=$1
    for _ in $(seq 1 100); do
        [[ "$(grep -c -- "$2" "${log}" || true)" -ge "${want}" ]] && return 0
        sleep 0.05
    done
    return 1
}

stub_call() {
    gdbus call --address "${MICROEMU_PAD_BUS}" --dest org.shadowblip.InputPlumber --object-path /org/shadowblip/InputPlumber \
        --method "test.Stub.$1" "${@:2}" >/dev/null
}

start_ip() {
    "${T}/inputplumber" "${MICROEMU_PAD_BUS}" "${log}" "$1" &
    ip_pid=$!
    pids+=("${ip_pid}")
    wait_for "$2" "^owned$" || fail "fake InputPlumber did not take the name"
}

"${pad}" xb360 2> "${T}/pad.err" &
pad_pid=$!
pids+=("${pad_pid}")
sleep 0.3
kill -0 "${pad_pid}" 2>/dev/null || fail "microemu-pad exited without InputPlumber"
[[ "$(grep -c '^set ' "${log}" || true)" == 0 ]] || fail "a set without InputPlumber"

start_ip 0,1 1
wait_for 2 "^set " || fail "start: devices not set: $(cat "${log}")"
grep -qx "set /org/shadowblip/InputPlumber/CompositeDevice0 xb360 keyboard" "${log}" || fail "start: CompositeDevice0 not set"
grep -qx "set /org/shadowblip/InputPlumber/CompositeDevice1 xb360 keyboard" "${log}" || fail "start: CompositeDevice1 not set"
grep -q "gamepad0" "${log}" && fail "start: a target device was set"

stub_call AddDevice 2
wait_for 3 "^set " || fail "device added: not set: $(cat "${log}")"
grep -qx "set /org/shadowblip/InputPlumber/CompositeDevice2 xb360 keyboard" "${log}" || fail "device added: CompositeDevice2 not set"
stub_call AddOther
sleep 0.3
[[ "$(grep -c '^set ' "${log}")" == 3 ]] || fail "a non composite object was set: $(cat "${log}")"

kill "${ip_pid}"
wait "${ip_pid}" 2>/dev/null || true
sleep 0.3
kill -0 "${pad_pid}" 2>/dev/null || fail "microemu-pad exited when InputPlumber left"
start_ip 5 2
wait_for 4 "^set " || fail "InputPlumber restart: not set again: $(cat "${log}")"
grep -qx "set /org/shadowblip/InputPlumber/CompositeDevice5 xb360 keyboard" "${log}" || fail "InputPlumber restart: CompositeDevice5 not set"
stub_call AddDevice 6
wait_for 5 "^set " || fail "device added after the restart: not set"
[[ "$(grep -c 'CompositeDevice6' "${log}")" == 1 ]] || fail "device added after the restart: set $(grep -c 'CompositeDevice6' "${log}") times (old subscription kept)"

kill -TERM "${pad_pid}"
rc=0
wait "${pad_pid}" || rc=$?
[[ "${rc}" == 0 ]] || fail "SIGTERM exit ${rc}"
grep -q "set /org/shadowblip/InputPlumber/CompositeDevice0 target to xb360 keyboard" "${T}/pad.err" || fail "no log line: $(cat "${T}/pad.err")"

rc=0
"${pad}" bogus 2>/dev/null || rc=$?
[[ "${rc}" == 2 ]] || fail "bad argument exit ${rc}"

grep -qx 'ExecStart=/usr/libexec/microemu/microemu-pad xb360' "${unit}" || fail "unit ExecStart"
grep -q '^Type=oneshot\|^RemainAfterExit' "${unit}" && fail "unit is still a oneshot"
grep -qx 'BindsTo=gamescope-session-plus@microemu.service' "${unit}" || fail "unit not bound to the session"
grep -qx 'After=gamescope-session-plus@microemu.service steamos-manager.service' "${unit}" || fail "unit ordering"

if (( failures )); then
    echo "pad-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "pad-test: ok"
