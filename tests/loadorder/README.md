# loadorder — D3D/Vulkan builtin default

Regression test for `patches/proton-wine/0017-macos-metal-builtin-dll-loadorder.patch`.

That patch extends Wine's `get_load_order()` so `d3d9`, `d3d8`, `d3d11`,
`d3d10core`, `dxgi`, `vulkan-1` (+ `winemetal` on macOS) default to **builtin** —
DXVK / DXMT / winevulkan — with no per-bottle `WINEDLLOVERRIDES`. It matches on the
basename, so it also catches app-directory loads (notably Steam CEF's own bundled
`vulkan-1.dll`) that an env override cannot.

Because the app sets **no** override anymore, this is the only thing keeping Steam's
CEF renderable and D3D9 games working. If a `make proton` / base bump drops or
supersedes the patch, this test fails loudly.

## Run

```bash
tests/loadorder/run.sh
```

Needs `make proton` (installed Wine) and `mingw-w64`. It cross-compiles
`loadorder_probe.exe` and, in its own throwaway prefix with **no**
`WINEDLLOVERRIDES`, `LoadLibrary`s each module — **one DLL per wine invocation**,
under `WINEDEBUG=+module` (the channel `loadorder.c` logs on) — and asserts
`get_load_order()` chose builtin for every one. Per-module traces land in
`.build/loadorder-<dll>.trace`.

One process per DLL keeps each module in a fresh address space, so a large builtin
that fails to *map* (or crashes in init) can't suppress another module's trace —
which is what happened when all seven ~90 MB DXVK+DXMT builtins shared one process.

`get_load_order()` only runs once the loader has *found* a file for the name.
`d3d11`/`d3d10core`/`dxgi`/`vulkan-1`/`winemetal` are genuine Wine/DXMT builtins
whose DOS stub carries the `Wine builtin DLL` signature, so wineboot mirrors them
into the prefix's `system32` as fake DLLs and the loader finds them. DXVK's
`d3d9`/`d3d8` are third-party PEs *without* that signature — wineboot makes no fake
DLL, so `LoadLibraryA("d3d9.dll")` would fail with `STATUS_DLL_NOT_FOUND` *before*
`get_load_order()` even runs. So the harness drops a tiny placeholder `<dll>` next
to the probe exe before each probe: the loader finds it and reaches
`get_load_order()`, which must still force **builtin** (the real module is pulled
from Wine's lib dir; the placeholder is never loaded). That mirrors the app
auto-dropping DXVK's `d3d9.dll` next to a game exe, and is a stronger check — an
app-directory native copy present, yet builtin still wins (as it must for Steam
CEF's own bundled `vulkan-1.dll`).
