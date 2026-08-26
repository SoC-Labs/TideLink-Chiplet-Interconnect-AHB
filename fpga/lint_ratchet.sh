#!/bin/bash
# =============================================================================
# lint_ratchet.sh — ratchet a lint against an accepted baseline. CHECKER ONLY.
#
# Sourced by fpga/farm_gate.sh. Split out so ci/checker_controls/ can exercise
# the grading without running the gate.
#
# Callers must provide say() / fail() / pass(); farm_gate.sh does.
#
# WHY THE LIVENESS CHECK EXISTS
#
#   The gate used to invoke each linter as:
#
#       python3 "$LINT_DIR/xdc_lint.py" ... >"$LOG" 2>&1 || true
#       ratchet_lint "xdc_lint" "$LOG" "$BASELINE"
#
#   `|| true` is correct for exit 1 — that is the linter's documented "findings
#   exist" status, and the ratchet, not the exit code, decides pass/fail. But it
#   swallowed EVERY other status too: 2 (argparse error), 127 (interpreter or
#   script missing), 137 (OOM kill). extract_keys then parsed an empty or
#   traceback-only log, produced ZERO keys, found nothing new against the
#   baseline, and printed "ok: no new findings". A lint that never ran graded
#   clean.
#
#   A MISSING BASELINE was already fail-closed here (every finding is treated as
#   NEW). A CRASHED LINT was not. Both are now handled.
#
#   Exit code alone is not sufficient: an uncaught Python exception also exits
#   1, indistinguishable from "findings exist". So liveness is proven from the
#   log itself — both linters end with a verdict receipt, "OK — no ..." or
#   "FAIL — N ... finding(s)". No receipt => the tool did not complete.
#
# THREE outcomes, never two: PASS / FAIL / COULD-NOT-EVALUATE.
# An unevaluable lint is a BLOCKING failure, not a silent pass.
# =============================================================================

#   Finding lines : <path>:<line>: <CODE> <message...>
#   Baseline lines: <path>:<line>: <CODE>            (message dropped)
extract_keys() {
    # $1 = file of raw lint/baseline text -> stdout: sorted-uniq "path:line: CODE"
    sed -nE 's#^([^:[:space:]]+:[0-9]+):[[:space:]]+([A-Z_]+).*$#\1: \2#p' "$1" \
        | sort -u
}

# lint_evaluable <label> <log> <rc>
# stdout: reason when NOT evaluable.  returns 0 = evaluable, 1 = could-not-evaluate
lint_evaluable() {
    local label="$1" log="$2" rc="$3"
    if [ ! -f "$log" ]; then
        echo "no output log at $log — the linter never wrote anything"; return 1
    fi
    if [ ! -s "$log" ]; then
        echo "output log $log is empty — the linter produced no output at all"; return 1
    fi
    case "$rc" in
        0|1) : ;;
        127) echo "exit 127 — interpreter or script not found (is $label installed / path correct?)"; return 1 ;;
        2)   echo "exit 2 — the linter rejected its own arguments (usage/argparse error)"; return 1 ;;
        *)   echo "exit $rc — not the linter's documented 0 (clean) or 1 (findings)"; return 1 ;;
    esac
    if grep -q 'Traceback (most recent call last)' "$log"; then
        echo "python traceback in $log — the linter crashed (exit $rc is the interpreter's, not a verdict)"
        return 1
    fi
    # Verdict receipt: both linters print one of these as their last word.
    if ! grep -Eq '(^|[[:space:]])(OK|FAIL)[[:space:]]+—' "$log"; then
        echo "no verdict line ('OK — ...' / 'FAIL — ...') in $log — the linter did not run to completion"
        return 1
    fi
    return 0
}

# ratchet_lint <label> <raw-output-log> <baseline-file> <linter-exit-code>
# Fails ONLY on keys not already in the accepted baseline, so the gate stays
# green on today's known debt yet red on any NEW finding — and red on a lint
# that could not be evaluated at all.
ratchet_lint() {
    local label="$1" rawlog="$2" baseline="$3" rc="${4:-0}"
    local cur="$LOG_DIR/${label}_cur.$STAMP.txt"
    local base="$LOG_DIR/${label}_base.$STAMP.txt"

    local why
    if ! why="$(lint_evaluable "$label" "$rawlog" "$rc")"; then
        fail "$label — COULD NOT EVALUATE: $why"
        say  "  a lint that did not run has NOT passed; this blocks the gate."
        say  "  (full $label output: $rawlog)"
        return 1
    fi

    extract_keys "$rawlog" >"$cur"
    if [ -f "$baseline" ]; then
        extract_keys "$baseline" >"$base"
    else
        : >"$base"
        say "WARNING: baseline $baseline absent — treating all $label findings as NEW"
    fi

    # The linter said "findings exist" but nothing parsed as a finding: the
    # output format drifted away from extract_keys' pattern, so the ratchet is
    # comparing nothing against nothing. That is unevaluable, not clean.
    if [ "$rc" = 1 ] && [ ! -s "$cur" ]; then
        fail "$label — COULD NOT EVALUATE: exit 1 (findings exist) but no finding line matched the 'path:line: CODE' pattern — lint output format drift"
        say  "  (full $label output: $rawlog)"
        return 1
    fi

    local newf gone
    newf="$(comm -23 "$cur" "$base")"
    gone="$(comm -13 "$cur" "$base")"   # in baseline, no longer found -> retire
    if [ -n "$newf" ]; then
        fail "$label — NEW finding(s) not in $baseline:"
        printf '%s\n' "$newf" | sed 's/^/[farm_gate]     + /' >&2
        say "(full $label output: $rawlog)"
    else
        pass "$label (no new findings vs baseline; $(grep -c . "$base" 2>/dev/null || echo 0) accepted)"
    fi
    if [ -n "$gone" ]; then
        say "note: $label baseline entry(ies) no longer found — retire from $baseline:"
        printf '%s\n' "$gone" | sed 's/^/[farm_gate]     - /'
    fi
    return 0
}
