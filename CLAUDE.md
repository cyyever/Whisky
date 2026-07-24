# Whisky - Wine wrapper for macOS

## Current TODO (2026-07-24, across reboot)
- **Verify Proton-lock in UI**: the Proton-as-default backend change is committed (`58e81664`; WhiskyKit compiles) but `make app` has NOT been run / UI-smoke-tested. → next: `make app`, confirm a bottle launches on Proton with the selector gone.
- **[Next session] Finer-grain `WINEMSYNC_NO_ANON_AUTOEVENT` masking — enable more msync.** Today `Wine.swift` wires `WINEMSYNC_NO_ANON_AUTOEVENT=1`, and `event_uses_msync()` (`dlls/ntdll/unix/msync.c:1112`) routes **all** anonymous auto-reset events → wineserver sync. That's coarse (Steam makes many harmless anon auto-events; only a small cluster is pathological), so lots of events needlessly lose fast-sync. Goal: mask only the offending object(s), keep the rest on msync.
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

## Proton backend (shipped default; debugging history: docs/proton-migration.md)
- **Valve `proton-wine` 11.0** (x86_64/Rosetta) is the default and only user-facing backend. It inherits all Whisky macOS capabilities — msync, DXMT (D3D11/10/DXGI), KosmicKrisp Vulkan, DXVK (D3D9), Steam webhelper IFEO, coreaudio virtual-device hiding, `WINE_NX_COMPAT`. Steam logs in fully under msync; reports `wine-11.0`
- **App wiring**: `BottleSettings.WineBackend` defaults to `.proton` (decode fallback too); the ConfigView selector is removed. `.whiskyWine` (legacy Wine 11.13) stays in the enum for fallback but is not user-selectable. `Wine.binFolder(for:)`/`wineBinary(for:)` resolve per bottle; `WhiskyWineInstaller.protonBinFolder` prefers a side-by-side `Libraries/WineProton`, else falls back to `Libraries/Wine` (so it works whether Proton is installed side-by-side or laid directly over `Libraries/Wine`)
- **Install layout**: on this machine Proton is laid over `Libraries/Wine` (Whisky Wine backed up at `Libraries/Wine.whisky-bak`), DXMT built on top. `scripts/install-proton.sh` also supports `INSTALL_TO_WHISKY=1` → side-by-side `Libraries/WineProton`
- Source `vendor/proton-wine/` **gitignored** (tag `proton-wine-11.0-…`). Tracked in main: `patches/proton-wine/` (14-patch series — `0001`–`0006`, `0008`–`0015`, gap at `0007`; disjoint file ownership, base `81d78e4`) + `scripts/install-proton.sh`; `scripts/build-dxmt.sh` + `scripts/build-wine-x86.sh` have env-var / source-reset hooks. What each patch does and the migration debugging log live in **docs/proton-migration.md** — keep bug detail there, not here
- DXMT vs Proton: `scripts/build-dxmt.sh` reads `DXMT_WINE_BUILD` / `DXMT_WINE_LIB` — `DXMT_WINE_BUILD=vendor/proton-wine/build DXMT_WINE_LIB=<ProtonInstall>/Wine/lib/wine`
- Mono: Proton hardcodes `wine-mono-10.4.1` — **don't build from source**; `wineboot` installs the `.msi` at runtime (fetched to `~/.cache/wine/` via proxy; `dl.winehq.org` GFW-blocked direct)
- **Steam-on-Proton gotchas**: (1) turn **Follow System Proxy OFF** — the geph HTTP proxy breaks Steam's CM (WSS→403); CMs are directly reachable. (2) msync-only: `BottleSettings.swift` sets `WINEESYNC=0` for the Proton backend (macOS has no eventfd; esync misbehaves) while keeping `WINEESYNC=1` for legacy Whisky-Wine (DXMT `lid3dshared.dylib` esync-detection lie). (3) `PROTON_DISABLE_LSTEAMCLIENT=1` (wired into `Wine.swift`) fixes the Proton lsteamclient tier0 crash ("reinstall Steam" box). (4) NOT a network/VPN/winsock issue (host reaches Steam HTTP direct; only raw CM ports GFW-blocked). CLI launch needs `whisky steam-fix <bottle>` first

## Unity fullscreen "empty top bar" (空栏) — Steam D3D11 games
- Some Unity fullscreen games show a ~32px macOS title bar offset. Workaround: Steam Launch Options `-popupwindow -screen-fullscreen 0` (borderless `WS_POPUP`; stored in `userdata/<id>/config/localconfig.vdf`, edit with Steam closed). Patches `0003`/`0004` make the borderless window land edge-to-edge

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

## Steam notes (details: docs/steam-webhelper-ifeo.md)
- Black CEF window fixed by the IFEO-attached wrapper (needs `patches/wine/0001`); on-disk `steamwebhelper.exe` stays byte-identical to Valve's so `BVerifyInstalledFiles` passes. `Steam.swift` (`Wine.configureSteam`) re-asserts wrapper + registry on every launch; CLI: `whisky steam-fix <bottle>`. 64-bit CEF dirs only
- Update stuck behind proxy/GFW: enable the bottle's **Follow System Proxy** toggle (`SystemProxy.swift` resolves PAC → injects `http_proxy` etc.). Irrelevant for VPN/TUN
- CEF GPU: the shipped wrapper appends only `--no-sandbox --in-process-gpu`; CEF renders correctly on wined3d (GLES 2.0). An ANGLE-Vulkan ES3 route is shelved (flickers). GPU-backend analysis and the ES3 experiment live in docs/steam-webhelper-ifeo.md §1
- Always launch Steam with the **full bottle env** (`WhiskyCmd shellenv <bottle>` dumps it) — a minimal env missing `WINEDLLOVERRIDES=…winemetal=b` + `DYLD_FALLBACK_LIBRARY_PATH` makes `steam.exe` spin with no login window. Kill cleanly with `pkill -9 -f steamwebhelper` (+ `cef.win64`), not just `steam.exe`
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
