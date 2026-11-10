#!/bin/bash
set -e

# Build Mesa's KosmicKrisp Vulkan driver (Vulkan-on-Metal) as x86_64, for use
# under Rosetta. Two-phase build so no x86_64 LLVM toolchain is needed:
#   1) arm64 native build of the build-time tools (mesa_clc, vtn_bindgen2),
#      using the ARM brew llvm/libclc/spirv-llvm-translator/spirv-tools.
#   2) x86_64 cross build of the driver with -Dmesa-clc=system, pointing PATH
#      at the phase-1 tools. A meson cross file is required: plain
#      CC="clang -arch x86_64" leaves host cpu_family=aarch64 and blake3
#      selects NEON sources. needs_exe_wrapper=false — Rosetta runs the
#      in-tree x86_64 tools (kk_clc) directly during the build.
# Output: vendor/kosmickrisp/libvulkan_kosmickrisp.dylib + ICD json.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
whisky_ccache_guard   # honor WHISKY_CCACHE=0 for the meson/clang build
MESA_SRC="$PROJECT_DIR/vendor/mesa"
OUT_DIR="$PROJECT_DIR/vendor/kosmickrisp"
ARM_BREW_PREFIX="$(brew --prefix)"

# ARM brew meson/ninja (~/.local/bin has a meson with a broken interpreter — keep it
# off PATH). llvm is keg-only; phase 1 (mesa_clc) needs its llvm-config.
export PATH="$ARM_BREW_PREFIX/opt/llvm/bin:$ARM_BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
whisky_link_probe   # fail fast if DEVELOPER_DIR cannot link the installed SDK
# Homebrew LLVM builds the native shader tools above. Use Xcode's compiler for
# the macOS x86_64 driver: Homebrew clang cannot resolve the SDK's endian.h
# compatibility header in this cross build, which makes compilation fail in
# u_endian.h.
XCODE_CLANG="$(xcrun --find clang)"
XCODE_CLANGXX="$(xcrun --find clang++)"
# WHISKY_BUILD_JOBS caps ninja; unset, ninja keeps its own default.
NINJA_JOBS=()
if [ -n "${WHISKY_BUILD_JOBS:-}" ]; then NINJA_JOBS=(-j "$(whisky_ncpu)"); fi

# This payload only needs the Vulkan-on-Metal driver. Media playback is
# provided separately by Wine/GStreamer, not Mesa video drivers.
minimal_options=(
    -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled
    -Dgbm=disabled -Dvideo-codecs= -Dvulkan-layers= -Dtools=
    -Dbuild-tests=false
)

# Apply out-of-tree Mesa patches (patches/mesa/0001-*.patch: the WSI present-blit
# command-buffer lifetime fix -- acquire frees a blit cmdbuf the GPU may still be
# executing; the freed quad tears into a diagonal under GPU backlog).
# Checked before patching: apply_patches resets the worktree, so a drifted
# checkout would be silently patched and built instead of reported.
check_submodule_pin vendor/mesa Mesa
apply_patches "$MESA_SRC" "$PROJECT_DIR/patches/mesa" Mesa

# A brew upgrade moves a dependency's Cellar directory, and meson does not
# notice: it caches dependency lookups in meson-private, so --reconfigure
# reports `LLVMSPIRVLib found: YES 23.1.0.0 (cached)` and keeps emitting -I for a
# 23.1.0 directory brew deleted when it installed 23.1.1 -- phase 1 then dies on
# a header that is present all along, one directory over. Only starting the build
# dir over clears that cache. Detect it by asking whether a Cellar path the build
# dir still names is actually there, so this triggers on any upgraded dependency
# rather than on a list we would have to maintain.
drop_if_stale() {  # <build-dir>
    local dir=$1 path
    [ -f "$dir/build.ninja" ] || return 0
    for path in $(grep -ohE '/opt/homebrew/Cellar/[^/]+/[^/ :"]+' "$dir/build.ninja" | sort -u); do
        [ -d "$path" ] && continue
        echo "=== $(basename "$dir") was configured against $path, which is gone; rebuilding it from scratch ==="
        rm -rf "$dir"
        return 0
    done
}

TOOLS_BUILD="$MESA_SRC/build-arm64-tools"
TOOLS_BIN="$TOOLS_BUILD/staged-bin"
drop_if_stale "$TOOLS_BUILD"
echo "=== Phase 1: arm64 mesa_clc / vtn_bindgen2 ==="
# ninja every time, not just when the tools are absent. These are compilers for
# phase 2's .cl shaders, built from the same tree they compile, so a bump moves
# both -- and a stale mesa_clc does not fail cleanly: after ~500 commits it took
# SIGBUS on kk_draws.cl, and ninja reported only `FAILED: [code=138]`, with the
# four builds that follow still returning 0. ninja is incremental, so this costs
# nothing when the tree has not moved.
#
# --reconfigure rather than skip, for the same reason build-dxvk.sh and
# build-vkd3d.sh use it: meson caches the flags pkg-config gave it, and a brew
# upgrade moves the paths those flags name. A build dir configured against
# spirv-llvm-translator 23.1.0 kept compiling with -I.../23.1.0/include after
# brew replaced it with 23.1.1, and phase 1 died on a header that was present all
# along, just one directory over. Reconfiguring is cheap and keeps object files.
tools_setup=(meson setup "$TOOLS_BUILD" "$MESA_SRC" -Dbuildtype=release
    -Dplatforms=macos -Dvulkan-drivers= -Dgallium-drivers= -Dopengl=false
    -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dzstd=disabled
    "${minimal_options[@]}")
if [ -f "$TOOLS_BUILD/build.ninja" ]; then tools_setup+=(--reconfigure); fi
"${tools_setup[@]}"
ninja -C "$TOOLS_BUILD" "${NINJA_JOBS[@]}" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2
mkdir -p "$TOOLS_BIN"
cp "$TOOLS_BUILD/src/compiler/clc/mesa_clc" \
   "$TOOLS_BUILD/src/compiler/spirv/vtn_bindgen2" "$TOOLS_BIN/"

DRIVER_BUILD="$MESA_SRC/build-x86_64"
# Outside the submodule. meson self-ignores its build dirs (it writes a
# .gitignore containing `*` into each), but a file dropped in mesa's source root
# does not get that, and left the parent repo reporting vendor/mesa as having
# untracked content forever. build/ is already gitignored here.
CROSS_FILE="$PROJECT_DIR/build/mesa-x86_64-darwin-cross.ini"
mkdir -p "$(dirname "$CROSS_FILE")"
cat > "$CROSS_FILE" <<EOF
[binaries]
c = ['$XCODE_CLANG', '-arch', 'x86_64']
cpp = ['$XCODE_CLANGXX', '-arch', 'x86_64']
objc = ['$XCODE_CLANG', '-arch', 'x86_64']
objcpp = ['$XCODE_CLANGXX', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = '$ARM_BREW_PREFIX/bin/pkg-config'

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = false
EOF

echo "=== Phase 2: x86_64 KosmicKrisp driver ==="
export PATH="$TOOLS_BIN:$PATH"
# LIBDIR, not PATH: PKG_CONFIG_PATH only puts these first, and anything missing
# from them then resolves from the ARM brew -- an arm64 spirv-tools that the
# x86_64 kk_clc cannot link ("_spvTextDestroy ... not found for architecture
# x86_64"). With LIBDIR an absent x86_64 library fails at configure instead.
export PKG_CONFIG_LIBDIR="$X86_DEPS/lib/pkgconfig:$X86_DEPS/share/pkgconfig"
meson_args=( "$DRIVER_BUILD" "$MESA_SRC" --cross-file "$CROSS_FILE"
    -Dbuildtype=release -Dplatforms=macos
    -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false
    -Dmesa-clc=system -Dzstd=disabled "${minimal_options[@]}" )
# meson records the cross-file's absolute path in meson-private/cmd_line.txt and
# re-reads it on every regeneration -- including from `ninja`, before it can be
# told a new one. So a build dir configured against a cross-file that has since
# moved cannot be repaired by --reconfigure or --wipe; it dies in
# machinefile.py with a FileNotFoundError that names the path and nothing else.
# Start over instead. Costs one full rebuild, once.
drop_if_stale "$DRIVER_BUILD"
recorded="$DRIVER_BUILD/meson-private/cmd_line.txt"
rebuild_driver=false
if [ -d "$DRIVER_BUILD" ]; then
    if [ -f "$recorded" ] && ! grep -qF "$CROSS_FILE" "$recorded"; then
        rebuild_driver=true
    elif [ -f "$DRIVER_BUILD/build.ninja" ] &&
         ! grep -qF "$XCODE_CLANG -arch x86_64" "$DRIVER_BUILD/build.ninja"; then
        # Meson keeps the compiler cached even when --reconfigure sees an updated
        # cross file, so old build dirs would continue using Homebrew clang.
        rebuild_driver=true
    fi
fi
if [ "$rebuild_driver" = true ]; then
    echo "=== Build dir uses a stale cross-file or compiler; rebuilding from scratch ==="
    rm -rf "$DRIVER_BUILD"
fi
if [ -d "$DRIVER_BUILD" ]; then meson_args+=(--reconfigure); fi
meson setup "${meson_args[@]}"
ninja -C "$DRIVER_BUILD" "${NINJA_JOBS[@]}"

echo "=== Installing to $OUT_DIR ==="
mkdir -p "$OUT_DIR"
DYLIB="$DRIVER_BUILD/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
cp "$DYLIB" "$OUT_DIR/"
# Homebrew does not always leave an unversioned python3 symlink in bin (this
# machine has only python3.12 and python3.14), so resolve an interpreter
# instead of hardcoding one. Any python3 will do --
# this only reads one key out of one JSON file.
PY=""
for cand in /opt/homebrew/bin/python3 /opt/homebrew/bin/python3.14 \
            /opt/homebrew/bin/python3.12 /usr/bin/python3; do
    [ -x "$cand" ] && { PY="$cand"; break; }
done
[ -n "$PY" ] || { echo "ERROR: no python3 found to read the ICD api_version" >&2; exit 1; }
API_VERSION=$("$PY" -c "import json,glob; print(json.load(open(glob.glob('$DRIVER_BUILD/src/kosmickrisp/vulkan/*_icd.*.json')[0]))['ICD']['api_version'])")
cat > "$OUT_DIR/kosmickrisp_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "$API_VERSION",
        "library_path": "$OUT_DIR/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.0"
}
EOF

echo "=== Done ==="
file "$OUT_DIR/libvulkan_kosmickrisp.dylib"
echo "MTL4 symbol references: $(strings "$OUT_DIR/libvulkan_kosmickrisp.dylib" | grep -c MTL4 || true)"
