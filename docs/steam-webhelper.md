# Steam webhelper: CEF flags via Proton + update-stuck proxy fix

Three Steam-under-Wine problems and how Whisky solves them. §0 and §1 both present as a
black window and are easy to confuse — §0's vanishes, §1's stays.

## 0. Black window that then *vanishes* — the DXMT child-HWND abort (root cause, fixed 2026-08-06)

Distinct from §1's permanently-black window: this one paints black for a few seconds
and then the window disappears, taking the GPU process with it. It hit Steam's CEF,
GOG Galaxy (Qt WebEngine) **and** plain upstream Chromium in the same bottle — but never
a game.

Cause was ours, in `patches/proton-wine/0009`. Its winemac Metal-view shim hand-rolled a
view with `macdrv_create_view()` and only attached it when `data->cocoa_window` was set —
true for a toplevel window, never for a **child HWND**, which has no Cocoa window of its
own. DXMT reads the resulting NULL view as a broken Wine: `d3d11_swapchain.cpp:138` logs
*"your Wine has no exported symbols needed by DXMT"* and calls `abort()`. Browsers
composite into child HWNDs; games render into their toplevel. Hence "only browsers".

Fixed by rewriting `0009` (`fc088f9e` → `845bd4d4` → `77a47e98`) onto
`macdrv_client_surface_create()` + `add_window_client_surface()`, exporting two scalar
functions instead of a struct-shaped ABI — details in `docs/proton-migration.md` under
`0009`. Regression test: `tests/dxmt-child-swapchain-test.c`.

**Diagnosing this one:** the DXMT log line above is the tell. If you instead see feature
level 9_3 in `tests/d3d11-featurelevel-test.c`, that is the *other* DXMT bug — `make proton`
clobbering DXMT with wined3d, §1 below.

**Status after the fix:** steam.exe survives 7+ minutes (it used to die inside 45 s) and
steamwebhelper no longer hits "Quit message loop" (it used to, at 12–21 s). Login now
works end to end when launched **from the Whisky GUI** — the 700x440 login window renders,
`RecvMsgClientLogOnResponse 'OK'`, and the full UI (main window 1280x800, Friends List,
Special Offers) comes up onscreen. The earlier "the window exists at 1102x659 with
`WS_VISIBLE` unset, Steam never calls `ShowWindow`" reading came from a bare-CLI launch,
which is not equivalent to the GUI launch and does not count.

`gldriverquery.exe` exiting `3221225781` (`STATUS_DLL_NOT_FOUND`, the missing 32-bit
`SDL2.dll`) is **not** a lead for anything — measured 2026-08-07 by moving the DLL aside:
the probe failed, and Steam logged in three seconds later and showed its whole UI anyway.
`scripts/build-sdl2.sh` only silences that one log line; it is optional.

**Still open:** the "Special Offers" news window cannot be closed **while msync is on**.
`WM_CLOSE` is ignored and `SendMessageTimeout(WM_NULL)` to it times out — its owning
thread is not pumping; `sample` puts `CrBrowserMain` in `msync_wait_single` /
`msync_wait_multiple`. Setting the bottle's enhanced sync to **none** (`WINEMSYNC=0`)
closes the window, and a `sample` of that run has zero `msync_wait_single` frames and 47
`server_select` frames — so msync is the cause, not the window system. The object type is
**not** yet narrowed: manual events are already gated to server-sync by default, so the remaining
candidates are auto-events, semaphores and mutexes.

Read that A/B narrowly. Until `7ea00fa1`, `constructWineServerEnvironment()` did not apply
the bottle's settings, so enhanced-sync-none turned msync off **for the clients only** —
the wineserver kept running with it on (confirmed by reading the live server's environment
with `ps eww`). The observation stands, but it implicates the client half
(`dlls/ntdll/unix/msync_*.c`), not the whole subsystem. A quick way to tell which side is
off: MRING is armed at the end of `msync_init()`, which only runs when `do_msync()` is
true, so the **absence** of `/tmp/mring_<pid>.log` for a process proves msync is off in it.

Bisect it with per-program environment variables (`ProgramSettings.environment`, stored in
the bottle's `Program Settings/<exe>.plist`) — they are applied after Whisky's defaults and
override them, so no rebuild is needed. Kill every stale Wine process between arms or the
next one dies at `msync_init Failed to open msync shared memory file`. Use only gates
`msync_obj.c` actually reads (`WINEMSYNC_NO_EVENT`, `_NO_AUTOEVENT`, `_NO_MANUALEVENT`,
`_NO_SEMAPHORE`, `_NO_MUTEX`); `WINEMSYNC_NO_ANON_AUTOEVENT` never existed and silently
invalidated earlier A/Bs (removed in `bf150501`; `tests/env-contract-test.sh` now guards
against the whole class).

> When reading exit codes, do not pipe: `cmd | grep | head; echo $?` reports the status of
> `head`, not of `cmd`. Several readings during this investigation were wrong for exactly
> that reason. `tests/bottle-health-test.c` uses `GetExitCodeProcess` and is correct.

## 1. Black window (CEF GPU sandbox)

Steam's CEF host `steamwebhelper.exe` renders a black window under Wine: its
sandbox hooks the NT kernel and the out-of-process GPU can't reset the D3D
device (`problems[10]: Some drivers are unable to reset the D3D device in the GPU
process sandbox`). It needs `--no-sandbox`.

**Why the sandbox can't be fixed.** Wine's sandbox emulation is incomplete:
`SetTokenInformation(TokenIntegrityLevel)`, `SetProcessMitigationPolicy`, and
`NtCreateLowBoxToken` are silent stubs that report success without enforcing
anything — only the window-station/desktop access fix from Wine 8.0 (WineHQ
53981) landed upstream; no wine-devel / wine-staging / Proton patch implements the
rest. So the CEF broker's sandbox handshake with its child processes deadlocks,
Steam's outer watchdog trips `Stalled cross-thread pipe` (`src/common/pipes.cpp`),
and the host exits. `--no-sandbox` is the universal Wine/Proton workaround
(Valve's own Linux Steam passes `-no-cef-sandbox`); there is no realistic root
fix, so the flag is permanent.

**GPU rendering and the GLES3 requirement (DXMT on the D3D11 path).** CEF's GPU
process needs a shared **GLES3** context for its `SharedImageStub` (GPU
virtualization); without it CEF hits `kFatalFailure` and retries forever — the
**webhelper death-loop** (~160% CPU, multi-GB `cef_log`, no login window). On
Wine+macOS that GLES3 context only exists when ANGLE's D3D11 backend is served by
**DXMT** (the Metal `d3d11.dll` builtin, feature level **11_1** → GLES3). With
DXMT active the webhelper renders correctly and roughly **halves the webhelper
CPU** vs software raster (software-raster ~44% → ~24% on the main renderer). So
patch `0020` appends only `--no-sandbox`; there is no
`--disable-gpu`/SwiftShader path — it was the old approach and was briefly retried
this investigation, but SwANGLE fails at `eglInitialize` (winevulkan rejects
`VK_KHR_surface` on the host instance) and crashes inside ANGLE's closed
`libGLESv2`. The real GLES3 fix is DXMT on the D3D11 path. (An experimental
**ANGLE-Vulkan** path also reaches GLES 3.0 but has an open flicker bug — see the
ANGLE-Vulkan subsection below.)

**Why DXMT is required (the wined3d failure mode).** The Wine builtin `d3d11.dll`
is **wined3d** (D3D11-on-macOS-GL), not DXMT. wined3d gets a core GL 4.1 context
but caps at **FL_9_3 / SM3** because Apple's frozen GL 4.1 lacks
`GL_EXT_shader_integer_mix` (and `GL_ARB_polygon_offset_clamp`), which
`shader_glsl_get_shader_model` requires for SM4. Forcing SM4/FL_10 anyway (patch
0016, reverted in `d0994f4b`) makes ANGLE's D3D11 init **hang** — the gate exists
because Apple GL can't compile SM4's integer `mix()`. Under wined3d ANGLE's
Renderer11 therefore caps at **GLES 2.0** (`eglCreateContext: Requested GLES 3.0 >
max supported 2.0`) → `SharedImageStub` "Failed to create shared context for
virtualization" → death-loop. **ES3 can only come from DXMT (or Vulkan), not
wined3d-GL.**

**Death-loop root cause — `make proton` clobbering DXMT (fixed, commit e20c85ca).**
Wine's `make install` rewrites the builtin `d3d11.dll` (wined3d) **over** the DXMT
copy that `make dxmt` had installed, silently dropping the webhelper (and D3D11
games) back to FL_9_3 → GLES2 → death-loop. The patch-0017 load order is correct
(it routes `d3d11` to the builtin); the bug was the builtin being wined3d. Fix:
`scripts/build-proton-x86.sh` now restores DXMT (d3d11/d3d10core/dxgi/winemetal)
over wined3d after `make install`, mirroring the KosmicKrisp loader swap — so
`make proton` is order-independent (no need to re-run `make dxmt` after every
rebuild). Skipped when DXMT artifacts are absent (wined3d stays; run `make dxmt`).

**Experimental ANGLE-Vulkan ES3 (shelved).** `--use-angle=vulkan --use-cmd-decoder=passthrough`
routes ANGLE → `vulkan-1.dll` (winevulkan) → KosmicKrisp → Metal, giving real **GLES 3.0**
and bypassing Apple's GL. But the Steam UI **flickers**, root-caused to KosmicKrisp's
Metal-4 WSI: ruled out present-mode (force-FIFO no effect), `framebufferOnly=NO`
(→ freeze), and `--disable-partial-swap`; the present path itself is structurally
correct Metal-4 (which is why single-swapchain DXVK games render fine). Likely cause:
CEF's ~10 swapchains interleaving on KosmicKrisp's single Metal-4 queue — a WSI-maturity
issue, not a Wine/flag fix. The flags are **not** in the tree and **not** shipped;
the Steam UI stays on stable DXMT-ES3 (renders fine, no flicker). Do NOT set a
bottle-global `d3d11=native` override for the UI.

**Bundled `cef.win64/vulkan-1.dll` shadows winevulkan — fixed with `vulkan-1=b`
(2026-07-26).** In a freshly created bottle CEF would spin in a tight GL-init retry
loop: `cef_log` floods ~40k lines/s, a core pinned at ~160%, and no login window ever
paints. Root cause: Steam's CEF host ships **its own `vulkan-1.dll`** in
`bin/cef/cef.win64` (and `cef.win7x64`). Loaded from the app directory it wins over
Wine's builtin, and it is a **Windows** Vulkan loader — under Wine it finds no ICD, so
it exposes **no** `VK_KHR_surface` / `VK_KHR_win32_surface`. ANGLE's Vulkan backend
**and** the SwiftShader fallback then both abort (`Extension VK_KHR_surface is not
supported`), Chromium's `gl_factory_win` NOTREACHEs, and CEF retries GL-init forever.
(ANGLE-GL is not an escape hatch either: it needs `WGL_NV_DX_interop2`, which macOS GL
lacks.) The earlier "`make proton` regression broke Wine's WSI" theory was **refuted** —
a standalone probe confirmed **builtin winevulkan** exposes `VK_KHR_surface` +
`VK_KHR_win32_surface` (14 instance extensions) and reaches KosmicKrisp fine; the WSI
was always healthy, the wrong loader was just shadowing it. Fix: default **`vulkan-1`**
to builtin so Wine substitutes builtin winevulkan even for that app-directory load. This
now lives in **proton-wine patch `0017`** (the macOS builtin-DLL load-order default),
which matches `vulkan-1` (plus d3d9/d3d8/d3d11/d3d10core/dxgi/winemetal) **by basename** —
so it catches CEF's `bin/cef/cef.win64/vulkan-1.dll` full-path load, which no env-level
`WINEDLLOVERRIDES` could. (The earlier Swift wiring — a `BottleSettings.swift`
`WINEDLLOVERRIDES=vulkan-1=b` env plus a `Steam.configure` registry override — has been
removed; the load-order default replaces both.) The on-disk `vulkan-1.dll` stays
byte-identical, so Steam's `BVerifyInstalledFiles` (see below) still passes. Verified:
with the override a real launch cleared **all** `VK_KHR_surface`/`gl_factory_win` errors,
CPU dropped from ~160% to ~0.5%, and the log flood stopped. (The login window then still
needs network connectivity — a separate proxy/network matter, see §2.)

Diagnostics: `WINEDEBUG=+d3d` (feature level / GL version); `DXMT_LOG_PATH` is honored
in the webhelper (d3d11 is DXMT). Always launch Steam with the **full bottle env**
(the app builds it in `Wine.runProgram`) — a minimal env missing `winemetal=b` /
`DYLD_FALLBACK_LIBRARY_PATH` makes steam.exe spin at ~100% with no window.

### Solution: append the flags in Proton (patch 0020)

`steamwebhelper.exe` is left byte-identical to Valve's. The two flags are appended
inside Wine itself: `hack_append_command_line()` (in `dlls/kernelbase/process.c`)
gains a `steamwebhelper.exe` entry — `patches/proton-wine/0020` — so every
`steamwebhelper.exe` launch (the browser host **and** its renderer/gpu/utility
children) picks up `--no-sandbox`. CEF propagates flags to its own
child processes anyway; the substring match just makes sure each child also matches.

`--in-process-gpu` used to be appended here too: the out-of-process GPU could not
create an ANGLE/D3D11 window surface on the browser window (`eglCreateWindowSurface`
failed, `SwapChain11.cpp`) and the UI never painted. That was a *symptom* of patch
`0009` — winemac's DXMT shim built a Metal view only for toplevel windows, so any
child HWND, which is what a browser composites into, got NULL and DXMT `abort()`ed.
`0009` now creates a client surface for child HWNDs as well, so the flag is gone.
**UNVERIFIED**: not retested against a live Steam session. If the webhelper UI stops
painting, putting `--in-process-gpu` back is the first thing to try.

This replaces a heavier mechanism. Whisky formerly attached a small
`steamwebhelper_wrapper.exe` launcher through the image's IFEO `Debugger` value
(IFEO-`Debugger` support carried by a now-removed kernelbase patch); the wrapper
re-launched a `steamwebhelper_real.exe` copy with the flags. Two flags weren't worth
the wrapper binary, the `_real` copy, the per-bottle registry value, the Swift
plumbing, and the Wine patch that made it all work, so the in-Wine table entry wins
on every axis:

- **No verification storm.** Steam's startup `BVerifyInstalledFiles` checksums each
  executable against the manifest; the very first version of the fix *overwrote*
  `steamwebhelper.exe` with the wrapper, so every launch Steam saw "corruption" and
  re-downloaded the client (slow, and a hang behind a blocked CDN — see §2):

  ```
  BVerifyInstalledFiles: bin\cef\cef.win64\steamwebhelper.exe is 147972 bytes, expected 7723160
  Downloading update...
  ```

  Leaving the binary untouched — which both the IFEO approach and the patch approach
  do — is what avoids that.
- **Nothing per-bottle.** The flags ship in the Wine build; `steamwebhelper.exe` is
  never overwritten and no registry value or shim is installed, so there is nothing
  to migrate or clean up. (Old bottles may still carry a stale IFEO `Debugger` value
  and orphan `steamwebhelper_wrapper.exe` / `_real` copies from the retired wrapper;
  they are inert — Wine no longer honors IFEO-`Debugger`, and Steam ignores the
  orphan files.)

The kernelbase IFEO-`Debugger` support (former patch `0010`) is removed too: with no
wrapper registering a `Debugger` value, the feature had no consumer.

## 2. "Steam is updating" stuck

Symptom: Steam hangs on the update progress bar. From
`Steam/logs/bootstrap_log.txt`:

```
Download failed: http error 0 (media.st.dl.eccdnx.com/client/steam_client_win64)
... (next host hangs for minutes) ...
```

Cause: Steam's bootstrapper connects **directly** to its CDN. Wine processes are
launched with an explicit `Process.environment` that does **not** inherit the
host's proxy, so a system proxy / VPN-proxy is bypassed and the direct
connections stall (e.g. on a filtering network). The §1 overwrite bug made it worse by
forcing an update download every launch.

### Solution: Follow System Proxy

Enable the bottle's **Config → Wine → "Follow System Proxy"** toggle
(`BottleSettings.followSystemProxy`). `SystemProxy.swift` reads the macOS system
proxy via `CFNetworkCopyProxiesForURL` (executing the PAC script if configured,
and rewriting an advertised `0.0.0.0` to `127.0.0.1`) and injects
`http_proxy`/`https_proxy`/`no_proxy` into the Wine environment.

This only covers proxy-mode setups. VPN / "TUN" tunnels route traffic
transparently at the IP layer and need no proxy variables — leave the toggle off.
