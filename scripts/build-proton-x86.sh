#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
WINE_SRC="$PROJECT_DIR/vendor/proton-wine"
BUILD_DIR="$WINE_SRC/build"
# release (default) strips PE debug info at install time; debug keeps it for
# winedbg (`make proton-debug`). Compilation always carries -g, so switching
# modes never invalidates the build tree or ccache — only the install differs.
WINE_BUILD="${WHISKY_WINE_BUILD:-release}"

echo "=== Building Proton (proton-wine) x86_64 from $WINE_SRC ==="

# Apply the Proton macOS patch series (patches/proton-wine/, base c3007e6f on Valve's
# bleeding-edge — the only branch Valve still pushes to; proton_11.0 and
# experimental_11.0 are both older). The reset arg
# cleans the source first (`git checkout -- .` + `git clean -fdq`), so add-file patches
# (msync.c, server/msync.c, …) re-apply cleanly on a forced rebuild. `git clean -fdq`
# removes untracked NON-ignored files — patch leftovers, the generated inputs, and stray
# dist/.cache — but KEEPS gitignored paths: build/ (intentional — incremental compiles)
# and configure. NOTE: also discards uncommitted proton-wine edits (e.g. local msync
# diagnostics) — commit them or capture as a patch to survive a rebuild.
apply_patches "$WINE_SRC" "$PROJECT_DIR/patches/proton-wine" Wine reset

# Wine's generator bootstrap needs autotools + python3 + perl (Wine's own generators).
for t in autoreconf python3 perl; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "ERROR: $t not found (brew install autoconf; python3/perl ship with macOS/brew)" >&2
        exit 1
    }
done

# Regenerate Wine's generated build inputs. The clean removed the non-ignored ones
# (include/config.h.in, include/wine/vulkan.h, server_protocol.h, syscall headers);
# configure is gitignored so the clean KEPT it — remove it too so autoreconf regenerates
# it fresh from the current configure.ac. All generators are offline (vk.xml is vendored).
# These are build artifacts, deliberately kept OUT of git (committing them caused the past
# base-drift). build/ (also gitignored) is intentionally preserved for incremental builds.
echo "=== Regenerating Wine build inputs (generator bootstrap) ==="
rm -f "$WINE_SRC/configure"
( cd "$WINE_SRC" && \
    tools/make_requests && \
    python3 dlls/winevulkan/make_vulkan && \
    tools/make_specfiles && \
    autoreconf -f )

export_homebrew_mirrors

if [ ! -f "$X86_BREW" ]; then
    echo "ERROR: x86_64 Homebrew not found. Run scripts/setup-x86-brew.sh first."
    exit 1
fi

X86_PREFIX=$(arch -x86_64 "$X86_BREW" --prefix)
# Build tools (bison, the mingw-w64 cross-compiler, pkg-config) come from the ARM64
# brew — they are arch-independent / target PE, so no x86_64 copies are needed. Only
# the libraries linked into x86_64 Wine (freetype, gnutls, sdl2, gettext/libintl,
# MoltenVK) must be x86_64, and those are picked up via PKG_CONFIG_PATH below.
ARM_BREW_PREFIX="$(brew --prefix)"

# The reset above KEEPS the gitignored build/ tree, so configure+make below are
# incremental (ccache further speeds recompiles). `make clean-proton` (rm -rf build/)
# for a true from-scratch build tree.
mkdir -p "$BUILD_DIR"

# CLEAN_PATH is also needed for the make step below (env -i wipes PATH).
CLEAN_PATH="$(wine_clean_path)"

# The env/toolchain + shared configure flags live in wine_configure (lib/common.sh),
# byte-for-byte identical to build-msync-tests.sh; --disable-tests is the only extra.
# ccache is on by default; WHISKY_CCACHE=0 disables it (release/reproducible builds
# or to rule out a stale-object bug) — see whisky_ccache_on in lib/common.sh.
echo "=== Configuring Wine (x86_64) ==="
wine_configure "$BUILD_DIR" --disable-tests

NCPU=$(whisky_ncpu)
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
# release installs, kept by `make proton-debug`. (.tlb/.msstyles are data, not
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

# --- DXMT (Metal D3D11) restore over wined3d --------------------------------
# Wine's builtin d3d11/d3d10core/dxgi are wined3d-backed (GL 2.1 -> feature
# level 9_3 -> GLES2 only). DXMT replaces them with Metal builds (FL 11_1 ->
# GLES3), which ANGLE's D3D11 backend (Steam webhelper SharedImageStub) and
# D3D11 games require. The cp -R of lib/ above just wrote wined3d's copies,
# clobbering any prior DXMT install — restore DXMT over them so `make proton`
# is order-independent (no need to re-run `make dxmt` after every proton
# rebuild). Mirrors the KosmicKrisp loader swap below: skipped entirely when
# the DXMT artifacts are absent (wined3d stays; run `make dxmt` to build them).
DXMT_B64="$PROJECT_DIR/vendor/dxmt/build/src"
DXMT_B32="$PROJECT_DIR/vendor/dxmt/build32/src"
if [ -f "$DXMT_B64/d3d11/d3d11.dll" ]; then
    echo "=== Restoring DXMT builtins over wined3d (proton install clobbered them) ==="
    for p in d3d11/d3d11.dll d3d10/d3d10core.dll dxgi/dxgi.dll winemetal/winemetal.dll; do
        cp "$DXMT_B64/$p" "$INSTALL_DIR/Wine/lib/wine/x86_64-windows/${p##*/}"
        [ -f "$DXMT_B32/$p" ] && cp "$DXMT_B32/$p" "$INSTALL_DIR/Wine/lib/wine/i386-windows/${p##*/}"
    done
    cp "$DXMT_B64/winemetal/unix/winemetal.so" "$INSTALL_DIR/Wine/lib/wine/x86_64-unix/winemetal.so"
    echo "DXMT restored: d3d11/d3d10core/dxgi/winemetal (x86_64 + i386)"
fi

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
# brew dylibs — asserting the swap right after keeps every `make proton` correct.
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
