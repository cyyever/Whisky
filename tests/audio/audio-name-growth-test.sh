#!/usr/bin/env bash
#
# audio-name-growth-test — do audio device names grow every time Wine looks?
#
#   tests/gstreamer/audio-name-growth-test.sh [rounds] [bottle ...]
#
# WHY. A bottle here had an unplugged monitor's HDMI endpoint stored as
#
#   "Speakers (Speakers (Speakers ( ... x97 ... (DELL S2817Q) ... )))"
#
# mmdevapi re-creates devices that are in the registry but no longer present,
# and seeded each from its stored device friendly name -- which
# MMDevice_Create treats as a driver id and decorates as "Speakers (%s)"
# before writing it back. Every enumeration added a layer, forever.
#
# NO DEVICE SWITCHING NEEDED, which is the point: the growth is per
# *enumeration*, not per plug event, so any process that opens the audio stack
# advances it. That makes the bug reproducible in seconds instead of by
# unplugging things a hundred times -- and it is why the count reached 97 on a
# machine nobody was deliberately stressing.
#
# The check is the registry, not the API: the corruption is what gets
# persisted, and an in-process enumeration would report the fresh string rather
# than the stored one.
#
# Exit: 0 names stable, 1 setup failure, 2 a name grew.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"
. "$PROJECT_DIR/scripts/lib/common.sh"

WHISKY_LIB="$INSTALL_DIR/Wine"
PROBE="$PROJECT_DIR/tests/audio/audio-device-name-test32.exe"
SRC="$PROJECT_DIR/tests/audio/audio-device-name-test.c"
CC=i686-w64-mingw32-gcc

ROUNDS=3
if [ $# -gt 0 ] && [ "$1" -eq "$1" ] 2>/dev/null; then ROUNDS="$1"; shift; fi
[ "$ROUNDS" -ge 1 ] || { echo "usage: $0 [rounds>=1] [bottle ...]"; exit 1; }

command -v "$CC" >/dev/null || { echo "SKIP: $CC not found (brew install mingw-w64)"; exit 0; }
command -v timeout >/dev/null || { echo "SKIP: timeout not found (brew install coreutils)"; exit 0; }
[ -x "$WHISKY_LIB/bin/wine" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }

select_bottles "$@"
BOTTLE="${bottles[0]}"
REG="$BOTTLE/system.reg"
[ -f "$REG" ] || { echo "SKIP: no system.reg in $(basename "$BOTTLE")"; exit 0; }

# The bug only touches devices that are in the registry and no longer on the
# system: present ones get their name rebuilt from the real driver id. A bottle
# without one is stable with or without the fix, so measuring it would report a
# pass that means nothing.
if ! grep -q 'dword:00000004' "$REG" 2>/dev/null; then
    echo "SKIP: $(basename "$BOTTLE") has no DEVICE_STATE_NOTPRESENT device --"
    echo "      nothing here can exhibit the growth (unplug a display or headset once)"
    exit 0
fi

if [ ! -f "$PROBE" ] || [ "$SRC" -nt "$PROBE" ]; then
    "$CC" -O2 -o "$PROBE" "$SRC" -ldsound -lole32 -loleaut32 -luuid -lpropsys || exit 1
fi

# Total length of every stored audio device name. One number, and it can only
# move one way if the bug is present.
name_bytes() {
    grep -oE '"\{(026E516E-B814-414B-83CD-856D6FEF4822|A45C254E-DF1C-4EFD-8020-67D146A850E0)\},(2|14)"="[^"]*"' \
        "$REG" 2>/dev/null | wc -c | tr -d ' '
}

# The registry is written by wineserver on shutdown, so each round has to be a
# complete server lifetime or the growth stays in memory and the file never
# changes -- the test would pass by never looking at the corruption.
# bare wineserver: bottle_shellenv has already put the right one on PATH with
# the right WINEPREFIX and WINEMSYNC. -k returns once the server has released
# its lock, which is after the registry save, so no sleep is needed.
flush() { wineserver -k 2>/dev/null; }

eval "$(bottle_shellenv "$BOTTLE")"
export WINEDEBUG=-all

flush
before=$(name_bytes)
echo "stored audio device names: $before bytes"
if [ "$before" -eq 0 ]; then
    echo "SKIP: found no stored device names to measure -- the registry format"
    echo "      this greps for has changed, so a stable count would mean nothing"
    exit 0
fi
now=$before

for i in $(seq 1 "$ROUNDS"); do
    if ! timeout -k 5 60 wine "$PROBE" >/dev/null 2>&1; then
        echo "FAIL  the enumeration probe did not complete on round $i --"
        echo "      nothing enumerated, so a stable byte count would prove nothing"
        echo "1 failed check(s)"
        exit 1
    fi
    flush
    now=$(name_bytes)
    printf "  round %d: %s bytes (%+d)\n" "$i" "$now" $((now - before))
done

echo
if [ "$now" -gt "$before" ]; then
    echo "FAIL  names grew by $((now - before)) bytes over $ROUNDS enumerations --"
    echo "      every look at the audio stack is decorating the stored names again"
    echo "      (patches/proton-wine/0037)"
    echo "1 failed check(s)"
    exit 2
fi
echo "pass  names stable across $ROUNDS enumerations"
echo "0 failed check(s)"
