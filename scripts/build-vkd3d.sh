#!/bin/bash
set -e

MODE="${1:-}"
case "$MODE" in ""|--build-only|--install-only) ;; *)
    echo "Usage: $0 [--build-only|--install-only]" >&2; exit 2 ;;
esac

# Build vkd3d-proton's d3d12.dll + d3d12core.dll (64-bit PE, cross-compiled with
# mingw-w64) and install them as the Wine *builtin* d3d12, the same lifecycle as
# DXVK's d3d9/d3d11.
#
# Whisky currently packages the win64 pair only. D3D12 remains opt-in until
# real-game rendering is verified; tests/d3d12 checks the installed builtins.
# make vkd3d builds this pair first, rebuilds Wine if needed, then installs it.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/vkd3d.sh"
whisky_ccache_guard
VKD3D_SRC="$PROJECT_DIR/vendor/vkd3d-proton"

export PATH="/opt/homebrew/bin:/usr/bin:/bin"

require_tools git meson ninja x86_64-w64-mingw32-gcc python3 glslang

BUILD_DIR=build.w64

if [ "$MODE" != --install-only ]; then
    if [ ! -d "$VKD3D_SRC" ]; then
        git clone --no-checkout "$VKD3D_SOURCE_URL" "$VKD3D_SRC"
        git -C "$VKD3D_SRC" checkout --detach "$VKD3D_REVISION"
    fi
    [ "$(git -C "$VKD3D_SRC" rev-parse HEAD)" = "$VKD3D_REVISION" ] || {
        echo "ERROR: vkd3d-proton must be at $VKD3D_REVISION; preserve local changes before switching." >&2
        exit 1
    }
    git -C "$VKD3D_SRC" submodule update --init --recursive

    echo "=== Building vkd3d-proton from $VKD3D_SRC ==="

    apply_patches "$VKD3D_SRC" "$PROJECT_DIR/patches/vkd3d-proton" vkd3d-proton

    MESON_OPTS=(
        --buildtype release
        --strip
        -Denable_tests=false -Denable_extras=false -Denable_profiling=false
        -Denable_descriptor_qa=false
    )

    if [ ! -f "$VKD3D_SRC/$BUILD_DIR/build.ninja" ]; then
        (cd "$VKD3D_SRC" && meson setup --cross-file build-win64.txt "${MESON_OPTS[@]}" "$BUILD_DIR")
    else
        # --reconfigure, not a fresh setup: a stale build dir otherwise keeps the old
        # options and fails on a now-missing ninja target.
        (cd "$VKD3D_SRC" && meson setup --reconfigure --cross-file build-win64.txt "${MESON_OPTS[@]}" "$BUILD_DIR")
    fi

    ninja -C "$VKD3D_SRC/$BUILD_DIR"
fi
[ "$MODE" != --build-only ] || exit 0

WINE_LIB="$INSTALL_DIR/Wine/lib/wine"
[ -d "$WINE_LIB" ] ||
    { echo "ERROR: Wine not installed at $WINE_LIB. Run 'make proton' first." >&2; exit 1; }

install_vkd3d_builtins "$VKD3D_SRC/$BUILD_DIR/libs" "$WINE_LIB/x86_64-windows"

echo "=== vkd3d-proton installed ==="
echo "Run make test-d3d12 to verify the installed DLLs. Real games remain unverified."
