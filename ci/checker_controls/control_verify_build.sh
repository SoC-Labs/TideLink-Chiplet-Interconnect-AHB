#!/bin/bash
# =============================================================================
# MUST-FAIL CONTROL — verify_build.sh must not exit 0 on an UNVERIFIABLE build
#
#   ci/checker_controls/control_verify_build.sh
#   VERIFY_BUILD_SH=<path> ...   grade an alternative copy (used to prove the
#                                pre-fix script goes RED)
#
# Part A — classification. Runs the real script against a synthetic worktree
#          whose impl log, OOC synth log and routed timing report are all
#          absent, and asserts each is reported as UNKNOWN (could-not-evaluate)
#          rather than WARN (advisory).
# Part B — verdict mapping. Extracts the verdict block and drives it with
#          synthetic counters, asserting the exit code for each combination.
#
# The (i) block's own comment records why this matters: a build shipped at
# WNS -2.427 ns with 1673 failing endpoints and passed verify_build.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
VB="${VERIFY_BUILD_SH:-$root/fpga/scripts/verify_build.sh}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
rc_overall=0

echo "==============================================================="
echo " CONTROL: verify_build.sh — unverifiable must not grade clean"
echo " script under test: $VB"
echo "==============================================================="

# ---- Part A: classification of unevaluable checks --------------------------
echo "-- Part A: an absent artefact must classify as UNKNOWN, not WARN --"
WT="$WORK/wt"; mkdir -p "$WT/imp/fpga/run"
OUT="$WORK/partA.txt"
"$VB" --worktree "$WT" --targets "tgtA" > "$OUT" 2>&1
A_EXIT=$?

check_line(){ # <tag> <needle>
    local tag="$1" needle="$2" line
    line=$(grep -E "^(WARN|UNKNOWN)[[:space:]]+\($tag\)" "$OUT" | head -1)
    if [ -z "$line" ]; then
        printf '   FAIL  (%s) %-28s no WARN/UNKNOWN line found\n' "$tag" "$needle"
        rc_overall=1; return
    fi
    if [[ "$line" == UNKNOWN* ]]; then
        printf '   PASS  (%s) %-28s classified UNKNOWN\n' "$tag" "$needle"
    else
        printf '   FAIL  (%s) %-28s classified WARN (should be UNKNOWN)\n' "$tag" "$needle"
        rc_overall=1
    fi
}
check_line g "dropped-XDC scan"
check_line h "OOC FF-removal scan"
check_line i "routed timing WNS"

printf '   verdict line: %s\n' "$(tail -2 "$OUT" | grep VERIFY_BUILD: || echo '(none)')"
printf '   exit code   : %s\n' "$A_EXIT"
echo

# ---- Part B: verdict mapping ----------------------------------------------
echo "-- Part B: verdict block exit-code mapping --"
VERDICT="$WORK/verdict.sh"
sed -n '/^# ----- verdict/,$p' "$VB" > "$VERDICT"
if [ ! -s "$VERDICT" ]; then
    echo "   FAIL  could not extract the verdict block from $VB"
    exit 1
fi

vcase(){ # <label> <NFAIL> <NWARN> <NUNKNOWN> <expected-exit> [waiver]
    local label="$1" nf="$2" nw="$3" nu="$4" want="$5" waiver="${6:-0}"
    local got
    got=$( NFAIL=$nf NWARN=$nw NUNKNOWN=$nu VERIFY_BUILD_ALLOW_UNVERIFIED=$waiver \
           bash -c 'set -u; NFAIL=${NFAIL}; NWARN=${NWARN}; NUNKNOWN=${NUNKNOWN}; source "$0" >/dev/null 2>&1' "$VERDICT"; echo $? )
    if [ "$got" = "$want" ]; then
        printf '   PASS  %-34s exit %s\n' "$label" "$got"
    else
        printf '   FAIL  %-34s exit %s (expected %s)\n' "$label" "$got" "$want"
        rc_overall=1
    fi
}

vcase "all clean"                        0 0 0 0
vcase "warnings only"                    0 3 0 0
vcase "a real failure"                   2 0 0 1
vcase "UNVERIFIABLE (0 fail, 1 unknown)" 0 0 1 2
vcase "unverifiable + failure"           1 0 2 1
vcase "unverifiable + explicit waiver"   0 0 1 0 1

echo
if [ $rc_overall -eq 0 ]; then echo "CONTROL_VERIFY_BUILD: PASS"; else echo "CONTROL_VERIFY_BUILD: FAIL"; fi
exit $rc_overall
