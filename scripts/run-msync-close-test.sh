#!/bin/bash
# Build + run scripts/msync-close-during-wait-test.c inside a bottle under
# WINEMSYNC=1 (full msync, NO_ANON_AUTOEVENT unset) and WINEMSYNC=0 (server
# oracle), and print both so the STATUS and timing can be diffed. See the C
# file's header for what it probes (patch 0016 non-mutex close-during-wait).
#
# Usage: scripts/run-msync-close-test.sh <bottle-dir> [iters]   (default iters: 1)
#   <bottle-dir> is a bottle's WINEPREFIX directory, e.g.
#   ~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/<UUID>
#   env MSYNC_CHURN=1  also runs the shm-reuse churn thread.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BOTTLE="${1:-}"
ITERS="${2:-1}"
if [ -z "$BOTTLE" ] || [ ! -d "$BOTTLE" ]; then
    echo "ERROR: bottle directory not found: '$BOTTLE'" >&2
    echo "       Pass a bottle's WINEPREFIX dir, e.g." >&2
    echo "       ~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/<UUID>" >&2
    exit 1
fi
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/msync-close-during-wait-test.c"
OUT="$(dirname "$SRC")/msync-close-during-wait-test.exe"

CC="$(brew --prefix)/bin/x86_64-w64-mingw32-gcc"
[ -x "$CC" ] || { echo "ERROR: mingw x86_64 gcc not found ($CC)"; exit 1; }

echo "=== compiling $SRC ==="
"$CC" -O2 -o "$OUT" "$SRC"
echo "  built: $OUT"

run_mode() {
    local mode="$1"
    (
        eval "$(bottle_shellenv "$BOTTLE")"
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
