#!/usr/bin/env bash
#
# strip-cull-test — does KosmicKrisp assemble and cull a quad correctly?
#
#   tests/vulkan/strip-cull-test.sh
#
# WHY. SSFIV renders 2D fullscreen draws (loading screens, video) with one of
# the quad's two triangles missing -- a clean diagonal, lower-right half only
# -- and the in-match 3D scene black. A native Vulkan repro (no Wine, no D3D)
# probing that shape directly:
#
#   - strip winding compensation before the cull test    -> correct (negative)
#   - uint16 index buffers at non-4-aligned byte offsets -> correct (negative)
#
# Both negatives are the point: they exonerate the driver's core draw path and
# push the artifact's origin up into DXVK<->KK state translation (vertex
# fetch, pretransformed-vertex shaders) -- and they pin these classes down as
# a regression guard for future KosmicKrisp bumps.
#
# Exit code is the number of failed checks.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VKH="$PROJECT_DIR/vendor/homebrew-x86/opt/vulkan-headers/include"
VKL="$PROJECT_DIR/vendor/homebrew-x86/opt/vulkan-loader/lib"
ICD="$PROJECT_DIR/vendor/kosmickrisp/kosmickrisp_icd.x86_64.json"
SRC="$PROJECT_DIR/tests/vulkan/vk-strip-cull-test.c"
EXE="$PROJECT_DIR/tests/vulkan/vk-strip-cull-test"

[ -d "$VKH" ] || { echo "SKIP: no x86 vulkan-headers (scripts/setup-x86-brew.sh)"; exit 0; }
[ -f "$ICD" ] || { echo "SKIP: no KosmicKrisp ICD (scripts/build-kosmickrisp-x86.sh)"; exit 0; }
command -v glslangValidator >/dev/null || { echo "SKIP: glslangValidator not found (brew install glslang)"; exit 0; }

# Regenerate every shader header (quad.vert -> quad_vert.h, quad_attr.vert ->
# quad_attr_vert.h, ...). Iterating the glob rather than a hardcoded quad.*
# list: a shader outside the list silently compiles against its stale header.
for shader in "$PROJECT_DIR"/tests/vulkan/*.vert "$PROJECT_DIR"/tests/vulkan/*.frag; do
    [ -e "$shader" ] || continue
    name="$(basename "$shader")"
    stem="${name%.*}"; ext="${name##*.}"
    hdr="$PROJECT_DIR/tests/vulkan/${stem}_${ext}.h"
    if [ "$shader" -nt "$hdr" ]; then
        glslangValidator -V --vn "${stem}_${ext}_spv" -o "$hdr" \
            "$shader" >/dev/null || exit 1
    fi
done
needs_build=0
[ ! -x "$EXE" ] && needs_build=1
[ "$SRC" -nt "$EXE" ] && needs_build=1
for hdr in "$PROJECT_DIR"/tests/vulkan/quad*.h; do
    [ -e "$hdr" ] && [ "$hdr" -nt "$EXE" ] && needs_build=1
done
if [ "$needs_build" = 1 ]; then
    clang -arch x86_64 -O1 -I"$VKH" -I"$PROJECT_DIR/tests/vulkan" -o "$EXE" "$SRC" \
        -L"$VKL" -lvulkan -Wl,-rpath,"$VKL" || exit 1
fi

VK_DRIVER_FILES="$ICD" arch -x86_64 "$EXE"
