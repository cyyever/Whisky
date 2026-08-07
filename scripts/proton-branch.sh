#!/usr/bin/env bash
set -euo pipefail

# Maintain patches/proton-wine/ as a branch of commits in vendor/proton-wine
# instead of editing patch files by hand.
#
# WHY. The patch files stay the source of truth for a fresh clone -- vendor/
# proton-wine is gitignored, laid down from a tarball, so a checkout has only the
# patches. But editing them directly does not scale: patch 0008 CREATES its files
# (`--- /dev/null`), so a change to one of them means rewriting a whole new-file
# section, and splitting a change across patches means reproducing, by hand, the
# state each patch sees. That was previously scripted by matching literal source
# text to peel one layer off another, which broke every time the code it anchored
# on was edited. Commits already express "a stack of changes, each seeing the
# previous one applied", so let git do it.
#
# WORKFLOW
#   scripts/proton-branch.sh init      once: replay the series onto a branch
#   ...edit vendor/proton-wine, commit to the branch, or `git commit --amend`,
#      or `git rebase -i whisky/base` to move a hunk between patches...
#   scripts/proton-branch.sh export    write the commits back to patches/
#   scripts/proton-branch.sh status    where things stand
#
# The build follows the tree: apply_patches() in lib/common.sh sees the branch
# checked out and applies nothing, so what gets built is the branch, and patches/
# only matters again after 'export'. (It cannot do anything else -- its per-patch
# reverse-check is unusable on a series where 0010 edits files 0008 creates.)

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

WINE_SRC="${WINE_SRC:-$PROJECT_DIR/vendor/proton-wine}"
PATCH_DIR="$PROJECT_DIR/patches/proton-wine"
BRANCH="$WHISKY_PATCH_BRANCH"   # shared with apply_patches(), which steps aside on it
BASE_REF="$WHISKY_PATCH_BASE"

g() { git -C "$WINE_SRC" "$@"; }

die() { echo "ERROR: $*" >&2; exit 1; }

# For export. Only tracked edits matter -- those are changes that would silently
# not reach patches/, since export writes commits, not the working tree. Untracked
# files are almost always build products (the generator bootstrap leaves a dozen),
# so they get a note rather than a refusal.
require_committed() {
    [ -z "$(g status --porcelain --untracked-files=no)" ] || die "vendor/proton-wine has uncommitted changes to tracked files.

       export writes commits, not the working tree, so these would be left behind.
       Put them on $BRANCH first -- as a new commit, or folded into the patch they
       belong to with 'git commit --amend' / 'git commit --fixup=<sha>' plus
       'git rebase --autosquash $BASE_REF'."
    local n
    n="$(g ls-files --others --exclude-standard | wc -l | tr -d ' ')"
    [ "$n" = 0 ] || echo "  NOTE: $n untracked file(s), not exported -- build products, unless you" \
                         "added a source file and have not 'git add'ed it"
}

# For init, which replays the series with `git am` onto a pristine base: untracked
# files DO matter there, since an add-file patch hits "already exists".
require_clean() {
    [ -z "$(g status --porcelain)" ] || die "vendor/proton-wine has uncommitted changes.

       Before 'init' the tree is patch-applied, so it is ALWAYS dirty. Capture
       anything you care about into patches/proton-wine/ first, then reset:
           cd vendor/proton-wine && git checkout -- . && git clean -fdq
       'init' replays the patch series back as commits, so nothing is lost --
       but only what is in the patch files is replayed."
}

# git format-patch emits a mail envelope; the series in patches/ uses a plainer
# shape (Subject:, blank line, body, blank line, diff). Convert between them here
# so switching to branch maintenance does not rewrite all 20-odd patch files.
normalise() {
    awk '
        function flush_subject() {
            if (subject != "") { print subject; subject = "" }
            folding = 0; dropping = 0
        }
        in_diff { print; next }
        /^diff --git / { flush_subject(); in_diff = 1; print ""; print; next }

        /^From [0-9a-f]+ / { next }                        # mbox separator
        /^(From|Date): / { dropping = 1; next }            # authorship lives in git, not the file
        /^X-Patch-File: / { dropping = 1; next }           # bookkeeping for export, not content
        /^Subject: / { flush_subject(); subject = $0; folding = 1; next }

        # An RFC-2822 continuation line. format-patch folds a Subject past 78
        # columns onto one of these; unfold it, or a plain init/export round trip
        # reflows the file with no change to the patch it carries.
        /^[ \t]/ && folding { sub(/^[ \t]+/, " "); subject = subject $0; next }
        /^[ \t]/ && dropping { next }

        $0 == "---" { next }                               # format-patch body/diff separator
        /^$/ { flush_subject(); pending = 1; next }        # collapse blanks before the diff
        { flush_subject(); if (pending) { print ""; pending = 0 } ; print }
    '
}

cmd_init() {
    [ -d "$WINE_SRC/.git" ] || die "no git repo at $WINE_SRC"
    require_clean
    g rev-parse --verify --quiet "$BRANCH" >/dev/null && \
        die "$BRANCH already exists. Delete it first if you really mean to re-init."

    local base
    base="$(g rev-parse HEAD)"
    echo "=== base: $(g log --oneline -1 "$base") ==="
    g tag -f "$BASE_REF" "$base" >/dev/null
    g checkout -q -b "$BRANCH" "$base"

    # Most patches carry only a Subject:, no From:. git am takes the author from
    # the mail rather than falling back to the config, and an absent From: parses
    # as an empty ident, which it refuses. Synthesise one from this repo's config
    # for the patches that lack it, rather than churning a From: into every file.
    local ident
    ident="$(g config user.name) <$(g config user.email)>"
    [ "$ident" != " <>" ] || die "set user.name/user.email in $WINE_SRC first"

    local p n tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT
    for p in "$PATCH_DIR"/*.patch; do
        n="$(basename "$p")"
        if grep -q "^From: " "$p"; then
            cp "$p" "$tmp/mail"
        else
            { printf 'From: %s\n' "$ident"; cat "$p"; } > "$tmp/mail"
        fi
        # -k keeps the Subject line verbatim (no [PATCH] wrapping/unwrapping)
        if ! g am -k --keep-non-patch "$tmp/mail" >/dev/null 2>&1; then
            g am --abort >/dev/null 2>&1 || true
            die "git am failed on $n -- it is probably not in Subject:/body/diff form"
        fi
        # remember which file this commit came from, so export can write it back
        # blank line before the trailer, so dropping it on export leaves the
        # body/diff spacing the hand-written patches use
        g commit -q --amend --no-edit -m "$(g log -1 --format=%B)

X-Patch-File: $n"
        echo "  applied $n"
    done
    echo "=== $BRANCH now has $(g rev-list --count "$BASE_REF..$BRANCH") commits ==="
    echo "Next: edit, commit, then 'scripts/proton-branch.sh export'."
}

cmd_export() {
    g rev-parse --verify --quiet "$BRANCH" >/dev/null || die "$BRANCH does not exist; run 'init' first"
    require_committed

    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT
    g format-patch -k --no-signature --no-stat --no-numbered \
        -o "$tmp" "$BASE_REF..$BRANCH" >/dev/null

    local f name out written=0 unnamed=0
    for f in "$tmp"/*.patch; do
        name="$(awk '/^X-Patch-File: /{print $2; exit}' "$f")"
        if [ -z "$name" ]; then
            # a commit added on the branch, with no recorded filename
            name="$(basename "$f")"
            unnamed=$((unnamed + 1))
            echo "  NOTE: new commit exported as $name (no X-Patch-File trailer)"
        fi
        out="$PATCH_DIR/$name"
        normalise < "$f" > "$out.new"
        if [ -f "$out" ] && cmp -s "$out" "$out.new"; then
            rm -f "$out.new"
        else
            mv "$out.new" "$out"
            echo "  wrote $name"
            written=$((written + 1))
        fi
    done
    echo "=== exported: $written changed, $unnamed unnamed ==="
}

cmd_status() {
    if ! g rev-parse --verify --quiet "$BRANCH" >/dev/null; then
        echo "branch:  $BRANCH does not exist (tree is patch-applied, not branch-maintained)"
        return
    fi
    echo "branch:  $BRANCH ($(g rev-list --count "$BASE_REF..$BRANCH") commits on $(g log --oneline -1 "$BASE_REF"))"
    echo "HEAD:    $(g rev-parse --abbrev-ref HEAD)"
    local dirty; dirty="$(g status --porcelain | wc -l | tr -d ' ')"
    echo "tree:    $([ "$dirty" = 0 ] && echo clean || echo "$dirty uncommitted file(s)")"
}

case "${1:-}" in
    init)   cmd_init ;;
    export) cmd_export ;;
    status) cmd_status ;;
    *) echo "usage: $(basename "$0") {init|export|status}" >&2; exit 2 ;;
esac
