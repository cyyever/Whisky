#!/bin/bash
set -e

# Build DXVK's d3d9.dll + d3d8.dll (32- and 64-bit PE, cross-compiled with
# mingw-w64) and install them as the Wine *builtin* d3d9/d3d8, overwriting
# wined3d's (broken for D3D9 on macOS) — the same layer DXMT uses for d3d11.
# proton-wine patch 0017 then defaults d3d9/d3d8 to builtin in the load order, so
# no bottle needs a WINEDLLOVERRIDES.
#
# d3d8 is a thin wrapper over DXVK's d3d9 (it calls Direct3DCreate9 from d3d9.dll),
# so it ships alongside d3d9. D3D11/D3D10/DXGI are NOT built here: DXMT owns them on
# macOS (upstream DXVK's d3d11 needs Vulkan geometryShader, absent on Apple GPUs).
# Must run AFTER `make proton`, which rebuilds Wine/lib and would otherwise clobber
# these builtins — same lifecycle as `make dxmt`.
#
# Requires: ARM brew mingw-w64 + meson + ninja. The ~/.local/bin meson has a
# broken interpreter — keep it off PATH.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0 for the meson build
DXVK_SRC="$PROJECT_DIR/vendor/dxvk"

export PATH="/opt/homebrew/bin:/usr/bin:/bin"

require_tools meson ninja i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc

echo "=== Building DXVK d3d9 from $DXVK_SRC ==="

# Apply out-of-tree DXVK patches (MoltenVK adaptations), kept as files so the
# submodule stays clean. Idempotent: skip a patch that is already applied,
# fail loudly on conflicts.
apply_patches "$DXVK_SRC" "$PROJECT_DIR/patches/dxvk" DXVK

# d3d9 + d3d8 (its wrapper); everything else is off (DXMT owns D3D11/D3D10/DXGI).
MESON_OPTS=(
    -Denable_d3d9=true
    -Denable_d3d8=true
    -Denable_d3d10=false
    -Denable_d3d11=false
    -Denable_dxgi=false
    --buildtype release
    --strip
)

setup_arch() {  # <cross-file> <build-dir> <install-subdir>
    local cross_file="$1" build_dir="$2" subdir="$3"
    # Fresh dir → configure; existing dir → --reconfigure so option changes
    # (e.g. flipping enable_d3d8 on) actually take, instead of silently reusing
    # the old options and failing on a now-missing ninja target. Both are
    # incremental (object files are kept). Kept sequential — concurrent meson
    # setups race on the shared subprojects cache.
    if [ ! -d "$DXVK_SRC/$build_dir" ]; then
        echo "=== Configuring DXVK ($subdir) ==="
        (cd "$DXVK_SRC" && meson setup --cross-file "$cross_file" "${MESON_OPTS[@]}" "$build_dir")
    else
        echo "=== Reconfiguring DXVK ($subdir) ==="
        (cd "$DXVK_SRC" && meson setup --reconfigure --cross-file "$cross_file" "${MESON_OPTS[@]}" "$build_dir")
    fi
}

# Install DXVK as the Wine *builtin* d3d9/d3d8 (overwriting wined3d's, which is
# broken for D3D9 on macOS) — the same layer DXMT uses for d3d11. `patches/proton-wine`
# 0017 then defaults d3d9/d3d8 to builtin in the load order, so no bottle needs a
# WINEDLLOVERRIDES. win64 -> x86_64-windows, win32 -> i386-windows.
WINE_LIB="$INSTALL_DIR/Wine/lib/wine"
[ -d "$WINE_LIB/x86_64-windows" ] || {
    echo "ERROR: Wine not installed at $WINE_LIB. Run 'make proton' first." >&2; exit 1; }

build_arch() {  # <build-dir> <wine-arch-dir>
    local build_dir="$1" wine_arch="$2"
    echo "=== Building DXVK ($wine_arch) ==="
    ninja -C "$DXVK_SRC/$build_dir" src/d3d9/d3d9.dll src/d3d8/d3d8.dll
    echo "=== Installing DXVK d3d9/d3d8 as Wine builtins ($wine_arch) ==="
    cp "$DXVK_SRC/$build_dir/src/d3d9/d3d9.dll" "$WINE_LIB/$wine_arch/d3d9.dll"
    cp "$DXVK_SRC/$build_dir/src/d3d8/d3d8.dll" "$WINE_LIB/$wine_arch/d3d8.dll"
    mark_wine_builtin "$WINE_LIB/$wine_arch/d3d9.dll"
    mark_wine_builtin "$WINE_LIB/$wine_arch/d3d8.dll"
}

setup_arch build-win32.txt build.w32 win32
setup_arch build-win64.txt build.w64 win64

# The two ninja builds use independent build dirs and only read the shared
# subprojects, so run them in parallel (wall-clock ~= the slower single arch).
build_arch build.w32 i386-windows &
pid_w32=$!
build_arch build.w64 x86_64-windows &
pid_w64=$!
build_failed=0
wait "$pid_w32" || build_failed=1
wait "$pid_w64" || build_failed=1
[ "$build_failed" -eq 0 ] || { echo "ERROR: a DXVK build failed" >&2; exit 1; }

# The KosmicKrisp Vulkan loader swap lives in build-proton-x86.sh (it owns
# Wine/lib and re-copies it on every build, so a swap here would be clobbered
# by the next `make proton`). Run `make proton` after building the KosmicKrisp
# driver to (re-)assert it.

echo "=== Done! ==="
file "$WINE_LIB/i386-windows/d3d9.dll" "$WINE_LIB/x86_64-windows/d3d9.dll" \
     "$WINE_LIB/i386-windows/d3d8.dll" "$WINE_LIB/x86_64-windows/d3d8.dll"
