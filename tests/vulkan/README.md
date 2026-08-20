# Pure-Vulkan KosmicKrisp control

`vk_triangle.c` renders a green fullscreen triangle into an offscreen
R8G8B8A8 image via core/KHR dynamic rendering and reads back the center pixel
— as a **native x86_64 (Rosetta) process**, linking the Vulkan loader directly
to KosmicKrisp/Metal, with **no Wine and no vkd3d/D3D** in the path.

It was the discriminator that showed KosmicKrisp's graphics were fine while the
`tests/d3d12` triangle rendered black — which turned out to be a bug in that
probe (a zero `RenderTargetWriteMask`), not in KK or vkd3d. Both render green
now.

- **Result (2026-07-18, Mesa 26.3-dev): green — PASS.** KosmicKrisp's
  rasterization, fragment output, and dynamic rendering are correct.

Kept as a fast KK graphics smoke test: if this ever regresses to black after a
`vendor/mesa` bump, a real KosmicKrisp graphics regression landed.

## strip-cull-test.sh — primitive assembly / cull / vertex-fetch matrix

`tests/vulkan/strip-cull-test.sh` draws one fullscreen quad under a matrix of
topology × cull × winding × fetch shape and reads back two diagonal probe
pixels: one inside each of the quad's two triangles. The two disagreeing on a
single draw is the signature of the SSFIV artifact (a fullscreen quad losing
exactly one triangle — the diagonal half-screen split during video and loading
screens).

Covers what the game's draw path actually does: strip winding compensation
before the cull test, uint16 index buffers at offsets ≡2 mod 4, D3D9-style
28-byte-stride vertex fetch at odd bind offsets, firstVertex/vertexOffset, and
triangle fans in both windings (DXVK passes `D3DPT_TRIANGLEFAN` through as
`VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN`; KK emulates fans on a helper queue).
A stress phase replays the presentation blit's shape — a 6-vertex triangle
list whose vertex data the CPU rewrites immediately before every draw — with
two frames in flight for 400 frames. A second stress covers the unroll path:
indexed uint16 TRIANGLE_FANs and STRIPs (what `kk_unroll_geometry` handles,
decomposing them through the device-global heap) with 2000 unrolled draws per
frame and two frames in flight — the cadence plus backlog under which the
game's loading screens run. It calibrates first: every vertex variant is
drawn single-shot at queue-idle and its two strict-interior probe pixels
(the generic ones sit exactly ON the quad diagonal, where one triangle's
edge fill lights both) are checked against expectations, with a pixel dump
on mismatch — a broken config would otherwise masquerade as aliasing.

A final block sets `primitiveRestartEnable` on **non-indexed** draws, which
the spec requires to be inert ("this enable only applies to indexed draws"),
and compares each against the identical draw with the flag off. That pair is
what caught the artifact: **`FANP perim restart=ON` rendered `BLACK/red` where
`restart=OFF` rendered `red/red`** — half a quad, cut along its diagonal.
KosmicKrisp was feeding vertex IDs through its restart comparison, so vertex 0
(the fan's hub) read as a restart marker and the 4-vertex fan emitted one
triangle instead of two. Fixed in `patches/mesa/0002`; see that patch for the
mechanism. Strips are unaffected because only fans unroll unconditionally.

**Result (2026-08-19): all 24 configs + both stress phases correct, 0
failures** (before the fix, the restart pair failed). The draw path, the
fan/strip unroll, and the unroll heap under in-flight frames are exonerated;
run this after every KosmicKrisp bump.

## present-probe-test.sh — the real presentation path

`tests/vulkan/present-probe-test.sh [seconds]` builds and runs
`vk-present-probe.m`: a real NSWindow + CAMetalLayer + `VK_EXT_metal_surface`
FIFO swapchain whose render loop only clears each frame to an alternating
solid colour (even = red, odd = blue) and presents — no app-side geometry.
Every present runs `kk_CmdBlitImage2` → `vk_meta_blit`, a 6-vertex
triangle-list blit into the drawable; the window must always be one solid
colour, and a diagonal split between the two colours is that quad losing a
triangle. The probe self-checks by capturing its own window ~once a second;
exit code 1 means a split was seen. Note: the window takes focus and flashes
for the duration — keep the run short when working interactively.

**Result (2026-08-15): 500+ frames, 0 splits.** The clean present path holds
under no load; the artifact needed GPU backlog (see `patches/mesa/0001`, the
acquire-time present-blit lifetime fix).

### `-dropped` — the present that is never displayed

`present-probe-test.sh -dropped [seconds]` covers the window-switch freeze:
SSFIV hung forever in `vkWaitForPresentKHR`, because KosmicKrisp advances
`present_id` only from a `CAMetalDrawable` presented handler and that handler
never runs for a drawable the window server does not put on screen. Metal has
no discarded-presentation callback, so nothing ever completed those presents
and DXVK's `UINT64_MAX` wait never returned. `patches/mesa/0003` synthesizes
the completion Metal will not send.

The condition cannot be produced from the Vulkan side — occluded, hidden,
miniaturized and unattached layers were all measured and all still get their
handlers called in 4–9 ms — so the driver takes
`MESA_VK_WSI_METAL_DROP_PRESENT_HANDLER` to skip the registration, and this mode
sets it. The verdict is not "the waits finished": it also requires them to
have taken the grace period, because finishing fast would mean the hook did
not take and the run proved nothing.

**Result (2026-08-20): waits complete in ~506 ms, 0 timeouts.** Without the
patch this run hangs on the first wait.

### `-occlusion` — cmd-tab with the handler intact

Presents with `VK_KHR_present_id`, waits with a finite `vkWaitForPresentKHR`,
and activates another app partway through to reproduce a cmd-tab. **Result
(2026-08-19): 3156 frames over a 60 s switch-away, presents completing in
9 ms, no stall** — a negative that mattered: KosmicKrisp's present path is
healthy on a plain Cocoa window, which is what pushed the search onto the
window `winemac.drv` creates and, from there, onto the presented handler.

### `-covered` — the drawable pool under a window that is really hidden

`-occlusion` activates another app, which leaves the probe window inactive but
still on screen unless that app happens to have a window over it, and it
acquires with a 500 ms timeout, so an empty drawable pool reads as
`VK_NOT_READY` and the loop carries on. SSFIV does neither: `dxvk` passes
`UINT64_MAX`, and four separate captures of the frozen game found `dxvk-submit`
in `[CAMetalLayer nextDrawable]`, inside `wsi_metal_swapchain_acquire`'s
`while (1)`. So this mode raises an opaque screen-sized window of its own over
the probe — no other application involved — and acquires the way dxvk does.

**Result (2026-08-20): negative. 2223 frames, worst acquire 1016 ms while
fully covered against 1019 ms while visible.** Covering a window does not stop
Metal recycling drawables: acquire blocks for the one-second `nextDrawable`
timeout, gets nil, retries and is served. The 1019 ms *visible* figure is worth
keeping too — this pool sits at its limit even on a healthy frame.

What the game does that this does not: the user's terminal is **fullscreen**,
which on macOS is a separate Space, so the game's window is not merely covered
but absent from the composited Space. That is not reproducible from inside one
process. It also does not explain the freeze surviving a switch back, which the
game's did.

## Build & run

```bash
X=vendor/homebrew-x86
# Regenerate SPIR-V headers only if you edit the shaders:
#   glslangValidator -V --vn vert_spv -o tri_vert.h tri.vert
#   glslangValidator -V --vn frag_spv -o tri_frag.h tri.frag
clang -arch x86_64 tests/vulkan/vk_triangle.c -o /tmp/vk_triangle \
    -I$X/opt/vulkan-headers/include -Itests/vulkan \
    -L$X/opt/vulkan-loader/lib -lvulkan
VK_DRIVER_FILES=vendor/kosmickrisp/kosmickrisp_icd.x86_64.json \
    DYLD_LIBRARY_PATH=$X/opt/vulkan-loader/lib arch -x86_64 /tmp/vk_triangle
```

Needs the x86_64 KosmicKrisp driver built (`scripts/build-kosmickrisp-x86.sh`)
and the x86 Homebrew Vulkan headers/loader.
