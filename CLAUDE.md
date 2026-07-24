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

## Proton migration (experimental — parallel track; canonical shipped stack is still Wine 11.13 above; details: docs/proton-migration.md)
- Goal: swap Whisky's x86_64 Wine 11.13 for **Valve `proton-wine` 11.0** (x86_64/Rosetta) so Proton inherits all Whisky macOS capabilities — msync, DXMT (D3D11/10/DXGI), KosmicKrisp Vulkan, DXVK (D3D9), Steam webhelper IFEO, coreaudio virtual-device hiding, `WINE_NX_COMPAT`
- **Status (2026-07-24): Steam logs in fully under msync.** Proton is live-swapped into `Libraries/Wine` (Whisky Wine backed up at `Libraries/Wine.whisky-bak`), DXMT built on top; reports `wine-11.0`. With **minimal msync** (`WINEMSYNC=1 WINEMSYNC_NO_SEMAPHORE=1 WINEMSYNC_NO_MUTEX=1 WINEMSYNC_NO_EVENT=1`, guest `http_proxy`/`https_proxy` unset) Steam boots → CEF webhelper → full CM logon (`RecvMsgClientLogOnResponse : 'OK'` + JWT, real SteamID; login window interactive; zero `OBJECT_TYPE_MISMATCH`)
- **Fixed since:** the `server/event.c req_event_op`/`query_event` `EXC_BAD_ACCESS` on `event->sync->ops` (msync object cast as `struct event`) — both handlers now branch on `obj.ops==&msync_ops` and read state via `msync_get_event_state()`/`msync_is_manual_event()` (committed `f41ab4b8`, in `0008`). The unified event-driven mixed-wait bridge's `get_sync` fix (subscribe the bridge to `obj->ops->get_sync(obj)`, not the handle object — server-backed objects wake through a separate sync obj so `wake_up` fired there, missing 100% of bridge signals) makes full msync boot + log in via the bridge (committed `f106896a`; `WINEMSYNC_UNIFIED` still opt-in). **Remaining:** a residual full-msync 100%-CPU spin — an app-level busy-poll (`WaitForMultipleObjects(timeout=0)`) of a small set of events (the known fsync/esync 100%-CPU class), **NOT yet reliably localized** (see lever note below). The bisection levers exist to narrow it further
- msync bisection levers (env, read by `dlls/ntdll/unix/msync.c`): `WINEMSYNC_NO_EVENT` (all events→server-sync), `NO_AUTOEVENT` (auto-reset events→server), and the finer **`NO_ANON_AUTOEVENT`** / `NO_NAMED_AUTOEVENT` (split auto-events by whether they're named vs anonymous). The confirmed-good levers (`NO_SEMAPHORE`/`NO_MUTEX`/`NO_MANUALEVENT`) were removed — semaphore/mutex/manual-event are always on msync now. These levers exist to bisect the residual full-msync spin; **do not treat any one as "the fix" or the confirmed default.** **Localization RETRACTED (2026-07-24):** an earlier note claimed the spin was "caused by ANONYMOUS auto-reset events" and that `WINEMSYNC_NO_ANON_AUTOEVENT=1` makes Steam "log in + settle to normal CPU" — both retracted. Re-verification showed the ~20k/s busy-poll (`MSYNCSPIN … timeout=0`) is on a **MANUAL event (type=3)**, not an auto-reset event, and steam.exe was still seen at ~98% CPU with `NO_ANON_AUTOEVENT=1` set. So the spin is **NOT reliably localized** and no lever is a confirmed default; whether it is a genuine upstream Steam producer stall or a msync lost-wake is unproven. Needs re-verification. Server-side `WINE_EVT_TRACE` + client `WINE_MRING`/`WINE_BRIDGE_TRACE`/`MSYNCSPIN` are the env-gated diagnostics for that
- Source `vendor/proton-wine/` **gitignored** (tag `proton-wine-11.0-…`). Tracked in main: `patches/proton-wine/` (15-patch series) + `scripts/install-proton.sh`; `scripts/build-dxmt.sh` + `scripts/build-wine-x86.sh` gained env-var / source-reset hooks
- **App wiring — per-bottle backend selector**: `BottleSettings.WineBackend` (`.whiskyWine` default / `.proton`); `Wine.wineBinary(for:)`/`binFolder(for:)` resolve per bottle; `WhiskyWineInstaller.protonBinFolder` = `Libraries/WineProton`; `ConfigView` shows a Proton picker when `isProtonInstalled()`. Proton lives side-by-side at `Libraries/WineProton` (canonical `Libraries/Wine` untouched)
- **Patch map** (`patches/proton-wine/`, disjoint file ownership, base `81d78e4`; all 15 apply cleanly and reproduce the live tree byte-for-byte, re-verified 2026-07-24 after the 0016→0008 merge):
  - `0001`–`0007` build/portability: de-linux ntdll futex/TEB; winedmo FFmpeg8 PCM BSF; win32u opengl w/o libEGL; media-converter pthread; amd_ags libdrm guard; loader64 wine64; rundll32 WS_VISIBLE
  - `0008` **msync (~55 files, ONE consolidated patch, incl. regenerated protocol files so a fresh apply needs no make_requests)** = CrossOver fast-sync core + boot-crash fix + `do_msync()` respects `WINEMSYNC` + `mach_msg2`→libSystem Rosetta wrapper + mixed-wait hybrid (`msync_wait_mixed_any`) + per-object msync idx for waits + msg-queue wake consistency (was patch 0016) + socket-async/system-APC lost-wake fix (`msync_run_system_apcs()` drains system APCs on the SIGUSR1/EINTR interrupt so socket async completions deliver — the fix that made Steam log in) + experimental `WINEMSYNC_UNIFIED` event-driven mixed-wait bridge
  - `0009`–`0013` macOS capability ports: `0009` winemac DXMT, `0010` kernelbase IFEO Debugger, `0011` `WINE_NX_COMPAT` env, `0012` coreaudio hide virtual devices, `0013` server fsync de-linux
  - `0014`–`0015` Steam-runtime deadlock fixes (build into PE `combase.dll`/`ntdll.dll` **both arches** — steam.exe is 32-bit): `0014` combase rpcss cold-start race (`WaitNamedPipe` on `\\.\pipe\lrpc\irpcss`), `0015` ntdll FLS-callback-no-lock (drop `fls_section` around FLS callbacks — **upstream Wine bug**)
- `scripts/install-proton.sh` — installs `vendor/proton-wine/build` into a self-contained `Wine/` dir (default `INSTALL_DIR=vendor/proton-wine/dist`): bundles x86_64 dylibs + ffmpeg, KosmicKrisp loader swap, rpath-patches `x86_64-unix/*.so`, `wine.inf Graphics=mac`, `wine64→wine`. **`INSTALL_TO_WHISKY=1`** lays it into `Libraries/WineProton`; or `cp -R` over `Libraries/Wine` to replace outright
- DXMT vs Proton: `scripts/build-dxmt.sh` reads `DXMT_WINE_BUILD` / `DXMT_WINE_LIB` — `DXMT_WINE_BUILD=vendor/proton-wine/build DXMT_WINE_LIB=<ProtonInstall>/Wine/lib/wine`
- Mono: Proton hardcodes `wine-mono-10.4.1` — **don't build from source**; `wineboot` installs the `.msi` at runtime (fetched to `~/.cache/wine/` via proxy; `dl.winehq.org` GFW-blocked direct)
- **Steam-on-Proton gotchas**: (1) turn **Follow System Proxy OFF** — the geph HTTP proxy breaks Steam's CM (WSS→403); CMs are directly reachable. (2) msync-only (`WINEESYNC=0`) — macOS has no eventfd for esync. (3) `PROTON_DISABLE_LSTEAMCLIENT=1` (wired into `Wine.swift`) fixes the Proton lsteamclient tier0 crash ("reinstall Steam" box). (4) NOT a network/VPN/winsock issue (host reaches Steam HTTP direct; only raw CM ports GFW-blocked). CLI launch needs `whisky steam-fix <bottle>` first

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
- Mesa **MR 42811** (present-queue residencySet; without it Metal 4 presented black) is now **merged upstream** (mesa `51ffe55` + `f16bbbf`), so `patches/mesa/0001` was dropped — `patches/mesa/` is now **empty** (no mesa patches remain). The `8b794a5` bump also brings upstream `VK_KHR_present_id`/`VK_KHR_present_wait` (mesa `ffedd67`)
- Keep the pin fresh (~35 commits/month): `git submodule update --remote vendor/mesa`, rebuild, re-check whether `patches/mesa/*` and DXVK optional-feature workarounds (e.g. `fillModeNonSolid`) are still needed. Progress tracker: `scripts/check-kosmickrisp-progress.sh`
- Verified 2026-07-18: Witch on the Holy Night (D3D9/64-bit) renders via DXVK → loader → KosmicKrisp → Metal 4 under Rosetta

## D3D9 games via DXVK
- wined3d is broken for D3D9 on macOS (GL backend: `GL_INVALID_FRAMEBUFFER_OPERATION` black screen; Vulkan backend: no fixed-function support); DXMT doesn't do D3D9 → DXVK fills the gap
- `vendor/dxvk` (upstream v3.0.2, pin `1a5919b7`) built d3d9-only, win32+win64, by `make dxvk` (applies `patches/dxvk/*`, 4 patches, still apply unchanged). Stock DXVK can't init on Apple GPUs — `0001` makes missing device features optional (`geometryShader`, `fillModeNonSolid`, …), `0002` forces `primitiveRestartEnable` for strip/fan, `0003` static vertex strides, `0004` dummy buffer for unbound vertex streams. Some trace to MoltenVK limits — re-check against KosmicKrisp when updating
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
