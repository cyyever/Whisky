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

`get_load_order()` only runs once the loader has *found* a file for the name. All
seven modules are Wine builtins carrying the `Wine builtin DLL` DOS-stub signature —
`d3d11`/`d3d10core`/`dxgi`/`vulkan-1`/`winemetal` from winebuild/DXMT, and DXVK's
`d3d9`/`d3d8` stamped by `build-dxvk.sh`'s `mark_wine_builtin` — so wineboot mirrors
each into the prefix's `system32` and the loader finds it. (An unsigned DXVK d3d9
would fail `LoadLibraryA` with `STATUS_DLL_NOT_FOUND` *before* `get_load_order()`
runs — that fresh-bottle regression is what the stamping fixes.)

On top of that, the harness drops a tiny placeholder `<dll>` next to the probe exe
before each probe, so the test also proves the stronger property: builtin still wins
when a native copy sits in the application directory — as it must for Steam CEF's own
bundled `vulkan-1.dll`. The placeholder is never loaded; builtin resolution pulls the
real module from Wine's lib dir.
