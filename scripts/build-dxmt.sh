#!/usr/bin/env bash
#
# Build DXMT (Metal-based D3D11/D3D10) from source against our Wine build and
# install it into the Wine library. Gives modern D3D11 games feature level 11.x
# via Metal (wined3d on macOS caps at FL10).
#
# Requires: full Xcode (Metal toolchain), cmake, meson, ninja, mingw-w64. Builds
# its own x86_64 LLVM 15 on first run. Run `make proton` first (needs the Wine
# build dir).
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0 for the meson/clang build
whisky_link_probe   # fail fast if DEVELOPER_DIR cannot link the installed SDK
DXMT_SRC="$PROJECT_DIR/vendor/dxmt"
# WINE_BUILD (Wine build tree for headers) and WINE_LIB (install target) default
# to the Proton build (the shipped backend); override to build DXMT against a
# different Wine: DXMT_WINE_BUILD=/path/to/build DXMT_WINE_LIB=/path/Wine/lib/wine
WINE_BUILD="${DXMT_WINE_BUILD:-$PROJECT_DIR/vendor/proton-wine/build}"
WINE_LIB="${DXMT_WINE_LIB:-$INSTALL_DIR/Wine/lib/wine}"

# --- prerequisites -----------------------------------------------------------
# Run it, not just `xcrun -f`: since Xcode 26 the metal in the toolchain is a stub
# that `xcrun -f` finds happily and that refuses to run until the separately
# downloaded Metal Toolchain component is installed.
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "ERROR: Metal toolchain not found. Install full Xcode 16+ and run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi
require_tools meson ninja x86_64-w64-mingw32-gcc
[ -d "$WINE_BUILD" ] || { echo "ERROR: Wine build dir missing ($WINE_BUILD). Run 'make proton' first." >&2; exit 1; }
[ -d "$WINE_LIB/x86_64-windows" ] || { echo "ERROR: Wine not installed. Run 'make proton' first." >&2; exit 1; }

export PATH="$(brew --prefix)/bin:$PATH"   # native cmake/meson/ninja/mingw

# DXMT pins LLVM 15, exact major (docs/DEVELOPMENT.md upstream; its CI builds
# llvmorg-15.0.7), and links it statically into the x86_64 winemetal.so -- so
# it must be an x86_64 LLVM 15, which no package manager here provides: the ARM
# brew's llvm is arm64 and 23, and the x86 brew's llvm@15 this used to come from
# is gone with the x86 brew. Build it the way DXMT's CI does: the arm64 clang
# cross-compiling with -arch x86_64, no backends, no tools, no zstd -- airconv
# only needs the IR, bitcode and pass libraries. Once, into vendor/llvm15-x86
# (gitignored); later runs find the stamp and skip it.
#
# Not under /opt/homebrew, so src/airconv/darwin/meson.build adds neither
# brew's libzstd nor libunwind -- this script used to have to patch zstd in.
LLVM15="$PROJECT_DIR/vendor/llvm15-x86"
LLVM15_VER=15.0.7
LLVM15_SRC_SHA=4ad8b2cc8003c86d0078d15d987d84e3a739f24aae9033865c027abae93ee7a4
LLVM15_CMAKE_SHA=8986f29b634fdaa9862eedda78513969fe9788301c9f2d938f4c10a3e7a3e7ea
if [ ! -f "$LLVM15/.built" ]; then
    require_tools cmake
    DL_DIR="$PROJECT_DIR/build/downloads"
    WORK="$PROJECT_DIR/build/llvm15"
    mkdir -p "$DL_DIR"
    # llvm-<ver>.src no longer carries LLVM's shared cmake modules; it expects
    # them in ../cmake, which is the separate (7 KB) cmake-<ver>.src tarball.
    for pair in "llvm-$LLVM15_VER.src.tar.xz:$LLVM15_SRC_SHA" "cmake-$LLVM15_VER.src.tar.xz:$LLVM15_CMAKE_SHA"; do
        f="${pair%%:*}" sha="${pair#*:}"
        for t in $(seq 1 10); do
            [ "$(shasum -a 256 "$DL_DIR/$f" 2>/dev/null | cut -d' ' -f1)" = "$sha" ] && break
            echo "=== Downloading $f (try $t) ==="
            curl -sSfL -C - --retry 3 --retry-all-errors -o "$DL_DIR/$f" \
                "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM15_VER/$f" || true
        done
        [ "$(shasum -a 256 "$DL_DIR/$f" | cut -d' ' -f1)" = "$sha" ] ||
            { echo "ERROR: could not download $f (or its sha256 does not match)" >&2; exit 1; }
    done
    rm -rf "$WORK"
    mkdir -p "$WORK/llvm" "$WORK/cmake"
    tar -xf "$DL_DIR/llvm-$LLVM15_VER.src.tar.xz" -C "$WORK/llvm" --strip-components 1
    tar -xf "$DL_DIR/cmake-$LLVM15_VER.src.tar.xz" -C "$WORK/cmake" --strip-components 1

    echo "=== Building x86_64 LLVM $LLVM15_VER into $LLVM15 ==="
    launcher=()
    if whisky_ccache_on; then
        launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    fi
    # The flags are DXMT's CI ones (.github/workflows/ci.yml, "Build LLVM for
    # Darwin (x86_64)"), including _LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23:
    # LLVM 15 relies on headers the current libc++ no longer pulls in
    # transitively. Tests, examples and docs are off only to build less.
    cmake -S "$WORK/llvm" -B "$WORK/build" -G Ninja \
        "${launcher[@]}" \
        -DCMAKE_INSTALL_PREFIX="$LLVM15" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
        -DLLVM_ENABLE_ASSERTIONS=On \
        -DLLVM_ENABLE_ZSTD=Off \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" \
        -DLLVM_TARGETS_TO_BUILD="" \
        -DLLVM_BUILD_TOOLS=Off \
        -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DLLVM_INCLUDE_TESTS=Off \
        -DLLVM_INCLUDE_EXAMPLES=Off \
        -DLLVM_INCLUDE_DOCS=Off \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
    cmake --build "$WORK/build"
    rm -rf "$LLVM15"
    cmake --install "$WORK/build"
    touch "$LLVM15/.built"
fi

# --- submodule ---------------------------------------------------------------
git -C "$PROJECT_DIR" submodule update --init --recursive vendor/dxmt

# --- out-of-tree DXMT patches (tracked in patches/dxmt/) ----------------------
# e.g. 0001 releases owned ColorSync CF objects in winemetal (leak fixes). Idempotent:
# reverse-check-skips already-applied patches. Left applied (submodule stays dirty) —
# same pattern as build-dxvk.sh; the patch files are the source of truth in main.
apply_patches "$DXMT_SRC" "$PROJECT_DIR/patches/dxmt" DXMT

# Older runs of this script injected brew's libzstd here; put it back.
git -C "$DXMT_SRC" checkout -- src/airconv/meson.build 2>/dev/null || true

# meson resolves the source dir from cwd, so build from inside the DXMT tree.
cd "$DXMT_SRC"

# Gate out subdirs we don't ship so they never enter the compile graph. These
# match the current upstream defaults (meson.options), but DXMT has active
# D3D12/vkd3d WIP (~55 recent commits) that could flip enable_d3d12's default —
# pin explicitly so a submodule bump can't silently pull the D3D12 subdir (and
# unused nvapi/nvngx/tests) into the build. Each gates its src/ subdir
# (src/meson.build).
DXMT_GATE_OPTS=(
    -Denable_d3d12=false   # WIP D3D12/vkd3d target — not shipped (DXMT serves D3D11/10/DXGI)
    -Denable_nvapi=false   # NVIDIA NVAPI shim — irrelevant on Metal/Apple GPUs
    -Denable_nvngx=false   # NVIDIA NGX/DLSS shim — irrelevant on Metal/Apple GPUs
    -Denable_tests=false   # unit tests — not needed for the shipped dlls
)

# --- build 64-bit (PE dlls + x86_64 unixlib) ---------------------------------
echo "=== Building DXMT (win64) ==="
rm -rf build
meson setup --cross-file build-win64.txt \
    -Dnative_llvm_path="$LLVM15" \
    -Dwine_build_path="$WINE_BUILD" \
    "${DXMT_GATE_OPTS[@]}" \
    build --buildtype release
meson compile -C build

# --- build 32-bit PE dlls (reuse the 64-bit unixlib) -------------------------
echo "=== Building DXMT (win32) ==="
rm -rf build32
meson setup --cross-file build-win32.txt \
    -Dnative_llvm_path="$LLVM15" \
    -Dwine_build_path="$WINE_BUILD" \
    "${DXMT_GATE_OPTS[@]}" \
    build32 --buildtype release
meson compile -C build32

# --- install into Wine library (builtin) -------------------------------------
echo "=== Installing DXMT into Wine library ==="
B64="$DXMT_SRC/build/src"
B32="$DXMT_SRC/build32/src"
install_dll() {  # <subpath> <leafname>
    cp "$B64/$1" "$WINE_LIB/x86_64-windows/$2"
    [ -f "$B32/$1" ] && cp "$B32/$1" "$WINE_LIB/i386-windows/$2"
}
install_dll d3d11/d3d11.dll       d3d11.dll
install_dll d3d10/d3d10core.dll   d3d10core.dll
install_dll dxgi/dxgi.dll         dxgi.dll
install_dll winemetal/winemetal.dll winemetal.dll
cp "$B64/winemetal/unix/winemetal.so" "$WINE_LIB/x86_64-unix/winemetal.so"

echo "=== DXMT installed ==="
echo "Active as Wine builtins with no per-bottle override — patches/proton-wine 0017"
echo "defaults d3d11/d3d10core/dxgi/winemetal to builtin in the load order."
