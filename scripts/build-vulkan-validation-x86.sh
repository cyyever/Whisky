#!/bin/bash
set -euo pipefail

# Cross-build x86_64 Khronos Vulkan Validation Layers (VK_LAYER_KHRONOS_validation)
# into vendor/vulkan-validation/ for use with Wine + KosmicKrisp Vulkan tests.
#
# Uses the same VULKAN_VER tag as scripts/build-x86-deps.sh, reuses the cached
# tarballs in build/downloads/ and x86_64 Vulkan-Headers in vendor/x86-deps/
# (without modifying vendor/x86-deps/), and builds minimal static build-time
# dependencies (Vulkan-Utility-Libraries, SPIRV-Headers, SPIRV-Tools) in a
# staging prefix under build/vulkan-validation/ so the resulting
# libVkLayer_khronos_validation.dylib is self-contained.
#
# Output:
#   vendor/vulkan-validation/libVkLayer_khronos_validation.dylib  (x86_64, ad-hoc signed)
#   vendor/vulkan-validation/VkLayer_khronos_validation.json      (absolute library_path)

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0
ARM_BREW_PREFIX="$(brew --prefix)"
export PATH="$ARM_BREW_PREFIX/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
whisky_link_probe
require_tools cmake ninja jq codesign

OUT_DIR="$PROJECT_DIR/vendor/vulkan-validation"
DL_DIR="$PROJECT_DIR/build/downloads"
WORK_DIR="$PROJECT_DIR/build/vulkan-validation"
DEPS_PREFIX="$WORK_DIR/deps"
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$DL_DIR" "$WORK_DIR" "$DEPS_PREFIX" "$STAGE_DIR" "$OUT_DIR"

# Keep aligned with VULKAN_VER in scripts/build-x86-deps.sh.
VULKAN_VER=vulkan-sdk-1.4.363.0
VULKAN_HEADERS_SHA=4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e
VULKAN_UTILITY_LIBRARIES_SHA=a5308b62e3bac84cf45c4d7dd5b830aabace4847fdb71f4fd7db3be034c2bebf
SPIRV_HEADERS_SHA=5b3a0d099f5c7649e29c0938476c462e71d66ad89a0bde42fa1ba3eb476956c9
SPIRV_TOOLS_SHA=e6c83a215538fbfd265ccf398d3877985055df1273dbed73912bd05307664688
VULKAN_VALIDATION_LAYERS_SHA=36720627913a591ae8ffc0f24b3c04f98af65242c9b7215d1944a85ff5b70e00

fetch() {
    local file="$1" sha="$2" url="$3" out t
    out="$DL_DIR/$file"
    if [ -f "$out" ] && [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
        return 0
    fi
    for t in 1 2 3 4 5; do
        echo "=== Downloading $file ($url, try $t) ==="
        curl -sSfL -C - --retry 3 --retry-all-errors -o "$out" "$url" || continue
        if [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
            return 0
        fi
        echo "WARNING: $file does not match its sha256; discarding it" >&2
        rm -f "$out"
    done
    echo "ERROR: could not download $file" >&2
    exit 1
}

unpack() {
    rm -rf "$2"
    mkdir -p "$2"
    tar -xf "$DL_DIR/$1" -C "$2" --strip-components 1
}

# Avoid leaking arm64 developer shell flags into the x86_64 cross-build.
unset LD_LIBRARY_PATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH \
      CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
      PKG_CONFIG_PATH LDFLAGS CPPFLAGS CFLAGS CXXFLAGS OBJCFLAGS

CCACHE_CMAKE_ARGS=()
if whisky_ccache_on; then
    CCACHE_CMAKE_ARGS=(
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
fi

cmake_dep_build() {
    local src="$1" build="$2"; shift 2
    rm -rf "$build"
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$WHISKY_MACOS_DEPLOYMENT_TARGET" \
        -DCMAKE_C_FLAGS="$WHISKY_X86_64_ARCH_FLAGS" \
        -DCMAKE_CXX_FLAGS="$WHISKY_X86_64_ARCH_FLAGS" \
        -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
        -DCMAKE_PREFIX_PATH="$DEPS_PREFIX;$X86_DEPS" \
        -DCMAKE_FIND_ROOT_PATH="$DEPS_PREFIX;$X86_DEPS" \
        ${CCACHE_CMAKE_ARGS[@]+"${CCACHE_CMAKE_ARGS[@]}"} \
        "$@"
    cmake --build "$build" --parallel "$(whisky_ncpu)"
    cmake --install "$build"
}

fetch "Vulkan-Utility-Libraries-$VULKAN_VER.tar.gz" "$VULKAN_UTILITY_LIBRARIES_SHA" \
    "https://codeload.github.com/KhronosGroup/Vulkan-Utility-Libraries/tar.gz/refs/tags/$VULKAN_VER"
fetch "SPIRV-Headers-$VULKAN_VER.tar.gz" "$SPIRV_HEADERS_SHA" \
    "https://codeload.github.com/KhronosGroup/SPIRV-Headers/tar.gz/refs/tags/$VULKAN_VER"
fetch "SPIRV-Tools-$VULKAN_VER.tar.gz" "$SPIRV_TOOLS_SHA" \
    "https://codeload.github.com/KhronosGroup/SPIRV-Tools/tar.gz/refs/tags/$VULKAN_VER"
fetch "Vulkan-ValidationLayers-$VULKAN_VER.tar.gz" "$VULKAN_VALIDATION_LAYERS_SHA" \
    "https://codeload.github.com/KhronosGroup/Vulkan-ValidationLayers/tar.gz/refs/tags/$VULKAN_VER"

if [ ! -d "$X86_DEPS/share/cmake/VulkanHeaders" ]; then
    echo "=== Vulkan-Headers ($VULKAN_VER) ==="
    fetch "Vulkan-Headers-$VULKAN_VER.tar.gz" "$VULKAN_HEADERS_SHA" \
        "https://codeload.github.com/KhronosGroup/Vulkan-Headers/tar.gz/refs/tags/$VULKAN_VER"
    unpack "Vulkan-Headers-$VULKAN_VER.tar.gz" "$WORK_DIR/vulkan-headers-src"
    cmake_dep_build "$WORK_DIR/vulkan-headers-src" "$WORK_DIR/vulkan-headers-build"
fi

echo "=== Vulkan-Utility-Libraries ($VULKAN_VER) ==="
unpack "Vulkan-Utility-Libraries-$VULKAN_VER.tar.gz" "$WORK_DIR/vulkan-utility-libraries-src"
cmake_dep_build "$WORK_DIR/vulkan-utility-libraries-src" "$WORK_DIR/vulkan-utility-libraries-build" \
    -DUPDATE_DEPS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_WERROR=OFF

echo "=== SPIRV-Headers ($VULKAN_VER) ==="
unpack "SPIRV-Headers-$VULKAN_VER.tar.gz" "$WORK_DIR/spirv-headers-src"
cmake_dep_build "$WORK_DIR/spirv-headers-src" "$WORK_DIR/spirv-headers-build" \
    -DSPIRV_HEADERS_ENABLE_TESTS=OFF

echo "=== SPIRV-Tools ($VULKAN_VER, static) ==="
unpack "SPIRV-Tools-$VULKAN_VER.tar.gz" "$WORK_DIR/spirv-tools-src"
cmake_dep_build "$WORK_DIR/spirv-tools-src" "$WORK_DIR/spirv-tools-build" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSPIRV-Headers_SOURCE_DIR="$WORK_DIR/spirv-headers-src" \
    -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV_SKIP_EXECUTABLES=ON \
    -DSPIRV_WERROR=OFF \
    -DSPIRV_TOOLS_BUILD_STATIC=ON

echo "=== Vulkan-ValidationLayers ($VULKAN_VER) ==="
unpack "Vulkan-ValidationLayers-$VULKAN_VER.tar.gz" "$WORK_DIR/vvl-src"
rm -rf "$WORK_DIR/vvl-build" "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cmake -S "$WORK_DIR/vvl-src" -B "$WORK_DIR/vvl-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$WHISKY_MACOS_DEPLOYMENT_TARGET" \
    -DCMAKE_C_FLAGS="$WHISKY_X86_64_ARCH_FLAGS" \
    -DCMAKE_CXX_FLAGS="$WHISKY_X86_64_ARCH_FLAGS" \
    -DCMAKE_INSTALL_PREFIX="$STAGE_DIR" \
    -DCMAKE_PREFIX_PATH="$DEPS_PREFIX;$X86_DEPS" \
    -DCMAKE_FIND_ROOT_PATH="$DEPS_PREFIX;$X86_DEPS" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-headerpad_max_install_names" \
    -DUPDATE_DEPS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_WERROR=OFF \
    -DUSE_MIMALLOC=OFF \
    -DVVL_CODEGEN=OFF \
    ${CCACHE_CMAKE_ARGS[@]+"${CCACHE_CMAKE_ARGS[@]}"}
cmake --build "$WORK_DIR/vvl-build" --parallel "$(whisky_ncpu)"
cmake --install "$WORK_DIR/vvl-build"

DYLIB_SRC="$(find "$STAGE_DIR" -name 'libVkLayer_khronos_validation.dylib' | head -n 1)"
JSON_SRC="$(find "$STAGE_DIR" -name 'VkLayer_khronos_validation.json' | head -n 1)"
if [ -z "$DYLIB_SRC" ] || [ -z "$JSON_SRC" ]; then
    echo "ERROR: staged validation layer artifacts not found under $STAGE_DIR" >&2
    exit 1
fi

DYLIB_OUT="$OUT_DIR/libVkLayer_khronos_validation.dylib"
JSON_OUT="$OUT_DIR/VkLayer_khronos_validation.json"

cp -f "$DYLIB_SRC" "$DYLIB_OUT"
install_name_tool -id "$DYLIB_OUT" "$DYLIB_OUT"
codesign --force --sign - "$DYLIB_OUT"

jq --arg lib "$DYLIB_OUT" '.layer.library_path = $lib' "$JSON_SRC" > "$JSON_OUT"

touch "$OUT_DIR/.built"
echo "=== Done: $OUT_DIR ==="
file "$DYLIB_OUT"
otool -L "$DYLIB_OUT"
codesign --verify --verbose "$DYLIB_OUT"
jq '{name: .layer.name, library_path: .layer.library_path, api_version: .layer.api_version}' "$JSON_OUT"
