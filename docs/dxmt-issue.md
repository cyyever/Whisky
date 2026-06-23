# DXMT Issue: ANGLE SwapChain11 fails with EGL_BAD_ALLOC

## Environment
- DXMT v0.74 (builtin)
- Wine 11.5 (upstream, x86_64 via Rosetta 2)
- macOS 26.4 (Tahoe), Apple M2
- Steam client (steamwebhelper using Chromium CEF with ANGLE D3D11 backend)

## Problem

Steam's CEF (Chromium Embedded Framework) uses ANGLE to translate OpenGL ES to D3D11. When DXMT provides the D3D11 implementation, ANGLE's `SwapChain11::reset()` fails to create swap chains:

```
SwapChain11.cpp:636 (virtual rx::SwapChain11::reset): Could not create additional swap chains or offscreen surfaces, HRESULT: 0x80004005
EGL Driver message (Critical) eglCreateWindowSurface: Bad allocation.
eglCreateWindowSurface failed with error EGL_BAD_ALLOC
```

The GPU process crashes repeatedly (6+ times) and Steam falls back to `--disable-gpu --in-process-gpu`, resulting in a black window.

## Steps to reproduce

1. Build Wine 11.5 from source on macOS (x86_64 via Rosetta)
2. Install DXMT v0.74 builtin DLLs
3. Create a Wine prefix and install Steam
4. Launch Steam — observe black window
5. Check `Steam/logs/cef_log.txt` for the SwapChain11 errors

## Analysis

ANGLE creates swap chains via `IDXGIFactory2::CreateSwapChainForHwnd` (DXGI 1.2). The `HRESULT: 0x80004005` (E_FAIL) suggests DXMT's DXGI swap chain creation doesn't support the specific parameters ANGLE uses.

This is related to issue #79 (ANGLE D3D11 Backend dEQP tests).

## Expected behavior

ANGLE's swap chain creation should succeed, allowing Steam's CEF to render its UI.

## Workaround

None currently. Using `--cef-disable-gpu` produces a black window. Wine's built-in wined3d also fails the same way.
