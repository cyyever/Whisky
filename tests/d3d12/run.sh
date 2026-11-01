#!/bin/bash
set -euo pipefail

# Exercise the installed builtins, with no native overrides or app-local DLLs.
# A fresh, disposable prefix avoids touching a user's games or wineserver.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../scripts/lib/common.sh"
source "$PROJECT_DIR/scripts/lib/vkd3d.sh"
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
require_tools x86_64-w64-mingw32-gcc python3 timeout
WINE="$INSTALL_DIR/Wine/bin/wine64"
SERVER="$INSTALL_DIR/Wine/bin/wineserver"
LIBS="$PROJECT_DIR/vendor/vkd3d-proton/build.w64/libs"
INSTALLED="$INSTALL_DIR/Wine/lib/wine/x86_64-windows"
[ -x "$WINE" ] || { echo "ERROR: run make proton first" >&2; exit 1; }
[ "$#" -eq 0 ] || { echo "Usage: $0 (always uses a disposable prefix)" >&2; exit 2; }

# Byte-for-byte provenance check, allowing only the builtin signature we stamp.
# Otherwise a test might pass against Wine's fallback implementation after rebuild.
python3 - "$LIBS" "$INSTALLED" <<'PY'
from pathlib import Path
import sys
source, installed = map(Path, sys.argv[1:])
for name in ('d3d12', 'd3d12core'):
    src, dst = source/name/(name+'.dll'), installed/(name+'.dll')
    if not src.is_file() or not dst.is_file():
        sys.exit(f'ERROR: missing {name}; run make vkd3d')
    expected = bytearray(src.read_bytes())
    expected[64:81] = b'Wine builtin DLL\0'
    if expected != dst.read_bytes():
        sys.exit(f'ERROR: installed {name} differs from vkd3d-proton; run make vkd3d')
    print(f'{name}: installed vkd3d-proton builtin verified')
PY

WORK="$SCRIPT_DIR/.build"
mkdir -p "$WORK"
RUN=$(mktemp -d "$WORK/run.XXXXXX")
export WINEPREFIX="$RUN/prefix"
export DYLD_FALLBACK_LIBRARY_PATH="$INSTALL_DIR/Wine/lib"
export WINEDEBUG=-all VKD3D_DEBUG=warn
unset WINEDLLOVERRIDES WINEARCH WINEMSYNC WINEESYNC WINEFSYNC
cleanup() {
    timeout 15 "$SERVER" -k >/dev/null 2>&1 || true
    if timeout 15 "$SERVER" -w >/dev/null 2>&1; then
        rm -rf "$WINEPREFIX"
    else
        echo "Keeping $WINEPREFIX: wineserver did not stop."
    fi
}
trap cleanup EXIT
mkdir -p "$WINEPREFIX"
echo "Logs: $RUN"
# Skip the Mono/Gecko prompts, which block wineboot when no one is at the display.
if ! WINEDLLOVERRIDES="mscoree,mshtml=" timeout 180 "$WINE" wineboot --init > "$RUN/wineboot.log" 2>&1; then
    cat "$RUN/wineboot.log"
    exit 1
fi

pass=0 fail=0
for test in smoke compute triangle mrt depth stencil streamout; do
    source_test="$test"
    case "$test" in mrt|depth|stencil) source_test=triangle ;; esac
    exe="$RUN/d3d12_$test.exe"
    x86_64-w64-mingw32-gcc -O2 -Wall "$SCRIPT_DIR/d3d12_$source_test.c" -o "$exe" -ld3d12 -ld3dcompiler
    status=0
    (cd "$RUN"; timeout 90 "$WINE" "$exe" "$test") > "$RUN/$test.log" 2>&1 || status=$?
    if [ "$status" -eq 0 ] && grep -q 'ALL OK' "$RUN/$test.log"; then
        echo "PASS: $test"; pass=$((pass + 1))
    else
        echo "FAIL: $test (exit $status)"; cat "$RUN/$test.log"
        fail=$((fail + 1))
    fi
done

echo "=== $pass passed, $fail failed ==="
# The EXIT trap stops only this prefix's server, then removes the prefix.
[ "$fail" -eq 0 ]
