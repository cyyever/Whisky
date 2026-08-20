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
