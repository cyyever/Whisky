#!/bin/bash
set -e

# Minimal x86_64 FFmpeg for Wine's winedmo (Media Foundation demux/decode).
# Only libavformat/libavcodec/libavutil (+swresample/swscale) with the builtin
# decoders/demuxers — no external codec libraries, no encoders/muxers/network.
# Built from source because Homebrew has no usable x86_64 ffmpeg bottle on
# Tahoe and its source build is gated on the newest Xcode.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FFMPEG_SRC="$PROJECT_DIR/vendor/ffmpeg"
FFMPEG_PREFIX="$PROJECT_DIR/vendor/ffmpeg-x86"
FFMPEG_TAG=n8.1.1

if [ ! -d "$FFMPEG_SRC" ]; then
    echo "=== Cloning FFmpeg $FFMPEG_TAG ==="
    git clone --depth 1 --branch "$FFMPEG_TAG" \
        https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_SRC"
fi

BUILD_DIR="$FFMPEG_SRC/build-x86_64"
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
    --disable-avfilter \
    --disable-encoders \
    --disable-muxers \
    --disable-network

echo "=== Building FFmpeg ==="
make -j"$(sysctl -n hw.ncpu)"
make install

echo "=== Done ==="
echo "Installed to: $FFMPEG_PREFIX"
for lib in avformat avcodec avutil; do
    file "$FFMPEG_PREFIX"/lib/lib$lib.*.dylib | head -1
done
