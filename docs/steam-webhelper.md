# Steam webhelper: CEF flags via Proton + update-stuck proxy fix

Whisky's default Steam D3D11 backend is Mullion → Metal. DXVK → winevulkan →
KosmicKrisp remains the D3D8/9 fallback. Always validate Steam from the Whisky
GUI; a bare CLI launch is not equivalent.

## Startup and Retina validation (2026-11-05)

Steam build 1792618285 reached the login UI through Whisky on M2/macOS 27.2
after repairing stale font registrations. The NT Fonts key named `tahoma.ttf`,
absent from the prefix's Windows Fonts directory, while Wine's external-font
cache retained the correct absolute macOS path. DirectWrite omitted Tahoma;
CEF recursively initialized its default font until exhausting its stack.
Patch 0039 verifies both public registrations before skipping a cached face.
A test recreated stale entries, confirmed the original runtime omitted the
family, and verified that the patched runtime repaired it automatically.

Patch 0036 now identifies Wine threads through their alternate signal stack.
Its previous pthread TLS lookup ran before Unix GS was restored and could
hang on a recoverable hardware exception. `tests/signal-thread-guard-test.c`
passed on initial and worker threads in both 32-bit and 64-bit builds.

Retina mode is paired with DPI from the primary macOS display's backing scale
at launch: 96 at 1x, 192 at 2x. On this 2x display, the Steam login window changed
from 350x220 to 700x440 macOS points with a 1400x880 pixel swapchain.
`tests/system-font-test.cpp` checks the default DirectWrite font and optional
DPI for a DPI-aware process. Unaware processes legitimately see virtualized
96 DPI. Live migration between monitors is not covered by this launch policy.

**Still unresolved:** the user reported flickering after startup. Logs show
repeated FIFO/Immediate swapchain recreation, but this is not a proven cause.
Steam was stopped after the report. These fixes do not resolve or establish
the cause of the presentation issue.

## 0. Child-window presentation

CEF and Qt WebEngine render into child HWNDs. The former private Metal-view shim
has been removed; Wine's Vulkan client surfaces now own positioning and lifetime.
`tests/d3d11-child-swapchain-test.c` covers top-level, child, nested, hidden-parent,
concurrent-child, and destroyed-window cases in both bitnesses.

Feature-level and child-window probes have passed with DXVK, but the full Steam UI
still needs GUI verification for flicker with many interleaved swapchains. Earlier
successful Steam login/UI observations predate this provider change.

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

**GPU rendering and GLES3.** CEF's SharedImageStub needs a shared GLES3
context. Mullion reports D3D11 feature level 11_1 on this host. Wine's wined3d path
falls back to FL_9_3, leaving ANGLE at GLES2 and causing a shared-context retry
loop. `make proton` builds and installs Mullion's d3d11/d3d10core/dxgi builtins.
The DXVK path remains available through an explicit `make dxvk` build.

Patch 0020 appends both `--no-sandbox` and `--in-process-gpu`. Keep these until
GUI testing establishes that the out-of-process surface path works with Mullion.
Removing the old graphics shim alone does not establish that.

**Experimental ANGLE-Vulkan ES3 (shelved).** Earlier experiments observed
Steam UI flicker, but did not establish a root cause. The shipped path is
ANGLE-D3D11 through DXVK. Do not infer a Metal queue bug from those observations.
The ANGLE-Vulkan flags are not shipped.

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
which matches `vulkan-1` (plus d3d9/d3d8/d3d11/d3d10core/dxgi/d3d12/d3d12core) **by basename** —
so it catches CEF's `bin/cef/cef.win64/vulkan-1.dll` full-path load and takes
precedence over stale registry overrides. Explicit `WINEDLLOVERRIDES` still wins. (The earlier Swift wiring — a `BottleSettings.swift`
`WINEDLLOVERRIDES=vulkan-1=b` env plus a `Steam.configure` registry override — has been
removed; the load-order default replaces both.) The on-disk `vulkan-1.dll` stays
byte-identical, so Steam's `BVerifyInstalledFiles` (see below) still passes. Verified:
with the override a real launch cleared **all** `VK_KHR_surface`/`gl_factory_win` errors,
CPU dropped from ~160% to ~0.5%, and the log flood stopped. (The login window then still
needs network connectivity — a separate proxy/network matter, see §2.)

Diagnostics: `WINEDEBUG=+d3d` (feature level / GL version); `DXVK_LOG_LEVEL=info` /
`DXVK_LOG_PATH` for the webhelper's D3D11. Launch Steam from the Whisky GUI,
which supplies the bottle environment including `DYLD_FALLBACK_LIBRARY_PATH`.

### Solution: append the flags in Proton (patch 0020)

`steamwebhelper.exe` is left byte-identical to Valve's. The two flags are appended
inside Wine itself: `hack_append_command_line()` (in `dlls/kernelbase/process.c`)
gains a `steamwebhelper.exe` entry — `patches/proton-wine/0020` — so every
`steamwebhelper.exe` launch (the browser host **and** its renderer/gpu/utility
children) picks up `--no-sandbox --in-process-gpu`. CEF propagates flags to its own
child processes anyway; the substring match just makes sure each child also matches.

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

## Presentation investigation (2026-11-06)

Mesa patch 0005 advertises FIFO/IMMEDIATE compatibility. Both modes use the
same three drawables and the existing Metal callback changes display sync.
An x86_64 driver build succeeded. A 25-second Steam GUI run reported
`dynamic: yes` and switched FIFO → IMMEDIATE → FIFO without recreating the
swapchain. This fixes unnecessary mode-change recreation, not Steam flicker.

The user still observed whole-window flicker with fixed FIFO and again at
96 DPI (CEF device scale factor 1). Neither workaround resolved it. A short
macdrv trace recorded 309 presents, with 308 using one HWND/surface pair;
no alternating surfaces on the same HWND were observed in that capture.
Surface update calls happen before each Vulkan present by design.

A static D3D11 two-child-window test completed 30 seconds without Present
errors. A separate 12-second window recording was decoded into 692 frames;
inspected frames retained blue/orange content, with no obvious black frames
or cross-window corruption. This limited workload did not reproduce Steam's
problem and does not establish correctness for CEF rendering.

Upstream Mesa MR !45568 was built temporarily as an independent WSI queue
experiment. A short Steam login run had no reported device loss or queue
creation failure, but no visual or matched performance improvement has been
established. It is not part of the patch series in this change.

RE2 used D3D12/vkd3d-proton, not DXVK D3D11. During reported stutter, system
GPU utilization sampled 94–95%, while pipeline caches continued updating.
macOS exposed a 1470×956 desktop at 2x (2940×1912 backing pixels), despite a
2560×1664 built-in panel. That matched the game's requested display size;
it was not evidence of an external-monitor detection error. CPU samples had
Rosetta stack-unwinding artifacts and did not establish a CPU bottleneck.

Local diagnostics remain outside Git in `.diagnostics/`, including recordings
and original configuration backups. At the end of these experiments, the
installed GUI was a temporary 96-DPI build, the desktop was changed to
1280×832 at 2x, and RE2's saved raytracing settings were disabled. The
Steam FIFO environment override was removed because games can inherit it.
Restore the normal GUI before treating subsequent runs as production defaults.
