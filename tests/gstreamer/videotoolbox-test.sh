#!/usr/bin/env bash
# Run against a built/installed x86_64 GStreamer, without touching Wine bottles.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="${WHISKY_GSTREAMER_PREFIX:-$PROJECT_DIR/vendor/gstreamer-x86}"
if [ "$(uname -s)" != Darwin ]; then
    echo "SKIP: VideoToolbox requires macOS"
    exit 77
fi
for plugin in applemedia isomp4 libav videoparsersbad; do
    [ -f "$prefix/lib/gstreamer-1.0/libgst$plugin.dylib" ] || {
        echo "FAIL: libgst$plugin.dylib missing; run make gstreamer" >&2
        exit 1
    }
done

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/whisky-videotoolbox.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
unset PKG_CONFIG_PATH
pkg-config --define-variable=prefix="$prefix" --cflags --libs \
    gstreamer-app-1.0 gstreamer-video-1.0 > "$run_dir/flags.rsp"
xcrun clang -arch x86_64 -O2 -framework Cocoa @"$run_dir/flags.rsp" \
    "$PROJECT_DIR/tests/gstreamer/videotoolbox-test.m" -o "$run_dir/probe"

export DYLD_LIBRARY_PATH="$prefix/lib"
export GST_PLUGIN_SYSTEM_PATH=""
export GST_PLUGIN_PATH="$prefix/lib/gstreamer-1.0"
export GST_PLUGIN_SCANNER="$prefix/libexec/gstreamer-1.0/gst-plugin-scanner"
for mode in hardware software mp4; do
    echo "=== $mode: twelve frames and full pixel validation ==="
    GST_REGISTRY="$run_dir/$mode.registry.bin" "$run_dir/probe" "--$mode"
done
