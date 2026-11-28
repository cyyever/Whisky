#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$PROJECT_DIR/scripts/lib/mullion.sh"
check_mullion_source
mullion_llvm_prefix >/dev/null  # catch a missing/wrong-architecture LLVM before the long Wine build
whisky_link_probe   # fail fast if DEVELOPER_DIR cannot link the installed SDK
WINE_SRC="$PROJECT_DIR/vendor/proton-wine"
BUILD_DIR="$WINE_SRC/build"
# Release strips PE debug info at install time. make proton-debug keeps it for winedbg.
WINE_BUILD="${WHISKY_WINE_BUILD:-release}"

echo "=== Building Proton (proton-wine) x86_64 from $WINE_SRC ==="

# ValveSoftware/wine bleeding-edge base: a47c73f52fd7b2efafc1c560710f3a5099ae51e0.
# Bootstrap vendor/proton-wine from https://codeload.github.com/ValveSoftware/wine/tar.gz/<base>.
# Commit the extracted source before applying patches. Reset mode discards local source edits and keeps build/.
apply_patches "$WINE_SRC" "$PROJECT_DIR/patches/proton-wine" Wine reset

for t in autoreconf python3 perl; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "ERROR: $t not found (brew install autoconf; python3/perl ship with macOS/brew)" >&2
        exit 1
    }
done

# Regenerate protocol, Vulkan and configure inputs from the patched sources.
echo "=== Regenerating Wine build inputs (generator bootstrap) ==="
rm -f "$WINE_SRC/configure"
( cd "$WINE_SRC" && \
    tools/make_requests && \
    python3 dlls/winevulkan/make_vulkan && \
    tools/make_specfiles && \
    autoreconf -f )

if [ ! -f "$X86_DEPS/.built" ]; then
    echo "ERROR: x86_64 libraries not found in $X86_DEPS. Run 'make x86-deps' first."
    exit 1
fi

# Use native build tools and the x86_64 libraries staged by build-x86-deps.sh.
ARM_BREW_PREFIX="$(brew --prefix)"

# Keep the build tree for incremental builds. make clean-proton removes it.
mkdir -p "$BUILD_DIR"

# CLEAN_PATH is also needed for the make step below (env -i wipes PATH).
CLEAN_PATH="$(wine_clean_path)"

echo "=== Configuring Wine (x86_64) ==="
# Drop Wine's generic USB passthrough and camera-capture backends. Xbox and
# other SDL controllers stay enabled through winebus.sys; they do not use
# libusb/wineusb.sys.
wine_configure "$BUILD_DIR" --disable-tests --without-usb --without-v4l2 --without-gphoto

NCPU=$(whisky_ncpu)
echo "=== Building Wine (x86_64) with $NCPU cores ==="
arch -x86_64 env -i \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/private/tmp}" \
    PATH="$CLEAN_PATH" \
    DEVELOPER_DIR="$DEVELOPER_DIR" \
    make -j"$NCPU"

echo "=== Installing to $INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR"
TMPINSTALL=$(mktemp -d)
WINE_STAGE=$(mktemp -d "$INSTALL_DIR/.Wine-stage.XXXXXX")
VERSION_STAGE="$INSTALL_DIR/.WhiskyWineVersion.plist.$$"
INSTALL_COMMITTED=0
cleanup_install() {
    rm -rf "$TMPINSTALL" "$VERSION_STAGE"
    [ -z "$WINE_STAGE" ] || rm -rf "$WINE_STAGE"
}
trap cleanup_install EXIT
arch -x86_64 make install DESTDIR="$TMPINSTALL"

WINE_INSTALL_BIN=$(find "$TMPINSTALL" -name "wine" -type f | head -1)
WINE_INSTALL_ROOT=$(dirname "$(dirname "$WINE_INSTALL_BIN")")

# Trim development files and strip PE debug sections in release builds.
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

cp -R "$WINE_INSTALL_ROOT/bin" "$WINE_STAGE/"
cp -R "$WINE_INSTALL_ROOT/lib" "$WINE_STAGE/"
cp -R "$WINE_INSTALL_ROOT/share" "$WINE_STAGE/"

# Restore DXVK's D3D8/9 DLLs after Wine installs its builtins. Stamp each installed DLL
# so wineboot can mirror it into a bottle.
DXVK_SRC_DIR="$PROJECT_DIR/vendor/dxvk"
if [ -f "$DXVK_SRC_DIR/build.w64/src/d3d9/d3d9.dll" ]; then
    echo "=== Restoring DXVK builtins over wined3d (proton install clobbered them) ==="
    for dxvk_pair in "build.w64:x86_64-windows" "build.w32:i386-windows"; do
        dxvk_bdir="${dxvk_pair%%:*}"; dxvk_arch="${dxvk_pair##*:}"
        # Same list as DXVK_DLLS in build-dxvk.sh.
        for dxvk_dll in d3d9/d3d9.dll d3d8/d3d8.dll; do
            dxvk_src="$DXVK_SRC_DIR/$dxvk_bdir/src/$dxvk_dll"
            [ -f "$dxvk_src" ] || continue
            cp "$dxvk_src" "$WINE_STAGE/lib/wine/$dxvk_arch/${dxvk_dll##*/}"
            mark_wine_builtin "$WINE_STAGE/lib/wine/$dxvk_arch/${dxvk_dll##*/}"
        done
    done
    echo "DXVK restored: d3d9/d3d8 (x86_64 + i386)"
fi

# Restore the Mullion builtins after Wine installs its Direct3D DLLs.
# Meson already strips and signs these in vendor/mullion-install-x86_64.
MULLION_STAGE="$PROJECT_DIR/vendor/mullion-install-x86_64"
if [ -d "$MULLION_STAGE/x86_64-windows" ] && [ -d "$MULLION_STAGE/x86_64-unix" ]; then
    echo "=== Restoring Mullion builtins over Wine's Direct3D implementation ==="
    cp "$MULLION_STAGE/x86_64-windows/"*.dll "$WINE_STAGE/lib/wine/x86_64-windows/"
    cp "$MULLION_STAGE/x86_64-unix/winemetal.so" "$WINE_STAGE/lib/wine/x86_64-unix/winemetal.so"
fi

# Preserve versioned dylib symlinks when bundling runtime dependencies.
echo "=== Bundling runtime dylibs ==="
cp -R "$X86_DEPS/lib/"*.dylib "$WINE_STAGE/lib/"
# Minimal x86_64 FFmpeg for winedmo (built by build-ffmpeg-x86.sh)
cp -Rn "$PROJECT_DIR/vendor/ffmpeg-x86/lib/"*.dylib "$WINE_STAGE/lib/" 2>/dev/null || true

# Bundle GStreamer's libraries, plugins and scanner together. Wine requires GStreamer,
# and the installed runtime must resolve these files after the build tree is removed.
GST_PREFIX="$PROJECT_DIR/vendor/gstreamer-x86"
if [ -d "$GST_PREFIX/lib" ]; then
    echo "=== Bundling GStreamer (winegstreamer's backend) ==="
    cp -R "$GST_PREFIX/lib/"*.dylib "$WINE_STAGE/lib/" 2>/dev/null || true
    rm -rf "$WINE_STAGE/lib/gstreamer-1.0"
    cp -R "$GST_PREFIX/lib/gstreamer-1.0" "$WINE_STAGE/lib/" 2>/dev/null || true
    # The scanner registers the libav plugin used for WMV decoding.
    mkdir -p "$WINE_STAGE/libexec/gstreamer-1.0"
    cp "$GST_PREFIX/libexec/gstreamer-1.0/gst-plugin-scanner" \
       "$WINE_STAGE/libexec/gstreamer-1.0/" 2>/dev/null || true

    # Relocate plugins, the scanner and all bundled libraries, including GLib, against Wine/lib.
    for f in "$WINE_STAGE/lib/gstreamer-1.0/"*.dylib \
             "$WINE_STAGE/lib/"*.dylib \
             "$WINE_STAGE/libexec/gstreamer-1.0/gst-plugin-scanner"; do
        [ -f "$f" ] || continue
        # Patch real files once. install_name_tool follows symlinks.
        [ -L "$f" ] && continue
        has_bundled_ref "$f" || continue
        case "$f" in
        */lib/gstreamer-1.0/*)     rp='@loader_path/..' ;;
        */libexec/gstreamer-1.0/*) rp='@loader_path/../../lib' ;;
        *)                         rp='@loader_path' ;;
        esac
        install_name_tool -add_rpath "$rp" "$f" 2>/dev/null || true
        relocate_to_rpath "$f"
    done

    n=$(ls "$WINE_STAGE/lib/gstreamer-1.0/"*.dylib 2>/dev/null | wc -l | tr -d ' ')
    if [ ! -x "$WINE_STAGE/libexec/gstreamer-1.0/gst-plugin-scanner" ]; then
        echo "ERROR: gst-plugin-scanner missing from the install; plugins will not register" >&2
        exit 1
    fi
    echo "GStreamer bundled: $n plugin(s), scanner present"
else
    echo "ERROR: no x86_64 GStreamer at $GST_PREFIX (run 'make gstreamer')" >&2
    exit 1
fi

# Install the Khronos loader under both names that winevulkan can request so either resolves KosmicKrisp.
KK_DYLIB="$PROJECT_DIR/vendor/kosmickrisp/libvulkan_kosmickrisp.dylib"
if [ -f "$KK_DYLIB" ]; then
    echo "=== Asserting KosmicKrisp Vulkan loader swap ==="
    rm -f "$WINE_STAGE/lib/libMoltenVK.dylib.mvk-stock" \
          "$WINE_STAGE/lib/libMoltenVK.dylib.orig"
    # cp -L resolves the libvulkan.1 -> libvulkan.1.x.y symlink to a real file
    # (the bundling above may have left symlinks; replace with the loader).
    for name in libMoltenVK.dylib libvulkan.1.dylib; do
        rm -f "$WINE_STAGE/lib/$name"
        cp -L "$X86_DEPS/lib/libvulkan.1.dylib" "$WINE_STAGE/lib/$name"
        # After the relocation loop above, so these copies need their own pass.
        relocate_to_rpath "$WINE_STAGE/lib/$name"
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
for so in "$WINE_STAGE/lib/wine/x86_64-unix/"*.so; do
    install_name_tool -add_rpath '@loader_path/../..' "$so" 2>/dev/null || true
    relocate_to_rpath "$so"
done

# On macOS 26, Wine's auto-detect of the graphics driver via explorer's
# desktop GUID does not work reliably and new bottles end up with no
# display driver loaded (winecfg/etc. silently never show a window).
# Patch wine.inf so wineboot writes the driver explicitly into HKLM
# when initialising the prefix.
echo "=== Patching wine.inf to set Graphics driver = mac ==="
WINE_INF="$WINE_STAGE/share/wine/wine.inf"
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

# Build wineserver as native arm64: it is an independent daemon that executes
# no x86 Windows code and communicates with Rosetta x86_64 wine64 clients over
# LP64 little-endian Unix sockets / shared memory (patch 0026 advertises AMD64).
echo "=== Building native arm64 wineserver ==="
WS_OBJ="$WINE_SRC/build/server-arm64"
rm -rf "$WS_OBJ" && mkdir -p "$WS_OBJ"
WS_CFLAGS="-O2 -flto=thin"
WS_LDFLAGS="-flto=thin"
WS_CC="clang"
WS_SDK_FLAGS=""
if [ "${WHISKY_WINE_ASAN:-0}" = "1" ]; then
    if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
        WS_CC="/opt/homebrew/opt/llvm/bin/clang"
        WS_SDK_FLAGS="-isysroot $(xcrun --show-sdk-path)"
        echo "=== Enabling ASan + UBSan + LSan (LLVM) on arm64 wineserver ==="
    else
        echo "=== Enabling ASan + UBSan (Apple Clang) on arm64 wineserver ==="
    fi
    WS_CFLAGS="-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize=function -fno-sanitize-recover=undefined"
    WS_LDFLAGS="-fsanitize=address,undefined -fno-sanitize=function"
fi
for f in "$WINE_SRC"/server/*.c; do
    base=$(basename "$f" .c)
    ccache "$WS_CC" -arch arm64 $WS_SDK_FLAGS $WS_CFLAGS -c -o "$WS_OBJ/${base}.o" "$f" \
        -I"$WINE_SRC/build/server" -I"$WINE_SRC/server" \
        -I"$WINE_SRC/build/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -DWINE_UNIX_LIB \
        -DBINDIR='"/usr/local/bin"' -DDATADIR='"/usr/local/share"' \
        -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing
done
"$WS_CC" -arch arm64 $WS_SDK_FLAGS $WS_LDFLAGS -o "$WINE_STAGE/bin/wineserver" "$WS_OBJ"/*.o
rm -rf "$WS_OBJ"

# Remove Wine SDK/build-time tools not used at runtime
rm -f "$WINE_STAGE/bin/"{widl,winebuild,winecpp,winedump,wineg++,winegcc,winemaker,wmc,wrc,function_grep.pl}

# Create wine64 symlink for Whisky compatibility
cd "$WINE_STAGE/bin"
[ ! -f wine64 ] && ln -s wine wine64

"$PROJECT_DIR/scripts/sign-wine.sh" "$WINE_STAGE"

# Use VERSION for the plist. Shallow or tarball-based checkouts may lack the matching Wine tags.
WINE_VER=$(sed -n 's/^Wine version //p' "$WINE_SRC/VERSION" 2>/dev/null)
[ -n "$WINE_VER" ] ||
    WINE_VER=$("$WINE_STAGE/bin/wine64" --version 2>&1 | sed 's/^wine-//; s/-.*$//')
MAJOR=$(echo "$WINE_VER" | cut -d. -f1)
MINOR=$(echo "$WINE_VER" | cut -d. -f2)
PATCH=$(echo "$WINE_VER" | cut -d. -f3)
PATCH=${PATCH:-0}

# Record the same patch digest as the app so a bottle can identify its Wine build.
PATCH_DIGEST=$(cat "$PROJECT_DIR"/patches/proton-wine/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)

cat > "$VERSION_STAGE" << PLISTEOF
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
	<key>patchSeriesDigest</key>
	<string>$PATCH_DIGEST</string>
</dict>
</plist>
PLISTEOF

 # Replace only after the complete Wine tree and its metadata have been assembled.
rm -rf "$INSTALL_DIR/Wine"
mv "$WINE_STAGE" "$INSTALL_DIR/Wine"
WINE_STAGE=""
mv "$VERSION_STAGE" "$INSTALL_DIR/WhiskyWineVersion.plist"
INSTALL_COMMITTED=1

prewarm_rosetta_aot \
    "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/ntdll.so" \
    "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/win32u.so" \
    "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/winemac.so" \
    "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/winevulkan.so" \
    "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/winemetal.so" \
    "$KK_DYLIB"

echo "=== Done! ==="
echo "Wine version: $WINE_VER"
echo "Installed to: $INSTALL_DIR"
file "$INSTALL_DIR/Wine/bin/wine64"
file "$INSTALL_DIR/Wine/bin/wineserver"
