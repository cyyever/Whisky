# Whisky 🥃

A SwiftUI macOS app for running Windows games via Steam on Apple Silicon. This
is a hard fork of the archived
[Whisky-App/Whisky](https://github.com/Whisky-App/Whisky), retargeted at Steam
gaming: it runs on **Valve proton-wine 11.0** (x86_64, under Rosetta 2), with
**Mullion** translating D3D10/11/12 directly to Metal and **DXVK** for D3D8/9
through **KosmicKrisp** (Mesa Vulkan-on-Metal). Architecture and engineering detail
live in [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs).

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
make submodule       # fetch the pinned sources, including your Mullion fork
make x86-deps        # one-time: cross-build Wine's x86_64 libraries
make proton          # build Proton, DXVK D3D8/9 fallback, and default Mullion D3D10/11/12 Metal backend
make dxvk            # select DXVK for D3D8/9/10/11 instead of Mullion
make vkd3d           # optional vkd3d-proton D3D12 fallback
make mullion         # select/rebuild Mullion as the default D3D10/11/12 backend
make test-d3d12      # test the vkd3d-proton fallback
make app             # build the Whisky app (or: make run)
```

See [`CLAUDE.md`](CLAUDE.md) for the full fresh-machine bootstrap (FFmpeg and
KosmicKrisp builds are required before `make proton`). Mullion also needs x86_64
LLVM 15 static libraries from an x86_64 toolchain; the default lookup is
`/usr/local/opt/llvm@15`. Set `WHISKY_MULLION_LLVM` to use another compatible
installation.

## My game isn't working

Some games need extra steps. See [`docs/`](docs) and [`CLAUDE.md`](CLAUDE.md) for
notes on Steam, D3D9/DXVK, Unity fullscreen, and controllers.

## Credits

- [proton-wine](https://github.com/ValveSoftware/wine) by Valve, and [WineHQ](https://www.winehq.org)
- [DXVK](https://github.com/doitsujin/dxvk) by doitsujin
- [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) for optional D3D12
- [KosmicKrisp / Mesa](https://gitlab.freedesktop.org/mesa/mesa) by LunarG and the Mesa project
- Built on the original Whisky by Isaac Marovitz and contributors.

## License

GPLv3 — see [`LICENSE`](LICENSE).
