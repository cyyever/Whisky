#!/bin/bash
# Mullion is the default D3D10/11/12 + DXGI provider for Whisky's x86_64 Wine.
MULLION_DIR="$PROJECT_DIR/vendor/mullion"
MULLION_BUILD="$PROJECT_DIR/vendor/mullion-build-x86_64"
MULLION_STAGE="$PROJECT_DIR/vendor/mullion-install-x86_64"

check_mullion_source() {
    if [ ! -f "$MULLION_DIR/meson.build" ]; then
        echo "ERROR: Mullion source is missing at $MULLION_DIR; initialize vendor/mullion." >&2
        return 1
    fi
    check_submodule_pin vendor/mullion Mullion || return 1
    if [ ! -f "$MULLION_DIR/include/native/directx/d3d11.h" ]; then
        echo "ERROR: Mullion's nested submodules are missing; run 'git submodule update --init --recursive vendor/mullion'." >&2
        return 1
    fi
}

mullion_llvm_prefix() {
    local candidate
    if [ -n "${WHISKY_MULLION_LLVM:-}" ]; then
        candidate="$WHISKY_MULLION_LLVM"
    else
        for candidate in "$PROJECT_DIR/vendor/llvm23-x86_64" /usr/local/opt/llvm@23 /usr/local/opt/llvm /opt/homebrew/opt/llvm@23 /opt/homebrew/opt/llvm; do
            [ -x "$candidate/bin/llvm-config" ] && break
        done
    fi
    if [ ! -x "$candidate/bin/llvm-config" ]; then
        echo "ERROR: Mullion needs LLVM 23 for x86_64. Set WHISKY_MULLION_LLVM to its prefix." >&2
        return 1
    fi
    local version target
    version=$("$candidate/bin/llvm-config" --version)
    target=$("$candidate/bin/llvm-config" --host-target)
    if [ "${version%%.*}" != 23 ] || [[ "$target" != x86_64-* ]]; then
        echo "ERROR: Mullion needs x86_64 LLVM 23; $candidate reports $version ($target)." >&2
        echo "       Install the x86_64 LLVM 23 build and set WHISKY_MULLION_LLVM to its prefix." >&2
        return 1
    fi
    printf '%s\n' "$candidate"
}
