#!/usr/bin/bash
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "${here}")
dist="${MICROEMU_DIST:-${repo}/dist}"
other="${MICROEMU_OTHER_DIST:-}"

if [[ -z "${other}" ]]; then
    echo "paths-test: skip, MICROEMU_OTHER_DIST not set"
    exit 0
fi
[[ -d "${dist}/usr" ]] || { echo "paths-test: ${dist} has no usr tree, run just dist first" >&2; exit 1; }
[[ -d "${other}/usr" ]] || { echo "paths-test: ${other} has no usr tree" >&2; exit 1; }

list() { (cd "$1" && find . \( -type f -o -type l \) | sed 's#^\.##' | sort -u); }

shared=$(comm -12 <(list "${dist}") <(list "${other}"))
if [[ -n "${shared}" ]]; then
    echo "paths-test: $(grep -c . <<<"${shared}") path(s) in both ${dist} and ${other}:" >&2
    printf '%s\n' "${shared}" >&2
    exit 1
fi
echo "paths-test: ok, no path shared with ${other}"
