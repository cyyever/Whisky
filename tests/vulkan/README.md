# Pure-Vulkan KosmicKrisp control

`vk_triangle.c` renders a green fullscreen triangle into an offscreen
R8G8B8A8 image via core/KHR dynamic rendering and reads back the center pixel
— as a **native x86_64 (Rosetta) process**, linking the Vulkan loader directly
to KosmicKrisp/Metal, with **no Wine and no vkd3d/D3D** in the path.

It is the discriminator for the `tests/d3d12` black-triangle wall:

- **Result (2026-07-18, Mesa 26.3-dev): green — PASS.** KosmicKrisp's
  rasterization, fragment output, and dynamic rendering are correct.
- Therefore the `tests/d3d12` black triangle is **not** a KosmicKrisp core
  graphics bug (nor the missing `VK_EXT_dynamic_rendering_unused_attachments`,
  nor `nir_lower_blend` #15344). It is specific to how **vkd3d-proton** drives
  Vulkan on KosmicKrisp.

If this control ever regresses to black after a `vendor/mesa` bump, the bug
moved into KosmicKrisp itself.

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
