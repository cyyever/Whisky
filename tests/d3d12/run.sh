#!/bin/bash
set -e

# Cross-compile and run the D3D12 conformance probes against vkd3d-proton on
# whatever Vulkan driver Wine currently loads (KosmicKrisp/Metal 4 when the
# loader swap is in place — see CLAUDE.md "Vulkan backend: KosmicKrisp").
#
# The graphics render wall (VK_EXT_dynamic_rendering_unused_attachments) has
# LIFTED as of 2026-08-13: d3d12_triangle compiles HLSL, builds a graphics
# pipeline, draws and reads back the right green pixel. What still fails is
# d3d12_compute, and not in the driver -- vkd3d-shader's HLSL front end rejects
# a structured-buffer store with "E5017: not yet implemented".
#
# Usage: tests/d3d12/run.sh [bottle-dir]
#   bottle-dir defaults to $WINEPREFIX, else the first bottle found.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
WINE="$INSTALL_DIR/Wine/bin/wine64"
VKD3D_BUILD="$PROJECT_DIR/vendor/vkd3d-proton/build.w64/libs"

BOTTLE="${1:-${WINEPREFIX:-}}"
if [ -z "$BOTTLE" ]; then
    BOTTLE=$(find "$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles" \
        -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
fi

[ -x "$WINE" ] || { echo "ERROR: Wine not found at $WINE (run make wine)"; exit 1; }
[ -d "$BOTTLE" ] || { echo "ERROR: no bottle (pass one as \$1 or set WINEPREFIX)"; exit 1; }
[ -f "$VKD3D_BUILD/d3d12/d3d12.dll" ] || {
    echo "ERROR: vkd3d-proton not built. See tests/d3d12/README.md"; exit 1; }

export PATH="/opt/homebrew/bin:/usr/bin:/bin"
command -v x86_64-w64-mingw32-gcc >/dev/null || {
    echo "ERROR: mingw-w64 not found (brew install mingw-w64)"; exit 1; }

WORK="$SCRIPT_DIR/.build"
mkdir -p "$WORK"
# vkd3d-proton as native d3d12; keep the dlls beside the test exes.
cp "$VKD3D_BUILD/d3d12/d3d12.dll" "$VKD3D_BUILD/d3d12core/d3d12core.dll" "$WORK/"

pass=0 fail=0
for test in smoke compute triangle; do
    src="$SCRIPT_DIR/d3d12_$test.c"
    exe="$WORK/d3d12_$test.exe"
    x86_64-w64-mingw32-gcc "$src" -o "$exe" -ld3d12 -ld3dcompiler
    echo "=== d3d12_$test ==="
    # Keep the output: a hardcoded "expected for 'triangle'" used to be printed
    # for whichever test failed, which read as a known-good failure and hid a
    # real one in a different test.
    # `|| true`: the script runs under `set -e`, and a failing probe is a result
    # to report, not a reason to stop. The old form was exempt only because it
    # sat inside an `if`.
    out=$(WINEPREFIX="$BOTTLE" WINEMSYNC=1 VKD3D_DEBUG=warn \
        WINEDLLOVERRIDES="d3d12,d3d12core=n" WINEDEBUG=-all \
        "$WINE" "$exe" 2>&1) || true
    if echo "$out" | grep -qE 'ALL OK'; then
        echo "  PASS"; pass=$((pass + 1))
    else
        # Fall back to the last line of output, then to a plain statement: a bare
        # "FAIL:" for a crash or a hang would be the same unreadable result the
        # hardcoded string used to give.
        why=$(echo "$out" | grep -E 'E[0-9]{4}:|[Ff]ailed|FAIL' | tail -1)
        [ -n "$why" ] || why=$(echo "$out" | grep -v '^[[:space:]]*$' | tail -1)
        echo "  FAIL: ${why:-no output captured (crash or hang?)}"
        fail=$((fail + 1))
    fi
done

echo "=== $pass passed, $fail failed ==="
