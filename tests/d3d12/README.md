# D3D12-on-KosmicKrisp probes

Minimal headless D3D12 programs that map how far the **open** D3D12 path
(vkd3d-proton → winevulkan → KosmicKrisp/Metal 4, under Rosetta) gets. Re-run
after bumping `vendor/mesa` (KosmicKrisp) to see whether a wall has lifted.

| Probe | Exercises | Status (2026-07-18, Mesa 26.3-dev) |
|-------|-----------|-------------------------------------|
| `d3d12_smoke.c` | device + command queue + fence | ✅ PASS |
| `d3d12_compute.c` | DXBC `cs_5_0` → compute PSO → root UAV → dispatch → readback | ✅ PASS (correct results) |
| `d3d12_triangle.c` | VS/PS → offscreen RT → draw → readback | ❌ FAIL — draw writes no pixels |

## The current wall

`d3d12_triangle` renders **black** (the draw produces no fragments), while a
red *clear* reads back red — so clear / RT / copy / readback all work; only
`DrawInstanced` rasterization output fails. This matches vkd3d-proton's runtime
warning:

```
VK_EXT_dynamic_rendering_unused_attachments not supported.
The functionality in this EXT is required for correct operation.
```

vkd3d-proton renders D3D12 via Vulkan dynamic rendering; without that EXT the
color-attachment binding is wrong and fragments aren't written. Lifting this is
a **KosmicKrisp/Mesa** change, not something vkd3d-proton can relax. Beyond it
lie the Metal-hardware gaps (transform feedback, geometry shaders).

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
