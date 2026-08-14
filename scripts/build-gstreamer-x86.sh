#!/bin/bash
set -e

# Build GStreamer as x86_64, for the winegstreamer that wmvcore's IWMSyncReader
# is implemented on. Without it a game playing a WMV dies on a delay-load of
# winegstreamer.dll -- SSFIV's intro does, at exit 255 (tests/gstreamer/).
#
# Built here rather than installed from Homebrew. The x86_64 brew cannot supply
# it: the formula merged base/good/bad/ugly/libav into one package that pulls in
# GTK, X11 and an image stack, and its transitive netpbm and subversion have no
# x86_64 bottle for macOS 27, so brew wants to build them from source and refuses
# because Xcode 26.5 is older than the macOS it expects. That check is Homebrew
# policy, not a compiler limit -- the same toolchain builds Wine, DXVK, DXMT and
# KosmicKrisp here every day.
#
# Only what decoding a WMV needs, via -Dauto_features=disabled plus an explicit
# enable list: core, the base plugins wg_parser drives (app for appsrc/appsink,
# playback for decodebin, the converters), asfdemux for the container, and libav
# for the codec, plus the handful of good/bad plugins winegstreamer creates by
# name (see the enable list below). Everything else -- rs, devtools,
# introspection, the GTK and X11 sinks -- stays off. FFmpeg comes from vendor/ffmpeg-x86, already
# built by build-ffmpeg-x86.sh, not from the FFmpeg.wrap subproject.
#
# glib comes from subprojects/glib.wrap: the x86_64 brew cannot provide that
# either, for the same reason.
#
# Output: vendor/gstreamer-x86/{lib,include}. Wine finds it through
# PKG_CONFIG_PATH in wine_configure (lib/common.sh).

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0

GST_SRC="$PROJECT_DIR/vendor/gstreamer"
OUT_DIR="$PROJECT_DIR/vendor/gstreamer-x86"
BUILD_DIR="$GST_SRC/build-x86_64"
FFMPEG_PREFIX="$PROJECT_DIR/vendor/ffmpeg-x86"
X86_PREFIX="$X86_BREW_HOME"
ARM_BREW_PREFIX="$(brew --prefix)"

[ -f "$GST_SRC/meson.build" ] || {
    echo "ERROR: no GStreamer source at $GST_SRC" >&2
    echo "       git submodule update --init --depth 1 vendor/gstreamer" >&2
    exit 1; }
[ -d "$FFMPEG_PREFIX/lib/pkgconfig" ] || {
    echo "ERROR: no x86_64 FFmpeg at $FFMPEG_PREFIX (run scripts/build-ffmpeg-x86.sh)" >&2
    exit 1; }

# ARM brew meson/ninja (~/.local/bin has a meson with a broken interpreter --
# keep it off PATH), same as build-kosmickrisp-x86.sh.
export PATH="$ARM_BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# A developer shell can point these at arm64 libraries, and they reach the
# linker: with LD_LIBRARY_PATH=~/opt/lib set, ld found an arm64 libz, skipped it
# as the wrong architecture, and failed on _uncompress -- 350 objects into the
# build, naming zlib and not the environment. The Wine build avoids the whole
# class by configuring inside `env -i`; this is the same idea, narrowed to the
# variables that steer the compiler and the linker.
unset LD_LIBRARY_PATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH \
      CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
      PKG_CONFIG_PATH LDFLAGS CPPFLAGS CFLAGS CXXFLAGS OBJCFLAGS

# Outside the submodule: meson self-ignores its build dirs, a file in the source
# root gets no such cover and leaves the parent repo reporting untracked content.
CROSS_FILE="$PROJECT_DIR/build/gstreamer-x86_64-darwin-cross.ini"
mkdir -p "$(dirname "$CROSS_FILE")"
cat > "$CROSS_FILE" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = '$ARM_BREW_PREFIX/bin/pkg-config'

[host_machine]
system = 'darwin'
# Required: gstreamer's meson calls host_machine.subsystem(), which meson cannot
# autodetect for a cross build and errors out on ("Subsystem not defined").
subsystem = 'macos'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = false
pkg_config_libdir = ['$FFMPEG_PREFIX/lib/pkgconfig', '$X86_PREFIX/lib/pkgconfig', '$X86_PREFIX/share/pkgconfig']

# So glib's \`dependency('intl')\` finds the brew gettext. gettext ships no .pc,
# meson looks for libintl.h and the library directly, and pkg-config paths alone
# do not help it. Without this glib falls back to its proxy-libintl subproject,
# which installs a libintl.8.dylib exporting g_libintl_* -- the same file name
# as the brew gettext that freetype and gnutls link, different ABI. Only one can
# sit in Wine/lib, and whichever loses takes every GStreamer plugin with it:
# "Symbol not found: _g_libintl_bind_textdomain_codeset".
[built-in options]
c_args = ['-I$X86_PREFIX/include']
cpp_args = ['-I$X86_PREFIX/include']
objc_args = ['-I$X86_PREFIX/include']
c_link_args = ['-L$X86_PREFIX/lib']
cpp_link_args = ['-L$X86_PREFIX/lib']
objc_link_args = ['-L$X86_PREFIX/lib']
EOF

meson_args=( "$BUILD_DIR" "$GST_SRC"
    --cross-file "$CROSS_FILE"
    --prefix "$OUT_DIR"
    -Dbuildtype=release
    -Dauto_features=disabled
    # The subprojects we need, and every other one off.
    -Dbase=enabled -Dugly=enabled -Dlibav=enabled
    -Dgood=enabled -Dbad=enabled -Drs=disabled -Ddevtools=disabled
    -Dges=disabled -Drtsp_server=disabled -Dpython=disabled -Dsharp=disabled
    -Dgst-examples=disabled -Dtests=disabled -Dexamples=disabled
    -Dintrospection=disabled -Ddoc=disabled -Dgtk_doc=disabled -Dnls=disabled
    -Dtools=disabled -Dgtk=disabled -Dqt5=disabled -Dqt6=disabled
    # ...except in core, where `tools` also gates gst-plugin-scanner
    # (libs/gst/helpers/meson.build: `if not get_option('tools').disabled()`).
    # GStreamer registers plugins by running that helper; without it the
    # in-process fallback takes the simple plugins and drops libav, so a WMV
    # finds no decoder and decodebin stalls instead of failing. Disabling tools
    # cost exactly that, and the symptom named zlib's cousin, not the scanner.
    -Dgstreamer:tools=enabled
    # glib's wrap otherwise builds proxy-libintl, which installs its own
    # libintl.8.dylib exporting g_libintl_* -- the same file name as the brew
    # gettext that freetype and gnutls link, with a different ABI. Only one can
    # sit in Wine/lib, and whichever loses takes every GStreamer plugin with it
    # ("Symbol not found: _g_libintl_bind_textdomain_codeset"). Nothing here
    # needs translated GLib messages, so the dependency goes away instead.
    -Dglib:nls=disabled
    -Dwebrtc=disabled -Dtls=disabled -Dlibnice=disabled
    # asfdemux is GPL-gated in gst-plugins-ugly.
    -Dgpl=enabled
    # What wg_parser actually drives: appsrc/appsink, decodebin, the converters,
    # and typefind to pick the demuxer.
    -Dgst-plugins-base:app=enabled
    -Dgst-plugins-base:playback=enabled
    -Dgst-plugins-base:typefind=enabled
    -Dgst-plugins-base:audioconvert=enabled
    -Dgst-plugins-base:audioresample=enabled
    -Dgst-plugins-base:videoconvertscale=enabled
    # Wine's configure requires gstreamer-gl-1.0 alongside core/video/audio/tag
    # and hard-errors without it, so GL is not optional here even though nothing
    # in the WMV path uses it. Backends pinned to macOS's so autodetection cannot
    # reach for X11 or EGL.
    -Dgst-plugins-base:gl=enabled
    -Dgst-plugins-base:gl_api=opengl
    -Dgst-plugins-base:gl_platform=cgl
    -Dgst-plugins-base:gl_winsys=cocoa
    # glvideoflip (one of the elements wg_parser creates by name when the PE side
    # asks for the OpenGL path) is compiled only when graphene is found -- see
    # gst-plugins-base/ext/gl/meson.build. Without it winegstreamer logs
    # "failed to create glvideoflip" and Open() never returns. graphene comes
    # from a wrap, so this costs one more subproject and no system dependency.
    -Dgst-plugins-base:gl-graphene=enabled
    -Dgst-plugins-ugly:asfdemux=enabled
    -Dgst-plugins-ugly:gpl=enabled
    # winegstreamer instantiates these by name (create_element / factory_make in
    # dlls/winegstreamer/*.c). A missing one is not an error at init: the element
    # is simply never created, the branch it belongs to never links, and Open()
    # blocks forever waiting for a stream that will never arrive -- which reads
    # as "no decoder" even though the decoder is present and running.
    -Dgst-plugins-good:videofilter=enabled
    -Dgst-plugins-good:deinterlace=enabled
    -Dgst-plugins-good:debugutils=enabled
    -Dgst-plugins-bad:audiobuffersplit=enabled
    # h264parse. wg_transform's decoder chain looks for a parser first and only
    # falls back to feeding the decoder the raw input caps; without it Steam's
    # CEF video hits that fallback, where an avdec_h264 workaround tries to
    # rewrite caps it does not own -- see patch 0034. The parser is the path
    # that code was written for, so build it rather than only fixing the
    # fallback.
    -Dgst-plugins-bad:videoparsers=enabled )

# meson records the cross-file's absolute path and re-reads it on every
# regeneration, so a build dir configured against a different one dies in
# machinefile.py rather than reconfiguring. Start over instead.
recorded="$BUILD_DIR/meson-private/cmd_line.txt"
if [ -d "$BUILD_DIR" ] && { [ ! -f "$recorded" ] || ! grep -qF "$CROSS_FILE" "$recorded"; }; then
    # No cmd_line.txt means a previous `meson setup` died partway, and the
    # `[ -d ] ||` below would then skip setup and hand ninja a broken dir.
    echo "=== Build dir is stale or half-configured; starting over ==="
    rm -rf "$BUILD_DIR"
fi

echo "=== Configuring GStreamer (x86_64) ==="
# --reconfigure, not "skip if it exists". The option list above is part of the
# build's identity -- adding -Dgstreamer:tools=enabled (the plugin scanner) to a
# dir configured without it otherwise does nothing, ninja and install succeed,
# the Makefile stamp refreshes, and the only symptom is a WMV that hangs.
#
# The retry is not defensive noise: meson validates `subproject:option` names
# against the subprojects the EXISTING dir knows about, so switching a
# subproject on (-Dgood=disabled -> enabled) and naming its options in the same
# command dies with `Unknown option: "gst-plugins-good:videofilter"`. A fresh
# setup sees the whole option list at once and is fine.
if [ -d "$BUILD_DIR" ]; then
    if ! meson setup --reconfigure "${meson_args[@]}"; then
        echo "=== Reconfigure failed (subproject set likely changed); starting over ==="
        rm -rf "$BUILD_DIR"
        meson setup "${meson_args[@]}"
    fi
else
    meson setup "${meson_args[@]}"
fi

echo "=== Building ==="
ninja -C "$BUILD_DIR"

# meson install adds and overwrites; it never removes. A libintl.8.dylib from a
# configuration that still built proxy-libintl survives here and gets bundled
# over the brew gettext, reproducing the ABI clash the options exist to avoid.
#
# After ninja, not before: a failed build would otherwise leave no tree at all,
# and build-proton-x86.sh's `[ -d "$GST_PREFIX/lib" ]` silently skips bundling --
# so the next `make proton` spends tens of minutes producing a Wine with no
# GStreamer and says nothing about it.
rm -rf "$OUT_DIR"
meson install -C "$BUILD_DIR"

echo "=== Done ==="
echo "Installed to: $OUT_DIR"
file "$OUT_DIR/lib/libgstreamer-1.0.dylib" 2>/dev/null | head -1
echo "Plugins that matter for WMV:"
missing=0
for p in libgstapp libgstplayback libgstasf libgstlibav libgsttypefindfunctions; do
    printf '  %-26s ' "$p"
    if [ -f "$OUT_DIR/lib/gstreamer-1.0/$p.dylib" ]; then
        echo "ok"
    else
        echo "MISSING"
        missing=$((missing + 1))
    fi
done
printf '  %-26s ' "gst-plugin-scanner"
if [ -x "$OUT_DIR/libexec/gstreamer-1.0/gst-plugin-scanner" ]; then
    echo "ok"
else
    echo "MISSING — plugins will not register; a WMV will find no decoder"
    missing=$((missing + 1))
fi

# Exit non-zero, or `make gstreamer` reports success without a decoder, the
# Makefile stamp is satisfied, make proton proceeds, and the failure surfaces as
# a hung WMV at runtime -- which is the thing this build exists to prevent.
if [ "$missing" -ne 0 ]; then
    echo
    echo "ERROR: $missing required artifact(s) missing" >&2
    exit 1
fi
echo
echo "Wine picks this up through wine_configure's PKG_CONFIG_PATH (lib/common.sh)."
echo "Verify with tests/gstreamer/gstreamer-test.sh after 'make proton'."
