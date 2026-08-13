#!/usr/bin/env bash
#
# vulkan-loader-test — can a bottle actually reach a Vulkan driver?
#
#   tests/vulkan/vulkan-loader-test.sh [bottle]
#
# WHY. SSFIV exited 3 on every launch. The cause was DXVK failing to create a
# Vulkan instance, and behind it a missing HOME: the loader reads
# `$HOME/.local/share/vulkan/icd.d/*.json`, where build-kosmickrisp-x86.sh
# installs the KosmicKrisp manifest. Without it, 3 loader-only extensions, no
# VK_KHR_surface, VK_ERROR_INCOMPATIBLE_DRIVER. Nothing in that chain warns.
#
#   1. with HOME    -> must succeed
#   2. HOME stripped -> must fail
#
# Arm 2 is not padding: if it passes, the ICD is being found some other way and
# arm 1 proves nothing.
#
# Does NOT check that Whisky passes HOME -- revert Wine.swift's merge and both
# arms still pass. tests/env-contract-test.sh holds the Swift side.
#
# Exit code is the number of failed checks.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_DIR/tests/lib/bottles.sh"

WHISKY_LIB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
VK_HEADERS="$PROJECT_DIR/vendor/homebrew-x86/opt/vulkan-headers/include"
PROBE_SRC="$PROJECT_DIR/tests/vulkan/vk-instance-ext-test.c"
PROBE_EXE="$PROJECT_DIR/tests/vulkan/vk-instance-ext-test.exe"

failures=0
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "pass  $*"; }

[ -x "$WHISKY_LIB/bin/wine64" ] || { echo "SKIP: no Wine at $WHISKY_LIB (run 'make proton')"; exit 0; }
command -v i686-w64-mingw32-gcc >/dev/null ||
    { echo "SKIP: mingw-w64 not found (brew install mingw-w64)"; exit 0; }
[ -d "$VK_HEADERS" ] ||
    { echo "SKIP: no vulkan headers at $VK_HEADERS (run 'make setup-x86-brew')"; exit 0; }

# Any bottle, and one is enough: the search is per-process, keyed on HOME.
select_bottles "$@"
BOTTLE="${bottles[0]}"
echo "bottle: $(basename "$BOTTLE")"

# 32-bit: that is what a 32-bit game's DXVK runs as.
if [ ! -f "$PROBE_EXE" ] || [ "$PROBE_SRC" -nt "$PROBE_EXE" ]; then
    i686-w64-mingw32-gcc -O2 -I "$VK_HEADERS" -o "$PROBE_EXE" "$PROBE_SRC" || exit 1
fi

# NOT a mirror of Wine.constructWineEnvironment(): only what can change where
# the loader looks. The rest of Whisky's list cannot affect an ICD search.
run_probe() {  # $@ = extra `env` assignments
    ( cd "$WHISKY_LIB/bin" && env -i "$@" \
        WINEPREFIX="$BOTTLE" \
        WINEDEBUG=-all \
        DYLD_FALLBACK_LIBRARY_PATH="$WHISKY_LIB/lib" \
        ./wine64 "$PROBE_EXE" 2>/dev/null )
}

echo "=== 1. with HOME, as a shipped launch has it ==="
out_with=$(run_probe HOME="$HOME"); rc_with=$?
echo "$out_with" | sed -n '/instance extensions offered/,$p' | sed 's/^/    /'
if [ "$rc_with" -eq 0 ]; then
    pass "a driver is reachable and vkCreateInstance succeeds"
else
    fail "no usable Vulkan driver even with HOME set ($rc_with failed check(s) in the probe)"
    echo "      Look at: is the KosmicKrisp ICD manifest still in"
    echo "      \$HOME/.local/share/vulkan/icd.d/ ? (scripts/build-kosmickrisp-x86.sh writes it)"
fi

echo
echo "=== 2. control: HOME stripped, the state that produced the bug ==="
out_without=$(run_probe); rc_without=$?
echo "$out_without" | sed -n '/instance extensions offered/,/VK_KHR_win32_surface/p' | sed 's/^/    /'
# A nonzero exit is not enough: a bug in this script exits nonzero too. Require
# the probe's own output as proof it ran.
if ! echo "$out_without" | grep -q 'instance extensions offered'; then
    fail "the probe never ran without HOME, so this arm proves nothing"
    echo "      Output was:"
    echo "$out_without" | sed 's/^/      /'
elif [ "$rc_without" -ne 0 ]; then
    pass "fails without HOME, so arm 1 is testing what it claims to"
else
    fail "succeeded without HOME -- the ICD is being found some other way, so arm 1"
    echo "      no longer proves the passthrough works. Check for a system-wide"
    echo "      manifest or an exported VK_DRIVER_FILES/VK_ICD_FILENAMES."
fi

echo
echo "$failures failed check(s)"
exit "$failures"
