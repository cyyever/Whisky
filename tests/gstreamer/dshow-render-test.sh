#!/usr/bin/env bash
#
# dshow-render-test — can a DirectShow graph render a WMV, in BOTH bitnesses?
#
#   tests/gstreamer/dshow-render-test.sh [bottle]
#
# WHY. gstreamer-test.sh proves a WMV decodes: IWMSyncReader is a pull API,
# Open() then GetNextSample() hands frames back in memory, and no renderer or
# window is involved. It passed green while SSFIV froze on its first movie, the
# NVIDIA logo -- because the game does not use that API. Its stacks go
# qasf -> wmvcore -> winegstreamer, i.e. DirectShow, and the failure is in the
# half decoding never touches:
#
#     thread A: RenderFile -> FilterGraph2_Render -> autoplug
#               -> NtWaitForSingleObject          (waiting for the filter)
#     thread B: message_thread_run -> moniker_BindToObject -> CoCreateInstance
#               -> DSCF_CreateInstance -> video_renderer_default_create
#               -> vmr7_create -> video_window_create_window
#               -> CreateWindowExW -> NtUserCreateWindowEx     (never returns)
#
# quartz's message thread blocks creating the video renderer's window, and
# autoplug waits on it forever.
#
# Both bitnesses, because that is the whole finding: the identical graph over
# the identical file completes in a 64-bit process and hangs in a 32-bit one.
# A single-bitness test would have called this green. Steam is 32-bit and so is
# SSFIV, so the 32-bit arm is the one that matches the game.
#
# Exit code is the number of failed checks.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"
. "$PROJECT_DIR/scripts/lib/common.sh"

WHISKY_LIB="$INSTALL_DIR/Wine"
SRC="$PROJECT_DIR/tests/gstreamer/wmv-render-test.c"
EXE64="$PROJECT_DIR/tests/gstreamer/wmv-render-test.exe"
EXE32="$PROJECT_DIR/tests/gstreamer/wmv-render-test32.exe"
PLAY_SECONDS=20

failures=0
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "pass  $*"; }

[ -x "$WHISKY_LIB/bin/wine64" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }
for cc in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
    command -v "$cc" >/dev/null || { echo "SKIP: $cc not found (brew install mingw-w64)"; exit 0; }
done
command -v timeout >/dev/null || { echo "SKIP: timeout not found (brew install coreutils)"; exit 0; }

select_bottles "$@"
BOTTLE="${bottles[0]}"

# Any WMV in the bottle. Not a hardcoded game path: the finding is about the
# DirectShow path, not about one file, and a test that silently skips because
# one title is not installed reports green for a broken renderer.
WMV_UNIX=$(find "$BOTTLE/drive_c" -iname '*.wmv' -size +100k 2>/dev/null | head -1)
[ -n "$WMV_UNIX" ] || { echo "SKIP: no .wmv in $(basename "$BOTTLE")"; exit 0; }
# drive_c -> C:, and forward slashes to backslashes.
WMV_WIN='C:'"$(printf '%s' "${WMV_UNIX#"$BOTTLE/drive_c"}" | tr '/' '\\')"
echo "file: $(basename "$WMV_UNIX")"

for bits in 64 32; do
    if [ "$bits" = 32 ]; then cc=i686-w64-mingw32-gcc; exe="$EXE32"; else cc=x86_64-w64-mingw32-gcc; exe="$EXE64"; fi
    if [ ! -f "$exe" ] || [ "$SRC" -nt "$exe" ]; then
        "$cc" -O2 -o "$exe" "$SRC" -lole32 -loleaut32 -lstrmiids -luuid || exit 1
    fi
done

# bottle_shellenv, not a hand-built `env -i`: it emits WINEMSYNC from the
# bottle's enhancedSync. Get that wrong against a running wineserver and every
# wine invocation dies in msync_init before main(), which looks exactly like the
# hang this test is looking for.
eval "$(bottle_shellenv "$BOTTLE")"
export WINEDEBUG=-all

for bits in 64 32; do
    exe="$EXE64"; [ "$bits" = 32 ] && exe="$EXE32"
    echo
    echo "=== ${bits}-bit DirectShow RenderFile + Run ==="
    # -k and </dev/null so the timeout is authoritative: a wine64 wedged in
    # NtUserCreateWindowEx does not act on a plain SIGTERM, and it would hold
    # the pipe open with the command substitution blocking behind it.
    out=$( timeout -k 10 $((PLAY_SECONDS + 40)) "$WHISKY_LIB/bin/wine64" \
        "$exe" "$WMV_WIN" "$PLAY_SECONDS" </dev/null 2>/dev/null )
    rc=$?
    echo "$out" | grep -vE "machine-id|lsteamclient" | sed 's/^/    /'
    if [ "$rc" -eq 0 ]; then
        pass "${bits}-bit rendered"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        fail "${bits}-bit hung"
        echo "      No output at all means it never returned from RenderFile."
        echo "      Attach winedbg and expect autoplug waiting on a message thread"
        echo "      stuck in NtUserCreateWindowEx (see the header)."
    else
        fail "${bits}-bit failed (rc=$rc)"
    fi
done

echo
echo "$failures failed check(s)"
exit "$failures"
