#!/usr/bin/bash
set -eu

export PYTHONDONTWRITEBYTECODE=1

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
nodes="${repo}/sysext/usr/libexec/microemu/microemu-pad-nodes"
fuzz="${repo}/sysext/usr/libexec/microemu/microemu-pad-fuzz"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export MICROEMU_SYS_INPUT="${T}/sys"
export MICROEMU_DEV_INPUT="${T}/dev"
mkdir -p "${MICROEMU_DEV_INPUT}" "${T}/fake"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

node() {
    mkdir -p "${MICROEMU_SYS_INPUT}/$1/device/id"
    echo "$2" > "${MICROEMU_SYS_INPUT}/$1/device/name"
    echo "$3" > "${MICROEMU_SYS_INPUT}/$1/device/id/vendor"
    echo "$4" > "${MICROEMU_SYS_INPUT}/$1/device/id/product"
    [[ "${5:-dev}" != dev ]] || : > "${MICROEMU_DEV_INPUT}/$1"
}

node event10 "Microsoft X-Box 360 pad" 045e 028e
node event12 "Microsoft X-Box 360 pad" 045e 028e
node event3 "aya-keys" 0001 0001
node event5 "Microsoft X-Box 360 pad" 28de 11ff
node event7 "Steam Deck" 045e 028e
node event9 "Microsoft X-Box 360 pad" 045e 028e nodev
[[ "$("${nodes}")" == "${MICROEMU_DEV_INPUT}/event10"$'\n'"${MICROEMU_DEV_INPUT}/event12" ]] || fail "pad nodes: $("${nodes}")"
MICROEMU_SYS_INPUT="${T}/none" "${nodes}" > "${T}/out"
[[ ! -s "${T}/out" ]] || fail "pad nodes without input devices: $(cat "${T}/out")"

cat > "${T}/fake/fake_fcntl.py" <<'PY'
import os
import struct

LOG = os.environ["FAKE_IOCTL_LOG"]


def ioctl(fd, op, arg):
    with open(LOG, "a") as log:
        if isinstance(arg, bytearray):
            arg[:] = struct.pack("6i", 500, -32768, 32767, 16, 128, 0)
            log.write(f"get {op:#x}\n")
        else:
            log.write(f"set {op:#x} {list(struct.unpack('6i', arg))}\n")
    if os.environ.get("FAKE_IOCTL_FAIL") == os.path.basename(fd.name):
        raise OSError(25, "Inappropriate ioctl for device")
    return 0
PY
export FAKE_IOCTL_LOG="${T}/ioctl"
cat > "${T}/fake/harness.py" <<'PY'
import importlib.machinery
import importlib.util
import sys

fake_loader = importlib.machinery.SourceFileLoader("fcntl", sys.argv[1] + "/fake_fcntl.py")
fake = importlib.util.module_from_spec(importlib.util.spec_from_loader("fcntl", fake_loader))
fake_loader.exec_module(fake)
sys.modules["fcntl"] = fake
loader = importlib.machinery.SourceFileLoader("microemu_pad_fuzz", sys.argv[2])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
sys.exit(module.main(sys.argv[3:]))
PY
fuzz_run() { python3 "${T}/fake/harness.py" "${T}/fake" "${fuzz}" "$@"; }

fuzz_run "${MICROEMU_DEV_INPUT}/event10"
expected="get 0x80184540
set 0x401845c0 [500, -32768, 32767, 512, 128, 0]
get 0x80184541
set 0x401845c1 [500, -32768, 32767, 512, 128, 0]
get 0x80184543
set 0x401845c3 [500, -32768, 32767, 512, 128, 0]
get 0x80184544
set 0x401845c4 [500, -32768, 32767, 512, 128, 0]"
[[ "$(cat "${FAKE_IOCTL_LOG}")" == "${expected}" ]] || fail "ioctls: $(cat "${FAKE_IOCTL_LOG}")"

: > "${FAKE_IOCTL_LOG}"
rc=0
FAKE_IOCTL_FAIL=event10 fuzz_run "${MICROEMU_DEV_INPUT}/event10" "${MICROEMU_DEV_INPUT}/event12" 2> "${T}/err" || rc=$?
[[ "${rc}" == 1 ]] || fail "failing node exit ${rc}"
grep -q "set 0x401845c4" "${FAKE_IOCTL_LOG}" || fail "second node skipped after a failure"
grep -q "event10" "${T}/err" || fail "failure not reported: $(cat "${T}/err")"

rc=0
fuzz_run "${T}/absent" 2>/dev/null || rc=$?
[[ "${rc}" == 1 ]] || fail "missing node exit ${rc}"

if (( failures )); then
    echo "pad-fuzz-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "pad-fuzz-test: ok"
