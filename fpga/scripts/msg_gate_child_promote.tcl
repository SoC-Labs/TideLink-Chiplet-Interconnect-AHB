###-----------------------------------------------------------------------------
### TideLink - Vivado message gate: CHILD-run promotion installer
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
### David Mapstone (d.a.mapstone@soton.ac.uk)  Copyright (C) 2026, SoC Labs
###-----------------------------------------------------------------------------
### WHY THIS EXISTS
###
### build_design.tcl installs the set_msg_config -> ERROR promotions in the
### PARENT Vivado session, but `launch_runs synth_1` / `impl_1` fork CHILD
### processes with their OWN Tcl interpreter and message-config state. The
### parent's promotions do NOT propagate into the child, so a CRITICAL WARNING
### (or a combinational-loop DRC) emitted DURING synth/route was never promoted
### and the parent's post-phase count saw "0". This file re-installs the
### promotions INSIDE the child; it is wired as STEPS.SYNTH_DESIGN.TCL.PRE and
### STEPS.ROUTE_DESIGN.TCL.PRE so the severity changes are active BEFORE the
### step emits its messages / runs its DRC. Idempotent.
###
### Canonical list + rationale: fpga/docs/VIVADO_MSG_GATE.md. Keep in sync with
### the Layer-1 block in fpga/build_design.tcl and package_tidelink_ip.tcl.
###-----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# WHY THESE ARE NO LONGER BARE `catch { ... }`
#
# Every promotion below used to be wrapped in a bare catch with no error
# branch. A catch with no branch is not error handling, it is error deletion:
# if Vivado renamed a message ID between releases, set_msg_config threw, the
# catch ate it, and the gate installed NOTHING — while still looking exactly
# like a gate that had installed everything. The whole point of this file is
# that the parent's promotions do not reach the child; a silently empty child
# promotion set puts us back to the bug it was written to fix, undetectably.
#
# Each promotion is now applied through tl_msg_gate_apply, which records
# whether it took. Three outcomes, never two: INSTALLED / FAILED /
# COULD-NOT-VERIFY. Anything that is not INSTALLED raises an error at the end
# of this file, which fails the synth/route step — because a message gate that
# cannot prove it armed itself is not a gate.
#
# Escape hatch for an exploratory build, matching the FPGA_ALLOW_CRITICAL_
# WARNINGS convention already used by msg_gate_child_check.tcl:
#   FPGA_ALLOW_MSG_GATE_DEGRADED=1
# ---------------------------------------------------------------------------
set _tl_mg_failed {}
set _tl_mg_ok     {}

proc tl_msg_gate_apply {what script} {
    global _tl_mg_failed _tl_mg_ok
    if {[catch {uplevel 1 $script} _e]} {
        lappend _tl_mg_failed "$what -> $_e"
        puts "\[tidelink_msg_gate/child\] ERROR: could not install: $what : $_e"
        return 0
    }
    lappend _tl_mg_ok $what
    return 1
}

# [Constraints 18-359] create_generated_clock: > 1 master pin matched -> derived
#   clock silently NOT created, downstream timing breaks.
tl_msg_gate_apply "promote Constraints 18-359 -> ERROR" \
    { set_msg_config -id "Constraints 18-359"  -new_severity ERROR }
# [Vivado 12-4739] set_input/output_delay: No valid object(s) -> no-op constraint.
tl_msg_gate_apply "promote Vivado 12-4739 -> ERROR" \
    { set_msg_config -id "Vivado 12-4739"      -new_severity ERROR }
# [Designutils 20-1307] procedural TCL not supported inside XDC -> silently skipped.
tl_msg_gate_apply "promote Designutils 20-1307 -> ERROR" \
    { set_msg_config -id "Designutils 20-1307" -new_severity ERROR }
# [Vivado 12-1411] empty get_pins/get_cells/get_ports filter -> silent no-op constraint.
tl_msg_gate_apply "promote Vivado 12-1411 -> ERROR" \
    { set_msg_config -id "Vivado 12-1411"      -new_severity ERROR }
# [Common 17-55] suppressed (benign Xilinx-IP OOC noise) - matches build_design.tcl.
tl_msg_gate_apply "suppress Common 17-55" \
    { set_msg_config -id "Common 17-55"        -suppress }

# COMBINATIONAL-LOOP guard (cb33c9f-class): an unintended combinational loop
# (e.g. the ahb_sub HREADY loopback that vanished silicon writes) is flagged by
# the LUTLP-1 DRC. INTENTIONAL loops are individually waived in *_tidelink_drc.xdc
# via ALLOW_COMBINATORIAL_LOOPS, so LUTLP-1 only fires on UN-waived (i.e. new,
# accidental) loops - exactly the regression class we want to hard-fail. Promote
# the DRC check to ERROR so write_bitstream's DRC dies at the source. The
# msg_gate_child_check.tcl POST hook ALSO runs report_drc -checks LUTLP-1
# explicitly, because write_bitstream's pre-DRC has historically ignored the
# severity change in Vivado 2024.1 (see the note in *_tidelink_drc.xdc).
#
# NB set_property on an EMPTY object list is a silent no-op in Vivado, not an
# error — so a renamed/absent LUTLP-1 would install nothing without throwing.
# The object list is checked explicitly before use.
tl_msg_gate_apply "promote DRC check LUTLP-1 -> ERROR" {
    set _lutlp [get_drc_checks LUTLP-1]
    if {[llength $_lutlp] != 1} {
        error "get_drc_checks LUTLP-1 returned [llength $_lutlp] object(s), expected 1 — check renamed or unavailable in this Vivado build"
    }
    set_property SEVERITY {ERROR} $_lutlp
}

# ---------------------------------------------------------------------------
# Verdict. An un-armed gate must not look like an armed one.
# ---------------------------------------------------------------------------
puts "\[tidelink_msg_gate/child\] promotions installed: [llength $_tl_mg_ok]/[expr {[llength $_tl_mg_ok] + [llength $_tl_mg_failed]}]"
if {[llength $_tl_mg_failed] > 0} {
    puts "==========================================="
    puts " TideLink message gate COULD NOT ARM (child run)"
    puts " [llength $_tl_mg_failed] promotion(s) did NOT install:"
    foreach _f $_tl_mg_failed { puts "   - $_f" }
    puts "-------------------------------------------"
    puts " A message ID or DRC check was probably renamed by this Vivado"
    puts " release. Until it is re-mapped, the CRITICAL WARNING and"
    puts " combinational-loop guards are NOT active for this step, and a"
    puts " green build would mean nothing."
    puts " Bypass exploratory builds with FPGA_ALLOW_MSG_GATE_DEGRADED=1."
    puts "==========================================="
    if {[info exists ::env(FPGA_ALLOW_MSG_GATE_DEGRADED)]
        && $::env(FPGA_ALLOW_MSG_GATE_DEGRADED) == "1"} {
        puts "\[tidelink_msg_gate/child\] FPGA_ALLOW_MSG_GATE_DEGRADED=1 - proceeding with a DEGRADED gate."
    } else {
        error "tidelink_msg_gate/child: [llength $_tl_mg_failed] promotion(s) failed to install"
    }
}
