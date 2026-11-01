# D3D12 on KosmicKrisp

The optional path is vkd3d-proton → winevulkan → KosmicKrisp → Metal.
Whisky packages win64 `d3d12.dll` and `d3d12core.dll` as Wine builtins. It does
not enable D3D12 in the default build or claim real-game compatibility.

```sh
make vkd3d           # fetch pinned source + submodules, build and install the pair
make test-d3d12      # build/install as needed, then run the installed-provider tests
# After building, rerun only the tests:
tests/d3d12/run.sh
```

The revision is pinned in `scripts/lib/vkd3d.sh`. An existing source tree at a
different revision is rejected instead of reset. Local adaptations live in
`patches/vkd3d-proton/`. `make vkd3d` builds the complete pair before invoking `make proton`, so it
can recover from an interrupted partial build. `make proton` restores both DLLs
after reinstalling Wine and rejects partial artifacts before replacing the
installation.

The runner checks installed DLL provenance, creates a disposable prefix, and
uses the normal builtin load order, without native overrides or app-local DLL
copies. Each process has a timeout; crashes, nonzero exits, missing success
markers, and wrong GPU results fail the suite. Logs remain in `.build/run.*`.
The prefix is removed after its wineserver stops; user bottles are untouched.

| Probe | Checks |
| --- | --- |
| smoke | Device, command queue, fence completion |
| compute | DXBC compute dispatch, root raw UAV, all 64 output values |
| triangle | Fullscreen draw, all pixels including alpha |
| mrt | Two simultaneous render targets, green and blue pixel readbacks |
| depth | Green draw writes depth; equal-depth red draw must fail LESS |
| stencil | Matching reference draws green; mismatched red draw must fail EQUAL |

Shaders are compiled with Wine's `d3dcompiler_47` to DXBC. This does not test
DXIL/SM6, bindless resources, geometry/tessellation shaders, stream output,
presentation, or real games. The texel-buffer alignment relaxation in the local
patch remains experimental; passing these probes does not validate that path.

Historical smoke/compute/triangle results predate the current checkout. Current
results should be taken from a fresh run, not inferred from those old records.

## Validation on 2026-11-01

The pinned vkd3d-proton build and the Wine rebuild/install completed. All twelve
DXVK/vkd3d-proton DLLs still matched their stamped build artifacts after Wine's
reinstall. The D3D12 probes compiled with `-Wall -Werror`.

Runtime execution was blocked before the first probe: wineserver could not bind
its local IPC socket in the execution sandbox (`Operation not permitted`). No
current GPU pass result is claimed for the six cases. Run `make test-d3d12` and
`tests/loadorder/run.sh` from a normal macOS terminal to complete runtime validation.
