#!/usr/bin/env bash
#
# d3d9-present-stall-test — does Present() stall when you cmd-tab away?
#
#   tests/d3d9-present-stall-test.sh [seconds] [bottle ...]
#
# Reproduces SSFIV's window-switch freeze without the game. See the .c header
# for the mechanism; the short version is that the frozen game sits in
# vkWaitForPresentKHR waiting on a CAMetalDrawable presented-handler that never
# fires, and the native probe (tests/vulkan/present-probe-test.sh) showed
# KosmicKrisp's present path is fine on its own — so the repro has to go
# through the window winemac.drv creates.
#
# INTERACTIVE: a window opens and you must cmd-tab away from it for ~10 s,
# then come back. Nothing inside Wine can deactivate its own app the way the
# window server does.
#
# Exit: 0 no stall, 2 Present() stalled (the bug).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"
. "$PROJECT_DIR/scripts/lib/common.sh"

WHISKY_LIB="$INSTALL_DIR/Wine"
SRC="$PROJECT_DIR/tests/d3d9-present-stall-test.c"
EXE="$PROJECT_DIR/tests/d3d9-present-stall-test.exe"

# 32-bit: SSFIV is, and DXVK's d3d9 is loaded as a builtin for both bitnesses.
CC=i686-w64-mingw32-gcc
command -v "$CC" >/dev/null || { echo "SKIP: $CC not found (brew install mingw-w64)"; exit 0; }
[ -x "$WHISKY_LIB/bin/wine" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }

SECONDS_ARG=40
if [ $# -gt 0 ] && [ "$1" -eq "$1" ] 2>/dev/null; then SECONDS_ARG="$1"; shift; fi

select_bottles "$@"
BOTTLE="${bottles[0]}"

if [ ! -f "$EXE" ] || [ "$SRC" -nt "$EXE" ]; then
    "$CC" -O2 -o "$EXE" "$SRC" -ld3d9 -lgdi32 -luser32 || exit 1
fi

# bottle_shellenv, not a hand-built env: it emits WINEMSYNC from the bottle's
# enhancedSync, and getting that wrong kills wine in msync_init before main()
# — which would look exactly like the hang under test.
eval "$(bottle_shellenv "$BOTTLE")"
export WINEDEBUG=-all

echo "bottle: $(basename "$BOTTLE")"
echo
# No `timeout` wrapper: a stall here is the RESULT, not a hung test. The
# watchdog thread reports it while the main thread is still inside Present(),
# and _exit(2)s after 30 s, so the run always ends on its own.
wine "$EXE" "$SECONDS_ARG"
rc=$?

echo
case $rc in
    0) echo "0 failed check(s)" ;;
    2) echo "1 failed check(s) — Present() stalled on window switch" ;;
    *) echo "1 failed check(s) — exit $rc" ;;
esac
exit $((rc == 0 ? 0 : 1))
