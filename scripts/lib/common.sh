#!/bin/bash
#
# Shared helpers for the Whisky build scripts. Source it near the top of a
# script with:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Sourcing has no side effects beyond defining variables and functions: it sets
# PROJECT_DIR / INSTALL_DIR / X86_BREW(_HOME) and defines the helpers below
# (export_homebrew_mirrors, apply_patches, require_tools, whisky_ncpu, and the
# ccache helpers). No subprocesses (brew, git) run until a function is called.

# Repo root, derived from this file's own location (scripts/lib/common.sh).
# Reliable regardless of the caller's cwd or how it was invoked.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Where the build payloads land (Wine, DXVK, DXMT, SteamHelper, version plist).
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"

# x86_64 Homebrew (installed by setup-x86-brew.sh) — provides the libraries
# linked into x86_64 Wine. Build tools come from the ARM64 brew.
X86_BREW_HOME="$PROJECT_DIR/vendor/homebrew-x86"
X86_BREW="$X86_BREW_HOME/bin/brew"

# USTC mirrors for Homebrew (git remotes + bottle/api domains). Call before any
# x86_64 `brew` invocation that may fetch from the network.
export_homebrew_mirrors() {
    export HOMEBREW_BREW_GIT_REMOTE=https://mirrors.ustc.edu.cn/brew.git
    export HOMEBREW_CORE_GIT_REMOTE=https://mirrors.ustc.edu.cn/homebrew-core.git
    export HOMEBREW_BOTTLE_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles
    export HOMEBREW_API_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles/api
}

# apply_patches <src_dir> <patch_dir> <label> [reset]
#
# Idempotently apply patch_dir/*.patch to the git worktree at src_dir: skip
# already-applied patches (reverse-check), apply pending ones, and hard-fail on
# a conflict or partial apply. A no-op if patch_dir does not exist. Pass a
# non-empty 4th argument to `git checkout -- .` first, giving a deterministic
# clean base (discards uncommitted working-tree edits in src_dir).
apply_patches() {
    local src_dir="$1" patch_dir="$2" label="$3" reset="${4:-}"
    [ -d "$patch_dir" ] || return 0
    if [ -n "$reset" ]; then
        git -C "$src_dir" checkout -- .
        # checkout -- . only reverts tracked files; untracked files created by add-file
        # patches (e.g. msync.c/.h, server/msync.c) linger and make a re-apply hit
        # "already exists" and hard-fail. `git clean -fdq` removes untracked NON-ignored
        # files (patch leftovers + generated inputs + stray dirs) for a deterministic base.
        # Deliberately no -x, so gitignored paths survive — notably an out-of-tree build/
        # tree, keeping compiles incremental across forced rebuilds.
        git -C "$src_dir" clean -fdq
    fi
    local patch
    for patch in "$patch_dir"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$src_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
            echo "=== $label patch already applied: $(basename "$patch") ==="
        elif git -C "$src_dir" apply --check "$patch" >/dev/null 2>&1; then
            echo "=== Applying $label patch: $(basename "$patch") ==="
            git -C "$src_dir" apply "$patch"
        else
            echo "ERROR: cannot apply $(basename "$patch") (conflict or partial apply)"
            exit 1
        fi
    done
}

# bottle_shellenv <bottle-dir> — emit shell `export` lines (for `eval`) that
# reproduce the runtime environment the Whisky app sets for a Wine launch.
# Replaces the deleted `WhiskyCmd shellenv <bottle>` CLI. Values are kept in sync
# with WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift (constructWineEnvironment) and
# BottleSettings.swift (environmentVariables):
#   * PATH gains Wine/bin so wine64/wineserver are directly on PATH;
#   * WINEPREFIX points at the bottle;
#   * DYLD_FALLBACK_LIBRARY_PATH points at Wine/lib (dylib resolution);
#   * WINEMSYNC_NO_ANON_AUTOEVENT=1 matches the shipping msync mask.
# Deliberately does NOT emit WINEDLLOVERRIDES (the app no longer sets it — patch
# 0017's builtin load order handles D3D/Vulkan) nor WINEMSYNC (the msync test
# scripts drive WINEMSYNC=1 vs =0 themselves; the helper must not clobber that).
bottle_shellenv() {
    local bottle_dir="$1"
    if [ -z "$bottle_dir" ] || [ ! -d "$bottle_dir" ]; then
        echo "bottle_shellenv: bottle directory not found: '$bottle_dir'" >&2
        return 1
    fi
    local wine_dir="$INSTALL_DIR/Wine"
    printf 'export PATH=%q\n' "$wine_dir/bin:$PATH"
    printf 'export WINEPREFIX=%q\n' "$bottle_dir"
    printf 'export DYLD_FALLBACK_LIBRARY_PATH=%q\n' "$wine_dir/lib"
    printf 'export WINEMSYNC_NO_ANON_AUTOEVENT=1\n'
}

# whisky_ncpu — parallelism for make/ninja (physical CPU count). A function, not
# a source-time variable, so sourcing stays subprocess-free per the header.
whisky_ncpu() { sysctl -n hw.ncpu; }

# require_tools <tool>... — exit with an error if any named tool is missing from
# PATH. The install hint names the brew formulae for the shared build tools
# (meson/ninja/mingw-w64); every build script needs some subset of these.
require_tools() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || {
            echo "ERROR: $t not found (brew install meson ninja mingw-w64)" >&2
            exit 1
        }
    done
}

# ccache policy. Enabled by DEFAULT — the x86_64 Wine/DXMT builds run gcc/clang
# under Rosetta (slow), so caching turns an incremental rebuild from tens of
# minutes into seconds. Disable per-build with `WHISKY_CCACHE=0` for the two
# scenarios where a fresh, cache-independent compile matters:
#   * distribution / reproducible release builds (guarantee no cache poisoning);
#   * ruling out a suspected stale-object bug in a hard-to-trace Wine regression.
# NOT a system-wide switch — scoped to one build invocation.
#
# whisky_ccache_on: true when ccache should wrap the compiler. gcc-wrapper builds
# (build-proton-x86.sh, which uses `env -i` so the CCACHE_DISABLE env can't reach
# the compiler) branch on this to pick `ccache gcc` vs plain `gcc`.
whisky_ccache_on() {
    [ "${WHISKY_CCACHE:-1}" != "0" ] && command -v ccache >/dev/null 2>&1
}

# whisky_ccache_guard: for meson/other builds that auto-detect ccache from PATH.
# Honors WHISKY_CCACHE=0 by exporting CCACHE_DISABLE (ccache then passes straight
# through to the real compiler). Call once, after sourcing, before meson runs.
whisky_ccache_guard() {
    if [ "${WHISKY_CCACHE:-1}" = "0" ]; then
        export CCACHE_DISABLE=1
        echo "=== ccache disabled (WHISKY_CCACHE=0) ==="
    fi
}
