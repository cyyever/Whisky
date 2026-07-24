# Proton migration — Valve Proton_11.0 on Apple Silicon (Rosetta 2)

Goal: replace Whisky's x86_64 Wine 11.13 with **Valve's `proton-wine` 11.0** so Proton
inherits all of Whisky's macOS capabilities — msync fast-sync, DXMT (D3D11/10/DXGI),
KosmicKrisp Vulkan, DXVK (D3D9), the Steam webhelper IFEO wrapper, CoreAudio
virtual-device hiding, `WINE_NX_COMPAT` — while keeping D3D9/10/11 all working. Motivation:
Proton ships Valve's game fixes, media-converter, `amd_ags`, fsync, and a maintained
tree that plain WineHQ 11.13 lacks.

## Status (2026-07-24 — Proton is the shipped default backend; Steam logs in fully under msync)
- Proton lives **side-by-side** at `Libraries/WineProton` (canonical `Libraries/Wine`
  untouched). During bring-up it was also live-swapped into `Libraries/Wine` with the
  Whisky Wine backed up at `…/Libraries/Wine.whisky-bak`.
- Built x86_64, runs under Rosetta 2; DXMT installed on top of the Proton build.
  Reports `wine-11.0`.
- **Steam logs in fully.** With the minimal-msync config Steam boots → CEF webhelper →
  full CM logon: `RecvMsgClientLogOnResponse : 'OK'` + JWT, real SteamID, login window
  interactive, zero `OBJECT_TYPE_MISMATCH`. The launch config is:
  `WINEMSYNC=1` + `WINEMSYNC_NO_ANON_AUTOEVENT=1` (anon auto-reset events → server-sync,
  everything else on msync — a workaround lever; the residual full-msync spin is not
  reliably root-caused, see "Steam on Proton"), `PROTON_DISABLE_LSTEAMCLIENT=1`,
  Follow-System-Proxy OFF, and msync-only (`WINEESYNC=0` — macOS has no eventfd).
- Source tree `vendor/proton-wine/` is **gitignored** (like `vendor/wine`), tag
  `proton-wine-11.0-…`. Tracked in main: `patches/proton-wine/` (**14-patch series**) +
  `scripts/install-proton.sh`; `scripts/build-dxmt.sh` and `scripts/build-wine-x86.sh`
  gained env-var / source-reset hooks.
- **App wiring — Proton locked as default**: `BottleSettings.WineBackend` defaults to
  `.proton` (struct default + decode fallback); the `ConfigView` backend selector is
  removed. `.whiskyWine` (legacy Wine 11.13) stays in the enum for fallback but is not
  user-selectable. `Wine.wineBinary(for:)`/`binFolder(for:)` resolve per bottle;
  `WhiskyWineInstaller.protonBinFolder` prefers a side-by-side `Libraries/WineProton`,
  else falls back to `Libraries/Wine` (works whether Proton is side-by-side or laid over
  `Libraries/Wine`). `PROTON_DISABLE_LSTEAMCLIENT=1` is wired into `Wine.swift`.
- Not yet done: no version-plist/appcast switch (end-user shipping), no committed
  submodule pin for the Proton source. Legacy Whisky-Wine 11.13 remains only as a
  non-user-selectable fallback backend.

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

## patches/proton-wine/ — 14-patch series
Disjoint file ownership; all 14 apply cleanly (`git apply --check`) and reproduce the live
tree byte-for-byte (base `81d78e4`). Exported as `git format-patch` style `.patch` files.
Groups: `0001`–`0006` build/portability (`0007` **dropped** → gap), `0008` the single
consolidated msync patch, `0009`–`0013` macOS capability ports, `0014`–`0015`
Steam-runtime deadlock fixes. There is **no `0016`/`0017`** — the old standalone
msync-refinement patches were folded into `0008`.

### 0001–0006 — build / portability (make Proton compile + boot on macOS; 0007 dropped)
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
- `0007-rundll32-remove-ws-visible-wineboot-hang` — **DROPPED 2026-07-24 (obsolete).**
  Verified `wineboot --init` completes rc=0 in ~16s on a fresh prefix with upstream
  `WS_VISIBLE` (twice); the winemac deadlock is gone in proton-wine 11.0. Leaves a gap
  at 0007. The Whisky-Wine `patches/wine/0001` variant is left in place pending its own
  re-verification on the 11.13 stack.

### 0008 — msync (single consolidated patch)
- `0008-macos-msync` — the big one (**~55 files, ONE patch**, incl. regenerated protocol
  files so a fresh apply needs no `make_requests`). All msync work lives here:
  - CrossOver macOS fast-sync (msync) core across `dlls/ntdll/unix/*` and `server/*`;
  - the boot-crash dispatch-guard fix above (`do_msync()` on `NtResetEvent`/`NtPulseEvent`/
    `NtWaitForSingleObject` — else the client hits the server `event_op` path against an
    msync object and wineserver asserts) plus the `req_event_op`/`query_event` handlers
    branching on `obj.ops==&msync_ops`;
  - `do_msync()` honoring `WINEMSYNC` (was hardcoded on);
  - the `mach_msg2` → libSystem `mach_msg()` Rosetta wrapper (the raw `mach_msg2_trap`
    is invoked through an untranslated pointer under Rosetta and crashes);
  - the **mixed-wait hybrid** `msync_wait_mixed_any` + per-object msync idx for waits
    (formerly the standalone `0014` refinement — see "Mixed waits" below);
  - msg-queue wake consistency (formerly a standalone patch);
  - the **socket-async / system-APC lost-wake fix** (`msync_run_system_apcs()` drains
    system APCs on the SIGUSR1/EINTR interrupt so socket async completions deliver — the
    fix that made Steam log in);
  - the experimental `WINEMSYNC_UNIFIED` event-driven mixed-wait bridge (opt-in).

### 0009–0013 — macOS capability ports
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

Mapping to the Whisky-Wine patch set: `0009`≈`patches/wine/0002`+`0005`,
`0010`≈`patches/wine/0003`, `0011`≈`patches/wine/0004`, `0012`≈`patches/wine/0007`.
`0008`/`0013` (msync + fsync) and `0001`–`0006` are Proton-specific (WineHQ 11.13 already
had msync-free sync and none of Proton's extra unixlibs).

### Mixed waits (folded into 0008)
msync (like esync) cannot natively wait on a set mixing fast msync objects
(events/mutexes/semaphores) with pure-server objects (named pipes, async I/O, completion
ports). Upstream just logs a FIXME and waits on the msync objects only → deadlock
whenever a server object is the waker (RpcSs startup, wine-mono MSI, cold-boot service
handshake, Steam's `reg add`). fsync escapes this via in-proc-sync fds the server can
wait on; msync has no server-side shadow. Fix (now in `0008`): `msync_wait_mixed_any()`
polls — grab any ready msync object in userspace, and between checks do a short bounded
`server_wait()` on just the server subset (`objs[i]==NULL` marks a server object). Only
mixed waits (RPC/service, never a game hot path) take this path. Hardened per review:
propagate real `server_wait` errors instead of busy-looping on non-`STATUS_TIMEOUT`; back
the poll interval off 2 ms → 16 ms when idle; NULL-guard `msync_apc_addr`. The
experimental `WINEMSYNC_UNIFIED` bridge in `0008` is a later event-driven alternative to
this poll path (opt-in). (The earlier "uniform inproc_sync shadows" rework was folded into
`0008` as well.)

### 0014–0015 — Steam-runtime deadlock fixes (all found live under Steam)
Both are **PE** dlls built for BOTH arches (`dlls/{combase,ntdll}/{i386,x86_64}-windows/*.dll`
→ `Wine/lib/wine/{i386,x86_64}-windows/`) because **steam.exe is 32-bit**.
- `0014-combase-rpcss-cold-start-race` — `dlls/combase/rpc.c`. COM out-of-proc activation
  binds `ncalrpc:[irpcss]`; on a cold boot steam.exe races ahead and connects to the
  `\\.\pipe\lrpc\irpcss` endpoint ~tens-of-ms before rpcss creates it →
  `RPC_S_SERVER_UNAVAILABLE`, and `start_rpcss()`'s retry gave up because
  `OpenService("RpcSs")` also fails in the same cold window → uncaught → crash. Fix:
  make SCM/StartService best-effort and **`WaitNamedPipe`** on the irpcss endpoint pipe
  (bounded 30 s) before returning success. Root cause is startup ordering (`OpenService`
  failing during cold boot), not "Rosetta slowness" per se; the pipe path is derived from
  `IRPCSS_ENDPOINT` so it can't drift.
- `0015-ntdll-fls-callback-no-lock` — `dlls/ntdll/thread.c`. `RtlFlsFree` and
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

## Steam on Proton — launch investigation
**Resolved 2026-07-24: Steam logs in fully.** Order of bugs hit and fixed to get there:
1. **Proton lsteamclient tier0 crash** — the "reinstall Steam" box was Proton's
   lsteamclient redirect stranding `steamclient64`'s tier0 imports (`g_pMemAllocSteam`)
   on ntdll stubs. Fixed with `PROTON_DISABLE_LSTEAMCLIENT=1` (wired into `Wine.swift`).
   Proton-only bug, not upstream Wine.
2. **msync mixed-wait deadlock** (now folded into `0008`) — blocked wine-mono MSI,
   cold-boot service handshake (left `syswow64` empty), and Steam's `reg add`.
3. **combase/rpcss cold-start race** (`0014`) — steam.exe crashed ~seconds in with an
   uncaught `RPC_S_SERVER_UNAVAILABLE` during COM activation.
4. **FLS-callback deadlock** (`0015`) — bootstrap→client handoff hung 60 s on
   `fls_section`, then Steam self-terminated, orphaning `steamwebhelper_real.exe`.
5. **msync socket-async / system-APC lost-wake** (now in `0008`) — the last blocker.
   Socket async completions were not delivering under msync; `msync_run_system_apcs()`
   drains system APCs on the SIGUSR1/EINTR interrupt. **This is the fix that made Steam
   log in.**

After all of the above, under `WINEMSYNC=1` Steam completes a full CM logon
(`RecvMsgClientLogOnResponse : 'OK'` + JWT, real SteamID, interactive login window, zero
`OBJECT_TYPE_MISMATCH`).

**Remaining rough edge:** a full-msync (all-events-on-msync) CPU spin. `WINEMSYNC_NO_ANON_AUTOEVENT=1`
(anon auto-reset events → server-sync, everything else on msync) is the currently wired
Proton-backend default (`Wine.swift`), but re-verification found steam.exe can still pin a
core with it set (the busy-poll was seen on a *manual* event, type=3, not an auto-reset
event), so it is an **unproven workaround, not a fix or a diagnosis**. The earlier
"anonymous auto-reset events" localization was **retracted as unverified**; the root cause
is not reliably localized.

**msync enablement scope + gating code** (all in `dlls/ntdll/unix/msync.c`, code is the
source of truth):
- **Global switch — `do_msync()`.** On macOS msync defaults **ON** (`WINEMSYNC` unset ⇒ 1);
  `WINEMSYNC=0` forces it off (debug/fallback to the slower wineserver sync). It is the
  `__ulock`/mach-semaphore fast path.
- **Per-type scope.** Semaphores and mutexes are **never** gated — always on msync when the
  global switch is on (the game hot path). Only **events** are maskable, via
  `event_uses_msync(type, named)`: when it returns 0 the `Nt*Event` wrapper returns
  `STATUS_NOT_IMPLEMENTED` and falls through to the wineserver path (same as server-only
  objects — no msync/server casting). Manual-reset events go through msync unless
  `WINEMSYNC_NO_EVENT`; auto-reset events are additionally steerable (they're implicated in
  the spin).
- **Event bisection levers** (env, inherited so a named event resolves to the same type in
  every process): `WINEMSYNC_NO_EVENT` (all events → server), `WINEMSYNC_NO_AUTOEVENT` (all
  auto-reset events), and the finer `WINEMSYNC_NO_ANON_AUTOEVENT` / `WINEMSYNC_NO_NAMED_AUTOEVENT`
  (anonymous process-local vs named cross-process auto-events). There are **no**
  semaphore/mutex/manual-event levers — those types are unconditionally on msync. These
  levers exist to bisect the spin; none is a confirmed fix. (This also explains why
  `NO_ANON_AUTOEVENT` doesn't stop the spin: the busy-poll sits on a *manual* event, which
  no auto-event lever touches.)

**It is NOT a network / VPN / winsock problem** (verified during the investigation):
- Steam downloads its update manifest directly (`client-update.steamstatic.com`,
  "Verification complete") with no VPN.
- China-channel CMs (`ISteamDirectory/GetCMList?cellid=47` → `103.28.54.x:27017`) are
  **directly reachable** from the host (`nc` succeeds).
- The user's geph runs in **proxy mode** (SOCKS `9909` / HTTP `9910`, no `utun`), so it
  neither transparently routes Steam's raw CM traffic nor is needed for it.

**App-launch gotchas:**
- **Follow System Proxy OFF.** Follow System Proxy injects the geph HTTP proxy
  (`http_proxy=http://127.0.0.1:9910`) because geph registers a macOS system proxy; that
  HTTP proxy **breaks Steam's CM** (WSS → 403) and the CM is directly reachable anyway.
  (The bottle's internal `ProxyEnable` registry is separate; keep both off.)
- **msync-only (`WINEESYNC=0`).** macOS has no eventfd for esync. Resolved: `BottleSettings`
  now sets `WINEESYNC=0` for the Proton backend while keeping the DXMT `WINEESYNC=1` "lie"
  (`lid3dshared.dylib` esync-detection) for the legacy Whisky-Wine backend.
- **`PROTON_DISABLE_LSTEAMCLIENT=1`** (wired into `Wine.swift`).
- CLI launch needs `whisky steam-fix <bottle>` first.

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
- **`INSTALL_TO_WHISKY=1`** lays the result into `Libraries/WineProton` (side-by-side with
  `Libraries/Wine`, the legacy fallback that `Wine.binFolder(for:)` resolves to for a
  `.whiskyWine` bottle); or `cp -R "$INSTALL_DIR/Wine" …/Libraries/Wine` to replace outright.

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
