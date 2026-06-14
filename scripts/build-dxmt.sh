#!/usr/bin/env bash
#
# Build DXMT (Metal-based D3D11/D3D10) from source against our Wine build and
# install it into the Wine library. Gives modern D3D11 games feature level 11.x
# via Metal (wined3d on macOS caps at FL10).
#
# Requires: full Xcode (Metal toolchain), meson, ninja, mingw-w64, and the x86
# Homebrew (for x86_64 llvm@15). Run `make wine` first (needs the Wine build dir).
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DXMT_SRC="$PROJECT_DIR/vendor/dxmt"
WINE_BUILD="$PROJECT_DIR/vendor/wine/build-x86_64"
X86_BREW="$PROJECT_DIR/vendor/homebrew-x86/bin/brew"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
WINE_LIB="$INSTALL_DIR/Wine/lib/wine"

# --- prerequisites -----------------------------------------------------------
if ! xcrun -f metal >/dev/null 2>&1; then
    echo "ERROR: Metal toolchain not found. Install full Xcode 16+ and run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi
for t in meson ninja x86_64-w64-mingw32-gcc; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not found (brew install meson ninja mingw-w64)" >&2; exit 1; }
done
[ -d "$WINE_BUILD" ] || { echo "ERROR: Wine build dir missing ($WINE_BUILD). Run 'make wine' first." >&2; exit 1; }
[ -d "$WINE_LIB/x86_64-windows" ] || { echo "ERROR: Wine not installed. Run 'make wine' first." >&2; exit 1; }

X86_PREFIX="$(arch -x86_64 "$X86_BREW" --prefix)"
LLVM15="$X86_PREFIX/opt/llvm@15"
ZSTD_LIB="$X86_PREFIX/opt/zstd/lib/libzstd.dylib"

# DXMT pins LLVM 15 (its codegen API + Apple AIR bitcode compatibility).
if [ ! -x "$LLVM15/bin/llvm-config" ]; then
    echo "=== Installing x86_64 llvm@15 ==="
    arch -x86_64 "$X86_BREW" install llvm@15
fi

# --- submodule ---------------------------------------------------------------
git -C "$PROJECT_DIR" submodule update --init --recursive vendor/dxmt

# --- zstd link fix -----------------------------------------------------------
# brew's llvm@15 is built with zstd enabled, so its static libs reference zstd
# symbols. DXMT's link lists don't include zstd, so inject it. (Idempotent;
# reverted at the end so the submodule stays clean.)
AIRCONV_MESON="$DXMT_SRC/src/airconv/meson.build"
if ! grep -q "libzstd" "$AIRCONV_MESON"; then
    sed -i '' \
        "s#'-lLLVMBinaryFormat', '-lLLVMSupport', '-lLLVMDemangle'#'-lLLVMBinaryFormat', '-lLLVMSupport', '-lLLVMDemangle', '$ZSTD_LIB', '-lz'#" \
        "$AIRCONV_MESON"
fi

cleanup() { git -C "$DXMT_SRC" checkout -- src/airconv/meson.build 2>/dev/null || true; }
trap cleanup EXIT

export PATH="$(brew --prefix)/bin:$PATH"   # native meson/ninja/mingw

# meson resolves the source dir from cwd, so build from inside the DXMT tree.
cd "$DXMT_SRC"

# --- build 64-bit (PE dlls + x86_64 unixlib) ---------------------------------
echo "=== Building DXMT (win64) ==="
rm -rf build
meson setup --cross-file build-win64.txt \
    -Dnative_llvm_path="$LLVM15" \
    -Dwine_build_path="$WINE_BUILD" \
    build --buildtype release
meson compile -C build

# --- build 32-bit PE dlls (reuse the 64-bit unixlib) -------------------------
echo "=== Building DXMT (win32) ==="
rm -rf build32
meson setup --cross-file build-win32.txt \
    -Dnative_llvm_path="$LLVM15" \
    -Dwine_build_path="$WINE_BUILD" \
    build32 --buildtype release
meson compile -C build32

# --- install into Wine library (builtin) -------------------------------------
echo "=== Installing DXMT into Wine library ==="
B64="$DXMT_SRC/build/src"
B32="$DXMT_SRC/build32/src"
install_dll() {  # <subpath> <leafname>
    cp "$B64/$1" "$WINE_LIB/x86_64-windows/$2"
    [ -f "$B32/$1" ] && cp "$B32/$1" "$WINE_LIB/i386-windows/$2"
}
install_dll d3d11/d3d11.dll       d3d11.dll
install_dll d3d10/d3d10core.dll   d3d10core.dll
install_dll dxgi/dxgi.dll         dxgi.dll
install_dll winemetal/winemetal.dll winemetal.dll
cp "$B64/winemetal/unix/winemetal.so" "$WINE_LIB/x86_64-unix/winemetal.so"

echo "=== DXMT installed ==="
echo "Enable per bottle with: WINEDLLOVERRIDES=d3d11,d3d10core,dxgi,winemetal=n,b"
echo "(and copy the DXMT dlls into the bottle's system32/syswow64, or use WhiskyCmd)"
