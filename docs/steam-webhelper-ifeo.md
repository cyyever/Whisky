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

The GLES-2 cap is **not** a DXMT issue: investigated 2026-07-24 — the webhelper's
ANGLE Renderer11 does **not** use DXMT (DXMT never loads in that process, even with
`WINEDLLOVERRIDES=d3d11,dxgi,d3d10core,winemetal=b` forced — the `DXMT_LOG_PATH`
log stays empty; and the `CheckInterfaceSupport: Error querying driver version`
message DXMT would never emit, since it S_OKs `ID3D10Device`). So ANGLE's D3D11 is
served by **wined3d** (D3D11-on-macOS-GL), which caps ES at 2.0. Root cause traced
in wined3d (confirmed via `WINEDEBUG=+d3d`): the webhelper's wined3d **does** get a
**core GL 4.1 context, GLSL 4.10** ("Got a core profile context", GL_RENDERER "Apple
M2", GL_VERSION "4.1 Metal") — the earlier "legacy 2.1" guess was wrong. But it still
reports `GPU maximum feature level 0x9300` (**FL_9_3 / SM3**) because
`shader_glsl_get_shader_model` (dlls/wined3d/glsl_shader.c ~11295) requires, for SM4
(→ FL_10_0 → ES 3.0): `glsl_version >= 1.50` (ok) **AND** `ARB_SHADER_BIT_ENCODING`
(ok) **AND** `ARB_TEXTURE_SWIZZLE` (ok) **AND** `EXT_SHADER_INTEGER_MIX` — and
Apple's GL 4.1 does **not** expose `GL_EXT_shader_integer_mix` (a GL-4.x-era ext), so
wined3d falls to SM3. It also lacks `GL_ARB_polygon_offset_clamp`.

**Forcing wined3d to SM4/FL_10 on Apple GL is a DEAD END (A/B tested, reverted).**
Commit `53b99179` added `patches/proton-wine/0016-wined3d-sm4-fl10-apple-gl.patch`:
drop the `EXT_SHADER_INTEGER_MIX` gate in `shader_glsl_get_shader_model` (+ emulate
integer `mix()`) and drop the `ARB_POLYGON_OFFSET_CLAMP` gate in
`feature_level_from_caps`, so wined3d advertises SM4/FL_10_1. It was **REVERTED in
`d0994f4b`**: with wined3d advertising FL_10, ANGLE's Renderer11 D3D11-device init
**HANGS** (no window, zero ANGLE log lines). Unpatched wined3d → ANGLE gets SM3/FL_9_3,
logs the `GLES 3.0 > 2.0` downgrade, falls back to ES2 and **renders correctly and
stably**. The `EXT_shader_integer_mix` gate exists for a real reason — Apple GL 4.1
(frozen since 10.14) can't compile SM4 float→int saturation shaders' integer `mix()`.
**Conclusion: the wined3d-GL path cannot reach ES3 on Apple.** ES3 must come from
Vulkan (ANGLE-Vulkan below) or DXMT — not from relaxing the GL feature-level gate.

Diagnostic env if revisited: `WINEDEBUG=+d3d` (feature level / GL version), and
`DXMT_LOG_PATH`/`DXMT_LOG_LEVEL` (DXMT never loads in the webhelper's D3D11 path — it's
wined3d, even with `winemetal=b` forced).

Verified on the **Proton** stack; spot-check Whisky-Wine 11.13 bottles (shared
wrapper) — if a bottle black-windows, restore `--disable-gpu --disable-gpu-compositing`.

### ANGLE-Vulkan: the ES3 route (CONFIRMED working, flicker bug OPEN)

Appending **`--use-angle=vulkan --use-cmd-decoder=passthrough`** to the wrapper flags
routes CEF's ANGLE onto its **Vulkan backend** instead of D3D11:
ANGLE (`libEGL`/`libGLESv2`) → `vulkan-1.dll` (winevulkan) → `libvulkan.1.dylib`
(Khronos loader) → `libvulkan_kosmickrisp.dylib` (KosmicKrisp ICD) → Metal. Confirmed
via `lsof` on the in-process-GPU webhelper (7 vulkan/kosmickrisp/winevulkan libs
mapped). This gives **GLES 3.0** — the `eglCreateContext: Requested GLES 3.0 > max
supported 2.0` error DISAPPEARS (that error is emitted only by ANGLE's D3D11/Renderer11
path). It bypasses wined3d, DXMT, **and** Apple's frozen GL entirely — the cleanest ES3
route for the CEF UI.

**OPEN BUG — the Steam UI FLICKERS constantly under ANGLE-Vulkan → KosmicKrisp.** Not
shippable as-is; investigation in progress. Ruled out so far: not a Chromium flag
(`--disable-partial-swap` did NOT fix it); not "content-not-preserved" (the KosmicKrisp
Metal WSI, `vendor/mesa/src/vulkan/wsi/wsi_common_metal.c`, blits the full persistent
app-image → drawable each present). Current lead: present-mode/vsync — KosmicKrisp
offers only **IMMEDIATE + FIFO** present modes (no MAILBOX; `minImageCount=2`/`max=3`),
and if ANGLE picks IMMEDIATE, `wsi_metal_layer_set_immediate` disables displaySync →
tearing/flicker. A **force-FIFO experiment is in progress**. Note: DXVK fullscreen games
via KosmicKrisp do NOT flicker (full-frame present) — only the CEF compositor does.

**Status: EXPERIMENTAL / UNCOMMITTED.** The `--use-angle=vulkan --use-cmd-decoder=passthrough
--disable-partial-swap` flags are currently in the working tree of
`SteamHelper/webhelper_wrapper.c` but not committed and **not the shipped default**,
pending the flicker fix. Until then the shipped path stays wined3d-ES2 (stable). Do NOT
set a bottle-global `d3d11=native`/DXMT override just for the UI — DXMT is for games.

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
