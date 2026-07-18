#!/bin/bash
set -e

# Cross-compile and run the D3D12 conformance probes against vkd3d-proton on
# whatever Vulkan driver Wine currently loads (KosmicKrisp/Metal 4 when the
# loader swap is in place — see CLAUDE.md "Vulkan backend: KosmicKrisp").
#
# Re-run after bumping vendor/mesa (KosmicKrisp) to see whether the graphics
# render wall (VK_EXT_dynamic_rendering_unused_attachments) has lifted.
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
    if WINEPREFIX="$BOTTLE" WINEMSYNC=1 VKD3D_DEBUG=warn \
        WINEDLLOVERRIDES="d3d12,d3d12core=n" WINEDEBUG=-all \
        "$WINE" "$exe" 2>/dev/null | grep -qE 'ALL OK'; then
        echo "  PASS"; pass=$((pass + 1))
    else
        echo "  FAIL (expected for 'triangle' until the render wall lifts)"; fail=$((fail + 1))
    fi
done

echo "=== $pass passed, $fail failed ==="
