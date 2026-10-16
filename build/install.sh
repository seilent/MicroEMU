#!/usr/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?usage: install.sh <destdir>}
cache="${MICROEMU_CACHE:-${repo}/build/cache}"
version="${MICROEMU_VERSION:-unknown}"

mkdir -p "${dest}" "${cache}"
dest=$(cd "${dest}" && pwd)
share="${dest}/usr/share/microemu"
cp -a --no-preserve=ownership "${repo}/data/." "${dest}/"
find "${dest}" \( -name __pycache__ -o -name '*.pyc' \) -prune -exec rm -rf {} +

shaders=$(bash "${repo}/build/shaders.sh" "${cache}/shaders" "${dest}" "${repo}/build/shaders-audit")
theme=$(bash "${repo}/build/theme.sh" "${cache}/theme" "${dest}")
osd=$(bash "${repo}/build/osd.sh" "${cache}/osd" "${dest}")

mkdir -p "${share}"
find "${dest}" -mindepth 1 -type d -exec chmod 0755 {} +
echo "${version}" > "${share}/version"
{
    echo "MICROEMU_VERSION=${version}"
    echo "${shaders}"
    echo "${theme}"
    echo "${osd}"
} > "${share}/build-manifest"
