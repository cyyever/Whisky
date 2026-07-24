# Steam webhelper: IFEO launcher + update-stuck proxy fix

Two Steam-under-Wine problems and how Whisky solves them.

## 1. Black window (CEF GPU sandbox)

Steam's CEF host `steamwebhelper.exe` renders a black window under Wine: its
sandbox hooks the NT kernel and the out-of-process GPU can't reset the D3D
device (`problems[10]: Some drivers are unable to reset the D3D device in the GPU
process sandbox`). It needs `--no-sandbox --in-process-gpu`.

**GPU rendering re-enabled (2026-07-24, KosmicKrisp + DXMT stack).** The wrapper
used to also force `--disable-gpu --disable-gpu-compositing` (software raster).
That is no longer needed: on the current stack CEF's GPU process comes up via
ANGLE → D3D11 (**wined3d**, not DXMT — see the ANGLE/wined3d analysis below) → GL →
Metal without black-windowing, renders the UI correctly, and roughly **halves the
webhelper CPU** (software-raster ~44% → ~24% on the main renderer). So the shipped
wrapper appends only `--no-sandbox --in-process-gpu`
(`SteamHelper/webhelper_wrapper.c`). Caveat: ANGLE's Renderer11 caps the context
at **GLES 2.0** (`eglCreateContext: Requested GLES 3.0 > max supported 2.0`), so CEF
falls back to SwiftShader for the GLES-3 raster path; rendering is still correct. An
experimental **ANGLE-Vulkan** path reaches GLES 3.0 (bypassing wined3d) but has an open
flicker bug — see the ANGLE-Vulkan subsection below.

**Why ES2, and why ES3 on this path is a dead end.** ANGLE's Renderer11 is served by
**wined3d** (D3D11-on-macOS-GL), not DXMT (DXMT never loads in the webhelper). wined3d
gets a core GL 4.1 context but caps at **FL_9_3 / SM3** because Apple's frozen GL 4.1
lacks `GL_EXT_shader_integer_mix` (and `GL_ARB_polygon_offset_clamp`), which
`shader_glsl_get_shader_model` requires for SM4. Forcing SM4/FL_10 anyway (patch 0016,
reverted in `d0994f4b`) makes ANGLE's D3D11 init **hang** — the gate exists because
Apple GL can't compile SM4's integer `mix()`. **ES3 can only come from Vulkan or DXMT,
not wined3d-GL.**

**Experimental ANGLE-Vulkan ES3 (shelved).** `--use-angle=vulkan --use-cmd-decoder=passthrough`
routes ANGLE → `vulkan-1.dll` (winevulkan) → KosmicKrisp → Metal, giving real **GLES 3.0**
and bypassing Apple's GL. But the Steam UI **flickers**, root-caused to KosmicKrisp's
Metal-4 WSI: ruled out present-mode (force-FIFO no effect), `framebufferOnly=NO`
(→ freeze), and `--disable-partial-swap`; the present path itself is structurally
correct Metal-4 (which is why single-swapchain DXVK games render fine). Likely cause:
CEF's ~10 swapchains interleaving on KosmicKrisp's single Metal-4 queue — a WSI-maturity
issue, not a Wine/wrapper fix. The flags are **not** in the tree and **not** shipped;
the Steam UI stays on stable DXMT/wined3d-ES2 (renders fine, no flicker; ES3 isn't
needed for a 2D UI). Do NOT set a bottle-global `d3d11=native` override for the UI.

Diagnostics: `WINEDEBUG=+d3d` (feature level / GL version); `DXMT_LOG_PATH` stays empty
in the webhelper (it's wined3d). Always launch Steam with the **full bottle env**
(`WhiskyCmd shellenv <bottle>`) — a minimal env missing `winemetal=b` /
`DYLD_FALLBACK_LIBRARY_PATH` makes steam.exe spin at ~100% with no window. Spot-check
Whisky-Wine 11.13 bottles (shared wrapper) — if one black-windows, restore
`--disable-gpu --disable-gpu-compositing`.

### Why not just overwrite steamwebhelper.exe

The original fix replaced `steamwebhelper.exe` with the wrapper. But Steam's
startup `BVerifyInstalledFiles` checks each executable's size/checksum against
the manifest:

```
BVerifyInstalledFiles: bin\cef\cef.win64\steamwebhelper.exe is 147972 bytes, expected 7723160
Downloading update...
```

So every launch Steam treated the wrapper as corruption and re-downloaded the
client — slow at best, and a hang behind a blocked CDN (see §2). The on-disk
binary must stay byte-identical to Valve's.

### Solution: attach via IFEO `Debugger`

`steamwebhelper.exe` is left untouched. The wrapper is attached through the
image's **Image File Execution Options `Debugger`** value, so Wine launches:

```
steamwebhelper_wrapper.exe  <full path>\steamwebhelper.exe  <original args...>
```

The wrapper appends the flags and launches `steamwebhelper_real.exe` (a copy of
the genuine binary under a different name, so the IFEO redirect doesn't recurse).
CEF propagates the flags to its own child processes.

Stock Wine ignores the IFEO `Debugger` value at `CreateProcess`; support is added
by `patches/wine/0001-kernelbase-ifeo-debugger.patch` (in
`CreateProcessInternalW`: if the image has an IFEO `Debugger`, prepend it to the
command line and run that instead). Patches live as files and are applied by
`scripts/build-wine-x86.sh` so the `vendor/wine` submodule stays clean.

Driven by `Steam.swift` (via `Wine.configureSteam`, called from
`Wine.runProgram`): installs the wrapper at `C:\windows\steamwebhelper_wrapper.exe`,
restores a genuine `steamwebhelper.exe` (migrates old bottles), refreshes the
`steamwebhelper_real.exe` copy, and writes the IFEO registry value. CLI:
`whisky steam-fix <bottle>`.

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
connections stall (e.g. behind the GFW). The §1 overwrite bug made it worse by
forcing an update download every launch.

### Solution: Follow System Proxy

Enable the bottle's **Config → Wine → "Follow System Proxy"** toggle
(`BottleSettings.followSystemProxy`). `SystemProxy.swift` reads the macOS system
proxy via `CFNetworkCopyProxiesForURL` (executing the PAC script if configured,
and rewriting an advertised `0.0.0.0` to `127.0.0.1`) and injects
`http_proxy`/`https_proxy`/`no_proxy` into the Wine environment.

This only covers proxy-mode setups. VPN / "TUN" tunnels route traffic
transparently at the IP layer and need no proxy variables — leave the toggle off.
