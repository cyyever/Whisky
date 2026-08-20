#!/usr/bin/env bash
#
# wmv-stall-test — does a WMV's graph clock keep advancing, headless?
#
#   tests/gstreamer/wmv-stall-test.sh [-enough seconds] [-show] [bottle ...]
#
# The third probe on this stack, and the one that answers a question the other
# two cannot:
#
#   wmv-playback-test  — does the file DECODE?      (IWMSyncReader, pull, no renderer)
#   wmv-render-test    — does it RENDER in a window? (windowed, for a human to watch)
#   wmv-stall-test     — does the clock KEEP MOVING? (headless, prints Nx realtime)
#
# SSFIV hangs on a black screen at its intro movie. A backtrace showed the
# media pipeline live but seemingly stuck -- asfdemux and the libav audio
# decoder running, winegstreamer's sink_chain_cb and wg_parser_get_next_read_offset
# blocked at the app boundary -- while every DXVK thread sat idle. Telling "the
# pipeline is wedged" from "a 3-minute movie is merely long" needs the graph
# clock, not a wall-clock budget: this probe reports the ratio, and only a
# clock that STOPS counts as a stall.
#
# Exit code is the number of files whose clock stalled.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"
. "$PROJECT_DIR/scripts/lib/common.sh"

WHISKY_LIB="$INSTALL_DIR/Wine"
SRC="$PROJECT_DIR/tests/gstreamer/wmv-stall-test.c"
EXE="$PROJECT_DIR/tests/gstreamer/wmv-stall-test32.exe"

# 32-bit: Steam and SSFIV are, and dshow-render-test already showed this stack
# can complete in a 64-bit process while hanging in a 32-bit one.
CC=i686-w64-mingw32-gcc
command -v "$CC" >/dev/null || { echo "SKIP: $CC not found (brew install mingw-w64)"; exit 0; }
command -v timeout >/dev/null || { echo "SKIP: timeout not found (brew install coreutils)"; exit 0; }
[ -x "$WHISKY_LIB/bin/wine" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }

# Pass everything through to the exe; only non-flags are bottles. Enumerating
# the exe's flags here would silently swallow each new one as a bottle path.
exe_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -enough|-t)
            [ $# -ge 2 ] || { echo "usage: $0 [$1 SECONDS] [-show] [bottle ...]"; exit 1; }
            exe_args+=("$1" "$2"); shift 2 ;;
        -show)      exe_args+=("$1"); shift ;;
        *)          break ;;
    esac
done

select_bottles "$@"
BOTTLE="${bottles[0]}"

# The largest WMV in the bottle: a real movie rather than a UI sting, and the
# same choice on every machine with the same title installed, which `head -1`
# on directory order would not give. Not a hardcoded game path either -- the
# finding is about the DirectShow path, and a test that skips because one
# title is not installed reports green for a broken pipeline.
WMV_UNIX=$(find "$BOTTLE/drive_c" -iname '*.wmv' -size +1000k -exec stat -f '%z %N' {} + 2>/dev/null |
           sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$WMV_UNIX" ] || { echo "SKIP: no .wmv in $(basename "$BOTTLE")"; exit 0; }
# drive_c -> C:, forward slashes to backslashes. Pure shell: winepath would
# cost a whole extra Wine launch per file.
WMV_WIN='C:'"$(printf '%s' "${WMV_UNIX#"$BOTTLE/drive_c"}" | tr '/' '\\')"
echo "file: $(basename "$WMV_UNIX")"

if [ ! -f "$EXE" ] || [ "$SRC" -nt "$EXE" ]; then
    "$CC" -O2 -o "$EXE" "$SRC" -lole32 -loleaut32 -lstrmiids -luuid || exit 1
fi

# bottle_shellenv, not a hand-built env: it emits WINEMSYNC from the bottle's
# enhancedSync. Get that wrong against a running wineserver and every wine
# invocation dies in msync_init before main() -- which this test would report
# as the stall it is hunting.
eval "$(bottle_shellenv "$BOTTLE")"
export WINEDEBUG=-all

# timeout -k: a wine process wedged in the graph does not act on a plain
# SIGTERM, and the exe's own stall detector cannot fire if it hung before the
# poll loop (RenderFile itself can block).
timeout -k 10 240 wine "$EXE" "${exe_args[@]+"${exe_args[@]}"}" "$WMV_WIN"
rc=$?

case $rc in
    0)   echo "pass  clock advanced"; failures=0 ;;
    2)   echo "FAIL  clock stalled -- the game's symptom, without the game"; failures=1 ;;
    124|137) echo "FAIL  killed by timeout -- wedged before the poll loop could report"; failures=1 ;;
    *)   echo "FAIL  exit $rc"; failures=1 ;;
esac

echo
echo "$failures failed check(s)"
exit $failures
