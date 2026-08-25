#!/bin/bash
set -e

# Build vkd3d-proton's d3d12.dll + d3d12core.dll (64-bit PE, cross-compiled with
# mingw-w64) and install them as the Wine *builtin* d3d12, the same lifecycle as
# DXVK's d3d9 and DXMT's d3d11.
#
# 64-bit only: no D3D12 title ships a 32-bit build, and vkd3d-proton does not
# support one.
#
# Must run AFTER `make proton`, which rebuilds Wine/lib and would otherwise
# clobber these builtins -- the same ordering `make dxvk` and `make dxmt` need.
#
# STATUS. Device creation, compute and basic graphics have all been measured
# working on KosmicKrisp under Rosetta with patches/vkd3d-proton applied: a DXBC
# cs_5_0 dispatch reads back correct results, and a fullscreen triangle renders
# correct green (tests/d3d12/). What has NOT been tried is real-game complexity
# -- MRT, depth/stencil, geometry shaders and transform feedback (which Metal
# lacks), tessellation, bindless.
#
# The "VK_EXT_dynamic_rendering_unused_attachments not supported" warning vkd3d
# prints is a red herring, and cost a long bisection once: an earlier black
# triangle was the probe's own bug (its PSO left RenderTargetWriteMask at 0,
# masking all colour output on any D3D12 driver), not a driver gap.
#
# Requires: ARM brew mingw-w64 + meson + ninja.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard
VKD3D_SRC="$PROJECT_DIR/vendor/vkd3d-proton"

export PATH="/opt/homebrew/bin:/usr/bin:/bin"

require_tools meson ninja x86_64-w64-mingw32-gcc

echo "=== Building vkd3d-proton from $VKD3D_SRC ==="

apply_patches "$VKD3D_SRC" "$PROJECT_DIR/patches/vkd3d-proton" vkd3d-proton

MESON_OPTS=(
    --buildtype release
    --strip
)

BUILD_DIR=build.w64
if [ ! -f "$VKD3D_SRC/$BUILD_DIR/build.ninja" ]; then
    (cd "$VKD3D_SRC" && meson setup --cross-file build-win64.txt "${MESON_OPTS[@]}" "$BUILD_DIR")
else
    # --reconfigure, not a fresh setup: a stale build dir otherwise keeps the old
    # options and fails on a now-missing ninja target.
    (cd "$VKD3D_SRC" && meson setup --reconfigure --cross-file build-win64.txt "${MESON_OPTS[@]}" "$BUILD_DIR")
fi

ninja -C "$VKD3D_SRC/$BUILD_DIR"

WINE_LIB="$INSTALL_DIR/Wine/lib/wine"
[ -d "$WINE_LIB" ] ||
    { echo "ERROR: Wine not installed at $WINE_LIB. Run 'make proton' first." >&2; exit 1; }

for dll in d3d12 d3d12core; do
    src="$VKD3D_SRC/$BUILD_DIR/libs/$dll/$dll.dll"
    [ -f "$src" ] || { echo "ERROR: $src not built" >&2; exit 1; }
    cp "$src" "$WINE_LIB/x86_64-windows/$dll.dll"
    # The DOS-stub "Wine builtin DLL" signature, same as build-dxvk.sh's
    # mark_wine_builtin: without it a fresh bottle fails STATUS_DLL_NOT_FOUND
    # before the load order is ever consulted.
    mark_wine_builtin "$WINE_LIB/x86_64-windows/$dll.dll"
    echo "  installed $dll.dll"
done

echo "=== vkd3d-proton installed ==="
echo "Device creation, compute and a basic triangle are verified on KosmicKrisp;"
echo "real-game features (MRT, depth/stencil, geometry shaders, tessellation,"
echo "bindless) are not."
