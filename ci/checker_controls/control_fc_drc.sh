#!/bin/bash
# =============================================================================
# MUST-FAIL CONTROL — fc_drc scoring / stage-marker gate
#
#   ci/checker_controls/control_fc_drc.sh              test the current script
#   FC_DRC_TCL=<path> ci/.../control_fc_drc.sh         test an alternative copy
#                                                      (used to prove the
#                                                       pre-fix script goes RED)
#
# Extracts the pure-Tcl scoring region from 7_drc.tcl and executes it under
# tclsh against fabricated FC reports, so the grading can be tested with no
# fc_shell and no design. Asserts the stage verdict for five scenarios.
#
# Pre-fix, scenarios "missing-reports" and "unparseable-reports" both grade
# PASS: grep_count returns -1 for both "file absent" and "regex missed", every
# call site coerced -1 -> 0, and 0 scored as a clean check. That is the defect.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
TCL="${FC_DRC_TCL:-$root/syn/asic/fusion-compiler/scripts/7_drc.tcl}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rc_overall=0

echo "==============================================================="
echo " CONTROL: fc_drc scoring + FC_STAGE_OK gate"
echo " script under test: $TCL"
echo "==============================================================="

# ---- extract the scoring region -------------------------------------------
REGION="$WORK/region.tcl"
if grep -q 'DRC-SCORING-REGION BEGIN' "$TCL"; then
    sed -n '/DRC-SCORING-REGION BEGIN/,/DRC-SCORING-REGION END/p' "$TCL" > "$REGION"
    MODE="marked"
else
    # Legacy (pre-fix) layout: no markers. Take the scoring block from the
    # grep_count proc to the close of the summary file handle.
    sed -n '/^proc grep_count /,/^close \$sfp/p' "$TCL" > "$REGION"
    MODE="legacy"
fi
if [ ! -s "$REGION" ]; then
    echo "  FAIL: could not extract a scoring region from $TCL"
    exit 1
fi
echo "  region: $MODE, $(wc -l < "$REGION") lines"
if grep -Eqn '^[[:space:]]*(save_block|save_lib|open_lib|open_block|current_design)\b' "$REGION"; then
    echo "  FAIL: scoring region contains fc_shell commands — not purely testable"
    rc_overall=1
fi
echo

# ---- driver ---------------------------------------------------------------
cat > "$WORK/driver.tcl" <<'TCL'
set fc_reports  $::env(TEST_REPORTS)
set top_module  tidelink_top
array set drc_results {}
foreach c {pre_netlist pre_designdata pre_signoff pre_timing
           check_placement check_mv_design check_pin_placement check_clock_trees} {
    set drc_results($c) [list 0 ${fc_reports}/07_${c}.rep]
}
source $::env(TEST_REGION)
if {![info exists drc_stage_verdict]} {
    # Pre-fix script: no verdict variable existed. Reproduce the semantics it
    # actually had — CLEAN whenever total_violations == 0, and FC_STAGE_OK was
    # then emitted unconditionally regardless even of that.
    set drc_stage_verdict [expr {$total_violations == 0 ? "PASS" : "FAIL"}]
    set marker_emitted 1
} else {
    set marker_emitted [expr {$drc_stage_verdict eq "PASS"}]
}
if {![info exists total_indeterminate]} { set total_indeterminate 0 }
puts "VERDICT=$drc_stage_verdict VIOL=$total_violations UNKNOWN=$total_indeterminate MARKER=$marker_emitted"
TCL

# ---- report factory --------------------------------------------------------
mk_reports(){ # $1 = scenario dir, $2 = mode
    local d="$1" mode="$2"
    mkdir -p "$d"
    [ "$mode" = "missing" ] && return 0
    if [ "$mode" = "unparseable" ]; then
        # reports exist but the run was truncated before the count lines
        for f in check_design check_pg_connectivity check_pg_drc check_routes; do
            printf 'Starting %s ...\nReading design ...\n' "$f" > "$d/07_$f.rep"
        done
        echo "check_legality succeeded" > "$d/07_check_legality.rep"
        for c in pre_netlist pre_designdata pre_signoff pre_timing check_placement \
                 check_mv_design check_pin_placement check_clock_trees; do
            echo "Total 1 EMS messages : 0 errors" > "$d/07_$c.rep"
        done
        return 0
    fi
    # clean / violations
    echo "Total 3 EMS messages : 0 errors"                > "$d/07_check_design.rep"
    echo "check_legality succeeded"                       > "$d/07_check_legality.rep"
    { echo "Number of floating std cells: 0"
      echo "Number of floating hard macros: 0"; }         > "$d/07_check_pg_connectivity.rep"
    echo "Total number of errors found: 0"                > "$d/07_check_pg_drc.rep"
    if [ "$mode" = "violations" ]; then
        { echo "Total number of DRCs = 5"
          echo "Total number of open nets = 2"; }         > "$d/07_check_routes.rep"
    else
        { echo "Total number of DRCs = 0"
          echo "Total number of open nets = 0"; }         > "$d/07_check_routes.rep"
    fi
    for c in pre_netlist pre_designdata pre_signoff pre_timing check_placement \
             check_mv_design check_pin_placement check_clock_trees; do
        echo "Total 1 EMS messages : 0 errors" > "$d/07_$c.rep"
    done
}

run_case(){ # <label> <report-mode> <expected-verdict> <expected-marker> [env...]
    local label="$1" mode="$2" want_v="$3" want_m="$4"; shift 4
    local d="$WORK/$label"; mk_reports "$d" "$mode"
    local out got_v got_m
    out=$(env "$@" TEST_REPORTS="$d" TEST_REGION="$REGION" \
          tclsh "$WORK/driver.tcl" 2>&1 | grep '^VERDICT=' )
    got_v=$(sed -E 's/^VERDICT=([A-Z]+).*/\1/' <<<"$out")
    got_m=$(sed -E 's/.*MARKER=([01]).*/\1/'   <<<"$out")
    if [ "$got_v" = "$want_v" ] && [ "$got_m" = "$want_m" ]; then
        printf '   PASS  %-22s %s\n' "$label" "$out"
    else
        printf '   FAIL  %-22s %s\n' "$label" "$out"
        printf '         expected VERDICT=%s MARKER=%s\n' "$want_v" "$want_m"
        rc_overall=1
    fi
}

echo "-- scenarios (MARKER=1 means FC_STAGE_OK would be emitted) --"
run_case all-clean            clean       PASS          1 FC_PG_CONN_WAIVER=1
run_case with-violations      violations  FAIL          0 FC_PG_CONN_WAIVER=1
run_case missing-reports      missing     INDETERMINATE 0 FC_PG_CONN_WAIVER=1
run_case unparseable-reports  unparseable INDETERMINATE 0 FC_PG_CONN_WAIVER=1
run_case missing-but-waived   missing     PASS          1 FC_PG_CONN_WAIVER=1 FC_DRC_ALLOW_INDETERMINATE=1

echo
if [ $rc_overall -eq 0 ]; then echo "CONTROL_FC_DRC: PASS"; else echo "CONTROL_FC_DRC: FAIL"; fi
exit $rc_overall
