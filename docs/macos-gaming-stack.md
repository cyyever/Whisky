# macOS gaming stack: D3D translation, native ARM, and what this repo can/can't do

Findings from evaluating this fork (Wine 11.13 x86_64 via Rosetta 2 + DXMT) on
Apple Silicon (M2, macOS Tahoe 26.5). Current as of July 2026.

## D3D → Metal translation options

| Layer | API it translates | Open source? | Apple-silicon usability |
|-------|-------------------|--------------|-------------------------|
| **DXMT** (`vendor/dxmt`) | D3D11/D3D10/DXGI → Metal | ✅ | Good — this repo's default D3D11 path |
| **D3DMetal** (Apple GPTK) | D3D11 **and D3D12** → Metal | ❌ Apple proprietary | Best (covers D3D12); CrossOver-only |
| **DXVK** | D3D9/10/11 → Vulkan | ✅ | D3D9-only in this repo: works on KosmicKrisp with `patches/dxvk` (optional-feature relaxations); upstream-stock still can't init (hard-requires `geometryShader`, absent on Apple GPUs) |
| **vkd3d-proton + KosmicKrisp** | D3D12 → Vulkan → Metal 4 | ✅ | ⚠️ Foothold only: device + compute + basic graphics work (2 `patches/vkd3d-proton` relaxations); real games blocked on Metal-hardware geometry stages (GS/transform-feedback) |

- **DXVK's role here**: DXMT is the default D3D11/D3D10 path; DXVK
  (`vendor/dxvk` + `patches/dxvk`) covers **D3D9 only**, which DXMT does not
  implement, and now runs on KosmicKrisp.
- **Vulkan-on-Metal is shifting (July 2026):** LunarG's **KosmicKrisp** (in Mesa,
  Google-sponsored) is a fully **conformant** Vulkan 1.3/1.4 driver built on
  **Metal 4** (macOS 26+, Apple Silicon only), reached MoltenVK feature parity
  Feb 2026; LunarG positions it as the future of Vulkan on Apple, with MoltenVK
  (1.4.1, Metal 3) trending toward maintenance. If it works under Rosetta
  (x86_64), the MoltenVK-workaround patches in `patches/dxvk`/`patches/moltenvk`
  may become unnecessary, and vkd3d-proton (D3D12) gains a first plausible open
  path. **Verified 2026-07-18: KosmicKrisp builds as x86_64 and works under
  Rosetta** (Mesa 26.1.5; vulkaninfo enumerates Apple M2 as
  DRIVER_ID_MESA_KOSMICKRISP, Vulkan 1.3.354, and a real
  device-create → vkCmdFillBuffer → submit → verify test passes in an x86_64
  process). The 26.1.5 release still drives classic Metal (no `MTL4*`
  references), but **Mesa main's MTL4 rework also verified under Rosetta**
  (26.3.0-devel via `scripts/build-kosmickrisp-x86.sh` + `vendor/mesa`:
  Vulkan 1.4.354, MTL4 command queue/compiler in the binary, same GPU-submit
  test passes) — so Metal 4 API is usable from Rosetta processes. Wine wiring
  verified with a real game (Witch on the Holy Night, 64-bit D3D9 → DXVK →
  winevulkan → x86 Vulkan loader in place of libMoltenVK.dylib → KosmicKrisp):
  renders correctly with Mesa MR 42811 (present-queue residencySet,
  `patches/mesa/0001`) plus DXVK's `fillModeNonSolid` made optional. See
  CLAUDE.md "Vulkan backend: KosmicKrisp".
- **D3D12 (e.g. Black Myth: Wukong, UE5):** DXMT is D3D11-only (no `d3d12` in
  its source tree). Apple's closed **D3DMetal** (CrossOver-only) is still the
  only *shipping* D3D12 path on Mac. The **open** path —
  vkd3d-proton → winevulkan → KosmicKrisp/Metal 4 under Rosetta — now has a
  **foothold** (verified 2026-07-18): D3D12 device creation, compute
  (DXBC `cs_5_0` → dispatch → readback), and basic graphics (VS/PS triangle)
  all work, after two device-init gates are relaxed
  (`patches/vkd3d-proton/0001`: `transformFeedbackQueries` + single-texel
  alignment made non-fatal). Probes: `tests/d3d12/` (+ a pure-Vulkan control in
  `tests/vulkan/`). It is **not** playability: real D3D12 games hit the
  **Metal-hardware geometry gaps** — no HW geometry shaders or transform
  feedback (KosmicKrisp emulates these via its compute "poly" pipeline;
  tessellation landed June 2026, GS still stubbed). Track with
  `scripts/check-kosmickrisp-progress.sh`.

## Native ARM64 Wine (Rosetta-free): not viable here yet

- Wine 11.13 on macOS is **x86_64 + Rosetta 2**. Source check: `loader/preloader_mac.c`
  has only `__x86_64__`/`__i386__` branches — **no `__aarch64__`**, so a native
  ARM macOS build can't be produced. Generic ARM64 plumbing (complete WoW64,
  ARM64 large-page support, ARM64EC) *is* in Wine 11, but the macOS-specific
  enablement is not.
- Native macOS ARM64 Wine is **experimental upstream** (Martin Storsjö; runs only
  "small test executables", not in a usable release). Blockers: 16K pages,
  low-4GB unmapped, W^X (no writable+executable).
- **"CrossOver ARM64 is Rosetta-free" is a myth for games.** CrossOver runs Wine
  as native ARM but still translates the x86 *game* code with **Apple Rosetta**.
  Rosetta stays in the loop; only Wine's own overhead becomes native. Since our
  workload is **GPU-bound** (see below), native-ARM Wine would help little.
- CodeWeavers is upstream-first (>95% of their Wine work goes upstream), so the
  Wine-side ARM bits flow upstream as they mature — but the decisive pieces
  (Rosetta-as-translator hookup, D3DMetal) are **Apple proprietary and never
  upstreamable**.

## CrossOver / GPTK / D3DMetal relationship

- Apple's **Game Porting Toolkit is built on CrossOver source** (CodeWeavers'
  Wine). In return, CodeWeavers is **licensed to bundle Apple's D3DMetal** in
  commercial CrossOver (since 23.5; CrossOver 26 ships D3DMetal 3.0).
- Apple's standalone GPTK EULA is "development use only"; CrossOver's license is
  what lets gamers use D3DMetal legally. D3DMetal stays closed — it can't ship in
  an open-source fork like this one.

## macOS 27+: the Rosetta deprecation question

- WWDC 2025: Rosetta 2 stays **fully functional through macOS 26 and 27**; after
  that Apple limits it to a **subset for older unmaintained games** (plus some
  framework uses). So **macOS 28 is the inflection point, not 27** — nothing to do
  until then.
- **The binding constraint is the x86→ARM translation of the *game* code, not
  Wine's architecture.** Even native-ARM Wine must translate the x86 Windows game,
  and on macOS that translator is Apple Rosetta. Split by what upstream can fix:
  - ✅ *Upstream can* (and likely will, given CodeWeavers' upstream-first model):
    native-ARM macOS Wine — preloader `__aarch64__`, macdrv ARM, the WoW64 +
    pluggable x86-emulator interface. Whisky gets this for free by tracking
    upstream, and it needs **no** D3DMetal (uses open DXMT/DXVK), so that closed
    piece is irrelevant here.
  - ❌ *Upstream can't*: the game-code translation backend. On macOS that is Apple
    Rosetta (the in-process hookup CrossOver uses is Apple-private, historically
    not upstreamed) or the open **FEX-Emu** (mature on Linux-ARM, immature/unproven
    on macOS). Neither is a Wine-upstream deliverable.
- **So "if CrossOver upstreams it, we're fine" holds only for the Wine side.**
  Surviving macOS 28 hinges on Apple keeping Rosetta usable for this workload
  (likely — it's exactly the "older x86 game" case Apple is preserving — but
  unconfirmed: the carve-out may be per-recognized-game, and a generic x86_64 Wine
  process might not qualify), or on FEX-on-macOS maturing. The bottleneck is Apple,
  not Wine.
- **Plan:** nothing through macOS 27; when macOS 28 betas land, test whether the
  x86_64 Wine still translates. If it breaks, the only open path is FEX-Emu on
  macOS (large effort) — otherwise keep the host on macOS 27, or follow CrossOver
  (Apple-licensed, adapts first).

## Performance: it's GPU-bound, not Wine

Measured while running a Unity D3D11 game (阎罗索命/HellTakesYourLife, 64-bit):

- **GPU ~96%** utilization (`ioreg IOAccelerator`: Device 96 / Renderer 90 / Tiler 87).
- Game CPU ~1.3 of 8 cores; `sample` showed Wine threads overwhelmingly parked in
  `__wine_syscall_dispatcher` / wait primitives → **waiting on the GPU**, not burning CPU.
- Conclusion: the M2 10-core GPU is the bottleneck. The only real lever is
  **reducing render load** (resolution / quality / frame cap). Rosetta + DXMT are
  a fixed translation tax but not the active bottleneck here.
- Builds are already optimized (Wine `-O2`, DXMT `meson --buildtype release`).

### Audio crackle / desync
`winecoreaudio.drv` (correct driver). Crackle + drift is **buffer underrun under
GPU saturation** — when frames hitch, the audio thread misses deadlines. Same
root as the stutter; fixed by lowering load (and closing background apps). Wine's
CoreAudio path is also inherently less resilient under load than native, but
there's no good buffer knob to tune. To tell apart: if it crackles in light
menus too → Wine-audio side; only under load → underrun.

## Tweaks this repo applies for performance/compat

- `WINEDEBUG=-all` — disable Wine debug logging (the default `-fixme+err+warn`
  still let fixme spam flood stderr and stutter games).
- `WINE_NX_COMPAT=1` + `patches/wine/0002-nx-compat-env-var.patch` — keep DEP on
  for legacy non-NX_COMPAT 32-bit images so Wine doesn't force PROT_EXEC on data
  pages, which makes Metal/DXMT a slideshow on Tahoe (3Shain/dxmt#161). 64-bit
  games are unaffected.
- DXMT enabled per bottle via `WINEDLLOVERRIDES=d3d11,d3d10core,dxgi,winemetal=b`
  (builtin selection; no per-bottle DLL install).

## Bottom line for this repo

- ✅ **x86 D3D11 games** (Unity/UE4, etc.): fully working today on Wine 11.13 + DXMT.
- ✅ **x86 D3D9 games**: DXVK → KosmicKrisp/Metal 4 (`patches/dxvk`), verified end-to-end.
- ⚠️ **D3D12 games** (UE5/Black Myth): open path (vkd3d-proton → KosmicKrisp)
  reaches device + compute + basic graphics, but not playable — blocked on
  Metal-hardware geometry stages (GS/transform-feedback). Shipping D3D12 today
  still needs closed D3DMetal (CrossOver).
- ❌ **Rosetta-free / native ARM**: blocked on experimental upstream macOS-ARM
  Wine; wouldn't help GPU-bound titles anyway.
- The practical ceiling for demanding/D3D12 titles on Mac remains **CrossOver
  (closed D3DMetal) + stronger GPU (M3 Pro/Max+)**.

## Sources
- Phoronix — Wine developer experimenting with macOS ARM64: https://www.phoronix.com/news/Wine-ARM64-macOS-Initial-Patch
- GamingOnLinux — Wine 11.9 ARM64 improvements: https://www.gamingonlinux.com/2026/05/wine-11-9-released-with-arm64-improvements-initial-support-for-system-threads/
- CodeWeavers — GPTK powered by CrossOver source: https://www.codeweavers.com/blog/mjohnson/2023/6/6/wine-comes-to-macos-apple-s-game-porting-toolkit-powered-by-crossover-source-code
- CodeWeavers — CrossOver 23.5 (D3DMetal): https://www.codeweavers.com/about/news/press/20230927
- CodeWeavers — Sending work upstream: https://www.codeweavers.com/blog/aeikum/2019/1/22/working-on-wine-part-6-sending-your-work-upstream
- The Gistre Blog — Running x86 builds on ARM64 macOS: https://blog.gistre.epita.fr/posts/louis.le-quellec-2025-06-12-running_x86_application_builds_on_a_arm64_macos/
- 3Shain/dxmt#161 — Placed buffer slow on Tahoe (WoW64): https://github.com/3Shain/dxmt/issues/161
