#!/bin/bash
# =============================================================================
# MUST-FAIL CONTROL — Vivado child message gate (both layers)
#
#   ci/checker_controls/control_msg_gate.sh
#   MSG_GATE_DIR=<dir> ...   grade an alternative copy of the two scripts
#                            (used to prove the pre-fix pair goes RED)
#
# Runs msg_gate_child_promote.tcl / msg_gate_child_check.tcl under tclsh with
# stubbed Vivado commands, so the failure paths can be exercised with no
# Vivado and no design. "RAISED" means the script errored, which in a
# STEPS.*.TCL.PRE/POST hook fails the run.
# =============================================================================
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
DIR="${MSG_GATE_DIR:-$root/fpga/scripts}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
rc_overall=0

echo "==============================================================="
echo " CONTROL: Vivado child message gate"
echo " scripts under test: $DIR"
echo "==============================================================="

# $1 label  $2 expected RAISED|CLEAN  $3 script(promote|check)  $4 stub-tcl  [env...]
run_case(){
    local label="$1" want="$2" which="$3" stubs="$4"; shift 4
    local drv="$WORK/drv.tcl"
    {
        cat "$stubs"
        echo "if {[catch { source \"$DIR/msg_gate_child_${which}.tcl\" } e]} {"
        echo "    puts \"RESULT=RAISED\""
        echo "} else { puts \"RESULT=CLEAN\" }"
    } > "$drv"
    local got
    got=$(env "$@" tclsh "$drv" 2>&1 | grep -o 'RESULT=[A-Z]*' | tail -1)
    got="${got#RESULT=}"
    [ -z "$got" ] && got="CRASH"
    if [ "$got" = "$want" ]; then
        printf '   PASS  %-28s got %-6s want %s\n' "$label" "$got" "$want"
    else
        printf '   FAIL  %-28s got %-6s want %s\n' "$label" "$got" "$want"
        rc_overall=1
    fi
}

# ---- stub sets -------------------------------------------------------------
mkstub(){ cat > "$WORK/$1.tcl"; }

mkstub happy <<'T'
proc set_msg_config args {
    if {[lindex $args 0] eq "-count"} { return 0 }
    return
}
proc get_msg_config args { return 0 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "ROUTED" }; return "" }
proc report_drc args {}
proc get_drc_violations args { return {} }
T

# a message ID this Vivado release renamed: set_msg_config throws for it
mkstub renamed_id <<'T'
proc set_msg_config args {
    if {[lindex $args 0] eq "-count"} { return 0 }
    if {[lsearch -exact $args "Vivado 12-1411"] >= 0} {
        error "\[Common 17-69\] Command failed: unknown message id 'Vivado 12-1411'"
    }
    return
}
proc get_msg_config args { return 0 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "ROUTED" }; return "" }
proc report_drc args {}
proc get_drc_violations args { return {} }
T

# LUTLP-1 absent: get_drc_checks returns nothing, set_property on {} is a no-op
mkstub no_lutlp <<'T'
proc set_msg_config args { if {[lindex $args 0] eq "-count"} { return 0 }; return }
proc get_msg_config args { return 0 }
proc get_drc_checks args { return {} }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "ROUTED" }; return "" }
proc report_drc args {}
proc get_drc_violations args { return {} }
T

# synth POST: no routed design in memory, ROUTE_STATUS unreadable
mkstub synth_post <<'T'
proc set_msg_config args { if {[lindex $args 0] eq "-count"} { return 0 }; return }
proc get_msg_config args { return 0 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { error "no such property ROUTE_STATUS on a synthesized design" }
proc report_drc args {}
proc get_drc_violations args { return {} }
T

# route POST but the design is NOT routed
mkstub unrouted <<'T'
proc set_msg_config args { if {[lindex $args 0] eq "-count"} { return 0 }; return }
proc get_msg_config args { return 0 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "UNROUTED" }; return "" }
proc report_drc args {}
proc get_drc_violations args { return {} }
T

# report_drc itself fails on a routed design (check renamed / unavailable)
mkstub drc_broken <<'T'
proc set_msg_config args { if {[lindex $args 0] eq "-count"} { return 0 }; return }
proc get_msg_config args { return 0 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "ROUTED" }; return "" }
proc report_drc args { error "\[Vivado 12-1682\] no such DRC check 'LUTLP-1'" }
proc get_drc_violations args { return {} }
T

# a real un-waived combinational loop (must still fail, as it always did)
mkstub real_loop <<'T'
proc set_msg_config args { if {[lindex $args 0] eq "-count"} { return 0 }; return }
proc get_msg_config args { return 0 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "ROUTED" }; return "" }
proc report_drc args {}
proc get_drc_violations args { return [list viol_a viol_b] }
T

# a real CRITICAL WARNING (must still fail, as it always did)
mkstub real_cw <<'T'
proc set_msg_config args { return }
proc get_msg_config args { return 3 }
proc get_drc_checks args { return [list LUTLP-1] }
proc set_property args {}
proc current_design args { return design_1 }
proc get_property {prop obj} { if {$prop eq "ROUTE_STATUS"} { return "ROUTED" }; return "" }
proc report_drc args {}
proc get_drc_violations args { return {} }
T

echo "-- layer 1: promotion installer (msg_gate_child_promote.tcl) --"
run_case "all-ids-valid"            CLEAN  promote "$WORK/happy.tcl"
run_case "renamed-message-id"       RAISED promote "$WORK/renamed_id.tcl"
run_case "LUTLP-1-absent"           RAISED promote "$WORK/no_lutlp.tcl"
run_case "renamed-id + waiver"      CLEAN  promote "$WORK/renamed_id.tcl" FPGA_ALLOW_MSG_GATE_DEGRADED=1

echo "-- layer 2: POST checker (msg_gate_child_check.tcl) --"
run_case "routed, clean"            CLEAN  check "$WORK/happy.tcl"
run_case "synth POST (n/a)"         CLEAN  check "$WORK/synth_post.tcl"
run_case "route POST, UNROUTED"     RAISED check "$WORK/unrouted.tcl"
run_case "report_drc unavailable"   RAISED check "$WORK/drc_broken.tcl"
run_case "promotion failed upstream" RAISED check "$WORK/renamed_id.tcl"
echo "-- regressions: real defects must still fail --"
run_case "real comb-loop violation" RAISED check "$WORK/real_loop.tcl"
run_case "real CRITICAL WARNING"    RAISED check "$WORK/real_cw.tcl"

echo
if [ $rc_overall -eq 0 ]; then echo "CONTROL_MSG_GATE: PASS"; else echo "CONTROL_MSG_GATE: FAIL"; fi
exit $rc_overall
