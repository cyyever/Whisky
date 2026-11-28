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
VKH="$PROJECT_DIR/vendor/x86-deps/include"
VKL="$PROJECT_DIR/vendor/x86-deps/lib"
ICD="$PROJECT_DIR/vendor/kosmickrisp/kosmickrisp_icd.x86_64.json"
SRC="$PROJECT_DIR/tests/vulkan/vk-strip-cull-test.c"
EXE="$PROJECT_DIR/tests/vulkan/vk-strip-cull-test"

[ -f "$VKH/vulkan/vulkan.h" ] || { echo "SKIP: no x86 vulkan-headers (make x86-deps)"; exit 0; }
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
if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
    CC="/opt/homebrew/opt/llvm/bin/clang"
    SAN_FLAGS=(-g -fno-omit-frame-pointer -fsanitize=address,undefined,nullability,local-bounds,float-divide-by-zero)
else
    CC=clang
    SAN_FLAGS=(-g -fno-omit-frame-pointer -fsanitize=address,undefined)
fi

if [ "$needs_build" = 1 ]; then
    "$CC" -arch x86_64 -O1 "${SAN_FLAGS[@]}" -I"$VKH" -I"$PROJECT_DIR/tests/vulkan" -o "$EXE" "$SRC" \
        -L"$VKL" -lvulkan -Wl,-rpath,"$VKL" || exit 1
fi

VVL_DIR="$PROJECT_DIR/vendor/vulkan-validation"
VVL_ENV=()
if [ -f "$VVL_DIR/VkLayer_khronos_validation.json" ]; then
    VVL_ENV=(VK_LAYER_PATH="$VVL_DIR" VK_INSTANCE_LAYERS="VK_LAYER_KHRONOS_validation")
fi

# Note: MTL_SHADER_VALIDATION=1 (Metal GPU Validation) is omitted here because
# Apple's MetalTools MTL4GPUDebugCommandBuffer crashes with SEGV inside
# HeapUsageTable::updateHeapUsage on KosmicKrisp's Metal 4 backend.
ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1:halt_on_error=1" \
UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" \
METAL_DEVICE_WRAPPER_TYPE=1 \
MTL_DEBUG_LAYER=1 \
"${VVL_ENV[@]}" \
VK_DRIVER_FILES="$ICD" arch -x86_64 "$EXE"
