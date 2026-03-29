#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WINE_SRC="$PROJECT_DIR/vendor/wine"
BUILD_DIR="$WINE_SRC/build-x86_64"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
X86_BREW_HOME="$PROJECT_DIR/vendor/homebrew-x86"
X86_BREW="$X86_BREW_HOME/bin/brew"

echo "=== Building Wine x86_64 from $WINE_SRC ==="

export HOMEBREW_BREW_GIT_REMOTE=https://mirrors.ustc.edu.cn/brew.git
export HOMEBREW_CORE_GIT_REMOTE=https://mirrors.ustc.edu.cn/homebrew-core.git
export HOMEBREW_BOTTLE_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles
export HOMEBREW_API_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles/api

if [ ! -f "$X86_BREW" ]; then
    echo "ERROR: x86_64 Homebrew not found. Run scripts/setup-x86-brew.sh first."
    exit 1
fi

X86_PREFIX=$(arch -x86_64 "$X86_BREW" --prefix)
X86_BISON="$X86_PREFIX/opt/bison/bin"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

ARM_BREW_PREFIX="$(brew --prefix)"
CLEAN_PATH="$X86_BISON:$X86_PREFIX/bin:$ARM_BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "=== Configuring Wine (x86_64) ==="
arch -x86_64 env -i \
    HOME="$HOME" \
    PATH="$CLEAN_PATH" \
    PKG_CONFIG="$X86_PREFIX/bin/pkg-config" \
    PKG_CONFIG_PATH="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig" \
    PKG_CONFIG_LIBDIR="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig" \
    LDFLAGS="-L$X86_PREFIX/lib -L$X86_PREFIX/opt/molten-vk/lib" \
    CFLAGS="-I$X86_PREFIX/include -I$X86_PREFIX/opt/freetype/include/freetype2 -I$X86_PREFIX/opt/molten-vk/include" \
    CPPFLAGS="-I$X86_PREFIX/include -I$X86_PREFIX/opt/freetype/include/freetype2 -I$X86_PREFIX/opt/molten-vk/include" \
    ../configure \
        --enable-archs=i386,x86_64 \
        --with-vulkan \
        --without-gstreamer \
        --disable-tests \
        --without-x

NCPU=$(sysctl -n hw.ncpu)
echo "=== Building Wine (x86_64) with $NCPU cores ==="
arch -x86_64 env -i \
    HOME="$HOME" \
    PATH="$CLEAN_PATH" \
    make -j"$NCPU"

echo "=== Installing to $INSTALL_DIR ==="
TMPINSTALL=$(mktemp -d)
arch -x86_64 make install DESTDIR="$TMPINSTALL"

# Find where make install put files
WINE_INSTALL_BIN=$(find "$TMPINSTALL" -name "wine" -type f | head -1)
WINE_INSTALL_ROOT=$(dirname "$(dirname "$WINE_INSTALL_BIN")")

rm -rf "$INSTALL_DIR/Wine"
mkdir -p "$INSTALL_DIR/Wine"
cp -R "$WINE_INSTALL_ROOT/bin" "$INSTALL_DIR/Wine/"
cp -R "$WINE_INSTALL_ROOT/lib" "$INSTALL_DIR/Wine/"
cp -R "$WINE_INSTALL_ROOT/share" "$INSTALL_DIR/Wine/"

# Bundle x86 dylibs so Wine finds them at runtime
echo "=== Bundling runtime dylibs ==="
for lib in freetype sdl2 molten-vk gnutls gettext/lib; do
    LIBDIR="$X86_PREFIX/opt/$lib/lib"
    if [ -d "$LIBDIR" ]; then
        cp -n "$LIBDIR"/*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true
    fi
done
# Also copy top-level lib dylibs
cp -n "$X86_PREFIX/lib/"*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true

# Create wine64 symlink for Whisky compatibility
cd "$INSTALL_DIR/Wine/bin"
[ ! -f wine64 ] && ln -s wine wine64

# Write version plist
WINE_VER=$("$INSTALL_DIR/Wine/bin/wine64" --version 2>&1 | sed 's/wine-//')
MAJOR=$(echo "$WINE_VER" | cut -d. -f1)
MINOR=$(echo "$WINE_VER" | cut -d. -f2)
PATCH=$(echo "$WINE_VER" | cut -d. -f3)
PATCH=${PATCH:-0}

cat > "$INSTALL_DIR/WhiskyWineVersion.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>version</key>
	<dict>
		<key>major</key>
		<integer>MAJOR_PLACEHOLDER</integer>
		<key>minor</key>
		<integer>MINOR_PLACEHOLDER</integer>
		<key>patch</key>
		<integer>PATCH_PLACEHOLDER</integer>
	</dict>
</dict>
</plist>
PLISTEOF

sed -i '' "s/MAJOR_PLACEHOLDER/$MAJOR/" "$INSTALL_DIR/WhiskyWineVersion.plist"
sed -i '' "s/MINOR_PLACEHOLDER/$MINOR/" "$INSTALL_DIR/WhiskyWineVersion.plist"
sed -i '' "s/PATCH_PLACEHOLDER/$PATCH/" "$INSTALL_DIR/WhiskyWineVersion.plist"

rm -rf "$TMPINSTALL"

echo "=== Done! ==="
echo "Wine version: $WINE_VER"
echo "Installed to: $INSTALL_DIR"
file "$INSTALL_DIR/Wine/bin/wine64"
