# Whisky — Wine wrapper for macOS

Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived): a SwiftUI macOS app wrapping Wine to run Windows games via Steam on Apple Silicon. Proton-locked, Steam-gaming-focused.

Keep this file high-level. Details live in `docs/`, the build scripts, `patches/`, and the code — link to them, don't restate them here.

## Architecture
- **Whisky** — SwiftUI app (Xcode project). **WhiskyKit** — Swift package (Wine/bottle/process logic); `PlatformMacOS/` holds the macOS-specific files, `PlatformServices.swift` the cross-platform seam.
- **Wine** — x86_64 Proton-wine 11.0, built from source, runs under Rosetta 2. Source `vendor/proton-wine` (gitignored) + `patches/proton-wine/`.
- **DXMT** — Metal D3D11/10/DXGI (`vendor/dxmt`). **DXVK** — D3D9 only (`vendor/dxvk`). **KosmicKrisp** — Vulkan-on-Metal (`vendor/mesa`).
- **SteamHelper** — webhelper wrapper attached via IFEO to fix Steam's black CEF window.

## Build
```bash
make setup-x86-brew   # one-time: x86_64 Homebrew + deps
make proton           # build + install Proton (applies patches/proton-wine/*)
make dxmt             # DXMT builtin (needs full Xcode + llvm@15)
make dxvk             # DXVK d3d9.dll
make steam-helper     # webhelper wrapper
make app / make run   # build / run the app
```
Fresh-machine order: ARM brew deps → `make setup-x86-brew` → `scripts/build-ffmpeg-x86.sh` + `scripts/build-kosmickrisp-x86.sh` → `make proton` → `make dxmt` / `make dxvk`. The scripts own the decisions.

## Key paths
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`
- Bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`
- x86 brew: `vendor/homebrew-x86/` (gitignored). Build scripts: `scripts/`.

## Detailed docs
- Proton migration + per-patch notes → `docs/proton-migration.md`
- Steam webhelper / IFEO / CEF GPU → `docs/steam-webhelper-ifeo.md`
- C++ cross-platform plan → `docs/cxx-migration-plan.md`

## Operational gotchas
- **Steam login**: turn Follow System Proxy OFF (the geph HTTP proxy breaks Steam's CM); SOCKS is tunneled via proxychains automatically. Launch games from the **Steam Play button**, not a bare CLI.
- Native ARM64 Wine doesn't work on macOS — x86_64 + Rosetta only; WoW64 (`i386,x86_64`) because Steam is 32-bit.
- Xbox Bluetooth controllers need `SDL_JOYSTICK_MFI=0`.
- Rebuild Wine → restart Whisky/Steam (wineserver version mismatch).

## Conventions
- Swift 6.3, macOS 26 target, SwiftLint strict, GPL v3. `vendor/` excluded from lint.
- Deps: SemanticVersion, swift-argument-parser, SwiftyTextTable.

## Distribution
- Version plist, Libraries tarball, and appcast under `https://cyyever.github.io/Whisky/` and the repo's GitHub releases.
