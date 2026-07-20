# Xbox controller probes (macOS → SDL → Wine → XInput)

Layer-by-layer probes used to bring up Xbox controller support (2026-07-20,
Xbox One S pad model 1708 over Bluetooth, macOS 27.0 beta 26A5378n).

## The finding

Every layer worked except one: **SDL's GCController (MFI) backend enumerates
the pad but delivers zero input** on macOS 27.0 beta — same shape as the
macOS 26.0 GameController regression that Apple fixed in 26.1. Forcing SDL
off the GameController framework fixes input end-to-end:

```
SDL_JOYSTICK_MFI=0
```

Whisky sets this in both `constructWineEnvironment` and
`constructWineServerEnvironment` (winedevice.exe, which hosts winebus.sys,
inherits its unix env from wineserver). With it, SDL's HIDAPI driver reads
the Bluetooth HID reports directly (name shows as "Xbox One S Controller",
vs the IOKit path's "Xbox Wireless Controller") and rumble output reports
stay available. Revisit when a GA macOS fixes the framework.

## Probes

| file | layer | build & run |
|---|---|---|
| `sdl_probe.c` | SDL enumeration under winebus conditions (`plain`/`runloop`/`thread` modes — SDL#11742 said GCController needs a pumped CFRunLoop; enumeration turned out fine in all three) | `clang -arch x86_64 sdl_probe.c -I$X86/include/SDL2 -D_THREAD_SAFE -L$X86/lib -lSDL2 -framework CoreFoundation -Wl,-rpath,$X86/lib` with `X86=vendor/homebrew-x86/opt/sdl2` |
| `sdl_input.c` | SDL *input delivery* (the layer that actually broke). Args: `bg` sets ALLOW_BACKGROUND_EVENTS. Compare `./sdl_input bg` (0 changes) vs `SDL_JOYSTICK_MFI=0 ./sdl_input bg` (input flows) | same as above, no CoreFoundation |
| `xinput_probe.c` | one-shot XInput + winmm inside Wine (connect status, duplicate-device check — SDL and IOHID backends double-reporting would show 2 winmm joysticks) | `x86_64-w64-mingw32-gcc xinput_probe.c -lwinmm` |
| `xinput_poll.c` | 8-second XInput poll inside Wine — proves reports flow (A button = `buttons=1000`) | `x86_64-w64-mingw32-gcc xinput_poll.c` |

Run the Wine ones with `WINEPREFIX=<bottle> wine xinput_poll.exe`; restart
`wineserver -k` after changing env vars, winebus only reads them at startup.

## Hardware notes

- **Bluetooth (works, zero code needed beyond the env var)**: model 1708+
  pads pair directly (hold the top pair button; System Settings → Bluetooth).
  Shows as HID UsagePage 1 / Usage 5, VID 045E PID 02FD.
- **Wired USB**: macOS 15 Sequoia+ has a native GIP driver for official pads.
  Untested here — the only cable at hand was charge-only (pad stays dark =
  no VBUS data lines; a dead giveaway).
- **Xbox Wireless Adapter dongle ("XBOX ACC", 045E:02FE, model 1790)**:
  enumerates on USB but macOS has no driver — only
  `AppleUSBHostCompositeDevice` attaches, so pairing can never complete.
  Linux drives it with open-source xow (userspace libusb) / xone (kernel).
  A macOS port would be xow's mt76 firmware upload + GIP logic in an arm64
  helper feeding a thin winebus socket backend. Real project, parked.
