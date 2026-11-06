#!/bin/bash
set -euo pipefail

# Build the x86_64 libraries that Wine's unix side links or dlopens, into
# vendor/x86-deps. Replaces the x86_64 Homebrew this used to come from.
#
# Why not the x86_64 brew any more: Homebrew stopped shipping x86_64 bottles for
# macOS 27, so `brew install freetype gnutls sdl2 molten-vk` under Rosetta
# compiled the whole transitive tree from source -- gmp, nettle, libtasn1,
# p11-kit, libidn2, libunistring, gettext, automake, SDL3 (sdl2 is now
# sdl2-compat) -- each fetched from GNU mirrors that hang from here, and its
# prefix was too long for the bottles it did have to relocate into. The
# libraries still have to be x86_64 (they load into the x86_64 Wine process),
# but nothing about building them needs Rosetta: the arm64 clang cross-compiles
# with -arch x86_64, the build tools are the ARM brew's, and only what Wine
# actually uses gets built.
#
#   freetype     dlopened by win32u for font rendering
#   gmp, nettle  gnutls' crypto backend
#   gnutls       dlopened by secur32 (schannel) and bcrypt
#   SDL2         linked by winebus.so for controllers (vendor/sdl2, the tag the
#                32-bit SDL2.dll is built from too)
#   Vulkan loader  winevulkan dlopens it; build-proton-x86.sh installs it at the
#                leaf names winevulkan looks for and points it at KosmicKrisp
#   SPIRV-Tools  static, for build-kosmickrisp-x86.sh: the x86_64 driver and its
#                kk_clc link it (mesa's vtn disassembler)
#
# Not built, because nothing needs an x86_64 copy: gettext (msgfmt is a build
# tool, the ARM one serves; every library here is built without NLS, so no
# libintl), MoltenVK (KosmicKrisp is the Vulkan driver), and the libraries
# gnutls can carry inside itself (libtasn1, libunistring) or does not need
# (p11-kit, libidn2, trousers).
#
# Sources are pinned release tarballs, checked against the sha256 below and
# cached in build/downloads. Output: vendor/x86-deps/{lib,include}. Every
# dylib's install name is its absolute path in vendor/x86-deps/lib, so build
# tools linked against them run in place; build-proton-x86.sh rewrites them to
# @rpath/<leaf> when it bundles them into Wine/lib.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0
ARM_BREW_PREFIX="$(brew --prefix)"
export PATH="$ARM_BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
whisky_link_probe   # fail fast if DEVELOPER_DIR cannot link the installed SDK
require_tools cmake ninja pkg-config

PREFIX="$X86_DEPS"
DL_DIR="$PROJECT_DIR/build/downloads"
WORK_DIR="$PROJECT_DIR/build/x86-deps"
mkdir -p "$DL_DIR" "$WORK_DIR" "$PREFIX"

GMP_VER=6.3.0
GMP_SHA=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
NETTLE_VER=3.10.2
NETTLE_SHA=fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5
GNUTLS_VER=3.8.13
GNUTLS_SHA=ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e
FREETYPE_VER=2.15.0
FREETYPE_SHA=93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
VULKAN_VER=vulkan-sdk-1.4.363.0
VULKAN_HEADERS_SHA=4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e
VULKAN_LOADER_SHA=941eff558fc74f248745fb7df367640cf89a8457f216dae498a74ae14b6ba6f7
SPIRV_HEADERS_SHA=5b3a0d099f5c7649e29c0938476c462e71d66ad89a0bde42fa1ba3eb476956c9
SPIRV_TOOLS_SHA=e6c83a215538fbfd265ccf398d3877985055df1273dbed73912bd05307664688

# GNU's own servers (ftp.gnu.org, ftpmirror.gnu.org, savannah) time out from
# here -- that is where the brew build stalled -- so the GNU tarballs come from
# the TUNA/USTC mirrors.
GNU_MIRRORS=(https://mirrors.tuna.tsinghua.edu.cn/gnu https://mirrors.ustc.edu.cn/gnu)

# fetch <file> <sha256> <url>... -- download into DL_DIR (resuming a partial
# file, trying each URL in turn) unless a copy with the right hash is there.
fetch() {
    local file="$1" sha="$2" out url t
    shift 2
    out="$DL_DIR/$file"
    if [ -f "$out" ] && [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
        return 0
    fi
    for url in "$@"; do
        for t in 1 2 3 4 5; do
            echo "=== Downloading $file ($url, try $t) ==="
            curl -sSfL -C - --retry 3 --retry-all-errors -o "$out" "$url" || continue
            if [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
                return 0
            fi
            echo "WARNING: $file does not match its sha256; discarding it" >&2
            rm -f "$out"
        done
    done
    echo "ERROR: could not download $file" >&2
    exit 1
}

# unpack <tarball> <dir> -- extract a fresh copy, dropping the top-level folder.
unpack() {
    rm -rf "$2"
    mkdir -p "$2"
    tar -xf "$DL_DIR/$1" -C "$2" --strip-components 1
}

# Shared by the autotools and cmake builds. -headerpad_max_install_names so the
# install_name_tool rewrites in build-proton-x86.sh always fit.
CC_CMD="clang -arch x86_64"
CXX_CMD="clang++ -arch x86_64"
if whisky_ccache_on; then CC_CMD="ccache $CC_CMD"; CXX_CMD="ccache $CXX_CMD"; fi
X86_LDFLAGS="-L$PREFIX/lib -Wl,-headerpad_max_install_names"

# A developer shell can point these at arm64 libraries, and they reach the
# linker (see build-gstreamer-x86.sh); PKG_CONFIG_LIBDIR keeps pkg-config from
# answering with the ARM brew's .pc files.
unset LD_LIBRARY_PATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH \
      CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
      PKG_CONFIG_PATH LDFLAGS CPPFLAGS CFLAGS CXXFLAGS OBJCFLAGS
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# autotools_build <src-dir> [configure-args...] -- a cross build: --host makes
# configure stop trying to run what it compiles, so no step here needs Rosetta.
autotools_build() {
    local src="$1"; shift
    ( cd "$src" &&
      ./configure --host=x86_64-apple-darwin --build=aarch64-apple-darwin \
          --prefix="$PREFIX" --enable-shared --disable-static \
          CC="$CC_CMD" CXX="$CXX_CMD" \
          CPPFLAGS="-I$PREFIX/include" LDFLAGS="$X86_LDFLAGS" \
          "$@" &&
      make -j"$(whisky_ncpu)" &&
      make install )
}

# cmake_build <src-dir> <build-dir> [cmake-args...]
cmake_build() {
    local src="$1" build="$2"; shift 2
    rm -rf "$build"
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-headerpad_max_install_names" \
        `# Absolute install names, like the autotools libraries above. cmake's` \
        `# default @rpath/<leaf> leaves Wine's build-time tools (sfnt2fon, run` \
        `# while building fonts/) unable to find libfreetype at all; the bundle` \
        `# step in build-proton-x86.sh rewrites these to @rpath anyway.` \
        -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
        "$@"
    cmake --build "$build"
    cmake --install "$build"
}

# The libraries are built in dependency order, each into the shared prefix.
fetch "gmp-$GMP_VER.tar.xz" "$GMP_SHA" "${GNU_MIRRORS[@]/%//gmp/gmp-$GMP_VER.tar.xz}"
fetch "nettle-$NETTLE_VER.tar.gz" "$NETTLE_SHA" "${GNU_MIRRORS[@]/%//nettle/nettle-$NETTLE_VER.tar.gz}"
fetch "gnutls-$GNUTLS_VER.tar.xz" "$GNUTLS_SHA" \
    "https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_VER%.*}/gnutls-$GNUTLS_VER.tar.xz"
fetch "freetype-$FREETYPE_VER.tar.xz" "$FREETYPE_SHA" \
    "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VER/freetype-$FREETYPE_VER.tar.xz"
fetch "Vulkan-Headers-$VULKAN_VER.tar.gz" "$VULKAN_HEADERS_SHA" \
    "https://codeload.github.com/KhronosGroup/Vulkan-Headers/tar.gz/refs/tags/$VULKAN_VER"
fetch "Vulkan-Loader-$VULKAN_VER.tar.gz" "$VULKAN_LOADER_SHA" \
    "https://codeload.github.com/KhronosGroup/Vulkan-Loader/tar.gz/refs/tags/$VULKAN_VER"
fetch "SPIRV-Headers-$VULKAN_VER.tar.gz" "$SPIRV_HEADERS_SHA" \
    "https://codeload.github.com/KhronosGroup/SPIRV-Headers/tar.gz/refs/tags/$VULKAN_VER"
fetch "SPIRV-Tools-$VULKAN_VER.tar.gz" "$SPIRV_TOOLS_SHA" \
    "https://codeload.github.com/KhronosGroup/SPIRV-Tools/tar.gz/refs/tags/$VULKAN_VER"

echo "=== GMP $GMP_VER ==="
unpack "gmp-$GMP_VER.tar.xz" "$WORK_DIR/gmp"
# --host=x86_64-apple-darwin picks GMP's generic x86_64 assembly, not code tuned
# for the build machine -- there is no x86 CPU here to tune for.
autotools_build "$WORK_DIR/gmp" --disable-cxx

echo "=== nettle $NETTLE_VER ==="
unpack "nettle-$NETTLE_VER.tar.gz" "$WORK_DIR/nettle"
# nettle's x86_64 build is "fat" by default: AES-NI/SHA-NI paths are chosen by
# cpuid at run time, so they follow whatever Rosetta reports.
autotools_build "$WORK_DIR/nettle" --disable-documentation --disable-openssl

echo "=== GnuTLS $GNUTLS_VER ==="
unpack "gnutls-$GNUTLS_VER.tar.xz" "$WORK_DIR/gnutls"
# libtasn1 and libunistring go inside libgnutls; the rest is either a feature
# Wine never asks of it (PKCS#11, IDN, TPM, compressed certificates, DANE) or a
# tool/binding nobody here runs.
autotools_build "$WORK_DIR/gnutls" \
    --with-included-libtasn1 --with-included-unistring \
    --without-p11-kit --without-idn --without-tpm --without-tpm2 \
    --without-brotli --without-zstd --without-zlib --without-leancrypto \
    --disable-nls --disable-doc --disable-manpages --disable-tools \
    --disable-tests --disable-cxx --disable-guile --disable-libdane \
    --disable-openssl-compatibility --disable-full-test-suite

echo "=== FreeType $FREETYPE_VER ==="
unpack "freetype-$FREETYPE_VER.tar.xz" "$WORK_DIR/freetype-src"
# zlib from the SDK (compressed WOFF/PCF); no PNG, so colour-bitmap emoji fonts
# (sbix/CBDT) render without their bitmaps -- nothing Wine draws needs them.
cmake_build "$WORK_DIR/freetype-src" "$WORK_DIR/freetype-build" \
    -DBUILD_SHARED_LIBS=ON \
    -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON

echo "=== SDL2 (vendor/sdl2) ==="
git -C "$PROJECT_DIR" submodule update --init --depth 1 vendor/sdl2
# Build dir outside the submodule, so the parent repo does not report untracked
# content in vendor/sdl2 (build-sdl2.sh's win32 build dir has the same reason).
cmake_build "$PROJECT_DIR/vendor/sdl2" "$WORK_DIR/sdl2-build" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL_TESTS=OFF -DSDL_INSTALL_TESTS=OFF

echo "=== Vulkan headers + loader ($VULKAN_VER) ==="
unpack "Vulkan-Headers-$VULKAN_VER.tar.gz" "$WORK_DIR/vulkan-headers-src"
cmake_build "$WORK_DIR/vulkan-headers-src" "$WORK_DIR/vulkan-headers-build"
unpack "Vulkan-Loader-$VULKAN_VER.tar.gz" "$WORK_DIR/vulkan-loader-src"
cmake_build "$WORK_DIR/vulkan-loader-src" "$WORK_DIR/vulkan-loader-build" \
    -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX" -DBUILD_TESTS=OFF

echo "=== SPIRV-Headers + SPIRV-Tools ($VULKAN_VER) ==="
unpack "SPIRV-Headers-$VULKAN_VER.tar.gz" "$WORK_DIR/spirv-headers-src"
cmake_build "$WORK_DIR/spirv-headers-src" "$WORK_DIR/spirv-headers-build"
unpack "SPIRV-Tools-$VULKAN_VER.tar.gz" "$WORK_DIR/spirv-tools-src"
# Static only: what links it is the KosmicKrisp driver, so there is no extra
# dylib to bundle. Its generators run on the build machine's python3.
cmake_build "$WORK_DIR/spirv-tools-src" "$WORK_DIR/spirv-tools-build" \
    -DSPIRV-Headers_SOURCE_DIR="$WORK_DIR/spirv-headers-src" \
    -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_WERROR=OFF \
    -DBUILD_SHARED_LIBS=OFF -DSPIRV_TOOLS_BUILD_STATIC=ON

touch "$PREFIX/.built"   # the Makefile's stamp: written only once everything is in
echo "=== Done: $PREFIX ==="
for lib in libgnutls.30 libfreetype.6 libSDL2-2.0.0 libvulkan.1; do
    file "$PREFIX/lib/$lib.dylib"
done
