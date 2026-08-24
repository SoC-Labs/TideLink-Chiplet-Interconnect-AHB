#!/usr/bin/env bash
# =============================================================================
# xhb500_tree_digest.sh — provenance gate for deps/xhb500/generated
# =============================================================================
#
# THE PROBLEM THIS EXISTS TO CLOSE
# --------------------------------
# deps/xhb500/generated is ~2626 files / ~195 MB of vendor-GENERATED RTL. It is
# gitignored (.gitignore: "deps/xhb500/generated", under "# Generated IP (from
# set_env.sh)"), nothing under it is tracked, and deps/xhb500 is not a submodule
# — docs/BUILD_REGISTRY.yaml says it in its own words: "versioned by nothing".
#
# Four tracked flists nonetheless source 32 files each out of that tree, and one
# of them is the TAPEOUT netlist selector (flists/tidelink_top_full_asic_v2.flist,
# via syn/asic/fusion-compiler/Makefile). Among those 32 is
# xhb500_ahb_to_axi_bridge_chiplet_slv_hazard_list.sv — the settled root cause of
# the D2D peer-write wedge and the subject of the shipping errata.
#
# So the build's only cleanliness oracle is blind to it. `git_dirty` in the FPGA
# manifest is literally `git status --porcelain` non-empty
# (fpga/scripts/build_provenance.tcl, proc tl_git_sha), which by construction
# cannot see an ignored path. A tree with the ENTIRE dependency absent, or
# silently divergent, stamps git_dirty:false. That is not hypothetical: the
# worktree this gate was written in had the whole 195 MB missing and reported a
# clean status.
#
# Regeneration does not close it either. set_env.sh treats a generation as
# complete when ONE file out of 2626 exists (logical/models/cells/generic/
# xhb500_flop.sv), so a truncated rsync (fpga/scripts/farm_build.sh copies the
# tree between hosts rather than regenerating), a tree from a different
# XHB500_IP_DIR, or a run under an out-of-range python all report "[skip]" and
# pass forever.
#
# WHY A DIGEST AND NOT TRACKING THE TREE
# --------------------------------------
# Tracking it was considered and REJECTED, not on size grounds but on licensing:
# this repository is public (see the Publication guard in the top-level
# Makefile), and the tree is licensed Arm vendor RTL. Committing it would be a
# far worse defect than the one being fixed. A digest pins the bytes without
# republishing them.
#
# For the same reason this file records NO vendor release name. The release
# identifier is a revision-coded vendor inventory string — precisely the class
# `make vendor-check` exists to keep out of a public tree. The digest identifies
# the release exactly, and identifies it better, without naming it.
#
# WHAT IS RECORDED
# ----------------
# deps/xhb500/TREE.sha256, tracked, two parts:
#
#   * tree_digest / file_count / total_bytes — the whole tree in one line, so
#     ANY divergence anywhere is caught.
#   * per-file sha256 for the 32 files the tracked flists actually name. Those
#     paths are ALREADY published in flists/, so this discloses nothing new, and
#     they are exactly the surface that reaches the netlist. They exist to make
#     a failure ACTIONABLE: "the tree differs" is not a useful error, "these 3
#     of the 32 ship files differ" is.
#
# USAGE
#   scripts/xhb500_tree_digest.sh            verify (default). Non-zero on any
#                                            mismatch, and on a missing tree.
#   scripts/xhb500_tree_digest.sh --update   rewrite the record from the tree on
#                                            disk. A DELIBERATE act: it is how a
#                                            vendor-release change is accepted,
#                                            and it belongs in its own commit
#                                            that says which release and why.
#   scripts/xhb500_tree_digest.sh --print    print the computed digest only.
#
# Env: TIDELINK_HOME (default: the repo this script lives in),
#      XHB500_GEN_DIR (default: $TIDELINK_HOME/deps/xhb500/generated).
# =============================================================================
set -u
set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${TIDELINK_HOME:=$(cd "$SELF_DIR/.." && pwd)}"
: "${XHB500_GEN_DIR:=$TIDELINK_HOME/deps/xhb500/generated}"
RECORD="$TIDELINK_HOME/deps/xhb500/TREE.sha256"

MODE="verify"
case "${1:-}" in
    --update) MODE="update" ;;
    --print)  MODE="print"  ;;
    "")       ;;
    *) echo "usage: $(basename "$0") [--update|--print]" >&2; exit 2 ;;
esac

say()  { printf '[xhb500] %s\n' "$*"; }
die()  { printf '[xhb500] ERROR: %s\n' "$*" >&2; exit 1; }

# --- the tree must be there at all -------------------------------------------
if [ ! -d "$XHB500_GEN_DIR" ]; then
    cat >&2 <<EOF
[xhb500] ERROR: the XHB500 generated tree is MISSING.

  looked for: $XHB500_GEN_DIR

  Four flists — including the tapeout selector
  flists/tidelink_top_full_asic_v2.flist — source 32 files from this path. It is
  gitignored, so \`git status\` is CLEAN without it and the build manifest would
  stamp git_dirty:false on a tree that cannot be built.

  Fix: source ./set_env.sh, which regenerates it from XHB500_IP_DIR.
EOF
    exit 1
fi

# Resolve the directory itself before walking it. This path HAS been a symlink in
# this repo's history -- 5e8bdb5a exists because deps/xhb500/generated was tracked
# as a mode-120000 link into an ungoverned tree -- and `find -P <symlink>` lists
# nothing, which would report an empty tree rather than the tree it points at.
# Resolving here keeps -P's loop-safety for everything INSIDE the tree.
XHB500_GEN_DIR="$(cd "$XHB500_GEN_DIR" && pwd -P)" || die "cannot enter $XHB500_GEN_DIR"

# --- compute ------------------------------------------------------------------
# find -P, NOT -L: a previous untracking left a self-referential symlink
# (deps/xhb500/generated/generated -> its own parent) in at least one checkout,
# and -L walks that forever. -P also means a symlinked file is hashed as a link
# target's content only if find lists it as a regular file, which -P will not do.
# LC_ALL=C so the sort order is byte order on every host.
compute() {
    ( cd "$XHB500_GEN_DIR" && \
      find -P . -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum -- \
        | sed 's#\*\?\./##' )
}

FILELIST="$(mktemp)"; trap 'rm -f "$FILELIST"' EXIT
compute > "$FILELIST" || die "hashing failed under $XHB500_GEN_DIR"

N_FILES="$(wc -l < "$FILELIST" | tr -d ' ')"
[ "$N_FILES" -gt 0 ] || die "no regular files found under $XHB500_GEN_DIR"
N_BYTES="$(find -P "$XHB500_GEN_DIR" -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}')"
TREE_DIGEST="$(LC_ALL=C sort "$FILELIST" | sha256sum | awk '{print $1}')"

if [ "$MODE" = "print" ]; then
    printf 'tree_digest %s\nfile_count %s\ntotal_bytes %s\n' \
        "$TREE_DIGEST" "$N_FILES" "$N_BYTES"
    exit 0
fi

# --- the ship files: whatever the tracked flists name, discovered not hardcoded
ship_paths() {
    grep -rhoE 'deps/xhb500/generated/[^ ]+' "$TIDELINK_HOME/flists/" 2>/dev/null \
        | sed 's#.*deps/xhb500/generated/##' \
        | LC_ALL=C sort -u
}

# =============================================================================
if [ "$MODE" = "update" ]; then
    tmp="$(mktemp)"
    {
        cat <<EOF
# XHB500 generated-tree provenance record  —  scripts/xhb500_tree_digest.sh
#
# deps/xhb500/generated is gitignored vendor-GENERATED RTL that the shipping
# flists hard-depend on, so a "clean" git status says nothing about it. This
# file is what pins it. Verify with:  make xhb500-check
#
# DELIBERATELY RECORDS NO VENDOR RELEASE NAME. A revision-coded release string is
# the vendor-inventory disclosure class that \`make vendor-check\` keeps out of
# this public repository; the digest identifies the release exactly without
# naming it. Put the human-readable release in your private site notes.
#
# Regenerate ONLY when a vendor-release change is intended, in its own commit:
#     scripts/xhb500_tree_digest.sh --update
EOF
        printf 'tree_digest %s\n' "$TREE_DIGEST"
        printf 'file_count %s\n'  "$N_FILES"
        printf 'total_bytes %s\n' "$N_BYTES"
        echo   '#'
        echo   '# Per-file digests for the files the tracked flists name. These paths are'
        echo   '# already published in flists/, so nothing new is disclosed here; they are'
        echo   '# listed so a mismatch names the offending file instead of the whole tree.'
        ship_paths | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            if [ -f "$XHB500_GEN_DIR/$rel" ]; then
                printf 'ship %s  %s\n' "$(sha256sum "$XHB500_GEN_DIR/$rel" | awk '{print $1}')" "$rel"
            else
                printf 'ship MISSING  %s\n' "$rel"
            fi
        done
    } > "$tmp"
    mv "$tmp" "$RECORD"
    say "recorded $N_FILES files, $N_BYTES bytes"
    say "tree_digest $TREE_DIGEST"
    say "wrote $RECORD"
    exit 0
fi

# =============================================================================
# verify
[ -f "$RECORD" ] || die "no provenance record at $RECORD — run: $0 --update"

want_digest="$(awk '$1=="tree_digest"{print $2}' "$RECORD")"
want_files="$(awk  '$1=="file_count"{print $2}'  "$RECORD")"
want_bytes="$(awk  '$1=="total_bytes"{print $2}' "$RECORD")"
[ -n "$want_digest" ] || die "$RECORD carries no tree_digest — run: $0 --update"

if [ "$TREE_DIGEST" = "$want_digest" ]; then
    say "OK  tree_digest $TREE_DIGEST  ($N_FILES files, $N_BYTES bytes)"
    exit 0
fi

# --- loud, and specific -------------------------------------------------------
{
    echo ""
    echo "==============================================================="
    echo " XHB500 GENERATED TREE DOES NOT MATCH THE RECORDED PROVENANCE"
    echo "==============================================================="
    echo ""
    echo "  tree:     $XHB500_GEN_DIR"
    echo "  record:   $RECORD"
    echo ""
    printf "  tree_digest  recorded %s\n" "$want_digest"
    printf "               ON DISK  %s\n" "$TREE_DIGEST"
    printf "  file_count   recorded %-10s on disk %s\n" "$want_files" "$N_FILES"
    printf "  total_bytes  recorded %-10s on disk %s\n" "$want_bytes" "$N_BYTES"
    echo ""

    ndiff=0; nmiss=0
    while read -r tag want rel; do
        [ "$tag" = "ship" ] || continue
        f="$XHB500_GEN_DIR/$rel"
        if [ ! -f "$f" ]; then
            [ "$nmiss" -eq 0 ] && echo "  SHIP FILES MISSING (named by tracked flists):"
            echo "    - $rel"
            nmiss=$((nmiss+1))
        else
            got="$(sha256sum "$f" | awk '{print $1}')"
            if [ "$got" != "$want" ]; then
                [ "$ndiff" -eq 0 ] && echo "  SHIP FILES DIFFERING (these reach the netlist):"
                echo "    ! $rel"
                ndiff=$((ndiff+1))
            fi
        fi
    done < "$RECORD"

    if [ "$ndiff" -eq 0 ] && [ "$nmiss" -eq 0 ]; then
        echo "  All flist-named ship files MATCH. The divergence is elsewhere in the"
        echo "  tree (generator version, unused collateral, or added/removed files)."
        echo "  It is still a divergence: this build is not the recorded one."
    else
        echo ""
        echo "  $ndiff differing, $nmiss missing, out of the flist-named ship files."
    fi

    cat <<'EOF'

  WHAT THIS MEANS
    The XHB500 bridge RTL compiled into this build is not the RTL the record
    pins. Because that tree is gitignored, no git status, no `git_dirty` flag and
    no freeze SHA would have told you.

  WHAT TO DO
    * Unintended (stale/partial tree, wrong host, half-finished rsync):
        rm -rf deps/xhb500/generated && source ./set_env.sh
      set_env.sh only regenerates when the tree is absent — it treats ONE file's
      presence as "already generated", so deleting it is the way to force a
      clean regeneration.
    * Intended (a deliberate vendor-release change):
        scripts/xhb500_tree_digest.sh --update
      in its OWN commit, stating which release and why. Do not fold it into an
      unrelated change: this is the only pin the tapeout flists have.
EOF
    echo ""
} >&2
exit 1
