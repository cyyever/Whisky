# Proton migration — Valve Proton_11.0 on Apple Silicon (Rosetta 2)

Goal: replace Whisky's x86_64 Wine 11.13 with **Valve's `proton-wine` 11.0** so Proton
inherits all of Whisky's macOS capabilities — msync fast-sync, DXMT (D3D11/10/DXGI),
KosmicKrisp Vulkan, DXVK (D3D9), Steam webhelper CEF flags, CoreAudio
virtual-device hiding, `WINE_NX_COMPAT` — while keeping D3D9/10/11 all working. Motivation:
Proton ships Valve's game fixes, media-converter, `amd_ags`, fsync, and a maintained
tree that plain WineHQ 11.13 lacks.

## Status (Proton is the shipped, single backend; Steam logs in fully under msync)
- Proton is laid **directly over** `Libraries/Wine` — the single shipped backend. The
  `WineBackend` enum and the side-by-side `Libraries/WineProton` plumbing that existed
  during bring-up are gone; legacy Whisky-Wine 11.13 (`vendor/wine`) is removed entirely.
- Built x86_64, runs under Rosetta 2; DXMT installed on top of the Proton build.
  Reports `wine-11.0`.
- **Steam logs in fully.** With the minimal-msync config Steam boots → CEF webhelper →
  full CM logon: `RecvMsgClientLogOnResponse : 'OK'` + JWT, real SteamID, login window
  interactive, zero `OBJECT_TYPE_MISMATCH`. The launch config is:
  `WINEMSYNC_NO_MANUALEVENT=1` (manual-reset events → server-sync, everything else on
  msync — this is what fixed the full-msync spin, see "Steam on Proton"),
  `PROTON_DISABLE_LSTEAMCLIENT=1`,
  Follow-System-Proxy OFF, and msync-only (no eventfd on macOS, so WINEESYNC is unset).
  (`WINEMSYNC=1` is **not** set — `do_msync()` defaults msync ON, so it was dropped as
  redundant; only the `.none` sync mode sets `WINEMSYNC=0`.)
- Source tree `vendor/proton-wine/` is **gitignored**, tag `proton-wine-11.0-…`. Tracked
  in main: `patches/proton-wine/` (**34-patch series**, base `c3007e6f` on Valve's
  `bleeding-edge`) + `scripts/build-proton-x86.sh`
  (`make proton` — the single Wine build; configures, builds, installs to `Libraries/Wine`);
  `scripts/build-dxmt.sh` defaults `DXMT_WINE_BUILD` to `vendor/proton-wine/build`.
- **App wiring**: single backend, no selector. `BottleSettings` has no `WineBackend`;
  `Wine.wineBinary(for:)`/`binFolder(for:)` resolve to `WhiskyWineInstaller.binFolder`
  (`Libraries/Wine/bin`). `PROTON_DISABLE_LSTEAMCLIENT=1` is wired into `Wine.swift`.
  `BottleWineConfig.enhancedSync` defaults to `.msync`; a legacy `.esync` bottle is
  decode-migrated to `.msync`.

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

## patches/proton-wine/ — 34-patch series
Base: **`c3007e6f`** on Valve's `bleeding-edge` — the only branch Valve still pushes to
(see the header comment in `scripts/build-proton-x86.sh`, which is the source of truth).

Disjoint file ownership; all apply cleanly (`git apply --check`). Exported as
`git format-patch` style `.patch` files. Groups: `0001`–`0006` build/portability
(`0007` **dropped** → gap), `0008` the single consolidated msync patch, `0009` + `0011`–`0013`
macOS capability ports, `0010` the temporary msync MRING wait-path tracer,
`0014`–`0015` Steam-runtime deadlock fixes, `0016` msync
abandoned-mutex on last-handle-close, `0017` D3D/Vulkan builtin load-order default,
`0018` ws2_32 prefix hosts-file lookup, `0019` ws2_32 IPv4-only `getaddrinfo`
(`WINE_DISABLE_IPV6`), `0020` kernelbase appends `--no-sandbox` to
`steamwebhelper.exe` (retires the IFEO wrapper — see `docs/steam-webhelper.md`),
`0021` ws2_32 `WSALookupServiceBegin` half-stub, `0022` server clears stale
`AFD_POLL_CONNECT_ERR` on socket reuse (backport of upstream `864ca426`, Wine 11.14),
`0023` winemac snaps a borderless work-area-origin fullscreen window.

### Editing the series — `scripts/proton-branch.sh`
The `.patch` files stay the source of truth for a fresh clone, since `vendor/proton-wine`
is gitignored. But editing them by hand does not scale: `0008` **creates** its files
(`--- /dev/null`), so touching one means rewriting a whole new-file section, and moving a
hunk between patches means reproducing by hand the state each patch sees.

`proton-branch.sh init` replays the series as one commit per patch file on branch
`whisky/patches`, off tag `whisky/base`. Edit and commit there — `git commit --fixup=<sha>`
plus `git rebase --autosquash whisky/base` puts a hunk in the right patch — then
`proton-branch.sh export` writes the commits back. An `X-Patch-File:` trailer on each
commit preserves the filenames. Round trip is exact: applying the exported series onto
`whisky/base` reproduces the branch tip's tree hash.

Two things to know. `apply_patches()` in `scripts/lib/common.sh` **applies nothing** when
the tree is on `whisky/patches` — the series is already there as commits, and its
per-patch reverse-check could not work anyway once `0010` edits files `0008` creates. And
most patches carry no `From:` line; `git am` takes the author from the mail rather than
falling back to the config, so `init` synthesises one from the repo config.

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
  at 0007.

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
  - (**removed 2026-08-06, `e01790ad`** — was: an experimental `WINEMSYNC_UNIFIED`
    event-driven mixed-wait bridge. Opt-in via an env var nothing in the tree ever set,
    so it was unreachable; it also leaked subscriptions on thread death and could hand a
    recycled bridge shm index's subscriptions to a new thread. Deleted along with the
    unreachable inproc_sync msync backing and the `MSYNCSPIN`/`INNERSPIN`/`WAITDUMP`
    debug instrumentation — ~570 lines total, no behavior change. msync runs on the
    classic per-object shm path and always did);
  - **four NT-sync conformance fixes** (formerly standalone `0016`/`0017` in two rounds,
    now all folded into `0008` to keep the client msync sources single-owner): mutex
    `NtReleaseMutant` previous-count (`*prev = 1 - mutex->count`); msync/fsync alertable
    `NtDelayExecution` returning `STATUS_TIMEOUT` instead of `STATUS_SUCCESS`; wait fast-path
    now enforces `SYNCHRONIZE` on the object (records the granted access mask per cached
    handle, denies a wait that lacks it — clears kernel32:sync test:300 + cascade test:330);
    `NtPulseEvent` falls through to the wineserver for handles that don't resolve to an
    msync event, so a keyed event yields `STATUS_OBJECT_TYPE_MISMATCH` not
    `STATUS_ACCESS_DENIED` (clears ntdll:sync test:338).

#### Layout: five files, not one `msync.c`
`0008` creates the client backend as `dlls/ntdll/unix/`:

| file | what it owns |
|---|---|
| `msync_private.h` | payload structs, the offset asserts, type predicates, the readiness primitives |
| `msync_shm.c` | shm mapping, the mach semaphore pool, `do_msync`, `msync_init` |
| `msync_obj.c` | the object cache, `create_msync`, typed getters, the `Nt*` entry points |
| `msync_wait.c` | wait registration, `msync_wait_single`, `msync_wait_multiple` |
| `msync_select.c` | the mixed msync/server wait strategies and `msync_wait_any`/`_all` |

Three invariants hold the backend together, and each is now stated once:

- **Readiness lives at offset 0** of every payload — `semaphore.count`, `event.signaled`,
  `mutex.tid` — because `__ulock_wait2()` compares against the word the pointer names.
  `C_ASSERT`s in the header enforce it. Everything that asks "is this ready?" goes through
  `msync_ready()`, and everything that parks goes through `msync_wait_value()`; the mutex's
  odd cases (free `0`, abandoned `~0`, recursively held by us) are encoded in those two
  and nowhere else. On this side, at least — `server/msync.c`'s registration TOCTTOU
  re-check is a second encoding, deliberately, since it runs in the other process.
- **Type checks are inseparable from payload access.** `get_semaphore_object()` /
  `get_mutex_object()` / `get_event_object()` return the typed payload or
  `STATUS_OBJECT_TYPE_MISMATCH`; there is no way to reach `obj->shm` without having
  proved the type. Asserting accessors were tried and dropped: re-reading `obj->type`
  after the caller already branched on it opens a window where a concurrent close and
  handle reuse turns a returnable status into an `abort()`.
- **The semaphore pool never shrinks.** `->total` is a high-water mark into a *fixed*
  array — alloc hands out `&semaphores[total]` and increments — so decrementing it frees
  nothing and instead re-points the next alloc at a slot still in use. `semaphore_create()`
  then overwrites that slot's port name under a live waiter, and because the waiter
  re-reads `*sem` at `semaphore_wait()` — *after* `server_register_wait()` already gave the
  wineserver the old port — the wake goes to the old port and the waiter never returns.
  A permanent hang in the multi-object path, which is what `MsgWaitForMultipleObjects`
  uses. Ports are bounded at 1024; not shrinking is cheap.

Also in `0008`: `msync_wait_mixed_all()`, which replaced a `FIXME` that silently skipped
every server object (a wait-all over an event plus a named pipe returned `SUCCESS` with the
pipe unsignaled). It takes the msync side first, since that side can be rolled back with
`msync_ungrab()`, then the server side as one zero-timeout `SELECT_WAIT_ALL`; the
inter-round sleep deliberately passes **no** handles, because a `SELECT_WAIT` there would
consume a server object it could not give back. And four missing `msync_close()` hooks
alongside the existing `close_inproc_sync()` calls (`DUPLICATE_CLOSE_SOURCE`,
`get_apc_result`, `suspend_thread`, `get_thread_context`).

### Validating msync (conformance harness)
msync is a *transparent* backend for the NT sync primitives, so it has no tests of its own.
`scripts/test-msync.sh` runs Wine's `ntdll:sync` + `kernel32:sync` subtests under
`WINEMSYNC=1` (fast path) vs `WINEMSYNC=0` (wineserver baseline) and diffs them — a subtest
that passes on the baseline but fails under msync is a real msync bug; one that fails under
both is a pre-existing non-msync issue and is filtered out. `--guard-malloc` reruns under
macOS libgmalloc to catch heap corruption in msync's unix-side allocations. The test PEs are
built by `scripts/build-msync-tests.sh` (re-configures the already-compiled
`vendor/proton-wine/build` *without* `--disable-tests` and links just the two `*_test.exe` —
never runs `make install`, so the shipping build is untouched). This harness drove the msync
conformance work above: msync-only failures went **6 → 2**.
- kernel32:sync test:393/397 **abandoned-mutex** — msync tracked mutex ownership
  client-side only, so the object was freed at last handle-close before the owner thread's
  `TerminateThread` could run `msync_abandon_mutexes`. Fixed by `0016`, which keeps the
  shm slot alive server-side while an owner still holds the mutex.

  Current state of the harness: **ntdll 0 failures on both arms; kernel32 1 on both**, so
  no msync-only failure remains. A run is only meaningful if both arms produce a non-empty
  log — a wineserver left over from a previous run makes msync init fail, and a 0-byte log
  reads as "zero failures".

### 0009–0013 — macOS capability ports
- `0009-macos-dxmt-winemac-support` — the winemac side DXMT needs: a Metal view for an
  HWND. **Rewritten 2026-08-06** (`fc088f9e` → `845bd4d4` → `77a47e98`); the old shape
  described here — a `macdrv_functions` table plus a struct mimicking DXMT's 8.16-era
  copy of `macdrv_win_data` — is **gone**. Current shape:
  - two **scalar** exports, `macdrv_dxmt_create_metal_view(hwnd, device, *view, *layer)`
    and `macdrv_dxmt_release_metal_view(view)`. Every field of the old table and struct
    was pointer-sized, so a rename or reorder on either side compiled clean on both and
    then called the wrong function pointer. Scalars have no layout to keep in step.
    The DXMT side is `patches/dxmt/0005-winemetal-scalar-metal-view-entry-point.patch`
    (additive — the old dlsym path stays as a fallback for 3Shain's fork).
  - the view comes from `macdrv_client_surface_create()` (what winemac's own Vulkan
    driver uses for MoltenVK), registered with win32u via `add_window_client_surface()`,
    which the patch moves from `win32u_private.h` to `include/wine/gdi_driver.h` so a
    driver can call it. Wine then owns repositioning (`update_client_surfaces`) and
    teardown (`detach_client_surfaces`); the returned handle is the surface, so its
    refcount is the whole lifetime rule.
  - **the bug this fixed:** the old code hand-rolled a view with `macdrv_create_view()`
    and only attached it when `data->cocoa_window` was set — true for a toplevel, never
    for a child HWND. DXMT reads a NULL view as a broken Wine, logs *"your Wine has no
    exported symbols needed by DXMT"* and `abort()`s. Browsers (Chromium/CEF, Qt
    WebEngine) composite into child HWNDs, games do not — which is why only browsers
    died, black window then gone. Covered by `tests/dxmt-child-swapchain-test.c`.
  - still pairs with the **`RTLD_GLOBAL` dlopen for `winemac.so` only** in
    `dlls/ntdll/unix/loader.c` (not every unixlib — that would put all their
    default-visibility symbols in one namespace).
  - a `scripts/check-dxmt-abi.sh` guard existed briefly (`21adee60`) to police the
    struct ABI and was **deleted the same night** (`2744d49a`): with scalar arguments
    there is nothing to police. It does not exist; ignore any reference to it.
- `0023-macos-snap-borderless-fullscreen-window` — `rcWork` and `rcMonitor` share an
  origin on Windows (taskbar at the bottom) but not on macOS (menu bar at the top);
  measured in a bottle: `rcMonitor 0,0 1470x956` vs `rcWork 0,33 1470x923`. An app that
  asks for the work-area origin while sizing to the full monitor (Unity `-popupwindow`
  and friends) therefore lands one menu-bar height too low. Snaps exactly that case —
  borderless, display-sized, top edge aligned to that display's work area — and forces
  the frame-changed event so Wine's rects follow. Titled windows are left alone: AppKit's
  `constrainFrameRect:toScreen:` pins their top a couple of points below the work area
  (a titled window asked for `0,33` or `0,0` both land at `0,35`), and Wine reporting
  that faithfully is correct, not something to fight. `tests/window-snap-test.c`.
- `0010-macos-msync-mring-tracer` — **temporary.** A lock-free ring recording which msync
  objects each thread is about to block on, snapshotted to `/tmp/mring_<pid>.log` by a
  background thread; `WINE_MRING=1` arms it. It exists because `fprintf`-based tracing
  perturbs the lost wakeup it is meant to catch — the TRACE path's latency reorders a
  sub-microsecond race out of existence — so the hot path costs one atomic fetch-add and
  a few plain stores. Kept out of `0008` so it can be dropped in one move.
  (The number previously held `macos-kernelbase-ifeo-debugger`, deleted when `0020`
  retired the Steam webhelper wrapper that was its only consumer, along with
  `Steam.configure`'s per-bottle IFEO cleanup.)
- `0011-macos-nx-compat-env` — DEP stays on for legacy images by default (fixes DXMT
  Tahoe slowness); `WINE_NX_COMPAT=0` restores upstream, per program.
- `0012-macos-coreaudio-hide-virtual-devices` — hide virtual audio devices from games
  (`winecoreaudio.drv` + `mmdevapi`) — fixes device enum-loop hangs.
- `0013-macos-server-fsync-delinux` — de-linux the `server/fsync.c` stubs for the macOS
  build.

Provenance — these were ported from the now-removed Whisky-Wine `patches/wine/` set:
`0009`≈old `0002`+`0005`+`0006` (macdrv export + Metal view position + borderless
fullscreen-snap) — the fullscreen-snap has since been **split out into `0023`**, so
`0009` is now the Metal-view entry points only; old `0010`≈`0003` (removed; the number
was later reused for the MRING tracer), `0011`≈`0004`,
`0012`≈`0007`. The old rundll32
WS_VISIBLE patch was obsolete (dropped above). `0008`/`0013` (msync + fsync) and
`0001`–`0006` are Proton-specific (WineHQ 11.13 already had msync-free sync and none of
Proton's extra unixlibs).

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
the poll interval off 2 ms → 16 ms when idle; NULL-guard `msync_apc_addr`. **This poll is
the only mixed-wait mechanism.** An event-driven `WINEMSYNC_UNIFIED` bridge and a "uniform
inproc_sync shadows" rework were both tried as alternatives and are both **gone** (see the
removal note under `0008` above); inproc_sync is structurally wrong for macOS, where an
msync object is pure shm + `__ulock` with no fd for the server to wait on.

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

### 0016–0035 — one line each
Not written up individually: each patch file carries its own reasoning in its header,
and that header is the source of truth. Listed here only so the enumeration above is
not mistaken for the whole series.

- `0016` msync: abandon an owned mutex once its last handle closes.
- `0017` ntdll: resolve the D3D/Vulkan builtins **ahead of the registry**, so a bottle's
  stale `DllOverrides` cannot make a shipped builtin unloadable.
- `0018` ws2_32: resolve names from the prefix `hosts` file first.
- `0019` ws2_32: IPv4-only `getaddrinfo` by default; `WINE_DISABLE_IPV6=0` opts out.
- `0020` kernelbase: append `--no-sandbox --in-process-gpu` to steamwebhelper.exe.
- `0021` ws2_32: `WSALookupServiceBegin` semi-stub succeeds with an empty set.
- `0022` server: clear connection-failure events in `IOCTL_AFD_WINE_CONNECT`.
- `0023` winemac: correct a borderless window placed at the work-area origin.
- `0026` ntdll: disable Steam's overlay DLLs on macOS. `GameOverlayRenderer.dll` hooks
  user32's input entry points inline; under Rosetta that write traps into Rosetta's own
  exception server and is retried forever, hanging the game with no fault ever reaching
  Wine. Resolved ahead of the registry like `0017`; `WINEDLLOVERRIDES` still wins.

**Permanent — behaviour fixes, keep:**

- `0031` ntdll: lsteamclient off by default; `PROTON_DISABLE_LSTEAMCLIENT=0` restores it.
- `0032` winebus: SDL's MFI joystick backend off by default, set as an SDL hint at
  `SDL_HINT_DEFAULT` priority so `SDL_JOYSTICK_MFI=1` still wins.
- `0033` winegstreamer: two faults in `autoplug_select_cb`. `stream_decodebin_create`
  connected it with `stream` where the callback reads its user_data as a
  `struct wg_parser *`, so `parser->error` came from the wrong offset and every
  decoder was silently SKIPped — present in upstream WineHQ too. And the mediaconv
  audio converters had no `!use_mediaconv` guard, so they outranked the real decoder
  and then failed in `change_state`. Symptom of either: "Missing decoder" on a Wine
  whose libav is registered and whose caps match.
- `0034` winegstreamer: the avdec_h264 capsfilter workaround is now gated on a parser
  actually having been found. Without one, `parsed_caps` is a second reference to
  `transform->input_caps` — `gst_caps_set_simple()` refuses to touch shared caps and
  only logs a GLib CRITICAL — and the filter would be the first element, forced to
  byte-stream against an avc caps event. It is h264parse's bug, so with no h264parse
  there is nothing to work around.
- `0035` winegstreamer: no GL display on macOS — a non-NULL display let the glupload
  chain create a Cocoa GL context whose main-thread block faults with no Wine TEB,
  freezing the process's Cocoa main thread. Guarded by `tests/gstreamer/dshow-render-test.sh`
  (which SKIPs without mingw/timeout/a bottle WMV — run it where those exist).

**Temporary — diagnostics, drop together when the investigations close:**

- `0024` ntdll: `WINE_SEGV_TRACE=1` → `/tmp/{segv,modmap,vprot}_<pid>.log`.
- `0025` kernelbase: `--enable-logging --v=1` for steamwebhelper, so CEF children report
  why they exit.
- `0027` ntdll: widen `0024`'s vprot filter to EXECUTE protections (and always log
  failures) so the game's own code pages are covered.
- `0028` ntdll: `WINE_DISABLE_IMAGE_ASLR` skips the server-assigned load address
  for DYNAMICBASE images, so a DLL lands on its preferred base when that address
  is free. Purely to isolate relocation as a variable — the comment lists why it
  must not be switched on, the sharpest being that per-process bases corrupt
  `IMAGE_SCN_MEM_SHARED|MEM_WRITE` sections across the prefix.
- `0029` ntdll: review fixes for the above — the vprot cap now announces itself,
  the disable traces with a verdict token, and the overlay comment carries the
  Steam Input cost it had been understating.
- `0030` ntdll: the sharpest argument against `0028` — per-process image bases
  break `IMAGE_SCN_MEM_SHARED|MEM_WRITE` sections, which are mapped MAP_SHARED
  across the prefix, so one process's relocations become another's wrong
  pointers. Plus the cap banner ordering and the environment branch's trace token.


## Steam on Proton — launch investigation
**Resolved 2026-07-24: Steam logs in fully.** Order of bugs hit and fixed to get there:
1. **Proton lsteamclient tier0 crash** — the "reinstall Steam" box was Proton's
   lsteamclient redirect stranding `steamclient64`'s tier0 imports (`g_pMemAllocSteam`)
   on ntdll stubs. Fixed by disabling the bridge by default (`0031`);
   `PROTON_DISABLE_LSTEAMCLIENT=0` restores it.
   Proton-only bug, not upstream Wine.
2. **msync mixed-wait deadlock** (now folded into `0008`) — blocked wine-mono MSI,
   cold-boot service handshake (left `syswow64` empty), and Steam's `reg add`.
3. **combase/rpcss cold-start race** (`0014`) — steam.exe crashed ~seconds in with an
   uncaught `RPC_S_SERVER_UNAVAILABLE` during COM activation.
4. **FLS-callback deadlock** (`0015`) — bootstrap→client handoff hung 60 s on
   `fls_section`, then Steam self-terminated, orphaning the webhelper child process.
5. **msync socket-async / system-APC lost-wake** (now in `0008`) — the last blocker.
   Socket async completions were not delivering under msync; `msync_run_system_apcs()`
   drains system APCs on the SIGUSR1/EINTR interrupt. **This is the fix that made Steam
   log in.**

After all of the above, with msync enabled (the default; no `WINEMSYNC=1` needed) Steam
completes a full CM logon (`RecvMsgClientLogOnResponse : 'OK'` + JWT, real SteamID,
interactive login window, zero `OBJECT_TYPE_MISMATCH`).

**The full-msync CPU spin — localized and fixed (`a54abb92`).** steam.exe pinned a core
inside `msync_wait_multiple` on a rapidly set/reset **MANUAL** event (type 3), not an
auto-reset one — so no auto-event lever could ever have stopped it.
Reproduced and bisected with `scripts/msync-manualevent-spin-test.c`: plain msync burns
~13.6 CPU-s / 12.6M wakeups, `WINEMSYNC_NO_MANUALEVENT=1` drops it to ~6.2 CPU-s / 0.6M —
identical to the `WINEMSYNC=0` server baseline, and `scripts/test-msync.sh` shows no new
msync-only failures. `Wine.swift` sets it, and it is now the only `WINEMSYNC_*` variable
Whisky sets; coarser lever if it ever regresses is
`WINEMSYNC_NO_EVENT=1` (all events → server). An inner-loop bounded-spin/`usleep` backoff
on `STATUS_PENDING` was tried and **reverted** — the cost is a wake storm (real
`STATUS_SUCCESS` returns), so a per-`STATUS_PENDING` backoff never fires; routing is the
right layer, not a fast-path code patch.

Note the spin was blamed for the invisible Steam login window; that turned out to be an
unrelated DXMT/winemac bug (see `0009` above and `docs/steam-webhelper.md` §0). The spin
was real and the fix is real, but it was not that bug's cause.

**msync enablement scope + gating code** (all in `dlls/ntdll/unix/msync_obj.c`, code is the
source of truth):
- **Global switch — `do_msync()`.** On macOS msync defaults **ON** (`WINEMSYNC` unset ⇒ 1);
  `WINEMSYNC=0` forces it off (debug/fallback to the slower wineserver sync). It is the
  `__ulock`/mach-semaphore fast path.
- **Per-type scope.** Every type is now gateable: events via `event_uses_msync(type)`,
  semaphores via `use_msync_semaphore()`, mutexes via `use_msync_mutex()`. When a gate
  returns 0 the `Nt*` wrapper returns `STATUS_NOT_IMPLEMENTED` and falls through to the
  wineserver path (same as server-only objects — no msync/server casting). All default
  **on**; semaphores and mutexes are the game hot path and should stay on.
- **Bisection levers** (env, inherited so a named object resolves to the same type in
  every process). The full set that `dlls/ntdll/unix/msync_obj.c` actually reads is:
  `WINEMSYNC_NO_EVENT` (all events → server), `WINEMSYNC_NO_AUTOEVENT`,
  `WINEMSYNC_NO_MANUALEVENT`, `WINEMSYNC_NO_SEMAPHORE`, `WINEMSYNC_NO_MUTEX`.
  `event_uses_msync()` takes only the type — there is **no** anon/named distinction.
  `NO_MANUALEVENT` is the one that fixed the spin, and is now ON by default in
  `read_type_gates()` (`=0` turns it off); the rest are for bisecting.
  > ⚠️ **`WINEMSYNC_NO_ANON_AUTOEVENT` / `WINEMSYNC_NO_NAMED_AUTOEVENT` never existed.**
  > Nothing in the msync sources reads them (verified against `vendor/proton-wine` and every
  > revision of patch `0008` in git). They were **removed** from `Wine.swift` and from
  > the harness scripts in `bf150501`. Do not reintroduce them, and do not trust any
  > older result that leaned on them: `test-msync.sh` and `run-msync-close-test.sh`
  > used to *unset* `NO_ANON_AUTOEVENT` to build their "full msync" arm, so both arms
  > were the same configuration and the comparison measured nothing.
  > `tests/env-contract-test.sh` now fails if Whisky sets a variable that nothing in
  > the Wine tree reads.

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
- **msync-only (no eventfd on macOS → esync can't exist).** Resolved: nothing on the
  stack reads WINEESYNC (no `esync.c` in the wine tree; DXMT doesn't read it — verified
  by binary scan). msync defaults ON in `do_msync()`, so `BottleSettings` sets **no**
  `WINEMSYNC` at all for the default `.msync` mode (only `.none` sets `WINEMSYNC=0`), and
  leaves WINEESYNC unset (the env dict fully replaces the parent, so unset ≡ 0). (There is no "DXMT esync-detection
  lie" — that was a myth; no such `lid3dshared.dylib` exists.)
- **lsteamclient disabled by default** (patch `0031`; `PROTON_DISABLE_LSTEAMCLIENT=0`
  restores it).
- The Steam webhelper wrapper is applied automatically on launch — from the GUI or via
  `whisky run`, both through `Wine.prepareForLaunch` → `Steam.configure`.

## scripts/build-proton-x86.sh (was install-proton.sh + build-wine-x86.sh)
`make proton` runs `scripts/build-proton-x86.sh`, the single Proton build: it resets
`vendor/proton-wine` tracked source to HEAD, (reverse-check-)applies
`patches/proton-wine/*`, configures + builds x86_64 (WoW64), then installs into
`Libraries/Wine` — the single shipped backend. Install steps:
- `make install DESTDIR=` into a tmp tree under `arch -x86_64`, drop `.a` import libs
  and `share/man`, PE-strip in release (`WHISKY_WINE_BUILD=debug` keeps debug info),
  copy `bin`/`lib`/`share`.
- Bundle x86_64 dylibs (freetype, sdl2, molten-vk, gnutls, gettext, our
  `vendor/ffmpeg-x86` libs), materializing brew link-farm symlinks.
- **KosmicKrisp loader swap**: install the Khronos Vulkan loader as BOTH
  `Wine/lib/libMoltenVK.dylib` and `Wine/lib/libvulkan.1.dylib`; drop the ICD manifest
  to `~/.local/share/vulkan/icd.d/`.
- **DXMT restore over wined3d**: `make install` writes Wine's builtin `d3d11.dll`
  (wined3d — FL 9_3 → GLES2 only), clobbering any prior DXMT install. The script
  restores the DXMT Metal builds (d3d11/d3d10core/dxgi/winemetal, x86_64 + i386)
  over them so `make proton` is order-independent — skipped when DXMT artifacts
  are absent (run `make dxmt`). Mirrors the KosmicKrisp swap; see
  `docs/steam-webhelper.md` for why the webhelper needs DXMT (GLES3 /
  SharedImageStub).
- `install_name_tool -add_rpath '@loader_path/../..'` on every `x86_64-unix/*.so`.
- Append `[Drivers] Graphics=mac` to `share/wine/wine.inf`; symlink `wine64 → wine`;
  write `WhiskyWineVersion.plist`.

(The old `install-proton.sh` — which assumed a pre-built tree and had an
`INSTALL_TO_WHISKY=1` side-by-side `Libraries/WineProton` option — was folded into
`build-proton-x86.sh` and removed. Proton now installs straight over `Libraries/Wine`.)

## DXMT against Proton — scripts/build-dxmt.sh parameterization
`build-dxmt.sh` reads two env vars, both **defaulting to the Proton build** (the
shipped backend):
- `DXMT_WINE_BUILD` — Wine build tree for headers (default `vendor/proton-wine/build`).
- `DXMT_WINE_LIB` — install target (default `…/Libraries/Wine/lib/wine`).

The defaults are correct for the normal `make dxmt`; override only to build DXMT
against a *different* Wine tree:
```
DXMT_WINE_BUILD=<other>/build \
DXMT_WINE_LIB=<OtherInstall>/Wine/lib/wine \
scripts/build-dxmt.sh
```
Everything else (LLVM 15 pin, zstd link fix, win64+win32 PE dlls, `winemetal.so`
unixlib) is unchanged.

## Mono
Proton hardcodes `wine-mono-10.4.1` (`MONO_VERSION` in
`dlls/appwiz.cpl/addons.c`). Decision: **do not build wine-mono from source** — let
Wine install it at runtime. The `.msi` is fetched to Wine's own cache (`~/.cache/wine/`)
through the system proxy (`dl.winehq.org` is blocked directly on some networks, reachable via
`127.0.0.1:9910`) so `wineboot` installs it silently.
