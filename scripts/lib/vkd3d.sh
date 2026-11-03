#!/bin/bash
# Shared source pin and DLL installation contract for vkd3d-proton.
VKD3D_REVISION=15dd1ee7864ef83c4ef835c72720effe60a10899
VKD3D_SOURCE_URL=https://github.com/HansKristian-Work/vkd3d-proton.git
VKD3D_DLLS=(d3d12 d3d12core)

# Reject partial builds before Wine replaces an existing installation.
check_vkd3d_pair() {
    local libs="$1" dll count=0
    for dll in "${VKD3D_DLLS[@]}"; do
        if [ -f "$libs/$dll/$dll.dll" ]; then count=$((count + 1)); fi
    done
    if [ "$count" -eq 1 ]; then
        echo "ERROR: incomplete vkd3d-proton build at $libs; run make vkd3d to rebuild both DLLs." >&2
        return 1
    fi
}

install_vkd3d_builtins() {
    local libs="$1" dest="$2" dll
    check_vkd3d_pair "$libs" || return 1
    for dll in "${VKD3D_DLLS[@]}"; do
        [ -f "$libs/$dll/$dll.dll" ] || {
            echo "ERROR: missing $dll.dll; run make vkd3d." >&2; return 1;
        }
    done
    for dll in "${VKD3D_DLLS[@]}"; do
        cp "$libs/$dll/$dll.dll" "$dest/$dll.dll" || return 1
        mark_wine_builtin "$dest/$dll.dll" || return 1
    done
}
