#!/bin/bash
set -euo pipefail

# Exercise the installed builtins, with no native overrides or app-local DLLs.
# A fresh, disposable prefix avoids touching a user's games or wineserver.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../scripts/lib/common.sh"
source "$PROJECT_DIR/scripts/lib/mullion.sh"
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
require_tools x86_64-w64-mingw32-gcc timeout
WINE="$INSTALL_DIR/Wine/bin/wine64"
SERVER="${WINESERVER:-$INSTALL_DIR/Wine/bin/wineserver}"
INSTALLED="$INSTALL_DIR/Wine/lib/wine/x86_64-windows"
[ -x "$WINE" ] || { echo "ERROR: run make proton first" >&2; exit 1; }
[ "$#" -eq 0 ] || { echo "Usage: $0 (always uses a disposable prefix)" >&2; exit 2; }

for name in d3d12 d3d12core; do
    dst="$INSTALLED/$name.dll"
    [ -f "$dst" ] || { echo "ERROR: missing $dst; run make mullion" >&2; exit 1; }
    if [ -f "$MULLION_STAGE/x86_64-windows/$name.dll" ] && ! cmp -s "$MULLION_STAGE/x86_64-windows/$name.dll" "$dst"; then
        echo "ERROR: installed $name differs from Mullion stage; run make mullion" >&2
        exit 1
    fi
    echo "$name: installed Mullion builtin verified"
done

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

D3DCOMPILER_LIB="-ld3dcompiler"
if [ ! -f "$INSTALLED/d3dcompiler_47.dll" ] && [ -f "$INSTALLED/d3dcompiler_46.dll" ]; then
    D3DCOMPILER_LIB="-ld3dcompiler_46"
fi

pass=0 fail=0
for test in smoke compute triangle mrt depth stencil streamout; do
    source_test="$test"
    case "$test" in mrt|depth|stencil) source_test=triangle ;; esac
    exe="$RUN/d3d12_$test.exe"
    x86_64-w64-mingw32-gcc -O1 -g -Wall -fsanitize=undefined -fsanitize-undefined-trap-on-error "$SCRIPT_DIR/d3d12_$source_test.c" -o "$exe" -ld3d12 "$D3DCOMPILER_LIB"
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
