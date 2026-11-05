# Whisky 🥃

A SwiftUI macOS app for running Windows games via Steam on Apple Silicon. This
is a hard fork of the archived
[Whisky-App/Whisky](https://github.com/Whisky-App/Whisky), retargeted at Steam
gaming: it runs on **Valve proton-wine 11.0** (x86_64, under Rosetta 2), with
**DXVK** for D3D9 and D3D11/D3D10/DXGI, and **KosmicKrisp** (Mesa Vulkan-on-Metal)
as the Vulkan backend. Architecture and engineering detail
live in [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs).

## System requirements

- Apple Silicon (M-series)
- macOS 26.0 or later

## Install

Download the latest build from this fork's
[Releases](https://github.com/cyyever/Whisky/releases), or build from source.

## Build

Use a Swift 6.4 toolchain (validated with Swift 6.4.2 / Xcode 27.2).

```bash
make x86-deps        # one-time: cross-build Wine's x86_64 libraries
make proton          # build proton-wine
make dxvk            # build DXVK (D3D9 + D3D11), install as Wine builtins
make vkd3d           # optional D3D12 (vkd3d-proton; real games unverified)
make test-d3d12      # test the installed D3D12 provider
make app             # build the Whisky app (or: make run)
```

See [`CLAUDE.md`](CLAUDE.md) for the full fresh-machine bootstrap (FFmpeg and
KosmicKrisp builds are required before `make proton`).

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
