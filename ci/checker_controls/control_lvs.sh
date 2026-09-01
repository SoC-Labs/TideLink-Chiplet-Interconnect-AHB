#!/bin/bash
# =============================================================================
# MUST-FAIL CONTROL — Calibre LVS verdict grading
#
# Red without the fix, green with it. Run: ci/checker_controls/control_lvs.sh
#
# Section 1 replays the SHIPPED-BUGGY grading logic verbatim to demonstrate the
# defect (INCORRECT graded as CORRECT). It is informational and never gates.
# Section 2 asserts the FIXED helper's three-outcome verdict on every fixture
# and IS the gate.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
FIX="$root/syn/asic/calibre/scripts/lvs_verdict.sh"
FIXTURES="$root/ci/fixtures"

rc_overall=0
note(){ printf '  %s\n' "$*"; }

echo "==============================================================="
echo " CONTROL: Calibre LVS verdict grading"
echo "==============================================================="
echo
# -- Section 0: the fixtures themselves must be present and non-vacuous -----
# A control whose inputs are missing grades nothing and reports success. The
# repo's blanket '*.rep' ignore rule already swallowed these once; assert
# rather than trust.
for f in lvs-missing-connection lvs-clean lvs-truncated; do
    rep="$FIXTURES/$f/tidelink_top_lvs.rep"
    if [ ! -s "$rep" ]; then
        echo "  FAIL: fixture $rep is missing or empty — this control would be vacuous."
        echo "        (is it excluded by .gitignore's '*.rep' rule?)"
        exit 1
    fi
done
n_inc=$(grep -Ec '(^|[^A-Za-z])INCORRECT([^A-Za-z]|$)' "$FIXTURES/lvs-missing-connection/tidelink_top_lvs.rep")
n_cor=$(grep -Ec '(^|[^A-Za-z])CORRECT([^A-Za-z]|$)'   "$FIXTURES/lvs-missing-connection/tidelink_top_lvs.rep")
if [ "$n_inc" -lt 1 ] || [ "$n_cor" -ne 0 ]; then
    echo "  FAIL: lvs-missing-connection fixture is not the intended must-fail case"
    echo "        (INCORRECT lines=$n_inc, standalone-CORRECT lines=$n_cor; want >=1 and 0)"
    exit 1
fi
echo "  fixtures ok: lvs-missing-connection has $n_inc INCORRECT line(s), $n_cor standalone CORRECT"
echo
echo "-- Section 1: the SHIPPED-BUGGY logic, replayed on each fixture --"
echo "   (if grep -q CORRECT ... elif grep -q INCORRECT ...)"
for f in lvs-missing-connection lvs-clean lvs-truncated lvs-empty; do
    rep="$FIXTURES/$f/tidelink_top_lvs.rep"
    if grep -q "CORRECT" "$rep" 2>/dev/null; then        legacy="LVS CORRECT"
    elif grep -q "INCORRECT" "$rep" 2>/dev/null; then    legacy="LVS INCORRECT"
    else                                                 legacy="indeterminate"
    fi
    printf '   %-26s -> %s\n' "$f" "$legacy"
done
echo
echo "   ^ note lvs-missing-connection graded 'LVS CORRECT'. That is the bug:"
echo "     3 uppercase INCORRECT tokens, 0 standalone CORRECT tokens."
echo

echo "-- Section 2: the FIXED helper (GATING) --"
if [ ! -x "$FIX" ]; then
    echo "  FAIL: $FIX missing or not executable"
    exit 1
fi

check(){ # <label> <report-path> <expected-verdict> <expected-exit>
    local label="$1" rep="$2" want_v="$3" want_rc="$4"
    local out got_rc got_v
    out="$("$FIX" "$rep" 2>&1)"; got_rc=$?
    got_v="${out%%:*}"
    if [ "$got_v" = "$want_v" ] && [ "$got_rc" = "$want_rc" ]; then
        printf '   PASS  %-26s -> %-19s (exit %s)\n' "$label" "$got_v" "$got_rc"
    else
        printf '   FAIL  %-26s -> %-19s (exit %s)  EXPECTED %s (exit %s)\n' \
               "$label" "$got_v" "$got_rc" "$want_v" "$want_rc"
        note "output: $out"
        rc_overall=1
    fi
}

check "lvs-missing-connection"  "$FIXTURES/lvs-missing-connection/tidelink_top_lvs.rep" "INCORRECT"          1
check "lvs-clean"               "$FIXTURES/lvs-clean/tidelink_top_lvs.rep"              "CORRECT"            0
check "lvs-truncated"           "$FIXTURES/lvs-truncated/tidelink_top_lvs.rep"          "COULD-NOT-EVALUATE" 2
check "lvs-empty"               "$FIXTURES/lvs-empty/tidelink_top_lvs.rep"              "COULD-NOT-EVALUATE" 2
check "no-report-at-all"        "$FIXTURES/lvs-does-not-exist/nope.rep"                 "COULD-NOT-EVALUATE" 2

echo
echo "-- Section 3: run_calibre_lvs.sh must EXIT NON-ZERO on a bad verdict --"
# The script used to end with an unconditional 'CALIBRE_LVS_OK' + exit 0, so
# even a correctly-graded INCORRECT could not fail 'make lvs'. Assert the
# verdict is now wired to the exit status.
if grep -q 'lvs_verdict.sh' "$root/syn/asic/calibre/scripts/run_calibre_lvs.sh" \
   && grep -q 'LVS_VERDICT_RC' "$root/syn/asic/calibre/scripts/run_calibre_lvs.sh"; then
    printf '   PASS  %-26s -> verdict wired to exit status\n' "run_calibre_lvs.sh"
else
    printf '   FAIL  %-26s -> verdict NOT wired to exit status\n' "run_calibre_lvs.sh"
    rc_overall=1
fi

echo
if [ $rc_overall -eq 0 ]; then
    echo "CONTROL_LVS: PASS"
else
    echo "CONTROL_LVS: FAIL"
fi
exit $rc_overall
