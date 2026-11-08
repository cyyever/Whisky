# Whisky — Wine wrapper for macOS

Fork of [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived): a SwiftUI macOS app wrapping Wine to run Windows games via Steam on Apple Silicon. Proton-locked, Steam-gaming-focused.

Keep this file high-level. Details live in `docs/`, the build scripts, `patches/`, and the code — link to them, don't restate them here.

## Architecture
- **Whisky** — SwiftUI app (Xcode project). **WhiskyKit** — Swift package (Wine/bottle/process logic); `PlatformMacOS/` holds the macOS-specific files.
- **Wine** — x86_64 Proton-wine 11.0, built from source, runs under Rosetta 2. Source `vendor/proton-wine` (gitignored) + `patches/proton-wine/`.
- **Mullion** — default D3D10/11/12 + DXGI provider, translated directly to Metal (`vendor/mullion`). **DXVK** — D3D9/8 over winevulkan (`vendor/dxvk`). **KosmicKrisp** — Vulkan-on-Metal (`vendor/mesa`). Transform feedback (stream output) is a backport of an unmerged MR (`patches/mesa/0004`).
- Steam CEF (`steamwebhelper.exe`) gets `--no-sandbox` appended in Proton itself (`hack_append_command_line`, patches/proton-wine 0020) — no launcher shim.

## Build
```bash
make x86-deps         # one-time: cross-build Wine's x86_64 libraries (freetype, gnutls, SDL2, Vulkan loader)
make llvm-x86         # build LLVM 23 x86_64 static libraries for Mullion
make gstreamer        # x86_64 GStreamer for winegstreamer (WMV); make proton needs it
make proton          # Proton plus Mullion D3D10/11/12 + DXGI builtins
make dxvk            # DXVK d3d9/d3d8 builtins
make app / make run   # build / run the app
```
Fresh-machine order: ARM brew deps (`autoconf automake bison cmake meson ninja nasm glslang pkg-config mingw-w64 ccache llvm libclc spirv-llvm-translator spirv-tools`, plus `mako pyyaml` for brew's python3) → Rosetta 2 → `git submodule update --init --recursive vendor/mullion` → `make llvm-x86` → `vendor/proton-wine` at the base hash in `scripts/build-proton-x86.sh` → `make x86-deps` → `scripts/build-ffmpeg-x86.sh` + `scripts/build-kosmickrisp-x86.sh` → `make proton` (builds GStreamer first — Wine is configured `--with-gstreamer` and configure hard-errors without it) → `make dxvk`. Set `WHISKY_MULLION_LLVM` for a different LLVM prefix.

## Key paths
- Wine install: `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/`
- Bottles: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/`
- x86_64 libraries: `vendor/x86-deps/` (gitignored), cross-built by the arm64 clang with `-arch x86_64` — there is no x86_64 Homebrew. Build scripts: `scripts/`.

## Detailed docs
- Proton migration + per-patch notes → `docs/proton-migration.md`
- Steam webhelper / CEF flags → `docs/steam-webhelper.md`
- Steam networking / proxy / TUN → `docs/steam-networking.md`
- C++ cross-platform plan → `docs/cxx-migration-plan.md`

## Operational gotchas
- **Steam login**: works end to end as of 2026-08-07, with no proxy and no TUN. Turn Follow System Proxy OFF (an HTTP proxy breaks Steam's CM); SOCKS is tunneled via proxychains automatically. Only on a genuinely filtering network is a system TUN worth reaching for — see `docs/steam-networking.md`. Launch Steam and games from the **Whisky GUI / Steam Play button**, never a bare CLI: a CLI launch logs `no bootstrapper found` and invalidates any conclusion about the login window.
- Native ARM64 Wine doesn't work on macOS — x86_64 + Rosetta only; WoW64 (`i386,x86_64`) because Steam is 32-bit.
- Xbox Bluetooth controllers need `SDL_JOYSTICK_MFI=0`.
- Rebuild Wine → restart Whisky/Steam (wineserver version mismatch).

## Conventions
- Swift 6.4 toolchain (validated with Swift 6.4.2 / Xcode 27.2), Swift 6 language mode, macOS 26 target, SwiftLint strict, GPL v3. `vendor/` excluded from lint.
- Deps: SemanticVersion, swift-argument-parser, SwiftyTextTable.

## Distribution
- No Libraries tarball or appcast: Wine is built from this checkout by `make proton`, never downloaded.
- `make proton` and `make install-app` both stamp a digest of `patches/proton-wine/*.patch`
  (into `WhiskyWineVersion.plist` and `Info.plist`). A mismatch means the installed Wine
  predates what the app expects — it is reported in the launch log; fix with `make proton`.
