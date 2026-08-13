#!/usr/bin/env bash
#
# gstreamer-test — is the WMV path actually there?
#
#   tests/gstreamer/gstreamer-test.sh [bottle]
#
# WHY. SSFIV reached Steam's stats API, then died:
#
#     err:module:DelayLoadFailureHook failed to delay load
#         winegstreamer.dll.winegstreamer_create_wm_sync_reader
#     -> EXCEPTION_WINE_STUB -> crashhandler -> exit 255
#
# It plays a WMV intro. wmvcore's IWMSyncReader is implemented in
# dlls/winegstreamer on wg_parser, and the build was configured
# --without-gstreamer, so the DLL did not exist. Nothing in the failure names
# GStreamer -- the game just stops, at an exit code that says nothing.
#
# Two checks, static then live, because they fail differently:
#
#   1. winegstreamer.dll installed for both architectures. Catches a Wine
#      configured without it, which is a build-config fault, not a runtime one.
#   2. WMCreateSyncReader actually returns a reader. Catches the case where the
#      DLL is present but the GStreamer pipeline cannot be built -- plugins
#      missing, or an x86_64 plugin registry a Rosetta process cannot load.
#
# Check 2 is the one that matches the game. Check 1 alone would pass on a Wine
# whose winegstreamer loads but finds no decoders.
#
# Exit code is the number of failed checks.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"

WHISKY_LIB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
WINE_LIB="$WHISKY_LIB/lib/wine"
PROBE_SRC="$PROJECT_DIR/tests/gstreamer/wm-sync-reader-test.c"
PROBE_EXE="$PROJECT_DIR/tests/gstreamer/wm-sync-reader-test.exe"
PLAY_SRC="$PROJECT_DIR/tests/gstreamer/wmv-playback-test.c"
PLAY_EXE="$PROJECT_DIR/tests/gstreamer/wmv-playback-test.exe"

failures=0
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "pass  $*"; }

[ -x "$WHISKY_LIB/bin/wine64" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }
command -v i686-w64-mingw32-gcc >/dev/null ||
    { echo "SKIP: mingw-w64 not found (brew install mingw-w64)"; exit 0; }

echo "=== 1. winegstreamer.dll installed ==="
for arch in x86_64-windows i386-windows; do
    if [ -f "$WINE_LIB/$arch/winegstreamer.dll" ]; then
        pass "$arch"
    else
        fail "$arch has no winegstreamer.dll"
        echo "      Wine was built --without-gstreamer. wmvcore cannot create a"
        echo "      sync reader, and any game playing a WMV dies on the delay-load."
    fi
done

# select_bottles exits 0 on a machine with no bottles, which would discard the
# failures check 1 just recorded -- and check 1 is a property of the Wine install,
# not of any prefix, so a Wine built --without-gstreamer must not report green
# just because nothing is installed to run it against.
if [ "$failures" -ne 0 ]; then
    echo
    echo "$failures failed check(s) — skipping the live check"
    exit "$failures"
fi

# Any bottle: this is a property of the Wine install, not of the prefix.
select_bottles "$@"
BOTTLE="${bottles[0]}"

if [ ! -f "$PROBE_EXE" ] || [ "$PROBE_SRC" -nt "$PROBE_EXE" ]; then
    i686-w64-mingw32-gcc -O2 -o "$PROBE_EXE" "$PROBE_SRC" || exit 1
fi

echo
echo "=== 2. WMCreateSyncReader returns a reader (bottle: $(basename "$BOTTLE")) ==="
out=$( cd "$WHISKY_LIB/bin" && env -i HOME="$HOME" \
    WINEPREFIX="$BOTTLE" WINEDEBUG=-all \
    DYLD_FALLBACK_LIBRARY_PATH="$WHISKY_LIB/lib" \
    ./wine64 "$PROBE_EXE" 2>/dev/null )
rc=$?
echo "$out" | sed 's/^/    /'

if [ "$rc" -eq 0 ]; then
    pass "a sync reader was created"
elif echo "$out" | grep -qE "returned 0x|IWMSyncReader created"; then
    # It came back and said no. A different fault from the one below, and the
    # HRESULT is in the output above.
    fail "WMCreateSyncReader returned an error ($rc)"
elif echo "$out" | grep -q "calling WMCreateSyncReader"; then
    fail "the probe did not return from WMCreateSyncReader ($rc)"
    echo "      That is the game's failure: the delay-load of winegstreamer.dll"
    echo "      raised EXCEPTION_WINE_STUB. Check 1 above says whether it exists."
else
    fail "the probe failed before reaching WMCreateSyncReader ($rc)"
fi

# Check 3: decode, not just construct. Creating a reader builds no pipeline, so
# check 2 passes on a GStreamer with no demuxer and no decoder -- it did, while
# opening a real WMV hung. Only this one exercises asfdemux and libav.
WMV_WIN='C:\\Program Files (x86)\\Steam\\steamapps\\common\\Super Street Fighter IV - Arcade Edition\\movie\\opening\\opening_tm_low.wmv'
WMV_UNIX="$BOTTLE/drive_c/Program Files (x86)/Steam/steamapps/common/Super Street Fighter IV - Arcade Edition/movie/opening/opening_tm_low.wmv"
echo
echo "=== 3. decode a real WMV ==="
if [ ! -f "$WMV_UNIX" ]; then
    echo "SKIP: no WMV to decode at $WMV_UNIX"
else
    if [ ! -f "$PLAY_EXE" ] || [ "$PLAY_SRC" -nt "$PLAY_EXE" ]; then
        i686-w64-mingw32-gcc -O2 -o "$PLAY_EXE" "$PLAY_SRC" -lole32 || exit 1
    fi
    # A timeout is part of the check: the failure this catches is a hang, not an
    # error return -- decodebin stalls when nothing can decode the stream.
    out=$( cd "$WHISKY_LIB/bin" && timeout 90 env -i HOME="$HOME" \
        WINEPREFIX="$BOTTLE" WINEDEBUG=-all \
        DYLD_FALLBACK_LIBRARY_PATH="$WHISKY_LIB/lib" \
        GST_PLUGIN_PATH="$WHISKY_LIB/lib/gstreamer-1.0" \
        ./wine64 "$PLAY_EXE" "$WMV_WIN" 2>/dev/null )
    rc=$?
    echo "$out" | grep -vE "machine-id" | sed 's/^/    /'
    if [ "$rc" -eq 0 ]; then
        pass "samples decoded"
    elif [ "$rc" -eq 124 ]; then
        fail "timed out in Open() — no decoder for the stream, so decodebin stalls"
        echo "      GST_DEBUG=2 names it: \"Missing decoder: Windows Media Video 9\"."
    else
        fail "playback failed (rc=$rc)"
    fi
fi

echo
echo "$failures failed check(s)"
exit "$failures"
