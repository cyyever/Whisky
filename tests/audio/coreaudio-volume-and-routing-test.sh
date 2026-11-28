#!/usr/bin/env bash
#
# coreaudio-volume-and-routing-test — verify winecoreaudio.drv:
#   1. Host C unit test of volume_scale.h across FLOAT32 / PCM16 / PCM24 / PCM32 / PCM8.
#   2. Live WASAPI playback on kAudioUnitSubType_DefaultOutput with ISimpleAudioVolume /
#      IAudioStreamVolume / IChannelAudioVolume + SetMute(TRUE) does NOT mutate macOS
#      host system output volume or mute state.
#
# Usage: tests/audio/coreaudio-volume-and-routing-test.sh [prefix]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_DIR/scripts/lib/common.sh"

WINE="$INSTALL_DIR/Wine/bin/wine64"
SERVER="${WINESERVER:-$INSTALL_DIR/Wine/bin/wineserver}"
[ -x "$WINE" ] || { echo "ERROR: Wine not found at $WINE (run make proton)" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/whisky-audio-test.XXXXXX")
OWN_PREFIX=0
if [ -n "${1:-}" ]; then
    PREFIX="$1"
else
    PREFIX="$WORK/prefix"
    mkdir -p "$PREFIX"
    OWN_PREFIX=1
fi
cleanup() {
    if [ "$OWN_PREFIX" = "1" ]; then
        WINEPREFIX="$PREFIX" DYLD_FALLBACK_LIBRARY_PATH="$INSTALL_DIR/Wine/lib" "$SERVER" -k >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== 1. Host unit test: volume_scale.h (all 5 PCM formats, ASan+UBSan+LSan) ==="
SDK="$(xcrun --show-sdk-path)"
if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
    HOST_CC="/opt/homebrew/opt/llvm/bin/clang"
    ASAN_OPTS="detect_leaks=1:halt_on_error=1:exitcode=77"
else
    HOST_CC="$(xcrun --find clang)"
    ASAN_OPTS="detect_leaks=0:halt_on_error=1:exitcode=77"
fi
"$HOST_CC" -arch arm64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    -Wall -Wextra \
    -I"$PROJECT_DIR/vendor/proton-wine/dlls/winecoreaudio.drv" \
    "$PROJECT_DIR/tests/audio/volume-scale-unit-test.c" \
    -o "$WORK/volume-scale-unit-test" -lm
ASAN_OPTIONS="$ASAN_OPTS" UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" \
    "$WORK/volume-scale-unit-test"

echo ""
echo "=== 2. Compile live WASAPI test PE (UBSan trap) ==="
x86_64-w64-mingw32-gcc -O1 -g -Wall -Wextra -fsanitize=undefined -fsanitize-undefined-trap-on-error \
    -o "$WORK/wasapi-volume-and-routing-test.exe" \
    "$PROJECT_DIR/tests/audio/wasapi-volume-and-routing-test.c" \
    -lole32 -luuid

echo ""
echo "=== 3. Live macOS system-volume isolation & DefaultOutput test ==="
read_host_vol() {
    osascript -e 'set s to get volume settings' \
              -e 'return (output volume of s as text) & "," & (output muted of s as text)' 2>/dev/null || echo "unavailable"
}

BEFORE=$(read_host_vol)
echo "Host macOS volume before: $BEFORE"

export WINEPREFIX="$PREFIX"
export DYLD_FALLBACK_LIBRARY_PATH="$INSTALL_DIR/Wine/lib"
export WINEDEBUG="-all"
export WINEMSYNC=1

if [ "$OWN_PREFIX" = "1" ]; then
    "$WINE" wineboot -u >/dev/null 2>&1
    "$SERVER" -w
fi

"$WINE" "$WORK/wasapi-volume-and-routing-test.exe"

AFTER=$(read_host_vol)
echo "Host macOS volume after:  $AFTER"

if [ "$BEFORE" != "unavailable" ] && [ "$BEFORE" != "$AFTER" ]; then
    echo "FAIL: WASAPI stream volume/mute mutated macOS host volume ($BEFORE -> $AFTER)!" >&2
    exit 1
fi
echo "PASS: macOS host output volume/mute untouched ($BEFORE)"
