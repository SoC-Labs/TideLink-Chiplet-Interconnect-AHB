#!/bin/bash
# =============================================================================
# lvs_verdict.sh — grade a Calibre LVS report. CHECKER ONLY.
#
# WHY THIS EXISTS
#
#   run_calibre_lvs.sh used to grade the report with:
#
#       if   grep -q "CORRECT"   "$report"; then  LVS CORRECT
#       elif grep -q "INCORRECT" "$report"; then  LVS INCORRECT
#
#   "INCORRECT" CONTAINS the substring "CORRECT", so the first grep matched
#   every failing report and the elif was UNREACHABLE. Every LVS mismatch this
#   flow ever saw was reported as a clean match. Worse, the script then exited
#   0 regardless of verdict — Calibre's own exit status reflects whether the
#   TOOL ran, not whether the layout MATCHES, so nothing downstream could tell
#   a match from a mismatch.
#
# THE RULE
#
#   Three outcomes, never two. An indeterminate report is NOT a pass.
#
#     exit 0  CORRECT             canonical match verdict found
#     exit 1  INCORRECT           canonical mismatch verdict found
#     exit 2  COULD-NOT-EVALUATE  no report / unreadable / empty / no verdict
#
#   Matching is anchored, in priority order:
#     1. Calibre's boxed banner line:  "# --- CORRECT --- #" / "--- INCORRECT ---"
#     2. failing verdict before passing verdict (fail-first)
#     3. whole-word match only: "[^A-Za-z]CORRECT[^A-Za-z]" cannot match inside
#        "INCORRECT", because the character before CORRECT there is "N".
#
# Usage: lvs_verdict.sh <lvs-report-file>
#        prints one of: CORRECT | INCORRECT | COULD-NOT-EVALUATE  (+ reason)
# =============================================================================
set -u

report="${1:-}"

if [ -z "$report" ]; then
    echo "COULD-NOT-EVALUATE: no report path given"
    exit 2
fi
if [ ! -f "$report" ]; then
    echo "COULD-NOT-EVALUATE: no LVS report at $report (Calibre may not have run a compare pass)"
    exit 2
fi
if [ ! -r "$report" ]; then
    echo "COULD-NOT-EVALUATE: LVS report $report is not readable"
    exit 2
fi
if [ ! -s "$report" ]; then
    echo "COULD-NOT-EVALUATE: LVS report $report is empty (run truncated?)"
    exit 2
fi

# --- tier 1: Calibre's boxed verdict banner (most specific) ------------------
# Fail-first: test INCORRECT before CORRECT so no substring can shadow it.
if grep -Eq -- '-{2,}[[:space:]]*INCORRECT[[:space:]]*-{2,}' "$report"; then
    echo "INCORRECT: Calibre comparison banner reports INCORRECT"
    exit 1
fi
if grep -Eq -- '-{2,}[[:space:]]*CORRECT[[:space:]]*-{2,}' "$report"; then
    echo "CORRECT: Calibre comparison banner reports CORRECT"
    exit 0
fi

# --- tier 2: whole-word verdict token anywhere in the report ----------------
if grep -Eq '(^|[^A-Za-z])INCORRECT([^A-Za-z]|$)' "$report"; then
    echo "INCORRECT: whole-word INCORRECT verdict found in $(basename "$report")"
    exit 1
fi
if grep -Eq '(^|[^A-Za-z])CORRECT([^A-Za-z]|$)' "$report"; then
    echo "CORRECT: whole-word CORRECT verdict found in $(basename "$report")"
    exit 0
fi

# --- no verdict at all: indeterminate, and indeterminate is NOT clean -------
echo "COULD-NOT-EVALUATE: no CORRECT/INCORRECT verdict in $(basename "$report") — Calibre did not complete the comparison"
exit 2
