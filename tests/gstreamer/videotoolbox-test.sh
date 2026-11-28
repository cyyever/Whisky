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
SDK="$(xcrun --show-sdk-path)"
if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
    HOST_CC="/opt/homebrew/opt/llvm/bin/clang"
    cat > "$run_dir/lsan.supp" <<'SUPP'
# GLib/GObject static type-class registration & macOS AppKit/CoreGraphics singletons
leak:g_type_class_get
leak:type_class_init_Wm
leak:NSApplication
leak:CoreGraphics
SUPP
    VT_ASAN_OPTS="detect_leaks=1:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1:halt_on_error=1:exitcode=77"
    VT_LSAN_OPTS="suppressions=$run_dir/lsan.supp"
else
    HOST_CC="$(xcrun --find clang)"
    VT_ASAN_OPTS="detect_leaks=0:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1:halt_on_error=1:exitcode=77"
    VT_LSAN_OPTS=""
fi
VT_UBSAN_OPTS="print_stacktrace=1:halt_on_error=1"
"$HOST_CC" -arch x86_64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined,nullability,local-bounds,float-divide-by-zero -fno-sanitize-recover=all \
    -framework Cocoa @"$run_dir/flags.rsp" \
    "$PROJECT_DIR/tests/gstreamer/videotoolbox-test.m" -o "$run_dir/probe"
"$HOST_CC" -arch x86_64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer \
    -fsanitize=thread \
    -framework Cocoa @"$run_dir/flags.rsp" \
    "$PROJECT_DIR/tests/gstreamer/videotoolbox-test.m" -o "$run_dir/probe-tsan"
if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
    "$HOST_CC" -arch x86_64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer \
        -fsanitize=type \
        -framework Cocoa @"$run_dir/flags.rsp" \
        "$PROJECT_DIR/tests/gstreamer/videotoolbox-test.m" -o "$run_dir/probe-tysan"
fi

export DYLD_LIBRARY_PATH="$prefix/lib"
export GST_PLUGIN_SYSTEM_PATH=""
export GST_PLUGIN_PATH="$prefix/lib/gstreamer-1.0"
export GST_PLUGIN_SCANNER="$prefix/libexec/gstreamer-1.0/gst-plugin-scanner"
for mode in hardware software mp4; do
    echo "=== $mode (ASan+UBSan+LSan): twelve frames and full pixel validation ==="
    ASAN_OPTIONS="$VT_ASAN_OPTS" LSAN_OPTIONS="$VT_LSAN_OPTS" UBSAN_OPTIONS="$VT_UBSAN_OPTS" \
        GST_REGISTRY="$run_dir/$mode.registry.bin" "$run_dir/probe" "--$mode"
done
for mode in hardware software mp4; do
    echo "=== $mode (TSan): twelve frames and full pixel validation ==="
    TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1" \
        GST_REGISTRY="$run_dir/$mode-tsan.registry.bin" "$run_dir/probe-tsan" "--$mode"
done
if [ -x "$run_dir/probe-tysan" ]; then
    for mode in hardware software mp4; do
        echo "=== $mode (TySan): twelve frames and full pixel validation ==="
        TYSAN_OPTIONS="halt_on_error=1" \
            GST_REGISTRY="$run_dir/$mode-tysan.registry.bin" "$run_dir/probe-tysan" "--$mode"
    done
fi
