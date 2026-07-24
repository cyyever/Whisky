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
ANGLE → D3D11 (DXMT) → Metal without black-windowing, renders the UI correctly,
and roughly **halves the webhelper CPU** (software-raster ~44% → ~24% on the main
renderer). So the wrapper now appends only `--no-sandbox --in-process-gpu`
(`SteamHelper/webhelper_wrapper.c`). Caveat: ANGLE's Renderer11 caps the context
at **GLES 2.0** — DXMT reports D3D feature level 11_1, but ANGLE downgrades ES
(`eglCreateContext: Requested GLES 3.0 > max supported 2.0`), so CEF falls back to
SwiftShader for the GLES-3 raster path; rendering is still correct.

The GLES-2 cap is **not** a DXMT issue: investigated 2026-07-24 — the webhelper's
ANGLE Renderer11 does **not** use DXMT (DXMT never loads in that process, even with
`WINEDLLOVERRIDES=d3d11,dxgi,d3d10core,winemetal=b` forced — the `DXMT_LOG_PATH`
log stays empty; and the `CheckInterfaceSupport: Error querying driver version`
message DXMT would never emit, since it S_OKs `ID3D10Device`). So ANGLE's D3D11 is
served by **wined3d** (D3D11-on-macOS-GL), which caps ES at 2.0. Root cause traced
in wined3d: `feature_level_from_caps` (dlls/wined3d/adapter_gl.c) maps shader model
→ feature level (SM4 → FL_10_0 → ES 3.0; SM3 → FL_9_3 → ES 2.0), and the webhelper's
wined3d reports **FL_9_3 / SM3** — i.e. its GL context fell back to legacy (GL 2.1 /
GLSL 1.20), not the core GL 3.2+ winemac requests (`kCGLOGLPVersion_3_2_Core`,
dlls/winemac.drv/opengl.c). So ES 3.x would need the webhelper's wined3d to actually
get a core GL context on macOS (a winemac/wined3d GL-context fix; bumping winemac's
core request 3.2→4.1 alone wouldn't help while it falls back to legacy). Dropped as
not worth forcing — the ES-2 GPU path above already renders correctly and roughly
halves the CPU. Diagnostic env if revisited: `DXMT_LOG_PATH`/`DXMT_LOG_LEVEL` (DXMT
never loads in the webhelper — confirms wined3d, not DXMT), and wined3d `+d3d` trace
for the reported feature level.

Verified on the **Proton** stack; spot-check Whisky-Wine 11.13 bottles (shared
wrapper) — if a bottle black-windows, restore `--disable-gpu --disable-gpu-compositing`.

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
