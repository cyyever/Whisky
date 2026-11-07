#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools cmake ninja curl tar xcrun lipo shasum

LLVM_VERSION=23.1.5
LLVM_ARCHIVE="$PROJECT_DIR/vendor/llvm-project-$LLVM_VERSION.src.tar.xz"
LLVM_SOURCE="$PROJECT_DIR/vendor/llvm23-source/llvm-project-$LLVM_VERSION.src"
LLVM_BUILD="$PROJECT_DIR/vendor/llvm23-build-x86_64"
LLVM_PREFIX="$PROJECT_DIR/vendor/llvm23-x86_64"
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz"
LLVM_SHA256=fb50b1eac93ddeb3aa8dab4cfe324dff74f4a9c2bdee6160c9e36188f8d06a6e

if [ ! -f "$LLVM_ARCHIVE" ]; then
    echo "=== Downloading LLVM $LLVM_VERSION source ==="
    curl -fL --retry 3 "$LLVM_URL" -o "$LLVM_ARCHIVE"
fi
echo "$LLVM_SHA256  $LLVM_ARCHIVE" | shasum -a 256 -c -

if [ ! -f "$LLVM_SOURCE/llvm/CMakeLists.txt" ]; then
    mkdir -p "$PROJECT_DIR/vendor/llvm23-source"
    tar -xf "$LLVM_ARCHIVE" -C "$PROJECT_DIR/vendor/llvm23-source"
fi

echo "=== Configuring LLVM $LLVM_VERSION for x86_64 macOS ==="
CCACHE_DISABLE=1 cmake \
    -S "$LLVM_SOURCE/llvm" \
    -B "$LLVM_BUILD" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
    -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-apple-darwin \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_ENABLE_RTTI=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DLLVM_BUILD_DOCS=OFF \
    -DLLVM_OPTIMIZED_TABLEGEN=ON

NCPU=$(whisky_ncpu)
echo "=== Building LLVM $LLVM_VERSION static libraries with $NCPU jobs ==="
CCACHE_DISABLE=1 ninja -C "$LLVM_BUILD" -j "$NCPU" \
    install-llvm-libraries install-llvm-headers install-llvm-config

actual_version=$("$LLVM_PREFIX/bin/llvm-config" --version)
actual_target=$("$LLVM_PREFIX/bin/llvm-config" --host-target)
[ "$actual_version" = "$LLVM_VERSION" ] || {
    echo "ERROR: expected LLVM $LLVM_VERSION, got $actual_version." >&2; exit 1;
}
[[ "$actual_target" == x86_64-* ]] || {
    echo "ERROR: expected x86_64 LLVM, got $actual_target." >&2; exit 1;
}
lipo -archs "$LLVM_PREFIX/lib/libLLVMCore.a" | grep -qw x86_64 || {
    echo "ERROR: libLLVMCore.a does not contain x86_64 code." >&2; exit 1;
}
echo "LLVM $actual_version installed for $actual_target at $LLVM_PREFIX."
