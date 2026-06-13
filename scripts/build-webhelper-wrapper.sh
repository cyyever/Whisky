#!/usr/bin/env bash
#
# Build the Steam webhelper wrapper (a Windows PE that injects Wine-compat CEF
# flags into steamwebhelper) and install it next to the Wine libraries so
# WhiskyKit can copy it into bottles. See SteamHelper/webhelper_wrapper.c.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJECT_DIR/SteamHelper/webhelper_wrapper.c"
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/SteamHelper"
OUT="$INSTALL_DIR/steamwebhelper_wrapper.exe"

# Prefer the native Homebrew mingw, fall back to the x86 toolchain's copy.
MINGW_CC="$(command -v x86_64-w64-mingw32-gcc || true)"
if [ -z "$MINGW_CC" ]; then
    MINGW_CC="$PROJECT_DIR/vendor/homebrew-x86/bin/x86_64-w64-mingw32-gcc"
fi
if [ ! -x "$MINGW_CC" ] && ! command -v "$MINGW_CC" >/dev/null 2>&1; then
    echo "ERROR: x86_64-w64-mingw32-gcc not found. Install with: brew install mingw-w64" >&2
    exit 1
fi

echo "=== Building steamwebhelper wrapper (x86_64, GUI subsystem) ==="
mkdir -p "$INSTALL_DIR"
# -mwindows => GUI subsystem so no console window pops up under Wine.
"$MINGW_CC" -O2 -mwindows -o "$OUT" "$SRC"
echo "=== Installed: $OUT ==="
