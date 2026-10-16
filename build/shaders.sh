#!/usr/bin/bash
set -euo pipefail

SLANG_COMMIT=e1d75632a205c70f14a4cc947c46d5abb7b3f7f1
SLANG_URL="https://raw.githubusercontent.com/libretro/slang-shaders/${SLANG_COMMIT}"
RC_TAG=20260321
RC_COMMIT=b7e2e26e1aba2beec3c3e5751de2245e436898b7
RC_ZIP=Retro.Crisis.GDV-NTSC.2026.03.21.zip
RC_URL="https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC/releases/download/${RC_TAG}/${RC_ZIP}"
RC_SHA=99a844e24d244bcc30b5bd2657c97019fa8b27b8fde22047840921d4c69516b9
RC_LICENSE_URL="https://raw.githubusercontent.com/RetroCrisis/Retro-Crisis-GDV-NTSC/${RC_COMMIT}/LICENSE"
RC_LICENSE_SHA=3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986
PROTO="=https"

SLANG_FILES="
14c8506055d808c4978fbb7f54b06b5536160828318e98acc21433a63ac4dc8c crt/crt-guest-advanced-fast.slangp
90e16aa3ac1bc48129ef5fa7470345ddac9a1b81459d750de521157f97af17a5 crt/crt-guest-advanced-fastest.slangp
0f183cb4a751cc5f70459ff93b3cde2bd164c188bebb44c5b0bac9dfa6fa381d crt/shaders/guest/fast/bloom_horizontal.slang
7020fa020a431aaba71010a06652287dcb21050db364e5848043ef0f49f59a6f crt/shaders/guest/fast/bloom_vertical.slang
0f70a79027e5ef7afd22ee43345c20c190a2fdad0e7201c724614042d1e06052 crt/shaders/guest/fast/crt-guest-advanced-pass1.slang
ef8231448854bc3318c82c72bb05a6414162272c001e051b14690c0ec8721891 crt/shaders/guest/fast/crt-guest-advanced-pass1f.slang
15a906f8c691171ec3e2f7a90b56b1ee773101aa5bf95cf9582b60782ed4acc8 crt/shaders/guest/fast/crt-guest-advanced-pass2.slang
dbcc89592064dad6034c901aa5196f2b6b52b65643ca63a3b76e67a756438c2f crt/shaders/guest/fast/crt-guest-advanced-pass2f.slang
b9258dc319b5e7d9d5eefbff9d3abfe3309c20e9edceb6c16c4635e8428504a2 crt/shaders/guest/fast/deconvergence-f.slang
60a75029a075a51c6f6659ef8ddf343defda96ebfdcdf6f420e15925b0adcef2 crt/shaders/guest/fast/linearize.slang
90daca1f3d3e40e64a604c6bd02667a260dc1e9efce41642ec1c52af6f0aa5b9 crt/shaders/guest/fast/linearizef.slang
65b57363e76aed5ed680f6d140c5aaa2d9eea04d05d0215aeebaa24797b8abcf crt/shaders/guest/fast/perf-pass.slang
408815969bdb2dee37dc455fc2a597f99d2d28f9e73b1c2579867542b36c018d crt/shaders/guest/fast/pre-shaders.slang
5f801939ffe1bb07b095e056dde4808c9afffdb137003cac636109002d999d22 crt/shaders/guest/fast/pre-shadersf.slang
fa7d346e3706a351aa77dc8e77bd049b8bfde635baf4376fedcf81f38d9a4008 crt/shaders/guest/fast/stock.slang
7a53266418477402d00ae20848142fc5db795befc25e5870edcb03b28d0dbafd crt/shaders/guest/advanced/afterglow0.slang
30d27513e322a7c82654f7c70b2a7a34eaeff554761e40cba7756b8f4068cbb4 crt/shaders/guest/advanced/avg-lum-ntsc.slang
a5ab3547d19990144bf3e0e80abcc7dc8a541cb1ca80ec44a9464c3307cb7972 crt/shaders/guest/advanced/bloom_horizontal.slang
e7992b156937ce826572ae72e7e379d4e548b1de8315d82c4de625ba5f9e8b6b crt/shaders/guest/advanced/bloom_vertical.slang
d499fad2c65b03c36a3057e1efc8e74d9d9aa67edf72ca23ac18c992453cee64 crt/shaders/guest/advanced/crt-guest-advanced-ntsc-pass1.slang
b094a856579913a5207dba2a4d449ba764d523bb58fd3c8c6e5be5a6fc35ccf8 crt/shaders/guest/advanced/crt-guest-advanced-ntsc-pass2.slang
ef91e3d4f564a8fe4f097aaaec46c0611867ba2e122b180c9355c8a9a41810b8 crt/shaders/guest/advanced/custom-fast-sharpen.slang
93326a53f688c31f01d740f50bd5de0efabb96e952edb27631c7d86e826c9ef0 crt/shaders/guest/advanced/deconvergence-ntsc.slang
31c3999ac5b0f6dd784039a22ab3da3c56cd2141eeaedf7b3821c831556e9e53 crt/shaders/guest/advanced/gaussian_horizontal.slang
869e6d0eb1b630ab8e5b3ff9868df3cf9a7a6ba33d768dcc9ecc0ea93b36b359 crt/shaders/guest/advanced/gaussian_vertical.slang
25708f1e8067dabe30c72823689568123698ac0674c6e1aad5278bb521391174 crt/shaders/guest/advanced/linearize-ntsc.slang
2acb6633e4dede7f36e3e62b7aa9d0ed76ecfbc5cb7ed7f3f8813dddec0e9145 crt/shaders/guest/advanced/lut/inv-trinitron-lut.png
86ec3d2e21138845cb73500e915425582b991e173a4149fa192a62d798382b59 crt/shaders/guest/advanced/lut/nec-lut.png
a23ae9d27d6d5f9073d4a84678187f54758b329387c47686294ea979dcde6d03 crt/shaders/guest/advanced/lut/ntsc-lut.png
bcc8c237eb39ed2a632554959cb4c5e0dd52b59a4922745b46b7525fc6b6b61a crt/shaders/guest/advanced/lut/trinitron-lut.png
31788bb4b9929e66ed656ff4b32bb419dec744263f4f4ac7c989ca300481fbc3 crt/shaders/guest/advanced/ntsc/ntsc-pass1.slang
572cb5da08482742ba849b04f65f2ce4bbde8bba495213e7c2e9069582ba2aaa crt/shaders/guest/advanced/ntsc/ntsc-pass2.slang
1b8f9c6bd9738355498155e49be6491ff7b6ab7e436994974bbdeea4163d9a6b crt/shaders/guest/advanced/ntsc/ntsc-pass3.slang
1c4e57ff95acc881d761d95196fce8e3000701750868187907c4cffad5c6d4b7 crt/shaders/guest/advanced/pre-shaders-afterglow.slang
fa7d346e3706a351aa77dc8e77bd049b8bfde635baf4376fedcf81f38d9a4008 crt/shaders/guest/advanced/stock.slang
bf4dd78713f870c4ee485d935a90676b6093e7c5243ed4f47669e3b6b62b85ef reshade/shaders/LUT/64.png
a6bd9e7e93aa6df93edfc1007b4b9ff1bb9bc98430e6c7beb2a3c1558f10b6b1 reshade/shaders/LUT/multiLUT.slang
"
RC_FILES="
091000e3ffb3731d98742d913665df8ab60ce9e05902346786419fe38ba6afa7 retro crisis/1080p Flat/RC GDV-NTSC - NES - Clean.slangp
7bc92784cf78ef1928e8b13294bf073101f0721e394899e8fa72ada2e7684c88 retro crisis/1080p Flat/RC GDV-NTSC - SNES - Clean.slangp
b8d95307ec221919b5e51834b6b0b8cf291888044ef47fb3b5059e40fa8c3f89 retro crisis/4K Flat/RC GDV-NTSC - NES - Clean.slangp
cda007aa1676168c0d194aa01deaa0bcf2397ec061d9bf5f77c580951b36fcb3 retro crisis/4K Flat/RC GDV-NTSC - SNES - Clean.slangp
"

if [[ "${MICROEMU_TEST:-}" == 1 ]]; then
    SLANG_URL="${MICROEMU_SLANG_URL:-${SLANG_URL}}"
    SLANG_FILES="${MICROEMU_SLANG_FILES:-${SLANG_FILES}}"
    RC_URL="${MICROEMU_RC_URL:-${RC_URL}}"
    RC_SHA="${MICROEMU_RC_SHA:-${RC_SHA}}"
    RC_FILES="${MICROEMU_RC_FILES:-${RC_FILES}}"
    RC_LICENSE_URL="${MICROEMU_RC_LICENSE_URL:-${RC_LICENSE_URL}}"
    RC_LICENSE_SHA="${MICROEMU_RC_LICENSE_SHA:-${RC_LICENSE_SHA}}"
    PROTO="=https,file"
fi

cache=$1
dist=$2
audit=$3
dest="${dist}/usr/share/microemu/retroarch/shaders/shaders_slang"
licenses="${dist}/usr/share/licenses/microemu"

fail() { echo "shaders.sh: $*" >&2; exit 1; }

fetch() {
    local url=$1 sha=$2 file=$3
    if echo "${sha}  ${file}" | sha256sum -c --status 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "${file}")"
    curl --proto "${PROTO}" --proto-redir =https -fsSL --retry 3 --connect-timeout 30 -o "${file}.part" "${url}" \
        || { rm -f "${file}.part"; fail "download failed: ${url}"; }
    echo "${sha}  ${file}.part" | sha256sum -c --status || { rm -f "${file}.part"; fail "sha256 mismatch: ${url}"; }
    mv "${file}.part" "${file}"
}

[[ -f "${audit}" ]] || fail "${audit} missing"
rm -rf "${dest}"
mkdir -p "${dest}" "${licenses}/slang-shaders" "${licenses}/retro-crisis"

while read -r sha path; do
    [[ -n "${path}" ]] || continue
    grep -qF " ${path} " "${audit}" || fail "${path} is not in ${audit}"
    fetch "${SLANG_URL}/${path}" "${sha}" "${cache}/slang-shaders/${SLANG_COMMIT}/${path}"
    install -D -m 0644 "${cache}/slang-shaders/${SLANG_COMMIT}/${path}" "${dest}/${path}"
done <<< "${SLANG_FILES}"

fetch "${RC_URL}" "${RC_SHA}" "${cache}/${RC_ZIP}"
while read -r sha path; do
    [[ -n "${path}" ]] || continue
    mkdir -p "$(dirname "${dest}/${path}")"
    unzip -p "${cache}/${RC_ZIP}" "shaders/shaders_slang/${path}" > "${dest}/${path}" 2>/dev/null || fail "${path} missing in ${RC_ZIP}"
    [[ "$(sha256sum "${dest}/${path}" | cut -d' ' -f1)" == "${sha}" ]] || fail "${path} from ${RC_ZIP}: sha256 mismatch"
    chmod 0644 "${dest}/${path}"
done <<< "${RC_FILES}"
fetch "${RC_LICENSE_URL}" "${RC_LICENSE_SHA}" "${cache}/retro-crisis-LICENSE"

python3 - "${dist}/usr/share/microemu/retroarch/shaders" <<'PY' || fail "a shipped preset or shader references a missing file"
import os
import re
import sys

root = sys.argv[1]
missing = []
for directory, _, files in os.walk(root):
    for name in files:
        path = os.path.join(directory, name)
        if not name.endswith((".slangp", ".slang")):
            continue
        text = open(path, errors="replace").read()
        refs = []
        if name.endswith(".slangp"):
            refs += re.findall(r'^\s*#reference\s+"([^"]+)"', text, re.M)
            values = dict((k, v.strip().strip('"')) for k, v in re.findall(r'^\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$', text, re.M))
            refs += [v for k, v in values.items() if re.match(r"shader\d+$", k)]
            for texture in values.get("textures", "").split(";"):
                if texture.strip() in values:
                    refs.append(values[texture.strip()])
        else:
            refs += re.findall(r'^\s*#include\s+"([^"]+)"', text, re.M)
        for ref in refs:
            if not os.path.isfile(os.path.normpath(os.path.join(directory, ref))):
                missing.append(f"{os.path.relpath(path, root)}: {ref}")
if missing:
    sys.exit("missing shader references:\n" + "\n".join(missing))
PY

install -m 0644 "${audit}" "${licenses}/slang-shaders/AUDIT"
{
    echo "Retro Crisis GDV-NTSC ${RC_TAG}, https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC at ${RC_COMMIT}"
    echo
    cat "${cache}/retro-crisis-LICENSE"
} > "${licenses}/retro-crisis/LICENSE"

echo "SLANG_SHADERS_COMMIT=${SLANG_COMMIT}"
echo "RETRO_CRISIS_SHA256=${RC_SHA}"
echo "SHADER_FILES=$(find "${dist}/usr/share/microemu/retroarch/shaders" -type f | wc -l)"
