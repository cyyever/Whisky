#!/bin/bash
set -e

# Build Mesa's KosmicKrisp Vulkan driver (Vulkan-on-Metal) as x86_64, for use
# under Rosetta. Two-phase build so no x86_64 LLVM toolchain is needed:
#   1) arm64 native build of the build-time tools (mesa_clc, vtn_bindgen2),
#      using the ARM brew llvm/libclc/spirv-llvm-translator/spirv-tools.
#   2) x86_64 cross build of the driver with -Dmesa-clc=system, pointing PATH
#      at the phase-1 tools. A meson cross file is required: plain
#      CC="clang -arch x86_64" leaves host cpu_family=aarch64 and blake3
#      selects NEON sources. needs_exe_wrapper=false — Rosetta runs the
#      in-tree x86_64 tools (kk_clc) directly during the build.
# Output: vendor/kosmickrisp/libvulkan_kosmickrisp.dylib + ICD json.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MESA_SRC="$PROJECT_DIR/vendor/mesa"
OUT_DIR="$PROJECT_DIR/vendor/kosmickrisp"
X86_PREFIX="$PROJECT_DIR/vendor/homebrew-x86"
ARM_BREW_PREFIX="$(brew --prefix)"

# ARM brew meson/ninja (~/.local/bin has a meson with a broken interpreter — keep it
# off PATH). llvm is keg-only; phase 1 (mesa_clc) needs its llvm-config.
export PATH="$ARM_BREW_PREFIX/opt/llvm/bin:$ARM_BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Apply out-of-tree Mesa patches (same idempotent pattern as build-wine-x86.sh).
# 0001 = Mesa MR 42811 (present-queue residencySet) — without it every frame
# presents black under Metal 4; drop once merged upstream.
PATCH_DIR="$PROJECT_DIR/patches/mesa"
if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$MESA_SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
            echo "=== Mesa patch already applied: $(basename "$patch") ==="
        elif git -C "$MESA_SRC" apply --check "$patch" >/dev/null 2>&1; then
            echo "=== Applying Mesa patch: $(basename "$patch") ==="
            git -C "$MESA_SRC" apply "$patch"
        else
            echo "ERROR: cannot apply $(basename "$patch")"
            exit 1
        fi
    done
fi

TOOLS_BUILD="$MESA_SRC/build-arm64-tools"
TOOLS_BIN="$TOOLS_BUILD/staged-bin"
if [ ! -x "$TOOLS_BIN/mesa_clc" ]; then
    echo "=== Phase 1: arm64 mesa_clc / vtn_bindgen2 ==="
    meson setup "$TOOLS_BUILD" "$MESA_SRC" -Dbuildtype=release -Dplatforms=macos \
        -Dvulkan-drivers= -Dgallium-drivers= -Dopengl=false \
        -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dzstd=disabled
    ninja -C "$TOOLS_BUILD" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2
    mkdir -p "$TOOLS_BIN"
    cp "$TOOLS_BUILD/src/compiler/clc/mesa_clc" \
       "$TOOLS_BUILD/src/compiler/spirv/vtn_bindgen2" "$TOOLS_BIN/"
fi

DRIVER_BUILD="$MESA_SRC/build-x86_64"
CROSS_FILE="$MESA_SRC/x86_64-darwin-cross.ini"
cat > "$CROSS_FILE" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = '$ARM_BREW_PREFIX/bin/pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = false
EOF

echo "=== Phase 2: x86_64 KosmicKrisp driver ==="
export PATH="$TOOLS_BIN:$PATH"
export PKG_CONFIG_PATH="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig"
if [ ! -d "$DRIVER_BUILD" ]; then
    meson setup "$DRIVER_BUILD" "$MESA_SRC" --cross-file "$CROSS_FILE" \
        -Dbuildtype=release -Dplatforms=macos \
        -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false \
        -Dmesa-clc=system -Dzstd=disabled
fi
ninja -C "$DRIVER_BUILD"

echo "=== Installing to $OUT_DIR ==="
mkdir -p "$OUT_DIR"
DYLIB="$DRIVER_BUILD/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
cp "$DYLIB" "$OUT_DIR/"
API_VERSION=$(/opt/homebrew/bin/python3 -c "import json,glob; print(json.load(open(glob.glob('$DRIVER_BUILD/src/kosmickrisp/vulkan/*_icd.*.json')[0]))['ICD']['api_version'])")
cat > "$OUT_DIR/kosmickrisp_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "$API_VERSION",
        "library_path": "$OUT_DIR/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.0"
}
EOF

echo "=== Done ==="
file "$OUT_DIR/libvulkan_kosmickrisp.dylib"
echo "MTL4 symbol references: $(strings "$OUT_DIR/libvulkan_kosmickrisp.dylib" | grep -c MTL4 || true)"
echo "Test: VK_DRIVER_FILES=$OUT_DIR/kosmickrisp_icd.x86_64.json arch -x86_64 $X86_PREFIX/opt/vulkan-tools/bin/vulkaninfo --summary"
