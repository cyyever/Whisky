#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WINE_SRC="$PROJECT_DIR/vendor/wine"
BUILD_DIR="$WINE_SRC/build-x86_64"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
X86_BREW_HOME="$PROJECT_DIR/vendor/homebrew-x86"
X86_BREW="$X86_BREW_HOME/bin/brew"
# release (default) strips PE debug info at install time; debug keeps it for
# winedbg (`make wine-debug`). Compilation always carries -g, so switching
# modes never invalidates the build tree or ccache — only the install differs.
WINE_BUILD="${WHISKY_WINE_BUILD:-release}"

echo "=== Building Wine x86_64 from $WINE_SRC ==="

# Apply out-of-tree Wine patches. Patches 0001-0002 mirror the branch's own
# base commits (already in HEAD); 0003+ are out-of-tree. Reset tracked source to
# a clean HEAD first so the state is deterministic: the base-commit patches are
# then detected as already-applied and skipped, while the out-of-tree patches
# apply fresh. checkout touches only tracked files, so build-x86_64/ is kept.
PATCH_DIR="$PROJECT_DIR/patches/wine"
if [ -d "$PATCH_DIR" ]; then
    git -C "$WINE_SRC" checkout -- .
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$WINE_SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
            echo "=== Patch already applied: $(basename "$patch") ==="
        elif git -C "$WINE_SRC" apply --check "$patch" >/dev/null 2>&1; then
            echo "=== Applying Wine patch: $(basename "$patch") ==="
            git -C "$WINE_SRC" apply "$patch"
        else
            echo "ERROR: cannot apply $(basename "$patch") (conflict or partial apply)"
            exit 1
        fi
    done
fi

export HOMEBREW_BREW_GIT_REMOTE=https://mirrors.ustc.edu.cn/brew.git
export HOMEBREW_CORE_GIT_REMOTE=https://mirrors.ustc.edu.cn/homebrew-core.git
export HOMEBREW_BOTTLE_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles
export HOMEBREW_API_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles/api

if [ ! -f "$X86_BREW" ]; then
    echo "ERROR: x86_64 Homebrew not found. Run scripts/setup-x86-brew.sh first."
    exit 1
fi

X86_PREFIX=$(arch -x86_64 "$X86_BREW" --prefix)
# Build tools (bison, the mingw-w64 cross-compiler, pkg-config) come from the ARM64
# brew — they are arch-independent / target PE, so no x86_64 copies are needed. Only
# the libraries linked into x86_64 Wine (freetype, gnutls, sdl2, gettext/libintl,
# MoltenVK) must be x86_64, and those are picked up via PKG_CONFIG_PATH below.

# Incremental by default; run `make clean-wine` for a clean rebuild.
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

ARM_BREW_PREFIX="$(brew --prefix)"
# bison is keg-only (macOS ships an old one), so its keg bin must be on PATH explicitly.
CLEAN_PATH="$ARM_BREW_PREFIX/opt/bison/bin:$ARM_BREW_PREFIX/bin:$X86_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Use ccache if available
CC_CMD="gcc"
CXX_CMD="g++"
if command -v ccache &>/dev/null; then
    echo "=== Using ccache ==="
    CC_CMD="ccache gcc"
    CXX_CMD="ccache g++"
fi

echo "=== Configuring Wine (x86_64) ==="
arch -x86_64 env -i \
    HOME="$HOME" \
    PATH="$CLEAN_PATH" \
    CC="$CC_CMD" \
    CXX="$CXX_CMD" \
    PKG_CONFIG="$ARM_BREW_PREFIX/bin/pkg-config" \
    PKG_CONFIG_PATH="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig:$PROJECT_DIR/vendor/ffmpeg-x86/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig:$PROJECT_DIR/vendor/ffmpeg-x86/lib/pkgconfig" \
    SDL2_CFLAGS="-I$X86_PREFIX/include/SDL2 -D_THREAD_SAFE" \
    SDL2_LIBS="-L$X86_PREFIX/lib -lSDL2" \
    LDFLAGS="-L$X86_PREFIX/lib -L$X86_PREFIX/opt/molten-vk/lib" \
    CFLAGS="-I$X86_PREFIX/include -I$X86_PREFIX/opt/freetype/include/freetype2 -I$X86_PREFIX/opt/molten-vk/include" \
    CPPFLAGS="-I$X86_PREFIX/include -I$X86_PREFIX/opt/freetype/include/freetype2 -I$X86_PREFIX/opt/molten-vk/include" \
    ../configure \
        --enable-archs=i386,x86_64 \
        --with-vulkan \
        --without-gstreamer \
        --disable-tests \
        --without-x \
        --without-cups \
        --without-krb5 \
        --without-gssapi \
        --without-pcap \
        --without-pcsclite

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

# --- Trim the install --------------------------------------------------------
# winegcc import libs (.a, ~97 MB) and man pages are dev-only. PE debug
# sections are ~2/3 of lib/wine and only useful to winedbg — stripped in
# release installs, kept by `make wine-debug`. (.tlb/.msstyles are data, not
# PE — excluded.)
find "$WINE_INSTALL_ROOT/lib/wine" -name '*.a' -delete
rm -rf "$WINE_INSTALL_ROOT/share/man"
if [ "$WINE_BUILD" = "release" ]; then
    echo "=== Stripping PE debug info (release install) ==="
    MINGW_STRIP="$ARM_BREW_PREFIX/bin/x86_64-w64-mingw32-strip"
    if [ ! -x "$MINGW_STRIP" ]; then
        echo "ERROR: $MINGW_STRIP not found (brew install mingw-w64)"
        exit 1
    fi
    find "$WINE_INSTALL_ROOT/lib/wine" \( -name '*.dll' -o -name '*.exe' \
        -o -name '*.sys' -o -name '*.cpl' -o -name '*.ocx' -o -name '*.acm' \
        -o -name '*.drv' -o -name '*.ax' -o -name '*.com' \) \
        -exec "$MINGW_STRIP" --strip-unneeded {} +
fi

rm -rf "$INSTALL_DIR/Wine"
mkdir -p "$INSTALL_DIR/Wine"
cp -R "$WINE_INSTALL_ROOT/bin" "$INSTALL_DIR/Wine/"
cp -R "$WINE_INSTALL_ROOT/lib" "$INSTALL_DIR/Wine/"
cp -R "$WINE_INSTALL_ROOT/share" "$INSTALL_DIR/Wine/"

# Bundle x86 dylibs so Wine finds them at runtime. cp -R (implies -P on BSD)
# preserves the libfoo.dylib -> libfoo.N.dylib -> libfoo.N.x.y.dylib symlink
# chains — plain cp used to materialize each as a full copy (3x libavcodec
# alone wasted ~28 MB).
echo "=== Bundling runtime dylibs ==="
for lib in freetype sdl2 molten-vk gnutls gettext/lib; do
    LIBDIR="$X86_PREFIX/opt/$lib/lib"
    if [ -d "$LIBDIR" ]; then
        cp -Rn "$LIBDIR"/*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true
    fi
done
# Also copy top-level lib dylibs. These are brew's link farm: symlinks into
# ../Cellar/<keg>/..., which would be dangling inside the bundle — materialize
# those with cp -L. (The keg loop above already copied real files with their
# intra-directory version-chain symlinks; -n below keeps them.)
for f in "$X86_PREFIX/lib/"*.dylib; do
    dest="$INSTALL_DIR/Wine/lib/$(basename "$f")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then continue; fi
    if [ -L "$f" ] && [[ "$(readlink "$f")" == */* ]]; then
        cp -L "$f" "$dest" 2>/dev/null || true
    else
        cp -R "$f" "$dest" 2>/dev/null || true
    fi
done
# Minimal x86_64 FFmpeg for winedmo (built by build-ffmpeg-x86.sh)
cp -Rn "$PROJECT_DIR/vendor/ffmpeg-x86/lib/"*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true

# --- KosmicKrisp Vulkan driver (Mesa) loader swap ----------------------------
# winevulkan dlopens the Vulkan implementation by leaf name: historically
# "libMoltenVK.dylib", but a Wine configured against the x86 brew vulkan-loader
# keg uses "libvulkan.1.dylib" instead. Install the real Khronos loader at BOTH
# names so ICD discovery picks KosmicKrisp up either way. This lives here (not
# in build-dxvk.sh) because the Wine/lib bundling above just re-copied the
# brew dylibs — asserting the swap right after keeps every `make wine` correct.
# Skipped entirely when the KosmicKrisp artifacts are absent (stock MoltenVK
# stays in place).
KK_DYLIB="$PROJECT_DIR/vendor/kosmickrisp/libvulkan_kosmickrisp.dylib"
VK_LOADER_DIR="$X86_PREFIX/opt/vulkan-loader/lib"
if [ -f "$KK_DYLIB" ] && [ -d "$VK_LOADER_DIR" ]; then
    echo "=== Asserting KosmicKrisp Vulkan loader swap ==="
    # No backup copy: stock MoltenVK is always recoverable from the x86 brew
    # molten-vk keg. Drop stale backups from older installs.
    rm -f "$INSTALL_DIR/Wine/lib/libMoltenVK.dylib.mvk-stock" \
          "$INSTALL_DIR/Wine/lib/libMoltenVK.dylib.orig"
    # cp -L resolves the libvulkan.1 -> libvulkan.1.x.y symlink to a real file
    # (the bundling above may have left symlinks; replace with the loader).
    for name in libMoltenVK.dylib libvulkan.1.dylib; do
        rm -f "$INSTALL_DIR/Wine/lib/$name"
        cp -L "$VK_LOADER_DIR/libvulkan.1.dylib" "$INSTALL_DIR/Wine/lib/$name"
    done

    # ICD manifest so the loader finds the KosmicKrisp driver.
    ICD_DIR="$HOME/.local/share/vulkan/icd.d"
    mkdir -p "$ICD_DIR"
    cp "$PROJECT_DIR/vendor/kosmickrisp/kosmickrisp_icd.x86_64.json" \
       "$ICD_DIR/kosmickrisp_icd.x86_64.json"
    echo "KosmicKrisp loader installed as libMoltenVK.dylib + libvulkan.1.dylib"
fi

# Wine's x86_64-unix .so modules dlopen bundled dylibs by leaf name (e.g.
# "libfreetype.6.dylib"); dyld won't find them in Wine/lib/ unless an rpath
# points there. Each .so already has @loader_path/ (its own dir); add ../..
# so the search reaches Wine/lib/.
echo "=== Patching rpaths on Wine unix modules ==="
for so in "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/"*.so; do
    install_name_tool -add_rpath '@loader_path/../..' "$so" 2>/dev/null || true
done

# On macOS 26, Wine's auto-detect of the graphics driver via explorer's
# desktop GUID does not work reliably and new bottles end up with no
# display driver loaded (winecfg/etc. silently never show a window).
# Patch wine.inf so wineboot writes the driver explicitly into HKLM
# when initialising the prefix.
echo "=== Patching wine.inf to set Graphics driver = mac ==="
WINE_INF="$INSTALL_DIR/Wine/share/wine/wine.inf"
if ! grep -q '^\[Drivers\]' "$WINE_INF"; then
    # Append the new section and reference it from [BaseInstall]'s AddReg list.
    cat >> "$WINE_INF" <<'INFEOF'

[Drivers]
HKLM,Software\Wine\Drivers,Graphics,,"mac"
INFEOF
    # Insert "Drivers,\" into the BaseInstall AddReg list, after the
    # "AddReg=\" line that opens it.
    awk '
        /^\[BaseInstall\]/ { in_base = 1 }
        /^\[/ && !/^\[BaseInstall\]/ { in_base = 0 }
        in_base && /^AddReg=\\$/ { print; print "    Drivers,\\"; next }
        { print }
    ' "$WINE_INF" > "$WINE_INF.new" && mv "$WINE_INF.new" "$WINE_INF"
fi

# Create wine64 symlink for Whisky compatibility
cd "$INSTALL_DIR/Wine/bin"
[ ! -f wine64 ] && ln -s wine wine64

# Write version plist. wine64 --version may add a git-describe suffix like
# "11.9-1-gede55241ff5"; strip it so the parts are plain integers.
WINE_VER=$("$INSTALL_DIR/Wine/bin/wine64" --version 2>&1 | sed 's/^wine-//; s/-.*$//')
MAJOR=$(echo "$WINE_VER" | cut -d. -f1)
MINOR=$(echo "$WINE_VER" | cut -d. -f2)
PATCH=$(echo "$WINE_VER" | cut -d. -f3)
PATCH=${PATCH:-0}

cat > "$INSTALL_DIR/WhiskyWineVersion.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>version</key>
	<dict>
		<key>major</key>
		<integer>$MAJOR</integer>
		<key>minor</key>
		<integer>$MINOR</integer>
		<key>patch</key>
		<integer>$PATCH</integer>
		<key>preRelease</key>
		<string></string>
		<key>build</key>
		<string>0</string>
	</dict>
</dict>
</plist>
PLISTEOF

rm -rf "$TMPINSTALL"

echo "=== Done! ==="
echo "Wine version: $WINE_VER"
echo "Installed to: $INSTALL_DIR"
file "$INSTALL_DIR/Wine/bin/wine64"
