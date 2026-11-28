#!/usr/bin/env bash
#
# multi-render-test.sh — minimal reproducer for DirectShow FilterGraph reuse stall.
#
#   tests/gstreamer/multi-render-test.sh [bottle]
#
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"
. "$PROJECT_DIR/scripts/lib/common.sh"

WHISKY_LIB="$INSTALL_DIR/Wine"
SRC="$PROJECT_DIR/tests/gstreamer/wmv-multi-render-test.c"
EXE32="$PROJECT_DIR/tests/gstreamer/wmv-multi-render-test32.exe"

[ -x "$WHISKY_LIB/bin/wine" ] || { echo "SKIP: no Wine at $WHISKY_LIB"; exit 0; }
command -v i686-w64-mingw32-gcc >/dev/null || { echo "SKIP: i686-w64-mingw32-gcc not found"; exit 0; }
command -v timeout >/dev/null || { echo "SKIP: timeout not found"; exit 0; }

select_bottles "$@"
BOTTLE="${bottles[0]}"

WMVS=()
while IFS= read -r line; do
    WMVS+=("$line")
done < <(find "$BOTTLE/drive_c" -iname '*.wmv' -size +100k 2>/dev/null | head -n 2)
[ ${#WMVS[@]} -ge 2 ] || { echo "SKIP: need >=2 .wmv files in $(basename "$BOTTLE")"; exit 0; }

W1='C:'"$(printf '%s' "${WMVS[0]#"$BOTTLE/drive_c"}" | tr '/' '\\')"
W2='C:'"$(printf '%s' "${WMVS[1]#"$BOTTLE/drive_c"}" | tr '/' '\\')"
echo "clip1: $(basename "${WMVS[0]}")"
echo "clip2: $(basename "${WMVS[1]}")"

if [ ! -f "$EXE32" ] || [ "$SRC" -nt "$EXE32" ]; then
    i686-w64-mingw32-gcc -O2 -Wall -Wextra -o "$EXE32" "$SRC" -lole32 -loleaut32 -lstrmiids -luuid || exit 1
fi

eval "$(bottle_shellenv "$BOTTLE")"
export WINEDEBUG=-all

timeout -k 3 45 "$WHISKY_LIB/bin/wine" "$EXE32" "$W1" "$W2" </dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "PASS: 3 sequential clips on reused FilterGraph"
else
    echo "FAIL: FilterGraph reuse stalled/hung (rc=$rc)"
fi
exit "$rc"
