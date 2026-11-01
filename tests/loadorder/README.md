# Graphics builtin load-order regression test

Run `tests/loadorder/run.sh` after `make proton`, `make dxvk`, and optionally
`make vkd3d`. Patch 0017 resolves d3d8/d3d9/d3d10core/d3d11/dxgi,
d3d12/d3d12core and vulkan-1 to builtins ahead of stale registry overrides.
Explicit environment overrides still win. D3D12 uses Wine's builtins until
vkd3d-proton is installed.

The runner creates a disposable prefix and loads one DLL per process. A native
placeholder next to the executable must not shadow the default builtin. Each
case checks both the loader trace and successful loading. For the D3D12 pair it
also checks stale registry entries and bare/wildcard native environment overrides.
Failures and timeouts return nonzero. Logs remain in `.build/run.*`; the prefix
is removed after its wineserver stops. No game bottle is modified.

`../d3d12/run.sh` additionally checks that the installed pair is byte-identical
to the vkd3d-proton build (except for the builtin signature), then exercises
compute and graphics through those installed DLLs without overrides.
