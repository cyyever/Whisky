# Proton migration — Valve Proton_11.0 on Apple Silicon (Rosetta 2)

Goal: replace Whisky's x86_64 Wine 11.13 with **Valve's `proton-wine` 11.0** so Proton
inherits all of Whisky's macOS capabilities — msync fast-sync, DXMT (D3D11/10/DXGI),
KosmicKrisp Vulkan, DXVK (D3D9), the Steam webhelper IFEO wrapper, CoreAudio
virtual-device hiding, `WINE_NX_COMPAT` — while keeping D3D9/10/11 all working. Motivation:
Proton ships Valve's game fixes, media-converter, `amd_ags`, fsync, and a maintained
tree that plain WineHQ 11.13 lacks.

## Status (in progress — NOT committed, NOT shipped)
- Proton is **live-swapped** into the Whisky install dir:
  `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine`, previous
  Whisky Wine backed up alongside at `…/Libraries/Wine.whisky-bak`.
- Built x86_64, runs under Rosetta 2; DXMT installed on top of the Proton build.
- Reports `wine-11.0`; boots and runs (`cmd` works) after the msync crash fix below.
- Source tree `vendor/proton-wine/` is **gitignored** (like `vendor/wine`); tag reads
  `proton-wine-11.0-1-2-gff30ac6`.
- Untracked / new: `patches/proton-wine/` (17-patch series) and
  `scripts/install-proton.sh`. `scripts/build-dxmt.sh` gained env-var parameterization.
- **Steam** boots through bootstrap + client startup + CEF webhelper but the client
  still self-exits ~35 s in before reaching a CM (see "Steam on Proton" below). Three
  runtime bugs found and fixed on the way there (patches `0014`–`0016`).
- Not yet done: no Whisky-app wiring, no version-plist/appcast switch, no committed
  submodule pin. Treat as an experimental parallel track next to the canonical
  Wine 11.13 stack.

## The msync startup crash (root cause)
Proton's `wineserver` crashed immediately at bottle init (0 files landed in
`system32`). Diagnosed with **live lldb** — dead Rosetta core dumps only carry ARM64
*host* registers and never expose guest x86_64 frames, so post-mortem cores were
useless; attaching live to the running guest was the only way to see the faulting
frame.

- Fault: `server/event.c` `req_event_op` tripped
  `assert(event->sync->ops == &event_sync_ops)` with a garbage `event->sync`.
- Cause: with `do_msync()` active, `get_event_obj` returns an `msync`-backed object
  cast as `struct event`. `req_event_op` then reads `event->sync`, but that field sits
  at a different offset in `struct msync` → garbage pointer. Only reached when the
  **client** actually sends an `event_op` request.
- Deeper cause: the msync port in `dlls/ntdll/unix/sync.c` had dropped the
  `if (do_msync()) return msync_reset_event/pulse_event(...)` guards from
  `NtResetEvent`/`NtPulseEvent`, and `NtSetEvent` had all three code paths wrongly
  piled together, so the client fell through to the server `event_op` path against an
  msync object.
- Fix (in patch `0008`): each `Nt*Event` guards its server fallback with
  `if (do_msync()) return msync_*`; also added the missing msync branch to
  `NtWaitForSingleObject` (only `NtWaitForMultipleObjects` had it).

## patches/proton-wine/ — 17-patch series
Disjoint file ownership (except the msync-refinement patches `0014`/`0017` which layer
onto `0008`'s `msync.c`/`sync.c`, applied in order); all pass `git apply --check`.
Exported as `git format-patch` style `.patch` files. Groups (`0001`–`0007` build,
`0008`–`0013` capability ports, `0014`–`0016` Steam-runtime sync/deadlock fixes, `0017`
msync uniform-shadow rework):

### 0001–0007 — build / portability (make Proton compile + boot on macOS)
- `0001-macos-de-linux-ntdll` — guard Linux-only futex/CPU paths in
  `signal_x86_64.c`/`system.c`/`fsync.c`; `set_thread_teb` a no-op on Apple (the
  dispatcher owns `%gs`/pthread TSD; raw TEB write → SIGBUS). Trimmed so `sync.c`/
  `loader.c` de-linux hunks live in `0008`.
- `0002-winedmo-ffmpeg8-pcm-bsf` — drop reliance on FFmpeg-internal BSF plumbing for
  PCM byte-order reversal (winedmo builds against our x86_64 FFmpeg 8).
- `0003-win32u-opengl-compile-without-libegl` — compile framebuffer-surface / fs_hack
  path without libEGL.
- `0004-media-converter-pthread-include-macos` — `#include <pthread.h>` for
  `pthread_mutex_t` in winegstreamer media-converter.
- `0005-amd_ags_x64-guard-libdrm-non-linux` — guard libdrm/amdgpu use behind `__linux__`.
- `0006-loader64-wine64-macos` — build a 64-bit `wine64` loader on macOS
  (`loader64/Makefile.in`).
- `0007-rundll32-remove-ws-visible-wineboot-hang` — drop `WS_VISIBLE` to fix a wineboot
  hang (same fix as Whisky Wine `patches/wine/0001`).

### 0008–0013 — macOS capability ports
- `0008-macos-msync-fast-sync` — the big one (~52 files): the CrossOver macOS fast-sync
  (msync) port across `dlls/ntdll/unix/*` and `server/*`, plus the event-crash fix above.
- `0009-macos-dxmt-winemac-support` — winemac.drv Metal-swapchain client view;
  `macdrv_functions` export + `winemetal.so` Wine-ABI unix driver; RTLD_GLOBAL driver
  dlopen — the winemac side DXMT needs.
- `0010-macos-kernelbase-ifeo-debugger` — IFEO `Debugger` support in kernelbase (Steam
  webhelper wrapper) + a kernel32 conformance test.
- `0011-macos-nx-compat-env` — `WINE_NX_COMPAT` env var to force DEP on legacy images
  (fixes DXMT Tahoe slowness).
- `0012-macos-coreaudio-hide-virtual-devices` — hide virtual audio devices from games
  (`winecoreaudio.drv` + `mmdevapi`) — fixes device enum-loop hangs.
- `0013-macos-server-fsync-delinux` — de-linux the `server/fsync.c` stubs for the macOS
  build.

Mapping to the Whisky-Wine patch set: `0007`≈`patches/wine/0001`, `0009`≈`patches/wine/0002`+`0005`,
`0010`≈`patches/wine/0003`, `0011`≈`patches/wine/0004`, `0012`≈`patches/wine/0007`.
`0008`/`0013` (msync + fsync) and `0001`–`0006` are Proton-specific (WineHQ 11.13 already
had msync-free sync and none of Proton's extra unixlibs).

### 0014–0016 — Steam-runtime sync / deadlock fixes (all found live under Steam)
- `0014-macos-msync-mixed-wait-hybrid` — `dlls/ntdll/unix/msync.c`. msync (like esync)
  cannot natively wait on a set mixing fast msync objects (events/mutexes/semaphores)
  with pure-server objects (named pipes, async I/O, completion ports). Upstream just
  logs a FIXME and waits on the msync objects only → deadlock whenever a server object
  is the waker (RpcSs startup, wine-mono MSI, cold-boot service handshake, Steam's
  `reg add`). fsync escapes this via in-proc-sync fds the server can wait on; msync has
  no server-side shadow, so we cannot delegate the whole set. Fix: `msync_wait_mixed_any()`
  polls — grab any ready msync object in userspace, and between checks do a short bounded
  `server_wait()` on just the server subset (`objs[i]==NULL` marks a server object). Only
  mixed waits (RPC/service, never a game hot path) take this path. Hardened per review:
  propagate real `server_wait` errors instead of busy-looping on non-`STATUS_TIMEOUT`;
  back the poll interval off 2 ms → 16 ms when idle; NULL-guard `msync_apc_addr`; assert
  no 64-bit truncation in the `mach_msg2` → `mach_msg()` wrapper (the wrapper routes
  through libSystem's `mach_msg()` because the raw `mach_msg2_trap` is invoked through an
  untranslated pointer under Rosetta and crashes).
- `0015-combase-rpcss-cold-start-race` — `dlls/combase/rpc.c`. COM out-of-proc activation
  binds `ncalrpc:[irpcss]`; on a cold boot steam.exe races ahead and connects to the
  `\\.\pipe\lrpc\irpcss` endpoint ~tens-of-ms before rpcss creates it →
  `RPC_S_SERVER_UNAVAILABLE`, and `start_rpcss()`'s retry gave up because
  `OpenService("RpcSs")` also fails in the same cold window → uncaught → crash. Fix:
  make SCM/StartService best-effort and **`WaitNamedPipe`** on the irpcss endpoint pipe
  (bounded 30 s) before returning success. Root cause is startup ordering (`OpenService`
  failing during cold boot), not "Rosetta slowness" per se; the pipe path is derived from
  `IRPCSS_ENDPOINT` so it can't drift.
- `0016-ntdll-fls-callback-no-lock` — `dlls/ntdll/thread.c`. `RtlFlsFree` and
  `RtlProcessFlsData` invoked the per-index FLS destructor callback **while holding the
  global `fls_section`**. A Steam thread-exit callback that blocks on another thread which
  itself needs `fls_section` (FlsAlloc/Free, or its own exit cleanup) deadlocks — one
  thread sits 60 s in `RtlpWaitForCriticalSection("fls_section ... blocked by <tid>")` and
  the client never starts. Windows runs FLS callbacks with no internal lock held; upstream
  Wine keeps the lock and only survives the process-**exit** variant (its
  `fls_exit_deadlock` test) via the shutdown path — it does *not* prevent our
  startup/handoff inversion, which msync + Rosetta timing hits every launch. Fix: clear
  each data slot *before* the callback (so a rescan / concurrent teardown never
  double-calls), drop `fls_section` around the callback, re-acquire and `goto restart`.
  This is a genuine upstream Wine bug, not Proton- or msync-specific.

### 0017 — msync uniform inproc_sync shadows (architectural)
`server/{inproc_sync,object,msync}.{c,h}`, `dlls/ntdll/unix/{msync,sync}.c`. The deep
fix behind `0014`: instead of *handling* mixed msync+server wait sets, eliminate them.
`0008` left the macOS `inproc_sync` backend stubbed (`create_*` → NULL,
`get_inproc_sync_fd` → -1) and only events/mutexes/semaphores had an msync shadow, so
Process/Thread/Msg-queue/etc. stayed "server-only" and every wait mixing them fell to
the poll path — which floods the wineserver and stalls under Rosetta. `0017` implements
that backend (each `inproc_sync` owns an msync shm slot) and makes
`server/object.c default_get_sync()` lazily give **every** waitable object an
msync-backed `struct object.sync` shadow mirroring its signaled state (released in
`free_object`; `inproc_self_get_sync` stops a shadow shadowing itself). Result:
server-only Process waits dropped 3201 → ~6 and mixed-wait stalls 6+ → 0. Also folds in
three fixes that shipped uncommitted next to `0008`: the **boot-crash** dispatch guards
(`do_msync()` on `NtResetEvent`/`NtPulseEvent`/`NtWaitForSingleObject`, else the client
hits the server `event_op` path against an msync object and wineserver asserts), the
`mach_msg2` → libSystem `mach_msg()` Rosetta wrapper, and `do_msync()` honoring
`WINEMSYNC` (was hardcoded on). Passing the inproc-sync fd as an shm index *by value*
(`fsync_shm_idx` reply) since an msync slot is not a real fd. **NB:** `0017` was not the
Steam fix — with all lost-wakeup paths instrumented, zero were found; the remaining
client self-exit is a Rosetta/webhelper-handshake perf issue, not msync (see below).
Uniform shadows is kept as a genuine architectural win (kills the wineserver poll storm).

Build/install for `0014`–`0017`: `0014`/`0017` are unix ntdll + wineserver
(`dlls/ntdll/ntdll.so` → `Wine/lib/wine/x86_64-unix/`, `server/wineserver` → `Wine/bin/`);
`0015` is PE combase and `0016` is PE ntdll — build BOTH arches
(`dlls/{combase,ntdll}/{i386,x86_64}-windows/*.dll`) and copy into
`Wine/lib/wine/{i386,x86_64}-windows/` because **steam.exe is 32-bit**. Restart the
bottle's `wineserver -k` after swapping the unix ntdll or wineserver (version-keyed).

## Steam on Proton — launch investigation
Order of bugs hit while getting Steam to run (each unblocked the next):
1. **msync mixed-wait deadlock** (`0014`) — blocked wine-mono MSI, cold-boot service
   handshake (left `syswow64` empty), and Steam's `reg add`.
2. **combase/rpcss cold-start race** (`0015`) — steam.exe crashed ~seconds in with an
   uncaught `RPC_S_SERVER_UNAVAILABLE` during COM activation.
3. **FLS-callback deadlock** (`0016`) — after `0014`+`0015` the crash was gone but the
   bootstrap→client handoff hung 60 s on `fls_section`, then Steam self-terminated,
   orphaning `steamwebhelper_real.exe`.

After all three: steam.exe **boots cleanly and gets far** — CEF webhelper launches
(`logs/webhelper.txt` shows `Starting message loop`, network + storage child processes),
runs its message loop ~24 s, then `Quit message loop` / `Shutdown` when the client
(`-steampid`) exits. The **client itself self-exits ~35 s in (no crash, no exception),
never writing `connection_log`** — i.e. before the CM stage. Signature is a client-side
timeout on the steam.exe ↔ steamwebhelper handshake / login, not a CEF-start failure.
Reproduced identically across runs 6/7/8 regardless of webhelper-wrapper config or proxy.

**It is NOT a network / VPN / winsock problem** (verified):
- Steam downloads its update manifest directly (`client-update.steamstatic.com`,
  "Verification complete") with no VPN.
- China-channel CMs (`ISteamDirectory/GetCMList?cellid=47` → `103.28.54.x:27017`) are
  **directly reachable** from the host (`nc` succeeds).
- The user's geph runs in **proxy mode** (SOCKS `9909` / HTTP `9910`, no `utun`), so it
  neither transparently routes Steam's raw CM traffic nor is needed for it.

**Two app-launch gotchas found** (via `WhiskyCmd shellenv SteamProton`):
- **Follow System Proxy injects the geph HTTP proxy** (`http_proxy=http://127.0.0.1:9910`)
  because geph registers a macOS system proxy. That HTTP proxy **breaks Steam's CM**
  (WSS → 403) and the CM is directly reachable anyway → **turn Follow System Proxy OFF**
  for the Steam bottle when using a proxy-mode VPN. (The bottle's internal `ProxyEnable`
  registry is separate; keep both off.)
- The env sets **both `WINEESYNC=1` and `WINEMSYNC=1`**; macOS has no eventfd for esync,
  so this should be msync-only (`WINEESYNC=0`) — worth wiring for the Proton backend.

Next blocker to chase: why steam.exe's client self-exits ~35 s in without connecting to a
CM (client↔webhelper IPC / login handshake under Wine).

## scripts/install-proton.sh
Installs `vendor/proton-wine/build` into a self-contained `Wine/` dir (default
`INSTALL_DIR=vendor/proton-wine/dist`), mirroring `build-wine-x86.sh`'s install:
- `make install DESTDIR=` into a tmp tree under `arch -x86_64`, drop `.a` import libs
  and `share/man`, copy `bin`/`lib`/`share`.
- Bundle x86_64 dylibs (freetype, sdl2, molten-vk, gnutls, gettext, our
  `vendor/ffmpeg-x86` libs), materializing brew link-farm symlinks.
- **KosmicKrisp loader swap**: install the Khronos Vulkan loader as BOTH
  `Wine/lib/libMoltenVK.dylib` and `Wine/lib/libvulkan.1.dylib`; drop the ICD manifest
  to `~/.local/share/vulkan/icd.d/` (same wiring as `build-wine-x86.sh`).
- `install_name_tool -add_rpath '@loader_path/../..'` on every `x86_64-unix/*.so`.
- Append `[Drivers] Graphics=mac` to `share/wine/wine.inf`; symlink `wine64 → wine`.
- Swap into Whisky manually: `cp -R "$INSTALL_DIR/Wine" …/Libraries/Wine`.

## DXMT against Proton — scripts/build-dxmt.sh parameterization
`build-dxmt.sh` now reads two env vars (defaulting to the Whisky Wine):
- `DXMT_WINE_BUILD` — Wine build tree for headers (default `vendor/wine/build-x86_64`).
- `DXMT_WINE_LIB` — install target (default `…/Libraries/Wine/lib/wine`).

Build DXMT against Proton with:
```
DXMT_WINE_BUILD=vendor/proton-wine/build \
DXMT_WINE_LIB=<ProtonInstall>/Wine/lib/wine \
scripts/build-dxmt.sh
```
Everything else (LLVM 15 pin, zstd link fix, win64+win32 PE dlls, `winemetal.so`
unixlib) is unchanged.

## Mono
Proton hardcodes `wine-mono-10.4.1` (`MONO_VERSION` in
`dlls/appwiz.cpl/addons.c`). Decision: **do not build wine-mono from source** — let
Wine install it at runtime. The `.msi` is fetched to Wine's own cache (`~/.cache/wine/`)
through the system proxy (`dl.winehq.org` is GFW-blocked directly, reachable via
`127.0.0.1:9910`) so `wineboot` installs it silently.
