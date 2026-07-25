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
# SDL2/LDFLAGS/CFLAGS, arch -x86_64) mirrors build-proton-x86.sh's configure
# block exactly, MINUS --disable-tests — kept as a duplicated block on purpose
# so this diagnostic script can never destabilize the shipping build script.

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

X86_PREFIX=$(arch -x86_64 "$X86_BREW" --prefix)
ARM_BREW_PREFIX="$(brew --prefix)"
# bison is keg-only (macOS ships an old one), so its keg bin must be on PATH.
CLEAN_PATH="$ARM_BREW_PREFIX/opt/bison/bin:$ARM_BREW_PREFIX/bin:$X86_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CC_CMD="gcc"
CXX_CMD="g++"
if whisky_ccache_on; then
    echo "=== Using ccache (WHISKY_CCACHE=0 to disable) ==="
    CC_CMD="ccache gcc"
    CXX_CMD="ccache g++"
fi

cd "$BUILD_DIR"

# Reconfigure the existing build tree with tests ENABLED. This is the SAME
# configure invocation build-proton-x86.sh uses, MINUS --disable-tests, so it
# only flips the test dirs from DISABLED_SUBDIRS into real subdirs (adding the
# *_test.exe rules) — it does not change any main-build object. The first run
# after a --disable-tests build re-runs configure once (a minute or two); the
# actual Wine objects are all cached, so nothing heavy recompiles.
echo "=== Reconfiguring build tree WITH tests (minus --disable-tests) ==="
arch -x86_64 env -i \
    HOME="$HOME" \
    PATH="$CLEAN_PATH" \
    CC="$CC_CMD" \
    CXX="$CXX_CMD" \
    PKG_CONFIG="$ARM_BREW_PREFIX/bin/pkg-config" \
    PKG_CONFIG_PATH="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig:$PROJECT_DIR/vendor/ffmpeg-x86/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$X86_PREFIX/lib/pkgconfig:$X86_PREFIX/share/pkgconfig:$PROJECT_DIR/vendor/ffmpeg-x86/lib/pkgconfig" \
    SDL2_CFLAGS="-I$X86_PREFIX/include/SDL2 -D_THREAD_SAFE" \
    SDL2_LIBS="-L$X86_PREFIX/lib -lSDL2" \
    LDFLAGS="-L$X86_PREFIX/lib -L$X86_PREFIX/opt/molten-vk/lib" \
    CFLAGS="-I$X86_PREFIX/include -I$X86_PREFIX/opt/freetype/include/freetype2 -I$X86_PREFIX/opt/molten-vk/include" \
    CPPFLAGS="-I$X86_PREFIX/include -I$X86_PREFIX/opt/freetype/include/freetype2 -I$X86_PREFIX/opt/molten-vk/include" \
    ../configure \
        --enable-archs=i386,x86_64 \
        --with-vulkan \
        --without-gstreamer \
        --disable-win16 \
        --without-x \
        --without-cups \
        --without-krb5 \
        --without-gssapi \
        --without-pcap \
        --without-pcsclite

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
found_any=0
for name in \
    "dlls/ntdll/tests/ntdll_test.exe" \
    "dlls/kernel32/tests/kernel32_test.exe"; do
    base_dir="$BUILD_DIR/$(dirname "$name")"
    exe_name="$(basename "$name")"
    hits=$(find "$base_dir" -name "$exe_name" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "$hits" | while read -r h; do echo "  built: $h"; done
        found_any=1
    else
        echo "  MISSING: $exe_name under $base_dir" >&2
    fi
done
echo ""
if [ "$found_any" = 1 ]; then
    echo "Next: scripts/test-msync.sh [bottle]  (runs sync tests, WINEMSYNC=1 vs =0)"
else
    echo "ERROR: no test PEs were produced." >&2
    exit 1
fi
