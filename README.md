# Whisky 🥃

A SwiftUI macOS app for running Windows games via Steam on Apple Silicon. This
is a hard fork of the archived
[Whisky-App/Whisky](https://github.com/Whisky-App/Whisky), retargeted at Steam
gaming: it runs on **Valve proton-wine 11.0** (x86_64, under Rosetta 2), with
**Mullion** translating D3D10/11/12 and DXGI directly to Metal, **DXVK** for D3D8/9,
and **KosmicKrisp** (Mesa Vulkan-on-Metal) for Vulkan applications. Architecture and
engineering detail live in [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs).

## System requirements

- Apple Silicon (M-series)
- macOS 26.0 or later

New bottles use Windows 11 mode. Older bottles are migrated to Windows 11 before
their next program launch; the GUI does not offer a Windows version selector.

## Install

Download the latest build from this fork's
[Releases](https://github.com/cyyever/Whisky/releases), or build from source.

## Build

Use a Swift 6.4 toolchain (validated with Swift 6.4.2 / Xcode 27.2).

```bash
make x86-deps        # one-time: cross-build Wine's x86_64 libraries
make llvm-x86        # build LLVM 23 static libraries for Mullion
make proton          # build proton-wine and Mullion (D3D10/11/12 + DXGI)
make dxvk            # build DXVK (D3D8 + D3D9), install as Wine builtins
make app             # build the Whisky app (or: make run)
```

`make llvm-x86` builds LLVM 23 static libraries for x86_64. Set
`WHISKY_MULLION_LLVM` to use another LLVM prefix. See [`CLAUDE.md`](CLAUDE.md)
for the full fresh-machine bootstrap (FFmpeg and KosmicKrisp are also required).

## My game isn't working

Some games need extra steps. See [`docs/`](docs) and [`CLAUDE.md`](CLAUDE.md) for
notes on Steam, D3D9/DXVK, Unity fullscreen, and controllers.

## Credits

- [proton-wine](https://github.com/ValveSoftware/wine) by Valve, and [WineHQ](https://www.winehq.org)
- [DXVK](https://github.com/doitsujin/dxvk) by doitsujin
- [Mullion](https://github.com/cyyever/mullion) for D3D10/11/12 and DXGI on Metal
- [KosmicKrisp / Mesa](https://gitlab.freedesktop.org/mesa/mesa) by LunarG and the Mesa project
- Built on the original Whisky by Isaac Marovitz and contributors.

## License

GPLv3 — see [`LICENSE`](LICENSE).
