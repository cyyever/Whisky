#!/bin/bash
set -e

# Build DXVK -- d3d9, d3d8, d3d11, d3d10core and dxgi, 32- and 64-bit PE,
# cross-compiled with mingw-w64 -- and install them as the Wine *builtin* DLLs,
# overwriting wined3d's (broken for D3D9 on macOS, and capped at feature level 9_3
# for D3D11 on its GL 2.1). proton-wine patch 0017 then defaults all of them to
# builtin in the load order, so no bottle needs a WINEDLLOVERRIDES. DXVK renders
# through winevulkan on KosmicKrisp.
#
# d3d8 is a thin wrapper over DXVK's d3d9 (it calls Direct3DCreate9 from d3d9.dll),
# and d3d10core over its d3d11, so each ships with the DLL it wraps.
# Transform feedback (stream output) comes from patches/mesa/0004, a backport of
# mesa!44928; drop that patch once the MR lands upstream.
# Must run AFTER `make proton`, which rebuilds Wine/lib; build-proton-x86.sh
# restores these builtins from the build trees, so the order only matters on the
# first build.
#
# Requires: ARM brew mingw-w64 + meson + ninja. The ~/.local/bin meson has a
# broken interpreter — keep it off PATH.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0 for the meson build
DXVK_SRC="$PROJECT_DIR/vendor/dxvk"

export PATH="/opt/homebrew/bin:/usr/bin:/bin"

require_tools meson ninja i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc

echo "=== Building DXVK from $DXVK_SRC ==="

# Apply out-of-tree DXVK patches (KosmicKrisp adaptations), tracked in the
# parent repository. Applying them makes the submodule worktree dirty. Idempotent: skip a patch that is already applied,
# fail loudly on conflicts.
apply_patches "$DXVK_SRC" "$PROJECT_DIR/patches/dxvk" DXVK

MESON_OPTS=(
    -Denable_d3d9=true
    -Denable_d3d8=true
    -Denable_d3d10=true
    -Denable_d3d11=true
    -Denable_dxgi=true
)

# <build-tree path>, relative to src/ -- the DLLs this script installs, and the
# ones build-proton-x86.sh restores after every Wine install (it keeps its own
# copy of this list; keep the two in step).
DXVK_DLLS=(d3d9/d3d9.dll d3d8/d3d8.dll d3d11/d3d11.dll d3d10/d3d10core.dll dxgi/dxgi.dll)

# WHISKY_DXVK_DEBUG=1 keeps symbols. A stripped release build is the right
# default, but it is also why a crash inside DXVK reads as a bare address: the
# dxvk-shader-n thread faulting at 0x0 symbolised as `__wine_reserve + 2063996129`,
# which names nothing. Same optimisation level, so the timing that produced the
# crash is not what changes.
if [ "${WHISKY_DXVK_DEBUG:-0}" = 1 ]; then
    MESON_OPTS+=( --buildtype debugoptimized )
    echo "=== DXVK: keeping symbols (WHISKY_DXVK_DEBUG=1) ==="
else
    MESON_OPTS+=( --buildtype release --strip )
fi

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

# Install DXVK as the Wine *builtin* DLLs (overwriting wined3d's). `patches/proton-wine`
# 0017 defaults them to builtin in the load order, so no bottle needs a
# WINEDLLOVERRIDES. win64 -> x86_64-windows, win32 -> i386-windows.
WINE_LIB="$INSTALL_DIR/Wine/lib/wine"
[ -d "$WINE_LIB/x86_64-windows" ] || {
    echo "ERROR: Wine not installed at $WINE_LIB. Run 'make proton' first." >&2; exit 1; }

build_arch() {  # <build-dir> <wine-arch-dir>
    local build_dir="$1" wine_arch="$2"
    echo "=== Building DXVK ($wine_arch) ==="
    local dll
    ninja -C "$DXVK_SRC/$build_dir" "${DXVK_DLLS[@]/#/src/}"
    echo "=== Installing DXVK as Wine builtins ($wine_arch) ==="
    for dll in "${DXVK_DLLS[@]}"; do
        cp "$DXVK_SRC/$build_dir/src/$dll" "$WINE_LIB/$wine_arch/${dll##*/}"
        mark_wine_builtin "$WINE_LIB/$wine_arch/${dll##*/}"
    done
}

# DXMT's Metal interface, left behind by an install from before D3D11 moved to
# DXVK. Nothing loads it any more; remove it so a bottle does not pick it up.
rm -f "$WINE_LIB/x86_64-windows/winemetal.dll" "$WINE_LIB/i386-windows/winemetal.dll" \
      "$WINE_LIB/x86_64-unix/winemetal.so"

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
for dll in "${DXVK_DLLS[@]}"; do
    file "$WINE_LIB/i386-windows/${dll##*/}" "$WINE_LIB/x86_64-windows/${dll##*/}"
done
