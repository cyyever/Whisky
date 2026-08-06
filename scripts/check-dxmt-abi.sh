#!/usr/bin/env bash
#
# Verify the hand-aligned ABI between DXMT and our winemac.drv shim.
#
# DXMT reaches the Cocoa view behind an HWND by dlsym()ing winemac.drv's
# internal symbols -- there is no public Wine interface for "give me the Metal
# layer for this window", so patches/proton-wine/0009 exports a "macdrv_functions"
# table and a win_data struct in the layout DXMT expects. That contract is two
# struct definitions in two repositories with nothing tying them together: no
# shared header, no version field, no runtime handshake.
#
# A rename or a reordering on either side compiles silently and then calls the
# wrong function pointer at runtime. Every field is pointer-sized, so nothing
# catches it -- not the compiler, not the linker, not a crash near the cause.
# This compares the two field lists so a submodule bump that moves the contract
# stops the build instead.
#
# Names and order are what matter: the fields are all pointers, so a type change
# that keeps the name is harmless to the layout, while a reorder that keeps the
# types is fatal.
#
# Run standalone or via build-dxmt.sh. Exits non-zero on mismatch.
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DXMT_SRC="$PROJECT_DIR/vendor/dxmt/src/winemetal/unix/winemetal_unix.c"
SHIM_PATCH="$PROJECT_DIR/patches/proton-wine/0009-macos-dxmt-winemac-support.patch"

[ -f "$DXMT_SRC" ]   || { echo "ERROR: DXMT source missing ($DXMT_SRC). Run 'git submodule update --init'." >&2; exit 1; }
[ -f "$SHIM_PATCH" ] || { echo "ERROR: shim patch missing ($SHIM_PATCH)." >&2; exit 1; }

# Field names of a struct, in declaration order, one per line.
#   "void (*on_main_thread)(dispatch_block_t b);" -> on_main_thread
#   "macdrv_view client_cocoa_view;"              -> client_cocoa_view
# Reads from stdin so it can take either a source file or patch-added lines.
struct_fields() {  # <struct-name>
    awk -v want="$1" '
        $0 ~ "struct[ \t]+" want "[ \t]*(\\{)?[ \t]*$" { depth = 1; next }
        depth && /^[ \t]*\}/ { exit }
        depth {
            line = $0
            sub(/\/\*.*/, "", line)              # drop trailing comments
            if (line !~ /;/) next                # skip blank/comment-only lines
            if (match(line, /\(\*[A-Za-z_][A-Za-z0-9_]*\)/))
                print substr(line, RSTART + 2, RLENGTH - 3)   # function pointer
            else if (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*(\[[^]]*\])?[ \t]*;/))
                { f = substr(line, RSTART, RLENGTH); gsub(/[ \t;]|\[.*\]/, "", f); print f }
        }
    '
}

# Our side lives in the patch as added lines; strip the leading "+" so the same
# parser works. Reading the patch rather than the checked-out Wine tree means
# this check works before (and without) a Proton build.
shim_source() { sed -n 's/^+//p' "$SHIM_PATCH"; }

fail=0
compare() {  # <label> <dxmt-struct> <shim-struct>
    local label="$1" theirs mine
    theirs="$(struct_fields "$2" < "$DXMT_SRC")"
    mine="$(shim_source | struct_fields "$3")"

    if [ -z "$theirs" ]; then
        echo "ERROR: could not find 'struct $2' in DXMT ($DXMT_SRC)." >&2
        echo "       Upstream may have restructured it; re-check patch 0009 by hand." >&2
        fail=1
        return
    fi
    if [ -z "$mine" ]; then
        echo "ERROR: could not find 'struct $3' in $SHIM_PATCH." >&2
        fail=1
        return
    fi

    if [ "$theirs" = "$mine" ]; then
        echo "  ok  $label ($(echo "$theirs" | wc -l | tr -d ' ') fields)"
    else
        echo "  MISMATCH  $label" >&2
        echo "  --- DXMT: struct $2" >&2
        echo "  +++ ours: struct $3 (patches/proton-wine/0009)" >&2
        diff <(echo "$theirs") <(echo "$mine") | sed 's/^/    /' >&2
        fail=1
    fi
}

echo "=== Checking DXMT <-> winemac.drv shim ABI ==="
compare "macdrv_functions table" macdrv_functions_t dxmt_macdrv_functions
compare "win_data struct"        macdrv_win_data    dxmt_win_data

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

DXMT's expectations no longer match patch 0009. Do NOT ship this build: every
field is pointer-sized, so a mismatch calls the wrong function rather than
failing loudly, and the symptom will surface far from the cause.

Fix patches/proton-wine/0009-macos-dxmt-winemac-support.patch to match the
field list above, then rebuild with `make proton && make dxmt`.
EOF
    exit 1
fi
echo "=== ABI matches ==="
