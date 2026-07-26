#!/bin/bash
set -e

# Build ONLY the two sync-conformance test PEs used to validate the macOS msync
# fast-sync backend:
#
#   dlls/ntdll/tests/ntdll_test.exe      (dlls/ntdll/tests/sync.c   -> "sync" subtest)
#   dlls/kernel32/tests/kernel32_test.exe (dlls/kernel32/tests/sync.c -> "sync" subtest)
#
# msync (dlls/ntdll/unix/msync.c) is a *transparent* backend for the NT sync
# primitives (NtCreateEvent / NtWaitForMultipleObjects / mutexes / semaphores),
# so it has no dedicated tests — it is validated by running Wine's generic sync
# conformance tests under WINEMSYNC=1 vs WINEMSYNC=0. `scripts/test-msync.sh`
# does the running/diffing; this script just produces the PEs.
#
# The shipping build (scripts/build-proton-x86.sh) configures with
# --disable-tests, so the test dirs are in DISABLED_SUBDIRS and no
# *_test.exe rule exists in the build graph. This script RE-CONFIGURES the
# EXISTING, already-compiled build tree (vendor/proton-wine/build) WITHOUT
# --disable-tests, then builds just the two test targets. Because all of Wine
# is already compiled, `make dlls/ntdll/tests/all dlls/kernel32/tests/all`
# only links the two test PEs (fast) — it does NOT rebuild Wine and does NOT
# reinstall Libraries/Wine. The next `make proton` re-runs configure with
# --disable-tests, so this self-corrects (the shipping install is untouched
# either way — this script never runs `make install`).
#
# Env/toolchain (env -i clean room, CLEAN_PATH, X86_PREFIX, PKG_CONFIG_PATH,
# SDL2/LDFLAGS/CFLAGS, arch -x86_64) is the SAME as the shipping
# build-proton-x86.sh, MINUS --disable-tests. That shared block lives in
# wine_configure (lib/common.sh) so the two can never drift; the ONLY divergence
# is the extra flag (proton passes --disable-tests, this script passes none), and
# it never mutates the shipping build's tree — this script reuses build/ read-only
# apart from the reconfigure + linking the two test PEs, and never `make install`s.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
WINE_SRC="$PROJECT_DIR/vendor/proton-wine"
BUILD_DIR="$WINE_SRC/build"

echo "=== Building msync sync-conformance test PEs (reusing $BUILD_DIR) ==="

if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/config.status" ]; then
    echo "ERROR: no configured Wine build at $BUILD_DIR." >&2
    echo "       Run 'make proton' first (this script reuses that build tree)." >&2
    exit 1
fi

if [ ! -f "$X86_BREW" ]; then
    echo "ERROR: x86_64 Homebrew not found. Run scripts/setup-x86-brew.sh first." >&2
    exit 1
fi

# CLEAN_PATH is also needed for the make step below (env -i wipes PATH).
CLEAN_PATH="$(wine_clean_path)"

# Reconfigure the existing build tree with tests ENABLED. wine_configure
# (lib/common.sh) runs the SAME env/toolchain + configure flags as the shipping
# build-proton-x86.sh, MINUS --disable-tests (that script's only extra flag), so
# this only flips the test dirs from DISABLED_SUBDIRS into real subdirs (adding
# the *_test.exe rules) — it does not change any main-build object. The first run
# after a --disable-tests build re-runs configure once (a minute or two); the
# actual Wine objects are all cached, so nothing heavy recompiles.
echo "=== Reconfiguring build tree WITH tests (minus --disable-tests) ==="
wine_configure "$BUILD_DIR"

NCPU=$(whisky_ncpu)
echo "=== Building the two sync test PEs with $NCPU cores ==="
# Wine's non-recursive Makefile exposes per-directory phony targets as
# "<dir>/all"; building those links only the two test exes + their (already
# built) deps — NOT the full ~340-dir test suite.
arch -x86_64 env -i \
    HOME="$HOME" \
    PATH="$CLEAN_PATH" \
    make -j"$NCPU" dlls/ntdll/tests/all dlls/kernel32/tests/all

echo ""
echo "=== Done ==="
# Multi-arch Wine (--enable-archs=i386,x86_64) emits the PE under an
# <arch>-windows/ subdir; older layouts drop it directly in the tests dir.
# Report every ntdll_test.exe / kernel32_test.exe found under the two dirs.
# test-msync.sh needs BOTH PEs, so require both — reporting success when only
# one built would just make test-msync.sh abort later on the missing one.
missing=0
for name in \
    "dlls/ntdll/tests/ntdll_test.exe" \
    "dlls/kernel32/tests/kernel32_test.exe"; do
    base_dir="$BUILD_DIR/$(dirname "$name")"
    exe_name="$(basename "$name")"
    hits=$(find "$base_dir" -name "$exe_name" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "$hits" | while read -r h; do echo "  built: $h"; done
    else
        echo "  MISSING: $exe_name under $base_dir" >&2
        missing=$((missing + 1))
    fi
done
echo ""
if [ "$missing" -eq 0 ]; then
    echo "Next: scripts/test-msync.sh [bottle]  (runs sync tests, WINEMSYNC=1 vs =0)"
else
    echo "ERROR: $missing test PE(s) missing — both are required." >&2
    exit 1
fi
