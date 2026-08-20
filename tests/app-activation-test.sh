#!/usr/bin/env bash
#
# app-activation-test — switch away from a Wine window and see whether the
# program is ever told.
#
#   tests/app-activation-test.sh [seconds] [bottle ...]
#
# Switching AWAY is done here by activating Finder, a plain Apple Event that
# needs no permission. Handing the probe the foreground in the first place
# does: macOS will not let a process launched from a shell take the front, and
# `System Events ... set frontmost` needs Accessibility. So the one thing asked
# of a human is a click on the probe window, and another to come back.
#
# It matters that this is checked rather than assumed. The first version of
# this runner switched blind and reported a confident FAIL for a Wine process
# that had never been the active application, so nothing had been measured and
# no APP_DEACTIVATED had ever been sent.
#
# Its predecessor tests/controller/input-after-switch-test.c asked a human to
# cmd-tab and printed SKIP on no WM_ACTIVATEAPP, reading "never told" as "never
# switched". With the runner switching, that same silence is the failure.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"
. "$PROJECT_DIR/scripts/lib/common.sh"

WHISKY_LIB="$INSTALL_DIR/Wine"
SRC="$PROJECT_DIR/tests/app-activation-test.c"
EXE="$PROJECT_DIR/tests/app-activation-test32.exe"

# 32-bit, because SSFIV is.
CC=i686-w64-mingw32-gcc
command -v "$CC" >/dev/null || { echo "SKIP: $CC not found (brew install mingw-w64)"; exit 0; }
command -v osascript >/dev/null || { echo "SKIP: osascript not found"; exit 0; }
[ -x "$WHISKY_LIB/bin/wine" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }

SECONDS_ARG=90
if [ $# -gt 0 ] && [ "$1" -eq "$1" ] 2>/dev/null; then SECONDS_ARG="$1"; shift; fi

select_bottles "$@"
BOTTLE="${bottles[0]}"

if [ ! -f "$EXE" ] || [ "$SRC" -nt "$EXE" ]; then
    "$CC" -O2 -o "$EXE" "$SRC" -lgdi32 -luser32 || exit 1
fi

eval "$(bottle_shellenv "$BOTTLE")"
export WINEDEBUG=-all

OUT=$(mktemp -t appactivation)
trap 'rm -f "$OUT"' EXIT

echo "bottle: $(basename "$BOTTLE")"
echo

wine "$EXE" "$SECONDS_ARG" > "$OUT" 2>&1 &
WINE_PID=$!

# Until READY there is nothing to switch away from.
for _ in $(seq 1 300); do
    grep -q "READY" "$OUT" 2>/dev/null && break
    kill -0 "$WINE_PID" 2>/dev/null || break
    sleep 0.1
done
if ! grep -q "READY" "$OUT" 2>/dev/null; then
    wait "$WINE_PID"; cat "$OUT"
    echo "SKIP: the probe never took the foreground"
    exit 0
fi

# The frontmost application, by name. Not GetForegroundWindow(): that is
# Wine's own idea of the foreground, which is exactly what is under test.
front_name() {
    local asn
    asn=$(lsappinfo front 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -n "$asn" ] || return 0
    lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | head -1
}

wait_front() {
    local want=$1 n=$2
    for _ in $(seq 1 "$n"); do
        [ "$(front_name)" = "$want" ] && return 0
        sleep 0.2
    done
    return 1
}

echo
echo "==> click the 'app-activation-test' window to give it the foreground"
if ! wait_front wine 150; then
    kill "$WINE_PID" 2>/dev/null; wait "$WINE_PID" 2>/dev/null
    echo "SKIP: the probe never became the active application (front: $(front_name))"
    exit 0
fi
echo "    probe is the active application"

echo "==> activating Finder"
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
wait_front Finder 50 || { echo "SKIP: could not switch away"; kill "$WINE_PID" 2>/dev/null; exit 0; }
sleep 3

echo "==> click the probe window again to come back"
wait_front wine 150 || echo "    (never came back; the return trip is not asserted on)"
sleep 2

wait "$WINE_PID"
rc=$?
cat "$OUT"

echo
case $rc in
    0) echo "0 failed check(s)" ;;
    2) echo "1 failed check(s) — switched away, program never told" ;;
    3) echo "1 failed check(s) — foreground moved but no WM_ACTIVATEAPP" ;;
    *) echo "1 failed check(s) — exit $rc" ;;
esac
exit $((rc == 0 ? 0 : 1))
