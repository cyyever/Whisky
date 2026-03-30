# Whisky - Wine wrapper for macOS

## Project overview
Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived). A SwiftUI macOS app that wraps Wine for running Windows games via Steam on Apple Silicon.

## Architecture
- **Whisky app** — SwiftUI macOS app (Xcode project)
- **WhiskyKit** — Local Swift package with Wine management, bottle settings, process execution
- **Wine** — x86_64 Wine 11.5 built from source via Rosetta 2 (submodule at `vendor/wine`)
- **DXMT** — Open-source Metal-based D3D11/D3D10 translation for Wine (submodule at `vendor/dxmt`)
- **DXVK** — Optional DirectX→Vulkan→Metal path

## Build instructions
```bash
make setup-x86-brew  # one-time: x86_64 Homebrew + deps in vendor/
make wine            # build Wine 11.5 x86_64 from vendor/wine submodule
make dxmt            # install DXMT (Metal D3D11) into Wine
make app             # build Whisky Swift app
make all             # build everything
make run             # build app and launch
```

## Key paths
- Wine submodule: `vendor/wine` (pinned to wine-11.5 tag)
- DXMT submodule: `vendor/dxmt` (pinned to v0.74 tag)
- x86 Homebrew: `vendor/homebrew-x86/` (gitignored)
- Build scripts: `scripts/setup-x86-brew.sh`, `scripts/build-wine-x86.sh`, `scripts/install-dxmt.sh`
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`
- Bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`

## Wine build notes
- Native ARM64 Wine does NOT work on macOS (preloader_mac.c has no aarch64 support)
- Must build x86_64 Wine and run via Rosetta 2
- Use `--enable-archs=i386,x86_64` for WoW64 32-bit support (Steam is 32-bit)
- Bundle FreeType, MoltenVK dylibs into Wine/lib; set DYLD_FALLBACK_LIBRARY_PATH
- DXMT replaces Wine's built-in D3D11/D3D10/DXGI DLLs with Metal-based ones
- Don't mix Apple's proprietary D3DMetal bridge DLLs with upstream Wine — use DXMT instead

## Distribution URLs
- Version plist: `https://cyyever.github.io/Whisky/WhiskyWineVersion.plist`
- Libraries download: `https://github.com/cyyever/Whisky/releases/download/v{version}/Libraries.tar.gz`
- Appcast: `https://cyyever.github.io/Whisky/appcast.xml`

## Dependencies
- Sparkle 2.9.1 (app updates)
- SemanticVersion 0.5.1
- swift-argument-parser 1.7.1
- SwiftyTextTable 0.9.0
- Progress.swift 0.4.0

## Coding conventions
- Swift 6.3, macOS 26.0 deployment target
- SwiftLint enforced (strict mode, 25+ opt-in rules, custom file header required)
- GPL v3 license
- `vendor/` and build artifacts excluded from SwiftLint
