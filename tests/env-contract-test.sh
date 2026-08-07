#!/usr/bin/env bash
#
# env-contract-test — assert every environment variable Whisky sets is actually
# read by something we ship.
#
# WINEMSYNC_NO_ANON_AUTOEVENT was set in Wine.swift and in three scripts for
# months. Nothing ever read it: msync.c gates on _NO_EVENT, _NO_AUTOEVENT,
# _NO_MANUALEVENT, _NO_SEMAPHORE and _NO_MUTEX, and there is no anon/named
# distinction to gate on. Setting it was harmless; believing in it was not —
# test-msync.sh and run-msync-close-test.sh unset it to build their "full msync"
# arm, so both arms were the same configuration and every comparison that rested
# on the distinction measured nothing.
#
# A misspelled or invented variable is silent in every other way: no warning at
# launch, no error at runtime, and the behaviour it was supposed to select just
# never happens. This is the only place it shows up.
#
# Run: tests/env-contract-test.sh      # exit 0 = every variable has a reader
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE_SRC="$PROJECT_DIR/vendor/proton-wine"
SWIFT="$PROJECT_DIR/WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift"

[ -f "$SWIFT" ]     || { echo "ERROR: $SWIFT missing" >&2; exit 1; }
[ -d "$WINE_SRC" ]  || { echo "ERROR: proton-wine tree missing; run 'make proton' first" >&2; exit 1; }

# Variables Whisky puts in a bottle's environment, as "NAME": "VALUE" literals.
vars=$(grep -oE '"(WINE|PROTON|SDL|DXVK|DXMT|GST|MVK|MTL)[A-Z0-9_]*"[[:space:]]*:' "$SWIFT" |
       tr -d '":' | sort -u)

# Wine reads its own variables through getenv() in the unix side, and Proton's
# hacks add a few more; the patch series can introduce others. Search the whole
# tree rather than guessing which file owns which name.
#
# Names consumed by something other than proton-wine, so they legitimately have
# no reader in that tree. Each needs a reason, not just an entry. (A case rather
# than an associative array: macOS ships bash 3.2, which has none.)
external_reason() {
    case "$1" in
        SDL_JOYSTICK_MFI)            echo "SDL2, bundled by games — not Wine" ;;
        DYLD_FALLBACK_LIBRARY_PATH)  echo "dyld itself" ;;
        GST_DEBUG)                   echo "GStreamer" ;;
        *)                           echo "" ;;
    esac
}

fail=0
for v in $vars; do
    reason=$(external_reason "$v")
    if [ -n "$reason" ]; then
        printf 'SKIP %-32s read by %s\n' "$v" "$reason"
        continue
    fi
    # Only C sources count. Matching any file would accept a name that appears
    # solely in a CI config or a translated man page, which is exactly the kind
    # of false pass this test exists to prevent.
    hits=$(grep -rIl --exclude-dir=.git --include='*.c' --include='*.h' --include='*.m' \
                 -- "$v" "$WINE_SRC" 2>/dev/null | head -3)
    if [ -n "$hits" ]; then
        printf 'PASS %-32s read by %s\n' "$v" "$(basename "$(echo "$hits" | head -1)")"
    else
        printf 'FAIL %-32s nothing in proton-wine reads this\n' "$v"
        fail=$((fail + 1))
    fi
done

# The same trap in reverse: a script that unsets a variable to build a control
# arm proves nothing if the variable has no reader. Catch those too.
for f in "$PROJECT_DIR"/scripts/*.sh "$PROJECT_DIR"/scripts/lib/*.sh; do
    [ -f "$f" ] || continue
    while read -r v; do
        [ -n "$v" ] || continue
        if ! grep -rIlq --exclude-dir=.git --include='*.c' --include='*.h' \
                  -- "$v" "$WINE_SRC" 2>/dev/null; then
            printf 'FAIL %-32s unset by %s to form a control arm, but has no reader\n' \
                   "$v" "$(basename "$f")"
            fail=$((fail + 1))
        fi
    done < <(grep -oE '^\s*unset (WINE|PROTON)[A-Z0-9_]*' "$f" 2>/dev/null | awk '{print $2}' | sort -u)
done

echo
if [ "$fail" -ne 0 ]; then
    echo "FAILED ($fail variable(s) with no reader)"
    echo
    echo "Either the name is wrong, or the patch that consumed it was dropped."
    echo "Setting a variable nothing reads is silent — the behaviour it selects"
    echo "simply never happens, and any A/B test built on it compares two"
    echo "identical configurations."
    exit 1
fi
echo "OK (every variable has a reader)"
