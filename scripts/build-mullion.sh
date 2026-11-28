#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$PROJECT_DIR/scripts/lib/mullion.sh"
check_mullion_source
require_tools meson ninja x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ x86_64-w64-mingw32-strip

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
STRIP_OPT=true
if [ "${WHISKY_WINE_BUILD:-release}" = debug ]; then
    STRIP_OPT=false
fi
TESTS_OPT="${WHISKY_MULLION_TESTS:-false}"

MESON_OPTIONS=(
    --cross-file "$MULLION_DIR/build-win64.txt"
    --native-file "$MULLION_DIR/build-native-llvm23.txt"
    --prefix "$MULLION_STAGE"
    --buildtype release
    -Dstrip="$STRIP_OPT"
    -Dnative_llvm_path="$LLVM_PREFIX"
    -Dwine_build_path="$WINE_BUILD"
    -Dwine_builtin_dll=true
    -Dbuild_airconv_for_windows=false
    "-Dc_args=['-march=x86-64-v3','-mprefer-vector-width=128']"
    "-Dcpp_args=['-march=x86-64-v3','-mprefer-vector-width=128']"
    -Dcpp_link_args=-lstdc++exp
    -Denable_d3d12=true
    -Denable_tests="$TESTS_OPT"
)

CMD_LINE_FILE="$MULLION_BUILD/meson-private/cmd_line.txt"
if [ ! -f "$MULLION_BUILD/build.ninja" ] || [ ! -f "$CMD_LINE_FILE" ]; then
    (cd "$MULLION_DIR" && meson setup "${MESON_OPTIONS[@]}" "$MULLION_BUILD")
elif ! grep -Fq "$MULLION_DIR/build-native-llvm23.txt" "$CMD_LINE_FILE"; then
    # Meson caches compiler selection. Recreate old Apple Clang configurations once.
    (cd "$MULLION_DIR" && meson setup --wipe "${MESON_OPTIONS[@]}" "$MULLION_BUILD")
elif ! grep -Fqx "strip = $STRIP_OPT" "$CMD_LINE_FILE" ||
     ! grep -Fqx "enable_tests = $TESTS_OPT" "$CMD_LINE_FILE" ||
     ! grep -Fqx "native_llvm_path = $LLVM_PREFIX" "$CMD_LINE_FILE" ||
     ! grep -Fqx "wine_build_path = $WINE_BUILD" "$CMD_LINE_FILE" ||
     ! grep -Fqx "prefix = $MULLION_STAGE" "$CMD_LINE_FILE" ||
     ! grep -Fq "x86-64-v3" "$CMD_LINE_FILE"; then
    (cd "$MULLION_DIR" && meson setup --reconfigure "${MESON_OPTIONS[@]}" "$MULLION_BUILD")
fi

NCPU=$(whisky_ncpu)
echo "=== Building Mullion for x86_64 Wine with $NCPU jobs ==="
ninja -C "$MULLION_BUILD" -j "$NCPU"
meson install -C "$MULLION_BUILD" --quiet

echo "=== Installing Mullion builtins ==="
for dll in "$MULLION_STAGE/x86_64-windows/"*.dll; do
    base="$(basename "$dll")"
    if ! cmp -s "$dll" "$WINE_LIB/x86_64-windows/$base"; then
        cp "$dll" "$WINE_LIB/x86_64-windows/$base"
    fi
done

winemetal_updated=0
if ! cmp -s "$MULLION_STAGE/x86_64-unix/winemetal.so" "$WINE_LIB/x86_64-unix/winemetal.so"; then
    rm -f "$WINE_LIB/x86_64-unix/winemetal.so"
    cp "$MULLION_STAGE/x86_64-unix/winemetal.so" "$WINE_LIB/x86_64-unix/winemetal.so"
    codesign --force --sign - "$WINE_LIB/x86_64-unix/winemetal.so"
    winemetal_updated=1
fi

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

if [ "$winemetal_updated" -eq 1 ]; then
    prewarm_rosetta_aot "$WINE_LIB/x86_64-unix/winemetal.so"
fi

echo "Mullion installed as the x86_64 Wine Direct3D backend."
