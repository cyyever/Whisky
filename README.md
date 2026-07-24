<div align="center">

  # Whisky 🥃
  *Wine but a bit stronger*

  ![](https://img.shields.io/github/actions/workflow/status/cyyever/Whisky/SwiftLint.yml?style=for-the-badge)
</div>

## About this fork

This is an actively-maintained fork of the archived
[Whisky-App/Whisky](https://github.com/Whisky-App/Whisky), retargeted at running
Windows games via Steam on Apple Silicon. The Wine backend and graphics stack
have been substantially reworked — see [`CLAUDE.md`](CLAUDE.md) and [`docs/`](docs)
for the architecture and build details.

<img width="650" alt="Config" src="https://github.com/Whisky-App/Whisky/assets/42140194/d0a405e8-76ee-48f0-92b5-165d184a576b">

Familiar UI that integrates seamlessly with macOS

<div align="right">
  <img width="650" alt="New Bottle" src="https://github.com/Whisky-App/Whisky/assets/42140194/ed1a0d69-d8fb-442b-9330-6816ba8981ba">

  One-click bottle creation and management
</div>

<img width="650" alt="debug" src="https://user-images.githubusercontent.com/42140194/229176642-57b80801-d29b-4123-b1c2-f3b31408ffc6.png">

Debug and profile with ease

---

Whisky provides a clean and easy to use graphical wrapper for Wine built in
native SwiftUI. You can make and manage bottles, install and run Windows apps and
games, and unlock the full potential of your Mac with no technical knowledge
required.

This fork runs on **Valve proton-wine 11.0** (x86_64, under Rosetta 2), with
**DXMT** for Metal-native D3D11/D3D10/DXGI, **DXVK** for D3D9, and **KosmicKrisp**
(Mesa Vulkan-on-Metal-4) as the Vulkan backend.

---

## System Requirements
- CPU: Apple Silicon (M-series chips)
- OS: macOS 26.0 or later

## Install

Download the latest build from this fork's
[Releases](https://github.com/cyyever/Whisky/releases), or build from source —
see the build instructions in [`CLAUDE.md`](CLAUDE.md).

## My game isn't working!

Some games need special steps. See the notes in [`docs/`](docs) (Steam,
D3D9/DXVK, Unity fullscreen, controllers, and the macOS gaming stack).

---

## Credits & Acknowledgments

Whisky is possible thanks to the magic of several projects:

- [proton-wine](https://github.com/ValveSoftware/wine) by Valve, and [WineHQ](https://www.winehq.org)
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [DXVK](https://github.com/doitsujin/dxvk) by doitsujin
- [KosmicKrisp / Mesa](https://gitlab.freedesktop.org/mesa/mesa) by LunarG and the Mesa project
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [SwiftyTextTable](https://github.com/scottrhoyt/SwiftyTextTable) by scottrhoyt

Built on the original Whisky by Isaac Marovitz and contributors.
