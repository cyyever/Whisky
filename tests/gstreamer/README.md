# DirectShow / winegstreamer probes

Wine plays WMV through quartz's filter graph, whose splitter and decoder are
both winegstreamer. When a game shows a black screen or hangs on a movie, the
question is *which half* broke — and these probes split it three ways so an
answer is one 25-second run rather than a game session.

| probe | question | how |
|---|---|---|
| `wmv-playback-test.c` | does the file **decode**? | `IWMSyncReader`, a pull API: `Open()` then `GetNextSample()`. No renderer, no window. |
| `wmv-render-test.c` | does it **render** in a window? | a full graph plus quartz's video renderer, for a human to watch |
| `wmv-stall-test.c` | does the clock **keep moving**? | headless graph, polls `IMediaSeeking` and reports the rate |

Green on the first and black in the game are perfectly consistent — they test
different halves.

## wmv-stall-test.sh — the graph clock

`tests/gstreamer/wmv-stall-test.sh [-enough seconds] [-show] [bottle ...]`

SSFIV once hung on a black screen with the media pipeline apparently stuck:
`asfdemux` and the libav audio decoder were running while winegstreamer sat
blocked at the app boundary. Telling that from *a three-minute movie playing
normally* needs the graph clock, not a wall-clock budget — so this reports the
ratio, and **only a clock that stops is a stall**.

The first version of this test got exactly that wrong and reported `TIMED OUT
at 60.1 s of 192.8 s` for a clip playing perfectly at 1.00x.

**Result (2026-08-19): 1.00x realtime.** The pipeline was healthy and the
black screen was elsewhere — it turned out to be Wine, and a bleeding-edge
bump fixed it.

## The audio probes

SSFIV's opening movie plays with sound and the main menu that follows is
silent. Those are two different paths — the movie is a DirectShow graph ending
in the DirectSound renderer, while the game imports `DSOUND.dll` and
enumerates devices itself — so "does Wine have audio" is the wrong question.
These two split it further.

Neither needs ears. `dsound-after-video-test` reads the **play cursor**:
`IDirectSoundBuffer::GetCurrentPosition` advances only while a buffer is
really being consumed, so a buffer that "plays" with a frozen cursor is
silence, and that is checkable without a person in the room.

| probe | question | result |
|---|---|---|
| `dsound-after-video-test.c` | does DirectSound still play once a DirectShow graph has had the device? | **negative (2026-08-20)**: 44216 bytes per 500 ms before *and* after the movie, against ~44100 expected — exactly real time both times |
| `audio-device-name-test.c` | can an app read the devices' names? | tracing the game showed `send_device GetValue(FriendlyName) failed: 80004005` on every run |

The first probe's negative retires the whole "the video left the device
occupied" theory. The second is unfinished: it hangs before printing its first
line — which is before any audio call, so the hang is in DLL load or
`CoInitialize` — while `wine cmd /c echo` runs normally in the same bottle at
the same moment. That hang is the more interesting finding and is where this
picks up.

## dshow-render-test.sh — 32-bit vs 64-bit rendering

Runs `wmv-render-test` in both bitnesses over any WMV in the bottle. The
finding it exists for: the identical file completed in a 64-bit process and
hung in a 32-bit one. A single-bitness test would have called that green, and
Steam and SSFIV are both 32-bit.

## Conventions

Runners take the bottle from `tests/lib/bottles.sh` (`select_bottles`) and the
environment from `scripts/lib/common.sh` (`bottle_shellenv`) — never a
hand-built `env`. `bottle_shellenv` emits `WINEMSYNC` from the bottle's
`enhancedSync`, and getting that wrong kills wine inside `msync_init` before
`main()`, which looks exactly like the hang these probes hunt.

Subjects are found by searching the bottle, not by hardcoding a game path: a
probe that skips because one title is not installed reports green for a broken
pipeline.
