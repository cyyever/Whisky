#!/bin/bash
# Build + run scripts/msync-close-during-wait-test.c inside a bottle under
# WINEMSYNC=1 (full msync, NO_ANON_AUTOEVENT unset) and WINEMSYNC=0 (server
# oracle), and print both so the STATUS and timing can be diffed. See the C
# file's header for what it probes (patch 0016 non-mutex close-during-wait).
#
# Usage: scripts/run-msync-close-test.sh [bottle] [iters]   (default: SteamProton 1)
#   env MSYNC_CHURN=1  also runs the shm-reuse churn thread.
set -euo pipefail

BOTTLE="${1:-SteamProton}"
ITERS="${2:-1}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/msync-close-during-wait-test.c"
OUT="$(dirname "$SRC")/msync-close-during-wait-test.exe"

CC="$(brew --prefix)/bin/x86_64-w64-mingw32-gcc"
[ -x "$CC" ] || { echo "ERROR: mingw x86_64 gcc not found ($CC)"; exit 1; }

echo "=== compiling $SRC ==="
"$CC" -O2 -o "$OUT" "$SRC"
echo "  built: $OUT"

WHISKYCMD=$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products/Debug/WhiskyCmd 2>/dev/null | head -1 || true)
[ -x "$WHISKYCMD" ] || { echo "ERROR: WhiskyCmd not found (make app)"; exit 1; }

run_mode() {
    local mode="$1"
    (
        eval "$("$WHISKYCMD" shellenv "$BOTTLE")"
        export WINEDEBUG="-all"
        unset WINEMSYNC_NO_ANON_AUTOEVENT
        export WINEMSYNC="$mode"
        exec wine64 "$OUT" "$ITERS" 2>&1
    ) | grep -aE 'RESULT|===' || true
}

echo ""
echo "########## WINEMSYNC=0 (server oracle) ##########"
run_mode 0
echo ""
echo "########## WINEMSYNC=1 (msync) ##########"
run_mode 1
echo ""
echo "(cleanup: wineserver -k in the bottle if not otherwise in use)"
