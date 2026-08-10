#!/usr/bin/env bash
#
# git_merge_flist.sh -- git merge driver for TideLink flists.
#
# CONTRACT
#   git_merge_flist.sh %O %A %B %L %P
#     %O  ancestor (base) version, temp file
#     %A  OUR version, temp file -- AND the output file the driver must write
#     %B  THEIR version, temp file
#     %L  conflict marker length
#     %P  the real pathname of the file in the worktree
#   exit 0  -> resolved; %A holds the final bytes
#   exit !0 -> conflicted; %A holds a conventional conflict-marked file
#
#   git 2.43.7 is installed here.  %O %A %B %L %P are supported; the 2.44+
#   %S/%X/%Y conflict-label placeholders are NOT -- do not use them.
#   Git runs the driver with cwd = top of the working tree, so a repo-relative
#   driver path is valid, including inside linked worktrees.
#
# WHAT IT DECIDES
#   A flist selects which RTL is compiled.  Two versions of one that differ
#   only in comments select an identical netlist; two that differ in one path
#   select a different chip.  Text merge cannot tell those apart.  This driver
#   compares the SEMANTIC MODEL (scripts/flist_semantic.py) and auto-resolves
#   only the first case -- and even then, only outside the safety boundary.
#
# DECISION PROCEDURE -- strictly ordered, first rule that fires wins:
#   R0 DENYLIST        %P is on the never-auto-resolve list  -> REFUSE
#   R1 ABSOLUTE PATH   either side contains an absolute path -> REFUSE
#   R2 PARSE           either side fails to parse            -> REFUSE
#   R3 SEMANTIC DELTA  keys differ                           -> REFUSE
#   R4 DOC SUPERSET    keys equal, one side's comments are an ordered
#                      subsequence of the other's -> take the SUPERSET side
#   R5 DOC FORK        keys equal but comments forked        -> REFUSE
#
# WHY R1 EXISTS AT ALL, given R3 would already catch these files: after
# stripping the worktree root, dut_src_1.f and dut_src_3.f become semantically
# EQUAL and would otherwise auto-resolve -- committing one machine's absolute
# path forever.  A file that violates the gate's own invariant is never
# auto-resolvable, whatever its semantics.  Automation must not launder a
# gate violation into a commit.
#
# WHY R5 EXISTS: semantic equality plus documentation divergence means two
# engineers recorded different provenance for the same change.  In this repo
# the provenance comment is what tells a future reader that a file is
# HW-proven; silently discarding one side's is a real loss.
#
# EXPLICITLY OUT OF SCOPE -- the driver must never: merge two comment blocks
# into a union; reorder records to make keys match; drop an unresolvable
# record so keys match; rewrite an absolute path into ${TIDELINK_HOME} form
# during a merge; consult the network or a sibling repository.
#
# FAIL-SAFE PROPERTY: if .gitattributes routes *.flist here but
# merge.flist.driver is unregistered in this clone, git falls back to the
# built-in text merge and the file CONFLICTS.  That is fail-safe, not
# fail-open: an unregistered driver can only ever cause extra human work,
# never a bad auto-resolution.
#
# REGISTER IT (per-clone, not committed; --local is shared by all linked
# worktrees of this repo):
#   git config --local merge.flist.name   "TideLink flist semantic merge"
#   git config --local merge.flist.driver "scripts/git_merge_flist.sh %O %A %B %L %P"
#   git config --local merge.flist.recursive text
# and commit a .gitattributes containing:
#   *.flist merge=flist
#   *.f     merge=flist
#
# DRY RUN (do this BEFORE `git merge`):
#   scripts/git_merge_flist.sh --preview <ours-ref> <theirs-ref> <base-ref> [paths...]
# git-merge-tree(1) at 2.43 documents nothing about honouring custom merge
# drivers, so the preview does the resolution itself rather than asking
# merge-tree to run us.

set -u
set -o pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEMANTIC_PY="${FLIST_SEMANTIC:-$HERE/flist_semantic.py}"

# Always go through python3 so the driver does not depend on the exec bit
# surviving a clone, a `git archive`, or a checkout with core.fileMode=false.
semantic() { python3 "$SEMANTIC_PY" "$@"; }

# --------------------------------------------------------------------------
# SAFETY BOUNDARY.
#
# These paths are NEVER auto-resolved, even when the two sides are
# byte-identical.  This is a policy refusal, not an inability: the driver
# still prints which side is correct and why, so the human decides in one
# step rather than investigating from scratch.
#
# Justification for the ASIC family specifically -- and this argues AGAINST
# the tempting position that semantic identity makes auto-resolution safe:
#   (i)  What the driver verifies is "these two blobs select the same RTL",
#        NOT "this selection is correct".  For the FPGA flist a wrong
#        selection is caught downstream by simulation and by hardware.  For
#        the tapeout flist there is no such backstop.
#   (ii) The only local test, sim_gate_asicelab_v2, runs bare
#        `vcs -f flists/tidelink_top_full_asic_v2.flist -top tidelink_top`:
#        it proves the flist ELABORATES, not that it selects the right files.
#        Any wrong-but-compilable re-point is green.
#   (iii)This repo has already shipped exactly this defect -- a commit whose
#        message said "flists re-pointed" (plural) touched only the FPGA
#        flist, leaving the tapeout netlist on a blanket ECC bypass with
#        every simulation still passing.
#   (iv) The cost of the boundary is one refusal per ASIC-flist merge, with
#        the correct answer printed.  The cost of one wrong auto-resolution
#        is a respin.
#
# The dut_src*.f entries are belt-and-braces: R1 already refuses them for
# containing absolute paths, but they are named here so the refusal explains
# the real problem (a tracked build artifact) rather than only the symptom.
#
# A policy file may EXTEND this list.  It can never shrink it.
# --------------------------------------------------------------------------
DENY_BUILTIN=(
  "flists/tidelink_top_full_asic_v2.flist|feeds the TAPEOUT netlist: syn/asic/fusion-compiler/Makefile reads this exact file as \$FLIST, and syn/asic/formality/scripts/run_lec.tcl reads the same \$FLIST for LEC. Netlist-affecting changes require human sign-off (docs/BUG_REGISTRY.yaml signoff_policy.auto_signoff_allowed=false).|David Mapstone"
  "flists/tidelink_top_full_asic.flist|ASIC top flist (V1 PHY): same tapeout class as the _v2 file; no simulation backstop distinguishes a wrong-but-compilable re-point.|David Mapstone"
  "flists/tidelink_asic.flist|ASIC flist consumed via ASIC_FLIST by syn/asic/design-compiler and syn/asic/rtl-architect.|David Mapstone"
  "flists/tidelink_netlist.flist|post-synthesis netlist + stdcell/memory model selection; a wrong pick here silently verifies the wrong netlist.|David Mapstone"
  "cocotb/tidelink_a2l_replay_cdc/dut_src.f|Makefile-GENERATED build artifact that should not be tracked (cocotb/tidelink_a2l_replay_cdc/Makefile rewrites it at every parse). Do not pick a side: gitignore the class.|David Mapstone"
  "cocotb/tidelink_a2l_replay_cdc/dut_src_1.f|Makefile-GENERATED build artifact that should not be tracked. Do not pick a side: gitignore the class.|David Mapstone"
  "cocotb/tidelink_a2l_replay_cdc/dut_src_3.f|Makefile-GENERATED build artifact that should not be tracked. Do not pick a side: gitignore the class.|David Mapstone"
  "cocotb/tidelink_a2l_replay_cdc/dut_src_5.f|Makefile-GENERATED build artifact that should not be tracked, AND theirs names the pristine deps/ pre-fix DUT (residue of a USE_DEPS_DUT=1 reproduce run). Do not pick a side: gitignore the class.|David Mapstone"
)

# Optional policy file, read from the WORKTREE and not from a git ref, so a
# merge that itself modifies the policy cannot weaken the rule for its own
# merge.  Format, one entry per line:  <path>|<reason>|<approver>
# ('#' comments and blank lines allowed).
POLICY_FILE="${FLIST_MERGE_POLICY:-}"
POLICY_EXPLICIT=0
if [[ -n "$POLICY_FILE" ]]; then
  POLICY_EXPLICIT=1
elif [[ -f "flists/FLIST_MERGE_POLICY" ]]; then
  POLICY_FILE="flists/FLIST_MERGE_POLICY"
fi

DENY_PATHS=()
DENY_REASONS=()
DENY_APPROVERS=()

load_denylist() {
  local line
  for line in "${DENY_BUILTIN[@]}"; do
    DENY_PATHS+=("${line%%|*}")
    local rest="${line#*|}"
    DENY_REASONS+=("${rest%%|*}")
    DENY_APPROVERS+=("${rest##*|}")
  done

  if [[ -n "$POLICY_FILE" ]]; then
    if [[ ! -f "$POLICY_FILE" ]]; then
      # Fail closed.  Mirrors fpga/scripts/merge_guard.sh: "refusing to pass
      # a check I could not run."
      echo "$PROG: policy file '$POLICY_FILE' not found -- refusing to" >&2
      echo "  auto-resolve anything.  A missing policy is not an empty policy." >&2
      return 1
    fi
    while IFS= read -r line; do
      [[ -z "${line// }" ]] && continue
      [[ "${line:0:1}" == "#" ]] && continue
      if [[ "$line" != *"|"*"|"* ]]; then
        echo "$PROG: policy file '$POLICY_FILE': unparseable line: $line" >&2
        echo "  expected <path>|<reason>|<approver>" >&2
        return 1
      fi
      DENY_PATHS+=("${line%%|*}")
      local rest="${line#*|}"
      DENY_REASONS+=("${rest%%|*}")
      DENY_APPROVERS+=("${rest##*|}")
    done < "$POLICY_FILE"
  fi
  return 0
}

deny_index() {
  local want="$1" i
  for i in "${!DENY_PATHS[@]}"; do
    [[ "${DENY_PATHS[$i]}" == "$want" ]] && { echo "$i"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------------------
# Reporting.  Everything goes to STDERR, never stdout: git shows the driver's
# stderr to the user, and stdout could be mistaken for file content by a
# careless caller.
# --------------------------------------------------------------------------
hr() { echo "--------------------------------------------------------------------" >&2; }

report_head() {
  hr
  echo "flist-merge REFUSED: $1" >&2
  echo "reason: $2" >&2
}

report_next() {
  local path="$1"
  echo "" >&2
  echo "next:" >&2
  echo "  scripts/flist_semantic.py diff <(git show :2:$path) <(git show :3:$path)" >&2
  echo "  git show :1:$path   # base   :2: ours   :3: theirs" >&2
  hr
}

# --------------------------------------------------------------------------
# Core decision.  Sets DECISION to one of:
#   AUTO_THEIRS | AUTO_OURS | AUTO_IDENTICAL | REFUSE
# and RULE to the rule that fired.
# --------------------------------------------------------------------------
DECISION=""
RULE=""
PORCELAIN=""

decide() {
  local O="$1" A="$2" B="$3" P="$4"
  DECISION="REFUSE"; RULE=""; PORCELAIN=""

  # ---- R0 denylist -------------------------------------------------------
  local idx
  if idx="$(deny_index "$P")"; then
    RULE="denylist"
    DENY_HIT="$idx"
    return
  fi

  # ---- R2 parse (run first mechanically; R1/R3 need its output) ----------
  local rc
  PORCELAIN="$(semantic diff "$A" "$B" --porcelain --label-a ours --label-b theirs 2>&1)"
  rc=$?
  if [[ $rc -ge 2 ]]; then
    RULE="parse-error"
    return
  fi

  # ---- R1 absolute-path poison ------------------------------------------
  if [[ "$(printf '%s\n' "$PORCELAIN" | grep -c '^has_abs_path=1$')" -gt 0 ]]; then
    RULE="absolute-path"
    return
  fi

  # ---- R3 semantic inequality -------------------------------------------
  if [[ $rc -ne 0 ]]; then
    RULE="semantic-delta"
    return
  fi

  # ---- R4 / R5 documentation ---------------------------------------------
  local rel
  rel="$(printf '%s\n' "$PORCELAIN" | sed -n 's/^comment_relation=//p')"
  case "$rel" in
    identical) DECISION="AUTO_IDENTICAL"; RULE="identical" ;;
    a_subset)  DECISION="AUTO_THEIRS";    RULE="doc-superset(theirs)" ;;
    b_subset)  DECISION="AUTO_OURS";      RULE="doc-superset(ours)" ;;
    fork)      DECISION="REFUSE";         RULE="documentation-fork" ;;
    *)         DECISION="REFUSE";         RULE="parse-error" ;;
  esac
}

print_refusal() {
  local P="$1" O="$2" A="$3" B="$4"
  case "$RULE" in
    denylist)
      report_head "$P" "denylist -- this path is never auto-resolved"
      echo "  ${DENY_REASONS[$DENY_HIT]}" >&2
      echo "  approver: ${DENY_APPROVERS[$DENY_HIT]}" >&2
      echo "" >&2
      echo "  This is a POLICY refusal, not an inability.  For the record," >&2
      echo "  here is what the semantic comparison says:" >&2
      semantic diff "$A" "$B" --label-a ours --label-b theirs 2>&1 \
        | sed 's/^/    /' >&2
      ;;
    absolute-path)
      report_head "$P" "absolute-path -- a side contains a machine-specific path"
      printf '%s\n' "$PORCELAIN" | sed -n 's/^abs_path=/  offending: /p' | sort -u >&2
      echo "" >&2
      echo "  A tracked flist may not contain an absolute path: it breaks in" >&2
      echo "  every other checkout, and because cocotb/flist_deps.mk drops" >&2
      echo "  paths that do not resolve, a dead absolute path silently removes" >&2
      echo "  the DUT from the staleness guard's prerequisites." >&2
      echo "  Auto-resolving would commit one machine's path forever, so the" >&2
      echo "  driver refuses even when the two sides are otherwise equal." >&2
      echo "  Correct form: \${TIDELINK_HOME}/... (what all other flists use)." >&2
      ;;
    parse-error)
      report_head "$P" "parse-error -- a side is not a well-formed flist"
      printf '%s\n' "$PORCELAIN" | sed 's/^/  /' >&2
      ;;
    semantic-delta)
      report_head "$P" "semantic-delta -- the two sides select DIFFERENT sources"
      echo "" >&2
      semantic diff "$A" "$B" --label-a ours --label-b theirs 2>&1 \
        | sed 's/^/  /' >&2
      ;;
    documentation-fork)
      report_head "$P" "documentation-fork -- same sources, divergent provenance"
      echo "  The two sides select an identical source set, but neither side's" >&2
      echo "  comment block is an ordered subsequence of the other's: each" >&2
      echo "  engineer recorded provenance the other did not.  Auto-resolving" >&2
      echo "  would silently destroy one side's record.  Merge the comments by" >&2
      echo "  hand." >&2
      printf '%s\n' "$PORCELAIN" | sed -n 's/^comments_/  comments_/p' >&2
      ;;
    *)
      report_head "$P" "unknown -- driver could not classify; refusing"
      ;;
  esac
  report_next "$P"
}

# --------------------------------------------------------------------------
# Preview mode
# --------------------------------------------------------------------------
do_preview() {
  local ours="$1" theirs="$2" base="$3"; shift 3
  local paths=("$@")

  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "$PROG --preview: no paths given." >&2
    echo "  Pass the paths explicitly.  Do NOT rely on git's conflict list:" >&2
    echo "  a file changed on only one side is auto-resolved SILENTLY and" >&2
    echo "  never appears there.  Suggested enumeration:" >&2
    echo "    git diff --name-only \$(git merge-base $ours $theirs) $theirs \\" >&2
    echo "      -- '*.flist' '*.f'" >&2
    return 2
  fi

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  local rc=0 p n=0
  printf '%-58s %s\n' "PATH" "DECISION"
  for p in "${paths[@]}"; do
    n=$((n + 1))
    local fO="$tmp/$n.base" fA="$tmp/$n.ours" fB="$tmp/$n.theirs"
    git show "$base:$p"   > "$fO" 2>/dev/null || : > "$fO"
    git show "$ours:$p"   > "$fA" 2>/dev/null || { printf '%-58s %s\n' "$p" "SKIP(absent on ours)"; continue; }
    git show "$theirs:$p" > "$fB" 2>/dev/null || { printf '%-58s %s\n' "$p" "SKIP(absent on theirs)"; continue; }

    decide "$fO" "$fA" "$fB" "$p"
    case "$DECISION" in
      AUTO_THEIRS)    printf '%-58s %s\n' "$p" "AUTO(theirs)" ;;
      AUTO_OURS)      printf '%-58s %s\n' "$p" "AUTO(ours)" ;;
      AUTO_IDENTICAL) printf '%-58s %s\n' "$p" "AUTO(identical)" ;;
      *)              printf '%-58s %s\n' "$p" "REFUSE($RULE)"; rc=1 ;;
    esac
  done
  return $rc
}

# --------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------
if [[ ! -f "$SEMANTIC_PY" ]]; then
  echo "$PROG: cannot find flist_semantic.py at '$SEMANTIC_PY'" >&2
  echo "  set FLIST_SEMANTIC to its path.  Refusing to resolve." >&2
  exit 1
fi

if [[ "${1:-}" == "--preview" ]]; then
  shift
  if [[ $# -lt 3 ]]; then
    echo "usage: $PROG --preview <ours-ref> <theirs-ref> <base-ref> <path>..." >&2
    exit 2
  fi
  load_denylist || exit 2
  do_preview "$@"
  exit $?
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 5 ]]; then
  sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

O="$1"; A="$2"; B="$3"; L="$4"; P="$5"

if ! load_denylist; then
  # Fail closed: leave a conventional conflict.
  git merge-file -L "ours (HEAD)" -L "base" -L "theirs (incoming)" \
    --marker-size="$L" "$A" "$O" "$B" >/dev/null 2>&1 || true
  report_head "$P" "policy-unavailable -- refusing to auto-resolve anything"
  report_next "$P"
  exit 1
fi

decide "$O" "$A" "$B" "$P"

case "$DECISION" in
  AUTO_THEIRS)
    cat "$B" > "$A" || exit 1
    echo "flist-merge: $P -> took THEIRS (semantically identical to ours;" >&2
    echo "  theirs is a documentation superset). $RULE" >&2
    exit 0
    ;;
  AUTO_OURS|AUTO_IDENTICAL)
    # %A already holds ours; write explicitly so the intent is on the record.
    cat "$A" > "$A.tmp" && mv "$A.tmp" "$A" || exit 1
    echo "flist-merge: $P -> kept OURS ($RULE)." >&2
    exit 0
    ;;
esac

# Refused.
#
# ORDER MATTERS HERE.  Print the report FIRST, while %A still holds the
# pristine "ours" version.  `git merge-file` rewrites %A in place with
# conflict markers, and those markers are not valid flist syntax -- reporting
# afterwards would make the driver parse-error on its own output and print a
# grammar complaint instead of the actual finding.
print_refusal "$P" "$O" "$A" "$B"

# Now reconstruct a conventional conflicted file so the operator's editor and
# mergetool behave exactly as they would without this driver.  %A holds ours,
# which is what git merge-file expects as its first argument.
git merge-file -L "ours (HEAD)" -L "base" -L "theirs (incoming)" \
  --marker-size="$L" "$A" "$O" "$B" >/dev/null 2>&1 || true

exit 1
