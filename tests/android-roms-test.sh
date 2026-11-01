#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
roms_cmd="${repo}/data/usr/libexec/microemu/microemu-android-roms"

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home"
export MICROEMU_RUNTIME_DIR="${T}/run/microemu"
paths="${MICROEMU_RUNTIME_DIR}/paths"
fallback="${HOME}/ROMs/androidgames"
mkdir -p "${HOME}" "${MICROEMU_RUNTIME_DIR}"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

reset() {
    rm -rf "${T:?}/card" "${T:?}/run" "${HOME:?}/ROMs"
    mkdir -p "${MICROEMU_RUNTIME_DIR}" "${HOME}"
}

pick() {
    printf '%s\n' layout=names "root=$1" "roms=$2" "bios=$1/BIOS/retroarch" "saves=$1/Saves" "states=$1/States" \
        "screenshots=$1/Screenshots" "media=$1/Media" saves_in_content=false > "${paths}"
}

run() {
    rc=0
    out=$("${roms_cmd}" 2> "${T}/err") || rc=$?
    err=$(cat "${T}/err")
}

reset
run
[[ "${rc}" == 0 && "${out}" == "${fallback}" ]] || fail "no paths file: exit ${rc}, out ${out}, err ${err}"

reset
: > "${paths}"
run
[[ "${rc}" == 0 && "${out}" == "${fallback}" ]] || fail "empty paths file: exit ${rc}, out ${out}"

reset
pick "${HOME}" "${HOME}/Games"
mkdir -p "${HOME}/Games"
run
[[ "${out}" == "${HOME}/Games/androidgames" ]] || fail "home folder: out ${out}"

reset
pick "${HOME}" ROMs
mkdir -p "${HOME}/ROMs"
run
[[ "${out}" == "${fallback}" ]] || fail "relative roms: out ${out}"

reset
printf '%s\n' layout=names "root=${HOME}" "roms=${HOME}/Games" "roms=${HOME}/Saves" saves_in_content=false > "${paths}"
mkdir -p "${HOME}/Games" "${HOME}/Saves"
run
[[ "${out}" == "${HOME}/Games/androidgames" ]] || fail "two lines: the first value did not win: ${out}"

reset
mkdir -p "${T}/absent"
pick "${HOME}" "${T}/absent/ROMs"
run
[[ "${out}" == "${fallback}" ]] || fail "missing dir: out ${out}"

reset
mkdir -p "${HOME}/Games"
ln -s "${HOME}/Games" "${T}/link"
pick "${HOME}" "${T}/link"
run
[[ "${out}" == "${fallback}" ]] || fail "link: out ${out}"

reset
card="${T}/card"
mkdir -p "${card}/Games"
pick "${T}/other" "${card}/Games"
run
[[ "${out}" == "${fallback}" ]] || fail "a plain dir that is not the card's mount root: out ${out}"

reset
card="${T}/card"
mkdir -p "${T}/rootdir" "${card}/Games"
pick "${T}/rootdir" "${card}/Games"
run
[[ "${out}" == "${fallback}" ]] || fail "an existing root that is not the mount of roms: out ${out}"

reset
card="${T}/card"
mkdir -p "${card}/ROMs"
pick "$(findmnt -rno TARGET -T "${card}")" "${card}/ROMs"
run
[[ "${out}" == "${card}/ROMs/androidgames" ]] || fail "roms on the card's mount root: out ${out}"

reset
mkdir -p "${T}/ghost/ROMs"
pick "${T}/gone" "${T}/ghost/ROMs"
run
[[ "${out}" == "${fallback}" ]] || fail "a ghost dir left behind a card that is gone: out ${out}"

reset
other="${T}/other"
mkdir -p "${other}"
pick "$(findmnt -rno TARGET -T "${other}")" "${other}"
run
[[ "${out}" == "${other}/androidgames" ]] || fail "roms on its root's mount: out ${out}"

reset
mkdir -p "${HOME}/ROMs"
printf '%s\n' "roms=${HOME}/ROMs" > "${paths}"
run
[[ "${out}" == "${HOME}/ROMs/androidgames" ]] || fail "home roms without a root line: out ${out}"

reset
ln -s "${HOME}" "${T}/homelink"
mkdir -p "${HOME}/ROMs"
pick "${T}/homelink" "${HOME}/ROMs"
out=$(HOME="${T}/homelink" "${roms_cmd}")
[[ "${out}" == "${HOME}/ROMs/androidgames" ]] || fail "HOME through a symlink: out ${out}"
rm -f "${T:?}/homelink"

if (( failures )); then
    echo "android-roms-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "android-roms-test: ok"
