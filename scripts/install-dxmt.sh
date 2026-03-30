#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
WINE_LIB="$INSTALL_DIR/Wine/lib/wine"
DXMT_VERSION="0.74"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v${DXMT_VERSION}/dxmt-v${DXMT_VERSION}-builtin.tar.gz"

if [ ! -d "$WINE_LIB" ]; then
    echo "ERROR: Wine not installed. Run scripts/build-wine-x86.sh first."
    exit 1
fi

echo "=== Installing DXMT v${DXMT_VERSION} ==="

TMPDIR=$(mktemp -d)
curl -sL -o "$TMPDIR/dxmt.tar.gz" "$DXMT_URL"
tar -xzf "$TMPDIR/dxmt.tar.gz" -C "$TMPDIR"

DXMT_DIR="$TMPDIR/v${DXMT_VERSION}"

# Install DXMT DLLs (overrides Wine's built-in D3D with Metal-based ones)
for arch in x86_64-windows x86_64-unix i386-windows; do
    SRC="$DXMT_DIR/$arch"
    DST="$WINE_LIB/$arch"
    if [ -d "$SRC" ] && [ -d "$DST" ]; then
        for f in "$SRC"/*; do
            fname=$(basename "$f")
            cp "$f" "$DST/$fname"
            echo "  $arch/$fname"
        done
    fi
done

rm -rf "$TMPDIR"

echo "=== DXMT v${DXMT_VERSION} installed ==="
echo "D3D11/D3D10/DXGI now use Metal via DXMT"
