#!/bin/bash
set -euo pipefail

# Verify patches/proton-wine/0017-macos-metal-builtin-dll-loadorder.patch: the
# D3D/Vulkan stack must default to *builtin* in Wine's load order, with NO
# WINEDLLOVERRIDES set. Cross-compiles loadorder_probe.exe and, for each module,
# LoadLibrary's it under WINEDEBUG=+module (the channel loadorder.c logs on) and
# asserts get_load_order() chose builtin. Re-run after `make proton` (or a
# proton/base bump) to catch the patch being dropped or superseded — the app sets
# no override, so a regression breaks Steam CEF (its app-dir vulkan-1.dll) and D3D9.
#
# One DLL per process isolates mapping failures. The installed DXVK and
# vkd3d-proton DLLs carry the Wine builtin signature, so wineboot mirrors them
# into a fresh prefix. Also exercise stale registry overrides and explicit
# environment overrides for the optional D3D12 pair.
#
# On top of that, we drop a tiny placeholder <dll> next to the probe exe (first on
# the search path) so the test also proves the *stronger* property: builtin wins
# even when a native copy sits in the application directory — exactly what keeps
# Steam CEF's own bundled vulkan-1.dll from winning. It also makes the test robust
# if DXVK happens to be unsigned. The placeholder is never loaded: builtin
# resolution pulls the real module from Wine's lib dir.
#
# Uses a throwaway prefix (.build/run.*/prefix) so a bottle's own — or stale, pre-0017 —
# DllOverrides can't mask the load-order DEFAULT this is testing.
#
# Usage: tests/loadorder/run.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
WINE="$INSTALL_DIR/Wine/bin/wine64"

[ -x "$WINE" ] || { echo "ERROR: Wine not found at $WINE (run make proton)"; exit 1; }
export DYLD_FALLBACK_LIBRARY_PATH="$INSTALL_DIR/Wine/lib"

export PATH="/opt/homebrew/bin:/usr/bin:/bin"
command -v x86_64-w64-mingw32-gcc >/dev/null || {
    echo "ERROR: mingw-w64 not found (brew install mingw-w64)"; exit 1; }

mkdir -p "$SCRIPT_DIR/.build"
WORK=$(mktemp -d "$SCRIPT_DIR/.build/run.XXXXXX")
EXE="$WORK/loadorder_probe.exe"
x86_64-w64-mingw32-gcc "$SCRIPT_DIR/loadorder_probe.c" -o "$EXE"

# Tiny placeholder PE, copied under each module's name into the probe dir so the
# loader always *finds* a file and reaches get_load_order (see header). It is a
# native app-dir copy that builtin resolution must override — never loaded itself.
STUB="$WORK/stub.dll"
echo '__declspec(dllexport) int stub(void){return 0;}' \
    | x86_64-w64-mingw32-gcc -shared -o "$STUB" -xc -

# Throwaway prefix — no DllOverrides, so only the load-order default decides.
export WINEPREFIX="$WORK/prefix"
unset WINEDLLOVERRIDES WINEARCH WINEMSYNC WINEESYNC WINEFSYNC
cleanup() {
    timeout 15 "$INSTALL_DIR/Wine/bin/wineserver" -k >/dev/null 2>&1 || true
    if timeout 15 "$INSTALL_DIR/Wine/bin/wineserver" -w >/dev/null 2>&1; then
        rm -rf "$WINEPREFIX"
    else
        echo "Keeping $WINEPREFIX: wineserver did not stop."
    fi
}
trap cleanup EXIT
echo "=== creating scratch prefix ==="
# Skip the Mono/Gecko prompts, which block wineboot when no one is at the display.
if ! WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" timeout 180 "$WINE" wineboot --init > "$WORK/wineboot.log" 2>&1; then
    cat "$WORK/wineboot.log"
    exit 1
fi

pass=0 fail=0
unset WINEDLLOVERRIDES
for d in d3d9 d3d8 d3d11 d3d10core dxgi d3d12 d3d12core vulkan-1; do
    cp -f "$STUB" "$WORK/$d.dll"
    TRACE="$WORK/loadorder-$d.trace"
    # The whole point: NO WINEDLLOVERRIDES. The load order alone must pick builtin.
    status=0
    WINEDEBUG=+module timeout 60 "$WINE" "$EXE" "$d.dll" > "$TRACE" 2>&1 || status=$?
    rm -f "$WORK/$d.dll"
    # patch 0017 logs: got fork builtin b for L"...\<d>.dll"
    if [ "$status" -eq 0 ] && grep -qiE "fork builtin b for .*\\\\${d}\.dll" "$TRACE"; then
        echo "  $d: builtin ✓"; pass=$((pass + 1))
    else
        echo "  $d: NOT builtin ✗  (0017 not applied/superseded — see $TRACE)"; fail=$((fail + 1))
    fi
done

# Stale registry values must lose; explicit environment overrides must win.
for d in d3d12 d3d12core; do
    cp "$STUB" "$WORK/$d.dll"
    WINEDEBUG=-all timeout 30 "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /d native /f > "$WORK/reg-$d.log" 2>&1
    TRACE="$WORK/registry-$d.trace"
    status=0
    WINEDEBUG=+module timeout 60 "$WINE" "$EXE" "$d.dll" > "$TRACE" 2>&1 || status=$?
    if [ "$status" -eq 0 ] && grep -qiE "fork builtin b for .*\\\\${d}\.dll" "$TRACE"; then
        echo "PASS: $d stale registry ignored"; pass=$((pass + 1))
    else
        echo "FAIL: $d stale registry (see $TRACE)"; fail=$((fail + 1))
    fi
    for key in "$d" "*$d"; do
        TRACE="$WORK/environment-${key//\*/wildcard}.trace"
        status=0
        WINEDEBUG=+module WINEDLLOVERRIDES="$key=n" timeout 60 "$WINE" "$EXE" "$d.dll" > "$TRACE" 2>&1 || status=$?
        if [ "$status" -eq 0 ] && grep -qiE "environment n for .*\\\\${d}\.dll" "$TRACE"; then
            echo "PASS: $key explicit native override"; pass=$((pass + 1))
        else
            echo "FAIL: $key explicit override (see $TRACE)"; fail=$((fail + 1))
        fi
    done
    rm -f "$WORK/$d.dll"
done

echo "=== $pass passed, $fail failed; logs: $WORK ==="
[ "$fail" -eq 0 ]
