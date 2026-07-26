# Whisky 🥃

A SwiftUI macOS app for running Windows games via Steam on Apple Silicon. This
is a hard fork of the archived
[Whisky-App/Whisky](https://github.com/Whisky-App/Whisky), retargeted at Steam
gaming: it runs on **Valve proton-wine 11.0** (x86_64, under Rosetta 2), with
**DXMT** for Metal-native D3D11/D3D10/DXGI, **DXVK** for D3D9, and **KosmicKrisp**
(Mesa Vulkan-on-Metal) as the Vulkan backend. Architecture and engineering detail
live in [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs).

## System requirements

- Apple Silicon (M-series)
- macOS 26.0 or later

## Install

Download the latest build from this fork's
[Releases](https://github.com/cyyever/Whisky/releases), or build from source.

## Build

```bash
make setup-x86-brew  # one-time: x86_64 Homebrew + deps
make proton          # build proton-wine
make dxmt            # build DXMT (Metal D3D11), install as Wine builtin
make dxvk            # build DXVK d3d9.dll
make app             # build the Whisky app (or: make run)
```

See [`CLAUDE.md`](CLAUDE.md) for the full fresh-machine bootstrap (FFmpeg and
KosmicKrisp builds are required before `make proton`).

## My game isn't working

Some games need extra steps. See [`docs/`](docs) and [`CLAUDE.md`](CLAUDE.md) for
notes on Steam, D3D9/DXVK, Unity fullscreen, and controllers.

## Credits

- [proton-wine](https://github.com/ValveSoftware/wine) by Valve, and [WineHQ](https://www.winehq.org)
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [DXVK](https://github.com/doitsujin/dxvk) by doitsujin
- [KosmicKrisp / Mesa](https://gitlab.freedesktop.org/mesa/mesa) by LunarG and the Mesa project
- Built on the original Whisky by Isaac Marovitz and contributors.

## License

GPLv3 — see [`LICENSE`](LICENSE).
