#!/bin/bash
#
# clang-tidy-scan.sh <dxvk|dxmt|mesa|steamhelper> [file-regex]
#
# Runs the repo's curated clang-tidy check set (see .clang-tidy at the root)
# against one vendored backend, using the compile_commands.json that its meson
# build already emitted. Writes a teed report to the scratch dir. Analysis only:
# never builds, never applies fixes.
#
# Backends and their compile DBs (meson auto-emits compile_commands.json):
#   dxvk        vendor/dxvk/build.w64   — D3D9, C++, mingw cross (UPSTREAM, low-pri)
#   dxmt        vendor/dxmt/build       — D3D11/Metal, C++ (actively developed here)
#   mesa        vendor/mesa/build-x86_64 — KosmicKrisp Vulkan driver, C (UPSTREAM)
#   steamhelper SteamHelper/webhelper_wrapper.c — our tiny PE shim, no compile DB
#
# The optional second arg is a file regex passed to run-clang-tidy. It defaults
# to that backend's OWN src/ subtree so pinned upstream deps and subprojects are
# not scanned. proton-wine is intentionally absent: its autotools build emits no
# compile_commands.json — regenerate with `bear -- make` once the build works.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The ARM Homebrew llvm keg carries clang-tidy / run-clang-tidy.
export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
require_tools clang-tidy run-clang-tidy

cd "$PROJECT_DIR"

backend="${1:-}"
regex="${2:-}"

# Report sink: session scratchpad if the harness provided one, else repo scratch.
SCRATCH="${WHISKY_SCRATCH:-$PROJECT_DIR/scratchpad}"
mkdir -p "$SCRATCH"
report="$SCRATCH/clang-tidy-${backend}.txt"

usage() {
    echo "usage: clang-tidy-scan.sh <dxvk|dxmt|mesa|steamhelper> [file-regex]" >&2
    exit 2
}

# compute_toolchain_args <build_dir> <file_regex>
#
# Emits (one per line) the -extra-arg-before / -extra-arg flags that let the
# llvm-keg clang-tidy actually PARSE this backend's TUs — without them the
# static analyzer never runs, it just dies on "file not found".
#
# Why it's needed: the compile_commands.json was emitted for a *different*
# compiler than clang-tidy's clang — x86_64-w64-mingw32-g++ for the PE code
# (DXVK/DXMT), Apple clang (`-arch x86_64`) for the macOS-native unix TUs
# (winemetal/unix) and Mesa. clang doesn't know those compilers' builtin
# `-isystem` dirs or their implied target, so <cstdint>/<dlfcn.h>/<windows.h>
# all vanish. We ask the *real* compiler for its search dirs and target, then
# feed them back to clang-tidy.
#
# The profile (mingw cross vs macOS native) is auto-detected from the first DB
# entry matching the scan regex — backend subtrees are single-toolchain, so one
# profile fits a scoped scan. (A broad dxmt regex spanning both the PE tree and
# winemetal/unix picks whichever matches first; scan the native unix subtree
# separately, e.g. `clang-tidy-scan.sh dxmt vendor/dxmt/src/winemetal/unix/`.)
compute_toolchain_args() {
    local build_dir="$1" regex="$2"
    local db="$build_dir/compile_commands.json"
    [ -f "$db" ] || return 0

    # Representative TU: real compiler (leading ccache stripped), -arch, and
    # language, parsed from the first entry whose canonical path matches regex.
    local info comp arch lang
    info=$(python3 - "$db" "$regex" <<'PY'
import json, os, re, shlex, sys
db, rx = sys.argv[1], re.compile(sys.argv[2])
entries = json.load(open(db))
pick = None
for e in entries:
    absf = os.path.normpath(os.path.join(e["directory"], e["file"]))
    if rx.search(absf):
        pick = e
        break
pick = pick or entries[0]
toks = shlex.split(pick["command"]) if pick.get("command") else pick["arguments"]
i = 0
while i < len(toks) and (toks[i].endswith("ccache") or toks[i].endswith("sccache")):
    i += 1
comp = toks[i]
arch = ""
for j, t in enumerate(toks):
    if t == "-arch" and j + 1 < len(toks):
        arch = toks[j + 1]
ext = pick["file"].rsplit(".", 1)[-1].lower()
lang = "c++" if ext in ("cpp", "cc", "cxx", "c++", "mm") else "c"
print(comp)
print(arch)
print(lang)
PY
)
    { read -r comp; read -r arch; read -r lang; } <<<"$info"
    [ -n "$comp" ] || return 0

    # Probe the real compiler for its builtin system-include search dirs. Probe
    # as C++ so C++ TUs get their stdlib (the C dirs are a subset, harmless to C
    # TUs). Drop the gcc-internal include/ + include-fixed/ dirs: they hold GCC's
    # own intrinsic headers (adxintrin.h, ia32intrin.h, ... full of
    # __builtin_ia32_* that clang doesn't define) — clang must use its own
    # resource-dir copies instead.
    local probe_arch=()
    [ -n "$arch" ] && probe_arch=(-arch "$arch")
    local dirs
    dirs=$(echo | "$comp" "${probe_arch[@]+"${probe_arch[@]}"}" -E -Wp,-v -xc++ - 2>&1 \
        | awk '/#include <\.\.\.> search starts here:/{f=1;next}/End of search list/{f=0}f{sub(/^ +/,"");sub(/ \(framework directory\)$/,"");print}' \
        | grep -vE '/lib/gcc/[^/]+/[0-9][^/]*/include(-fixed)?$' || true)

    # Target: mingw needs the cross triple (so _WIN32 etc. are predefined and the
    # mingw headers' #ifdef __MINGW32__ paths compile); native macOS needs the
    # SDK sysroot so <dlfcn.h> and the frameworks resolve.
    local triple
    triple=$("$comp" -dumpmachine 2>/dev/null || true)
    if printf '%s' "$triple" | grep -q mingw; then
        printf -- '-extra-arg-before=--target=%s\n' "$triple"
    else
        printf -- '-extra-arg-before=--target=%s-apple-macos\n' "${arch:-x86_64}"
        local sdk
        sdk=$(xcrun --show-sdk-path 2>/dev/null || true)
        if [ -n "$sdk" ]; then
            printf -- '-extra-arg-before=-isysroot\n'
            printf -- '-extra-arg-before=%s\n' "$sdk"
        fi
    fi
    local d
    while IFS= read -r d; do
        [ -n "$d" ] && printf -- '-extra-arg-before=-isystem%s\n' "$d"
    done <<<"$dirs"

    # Let clang tolerate the gcc-only flags/attributes left in the compile
    # command rather than erroring out of the whole TU.
    printf -- '%s\n' '-extra-arg=-Wno-unknown-warning-option' \
        '-extra-arg=-Qunused-arguments' \
        '-extra-arg=-Wno-unknown-attributes'
}

case "$backend" in
    dxvk)
        builddir="vendor/dxvk/build.w64"
        default_regex="vendor/dxvk/src/d3d9/"
        ;;
    dxmt)
        builddir="vendor/dxmt/build"
        default_regex="vendor/dxmt/src/"
        ;;
    mesa)
        builddir="vendor/mesa/build-x86_64"
        default_regex="vendor/mesa/src/kosmickrisp/"
        ;;
    steamhelper)
        builddir=""
        ;;
    ""|-h|--help)
        usage
        ;;
    *)
        echo "ERROR: unknown backend '$backend'" >&2
        usage
        ;;
esac

echo "=== clang-tidy scan: $backend -> $report ==="

# SteamHelper has no compile DB — it's a single standalone Windows PE source.
# Invoke clang-tidy directly with a mingw-ish target so the win32 headers and
# wide-char (-municode) entry point parse.
if [ "$backend" = "steamhelper" ]; then
    src="SteamHelper/webhelper_wrapper.c"
    [ -f "$src" ] || { echo "ERROR: $src not found" >&2; exit 1; }
    # No compile DB: give clang-tidy the mingw target plus the mingw-w64 sysroot
    # so <windows.h> and friends resolve. The opt/ prefix is a stable brew symlink.
    mingw_sysroot="/opt/homebrew/opt/mingw-w64/toolchain-x86_64/x86_64-w64-mingw32"
    clang-tidy "$src" -- -target x86_64-w64-mingw32 -municode \
        --sysroot="$mingw_sysroot" -isystem "$mingw_sysroot/include" 2>&1 | tee "$report"
    echo "=== done: $report ==="
    exit 0
fi

[ -f "$builddir/compile_commands.json" ] || {
    echo "ERROR: $builddir/compile_commands.json missing — build $backend first" >&2
    exit 1
}

# Default the file filter to this backend's own src/ so upstream deps and meson
# subprojects are skipped.
[ -n "$regex" ] || regex="$default_regex"

# Feed clang-tidy the real toolchain's system-include dirs + target so the
# clang-analyzer checks actually run (see compute_toolchain_args). Built into an
# array with a while-read loop — /bin/bash on macOS is 3.2, no mapfile.
extra_args=()
while IFS= read -r _a; do
    [ -n "$_a" ] && extra_args+=("$_a")
done < <(compute_toolchain_args "$builddir" "$regex")

# run-clang-tidy fans out across cores; -quiet drops the per-file progress spam.
run-clang-tidy -p "$builddir" -quiet "${extra_args[@]+"${extra_args[@]}"}" "$regex" 2>&1 | tee "$report"

echo "=== done: $report ==="
