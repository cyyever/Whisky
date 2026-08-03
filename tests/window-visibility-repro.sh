#!/bin/bash
# window-visibility-repro.sh — minimal reproducer: a Wine top-level window is
# created, framed and ordered front, Cocoa reports it visible, but it never
# appears and WindowServer has no record of it.
#
# Two halves, queried identically so the result is a comparison rather than an
# anecdote:
#   control  a plain x86_64 Cocoa process shows a 640x480 window
#   wine     win-toplevel-visible-test.exe shows a 640x480 window ([A])
# then CGWindowList is asked whether a 640x480 window exists. The control
# proves the machine/session can display windows; the Wine case is the bug.
#
# No human observation needed — CGWindowList is the oracle.
#
# Usage: tests/window-visibility-repro.sh [bottle-path]
# Exit:  0 = Wine's window reached WindowServer (bug absent)
#        1 = control worked but Wine's did not (bug reproduced)
#        2 = control itself failed (environment can't show windows; inconclusive)
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TESTS="$PWD/tests"
WINE_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
WINE="$WINE_DIR/bin/wine64"
WINESERVER="$WINE_DIR/bin/wineserver"
BOTTLE="${1:-$(ls -d "$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"/*/ 2>/dev/null | head -1)}"
NATIVE="$TESTS/window-visibility-native"
WINE_EXE="$TESTS/win-toplevel-visible-test.exe"
# Both halves ask for a 640x480 *content* area; the frame that CGWindowList
# reports is taller by the title bar, so the query size is taken from what the
# control actually got rather than assumed.
WIDTH=640; HEIGHT=480

[ -n "$BOTTLE" ] && [ -d "$BOTTLE" ] || { echo "no bottle found (pass one as \$1)"; exit 2; }

# --- build both halves ------------------------------------------------------
# The native half must be x86_64: it has to be able to see what a Wine process
# (x86_64 under Rosetta) puts on screen, and to be a like-for-like control.
echo "=== building ==="
clang -arch x86_64 -fobjc-arc -framework Cocoa \
      -o "$NATIVE" "$TESTS/window-visibility-native.m" || exit 2
[ -f "$WINE_EXE" ] || \
    x86_64-w64-mingw32-gcc -O2 -o "$WINE_EXE" "$TESTS/win-toplevel-visible-test.c" \
        -mconsole -lgdi32 -luser32 || exit 2

cleanup() {
    pkill -f window-visibility-native 2>/dev/null
    pkill -f win-toplevel-visible-test 2>/dev/null
    WINEPREFIX="$BOTTLE" "$WINESERVER" -k9 2>/dev/null
}
trap cleanup EXIT

# --- control: can this session show a window at all? ------------------------
echo
echo "=== control: plain x86_64 Cocoa process ==="
"$NATIVE" control 25 >/tmp/wvr-control.log 2>&1 & sleep 4
read -r _ WIDTH HEIGHT < <(grep '^QUERYSIZE' /tmp/wvr-control.log)
: "${WIDTH:=640}" "${HEIGHT:=512}"
cat /tmp/wvr-control.log | grep -v QUERYSIZE
echo "WindowServer sees (querying ${WIDTH}x${HEIGHT}):"
"$NATIVE" query "$WIDTH" "$HEIGHT"
control_ok=$?
pkill -f window-visibility-native 2>/dev/null
sleep 1

# --- the Wine case ----------------------------------------------------------
# Same wineserver hygiene the app uses: a stale server from a previous run
# holds the old desktop and skews the result.
echo
echo "=== wine: win-toplevel-visible-test.exe ==="
WINEPREFIX="$BOTTLE" "$WINESERVER" -k9 2>/dev/null; sleep 2
pkill -9 -f wineserver 2>/dev/null; sleep 1

WINEPREFIX="$BOTTLE" WINEMSYNC=0 WIN_TEST_HOLD=1 "$WINE" "$WINE_EXE" 2>&1 \
    | grep -E "^\[A\]" &
sleep 8
echo "WindowServer sees (querying ${WIDTH}x${HEIGHT}):"
"$NATIVE" query "$WIDTH" "$HEIGHT"
wine_ok=$?

# --- verdict ----------------------------------------------------------------
echo
echo "=== verdict ==="
if [ "$control_ok" -ne 0 ]; then
    echo "INCONCLUSIVE: the control window never reached WindowServer either."
    echo "  This session cannot display windows at all, so nothing can be said"
    echo "  about Wine. Check the login session / screen recording permissions."
    exit 2
fi
if [ "$wine_ok" -eq 0 ]; then
    echo "PASS: Wine's window reached WindowServer — the bug is absent."
    exit 0
fi
echo "REPRODUCED: the control window reached WindowServer, Wine's did not."
echo "  Wine's own view (WINEDEBUG=+macdrv) shows the full path succeeding:"
echo "    create_cocoa_window -> setFrame(100,376 640x480) -> orderFront -> isVisible=1"
echo "  so the NSWindow exists in-process but is never registered with"
echo "  WindowServer. Next: why does this process's window registration fail"
echo "  when a plain process's does not."
exit 1
