#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/vkd3d.sh"
VKD3D_LIBS="$PROJECT_DIR/vendor/vkd3d-proton/build.w64/libs"
check_vkd3d_pair "$VKD3D_LIBS"
whisky_link_probe   # fail fast if DEVELOPER_DIR cannot link the installed SDK
WINE_SRC="$PROJECT_DIR/vendor/proton-wine"
BUILD_DIR="$WINE_SRC/build"
# release (default) strips PE debug info at install time; debug keeps it for
# winedbg (`make proton-debug`). Compilation always carries -g, so switching
# modes never invalidates the build tree or ccache — only the install differs.
WINE_BUILD="${WHISKY_WINE_BUILD:-release}"

echo "=== Building Proton (proton-wine) x86_64 from $WINE_SRC ==="

# Apply the Proton macOS patch series (patches/proton-wine/, base e8e1bc79a94 on Valve's
# bleeding-edge — the only branch Valve still pushes to; proton_11.0 and
# experimental_11.0 are both older). On a fresh machine vendor/proton-wine is laid
# down from https://codeload.github.com/ValveSoftware/wine/tar.gz/<base> and
# committed once as a local git tree, so the reset below has something to reset
# to. Keep this hash in step with every rebase of the series. The reset arg
# cleans the source first (`git checkout -- .` + `git clean -fdq`), so add-file patches
# (msync_*.c, server/msync.c, …) re-apply cleanly on a forced rebuild. `git clean -fdq`
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

if [ ! -f "$X86_DEPS/.built" ]; then
    echo "ERROR: x86_64 libraries not found in $X86_DEPS. Run 'make x86-deps' first."
    exit 1
fi

# Build tools (bison, the mingw-w64 cross-compiler, pkg-config) come from the ARM64
# brew — they are arch-independent / target PE, so no x86_64 copies are needed. Only
# the libraries linked into x86_64 Wine (freetype, gnutls, SDL2, the Vulkan loader)
# must be x86_64; build-x86-deps.sh cross-builds those into X86_DEPS, and
# wine_configure finds them via PKG_CONFIG_PATH.
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
    TMPDIR="${TMPDIR:-/private/tmp}" \
    PATH="$CLEAN_PATH" \
    DEVELOPER_DIR="$DEVELOPER_DIR" \
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

# --- DXVK (D3D9/D3D8/D3D11/D3D10/DXGI) restore over wined3d -----------------
# build-dxvk.sh installs DXVK AS the builtin d3d9/d3d8/d3d11/d3d10core/dxgi
# (patch 0017 defaults them to builtin, so no bottle needs a WINEDLLOVERRIDES),
# and the cp -R of lib/ above just wrote wined3d's copies back over them.
# Without this every `make proton` silently drops games back to wined3d: D3D9
# paints a black window and burns a core in a SIGSEGV loop, and D3D11 caps at
# feature level 9_3, which ANGLE (Steam's webhelper) turns into GLES2 and a
# SharedImageStub death-loop -- failures that look nothing like "your graphics
# backend was replaced". Skipped when the DXVK build trees are absent (run
# `make dxvk`).
#
# The builtin signature is re-stamped rather than copied: build-dxvk.sh applies
# it to the INSTALLED file, so the build tree's copy does not carry it, and
# without it wineboot never mirrors the DLL into a bottle's system32.
DXVK_SRC_DIR="$PROJECT_DIR/vendor/dxvk"
if [ -f "$DXVK_SRC_DIR/build.w64/src/d3d9/d3d9.dll" ]; then
    echo "=== Restoring DXVK builtins over wined3d (proton install clobbered them) ==="
    for dxvk_pair in "build.w64:x86_64-windows" "build.w32:i386-windows"; do
        dxvk_bdir="${dxvk_pair%%:*}"; dxvk_arch="${dxvk_pair##*:}"
        # Same list as DXVK_DLLS in build-dxvk.sh.
        for dxvk_dll in d3d9/d3d9.dll d3d8/d3d8.dll d3d11/d3d11.dll d3d10/d3d10core.dll dxgi/dxgi.dll; do
            dxvk_src="$DXVK_SRC_DIR/$dxvk_bdir/src/$dxvk_dll"
            [ -f "$dxvk_src" ] || continue
            cp "$dxvk_src" "$INSTALL_DIR/Wine/lib/wine/$dxvk_arch/${dxvk_dll##*/}"
            mark_wine_builtin "$INSTALL_DIR/Wine/lib/wine/$dxvk_arch/${dxvk_dll##*/}"
        done
    done
    echo "DXVK restored: d3d9/d3d8/d3d11/d3d10core/dxgi (x86_64 + i386)"
fi

# --- vkd3d-proton (D3D12) restore over Wine's own vkd3d ----------------------
# Restore the complete win64 pair. Never silently mix Wine and vkd3d-proton.
if [ -f "$VKD3D_LIBS/d3d12/d3d12.dll" ]; then
    echo "=== Restoring vkd3d-proton builtins over Wine's vkd3d ==="
    install_vkd3d_builtins "$VKD3D_LIBS" "$INSTALL_DIR/Wine/lib/wine/x86_64-windows"
fi

# Bundle x86 dylibs so Wine finds them at runtime. cp -R (implies -P on BSD)
# preserves the libfoo.dylib -> libfoo.N.dylib -> libfoo.N.x.y.dylib symlink
# chains — plain cp used to materialize each as a full copy (3x libavcodec
# alone wasted ~28 MB).
echo "=== Bundling runtime dylibs ==="
# The x86_64 libraries from build-x86-deps.sh. Their symlinks are all leaf-name
# version chains within lib/, so cp -R keeps them intact; the install names that
# still point into vendor/x86-deps are rewritten by the relocation loop below.
cp -R "$X86_DEPS/lib/"*.dylib "$INSTALL_DIR/Wine/lib/"
# Minimal x86_64 FFmpeg for winedmo (built by build-ffmpeg-x86.sh)
cp -Rn "$PROJECT_DIR/vendor/ffmpeg-x86/lib/"*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true

# GStreamer for winegstreamer (built by build-gstreamer-x86.sh): the libraries,
# the glib the wrap built beside them, and the plugin directory. Without this the
# Libraries tree only works on the machine that built it -- winegstreamer.so and
# GStreamer's compiled-in plugin path both point into vendor/gstreamer-x86, so a
# tarball install or a cleaned build tree leaves wmvcore unable to create a sync
# reader again. GST_PLUGIN_PATH is set alongside, because the compiled-in path is
# the build tree's, not this one.
# The absent prefix is fatal, not a skipped optional feature: Wine is configured
# --with-gstreamer unconditionally. Delete
# vendor/gstreamer-x86 while build/ is up to date and make relinks nothing,
# `make install` succeeds, this block would silently not run, and the installed
# winegstreamer.so points at a prefix that no longer exists -- with no message
# anywhere until a game plays a WMV and hangs.
GST_PREFIX="$PROJECT_DIR/vendor/gstreamer-x86"
if [ -d "$GST_PREFIX/lib" ]; then
    echo "=== Bundling GStreamer (winegstreamer's backend) ==="
    cp -R "$GST_PREFIX/lib/"*.dylib "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true
    rm -rf "$INSTALL_DIR/Wine/lib/gstreamer-1.0"
    cp -R "$GST_PREFIX/lib/gstreamer-1.0" "$INSTALL_DIR/Wine/lib/" 2>/dev/null || true
    # The plugin scanner: GStreamer registers plugins by running this helper, and
    # without it the in-process fallback silently drops libav -- no WMV decoder.
    mkdir -p "$INSTALL_DIR/Wine/libexec/gstreamer-1.0"
    cp "$GST_PREFIX/libexec/gstreamer-1.0/gst-plugin-scanner" \
       "$INSTALL_DIR/Wine/libexec/gstreamer-1.0/" 2>/dev/null || true

    # Same absolute-path problem as the unix modules below, and the same fix: the
    # plugins and the scanner were linked against vendor/gstreamer-x86 by
    # pkg-config, so they resolve only on the machine that built them.
    # One rpath per location, pointing at Wine/lib where every dependency is --
    # not a handful of guesses, which only differ in how far up they climb.
    # Every dylib in lib/, not just libgst*: the GStreamer prefix also holds the
    # glib the wrap built (glib, gobject, gio, gmodule, ffi), and leaving those
    # pointing at the build tree pulled the whole build-tree branch back in --
    # two libgstreamers again, by a different route than the install names.
    for f in "$INSTALL_DIR/Wine/lib/gstreamer-1.0/"*.dylib \
             "$INSTALL_DIR/Wine/lib/"*.dylib \
             "$INSTALL_DIR/Wine/libexec/gstreamer-1.0/gst-plugin-scanner"; do
        [ -f "$f" ] || continue
        # Symlinks: install_name_tool follows them and rewrites the target, so a
        # versioned pair gets patched twice and the ID ends up under the link's
        # name while dependents record the real one.
        [ -L "$f" ] && continue
        # Only what came from a bundled build-tree prefix (see bundled_prefixes).
        # Not `grep "$PROJECT_DIR/"`: that is too wide (see bundled_prefixes).
        has_bundled_ref "$f" || continue
        case "$f" in
        */lib/gstreamer-1.0/*)     rp='@loader_path/..' ;;
        */libexec/gstreamer-1.0/*) rp='@loader_path/../../lib' ;;
        *)                         rp='@loader_path' ;;
        esac
        install_name_tool -add_rpath "$rp" "$f" 2>/dev/null || true
        relocate_to_rpath "$f"
    done

    n=$(ls "$INSTALL_DIR/Wine/lib/gstreamer-1.0/"*.dylib 2>/dev/null | wc -l | tr -d ' ')
    # Fatal, not a word inside an echo. GStreamer registers plugins by running
    # this helper; without it the in-process fallback drops libav, and the only
    # symptom is a WMV that finds no decoder and stalls at runtime. Reporting
    # "scanner MISSING" and exiting 0 hides a broken install behind a green build.
    if [ ! -x "$INSTALL_DIR/Wine/libexec/gstreamer-1.0/gst-plugin-scanner" ]; then
        echo "ERROR: gst-plugin-scanner missing from the install; plugins will not register" >&2
        exit 1
    fi
    echo "GStreamer bundled: $n plugin(s), scanner present"
else
    echo "ERROR: no x86_64 GStreamer at $GST_PREFIX (run 'make gstreamer')" >&2
    exit 1
fi

# --- KosmicKrisp Vulkan driver (Mesa) loader swap ----------------------------
# winevulkan dlopens the Vulkan implementation by leaf name: historically
# "libMoltenVK.dylib", but a Wine configured against a Vulkan loader uses
# "libvulkan.1.dylib" instead. Install the Khronos loader (build-x86-deps.sh)
# at BOTH names so ICD discovery picks KosmicKrisp up either way. There is no
# MoltenVK fallback any more: KosmicKrisp is the Vulkan driver, and without
# its artifacts Wine has no Vulkan at all.
KK_DYLIB="$PROJECT_DIR/vendor/kosmickrisp/libvulkan_kosmickrisp.dylib"
if [ -f "$KK_DYLIB" ]; then
    echo "=== Asserting KosmicKrisp Vulkan loader swap ==="
    rm -f "$INSTALL_DIR/Wine/lib/libMoltenVK.dylib.mvk-stock" \
          "$INSTALL_DIR/Wine/lib/libMoltenVK.dylib.orig"
    # cp -L resolves the libvulkan.1 -> libvulkan.1.x.y symlink to a real file
    # (the bundling above may have left symlinks; replace with the loader).
    for name in libMoltenVK.dylib libvulkan.1.dylib; do
        rm -f "$INSTALL_DIR/Wine/lib/$name"
        cp -L "$X86_DEPS/lib/libvulkan.1.dylib" "$INSTALL_DIR/Wine/lib/$name"
        # After the relocation loop above, so these copies need their own pass.
        relocate_to_rpath "$INSTALL_DIR/Wine/lib/$name"
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
    relocate_to_rpath "$so"
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

# Write version plist, from the tree's VERSION file rather than from the binary.
# `wine --version` is git-describe output against whatever tags the clone has,
# and ours is deepened rather than complete: the nearest wine-* tag it can see is
# wine-8.0, so the binary calls itself "wine-8.0-21162-g0509a0b64a4" and the
# plist claimed major 8 for a Wine 11.0 build. VERSION says "Wine version 11.0"
# and is what the tree is. Fall back to the binary if it is ever missing.
WINE_VER=$(sed -n 's/^Wine version //p' "$WINE_SRC/VERSION" 2>/dev/null)
[ -n "$WINE_VER" ] ||
    WINE_VER=$("$INSTALL_DIR/Wine/bin/wine64" --version 2>&1 | sed 's/^wine-//; s/-.*$//')
MAJOR=$(echo "$WINE_VER" | cut -d. -f1)
MINOR=$(echo "$WINE_VER" | cut -d. -f2)
PATCH=$(echo "$WINE_VER" | cut -d. -f3)
PATCH=${PATCH:-0}

# Which patch series this Wine carries. MAJOR.MINOR.PATCH stays 11.0.0 however
# much the series changes, so it cannot answer that. `make app` stamps the same
# digest into Info.plist.
PATCH_DIGEST=$(cat "$PROJECT_DIR"/patches/proton-wine/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)

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
	<key>patchSeriesDigest</key>
	<string>$PATCH_DIGEST</string>
</dict>
</plist>
PLISTEOF

rm -rf "$TMPINSTALL"

echo "=== Done! ==="
echo "Wine version: $WINE_VER"
echo "Installed to: $INSTALL_DIR"
file "$INSTALL_DIR/Wine/bin/wine64"
