# Steam webhelper: IFEO launcher + update-stuck proxy fix

Two Steam-under-Wine problems and how Whisky solves them.

## 1. Black window (CEF GPU sandbox)

Steam's CEF host `steamwebhelper.exe` renders a black window under Wine: its
sandbox hooks the NT kernel and the out-of-process GPU can't reset the D3D
device (`problems[10]: Some drivers are unable to reset the D3D device in the GPU
process sandbox`). It needs `--no-sandbox --in-process-gpu --disable-gpu
--disable-gpu-compositing`; Steam's own `--disable-gpu` fallback is not enough.

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
