#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
sysext="${repo}/sysext"
systems="${sysext}/usr/share/microemu/es-de/es_systems.xml"

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

cores=
if [[ -f "${repo}/build/retroarch.sh" ]]; then
    cores=$(grep -oE '[a-z0-9_]+_libretro\.so' "${repo}/build/retroarch.sh" | sort -u)
fi

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
        [[ "${command}" == /usr/libexec/microemu/* ]] || fail "${name}: command outside /usr/libexec/microemu: ${command}"
        exe=${command%% *}
        [[ -x "${sysext}${exe}" ]] || fail "${name}: ${exe} not shipped"
        for core in $(grep -oE -- '-L [^ ]+' <<<"${command}" | cut -d' ' -f2); do
            [[ "${core}" == /usr/lib64/libretro/* ]] || fail "${name}: core outside /usr/lib64/libretro: ${core}"
            grep -qx "$(basename "${core}")" <<<"${cores}" || fail "${name}: core $(basename "${core}") not shipped by the build"
        done
    done
    if [[ "${path}" == /* ]]; then
        [[ -d "${sysext}${path}" ]] || fail "${name}: ${path} not shipped"
        found=0
        for ext in ${extensions}; do
            compgen -G "${sysext}${path}/*${ext}" >/dev/null && found=1
        done
        (( found )) || fail "${name}: no ${extensions} entry under ${path}"
    fi
done

if (( failures )); then
    echo "systems-test: ${failures} failure(s)" >&2
    exit 1
fi
echo "systems-test: ok"
