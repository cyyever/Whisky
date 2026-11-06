#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/mullion.sh"
whisky_ccache_guard

export PATH="/opt/homebrew/bin:/usr/bin:/bin"
require_tools git meson ninja lipo x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ \
    x86_64-w64-mingw32-ar x86_64-w64-mingw32-windres

if [ ! -f "$MULLION_SRC/meson.build" ]; then
    git -C "$PROJECT_DIR" submodule update --init vendor/mullion
fi
[ -f "$MULLION_SRC/meson.build" ] || {
    echo "ERROR: Mullion source missing; initialize submodules with 'make submodule'." >&2
    exit 1
}
[ "$(git -C "$MULLION_SRC" rev-parse HEAD)" = "$MULLION_REVISION" ] || {
    echo "ERROR: vendor/mullion must be pinned at $MULLION_REVISION; update the gitlink and pin together." >&2
    exit 1
}

# The required nested dependency is Microsoft's DirectX headers. NVIDIA
# extensions stay disabled; the shipped Steam and RE2 paths do not use them.
git -C "$MULLION_SRC" submodule update --init include/native/directx

# Mullion's AIR converter needs LLVM 15 static libraries built for x86_64,
# matching Whisky's x86_64 Wine process under Rosetta. WHISKY_MULLION_LLVM can
# point to another compatible installation.
MULLION_LLVM="${WHISKY_MULLION_LLVM:-/usr/local/opt/llvm@15}"
LLVM_CONFIG="$MULLION_LLVM/bin/llvm-config"
[ -x "$LLVM_CONFIG" ] || {
    echo "ERROR: LLVM 15 not found at $MULLION_LLVM. Install x86_64 LLVM 15 or set WHISKY_MULLION_LLVM." >&2
    exit 1
}
LLVM_VERSION=$("$LLVM_CONFIG" --version)
case "$LLVM_VERSION" in 15.*) ;; *)
    echo "ERROR: Mullion requires LLVM 15 static libraries; $LLVM_CONFIG reports $LLVM_VERSION." >&2
    exit 1 ;;
esac
[ -f "$MULLION_LLVM/lib/libLLVMCore.a" ] || {
    echo "ERROR: LLVM static libraries are missing from $MULLION_LLVM/lib." >&2
    exit 1
}
LLVM_ARCHS=$(lipo -archs "$MULLION_LLVM/lib/libLLVMCore.a")
case " $LLVM_ARCHS " in *" x86_64 "*) ;; *)
    echo "ERROR: Mullion needs x86_64 LLVM libraries; libLLVMCore.a has: $LLVM_ARCHS." >&2
    exit 1 ;;
esac

echo "=== Building Mullion from $MULLION_SRC ($MULLION_REVISION) ==="
BUILD_PATH="$MULLION_SRC/$MULLION_BUILD_DIR"
MESON_ARGS=(
    --cross-file build-win64.txt
    --buildtype release
    --prefix /usr
    -Dnative_llvm_path="$MULLION_LLVM"
    -Dwine_install_path="$INSTALL_DIR/Wine"
    -Dwine_builtin_dll=true
    -Denable_tests=false
    -Denable_nvapi=false
    -Denable_nvngx=false
)

if [ -f "$BUILD_PATH/build.ninja" ]; then
    (cd "$MULLION_SRC" && meson setup --reconfigure "${MESON_ARGS[@]}" "$MULLION_BUILD_DIR")
else
    (cd "$MULLION_SRC" && meson setup "${MESON_ARGS[@]}" "$MULLION_BUILD_DIR")
fi

NINJA_JOBS=()
if [ -n "${WHISKY_BUILD_JOBS:-}" ]; then
    NINJA_JOBS=(-j "$(whisky_ncpu)")
fi
ninja -C "$BUILD_PATH" "${NINJA_JOBS[@]}"

rm -rf "$PROJECT_DIR/vendor/.mullion-stage"
meson install -C "$BUILD_PATH" --destdir "$PROJECT_DIR/vendor/.mullion-stage" --strip
install_mullion_builtins "$INSTALL_DIR/Wine"
echo "=== Mullion installed as Whisky's default D3D10/11/12 backend ==="
