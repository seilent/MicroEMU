#!/usr/bin/bash
set -eu

cd "$(dirname "$0")/.."

. build/base.env

version="${MICROEMU_VERSION:-unknown}"
root="${MICROEMU_BUILDER_ROOT:-}"
dist=dist
share="${dist}/usr/share/microemu"

fail() { echo "build.sh: $*" >&2; exit 1; }

os_value() { sed -n "s/^$1=//p" "${root}/usr/lib/os-release" | tr -d '"'; }

ext_value() { sed -n "s/^$1=//p" sysext/usr/lib/extension-release.d/extension-release.microemu; }

[[ "$(os_value IMAGE_VERSION)" == "${IMAGE_VERSION}" ]] || fail "builder IMAGE_VERSION $(os_value IMAGE_VERSION) differs from base.env ${IMAGE_VERSION}"
[[ "$(os_value VERSION_ID)" == "${VERSION_ID}" ]] || fail "builder VERSION_ID $(os_value VERSION_ID) differs from base.env ${VERSION_ID}"
[[ "$(ext_value VERSION_ID)" == "${VERSION_ID}" ]] || fail "extension-release.microemu VERSION_ID $(ext_value VERSION_ID) differs from base.env ${VERSION_ID}"
[[ "$(ext_value ID)" == "$(os_value ID)" ]] || fail "extension-release.microemu ID $(ext_value ID) differs from the builder ID $(os_value ID)"

rm -rf "${dist}"
mkdir -p "${share}"
cp -a sysext/. "${dist}/"

esde=$(bash build/esde.sh build/cache/es-de "${dist}")
retroarch=$(bash build/retroarch.sh build/cache/retroarch "${dist}")
shaders=$(bash build/shaders.sh build/cache/shaders "${dist}" build/shaders-audit)

echo "${version}" > "${share}/version"
{
    echo "BASE_IMAGE=${BASE_IMAGE}"
    echo "IMAGE_VERSION=${IMAGE_VERSION}"
    echo "VERSION_ID=${VERSION_ID}"
    echo "MICROEMU_VERSION=${version}"
    echo "${esde}"
    echo "${retroarch}"
    echo "${shaders}"
    echo
    rpm -qa | sort
} > "${share}/build-manifest"

if [[ "${MICROEMU_IMAGE:-0}" == 1 ]]; then
    raw="microemu-${version}-armada${VERSION_ID}-arm64.raw"
    rm -f "${raw}"
    mksquashfs "${dist}" "${raw}" -comp zstd -noappend -all-root -quiet
    echo "${raw}"
fi
