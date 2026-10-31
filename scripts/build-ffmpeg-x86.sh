#!/bin/bash
set -e

# Minimal x86_64 FFmpeg for Wine's winedmo (Media Foundation demux/decode) and
# for gst-libav (build-gstreamer-x86.sh). libavformat/libavcodec/libavutil +
# swresample/swscale/avfilter with the builtin decoders/demuxers — no external
# codec libraries, no encoders/muxers/network.
# Built from source because Homebrew has no usable x86_64 ffmpeg bottle on
# Tahoe and its source build is gated on the newest Xcode.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_link_probe   # fail fast if DEVELOPER_DIR cannot link the installed SDK
FFMPEG_SRC="$PROJECT_DIR/vendor/ffmpeg"
FFMPEG_PREFIX="$PROJECT_DIR/vendor/ffmpeg-x86"
FFMPEG_TAG=n9.0.2

BUILD_DIR="$FFMPEG_SRC/build-x86_64"
if [ ! -d "$FFMPEG_SRC" ]; then
    echo "=== Cloning FFmpeg $FFMPEG_TAG ==="
    git clone --depth 1 --branch "$FFMPEG_TAG" \
        https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_SRC"
elif [ "$(git -C "$FFMPEG_SRC" describe --tags --exact-match 2>/dev/null)" != "$FFMPEG_TAG" ]; then
    # An existing checkout is never moved by the clone above, so a bumped
    # FFMPEG_TAG would otherwise silently rebuild the old tree. The clone is a
    # single-tag shallow one: fetch just the new tag (fetching all tags dies
    # with `early EOF`), and drop the old build dir so no stale objects link in.
    echo "=== Switching FFmpeg to $FFMPEG_TAG ==="
    git -C "$FFMPEG_SRC" fetch --depth 1 origin tag "$FFMPEG_TAG"
    git -C "$FFMPEG_SRC" checkout -q "$FFMPEG_TAG"
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== Configuring FFmpeg (x86_64, minimal) ==="
../configure \
    --prefix="$FFMPEG_PREFIX" \
    --arch=x86_64 \
    --cc="clang -arch x86_64" \
    --enable-shared \
    --disable-static \
    --disable-programs \
    --disable-doc \
    --disable-avdevice \
    `# avfilter is for gst-libav, not winedmo: its meson requires libavfilter` \
    `# >= 7.16.100 with no wrap fallback, so a build without it stops at` \
    `# configure. See build-gstreamer-x86.sh.` \
    --enable-avfilter \
    --disable-encoders \
    --disable-muxers \
    --disable-network

echo "=== Building FFmpeg ==="
make -j"$(whisky_ncpu)"
make install

echo "=== Done ==="
echo "Installed to: $FFMPEG_PREFIX"
for lib in avformat avcodec avutil; do
    file "$FFMPEG_PREFIX"/lib/lib$lib.*.dylib | head -1
done
