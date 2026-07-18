# Whisky - Wine wrapper for macOS

## Project overview
Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived). A SwiftUI macOS app that wraps Wine for running Windows games via Steam on Apple Silicon.

## Architecture
- **Whisky app** — SwiftUI macOS app (Xcode project)
- **WhiskyKit** — Local Swift package with Wine management, bottle settings, process execution
- **Wine** — x86_64 Wine 11.13 built from source via Rosetta 2 (submodule at `vendor/wine`)
- **DXMT** — Metal-native D3D11/D3D10/DXGI (submodule `vendor/dxmt`, built via `make dxmt`, installed as the Wine builtin). Default D3D11 path; bottles enable it via `WINEDLLOVERRIDES=d3d11,d3d10core,dxgi,winemetal=b`. (DXVK here is **D3D9-only** — see the D3D9 section; stock upstream DXVK can't init on Apple GPUs without our optional-feature patches since it hard-requires `geometryShader`.)
- See `docs/macos-gaming-stack.md` for the D3D11/D3D12 translation landscape, native-ARM Wine status, CrossOver/D3DMetal relationship, and performance findings (GPU-bound, audio underruns, the `WINE_NX_COMPAT` Tahoe fix).
- **SteamHelper** — `webhelper_wrapper.c`, a PE launcher attached via IFEO that fixes Steam's black-window bug (see Steam notes)

## Build instructions
```bash
make setup-x86-brew  # one-time: x86_64 Homebrew + deps in vendor/
make wine            # build Wine 11.13 x86_64 from vendor/wine submodule (auto-applies patches/wine/*.patch)
make steam-helper    # cross-compile the Steam webhelper wrapper (mingw)
make dxvk            # build DXVK d3d9.dll (win32+win64) into Libraries/DXVK
make app             # build Whisky Swift app
make all             # build everything (app + Wine + steam-helper)
make run             # build app and launch
```

## Fresh-machine bootstrap (decisions live in code — no manual adaptation)
1. `git clone --recurse-submodules` this repo; install ARM brew deps (`bison mingw-w64 meson ninja llvm libclc spirv-llvm-translator spirv-tools nasm`)
2. `make setup-x86-brew` (x86_64 brew + linked libs, USTC mirrors)
3. `scripts/build-ffmpeg-x86.sh` (winedmo media backend) and
   `scripts/build-kosmickrisp-x86.sh` (Vulkan/Metal 4 driver) — **before** `make wine`,
   which bundles both and asserts the KosmicKrisp loader swap into Wine/lib
4. `make wine`, then `make dxmt` (D3D11) and `make dxvk` (D3D9)
5. Open Whisky, create bottle, install Steam, log in — everything else is automatic:
   Steam launch auto-installs the webhelper wrapper (black-window fix), auto-drops the
   right-arch DXVK `d3d9.dll` next to installed d3d9 games' executables (PE import scan)
   and sets `d3d9=native,builtin` (fallback instead of c0000135). Re-run `make wine`
   after rebuilding the KosmicKrisp driver to re-assert the loader swap.

## Key paths
- Wine submodule: `vendor/wine` (branch `dxmt-fixes-11.13`: wine-11.13 + rundll32 WS_VISIBLE fix + winemac macdrv export for DXMT)
- Wine patches: `patches/wine/*.patch` — out-of-tree, applied by `build-wine-x86.sh` so the submodule stays clean:
  - `0001` kernelbase IFEO `Debugger` support (for the Steam wrapper)
  - `0002` `WINE_NX_COMPAT` env var (keeps DEP on for legacy images → fixes DXMT/Metal Tahoe slowness)
  - `0003` winemac DXMT Metal client-view positioning + resize re-sync
  - `0004` winemac borderless fullscreen window snap-to-display-origin (Unity `-popupwindow` Y-offset fix)
- x86 Homebrew: `vendor/homebrew-x86/` (gitignored)
- Build scripts: `scripts/setup-x86-brew.sh`, `scripts/build-wine-x86.sh`, `scripts/build-ffmpeg-x86.sh`, `scripts/build-webhelper-wrapper.sh`
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`
- Steam wrapper: `SteamHelper/webhelper_wrapper.c` → installed to `…/Libraries/SteamHelper/steamwebhelper_wrapper.exe`
- Bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`

## Wine build notes
- Native ARM64 Wine does NOT work on macOS (preloader_mac.c has no aarch64 support)
- Must build x86_64 Wine and run via Rosetta 2
- Use `--enable-archs=i386,x86_64` for WoW64 32-bit support (Steam is 32-bit)
- Bundle FreeType, MoltenVK dylibs into Wine/lib; add @loader_path/../.. rpath to wine/x86_64-unix/*.so so dlopen finds them
- `vendor/homebrew-x86` only provides the x86_64 **libraries linked into Wine** (freetype, gettext/libintl, gnutls, sdl2, MoltenVK). The **build tools** (bison, pkg-config, the mingw-w64 cross-compiler) come from the **ARM64 brew** — they're arch-independent or target PE, so no x86_64 copies are needed (saves ~400 MB, mostly mingw-w64). `build-wine-x86.sh` puts the ARM `bison` keg (`$ARM/opt/bison/bin`, keg-only) + ARM `bin` on PATH and sets `PKG_CONFIG` to the ARM one, while keeping `PKG_CONFIG_PATH` on the x86 brew so the linked libs still resolve. Verified by the 11.13 rebuild (2026-07-18): the ARM64-brew mingw toolchain produces a working x86_64 Wine.
- Media playback (game videos via Media Foundation) needs `winedmo.so` linked against FFmpeg (libavformat/avcodec/avutil), which must be **x86_64** — the ARM brew ffmpeg can't be loaded into the Rosetta process, and Homebrew has no workable x86_64 ffmpeg on Tahoe (no bottle; source build gated on newest Xcode). `scripts/build-ffmpeg-x86.sh` builds a minimal x86_64 FFmpeg from source (builtin codecs only, no encoders/muxers/network) into `vendor/ffmpeg-x86/`; `build-wine-x86.sh` picks it up via pkg-config and bundles its dylibs. Without it Wine configure silently builds a stub winedmo (check: `otool -L winedmo.so` should list libavformat). Wine's in-tree `libs/ffmpeg` is unrelated — a trimmed copy (no libavformat, all codecs off) used only for swscale/swresample in PE-side DMOs.
- D3D11/D3D10/DXGI use DXMT (Metal-native, `make dxmt` installs it as the Wine builtin); wined3d remains the fallback. DXMT's earlier Steam-CEF conflict (ANGLE SwapChain11) is moot now that the webhelper wrapper forces CEF to `--disable-gpu` software rendering.
- Debugging: winemac's WINEDEBUG channel is **`macdrv`** (not `winemac`). DXMT's PE dlls (`d3d11/dxgi/d3d10core/winemetal.dll`) are loaded as **builtins from the Wine lib** (`Wine/lib/wine/x86_64-windows/`) under `=b`, NOT from the bottle's `system32` — patch the Wine-lib copy when swapping a DXMT build. Rosetta caches an AOT translation (`/private/var/db/oah/.../*.so.aot`) keyed by binary hash, so a rebuilt dll is re-translated automatically.

## Unity fullscreen / "empty top bar" (空栏) finding — Steam D3D11 games
- Symptom: a Unity game (D3D11 → DXMT) set to **fullscreen** (FullScreenWindow/borderless mode 1 *or* ExclusiveFullScreen mode 0) shows a ~32px macOS **title bar at the top** ("空栏"), sits at the menu-bar Y offset, and overflows the bottom.
- **Root cause is NOT DXMT.** The DXGI swapchain is windowed (`Windowed=1`); window styling is pure Win32. winemac correctly builds the borderless fullscreen window, then **Unity's own player reverts it** — `SetWindowLong` re-adds `WS_CAPTION` right after `WM_ACTIVATEAPP`, a fallback when its fullscreen "handshake" doesn't match a native Windows WM. Not cleanly fixable in winemac (Unity is closed-source; just suppressing the caption leaves Wine's caption geometry → a blank gap).
- **Fix/workaround**: set the game's **Steam Launch Options** to `-popupwindow -screen-fullscreen 0` → Unity makes a genuinely borderless `WS_POPUP` window (no caption, no revert). Stored per-game in `…/Steam/userdata/<id>/config/localconfig.vdf` (`LaunchOptions`; edit with Steam closed). Caveat: overrides the in-game display setting (always borderless).
- Patches `0003`/`0004` (above) make the borderless fullscreen window land edge-to-edge at the display origin (no title bar, no menu-bar offset, no overflow). Verify the on-screen window via CoreGraphics bounds (`CGWindowListCopyWindowInfo`): a clean fullscreen window is `0,0 — 1280×832` (logical), a reverted one is `…×864` (832 + 32 caption).

## Vulkan backend: KosmicKrisp (Metal 4) — replaces MoltenVK
- Wine's Vulkan backend is **Mesa KosmicKrisp** (Vulkan-on-Metal-4, conformant 1.4): `vendor/mesa` (shallow submodule tracking `main`) built by `scripts/build-kosmickrisp-x86.sh` (two-phase: arm64 `mesa_clc` tools, then x86_64 cross; auto-applies `patches/mesa/*.patch`; artifacts → `vendor/kosmickrisp/`).
- Wiring: `Wine/lib/libMoltenVK.dylib` is **actually the x86_64 Khronos Vulkan loader** (winevulkan dlopens that leaf name; the loader exports `vkGetInstanceProcAddr`, which the Mesa ICD does not); the loader finds KosmicKrisp via `~/.local/share/vulkan/icd.d/kosmickrisp_icd.x86_64.json`. Stock-MoltenVK backup: `libMoltenVK.dylib.mvk-stock` alongside. **`build-wine-x86.sh` owns this swap** — its dylib-bundling stage re-copies stock MoltenVK then swaps the loader in, so every `make wine` re-asserts it automatically (the swap only fires when `vendor/kosmickrisp/` artifacts exist, so build the KosmicKrisp driver before `make wine`).
- `patches/mesa/0001` = unmerged Mesa **MR 42811** (present-queue residencySet). Without it Metal 4 presents black frames. Drop when merged.
- **Keep the pin fresh**: KosmicKrisp moves fast (~35 commits/month, July 2026) — periodically `git submodule update --remote vendor/mesa`, rebuild, check whether `patches/mesa/*` and the DXVK optional-feature workarounds (e.g. `fillModeNonSolid`) are still needed.
- Verified end-to-end 2026-07-18: Witch on the Holy Night (Steam 2052410, 64-bit D3D9/HuneX) renders via DXVK → winevulkan → loader → KosmicKrisp → Metal 4 under Rosetta.

## D3D9 games via DXVK (KosmicKrisp; formerly MoltenVK)
- D3D9 games (e.g. *Sword and Fairy 5 Prequel* / `Pal5Q.exe`, appid 681840) default to wined3d, which is broken on macOS: the GL backend hits `GL_INVALID_FRAMEBUFFER_OPERATION` (black screen); the Vulkan backend lacks D3D9 **fixed-function pipeline** support (`No pipeline layout set`). DXMT does **not** implement D3D9.
- Experiment: `vendor/dxvk` submodule (upstream DXVK v3.0), built **d3d9-only** (`meson … -Denable_d3d9=true -Denable_d3d8/d3d10/d3d11/dxgi=false`, 32-bit via `build-win32.txt`). Upstream DXVK can't initialize on Apple GPUs (requires `geometryShader` etc. that the hardware lacks).
- `patches/dxvk/` adapts DXVK for MoltenVK (all trace to MoltenVK lacking `VK_EXT_robustness2`/`nullDescriptor`; the device-loss culprits were found with the Metal API validation layer — `METAL_DEVICE_WRAPPER_TYPE=1`): `0001` makes the missing device features optional (`geometryShader`, `shaderCullDistance`, `depthClipEnable`, `robustBufferAccess2`, `nullDescriptor`); `0002` forces `primitiveRestartEnable` on for strip/fan topologies (Metal can't disable primitive restart); `0003` forces **static vertex strides** (Metal validates dynamic `setVertexBufferOffset:attributeStride:` strictly → device loss); `0004` binds DXVK's **dummy buffer for unbound vertex streams** instead of `VK_NULL_HANDLE` (no `nullDescriptor` → Metal "missing buffer binding" → device loss). Run with `MVK_CONFIG_API_VERSION_TO_ADVERTISE=4206592` (advertise Vulkan 1.3) + `WINEDLLOVERRIDES="d3d9=n;d3dx9_30=n"` + the DXVK `d3d9.dll` in the game dir.
- The `d3dx9_30=n` override is essential: the game ships the native Microsoft `d3dx9_30.dll` (real shader assembler); Wine's builtin forwards `D3DXAssembleShader` to its incomplete `d3dcompiler` → `assemble_shader Asm reading failed`. Forcing native fixes it.
- **MoltenVK path status (2026-07-18): inactive** — the Vulkan backend is now KosmicKrisp (section above), and the currently bundled `libMoltenVK.dylib.mvk-stock` is **stock brew 1.4.1** (the patched build was clobbered by the 11.13 Wine reinstall; rebuild per below if the MoltenVK path is ever revived). **The bundled MoltenVK was patched** (`patches/moltenvk/0001-defer-residency-set-removal.patch`) to keep D3D9 working without losing the Metal device on macOS 15+: a residency set *retains* the resources added to it, and on that path command buffers use `retainedReferences = NO`, so the residency-set retain can be the last reference keeping a resource alive while a completed-but-not-yet-released `MTLCommandBuffer` still references it. Destroying the resource (`removeResidency` → `removeAllocation`) dropped that retain inside the window before Metal releases the command buffer → dangling-reference abort → `VK_ERROR_DEVICE_LOST`. The patch (in `MVKDevice`) **defers** the residency-set removal until a later queue submission completes — ping-ponged so each survives ≥1 submit/complete cycle — or immediately on `waitIdle`; the resource stays resident/alive until its command buffers are released. (Earlier approaches — blanket `retainedReferences=YES` when a residency set is active, or honouring `MVK_CONFIG_LIVE_CHECK_ALL_RESOURCES` — were rejected upstream as workarounds; the maintainer wanted the lifetime handled, not retain forced.) Upstreamed as **KhronosGroup/MoltenVK PR #2762**; compiles clean, runtime-validation with Metal API Validation still pending. Installed as `…/Wine/lib/libMoltenVK.dylib` (x86_64, ad-hoc signed; orig = `libMoltenVK.dylib.orig`). Rebuild: clone KhronosGroup/MoltenVK `v1.4.1`, apply `patches/moltenvk/0001-defer-residency-set-removal.patch`, `./fetchDependencies --macos && make macos`, `lipo -thin x86_64 Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib`, `codesign -s -` (Wine/lib is read-only — `chmod u+w` first). Bundled MoltenVK normally comes from x86 brew `molten-vk` 1.4.1.

### RESOLVED — black window (on KosmicKrisp: Mesa MR 42811)
- On the KosmicKrisp backend the black window was **fixed by `patches/mesa/0001`** (MR 42811: make the CAMetalLayer residencySet resident for the presenting queue — Metal 4 requirement). DXVK needs 64-bit builds for 64-bit games (`build.w64`, same meson cross setup as `build.w32`) and `fillModeNonSolid` demoted to optional in `patches/dxvk/0001` (KosmicKrisp doesn't implement it yet).
- Historical (MoltenVK path, unresolved there): both D3D9 games showed a **black window even though DXVK fully set up rendering** — logs showed `DXVK: v3.0`, `Found device: Apple M2 (MoltenVK)`, `D3D9DeviceEx::ResetSwapChain`, `Presenter: Actual swapchain … 1280×832, 3 images`, **0 `VK_ERROR_DEVICE_LOST`, 0 `Failed to create Direct3D9`** — and the game script runs (loads title/scene images). So DXVK renders + presents to the swapchain but the content never reaches the visible window: a **DXVK → MoltenVK → winemac Vulkan-surface presentation** problem. 仙剑5 *did* render its scene in some runs (~1.5 MB screenshots); **Trap Yuri Garden is always black** — diff the two (window mode, present mode `IMMEDIATE` vs `FIFO`, how winemac attaches the `CAMetalLayer` for the Vulkan swapchain surface vs the DXMT path in patches `0003`/`0004`). Debug tools that worked: Metal API validation (`METAL_DEVICE_WRAPPER_TYPE=1`); DXVK stderr (grep with `-a`, logs are Shift-JIS-tainted); `WINEDEBUG=+relay` (firehose, ~1000× slowdown, but confirms the call path). Vulkan validation layers do **not** insert under wine's winevulkan (it loads MoltenVK directly, bypassing the loader/layers).
- Launch is also flaky: games early-exit or hang at `get_strAccessToken` (Steam access token) when Steamworks isn't fully ready. Launch from the **Steam Play button** (proper Steamworks), not a bare CLI launch, and from a clean bottle — heavy CLI launch/kill testing churns wineserver/Steam (symptom: multiple orphan `explorer.exe /desktop` → multiple Dock icons; near-instant game exits). **Reboot for a clean slate before resuming.**
- **Second D3D9 game — Trap Yuri Garden** (appid 2183910, KiriKiriZ VN: `.xp3` archives + `krkrsteam.dll`, exe `Jyosou_Yuribatake.exe`). Same profile as 仙剑5: D3D9 → wined3d fails (`DrawDeviceForSteam: Failed to create Direct3D9`) → fixed by the DXVK `d3d9.dll` in the game dir + global `d3d9=native`,`d3dx9_30=native` (set in the bottle registry via `wine reg add 'HKCU\Software\Wine\DllOverrides'`). Reaches the title sequence (logo/background crossfade) but black (the open present issue). NOTE the global registry override affects *all* games — a d3d9 game without a DXVK `d3d9.dll` in its dir falls back to (broken) wined3d.
- The **Gcenx/dxvk-macOS** fork (DXVK 1.10.3) *fails* device creation on this MoltenVK 1.4.1 (queries timeline_semaphore as an extension; MoltenVK exposes it as core) — so upstream v3.0 + these patches is the working path. No `build-dxvk.sh` yet — patches archived, not auto-applied.

## Steam notes
- **Black-window fix**: Steam's CEF host (`steamwebhelper.exe`) renders a black window under Wine — its sandbox hooks the NT kernel and its out-of-process GPU can't reset the D3D device (`problems[10]: Some drivers are unable to reset the D3D device in the GPU process sandbox`). Neither wined3d nor DXMT fixes this; Steam's own `--disable-gpu` fallback is insufficient.
- **Solution (IFEO launcher)**: `SteamHelper/webhelper_wrapper.c` re-launches the genuine binary (a copy kept as `steamwebhelper_real.exe`) with `--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing` (`--no-sandbox` + `--in-process-gpu` are the flags Steam's fallback misses). It is attached via the image's **Image File Execution Options `Debugger`** value, NOT by overwriting `steamwebhelper.exe` — so the on-disk binary stays byte-identical to Valve's and passes Steam's startup verification. (Overwriting it tripped `BVerifyInstalledFiles` → Steam re-downloaded the client every launch.)
  - Requires Wine to honour the IFEO `Debugger` value at `CreateProcess`, which stock Wine does not — added by `patches/wine/0001-kernelbase-ifeo-debugger.patch`.
  - The wrapper launches `steamwebhelper_real.exe` (different name) so the IFEO redirect doesn't recurse. CEF propagates the flags to its child processes itself.
  - Built GUI-subsystem (`-mwindows`) so no console window appears; child spawned with `CREATE_NO_WINDOW`.
  - `Steam.swift` (hooked in `Wine.configureSteam`, called from `Wine.runProgram`) on every launch: installs the wrapper at `C:\windows\steamwebhelper_wrapper.exe`, restores a genuine `steamwebhelper.exe` (migrating old bottles where it was overwritten), refreshes the `steamwebhelper_real.exe` copy, and sets the IFEO `Debugger` registry value. CLI: `whisky steam-fix <bottle>`.
  - Installed into 64-bit CEF dirs only (`cef.win64` / `cef.win7x64`); a 32-bit Steam client (`-cef-force-32bit`) would need an i686 wrapper build.
- **Update-stuck fix (proxy)**: Steam's self-update connects directly to its CDN; behind a proxy/GFW that stalls (`http error 0`). `Process.environment` doesn't inherit the host proxy, so enable the bottle's **"Follow System Proxy"** toggle (`BottleSettings.followSystemProxy`) — `SystemProxy.swift` reads the macOS system proxy (resolving PAC) and injects `http_proxy`/`https_proxy`/`no_proxy` into the Wine env. Does not apply to VPN/TUN tunnels (those route transparently and need nothing).
- WoW64 caveat: a hand-driven `wineboot --init` may not populate `syswow64` (32-bit DLLs) — Steam's 32-bit `steam.exe` then fails with `c0000135`. The GUI/`WhiskyCmd` bottle-creation path handles this; if hitting it manually, copy `Wine/lib/wine/i386-windows/*.dll` into the bottle's `syswow64`.

## Distribution URLs
- Version plist: `https://cyyever.github.io/Whisky/WhiskyWineVersion.plist`
- Libraries download: `https://github.com/cyyever/Whisky/releases/download/v{version}/Libraries.tar.gz`
- Appcast: `https://cyyever.github.io/Whisky/appcast.xml`

## Dependencies
- SemanticVersion 0.5.1
- swift-argument-parser 1.7.1
- SwiftyTextTable 0.9.0
- Progress.swift 0.4.0

## Coding conventions
- Swift 6.3, macOS 26.0 deployment target
- SwiftLint enforced (strict mode, 25+ opt-in rules, custom file header required)
- GPL v3 license
- `vendor/` and build artifacts excluded from SwiftLint
