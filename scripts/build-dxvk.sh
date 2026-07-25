#!/bin/bash
set -e

# Build DXVK's d3d9.dll + d3d8.dll (32- and 64-bit PE, cross-compiled with
# mingw-w64) and install the payload into the Whisky Libraries folder. Whisky
# auto-copies the matching dll(s) into Steam game dirs whose executables import
# d3d9.dll / d3d8.dll (see WhiskyKit's Steam.installDXVKForGames).
#
# d3d8 is a thin wrapper over DXVK's d3d9 (it calls Direct3DCreate9 from
# d3d9.dll), so it ships alongside d3d9 and the auto-drop provides both to a
# D3D8 game. D3D11/D3D10/DXGI are still NOT built: DXMT owns them, and upstream
# DXVK's d3d11 path cannot initialize on Apple GPUs (needs Vulkan geometryShader).
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

build_arch() {  # <build-dir> <install-subdir>
    local build_dir="$1" subdir="$2"
    echo "=== Building DXVK ($subdir) ==="
    ninja -C "$DXVK_SRC/$build_dir" src/d3d9/d3d9.dll src/d3d8/d3d8.dll
    echo "=== Installing d3d9.dll + d3d8.dll ($subdir) ==="
    mkdir -p "$INSTALL_DIR/DXVK/$subdir"
    cp "$DXVK_SRC/$build_dir/src/d3d9/d3d9.dll" "$INSTALL_DIR/DXVK/$subdir/d3d9.dll"
    cp "$DXVK_SRC/$build_dir/src/d3d8/d3d8.dll" "$INSTALL_DIR/DXVK/$subdir/d3d8.dll"
}

setup_arch build-win32.txt build.w32 win32
setup_arch build-win64.txt build.w64 win64

# The two ninja builds use independent build dirs and only read the shared
# subprojects, so run them in parallel (wall-clock ~= the slower single arch).
build_arch build.w32 win32 &
pid_w32=$!
build_arch build.w64 win64 &
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
file "$INSTALL_DIR/DXVK/win32/d3d9.dll" "$INSTALL_DIR/DXVK/win64/d3d9.dll" \
     "$INSTALL_DIR/DXVK/win32/d3d8.dll" "$INSTALL_DIR/DXVK/win64/d3d8.dll"
