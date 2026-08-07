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

# Where the build payloads land (Wine, DXVK, DXMT, ProxyChains, version plist).
INSTALL_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"

# x86_64 Homebrew (installed by setup-x86-brew.sh) — provides the libraries
# linked into x86_64 Wine. Build tools come from the ARM64 brew.
X86_BREW_HOME="$PROJECT_DIR/vendor/homebrew-x86"
X86_BREW="$X86_BREW_HOME/bin/brew"

# Branch maintenance (scripts/proton-branch.sh): when a vendored tree is checked
# out on WHISKY_PATCH_BRANCH, the patch series is committed one commit per patch
# file on top of WHISKY_PATCH_BASE, and apply_patches() steps aside.
WHISKY_PATCH_BRANCH="whisky/patches"
WHISKY_PATCH_BASE="whisky/base"

# Every compile here runs under Rosetta, and the cc driver shells out to xcrun,
# which dlopens libxcrun from the *active* developer dir. A Command Line Tools
# install ships an arm64-only one, so x86_64 xcrun dies there with "missing
# compatible architecture" and configure fails at "C compiler cannot create
# executables". Xcode.app's copy is fat, so prefer it -- through the environment,
# since `xcode-select -s` needs sudo and would change the machine globally.
#
# Always resolved to a concrete path, never left unset: the builds run configure
# and make inside `env -i` clean rooms that pass an explicit allowlist, and a
# conditionally-absent variable cannot be expanded into one safely.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null)"
    if ! lipo -archs "$DEVELOPER_DIR/usr/lib/libxcrun.dylib" 2>/dev/null | grep -q x86_64 &&
       [ -d /Applications/Xcode.app/Contents/Developer ]
    then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
export DEVELOPER_DIR

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
# a conflict or partial apply. A no-op if patch_dir does not exist, or if
# src_dir is checked out on WHISKY_PATCH_BRANCH (see below). Pass a non-empty
# 4th argument to `git checkout -- .` first, giving a deterministic clean base
# (discards uncommitted working-tree edits in src_dir).
apply_patches() {
    local src_dir="$1" patch_dir="$2" label="$3" reset="${4:-}"
    [ -d "$patch_dir" ] || return 0

    # A branch-maintained tree already has the whole series applied, as commits,
    # so there is nothing to do -- and the loop below could not do it anyway. Its
    # "is this applied?" test reverse-checks one patch against the working tree,
    # which cannot hold once a later patch edits a file an earlier one CREATES:
    # 0008 creates dlls/ntdll/unix/msync_*.c, 0010 adds the MRING tracer to them,
    # so 0008's new-file section never matches what is on disk. That test only
    # ever held because `reset` guaranteed an unpatched base, and reset is itself
    # a no-op here -- the patched state is committed, not a working-tree edit.
    if [ "$(git -C "$src_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$WHISKY_PATCH_BRANCH" ]; then
        local n dirty
        n="$(git -C "$src_dir" rev-list --count "$WHISKY_PATCH_BASE..HEAD" 2>/dev/null || echo '?')"
        echo "=== $label: branch-maintained ($WHISKY_PATCH_BRANCH, $n commits); not applying $(basename "$patch_dir")/ ==="
        dirty="$(git -C "$src_dir" status --porcelain | wc -l | tr -d ' ')"
        [ "$dirty" = 0 ] || echo "    NOTE: $dirty uncommitted file(s) -- building them, but they" \
                                 "reach $(basename "$patch_dir")/ only via commit + proton-branch.sh export"
        return 0
    fi

    if [ -n "$reset" ]; then
        git -C "$src_dir" checkout -- .
        # checkout -- . only reverts tracked files; untracked files created by add-file
        # patches (e.g. msync_*.c/.h, server/msync.c) linger and make a re-apply hit
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

# --- x86_64 Wine configure/toolchain (shared by the two Wine builds) ----------
# build-proton-x86.sh (the shipping Proton build) and build-msync-tests.sh (the
# msync test-PE build) reconfigure the SAME vendor/proton-wine/build tree with an
# identical env/toolchain clean room and an identical configure flag list — the
# ONLY difference is that proton passes --disable-tests and the test build does
# not. These helpers own that shared block so the two can never drift; each is
# pure (echoes a value, no side effects) except wine_configure, which cds + runs
# configure. Callers still keep their own X86_PREFIX/ARM_BREW_PREFIX/CLEAN_PATH
# where they need them for OTHER steps (dylib bundling, the make PATH, strip).

# wine_clean_path — echo the PATH for the x86_64 Wine configure+make. bison is
# keg-only (macOS ships an old one) so its keg bin leads; build tools otherwise
# come from the ARM64 brew, the x86 brew bin trails (only its linked libraries
# matter, reached via PKG_CONFIG_PATH in wine_configure), then the system dirs.
wine_clean_path() {
    local x86_prefix arm_prefix
    x86_prefix=$(arch -x86_64 "$X86_BREW" --prefix)
    arm_prefix="$(brew --prefix)"
    echo "$arm_prefix/opt/bison/bin:$arm_prefix/bin:$x86_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

# wine_cc_cmd / wine_cxx_cmd — echo the C/C++ compiler command for the x86_64
# Wine build, wrapped in ccache when whisky_ccache_on (the default). Pure: no
# banner on stdout so they are safe in $(...) — wine_configure prints the ccache
# status line itself.
wine_cc_cmd()  { if whisky_ccache_on; then echo "ccache gcc"; else echo "gcc"; fi; }
wine_cxx_cmd() { if whisky_ccache_on; then echo "ccache g++"; else echo "g++"; fi; }

# wine_configure <build_dir> [extra_configure_flags...] — cd into build_dir and
# run Wine's ../configure for the x86_64/Rosetta build inside an `env -i` clean
# room. The env/toolchain block and the flag list are IDENTICAL for both callers;
# the extra flags are the only divergence (proton passes --disable-tests, the
# msync test build passes none). Extra flags are emitted right after
# --without-gstreamer — exactly where --disable-tests sat in the original proton
# command — so the generated configure line stays byte-for-byte identical to the
# pre-refactor invocation in BOTH callers. (An empty "$@" expands to zero words,
# so the test build gets the list with nothing inserted there.)
# NOTE: cds into build_dir; the cwd persists to the caller's subsequent `make`.
wine_configure() {
    local build_dir="$1"; shift
    local x86_prefix arm_prefix clean_path cc_cmd cxx_cmd
    x86_prefix=$(arch -x86_64 "$X86_BREW" --prefix)
    arm_prefix="$(brew --prefix)"
    clean_path="$(wine_clean_path)"
    cc_cmd="$(wine_cc_cmd)"
    cxx_cmd="$(wine_cxx_cmd)"
    if whisky_ccache_on; then
        echo "=== Using ccache (WHISKY_CCACHE=0 to disable) ==="
    fi
    cd "$build_dir"
    arch -x86_64 env -i \
        HOME="$HOME" \
        PATH="$clean_path" \
        DEVELOPER_DIR="$DEVELOPER_DIR" \
        CC="$cc_cmd" \
        CXX="$cxx_cmd" \
        PKG_CONFIG="$arm_prefix/bin/pkg-config" \
        PKG_CONFIG_PATH="$x86_prefix/lib/pkgconfig:$x86_prefix/share/pkgconfig:$PROJECT_DIR/vendor/ffmpeg-x86/lib/pkgconfig" \
        PKG_CONFIG_LIBDIR="$x86_prefix/lib/pkgconfig:$x86_prefix/share/pkgconfig:$PROJECT_DIR/vendor/ffmpeg-x86/lib/pkgconfig" \
        SDL2_CFLAGS="-I$x86_prefix/include/SDL2 -D_THREAD_SAFE" \
        SDL2_LIBS="-L$x86_prefix/lib -lSDL2" \
        LDFLAGS="-L$x86_prefix/lib -L$x86_prefix/opt/molten-vk/lib" \
        `# NOTE: no -O here, so the unix side (ntdll.so, winemac.drv.so, ...) builds` \
        `# unoptimised: setting CFLAGS at all suppresses autoconf's default -g -O2,` \
        `# and nothing puts it back. The PE side still gets -O2 from Wine's own` \
        `# configure. Left as-is on purpose while the msync hang is being chased --` \
        `# an optimised build makes sample(1) stacks much harder to read. Add -O2` \
        `# once that closes, and re-run scripts/test-msync.sh afterwards, since -O2` \
        `# changes atomics scheduling and can shake out races -O0 hides.` \
        CFLAGS="-I$x86_prefix/include -I$x86_prefix/opt/freetype/include/freetype2 -I$x86_prefix/opt/molten-vk/include" \
        CPPFLAGS="-I$x86_prefix/include -I$x86_prefix/opt/freetype/include/freetype2 -I$x86_prefix/opt/molten-vk/include" \
        ../configure \
            --enable-archs=i386,x86_64 \
            --with-vulkan \
            --without-gstreamer \
            "$@" \
            --disable-win16 \
            --without-x \
            --without-cups \
            --without-krb5 \
            --without-gssapi \
            --without-pcap \
            --without-pcsclite
}
