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
elif echo "$out" | grep -q "calling WMCreateSyncReader"; then
    fail "the probe did not return from WMCreateSyncReader ($rc)"
    echo "      That is the game's failure: the delay-load of winegstreamer.dll"
    echo "      raised EXCEPTION_WINE_STUB. Check 1 above says whether it exists."
else
    fail "the probe failed before reaching WMCreateSyncReader ($rc)"
fi

echo
echo "$failures failed check(s)"
exit "$failures"
