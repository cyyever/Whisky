# Whisky - Wine wrapper for macOS

## Project overview
Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived). A SwiftUI macOS app that wraps Wine for running Windows games via Steam on Apple Silicon.

## Architecture
- **Whisky app** — SwiftUI macOS app (Xcode project); **WhiskyKit** — Swift package (Wine management, bottle settings, process execution)
- **Wine** — x86_64 Wine 11.13 built from source, runs via Rosetta 2 (submodule `vendor/wine`)
- **DXMT** — Metal-native D3D11/D3D10/DXGI (submodule `vendor/dxmt`, `make dxmt` installs it as the Wine builtin; bottles enable via `WINEDLLOVERRIDES=d3d11,d3d10core,dxgi,winemetal=b`)
- **DXVK** — **D3D9-only** here (see D3D9 section); **KosmicKrisp** — Wine's Vulkan backend (see Vulkan section)
- **SteamHelper** — `webhelper_wrapper.c`, PE launcher attached via IFEO fixing Steam's black window (see Steam notes)
- Landscape/perf background: `docs/macos-gaming-stack.md`

## Build instructions
```bash
make setup-x86-brew  # one-time: x86_64 Homebrew + deps in vendor/
make wine            # build Wine (auto-applies patches/wine/*.patch); release install: strips PE debug info, drops .a/man (~1.8G -> ~0.7G)
make wine-debug      # reinstall keeping PE debug info for winedbg (build tree always has -g)
make dxmt            # build DXMT and install as Wine builtin (needs full Xcode + llvm@15)
make dxvk            # build DXVK d3d9.dll (win32+win64) into Libraries/DXVK
make steam-helper    # cross-compile the Steam webhelper wrapper (mingw)
make app / make run  # build Whisky app / build and launch
```

## Fresh-machine bootstrap (decisions live in code — no manual adaptation)
1. `git clone --recurse-submodules`; install ARM brew deps (`bison mingw-w64 meson ninja llvm libclc spirv-llvm-translator spirv-tools nasm`)
2. `make setup-x86-brew` (x86_64 brew + linked libs, USTC mirrors)
3. `scripts/build-ffmpeg-x86.sh` (winedmo media backend) and `scripts/build-kosmickrisp-x86.sh` (Vulkan driver) — **before** `make wine`, which bundles both and asserts the KosmicKrisp loader swap
4. `make wine`, then `make dxmt` and `make dxvk`
5. Open Whisky, create bottle, install Steam, log in — the rest is automatic: Steam launch installs the webhelper wrapper, auto-drops the right-arch DXVK `d3d9.dll` next to d3d9 games' executables (PE import scan) and sets `d3d9=native,builtin`. Re-run `make wine` after rebuilding KosmicKrisp to re-assert the loader swap.

## Key paths
- Wine submodule: `vendor/wine` (branch `dxmt-fixes-11.13`: wine-11.13 + rundll32 WS_VISIBLE fix + winemac macdrv export for DXMT)
- Wine patches (`patches/wine/`, applied by `build-wine-x86.sh` which resets tracked source to HEAD first): `0001`/`0002` mirror the branch's own base commits (rundll32 WS_VISIBLE fix; winemac/ntdll `macdrv_functions` export for DXMT) — already in HEAD, so the build detects them as applied and skips; `0003`+ are genuinely out-of-tree: `0003` kernelbase IFEO `Debugger` (Steam wrapper), `0004` `WINE_NX_COMPAT` env (DEP on for legacy images → fixes DXMT Tahoe slowness), `0005` winemac DXMT Metal view positioning/resize, `0006` winemac borderless-fullscreen snap-to-origin, `0007` coreaudio hide virtual devices
- x86 Homebrew: `vendor/homebrew-x86/` (gitignored); build scripts in `scripts/`
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`; bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`

## Wine build notes
- Native ARM64 Wine does NOT work on macOS (preloader_mac.c lacks aarch64) — build x86_64, run under Rosetta; `--enable-archs=i386,x86_64` for WoW64 (Steam is 32-bit)
- Toolchain split: x86 brew provides only the **libraries linked into Wine** (freetype, gnutls, sdl2, gettext, MoltenVK); **build tools** (bison keg, pkg-config, mingw-w64) come from ARM brew — arch-independent or PE-targeting, saves ~400 MB
- Dylibs bundled into Wine/lib with symlink chains preserved (`cp -Rn`); unix `.so` modules get an `@loader_path/../..` rpath so dlopen finds them
- Media playback (Media Foundation) needs `winedmo.so` linked against a **x86_64 FFmpeg** — `scripts/build-ffmpeg-x86.sh` builds a minimal one into `vendor/ffmpeg-x86/` (no brew x86_64 ffmpeg exists on Tahoe). Without it configure silently builds a stub winedmo (check `otool -L winedmo.so` for libavformat). Wine's in-tree `libs/ffmpeg` is unrelated (swscale/swresample only)
- Release install trimming lives in `build-wine-x86.sh` (`WHISKY_WINE_BUILD=debug` skips the PE strip; `.a` import libs and man pages always dropped). Configure `--without-*` flags don't shrink anything — modules still build as stubs (e.g. wpcap.so exists despite `--without-pcap`)
- Debugging: winemac's WINEDEBUG channel is **`macdrv`**. DXMT's PE dlls load as **builtins from Wine/lib** (`x86_64-windows/`) under `=b`, NOT from the bottle's `system32` — patch the Wine-lib copy when swapping DXMT builds. Rosetta AOT cache is keyed by binary hash → rebuilt dlls re-translate automatically

## Proton migration (experimental — replacing Wine 11.13; details: docs/proton-migration.md)
- Goal: swap Whisky's x86_64 Wine 11.13 for **Valve `proton-wine` 11.0** (x86_64/Rosetta) so Proton inherits all Whisky macOS capabilities — msync fast-sync, DXMT (D3D11/10/DXGI), KosmicKrisp Vulkan, DXVK (D3D9), Steam webhelper IFEO, coreaudio virtual-device hiding, `WINE_NX_COMPAT`. D3D9/10/11 all supported.
- **Status: patch series + tooling COMMITTED to main (`f3578ac8`/`0f111132`/`256fcf5e`); Proton itself NOT the shipped stack.** Proton is **live-swapped** into `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine` (Whisky Wine backed up at `…/Libraries/Wine.whisky-bak`), DXMT built on top; reports `wine-11.0`, boots and runs (`cmd` works) after the msync crash fix. **Steam** boots through bootstrap + client + CEF webhelper. Two real msync bugs found + fixed (both in `0008`): (1) `socket()` creation failed `STATUS_OBJECT_TYPE_MISMATCH` (Steam `PlatformSocketsInit` crash) — the uniform-shadow objects couldn't be server-waited; (2) a 2.9M/s `select→OBJECT_TYPE_MISMATCH` spin ("stalled cross-thread pipe") — the `get_msync_idx` handler used the ntsync-stubbed path. After both, Steam no longer crashes/spins but **hangs at 0% CPU before webhelper** — a deeper msync lost-wakeup/deadlock (NOT the queue/driver-event path, which was instrumented and ruled out; all threads idle with no queue activity). The pre-fix "spin" masked this by delivering false `signaled=1` wakeups. Localizing it needs a per-thread pure-`__ulock`-wait stall trace — a dedicated deep sub-project. Details: memory + docs/proton-migration.md. Canonical stack is still Wine 11.13 above — this is a parallel track
- Source `vendor/proton-wine/` is **gitignored** (like `vendor/wine`; tag `proton-wine-11.0-…`). Tracked in main: `patches/proton-wine/` (15-patch series; all msync work consolidated into `0008`) + `scripts/install-proton.sh`; `scripts/build-dxmt.sh` + `scripts/build-wine-x86.sh` gained env-var / source-reset hooks. **App wiring: per-bottle Wine backend selector** — `BottleSettings.WineBackend` (`.whiskyWine` default / `.proton`), `Wine.wineBinary(for:)`/`binFolder(for:)` resolve the binary per bottle, `WhiskyWineInstaller.protonBinFolder` = `Libraries/WineProton`, `ConfigView` shows a **Proton** picker only when `isProtonInstalled()`. Proton lives side-by-side at `Libraries/WineProton` (canonical `Libraries/Wine` untouched). No plist / submodule pin yet
- `patches/proton-wine/` — disjoint file ownership, base + all 15 apply cleanly and reproduce the live tree byte-for-byte (verified): **`0001`–`0007` build/portability** (de-linux ntdll futex/TEB; winedmo FFmpeg8 PCM BSF; win32u opengl w/o libEGL; media-converter pthread; amd_ags libdrm guard; loader64 wine64; rundll32 WS_VISIBLE). **`0008`–`0013` macOS capability ports**: **`0008` msync (~52 files, ONE consolidated patch)** = CrossOver fast-sync core + boot-crash fix + `do_msync()` respects `WINEMSYNC` + `mach_msg2`→libSystem Rosetta wrapper + mixed-wait hybrid (`msync_wait_mixed_any` bounded server poll on the server subset) + **per-object msync idx for waits** (the earlier "uniform inproc_sync shadow" was mismatched to macOS — msync objects are shm+`__ulock` with no fd so the server can't wait on them — and is DROPPED: `default_get_sync()` returns the object itself, and the `get_msync_idx` server handler uses each object's own `get_msync_idx` slot gated on non-server-waitable sync, not the ntsync-only `get_obj_inproc_sync`). `0009` winemac DXMT support, `0010` kernelbase IFEO Debugger, `0011` `WINE_NX_COMPAT` env, `0012` coreaudio hide virtual devices, `0013` server fsync de-linux. **`0014`–`0015` Steam-runtime deadlock fixes**: `0014` combase rpcss cold-start race (`WaitNamedPipe` on `\\.\pipe\lrpc\irpcss` before returning; steam.exe raced ahead of rpcss → uncaught `RPC_S_SERVER_UNAVAILABLE` crash), `0015` ntdll FLS-callback-no-lock (drop `fls_section` around FLS destructor callbacks — **upstream Wine bug**: callback-under-lock inversion deadlocks Steam's bootstrap→client handoff). Build `0014`/`0015` into PE `combase.dll`/`ntdll.dll` **both arches** (steam.exe is 32-bit)
- **msync crash fix** (in `0008`): Proton's wineserver crashed at bottle init — `server/event.c` `req_event_op` hit `assert(event->sync->ops==&event_sync_ops)` on a garbage `event->sync`, because with `do_msync()` on `get_event_obj` hands back an msync obj cast as `struct event` (`sync` field at a different offset). The port had lost the `if (do_msync()) return msync_*` guards in `NtResetEvent`/`NtPulseEvent` (and `NtSetEvent` piled all branches together); fix restores each guard + adds the msync branch to `NtWaitForSingleObject`. Diagnosed via **live lldb** — dead Rosetta cores only show ARM64 host regs, never guest x86_64 frames
- `scripts/install-proton.sh` — installs `vendor/proton-wine/build` into a self-contained `Wine/` dir (default `INSTALL_DIR=vendor/proton-wine/dist`) mirroring `build-wine-x86.sh`: bundles x86_64 dylibs + ffmpeg, KosmicKrisp loader swap (Khronos loader as BOTH `libMoltenVK.dylib` and `libvulkan.1.dylib` + ICD manifest), rpath-patches `x86_64-unix/*.so`, sets wine.inf `Graphics=mac`, symlinks `wine64→wine`. **`INSTALL_TO_WHISKY=1`** also lays the tree directly into `Libraries/WineProton` (the app's `.proton` backend path — pick it per-bottle in Config → Wine Backend); or `cp -R` the whole stack over `Libraries/Wine` to replace Whisky Wine outright
- DXMT against Proton: `scripts/build-dxmt.sh` now reads `DXMT_WINE_BUILD` / `DXMT_WINE_LIB` (default the Whisky Wine) — `DXMT_WINE_BUILD=vendor/proton-wine/build DXMT_WINE_LIB=<ProtonInstall>/Wine/lib/wine` builds DXMT against Proton
- Mono: Proton hardcodes `wine-mono-10.4.1` (`dlls/appwiz.cpl/addons.c`). Decision: **don't build from source** — let `wineboot` install it at runtime; the `.msi` fetches to `~/.cache/wine/` via the system proxy (`dl.winehq.org` GFW-blocked directly, reachable via `127.0.0.1:9910`)
- **Steam-on-Proton launch gotchas** (from `WhiskyCmd shellenv`): (1) **Follow System Proxy injects the geph/VPN HTTP proxy** (`http_proxy=127.0.0.1:9910`) which **breaks Steam's CM** (WSS→403); CMs are directly reachable (`cellid=47` → `103.28.54.x:27017`) so **turn the toggle OFF** for the Steam bottle when a proxy-mode VPN is up. (2) Env sets both `WINEESYNC=1`+`WINEMSYNC=1` — macOS has no eventfd for esync, should be msync-only. (3) Steam is NOT hindered by network/VPN/winsock (manifest downloads direct) NOR by msync (patch `0017` proved sync is correct); the open blocker is the client self-exiting ~35s in at the steam.exe↔steamwebhelper handshake (CEF starts fine per `logs/webhelper.txt`, client times out before CM) — most consistent with Rosetta emulation perf, so next avenues are profiling/speeding the webhelper CEF startup, not more msync work. Test via GUI + Steam Play; CLI launch also needs `whisky steam-fix <bottle>` first (webhelper wrapper)

## Unity fullscreen "empty top bar" (空栏) — Steam D3D11 games
- Unity fullscreen games show a ~32px macOS title bar + menu-bar Y offset: **not DXMT** — Unity's player re-adds `WS_CAPTION` after `WM_ACTIVATEAPP` when its fullscreen handshake fails under a non-Windows WM
- Workaround: Steam Launch Options `-popupwindow -screen-fullscreen 0` (genuine borderless `WS_POPUP`; stored in `userdata/<id>/config/localconfig.vdf`, edit with Steam closed)
- Patches `0003`/`0004` make the borderless window land edge-to-edge; verify via CoreGraphics bounds — clean is `0,0 — 1280×832`, reverted is `…×864` (+32 caption)

## Xbox controller (verified 2026-07-20)
- Bluetooth pads (model 1708+/Series) work end-to-end: macOS BT-HID → winebus SDL backend → winexinput → XInput. One required env var: **`SDL_JOYSTICK_MFI=0`** (set in `constructWineEnvironment` AND `constructWineServerEnvironment`) — macOS 27.0 beta's GameController framework enumerates pads but delivers zero input (same shape as the 26.0 regression); the hint forces SDL onto its working HIDAPI/IOKit path, rumble kept. Revisit at GA. winebus reads env at startup only → `wineserver -k` after changes
- Wired USB: macOS 15+ has a native GIP driver (untested; charge-only cables = pad LED stays dark). Xbox Wireless Adapter dongle (045E:02FE): **no macOS driver exists**; Linux xow/xone are the references if a port is ever wanted
- Layer probes + debug ladder: `tests/controller/`

## Vulkan backend: KosmicKrisp (Metal 4) — replaces MoltenVK
- Mesa KosmicKrisp (Vulkan-on-Metal-4, conformant 1.4): `vendor/mesa` (shallow, tracks `main`), built by `scripts/build-kosmickrisp-x86.sh` (two-phase: arm64 `mesa_clc`, then x86_64 cross; applies `patches/mesa/*`; artifacts → `vendor/kosmickrisp/`)
- Wiring: the **x86_64 Khronos Vulkan loader** is installed as BOTH `Wine/lib/libMoltenVK.dylib` and `Wine/lib/libvulkan.1.dylib` — winevulkan dlopens one of those leaf names depending on which keg Wine's configure saw (vulkan-loader keg present ⇒ `libvulkan.1.dylib`); the loader exports `vkGetInstanceProcAddr`, the Mesa ICD doesn't. ICD manifest at `~/.local/share/vulkan/icd.d/kosmickrisp_icd.x86_64.json`. **`build-wine-x86.sh` owns the swap** (fires only when `vendor/kosmickrisp/` exists). No MoltenVK backup kept — recoverable from the x86 brew `molten-vk` keg. Bundling materializes brew link-farm symlinks (`cp -L`) — a preserved `../Cellar/...` link is dangling inside the bundle
- `patches/mesa/0001` = unmerged Mesa **MR 42811** (present-queue residencySet; without it Metal 4 presents black). Drop when merged
- Keep the pin fresh (~35 commits/month): `git submodule update --remote vendor/mesa`, rebuild, re-check whether `patches/mesa/*` and DXVK optional-feature workarounds (e.g. `fillModeNonSolid`) are still needed. Progress tracker: `scripts/check-kosmickrisp-progress.sh`
- Verified 2026-07-18: Witch on the Holy Night (D3D9/64-bit) renders via DXVK → loader → KosmicKrisp → Metal 4 under Rosetta

## D3D9 games via DXVK
- wined3d is broken for D3D9 on macOS (GL backend: `GL_INVALID_FRAMEBUFFER_OPERATION` black screen; Vulkan backend: no fixed-function support); DXMT doesn't do D3D9 → DXVK fills the gap
- `vendor/dxvk` (upstream v3.0) built d3d9-only, win32+win64, by `make dxvk` (applies `patches/dxvk/*`). Stock DXVK can't init on Apple GPUs — `0001` makes missing device features optional (`geometryShader`, `fillModeNonSolid`, …), `0002` forces `primitiveRestartEnable` for strip/fan, `0003` static vertex strides, `0004` dummy buffer for unbound vertex streams. Some trace to MoltenVK limits — re-check against KosmicKrisp when updating
- Games shipping native `d3dx9_NN.dll` need it (`d3dx9_30=native`): Wine's builtin forwards to its incomplete d3dcompiler (`assemble_shader Asm reading failed`). Whisky's auto-drop sets per-game `d3d9=native,builtin`; beware **global** registry DllOverrides affect every game in the bottle
- Test-game specifics, MoltenVK-era saga (residency device-loss patch → MoltenVK PR #2762, black-window analysis, debug tooling): `docs/moltenvk-d3d9-history.md`

## Steam notes (details: docs/steam-webhelper-ifeo.md)
- Black CEF window fixed by the IFEO-attached wrapper (needs `patches/wine/0001`); on-disk `steamwebhelper.exe` stays byte-identical to Valve's so `BVerifyInstalledFiles` passes. `Steam.swift` (`Wine.configureSteam`) re-asserts wrapper + registry on every launch; CLI: `whisky steam-fix <bottle>`. 64-bit CEF dirs only
- Update stuck behind proxy/GFW: enable the bottle's **Follow System Proxy** toggle (`SystemProxy.swift` resolves PAC → injects `http_proxy` etc.). Irrelevant for VPN/TUN
- WoW64 caveat: hand-driven `wineboot --init` may leave `syswow64` unpopulated → 32-bit `steam.exe` fails `c0000135`; GUI/WhiskyCmd bottle creation handles it
- Launch games from the **Steam Play button** (Steamworks ready), not bare CLI; churned wineserver shows as orphan `explorer.exe` Dock icons + instant exits → reboot

## Distribution URLs
- Version plist: `https://cyyever.github.io/Whisky/WhiskyWineVersion.plist`
- Libraries download: `https://github.com/cyyever/Whisky/releases/download/v{version}/Libraries.tar.gz`
- Appcast: `https://cyyever.github.io/Whisky/appcast.xml`

## Dependencies
- SemanticVersion 0.5.1, swift-argument-parser 1.7.1, SwiftyTextTable 0.9.0

## Coding conventions
- Swift 6.3, macOS 26.0 deployment target; SwiftLint strict (25+ opt-in rules, custom file header); GPL v3
- `vendor/` and build artifacts excluded from SwiftLint
