#!/usr/bin/env bash
#
# present-probe-test — does KosmicKrisp's real presentation path tear?
#
#   tests/vulkan/present-probe-test.sh [seconds]
#
# WHY. Every offscreen probe of the driver's draw path passes, but the game
# artifact (a fullscreen quad losing exactly one of its two triangles) lives
# in what offscreen rendering cannot reach: the swapchain. Every present runs
# kk_CmdBlitImage2 -> vk_meta_blit, a 6-vertex triangle-list blit into the
# CAMetalDrawable. So: a real NSWindow + CAMetalLayer + VK_EXT_metal_surface
# FIFO swapchain, a render loop that only clears each frame to an alternating
# solid colour (even = red, odd = blue) and presents -- no app-side geometry.
# The window must always be ONE solid colour; a diagonal split between the
# two colours is the blit quad losing a triangle.
#
# The probe self-checks (captures its own window ~once a second and compares
# the two diagonal corners); this runner just builds and runs it. Note the
# probe window takes focus and flashes red/blue for the duration -- keep the
# run short when working interactively.
#
# Exit code: 0 = every self-check saw one solid colour, 1 = a split was seen
# (or the build/run failed).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VKH="$PROJECT_DIR/vendor/homebrew-x86/opt/vulkan-headers/include"
VKL="$PROJECT_DIR/vendor/homebrew-x86/opt/vulkan-loader/lib"
ICD="$PROJECT_DIR/vendor/kosmickrisp/kosmickrisp_icd.x86_64.json"
SRC="$PROJECT_DIR/tests/vulkan/vk-present-probe.m"
EXE="$PROJECT_DIR/tests/vulkan/vk-present-probe"

[ -d "$VKH" ] || { echo "SKIP: no x86 vulkan-headers (scripts/setup-x86-brew.sh)"; exit 0; }
[ -f "$ICD" ] || { echo "SKIP: no KosmicKrisp ICD (scripts/build-kosmickrisp-x86.sh)"; exit 0; }

if [ ! -x "$EXE" ] || [ "$SRC" -nt "$EXE" ]; then
    clang -arch x86_64 -fobjc-arc -Wno-deprecated-declarations \
        -framework Cocoa -framework QuartzCore -framework ImageIO \
        -I"$VKH" -o "$EXE" "$SRC" \
        -L"$VKL" -lvulkan -Wl,-rpath,"$VKL" || exit 1
fi

VK_DRIVER_FILES="$ICD" arch -x86_64 "$EXE" "${1:-10}"
