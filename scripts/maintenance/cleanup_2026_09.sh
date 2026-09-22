#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# cleanup_2026_09.sh — the 2026-09 repository cleanup, INERT BY DEFAULT.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Companion to docs/CLEANUP_PLAN_2026-09.md, which states for every item what
# it is, the evidence it is safe, and what breaks if that evidence is wrong.
# READ IT FIRST. This script is the plan's executable half and carries only
# the items the plan calls PROVEN SAFE. Everything uncertain is in the plan's
# "Needs a human decision" section and is deliberately absent from here.
#
#   ./scripts/maintenance/cleanup_2026_09.sh              # print, change nothing
#   ./scripts/maintenance/cleanup_2026_09.sh --execute    # actually do it
#   ./scripts/maintenance/cleanup_2026_09.sh --only tags  # one phase
#
# SAFETY RULES, enforced at run time rather than trusted from this file:
#
#   1. --execute is required. With no flag every action is printed and none
#      is taken, and the exit code is 0.
#   2. A dirty working tree aborts the run. Uncommitted work plus branch
#      deletion is how work disappears.
#   3. EVERY deletion is preceded by `git tag archive/2026-09/<name> <sha>`,
#      and the tag is verified to exist and to point at that sha before the
#      delete runs. No tag, no delete.
#   4. A branch is deleted ONLY if `git merge-base --is-ancestor <branch>
#      origin/main` succeeds AT RUN TIME. The list below is a plan, not a
#      permission: each entry is re-proved against the live origin/main.
#   5. A branch checked out in a worktree is never deleted, and a worktree
#      with any uncommitted change is never removed.
#   6. origin/main is re-fetched first, so "merged" means merged into what is
#      on the server now, not into a week-old remote-tracking ref.
#
# Exit: 0 all good (or a clean dry run), 1 something was refused, 2 the
# script could not establish its preconditions.
#-----------------------------------------------------------------------------
set -uo pipefail

EXECUTE=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --execute) EXECUTE=1; shift ;;
        --only)    ONLY="${2:?--only needs a phase name}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "cleanup_2026_09.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 2
TAG_NS="archive/2026-09"
refused=0

# ── Output helpers ──────────────────────────────────────────────────────────
say()   { printf '%s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }
skip()  { printf '   SKIP  %s\n' "$*"; }
note()  { printf '   note  %s\n' "$*"; }
refuse(){ printf '   REFUSED  %s\n' "$*"; refused=$((refused+1)); }

# run <description> <command...>
run() {
    local what="$1"; shift
    if [ "$EXECUTE" -eq 1 ]; then
        if "$@" >/dev/null 2>&1; then printf '   done  %s\n' "$what"; return 0
        else printf '   FAILED %s\n            (%s)\n' "$what" "$*"; refused=$((refused+1)); return 1; fi
    else
        printf '   would %s\n            $ %s\n' "$what" "$*"
    fi
}

phase() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ── Preconditions ───────────────────────────────────────────────────────────
head_ "Preconditions"

git rev-parse --git-dir >/dev/null 2>&1 || { say "   not a git checkout"; exit 2; }

DIRTY="$(git status --porcelain | wc -l)"
if [ "$DIRTY" -ne 0 ]; then
    say "   working tree is DIRTY ($DIRTY path(s))."
    say "   Refusing: deleting branches beside uncommitted work is how work is lost."
    say "   Commit, stash, or run this from a clean checkout."
    git status --porcelain | head -10 | sed 's/^/     /'
    exit 2
fi
say "   working tree clean"

if [ "$EXECUTE" -eq 1 ]; then
    git fetch origin --prune --quiet || { say "   could not fetch origin"; exit 2; }
    say "   fetched origin"
else
    note "dry run: skipping 'git fetch origin' (it writes remote-tracking refs)"
fi
MAIN="$(git rev-parse --verify -q origin/main)" || { say "   no origin/main"; exit 2; }
say "   origin/main = ${MAIN:0:8}"
[ "$EXECUTE" -eq 1 ] && say "   MODE: EXECUTE — changes will be made" \
                     || say "   MODE: dry run — nothing will change (pass --execute to act)"

# Branches that are checked out somewhere: never deletable.
CHECKED_OUT="$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')"
is_checked_out() { printf '%s\n' "$CHECKED_OUT" | grep -qx -- "$1"; }

# ── Tag helper: rule 3, no tag no delete ────────────────────────────────────
archive_tag() {           # archive_tag <name> <sha>  -> 0 if the tag is safe
    local name="$1" sha="$2" tag="$TAG_NS/$1"
    local have; have="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)"
    if [ -n "$have" ]; then
        if [ "$have" = "$(git rev-parse "$sha^{commit}")" ]; then
            note "tag $tag already present and correct"; return 0
        fi
        refuse "tag $tag exists but points at ${have:0:8}, not ${sha:0:8} — resolve by hand"
        return 1
    fi
    run "tag $tag -> ${sha:0:8}" git tag "$tag" "$sha" || return 1
    if [ "$EXECUTE" -eq 1 ]; then
        [ "$(git rev-parse -q --verify "refs/tags/$tag^{commit}")" = "$(git rev-parse "$sha^{commit}")" ] \
            || { refuse "tag $tag did not land — refusing any delete that depended on it"; return 1; }
    fi
    return 0
}

#=============================================================================
# PHASE 1 — Archive tags for work that exists NOWHERE ELSE.
#
# Tag only. Nothing here is deleted by this script, today or ever: these tips
# are not on origin, so a tag in one local repository is the only copy. The
# plan's instruction is to PUSH them and then decide.
#=============================================================================
if phase tags; then
head_ "Phase 1 — archive tags for local-only, unmerged work (NO deletion)"

# Re-derived at run time rather than hard-coded: a branch that has since been
# pushed should stop being reported as local-only.
for b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
    [ "$b" = main ] && continue
    sha="$(git rev-parse "$b")"
    git merge-base --is-ancestor "$sha" "$MAIN" && continue      # merged: phase 3
    if [ -n "$(git branch -r --contains "$sha" 2>/dev/null)" ]; then
        note "$b is unmerged but present on a remote — no archive tag needed"
        continue
    fi
    printf '   LOCAL-ONLY, UNMERGED: %-45s %s  %s\n' "$b" "${sha:0:8}" \
        "$(git log -1 --format='%cd %s' --date=short "$b" | cut -c1-50)"
    archive_tag "$b" "$sha"
    note "  ^ tag it, then PUSH the branch or the tag. A tag here is still only"
    note "    in this one repository; it is not a backup until it leaves the host."
done
fi

#=============================================================================
# PHASE 2 — Tag the commits that exist only on a remote we intend to remove.
#
# Removing a remote drops its remote-tracking refs, and any commit reachable
# only from them becomes unreferenced. Tag first, delete the remote later.
#=============================================================================
if phase remote-tags; then
head_ "Phase 2 — tag commits reachable only from a remote slated for removal"

OTHER_REFS="$(git for-each-ref --format='%(refname)' refs/remotes/origin refs/heads | tr '\n' ' ')"

for remote in gitlab ethclone; do
    git remote | grep -qx "$remote" || { skip "remote $remote is not configured"; continue; }
    for r in $(git for-each-ref --format='%(refname:short)' "refs/remotes/$remote"); do
        case "$r" in *"/HEAD") continue ;; esac
        # shellcheck disable=SC2086
        u="$(git rev-list --count "$r" --not $OTHER_REFS 2>/dev/null)"
        [ "${u:-0}" -gt 0 ] || continue
        printf '   %-58s %s commit(s) found nowhere else\n' "$r" "$u"
        archive_tag "${r//\//_}" "$(git rev-parse "$r")"
    done
done
fi

#=============================================================================
# PHASE 3 — Remove worktrees that are clean AND on a merged branch.
#
# Worktrees come out BEFORE branches, because a branch checked out in a
# worktree cannot be deleted. Any uncommitted change disqualifies a worktree
# outright — no --force anywhere in this script.
#=============================================================================
if phase worktrees; then
head_ "Phase 3 — remove clean worktrees sitting on merged branches"

git worktree list --porcelain | awk '
    /^worktree /{w=$2} /^HEAD /{h=$2} /^branch /{b=$2} /^detached/{b="-"}
    /^$/{if(w){print w"|"h"|"b; w=""}}
    END{if(w) print w"|"h"|"b}' |
while IFS='|' read -r wt sha br; do
    [ "$wt" = "$REPO" ] && { skip "$wt (this is the checkout the script is running from)"; continue; }
    [ "$wt" = "$(git rev-parse --show-toplevel)" ] && continue
    # The main working tree of the repository is never removable.
    if [ "$wt" = "$(git worktree list --porcelain | head -1 | awk '{print $2}')" ]; then
        skip "$wt (primary working tree — never removed)"; continue
    fi
    n="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)"
    if [ "$n" -ne 0 ]; then
        skip "$wt — $n uncommitted path(s). NOT TOUCHED."
        continue
    fi
    if ! git merge-base --is-ancestor "$sha" "$MAIN" 2>/dev/null; then
        skip "$wt — ${sha:0:8} is not an ancestor of origin/main (review reference)"
        continue
    fi
    run "remove worktree $wt (clean, ${sha:0:8} merged)" git worktree remove "$wt"
done
fi

#=============================================================================
# PHASE 4 — Tag and delete local branches merged into origin/main.
#
# Rule 4 in full: the ancestry test is run here, per branch, against the
# origin/main fetched at the top of THIS run.
#=============================================================================
if phase branches; then
head_ "Phase 4 — tag and delete local branches merged into origin/main"
if [ "$EXECUTE" -eq 0 ]; then
    note "DRY RUN: phase 3 removed no worktrees, so branches checked out in one"
    note "  are skipped below. Under --execute those worktrees are gone by now"
    note "  and the same branches WILL be tagged and deleted here."
fi

for b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
    [ "$b" = main ] && continue
    sha="$(git rev-parse "$b")"

    if ! git merge-base --is-ancestor "$sha" "$MAIN"; then
        skip "$b — NOT an ancestor of origin/main. Never deleted by this script."
        continue
    fi
    if is_checked_out "$b"; then
        skip "$b — checked out in a worktree; remove the worktree first"
        continue
    fi
    archive_tag "$b" "$sha" || { refuse "$b — not deleting without its archive tag"; continue; }
    run "delete branch $b (${sha:0:8}, merged)" git branch -d "$b"
done
fi

#=============================================================================
# PHASE 5 — Remotes.
#
# `mainclone` only. See docs/CLEANUP_PLAN_2026-09.md: its URL is a filesystem
# path into deps/tidelink-phy, a SUBMODULE working directory, and every commit
# it holds is also on that submodule's own origin (GitHub). Removing it drops
# a duplicate view, not history.
#
# `gitlab` is NOT removed here even though gitlab/main is 293 behind with
# nothing unique: across its 17 refs it holds commits found nowhere else, and
# a tag made in phase 2 is not a backup until it is pushed. The plan makes
# that a two-step with a human in the middle.
#=============================================================================
if phase remotes; then
head_ "Phase 5 — remove the mainclone remote"

if git remote | grep -qx mainclone; then
    url="$(git config --get remote.mainclone.url)"
    note "mainclone url = $url"
    # shellcheck disable=SC2086
    OTHER_REFS="$(git for-each-ref --format='%(refname)' refs/remotes/origin refs/remotes/ethclone refs/heads refs/tags | tr '\n' ' ')"
    unsafe=0
    for r in $(git for-each-ref --format='%(refname:short)' refs/remotes/mainclone); do
        u="$(git rev-list --count "$r" --not $OTHER_REFS 2>/dev/null)"
        if [ "${u:-0}" -gt 0 ]; then
            # Expected: this remote's commits belong to the PHY submodule, whose
            # own origin holds them. Prove that rather than assume it.
            if [ -d "$url" ] && git -C "$url" branch -r --contains "$(git rev-parse "$r")" 2>/dev/null | grep -q .; then
                note "$r: $u commit(s) unique HERE, but present on the submodule's own remote — safe"
            else
                refuse "$r holds $u commit(s) not found elsewhere and not confirmed on the submodule's remote"
                unsafe=1
            fi
        fi
    done
    if [ "$unsafe" -eq 0 ]; then
        run "remove remote mainclone" git remote remove mainclone
    else
        skip "mainclone — see REFUSED above; resolve by hand"
    fi
else
    skip "remote mainclone is not configured"
fi

note "remote 'gitlab' is deliberately NOT removed by this script."
note "  gitlab/main is 293 behind origin/main with 0 unique commits, but its"
note "  other refs hold commits found nowhere else. Phase 2 tags them; PUSH"
note "  those tags to origin, confirm they are there, and only then run:"
note "      git remote remove gitlab"
note "remote 'ethclone' is deliberately NOT removed: it is a live sibling"
note "  checkout, and three of its branches carry unique commits (phase 2)."
fi

#=============================================================================
# PHASE 6 — Tracked files with no consumer.
#
# Only files proved to have ZERO references in any build file AND no live
# documentation pointing at them. The plan lists three further flists that
# look orphaned but are NOT deleted here, with the reason for each.
#=============================================================================
if phase junk; then
head_ "Phase 6 — untrack files with no consumer"

JUNK="
scratch_resolved/cocotb__tidelink_a2l_replay_cdc__dut_src.f
scratch_resolved/cocotb__tidelink_a2l_replay_cdc__dut_src_1.f
scratch_resolved/cocotb__tidelink_a2l_replay_cdc__dut_src_3.f
scratch_resolved/cocotb__tidelink_a2l_replay_cdc__dut_src_5.f
scratch_resolved/flists__tidelink_fpga_v2.flist
scratch_resolved/flists__tidelink_top_full_asic_v2.flist
cocotb/tidelink_axi_datanode_recovery/tidelink_fpga_v2_eccoff.flist
cocotb/debug/tidelink_peer_aperture/flist.f
"
for f in $JUNK; do
    [ -f "$f" ] || { skip "$f (already gone)"; continue; }
    # Re-prove "no consumer" now: a reference added since the plan was written
    # must stop the deletion, not be overridden by this list.
    # `grep -v` twice, deliberately: once for the file itself (a flist that
    # names its own basename in a header comment is not a consumer), and once
    # for THIS script — whose JUNK list above contains every one of these
    # paths. Without the second exclusion the re-proof finds itself and
    # refuses all eight, which is exactly what the first dry run did.
    SELF="scripts/maintenance/$(basename "${BASH_SOURCE[0]}")"
    hits="$(git grep -l -F "$(basename "$f")" -- '*Makefile' '*.mk' '*.sh' '*.tcl' '*.py' '*.yml' '*.f' '*.flist' '*.prj' 2>/dev/null \
            | grep -v "^$f$" | grep -v "^$SELF$" | grep -v '^docs/CLEANUP_PLAN_2026-09\.md$')"
    if [ -n "$hits" ]; then
        refuse "$f is referenced now by: $(echo "$hits" | tr '\n' ' ')"
        continue
    fi
    run "git rm $f (no consumer)" git rm -q "$f"
done
note "NOT removed here (see the plan): flists/tidelink_phy_v2.flist (dormant"
note "  by design), flists/tidelink_generic.flist (cited by three docs),"
note "  cocotb/crc_diag/tidelink_fpga_v2_prefix.flist (a documented manual"
note "  V2_FLIST override), BRINGUP_REPORT.md (cited from 40 files including"
note "  7 RTL sources), docs/*_registry.html (CI checks them with --check)."
fi

#=============================================================================
head_ "Summary"
if [ "$EXECUTE" -eq 0 ]; then
    say "   Dry run. Nothing changed. Re-run with --execute to act."
    say "   Read docs/CLEANUP_PLAN_2026-09.md before you do."
fi
if [ "$refused" -gt 0 ]; then
    say "   $refused action(s) REFUSED — see above. Nothing was forced."
    exit 1
fi
say "   no refusals"
exit 0
