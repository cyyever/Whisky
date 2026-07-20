#!/bin/bash
set -e

# Build DXVK's d3d9.dll (32- and 64-bit PE, cross-compiled with mingw-w64) and
# install the payload into the Whisky Libraries folder. Whisky auto-copies the
# matching d3d9.dll into Steam game dirs whose executables import d3d9.dll
# (see WhiskyKit's Steam.installDXVKForD3D9Games).
#
# Only d3d9 is built: D3D11/D3D10/DXGI are served by DXMT, and upstream DXVK's
# d3d11 path cannot initialize on Apple GPUs (needs Vulkan geometryShader).
#
# Requires: ARM brew mingw-w64 + meson + ninja. The ~/.local/bin meson has a
# broken interpreter — keep it off PATH.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DXVK_SRC="$PROJECT_DIR/vendor/dxvk"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"

export PATH="/opt/homebrew/bin:/usr/bin:/bin"

for t in meson ninja i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "ERROR: $t not found (brew install meson ninja mingw-w64)" >&2
        exit 1
    }
done

echo "=== Building DXVK d3d9 from $DXVK_SRC ==="

# Apply out-of-tree DXVK patches (MoltenVK adaptations), kept as files so the
# submodule stays clean. Idempotent: skip a patch that is already applied,
# fail loudly on conflicts. Same pattern as build-wine-x86.sh.
PATCH_DIR="$PROJECT_DIR/patches/dxvk"
if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$DXVK_SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
            echo "=== Patch already applied: $(basename "$patch") ==="
        elif git -C "$DXVK_SRC" apply --check "$patch" >/dev/null 2>&1; then
            echo "=== Applying DXVK patch: $(basename "$patch") ==="
            git -C "$DXVK_SRC" apply "$patch"
        else
            echo "ERROR: cannot apply $(basename "$patch") (conflict or partial apply)"
            exit 1
        fi
    done
fi

# d3d9-only build; everything else is off (DXMT owns D3D11/D3D10/DXGI).
MESON_OPTS=(
    -Denable_d3d9=true
    -Denable_d3d8=false
    -Denable_d3d10=false
    -Denable_d3d11=false
    -Denable_dxgi=false
    --buildtype release
    --strip
)

setup_arch() {  # <cross-file> <build-dir> <install-subdir>
    local cross_file="$1" build_dir="$2" subdir="$3"
    # Incremental: reuse an existing build dir, set up otherwise. Kept
    # sequential — concurrent meson setups race on the shared subprojects cache.
    if [ ! -d "$DXVK_SRC/$build_dir" ]; then
        echo "=== Configuring DXVK ($subdir) ==="
        (cd "$DXVK_SRC" && meson setup --cross-file "$cross_file" "${MESON_OPTS[@]}" "$build_dir")
    fi
}

build_arch() {  # <build-dir> <install-subdir>
    local build_dir="$1" subdir="$2"
    echo "=== Building DXVK ($subdir) ==="
    ninja -C "$DXVK_SRC/$build_dir" src/d3d9/d3d9.dll
    echo "=== Installing d3d9.dll ($subdir) ==="
    mkdir -p "$INSTALL_DIR/DXVK/$subdir"
    cp "$DXVK_SRC/$build_dir/src/d3d9/d3d9.dll" "$INSTALL_DIR/DXVK/$subdir/d3d9.dll"
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

# The KosmicKrisp Vulkan loader swap lives in build-wine-x86.sh (it owns
# Wine/lib and re-copies it on every build, so a swap here would be clobbered
# by the next `make wine`). Run `make wine` after building the KosmicKrisp
# driver to (re-)assert it.

echo "=== Done! ==="
file "$INSTALL_DIR/DXVK/win32/d3d9.dll" "$INSTALL_DIR/DXVK/win64/d3d9.dll"
