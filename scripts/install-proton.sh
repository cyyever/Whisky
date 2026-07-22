#!/bin/bash
set -e
# Install the Proton build (vendor/proton-wine) into a self-contained Wine dir,
# bundling x86_64 dylibs + the KosmicKrisp Vulkan loader, mirroring
# build-wine-x86.sh's install. Assumes the Proton build tree already exists
# (vendor/proton-wine/build). DXMT + DXVK install on top afterwards.
#
#   INSTALL_DIR   where to place the Wine/ tree (default: vendor/proton-wine/dist)
# Swap into Whisky with:  cp -R "$INSTALL_DIR/Wine" ~/Library/Application\ Support/com.isaacmarovitz.Whisky/Libraries/Wine

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTON="$PROJECT_DIR/vendor/proton-wine"
BUILD="$PROTON/build"
INSTALL_DIR="${INSTALL_DIR:-$PROTON/dist}"
X86_PREFIX="$PROJECT_DIR/vendor/homebrew-x86"
ARM_BREW_PREFIX="$(brew --prefix)"
export PATH="$ARM_BREW_PREFIX/opt/bison/bin:$ARM_BREW_PREFIX/bin:$X86_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

[ -d "$BUILD" ] || { echo "ERROR: Proton build dir missing ($BUILD)." >&2; exit 1; }

echo "=== make install (Proton) ==="
TMPINSTALL=$(mktemp -d)
cd "$BUILD"
arch -x86_64 env PATH="$PATH" CCACHE_DISABLE=1 make -j"$(sysctl -n hw.ncpu)" install DESTDIR="$TMPINSTALL" >/tmp/proton-install-make.log 2>&1

WINE_INSTALL_BIN=$(find "$TMPINSTALL" -name "wine" -type f | head -1)
WINE_INSTALL_ROOT=$(dirname "$(dirname "$WINE_INSTALL_BIN")")
echo "installed root: $WINE_INSTALL_ROOT"

find "$WINE_INSTALL_ROOT/lib/wine" -name '*.a' -delete
rm -rf "$WINE_INSTALL_ROOT/share/man"

rm -rf "$INSTALL_DIR/Wine"; mkdir -p "$INSTALL_DIR/Wine"
cp -R "$WINE_INSTALL_ROOT/bin" "$INSTALL_DIR/Wine/"
cp -R "$WINE_INSTALL_ROOT/lib" "$INSTALL_DIR/Wine/"
cp -R "$WINE_INSTALL_ROOT/share" "$INSTALL_DIR/Wine/"

echo "=== bundle dylibs ==="
for lib in freetype sdl2 molten-vk gnutls gettext/lib; do
    LIBDIR="$X86_PREFIX/opt/$lib/lib"
    [ -d "$LIBDIR" ] && cp -Rn "$LIBDIR"/*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true
done
for f in "$X86_PREFIX/lib/"*.dylib; do
    dest="$INSTALL_DIR/Wine/lib/$(basename "$f")"
    { [ -e "$dest" ] || [ -L "$dest" ]; } && continue
    if [ -L "$f" ] && [[ "$(readlink "$f")" == */* ]]; then cp -L "$f" "$dest" 2>/dev/null || true
    else cp -R "$f" "$dest" 2>/dev/null || true; fi
done
cp -Rn "$PROJECT_DIR/vendor/ffmpeg-x86/lib/"*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true

echo "=== KosmicKrisp loader swap ==="
KK_DYLIB="$PROJECT_DIR/vendor/kosmickrisp/libvulkan_kosmickrisp.dylib"
VK_LOADER_DIR="$X86_PREFIX/opt/vulkan-loader/lib"
if [ -f "$KK_DYLIB" ] && [ -d "$VK_LOADER_DIR" ]; then
    for name in libMoltenVK.dylib libvulkan.1.dylib; do
        rm -f "$INSTALL_DIR/Wine/lib/$name"
        cp -L "$VK_LOADER_DIR/libvulkan.1.dylib" "$INSTALL_DIR/Wine/lib/$name"
    done
    ICD_DIR="$HOME/.local/share/vulkan/icd.d"; mkdir -p "$ICD_DIR"
    cp "$PROJECT_DIR/vendor/kosmickrisp/kosmickrisp_icd.x86_64.json" "$ICD_DIR/"
fi

echo "=== patch rpaths on unix modules ==="
for so in "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/"*.so; do
    install_name_tool -add_rpath '@loader_path/../..' "$so" 2>/dev/null || true
done

echo "=== wine.inf Graphics=mac ==="
WINE_INF="$INSTALL_DIR/Wine/share/wine/wine.inf"
if ! grep -q '^\[Drivers\]' "$WINE_INF"; then
    printf '\n[Drivers]\nHKLM,Software\\Wine\\Drivers,Graphics,,"mac"\n' >> "$WINE_INF"
    awk '/^\[BaseInstall\]/{in_base=1} /^\[/&&!/^\[BaseInstall\]/{in_base=0} in_base&&/^AddReg=\\$/{print;print "    Drivers,\\";next} {print}' "$WINE_INF" > "$WINE_INF.new" && mv "$WINE_INF.new" "$WINE_INF"
fi

cd "$INSTALL_DIR/Wine/bin"; [ ! -f wine64 ] && ln -s wine wine64
rm -rf "$TMPINSTALL"
echo "=== DONE ==="; "$INSTALL_DIR/Wine/bin/wine" --version; file "$INSTALL_DIR/Wine/bin/wine"
echo "Installed to: $INSTALL_DIR/Wine"
