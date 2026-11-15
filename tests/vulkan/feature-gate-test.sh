#!/usr/bin/env bash
#
# feature-gate-test — is any device-feature relaxation now dead weight?
#
#   tests/vulkan/feature-gate-test.sh
#
# Two questions, and a finding needs BOTH:
#
#   1. does the driver report the feature?   -- asked of KosmicKrisp, by the
#                                               companion C probe
#   2. does the source still relax it?       -- checked in DXVK/vkd3d-proton
#
# The C probe alone cannot answer the second; a relaxation is dead weight only
# when the driver reports support and the translation layer still relaxes it.
#
# Exit code is the number of relaxations that are dead weight, so a bump can be
# gated on it. Note it is the SCRIPT's exit code: piping this into `tail` reads
# tail's status instead, which has bitten this project before.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$PROJECT_DIR/tests/vulkan/feature-gate-test"
SRC="$PROJECT_DIR/tests/vulkan/feature-gate-test.c"
X86="$PROJECT_DIR/vendor/x86-deps"
VKH="$X86/include"
VKL="$X86/lib"

[ -f "$VKH/vulkan/vulkan.h" ] || { echo "SKIP: no x86 vulkan-headers (make x86-deps)"; exit 0; }
ICD=$(find "$PROJECT_DIR/vendor/kosmickrisp" -name '*icd*.json' 2>/dev/null | head -1)
[ -n "$ICD" ] || { echo "SKIP: no KosmicKrisp ICD (scripts/build-kosmickrisp-x86.sh)"; exit 0; }

if [ ! -x "$PROBE" ] || [ "$SRC" -nt "$PROBE" ]; then
    clang -arch x86_64 -O2 -o "$PROBE" "$SRC" \
        -I"$VKH" -L"$VKL" -lvulkan -Wl,-rpath,"$VKL" || exit 1
fi

out=$(VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" "$PROBE") || { echo "$out"; echo "FAIL: probe failed"; exit 1; }
echo "$out" | sed -n '1p'

# Each gate: feature name, source file, and a pattern present while relaxed.
gate() {  # <feature> <source> <grep-pattern>
    local feat=$1 source=$2 pat=$3 driver relaxed
    driver=$(echo "$out" | awk -v f="$feat" '$1 == f { print ($2 == "SUPPORTED") ? "yes" : "no" }')
    [ -n "$driver" ] || { printf "  %-26s (not reported by probe)\n" "$feat"; return 0; }
    if grep -Eq "$pat" "$PROJECT_DIR/$source" 2>/dev/null; then relaxed=yes; else relaxed=no; fi

    if [ "$driver" = yes ] && [ "$relaxed" = yes ]; then
        printf "  %-26s DEAD WEIGHT -- driver has it, %s still relaxes it\n" "$feat" "$source"
        return 1
    elif [ "$driver" = yes ]; then
        printf "  %-26s ok -- driver has it, and the relaxation is gone\n" "$feat"
    elif [ "$relaxed" = yes ]; then
        printf "  %-26s ok -- still missing, relaxation earning its place\n" "$feat"
    else
        printf "  %-26s GAP -- driver lacks it and nothing relaxes it\n" "$feat"
        return 1
    fi
    return 0
}

echo "cross-checking each relaxation against the source that carries it:"
dead=0
gate fillModeNonSolid    vendor/dxvk/src/dxvk/dxvk_device_info.cpp \
     'ENABLE_FEATURE\(core.features, fillModeNonSolid, false\)' || dead=$((dead+1))
gate transformFeedbackQueries patches/vkd3d-proton/0001-optional-features-kosmickrisp.patch \
     'disabling stream output' || dead=$((dead+1))
gate singleTexelAlignment     patches/vkd3d-proton/0001-optional-features-kosmickrisp.patch \
     'proceeding anyway' || dead=$((dead+1))

echo
if [ "$dead" = 0 ]; then
    echo "0 failed check(s) — every relaxation matches what the driver actually lacks"
else
    echo "$dead failed check(s) — narrow the patch, or add a relaxation for the gap"
fi
exit "$dead"
