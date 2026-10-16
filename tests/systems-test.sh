#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
data="${repo}/data"
systems="${data}/usr/share/microemu/es-de/es_systems.xml"

failures=0
fail() { echo "FAIL $*" >&2; failures=$((failures + 1)); }

T=$(mktemp -d)
trap 'rm -rf "${T}"' EXIT
[[ "$(sed -n 2p "${systems}")" == "<loadExclusive/>" && "$(sed -n 3p "${systems}")" == "<systemList>" ]] \
    || fail "<loadExclusive/> is not the top level element right before <systemList>"
{ echo '<wrap>'; sed 1d "${systems}"; echo '</wrap>'; } > "${T}/wrapped.xml"
xmllint --noout "${T}/wrapped.xml" || fail "xmllint rejects ${systems}"
systems="${T}/wrapped.xml"
[[ "$(xmllint --xpath 'count(/wrap/systemList//loadExclusive)' "${systems}")" == 0 ]] || fail "a <loadExclusive/> inside <systemList>"

cores="mednafen_ngp_libretro.so
mednafen_pce_fast_libretro.so
mednafen_vb_libretro.so
mednafen_wswan_libretro.so
bsnes_mercury_performance_libretro.so
gambatte_libretro.so
gw_libretro.so
handy_libretro.so
mgba_libretro.so
nestopia_libretro.so
pcsx_rearmed_libretro.so
prosystem_libretro.so
stella2014_libretro.so"

count=$(xmllint --xpath 'count(/wrap/systemList/system)' "${systems}")
(( count > 0 )) || fail "no systems"
for ((i = 1; i <= count; i++)); do
    name=$(xmllint --xpath "string(/wrap/systemList/system[${i}]/name)" "${systems}")
    path=$(xmllint --xpath "string(/wrap/systemList/system[${i}]/path)" "${systems}")
    extensions=$(xmllint --xpath "string(/wrap/systemList/system[${i}]/extension)" "${systems}")
    [[ -n "$(xmllint --xpath "string(/wrap/systemList/system[${i}]/theme)" "${systems}")" ]] || fail "${name}: no theme"
    commands=$(xmllint --xpath "count(/wrap/systemList/system[${i}]/command)" "${systems}")
    (( commands > 0 )) || fail "${name}: no command"
    for ((j = 1; j <= commands; j++)); do
        command=$(xmllint --xpath "string(/wrap/systemList/system[${i}]/command[${j}])" "${systems}")
        if [[ "${name}" == microos ]]; then
            [[ "${command}" == "/usr/bin/microos-session set-default %BASENAME%" ]] || fail "microos: command ${command}"
            continue
        fi
        [[ "${command}" == /usr/libexec/microemu/bin/retroarch\ * ]] || fail "${name}: command is not the RetroArch wrapper: ${command}"
        exe=${command%% *}
        [[ -x "${data}${exe}" ]] || fail "${name}: ${exe} not shipped"
        for core in $(grep -oE -- '-L [^ ]+' <<<"${command}" | cut -d' ' -f2); do
            [[ "${core}" == /usr/lib64/libretro/* ]] || fail "${name}: core outside /usr/lib64/libretro: ${core}"
            grep -qx "$(basename "${core}")" <<<"${cores}" || fail "${name}: core $(basename "${core}") not shipped by the build"
        done
    done
    if [[ "${name}" == microos ]]; then
        [[ "${path}" == %MICROOS_SESSIONS% && "${extensions}" == .session ]] || fail "microos: path ${path}, extensions ${extensions}"
    else
        [[ "${path}" == "%ROMPATH%/${name}" ]] || fail "${name}: path ${path}"
    fi
done
[[ "$(xmllint --xpath 'count(/wrap/systemList/system[name="microos"])' "${systems}")" == 1 ]] || fail "no microos system"
[[ "$(xmllint --xpath 'count(/wrap/systemList/system[name="androidgames"])' "${systems}")" == 0 ]] || fail "androidgames system shipped"
for core in ${cores}; do
    grep -q "/usr/lib64/libretro/${core} " "${systems}" || fail "core ${core} used by no system"
done

if (( failures )); then
    echo "systems-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "systems-test: ok"
