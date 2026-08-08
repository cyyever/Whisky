# Shared bottle discovery for the audit scripts under tests/.
#
# Source it, then call `select_bottles "$@"`:
#
#     . "$(dirname "$0")/lib/bottles.sh"
#     select_bottles "$@"
#     for bottle in "${bottles[@]}"; do ... done
#
# With an argument, that one bottle is checked; with none, every bottle is.
# `bottles` comes back as an array, and the "no bottles at all" case has already
# exited 0 (SKIP) — a machine with no bottles is not a failing machine, and an
# audit that fails there is an audit people learn to ignore.
#
# The container id lives here rather than in each script: it moved once already
# (the bundle identifier is inherited from upstream Whisky), and a stale copy
# makes a script silently pass by finding nothing to check.

BOTTLES_DIR="${BOTTLES_DIR:-$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles}"

select_bottles() {
    if [ $# -ge 1 ]; then
        bottles=("$1")
    else
        bottles=()
        for b in "$BOTTLES_DIR"/*/; do [ -d "$b/drive_c" ] && bottles+=("${b%/}"); done
    fi

    if [ ${#bottles[@]} -eq 0 ]; then
        echo "SKIP: no bottles found under $BOTTLES_DIR"
        exit 0
    fi

    # An explicit argument that is not a bottle is a caller mistake, not a skip.
    for b in "${bottles[@]}"; do
        [ -d "$b/drive_c" ] || { echo "ERROR: not a bottle: $b" >&2; exit 2; }
    done
}
