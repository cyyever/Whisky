# D3D12-on-KosmicKrisp probes

Minimal headless D3D12 programs that map how far the **open** D3D12 path
(vkd3d-proton → winevulkan → KosmicKrisp/Metal 4, under Rosetta) gets. Re-run
after bumping `vendor/mesa` (KosmicKrisp) to see whether a wall has lifted.

| Probe | Exercises | Status (2026-07-18, Mesa 26.3-dev) |
|-------|-----------|-------------------------------------|
| `d3d12_smoke.c` | device + command queue + fence | ✅ PASS |
| `d3d12_compute.c` | DXBC `cs_5_0` → compute PSO → root UAV → dispatch → readback | ✅ PASS (correct results) |
| `d3d12_triangle.c` | VS/PS → offscreen RT → draw → readback | ✅ PASS (green) |

**Basic D3D12 device creation, compute, and graphics all work** through
vkd3d-proton → winevulkan → KosmicKrisp → Metal 4 under Rosetta, with the two
device-init gates relaxed by `patches/vkd3d-proton/0001`. Device creation still
warns that `VK_EXT_dynamic_rendering_unused_attachments` is missing (relevant
only to multi/mismatched-RT cases, not these probes). What remains untested is
real-game complexity: multiple render targets, depth/stencil, geometry shaders
and transform feedback (Metal-hardware gaps), tessellation, bindless, etc.

> Note: an earlier version of `d3d12_triangle` rendered black — that was a bug
> *in the probe* (it left `RenderTargetWriteMask = 0`, masking all color
> output), not in KosmicKrisp or vkd3d. Fixed by setting
> `D3D12_COLOR_WRITE_ENABLE_ALL`. The `tests/vulkan/` control confirmed KK's
> graphics were fine all along.

Device creation itself needs two vkd3d-proton gates made non-fatal —
`patches/vkd3d-proton/0001-optional-features-kosmickrisp.patch`.

## Build & run

```bash
# 1. Build vkd3d-proton (win64) with the KosmicKrisp patch:
git clone --recurse-submodules https://github.com/HansKristian-Work/vkd3d-proton.git vendor/vkd3d-proton
git -C vendor/vkd3d-proton apply "$PWD/patches/vkd3d-proton/0001-optional-features-kosmickrisp.patch"
PATH=/opt/homebrew/bin:/usr/bin:/bin meson setup vendor/vkd3d-proton/build.w64 \
    --cross-file vendor/vkd3d-proton/build-win64.txt --buildtype release
PATH=/opt/homebrew/bin:/usr/bin:/bin ninja -C vendor/vkd3d-proton/build.w64

# 2. Run the probes (needs a bottle + the KosmicKrisp loader swap in Wine/lib):
tests/d3d12/run.sh [bottle-dir]
```

The probes shell-compile their HLSL at runtime via Wine's builtin
`d3dcompiler_47` (DXBC), so no `dxc`/DXIL toolchain is required.
