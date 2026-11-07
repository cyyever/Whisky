#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$PROJECT_DIR/scripts/lib/mullion.sh"
check_mullion_source
require_tools meson ninja x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++

LLVM_PREFIX=$(mullion_llvm_prefix)
WINE_BUILD="$PROJECT_DIR/vendor/proton-wine/build"
WINE_LIB="$INSTALL_DIR/Wine/lib/wine"
[ -d "$WINE_BUILD/dlls/ntdll/x86_64-windows" ] || {
    echo "ERROR: Proton's x86_64 build tree is missing at $WINE_BUILD; run 'make proton' first." >&2
    exit 1
}
[ -d "$WINE_LIB/x86_64-windows" ] || {
    echo "ERROR: Wine is not installed at $WINE_LIB; run 'make proton' first." >&2
    exit 1
}

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
MESON_OPTIONS=(
    --cross-file "$MULLION_DIR/build-win64.txt"
    --prefix "$MULLION_STAGE"
    --buildtype release
    -Dnative_llvm_path="$LLVM_PREFIX"
    -Dwine_build_path="$WINE_BUILD"
    -Dwine_builtin_dll=true
    -Dbuild_airconv_for_windows=false
    -Denable_d3d12=true
)

if [ -d "$MULLION_BUILD" ]; then
    (cd "$MULLION_DIR" && meson setup --reconfigure "${MESON_OPTIONS[@]}" "$MULLION_BUILD")
else
    (cd "$MULLION_DIR" && meson setup "${MESON_OPTIONS[@]}" "$MULLION_BUILD")
fi

NCPU=$(whisky_ncpu)
echo "=== Building Mullion for x86_64 Wine with $NCPU jobs ==="
MULLION_CACHE_HOME=/private/tmp/whisky-mullion-build-home
mkdir -p "$MULLION_CACHE_HOME"
HOME="$MULLION_CACHE_HOME" ninja -C "$MULLION_BUILD" -j "$NCPU"
meson install -C "$MULLION_BUILD"

echo "=== Installing Mullion builtins ==="
for dll in "$MULLION_STAGE/x86_64-windows/"*.dll; do
    cp "$dll" "$WINE_LIB/x86_64-windows/"
done
cp "$MULLION_STAGE/x86_64-unix/winemetal.so" "$WINE_LIB/x86_64-unix/"

for dll in d3d10core.dll d3d11.dll d3d12.dll d3d12core.dll dxgi.dll winemetal.dll; do
    [ -f "$WINE_LIB/x86_64-windows/$dll" ] || {
        echo "ERROR: Mullion install is missing $dll." >&2
        exit 1
    }
done
[ -f "$WINE_LIB/x86_64-unix/winemetal.so" ] || {
    echo "ERROR: Mullion install is missing winemetal.so." >&2
    exit 1
}

echo "Mullion installed as the x86_64 Wine Direct3D backend."
