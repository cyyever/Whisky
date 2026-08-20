# Audio stack probes

Wine's audio reaches macOS through `winecoreaudio.drv` under `mmdevapi`, with
`dsound` layered on top — which is what games import. These probe that stack
directly; the DirectShow side (movies, `quartz`) is in `tests/gstreamer/`.

## audio-device-name-test.c — enumeration and defaults

Answers two questions an engine's audio init depends on: are the devices
*named*, and which one does "the default" resolve to. Tracing SSFIV turned up
`send_device GetValue(FriendlyName) failed: 80004005` on every run, and macOS
distinguishes **Default Output Device** (where apps play) from **Default System
Output Device** (where alerts play) — they differ on this machine, so a driver
mapping the wrong one would send every game's audio somewhere nobody is
listening.

**Result (2026-08-20): both fine.** All six DirectSound devices are named, and
all three roles resolve to `Speakers (MacBook Air Speakers)`. The one name that
is unreadable belongs to a Chinese-named Multi-Output Device that is not the
default. So the warnings in the game's trace are cosmetic.

Names print one character at a time with non-ASCII as `?`. `%ls` emitted
nothing for that device *and swallowed the rest of the line* — an early version
hid the one device worth looking at.

## audio-name-growth-test.sh — the registry entry that never stops growing

This bottle held an unplugged monitor's HDMI endpoint stored as
`"Speakers (Speakers (Speakers ( … ×97 … (DELL S2817Q) … )))"`.
`MMDevice_Create` builds a device's friendly name from the driver id it is
handed, and the only id available for a device that is no longer present is a
name it built earlier — so every enumeration added a layer.

**No device switching required, and that is the finding.** The growth is per
*enumeration*, not per plug event, so anything that opens the audio stack
advances it — which is how a machine nobody was stressing reached 97 layers.

**Result: +22 bytes per enumeration before `patches/proton-wine/0037`, +0
after** (2026-08-20).

Three things it refuses to do, each of which would have made it pass while
measuring nothing: it SKIPs unless the bottle actually has a
`DEVICE_STATE_NOTPRESENT` device (the only kind that can exhibit the bug), it
SKIPs if the baseline byte count is zero (the registry format it greps for
changed), and it FAILs if the enumeration probe does not complete — "never
enumerated" and "did not grow" are the same number otherwise.

It checks the registry rather than the API because the corruption is what gets
*persisted*, and it kills wineserver between rounds because that is when the
registry is written. **That makes it unsafe to run against a bottle with a game
in it** — pass the bottle explicitly if you have more than one.

## Upstream

The bug is in WineHQ master, not something this fork introduced: `devenum.c`
there still seeds `load_devices_from_reg` from `DEVPKEY_Device_FriendlyName`
and still derives the name with `swprintf(… L"%ls (%ls)" …)`, and no `DriverId`
exists anywhere in the file. `patches/proton-wine/0037` applies to upstream
master unmodified (two hunks, −170 line offset), so it is submittable to
wine-devel as is — not to Valve's fork, which takes no external PRs.
