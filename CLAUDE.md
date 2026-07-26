# Whisky - Wine wrapper for macOS

## Current TODO (2026-07-25)
- **Proton-lock in UI — DONE.** App builds, bottle created via GUI this session launches on Proton with the backend selector gone (`58e81664`, `fceffe4e`); the bottle config is now Steam-gaming-focused/Proton-locked. Nothing left here.
- **msync conformance — fixed 4 of the 6 msync-only NT-sync failures; 2 remain.** All fixes are folded into `patches/proton-wine/0008-macos-msync.patch` (mutex `NtReleaseMutant` previous-count, msync/fsync alertable `NtDelayExecution` `STATUS_TIMEOUT`→`STATUS_SUCCESS`, wait-path `SYNCHRONIZE` access-rights enforcement, `NtPulseEvent` server-fallthrough). Validate with `scripts/test-msync.sh` (WINEMSYNC=1 vs =0 conformance diff; `--guard-malloc` for heap checks; PEs built by `scripts/build-msync-tests.sh`).
  - **Still open (deferred, risky):** kernel32:sync test:393/397 **abandoned-mutex** — msync tracks mutex ownership client-side only, so the object is freed at last handle-close before the owner thread's `TerminateThread` runs `msync_abandon_mutexes`. Needs server-side ownership refcounting. In progress in a separate task; NOT committed.
- **[Next session] Finer-grain `WINEMSYNC_NO_ANON_AUTOEVENT` masking — enable more msync.** Today `Wine.swift` wires `WINEMSYNC_NO_ANON_AUTOEVENT=1`, and `event_uses_msync()` (`dlls/ntdll/unix/msync.c:1112`) routes **all** anonymous auto-reset events → wineserver sync. That's coarse (Steam makes many harmless anon auto-events; only a small cluster is pathological), so lots of events needlessly lose fast-sync. The ~20k/s busy-poll spin root-cause is **still open**. Goal: mask only the offending object(s), keep the rest on msync.
  - Discriminators available at `msync_create_event`: only type (auto/manual), named/anon, initial-state, access — none uniquely tags the busy-poll set.
  - **KEY UNCERTAINTY (verify FIRST):** the retracted localization re-observed the ~20k/s busy-poll on a **MANUAL** event (type=3), which `NO_ANON_AUTOEVENT` never touches — so the current lever may be masking the wrong class, and dropping it might not regress the spin. Re-verify which exact `shm_idx`/object(s) spin via `WINE_EVT_TRACE` / `MSYNCSPIN` / `WINE_MRING` before changing anything.
  - Approaches (finest→coarsest): (1) adaptive per-object denylist — count `timeout=0` waits per `shm_idx`, demote only a busy-poll offender to server-sync (hard: needs a runtime server-forward flag on a live msync object); (2) identity/heuristic gate in `event_uses_msync` if offenders share a creation trait; (3) fix-not-mask — make the manual-event msync wait not spin so no lever is needed.
  - Steps: (a) trace to pin the spinning object; (b) if it's a manual event, test **dropping** `NO_ANON_AUTOEVENT` (enables msync for all anon auto-events); (c) implement the narrowest mask that holds the spin down while maximizing msync coverage.
  - **Dead-msync-path cleanup — DEFER until the spin is root-caused, don't remove now.** `dlls/ntdll/unix/msync.c` carries residual paths from refactors/experiments (the env-gated `WINEMSYNC_UNIFIED` event-driven bridge vs the default mixed-wait poll, plus the bisection levers). These are NOT truly dead — they're env-gated diagnostics/experiments the spin investigation above still needs, in the most Steam-login-critical file. Remove whichever path loses (bridge adopted ⇒ poll dead, or bridge abandoned ⇒ bridge dead) as the natural cleanup *after* the spin is resolved.
- **SF4 (Ultra Street Fighter IV, appid 45760) black screen — paused.** DXVK d3d9.dll (32-bit) is correctly auto-dropped next to `SSFIV.exe`; d3dx9_43 present. Blocker last session: **Steam was logged off** (`[Logged Off, 0, 0]`), so `-applaunch 45760` never started the game. → next: relog Steam (Follow System Proxy OFF), launch SF4 from the **Steam Play button**, capture `DXVK_LOG_LEVEL=info DXVK_LOG_PATH=<dir>` to see which render stage fails.

## Project overview
Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived). A SwiftUI macOS app that wraps Wine for running Windows games via Steam on Apple Silicon.

## Architecture
- **Whisky app** — SwiftUI macOS app (Xcode project); **WhiskyKit** — Swift package (Wine management, bottle settings, process execution)
- **Wine** — x86_64 **Proton-wine 11.0** built from source (`make proton`), runs via Rosetta 2 (source `vendor/proton-wine`; see Proton section). Legacy Whisky-Wine 11.13 (`vendor/wine`) is deprecated and no longer built.
- **DXMT** — Metal-native D3D11/D3D10/DXGI (submodule `vendor/dxmt`, `make dxmt` installs it as the Wine builtin; bottles enable via `WINEDLLOVERRIDES=d3d11,d3d10core,dxgi,winemetal=b`)
- **DXVK** — **D3D9-only** here (see D3D9 section); **KosmicKrisp** — Wine's Vulkan backend (see Vulkan section)
- **SteamHelper** — `webhelper_wrapper.c`, PE launcher attached via IFEO fixing Steam's black window (see Steam notes)

## Build instructions
```bash
make setup-x86-brew  # one-time: x86_64 Homebrew + deps in vendor/
make proton          # build Proton (auto-applies patches/proton-wine/*.patch, resets tracked source to HEAD first); release install: strips PE debug info, drops .a/man
make proton-debug    # reinstall keeping PE debug info for winedbg (build tree always has -g)
make dxmt            # build DXMT and install as Wine builtin (needs full Xcode + llvm@15)
make dxvk            # build DXVK d3d9.dll (win32+win64) into Libraries/DXVK
make steam-helper    # cross-compile the Steam webhelper wrapper (mingw)
make app / make run  # build Whisky app / build and launch
```

## Fresh-machine bootstrap (decisions live in code — no manual adaptation)
1. `git clone --recurse-submodules`; install ARM brew deps (`bison mingw-w64 meson ninja llvm libclc spirv-llvm-translator spirv-tools nasm`)
2. `make setup-x86-brew` (x86_64 brew + linked libs, USTC mirrors)
3. `scripts/build-ffmpeg-x86.sh` (winedmo media backend) and `scripts/build-kosmickrisp-x86.sh` (Vulkan driver) — **before** `make proton`, which bundles both and asserts the KosmicKrisp loader swap
4. `make proton`, then `make dxmt` and `make dxvk`
5. Open Whisky, create bottle, install Steam via the bottle's **Install / Run** menu (auto-downloads Valve's `SteamSetup.exe` and runs it; the menu also lists Epic/GOG/EA/Ubisoft/Battle.net installers and a "pick a local .exe/.msi/.bat" option, but **only Steam is a validated runtime path**), log in — the rest is automatic: Steam launch installs the webhelper wrapper, auto-drops the right-arch DXVK `d3d9.dll` next to d3d9 games' executables (PE import scan) and sets `d3d9=native,builtin`. Re-run `make proton` after rebuilding KosmicKrisp to re-assert the loader swap.

## Key paths
- **Build source is Proton** (`vendor/proton-wine` + `patches/proton-wine/`, see Proton section) — `make proton` is the only Wine build. Legacy Whisky-Wine 11.13 (`vendor/wine` submodule + `patches/wine/`) has been **removed entirely**; its macOS-capability patches are folded into `patches/proton-wine/` (`0009`≈old `0002`+`0005`+`0006`, `0010`≈`0003`, `0011`≈`0004`, `0012`≈`0007`; the old rundll32 WS_VISIBLE patch is obsolete — proton 11.0 has no wineboot deadlock).
- x86 Homebrew: `vendor/homebrew-x86/` (gitignored); build scripts in `scripts/`
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`; bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`

## Wine build notes
- Native ARM64 Wine does NOT work on macOS (preloader_mac.c lacks aarch64) — build x86_64, run under Rosetta; `--enable-archs=i386,x86_64` for WoW64 (Steam is 32-bit)
- Toolchain split: x86 brew provides only the **libraries linked into Wine** (freetype, gnutls, sdl2, gettext, MoltenVK); **build tools** (bison keg, pkg-config, mingw-w64) come from ARM brew — arch-independent or PE-targeting, saves ~400 MB
- Dylibs bundled into Wine/lib with symlink chains preserved (`cp -Rn`); unix `.so` modules get an `@loader_path/../..` rpath so dlopen finds them
- Media playback (Media Foundation) needs `winedmo.so` linked against a **x86_64 FFmpeg** — `scripts/build-ffmpeg-x86.sh` builds a minimal one into `vendor/ffmpeg-x86/` (no brew x86_64 ffmpeg exists on Tahoe). Without it configure silently builds a stub winedmo (check `otool -L winedmo.so` for libavformat). Wine's in-tree `libs/ffmpeg` is unrelated (swscale/swresample only)
- Release install trimming lives in `build-proton-x86.sh` (`WHISKY_WINE_BUILD=debug` skips the PE strip; `.a` import libs and man pages always dropped). Configure `--without-*` flags don't shrink anything — modules still build as stubs (e.g. wpcap.so exists despite `--without-pcap`)
- Debugging: winemac's WINEDEBUG channel is **`macdrv`**. DXMT's PE dlls load as **builtins from Wine/lib** (`x86_64-windows/`) under `=b`, NOT from the bottle's `system32` — patch the Wine-lib copy when swapping DXMT builds. Rosetta AOT cache is keyed by binary hash → rebuilt dlls re-translate automatically

## Proton backend (shipped default; debugging history: docs/proton-migration.md)
- **Valve `proton-wine` 11.0** (x86_64/Rosetta) is the default and only user-facing backend. It inherits all Whisky macOS capabilities — msync, DXMT (D3D11/10/DXGI), KosmicKrisp Vulkan, DXVK (D3D9), Steam webhelper IFEO, coreaudio virtual-device hiding, `WINE_NX_COMPAT`. Steam logs in fully under msync; reports `wine-11.0`
- **App wiring**: single backend — Proton laid directly over `Libraries/Wine`. The old `WineBackend` enum, the ConfigView backend selector, and `WhiskyWineInstaller.protonBinFolder`/side-by-side `Libraries/WineProton` plumbing are all **removed**; `Wine.binFolder(for:)`/`wineBinary(for:)` resolve to `WhiskyWineInstaller.binFolder` (`Libraries/Wine/bin`). `BottleWineConfig.enhancedSync` defaults to `.msync`; a legacy `.esync` bottle is decode-migrated to `.msync` (no eventfd on macOS, so esync never applied)
- **Install layout**: `make proton` (`scripts/build-proton-x86.sh`) builds + installs Proton to `Libraries/Wine` — the single shipped backend; DXMT built on top. The script does the full install (dylib bundle, KosmicKrisp loader swap, rpath fixups, wine.inf graphics-driver patch, version plist) against `vendor/proton-wine` + `patches/proton-wine`.
- Source `vendor/proton-wine/` **gitignored** (tag `proton-wine-11.0-…`). Tracked in main: `patches/proton-wine/` (14-patch series — `0001`–`0006`, `0008`–`0015`, gap at `0007`; disjoint file ownership, base `81d78e4`) + `scripts/build-proton-x86.sh` (resets tracked source to HEAD + applies the series, reverse-check-skipping ones already committed in HEAD); `scripts/build-dxmt.sh` defaults `DXMT_WINE_BUILD` to `vendor/proton-wine/build`. What each patch does and the migration debugging log live in **docs/proton-migration.md** — keep bug detail there, not here
- DXMT vs Proton: `scripts/build-dxmt.sh` reads `DXMT_WINE_BUILD` / `DXMT_WINE_LIB` — `DXMT_WINE_BUILD=vendor/proton-wine/build DXMT_WINE_LIB=<ProtonInstall>/Wine/lib/wine`
- Mono: Proton hardcodes `wine-mono-10.4.1` — **don't build from source**; `wineboot` installs the `.msi` at runtime (fetched to `~/.cache/wine/` via proxy; `dl.winehq.org` GFW-blocked direct)
- **Steam-on-Proton gotchas**: (1) turn **Follow System Proxy OFF** — the geph HTTP proxy breaks Steam's CM (WSS→403); CMs are directly reachable. (2) msync-only: nothing on the stack reads WINEESYNC (no `esync.c` in the wine tree; DXMT doesn't read it — verified by binary scan) and macOS has no eventfd, so `BottleSettings.swift` sets only `WINEMSYNC=1` and leaves WINEESYNC unset — the env dict fully replaces the parent, so unset ≡ 0. (3) `PROTON_DISABLE_LSTEAMCLIENT=1` (wired into `Wine.swift`) fixes the Proton lsteamclient tier0 crash ("reinstall Steam" box). (4) NOT a network/VPN/winsock issue (host reaches Steam HTTP direct; only raw CM ports GFW-blocked). The Steam webhelper wrapper is applied automatically on launch (GUI `Steam.configureSteam`, or `whisky run`'s `Wine.prepareForLaunch`)

## Unity fullscreen "empty top bar" (空栏) — Steam D3D11 games
- Some Unity fullscreen games show a ~32px macOS title bar offset. Workaround: Steam Launch Options `-popupwindow -screen-fullscreen 0` (borderless `WS_POPUP`; stored in `userdata/<id>/config/localconfig.vdf`, edit with Steam closed). Patches `0003`/`0004` make the borderless window land edge-to-edge

## Xbox controller (verified 2026-07-20)
- Bluetooth pads (model 1708+/Series) work end-to-end: macOS BT-HID → winebus SDL backend → winexinput → XInput. One required env var: **`SDL_JOYSTICK_MFI=0`** (set in `constructWineEnvironment` AND `constructWineServerEnvironment`) — macOS 27.0 beta's GameController framework enumerates pads but delivers zero input (same shape as the 26.0 regression); the hint forces SDL onto its working HIDAPI/IOKit path, rumble kept. Revisit at GA. winebus reads env at startup only → `wineserver -k` after changes
- Wired USB: macOS 15+ has a native GIP driver (untested; charge-only cables = pad LED stays dark). Xbox Wireless Adapter dongle (045E:02FE): **no macOS driver exists**; Linux xow/xone are the references if a port is ever wanted
- Layer probes + debug ladder: `tests/controller/`

## Vulkan backend: KosmicKrisp (Metal 4) — replaces MoltenVK
- Mesa KosmicKrisp (Vulkan-on-Metal-4, conformant 1.4): `vendor/mesa` (shallow, tracks `main`), built by `scripts/build-kosmickrisp-x86.sh` (two-phase: arm64 `mesa_clc`, then x86_64 cross; applies `patches/mesa/*`; artifacts → `vendor/kosmickrisp/`)
- Wiring: the **x86_64 Khronos Vulkan loader** is installed as BOTH `Wine/lib/libMoltenVK.dylib` and `Wine/lib/libvulkan.1.dylib` — winevulkan dlopens one of those leaf names depending on which keg Wine's configure saw (vulkan-loader keg present ⇒ `libvulkan.1.dylib`); the loader exports `vkGetInstanceProcAddr`, the Mesa ICD doesn't. ICD manifest at `~/.local/share/vulkan/icd.d/kosmickrisp_icd.x86_64.json`. **`build-proton-x86.sh` owns the swap** (fires only when `vendor/kosmickrisp/` exists). No MoltenVK backup kept — recoverable from the x86 brew `molten-vk` keg. Bundling materializes brew link-farm symlinks (`cp -L`) — a preserved `../Cellar/...` link is dangling inside the bundle
- Mesa **MR 42811** (present-queue residencySet; without it Metal 4 presented black) is now **merged upstream** (mesa `51ffe55` + `f16bbbf`), so `patches/mesa/0001` was dropped — `patches/mesa/` is now **empty** (no mesa patches remain). The `8b794a5` bump also brings upstream `VK_KHR_present_id`/`VK_KHR_present_wait` (mesa `ffedd67`)
- Keep the pin fresh (~35 commits/month): `git submodule update --remote vendor/mesa`, rebuild, re-check whether `patches/mesa/*` and DXVK optional-feature workarounds (e.g. `fillModeNonSolid`) are still needed. Progress tracker: `scripts/check-kosmickrisp-progress.sh`
- Verified 2026-07-18: Witch on the Holy Night (D3D9/64-bit) renders via DXVK → loader → KosmicKrisp → Metal 4 under Rosetta

## D3D9 games via DXVK
- wined3d is broken for D3D9 on macOS (GL backend: `GL_INVALID_FRAMEBUFFER_OPERATION` black screen; Vulkan backend: no fixed-function support); DXMT doesn't do D3D9 → DXVK fills the gap
- `vendor/dxvk` (upstream v3.0.2, pin `1a5919b7`) built d3d9-only, win32+win64, by `make dxvk` (applies `patches/dxvk/*`, 4 patches, still apply unchanged). Stock DXVK can't init on Apple GPUs — `0001` makes missing device features optional (`geometryShader`, `fillModeNonSolid`, …), `0002` forces `primitiveRestartEnable` for strip/fan, `0003` static vertex strides, `0004` dummy buffer for unbound vertex streams. Some trace to MoltenVK limits — re-check against KosmicKrisp when updating
- Games shipping native `d3dx9_NN.dll` need it (`d3dx9_30=native`): Wine's builtin forwards to its incomplete d3dcompiler (`assemble_shader Asm reading failed`). Whisky's auto-drop sets per-game `d3d9=native,builtin`; beware **global** registry DllOverrides affect every game in the bottle

## Steam notes (details: docs/steam-webhelper-ifeo.md)
- Black CEF window fixed by the IFEO-attached wrapper (needs the Wine IFEO `Debugger` support, `patches/proton-wine/0010`); on-disk `steamwebhelper.exe` stays byte-identical to Valve's so `BVerifyInstalledFiles` passes. `Steam.swift` (`Wine.configureSteam`) re-asserts wrapper + registry on every launch; `whisky run` applies it too via `Wine.prepareForLaunch`. 64-bit CEF dirs only
- Update stuck behind proxy/GFW: enable the bottle's **Follow System Proxy** toggle (`SystemProxy.swift` resolves PAC → injects `http_proxy` etc.). Irrelevant for VPN/TUN
- CEF GPU: the shipped wrapper appends only `--no-sandbox --in-process-gpu`; CEF renders correctly on wined3d (GLES 2.0). An ANGLE-Vulkan ES3 route is shelved (flickers). GPU-backend analysis and the ES3 experiment live in docs/steam-webhelper-ifeo.md §1
- Always launch Steam with the **full bottle env** (what `Program.launch` / `WhiskyCmd run` build from `BottleSettings.environmentVariables()`) — a minimal env missing `WINEDLLOVERRIDES=…winemetal=b` + `DYLD_FALLBACK_LIBRARY_PATH` makes `steam.exe` spin with no login window. Kill cleanly with `pkill -9 -f steamwebhelper` (+ `cef.win64`), not just `steam.exe` (or use the automatic reap in `Steam.reapCEFProcesses`)
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
