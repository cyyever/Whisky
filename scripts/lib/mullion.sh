#!/bin/bash
# Shared source pin and install contract for the Mullion Metal backend.
MULLION_REVISION=78509d7ea5414b102a6a1e9cfde9fccb6490096c
MULLION_SRC="$PROJECT_DIR/vendor/mullion"
MULLION_BUILD_DIR=build.w64
MULLION_STAGE="$PROJECT_DIR/vendor/.mullion-stage/usr"
MULLION_DLLS=(d3d10core d3d11 d3d12 d3d12core dxgi winemetal)

mullion_stage_ready() {
    local dll
    [ -f "$MULLION_STAGE/x86_64-unix/winemetal.so" ] || return 1
    for dll in "${MULLION_DLLS[@]}"; do
        [ -f "$MULLION_STAGE/x86_64-windows/$dll.dll" ] || return 1
    done
}

# Install staged Mullion DLLs over Wine's builtins. The PE side is generated
# with Wine's winebuild --builtin target; stamp again to keep the same explicit
# install contract as the other cross-compiled DLLs in this repository.
install_mullion_builtins() {  # <wine-root>
    local wine_root="$1" dll src dest
    mullion_stage_ready || {
        echo "ERROR: incomplete Mullion stage at $MULLION_STAGE; run make mullion." >&2
        return 1
    }
    [ -d "$wine_root/lib/wine/x86_64-windows" ] && [ -d "$wine_root/lib/wine/x86_64-unix" ] || {
        echo "ERROR: Wine is not installed at $wine_root." >&2
        return 1
    }
    for dll in "${MULLION_DLLS[@]}"; do
        src="$MULLION_STAGE/x86_64-windows/$dll.dll"
        dest="$wine_root/lib/wine/x86_64-windows/$dll.dll"
        cp "$src" "$dest" || return 1
        mark_wine_builtin "$dest" || return 1
    done
    cp "$MULLION_STAGE/x86_64-unix/winemetal.so" "$wine_root/lib/wine/x86_64-unix/winemetal.so"
    echo "Mullion restored: D3D10/11/12, DXGI and winemetal (x86_64)"
}
