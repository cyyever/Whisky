# Whisky - Wine wrapper for macOS

## Project overview
Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived). A SwiftUI macOS app that wraps Wine for running Windows games via Steam on Apple Silicon.

## Architecture
- **Whisky app** — SwiftUI macOS app (Xcode project)
- **WhiskyKit** — Local Swift package with Wine management, bottle settings, process execution
- **Wine** — x86_64 Wine 11.9 built from source via Rosetta 2 (submodule at `vendor/wine`); D3D11/D3D10/DXGI use Wine's built-in wined3d
- **DXVK** — Optional DirectX→Vulkan→Metal path
- **SteamHelper** — `webhelper_wrapper.c`, a PE shim that fixes Steam's black-window bug (see Steam notes)

## Build instructions
```bash
make setup-x86-brew  # one-time: x86_64 Homebrew + deps in vendor/
make wine            # build Wine 11.9 x86_64 from vendor/wine submodule
make steam-helper    # cross-compile the Steam webhelper wrapper (mingw)
make app             # build Whisky Swift app
make all             # build everything (app + Wine + steam-helper)
make run             # build app and launch
```

## Key paths
- Wine submodule: `vendor/wine` (pinned to wine-11.9 + rundll32 WS_VISIBLE fix)
- x86 Homebrew: `vendor/homebrew-x86/` (gitignored)
- Build scripts: `scripts/setup-x86-brew.sh`, `scripts/build-wine-x86.sh`, `scripts/build-webhelper-wrapper.sh`
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`
- Steam wrapper: `SteamHelper/webhelper_wrapper.c` → installed to `…/Libraries/SteamHelper/steamwebhelper_wrapper.exe`
- Bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`

## Wine build notes
- Native ARM64 Wine does NOT work on macOS (preloader_mac.c has no aarch64 support)
- Must build x86_64 Wine and run via Rosetta 2
- Use `--enable-archs=i386,x86_64` for WoW64 32-bit support (Steam is 32-bit)
- Bundle FreeType, MoltenVK dylibs into Wine/lib; add @loader_path/../.. rpath to wine/x86_64-unix/*.so so dlopen finds them
- D3D11/D3D10/DXGI use Wine's built-in wined3d (DXMT was removed: its `cross-process swapchain not supported yet` limit broke Steam's CEF)

## Steam notes
- **Black-window fix**: Steam's CEF host (`steamwebhelper.exe`) renders a black window under Wine — its sandbox hooks the NT kernel and its out-of-process GPU can't reset the D3D device (`problems[10]: Some drivers are unable to reset the D3D device in the GPU process sandbox`). Neither wined3d nor DXVK fixes this; Steam's own `--disable-gpu` fallback is insufficient.
- **Solution**: `SteamHelper/webhelper_wrapper.c` replaces `steamwebhelper.exe`, re-launching the genuine binary (renamed `steamwebhelper_real.exe`) with `--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing`. `--no-sandbox` + `--in-process-gpu` are the flags Steam's fallback misses.
- Built GUI-subsystem (`-mwindows`) so no console window appears; child spawned with `CREATE_NO_WINDOW`.
- `WhiskyKit/.../Whisky/Steam.swift` auto-installs/refreshes it into a bottle's 64-bit CEF dirs on every launch (hooked in `Wine.runProgram`); re-installs after Steam updates overwrite it. CLI: `whisky steam-fix <bottle>`.
- Installed into 64-bit CEF dirs only (`cef.win64` / `cef.win7x64`); a 32-bit Steam client (`-cef-force-32bit`) would need an i686 wrapper build.
- WoW64 caveat: a hand-driven `wineboot --init` may not populate `syswow64` (32-bit DLLs) — Steam's 32-bit `steam.exe` then fails with `c0000135`. The GUI/`WhiskyCmd` bottle-creation path handles this; if hitting it manually, copy `Wine/lib/wine/i386-windows/*.dll` into the bottle's `syswow64`.

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
