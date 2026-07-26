#!/bin/bash
set -e

# Verify patches/proton-wine/0017-macos-metal-builtin-dll-loadorder.patch: the
# D3D/Vulkan stack must default to *builtin* in Wine's load order, with NO
# WINEDLLOVERRIDES set. Cross-compiles loadorder_probe.exe and, for each module,
# LoadLibrary's it under WINEDEBUG=+module (the channel loadorder.c logs on) and
# asserts get_load_order() chose builtin. Re-run after `make proton` (or a
# proton/base bump) to catch the patch being dropped or superseded — the app sets
# no override, so a regression breaks Steam CEF (its app-dir vulkan-1.dll) and D3D9.
#
# One DLL per wine invocation: each module is probed in its own process (fresh
# address space), so a big builtin that fails to *map* — or a crash in one
# module's init — can't suppress another module's load-order trace. (Loading all
# seven ~90 MB DXVK+DXMT builtins in one process fragmented the WoW64+Rosetta
# address space and aborted the run before the later modules traced.)
#
# get_load_order() only runs once the loader has *found* a file for the name.
# d3d11/d3d10core/dxgi/vulkan-1/winemetal are genuine Wine/DXMT builtins whose DOS
# stub carries the "Wine builtin DLL" signature, so wineboot mirrors them into the
# prefix's system32 as fake DLLs and the loader finds them there. DXVK's d3d9/d3d8
# are third-party PEs *without* that signature, so wineboot creates no fake DLL and
# LoadLibraryA("d3d9.dll") fails with STATUS_DLL_NOT_FOUND *before* get_load_order
# runs — no trace at all. To make every module reach get_load_order regardless of
# the prefix's ambient fake-DLL set, we drop a tiny placeholder <dll> next to the
# probe exe (first on the search path). That mirrors reality — the app auto-drops
# DXVK's d3d9.dll next to a game exe — and is a *stronger* check: an app-directory
# native copy present, yet the load order must still force builtin (exactly what
# keeps Steam CEF's own bundled vulkan-1.dll from winning). The placeholder is
# never loaded: builtin resolution pulls the real module from Wine's lib dir.
#
# Uses a throwaway prefix (.build/prefix) so a bottle's own — or stale, pre-0017 —
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

WORK="$SCRIPT_DIR/.build"; mkdir -p "$WORK"
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
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "=== creating scratch prefix (first run, slow) ==="
    WINEDEBUG=-all "$WINE" wineboot --init >/dev/null 2>&1 || true
fi

pass=0 fail=0
for d in d3d9 d3d8 d3d11 d3d10core dxgi winemetal vulkan-1; do
    cp -f "$STUB" "$WORK/$d.dll"
    TRACE="$WORK/loadorder-$d.trace"
    # The whole point: NO WINEDLLOVERRIDES. The load order alone must pick builtin.
    WINEDEBUG=+module "$WINE" "$EXE" "$d.dll" > "$TRACE" 2>&1 || true
    rm -f "$WORK/$d.dll"
    # patch 0017 logs: get_load_order got fork|Metal builtin b for L"...\<d>.dll"
    if grep -qiE "(fork|Metal) builtin b for .*\\\\${d}\.dll" "$TRACE"; then
        echo "  $d: builtin ✓"; pass=$((pass + 1))
    else
        echo "  $d: NOT builtin ✗  (0017 not applied/superseded — see $TRACE)"; fail=$((fail + 1))
    fi
done

echo "=== $pass builtin, $fail not ==="
[ "$fail" -eq 0 ]
