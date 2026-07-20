# MoltenVK-era D3D9/DXVK debugging history (inactive path)

The Vulkan backend moved to Mesa KosmicKrisp (see CLAUDE.md); this file
preserves the MoltenVK-path findings in case that path is ever revived.

## The residency-set device-loss bug and patch

The bundled MoltenVK was patched
(`patches/moltenvk/0001-defer-residency-set-removal.patch`) to keep D3D9
working without losing the Metal device on macOS 15+: a residency set
*retains* the resources added to it, and on that path command buffers use
`retainedReferences = NO`, so the residency-set retain can be the last
reference keeping a resource alive while a completed-but-not-yet-released
`MTLCommandBuffer` still references it. Destroying the resource
(`removeResidency` → `removeAllocation`) dropped that retain inside the window
before Metal releases the command buffer → dangling-reference abort →
`VK_ERROR_DEVICE_LOST`. The patch (in `MVKDevice`) **defers** the
residency-set removal until a later queue submission completes — ping-ponged
so each survives ≥1 submit/complete cycle — or immediately on `waitIdle`; the
resource stays resident/alive until its command buffers are released.

Earlier approaches — blanket `retainedReferences=YES` when a residency set is
active, or honouring `MVK_CONFIG_LIVE_CHECK_ALL_RESOURCES` — were rejected
upstream as workarounds; the maintainer wanted the lifetime handled, not
retain forced. Upstreamed as **KhronosGroup/MoltenVK PR #2762**; compiles
clean, runtime-validation with Metal API Validation still pending.

Rebuild recipe: clone KhronosGroup/MoltenVK `v1.4.1`, apply the patch,
`./fetchDependencies --macos && make macos`,
`lipo -thin x86_64 Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib`,
`codesign -s -` (Wine/lib may be read-only — `chmod u+w` first). Run DXVK on
it with `MVK_CONFIG_API_VERSION_TO_ADVERTISE=4206592` (advertise Vulkan 1.3).

## The unresolved black window (MoltenVK path only)

Both D3D9 test games showed a **black window even though DXVK fully set up
rendering** — logs showed `DXVK: v3.0`, `Found device: Apple M2 (MoltenVK)`,
`D3D9DeviceEx::ResetSwapChain`, `Presenter: Actual swapchain … 1280×832, 3
images`, **0 `VK_ERROR_DEVICE_LOST`, 0 `Failed to create Direct3D9`** — and
the game script ran (loaded title/scene images). So DXVK rendered + presented
to the swapchain but the content never reached the visible window: a
**DXVK → MoltenVK → winemac Vulkan-surface presentation** problem. 仙剑5 *did*
render its scene in some runs (~1.5 MB screenshots); **Trap Yuri Garden was
always black** — the diff to chase was window mode, present mode `IMMEDIATE`
vs `FIFO`, and how winemac attaches the `CAMetalLayer` for the Vulkan
swapchain surface vs the DXMT path in `patches/wine/0003`/`0004`.

On KosmicKrisp the equivalent symptom was fixed by `patches/mesa/0001`
(MR 42811: make the CAMetalLayer residencySet resident for the presenting
queue — a Metal 4 requirement).

## Debug tooling that worked

- Metal API validation: `METAL_DEVICE_WRAPPER_TYPE=1` (found every device-loss culprit)
- DXVK stderr: grep with `-a` (logs are Shift-JIS-tainted)
- `WINEDEBUG=+relay`: firehose, ~1000× slowdown, but confirms the call path
- Vulkan validation layers do **not** insert under the MoltenVK-direct wiring
  (winevulkan loaded MoltenVK directly, bypassing loader/layers). The
  KosmicKrisp wiring goes through the real Khronos loader, so layers work there.

## Test games (D3D9 profile)

- **Sword and Fairy 5 Prequel** (仙剑5前传, appid 681840, 32-bit `Pal5Q.exe`):
  wined3d GL backend black-screens (`GL_INVALID_FRAMEBUFFER_OPERATION`);
  needs DXVK `d3d9.dll` + `d3dx9_30=native` (ships the real MS shader
  assembler; Wine's builtin forwards to its incomplete d3dcompiler →
  `assemble_shader Asm reading failed`).
- **Trap Yuri Garden** (appid 2183910, KiriKiriZ VN: `.xp3` + `krkrsteam.dll`,
  exe `Jyosou_Yuribatake.exe`): same profile; fixed via global
  `HKCU\Software\Wine\DllOverrides` registry overrides (`d3d9=native`,
  `d3dx9_30=native`). Note a global override affects *all* games — one without
  a DXVK `d3d9.dll` in its dir falls back to broken wined3d.
- Launch flakiness: games early-exit or hang at `get_strAccessToken` when
  Steamworks isn't ready — launch from the **Steam Play button**, not bare
  CLI. Heavy CLI launch/kill churns wineserver/Steam (symptom: multiple orphan
  `explorer.exe /desktop` → multiple Dock icons; near-instant exits) — reboot
  for a clean slate.
- The **Gcenx/dxvk-macOS** fork (DXVK 1.10.3) fails device creation on
  MoltenVK 1.4.1 (queries timeline_semaphore as an extension; MoltenVK
  exposes it as core) — upstream v3.0 + our patches is the working path.
