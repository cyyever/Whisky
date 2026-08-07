#!/usr/bin/env bash
#
# Build a 32-bit SDL2.dll for the bottle.
#
# Steam's GPU probe, bin/gldriverquery.exe, is a 32-bit PE that imports SDL2.dll.
# Every package Steam downloads for a 64-bit install is *_win64 or *_all, so the
# 32-bit SDL2 is simply never delivered: the probe exits c0000135
# (STATUS_DLL_NOT_FOUND) before main(), and Steam records one opaque line —
#
#   Error: CFindCurrentBucketJob::YieldingRunTestProgram:
#          process exit code 3221225781: .\bin\gldriverquery.exe
#
# Note the 64-bit sibling, gldriverquery64.exe, does not import SDL2 and already
# runs, so this is not on the critical path for anything known. It removes one
# startup error, which is worth having while the remaining "Steam never calls
# ShowWindow" problem is still being narrowed down.
#
# SDL2's ABI is stable across the 2.x series, so the exact release does not
# matter much; vendor/sdl2 is pinned at a release tag rather than a branch tip
# so a rebuild is reproducible.
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
SDL_SRC="$PROJECT_DIR/vendor/sdl2"
BUILD_DIR="$SDL_SRC/build-win32"

require_tools cmake ninja i686-w64-mingw32-gcc

git -C "$PROJECT_DIR" submodule update --init vendor/sdl2

# The toolchain file lives in the build dir, not the source tree: vendor/sdl2 is
# a pristine submodule and should stay that way.
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/mingw32-toolchain.cmake" <<'EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR i686)
set(CMAKE_C_COMPILER   i686-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER i686-w64-mingw32-g++)
set(CMAKE_RC_COMPILER  i686-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

echo "=== Configuring SDL2 (win32) ==="
# Only the shared library is wanted. The subsystems are left at their defaults:
# gldriverquery links the whole DLL, and trimming them is a way to produce a
# DLL that loads and then fails inside an SDL_Init we did not anticipate.
cmake -S "$SDL_SRC" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/mingw32-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TEST=OFF

echo "=== Building ==="
cmake --build "$BUILD_DIR"

DLL="$BUILD_DIR/SDL2.dll"
[ -f "$DLL" ] || { echo "ERROR: $DLL not produced" >&2; exit 1; }
file "$DLL"

# Install next to the executable that needs it, in every bottle that has Steam.
# Steam resolves it from the exe's own directory, so this needs no load-order
# entry and cannot shadow a real SDL2 a game ships.
installed=0
for bottle in "$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"/*/; do
    target="$bottle/drive_c/Program Files (x86)/Steam/bin"
    [ -d "$target" ] || continue
    cp "$DLL" "$target/SDL2.dll"
    echo "installed -> $target/SDL2.dll"
    installed=$((installed + 1))
done
[ "$installed" -gt 0 ] || echo "NOTE: no bottle with a Steam install found; DLL left at $DLL"

echo "=== SDL2 built ==="
