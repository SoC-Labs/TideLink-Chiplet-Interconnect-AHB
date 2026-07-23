###-----------------------------------------------------------------------------
### TideLink - Vivado message gate: CHILD-run POST-step checker
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
### David Mapstone (d.a.mapstone@soton.ac.uk)  Copyright (C) 2026, SoC Labs
###-----------------------------------------------------------------------------
### WHY THIS EXISTS
###
### The parent-session `tidelink_check_cw_count` was BLIND to synth_1 / impl_1
### CRITICAL WARNINGs because those run in child processes (the parent counted
### its own session -> always 0). This file runs the SAME gate INSIDE the child.
### Wired as STEPS.SYNTH_DESIGN.TCL.POST and STEPS.ROUTE_DESIGN.TCL.POST so it
### fires right after the step, in the child interpreter where the CWs actually
### live, and `error`s the run (-> run STATUS=ERROR -> build_design.tcl exit 1)
### on a violation.
###
### It performs two checks:
###   1. CRITICAL WARNING count for THIS child step (honours
###      FPGA_ALLOW_CRITICAL_WARNINGS=1 like the parent gate).
###   2. Combinational-loop DRC (LUTLP-1) - only meaningful once a routed design
###      exists, so it is guarded and silently skipped at synth POST. This is the
###      real cb33c9f-class catch: report_drc respects the ALLOW_COMBINATORIAL_
###      LOOPS waivers, so only NEW/accidental loops are reported.
###-----------------------------------------------------------------------------

# Re-assert the promotions in case this POST hook runs in a context where the
# matching PRE hook did not (belt-and-suspenders; idempotent).
catch { source [file join [file dirname [info script]] msg_gate_child_promote.tcl] }

# --- check 1: CRITICAL WARNING count (child-visible) -----------------------
set _cw [get_msg_config -count -severity {CRITICAL WARNING}]
puts "\[tidelink_msg_gate/child\] CRITICAL_WARNING count this step : $_cw"
if { $_cw > 0 } {
    if { [info exists ::env(FPGA_ALLOW_CRITICAL_WARNINGS)]
         && $::env(FPGA_ALLOW_CRITICAL_WARNINGS) == "1" } {
        puts "\[tidelink_msg_gate/child\] FPGA_ALLOW_CRITICAL_WARNINGS=1 - proceeding despite $_cw CW(s)."
    } else {
        puts "==========================================="
        puts " TideLink message gate FAILED (in child run)"
        puts " CRITICAL WARNING count: $_cw"
        puts " See this run's runme.log for the exact IDs."
        puts " Bypass exploratory builds with FPGA_ALLOW_CRITICAL_WARNINGS=1."
        puts "==========================================="
        error "tidelink_msg_gate/child: $_cw CRITICAL WARNING(s) in this step"
    }
}

# --- provenance: stamp git SHA into the bitstream USR_ACCESS register ------
# build_design.tcl exports TIDELINK_GIT_USR_ACCESS (low 32 bits of the CLEAN
# git SHA, "0xXXXXXXXX") into the child env. Set it on the routed impl design
# BEFORE write_bitstream so the built .bit carries the source SHA in its
# USR_ACCESS register (read back on-silicon via the USR_ACCESSE2 primitive /
# JTAG to prove exactly which commit is loaded). Only stamped for a clean tree
# (build_design.tcl leaves the env var unset when dirty, so a non-reproducible
# bitstream is never mislabelled with a commit SHA).
if { [info exists ::env(TIDELINK_GIT_USR_ACCESS)] && $::env(TIDELINK_GIT_USR_ACCESS) ne "" } {
    if { ![catch { set_property BITSTREAM.CONFIG.USR_ACCESS $::env(TIDELINK_GIT_USR_ACCESS) [current_design] } _uaerr] } {
        puts "\[tidelink_msg_gate/child\] stamped BITSTREAM.CONFIG.USR_ACCESS=$::env(TIDELINK_GIT_USR_ACCESS) (git SHA low32)"
    } else {
        puts "\[tidelink_msg_gate/child\] USR_ACCESS stamp skipped ($_uaerr)"
    }
}

# --- check 2: combinational-loop DRC (LUTLP-1) -----------------------------
# Only run when a fully-routed design is in memory (route POST). Guarded so the
# synth POST invocation (no placed/routed design) is a clean no-op.
if { ![catch { get_property ROUTE_STATUS [current_design] } _rs] && $_rs eq "ROUTED" } {
    if { ![catch { report_drc -checks {LUTLP-1} -name tl_combloop_drc } _drcerr] } {
        set _viols [get_drc_violations -name tl_combloop_drc]
        set _nv [llength $_viols]
        puts "\[tidelink_msg_gate/child\] combinational-loop (LUTLP-1) violations: $_nv"
        if { $_nv > 0 } {
            puts "==========================================="
            puts " TideLink message gate FAILED (in child run)"
            puts " UN-WAIVED combinational loop(s): $_nv"
            foreach _v $_viols {
                catch { puts "   - $_v : [get_property DESCRIPTION $_v]" }
            }
            puts "-------------------------------------------"
            puts " This is the cb33c9f class (silicon write-vanish)."
            puts " If the loop is INTENTIONAL, waive that specific net"
            puts " with ALLOW_COMBINATORIAL_LOOPS in *_tidelink_drc.xdc;"
            puts " otherwise fix the RTL."
            puts "==========================================="
            error "tidelink_msg_gate/child: $_nv un-waived combinational loop(s)"
        }
    } else {
        puts "\[tidelink_msg_gate/child\] report_drc LUTLP-1 unavailable ($_drcerr) - skipped."
    }
}
