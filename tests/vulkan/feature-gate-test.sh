#!/usr/bin/env bash
#
# feature-gate-test — is any relaxation in our patches now dead weight?
#
#   tests/vulkan/feature-gate-test.sh
#
# Two questions, and a finding needs BOTH:
#
#   1. does the driver report the feature?   -- asked of KosmicKrisp, by the
#                                               companion C probe
#   2. does the patch still relax it?        -- asked of the patch files here
#
# The C probe alone cannot answer the second, and reporting on the first alone
# is how the first version of this test kept calling four already-narrowed
# relaxations "dead weight" after they had been removed.
#
# Exit code is the number of relaxations that are dead weight, so a bump can be
# gated on it. Note it is the SCRIPT's exit code: piping this into `tail` reads
# tail's status instead, which has bitten this project before.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$PROJECT_DIR/tests/vulkan/feature-gate-test"
SRC="$PROJECT_DIR/tests/vulkan/feature-gate-test.c"
X86="$PROJECT_DIR/vendor/homebrew-x86"
VKH="$X86/opt/vulkan-headers/include"
VKL="$X86/opt/vulkan-loader/lib"

[ -d "$VKH" ] || { echo "SKIP: no x86 vulkan-headers (scripts/setup-x86-brew.sh)"; exit 0; }
ICD=$(find "$PROJECT_DIR/vendor/kosmickrisp" -name '*icd*.json' 2>/dev/null | head -1)
[ -n "$ICD" ] || { echo "SKIP: no KosmicKrisp ICD (scripts/build-kosmickrisp-x86.sh)"; exit 0; }

if [ ! -x "$PROBE" ] || [ "$SRC" -nt "$PROBE" ]; then
    clang -arch x86_64 -O2 -o "$PROBE" "$SRC" \
        -I"$VKH" -L"$VKL" -lvulkan -Wl,-rpath,"$VKL" || exit 1
fi

out=$(VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" "$PROBE") || { echo "$out"; echo "FAIL: probe failed"; exit 1; }
echo "$out" | sed -n '1p'

# Each gate: feature name, the patch that relaxes it, and a pattern that is
# present in that patch only while the relaxation is.
gate() {  # <feature> <patch> <grep-pattern>
    local feat=$1 patch=$2 pat=$3 driver relaxed
    driver=$(echo "$out" | awk -v f="$feat" '$1 == f { print ($2 == "SUPPORTED") ? "yes" : "no" }')
    [ -n "$driver" ] || { printf "  %-26s (not reported by probe)\n" "$feat"; return 0; }
    if grep -q "$pat" "$PROJECT_DIR/patches/$patch" 2>/dev/null; then relaxed=yes; else relaxed=no; fi

    if [ "$driver" = yes ] && [ "$relaxed" = yes ]; then
        printf "  %-26s DEAD WEIGHT -- driver has it, %s still relaxes it\n" "$feat" "$patch"
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

echo "cross-checking each relaxation against the patch that carries it:"
dead=0
gate fillModeNonSolid    dxvk/0001-d3d9-kosmickrisp-optional-features.patch \
     '^+.*fillModeNonSolid, false' || dead=$((dead+1))
gate geometryShader      dxvk/0001-d3d9-kosmickrisp-optional-features.patch \
     '^+.*geometryShader, false' || dead=$((dead+1))
gate shaderCullDistance  dxvk/0001-d3d9-kosmickrisp-optional-features.patch \
     '^+.*shaderCullDistance, false' || dead=$((dead+1))
gate depthClipEnable     dxvk/0001-d3d9-kosmickrisp-optional-features.patch \
     '^+.*depthClipEnable, false' || dead=$((dead+1))
gate robustBufferAccess2 dxvk/0001-d3d9-kosmickrisp-optional-features.patch \
     '^+.*robustBufferAccess2, false' || dead=$((dead+1))
gate nullDescriptor      dxvk/0001-d3d9-kosmickrisp-optional-features.patch \
     '^+.*nullDescriptor, false' || dead=$((dead+1))
gate transformFeedbackQueries vkd3d-proton/0001-optional-features-kosmickrisp.patch \
     'disabling stream output' || dead=$((dead+1))
gate singleTexelAlignment     vkd3d-proton/0001-optional-features-kosmickrisp.patch \
     'proceeding anyway' || dead=$((dead+1))

echo
if [ "$dead" = 0 ]; then
    echo "0 failed check(s) — every relaxation matches what the driver actually lacks"
else
    echo "$dead failed check(s) — narrow the patch, or add a relaxation for the gap"
fi
exit "$dead"
