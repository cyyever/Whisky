#!/bin/bash
set -euo pipefail

# Validate the macOS msync fast-sync backend against Wine's generic NT-sync
# conformance tests. msync (dlls/ntdll/unix/msync.c) transparently backs the NT
# sync primitives, so it has no tests of its own — we run the ntdll/kernel32
# "sync" subtests under WINEMSYNC=1 (msync path) and WINEMSYNC=0 (wineserver
# baseline) and diff. A subtest that PASSES on the server baseline but FAILS
# under msync is a real msync conformance bug; a subtest that fails under BOTH
# is a pre-existing (non-msync) issue and is filtered out.
#
# Requires the test PEs built by scripts/build-msync-tests.sh.
#
# Usage: scripts/test-msync.sh [--guard-malloc] [bottle-name]   (default: SteamProton)
#
# --guard-malloc runs the test PEs under macOS Guard Malloc (libgmalloc) to
# catch heap use-after-free / overflow in msync's unix-side (libc) allocations
# — the memory-safety complement to the conformance diff. ASan won't run under
# Rosetta+Wine, but libgmalloc (a fat dylib with an x86_64 slice) DYLD_INSERTs
# into the translated wine process fine. It is much slower and RAM-hungry (a
# guard page per allocation), so it is opt-in.
#
# NOTE: these sync tests are partly timing-sensitive, so a run-to-run diff can
# carry a little flaky/timing noise on top of genuine failures — eyeball the
# per-test .diff files this prints paths to. todo_wine expectations are handled
# by the framework and do not count as failures.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Args: [--guard-malloc] [bottle-name], order-independent.
GUARD_MALLOC=0
BOTTLE=""
for arg in "$@"; do
    case "$arg" in
        --guard-malloc) GUARD_MALLOC=1 ;;
        -*) echo "ERROR: unknown flag '$arg'" >&2; exit 2 ;;
        *) BOTTLE="$arg" ;;
    esac
done
BOTTLE="${BOTTLE:-SteamProton}"

WINE_SRC="$PROJECT_DIR/vendor/proton-wine"
BUILD_DIR="$WINE_SRC/build"

# Locate WhiskyCmd (Xcode DerivedData path has a random suffix).
WHISKYCMD=$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products/Debug/WhiskyCmd 2>/dev/null | head -1 || true)
if [ -z "$WHISKYCMD" ] || [ ! -x "$WHISKYCMD" ]; then
    echo "ERROR: WhiskyCmd not found. Build the app (make app) first." >&2
    exit 1
fi

# Resolve the two test PEs. build-msync-tests.sh may place them directly in the
# tests dir or under an <arch>-windows/ subdir (multi-arch build) — prefer the
# x86_64 build (wine64), else take whatever exists.
find_exe() {
    local dir="$1" name="$2" hit
    hit=$(find "$BUILD_DIR/$dir" -path '*x86_64-windows*' -name "$name" 2>/dev/null | head -1 || true)
    [ -z "$hit" ] && hit=$(find "$BUILD_DIR/$dir" -name "$name" 2>/dev/null | head -1 || true)
    printf '%s' "$hit"
}

NTDLL_EXE=$(find_exe "dlls/ntdll/tests" "ntdll_test.exe")
KERNEL32_EXE=$(find_exe "dlls/kernel32/tests" "kernel32_test.exe")

if [ -z "$NTDLL_EXE" ] || [ -z "$KERNEL32_EXE" ]; then
    echo "ERROR: sync test PEs not found under $BUILD_DIR." >&2
    echo "       Build them first:  scripts/build-msync-tests.sh" >&2
    [ -z "$NTDLL_EXE" ]    && echo "       missing: ntdll_test.exe" >&2
    [ -z "$KERNEL32_EXE" ] && echo "       missing: kernel32_test.exe" >&2
    exit 1
fi

# Verify the bottle exists (shellenv errors otherwise).
if ! "$WHISKYCMD" shellenv "$BOTTLE" >/dev/null 2>&1; then
    echo "ERROR: bottle '$BOTTLE' not found. Available bottles:" >&2
    "$WHISKYCMD" list >&2 || true
    exit 1
fi

OUTDIR=$(mktemp -d -t msync-test)
echo "=== msync conformance: bottle '$BOTTLE' ==="
[ "$GUARD_MALLOC" = "1" ] && echo "  Guard Malloc      : ON (libgmalloc DYLD_INSERT)"
echo "  ntdll_test.exe    : $NTDLL_EXE"
echo "  kernel32_test.exe : $KERNEL32_EXE"
echo "  output dir        : $OUTDIR"
echo ""

# Run one test PE once, with WINEMSYNC forced to the given value. Writes
# combined stdout+stderr to $outfile and returns wine's exit code (= the
# number of failed assertions in the Wine test framework).
#
# For the msync (WINEMSYNC=1) run we also UNSET WINEMSYNC_NO_ANON_AUTOEVENT so
# the FULL msync path is exercised — the shipping bottle sets that mask to route
# anonymous auto-reset events back to wineserver sync, which would hide msync
# bugs on exactly those objects and weaken the conformance signal.
run_one() {
    local exe="$1" mode="$2" outfile="$3" rc
    # IMPORTANT: capture through a PIPE (| cat), not a direct `> file` redirect.
    # Wine fully-buffers the test PE's stdout when it is a regular DISK file, and
    # the sync test's child processes exit without flushing, so a file redirect
    # silently drops ALL test output (only wine startup noise survives). A pipe
    # is FILE_TYPE_PIPE — written through and captured intact.
    set +e
    (
        eval "$("$WHISKYCMD" shellenv "$BOTTLE")"
        export WINEDEBUG="-all"
        unset WINEMSYNC_NO_ANON_AUTOEVENT
        if [ "$GUARD_MALLOC" = "1" ]; then
            # Guard Malloc guards the tail of each allocation (overflow trap); it
            # DYLD_INSERTs ahead of the shellenv-provided DYLD_FALLBACK_LIBRARY_PATH.
            export DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib
            export MALLOC_STRICT_SIZE=1
        fi
        if [ "$mode" = "msync" ]; then
            export WINEMSYNC=1
        else
            export WINEMSYNC=0
        fi
        # exec the real wine64 binary (on PATH from shellenv), not the shell
        # alias — aliases don't expand in this non-interactive subshell — so the
        # subshell's exit status IS wine's (= the test framework's failure count).
        exec wine64 "$exe" sync 2>&1
    ) | cat > "$outfile"
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

# Distill the set of failing assertion locations (file:line) from a run. Wine
# prints "sync.c:1234: Test failed: ..." on failure and "... Test succeeded
# inside todo block" for an unexpected todo pass (also a real failure). We key
# on the file:line prefix so run-to-run message/value churn doesn't create
# spurious diffs. todo_wine expectations ("Test marked todo") are NOT failures
# and are excluded.
fail_locs() {
    local f="$1"
    # grep exits 1 when a run is clean (no failures) — tolerate it so this
    # command substitution doesn't trip `set -e`/pipefail.
    { grep -aE 'Test failed|Test succeeded inside todo' "$f" 2>/dev/null || true; } \
        | sed -E 's/^([A-Za-z0-9_.]+:[0-9]+):.*/\1/' \
        | sort -u
}

overall_bugs=0

run_pair() {
    local exe="$1" label="$2"
    local msync_out="$OUTDIR/${label}.msync.log"
    local server_out="$OUTDIR/${label}.server.log"

    echo "=== $label: running server-sync baseline (WINEMSYNC=0) ==="
    local server_rc=0
    run_one "$exe" server "$server_out" || server_rc=$?
    echo "=== $label: running msync path (WINEMSYNC=1) ==="
    local msync_rc=0
    run_one "$exe" msync "$msync_out" || msync_rc=$?

    echo "  WINEMSYNC=0 (server) failures: $server_rc   -> $server_out"
    echo "  WINEMSYNC=1 (msync)  failures: $msync_rc   -> $msync_out"

    # Full unified diff for a human to eyeball timing noise.
    local diff_out="$OUTDIR/${label}.diff"
    diff -u "$server_out" "$msync_out" > "$diff_out" 2>&1 || true

    # msync-only failures = fail under WINEMSYNC=1 but NOT under WINEMSYNC=0.
    local server_fl msync_fl only
    server_fl=$(fail_locs "$server_out")
    msync_fl=$(fail_locs "$msync_out")
    only=$(comm -13 <(printf '%s\n' "$server_fl") <(printf '%s\n' "$msync_fl") | sed '/^$/d')

    if [ -n "$only" ]; then
        local n
        n=$(printf '%s\n' "$only" | grep -c . || true)
        echo "  >>> $n assertion location(s) FAIL under msync but PASS on server (candidate msync bugs):"
        printf '%s\n' "$only" | sed 's/^/        /'
        overall_bugs=$((overall_bugs + n))
    else
        echo "  OK: no location fails under msync that passes on server."
    fi
    echo "  full diff: $diff_out"
    echo ""
}

run_pair "$NTDLL_EXE" "ntdll"
run_pair "$KERNEL32_EXE" "kernel32"

echo "=== Summary ==="
if [ "$overall_bugs" -gt 0 ]; then
    echo "Found $overall_bugs candidate msync-only failure location(s) across both tests."
    echo "These pass on wineserver sync but fail under msync — likely real msync bugs."
    echo "Eyeball the .diff files (some sync subtests are timing-sensitive)."
else
    echo "No msync-only failures: every assertion that fails under WINEMSYNC=1"
    echo "also fails under WINEMSYNC=0 (so nothing points at msync specifically)."
fi
echo "Logs + diffs: $OUTDIR"
echo ""
echo "NOTE: running these may have started a wineserver for the bottle; if you"
echo "are not also running Steam in it, clean up with:  wineserver -k  (with"
echo "WINEPREFIX set to the bottle) — or via the bottle's shellenv."
