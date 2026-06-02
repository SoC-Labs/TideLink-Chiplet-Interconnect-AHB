###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - Vivado Build Driver Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Top-level Vivado TCL driver: creates project, sources block design,
### adds wrapper and constraints, runs synth/impl/bitstream and exports
### bitstream + .hwh for PYNQ overlay loading.
###
### Required environment variables:
###   FPGA_PART        - Xilinx part number (e.g. xc7z020clg400-1)
###   FPGA_PROJECT_DIR - Output directory for Vivado project
###   FPGA_IP_REPO     - Path to packaged IP repository
###   FPGA_TARGET_DIR  - Path to target-specific files (BD TCL, wrapper, XDC)
###   FPGA_OUTPUT_DIR  - Path for final outputs (.bit, .hwh, .xsa)
###   FPGA_NUM_JOBS    - Number of parallel jobs for synthesis/implementation
###
### Optional environment variables:
###   FPGA_ALLOW_CRITICAL_WARNINGS=1
###       Disables the generic post-phase CRITICAL_WARNING count check
###       (intended for exploratory / legacy builds). Does NOT disable
###       the per-message ERROR promotions below - those are always fatal
###       because they have been observed to cause silent constraint
###       regressions (e.g. 0/16 lane lock on hardware after a build that
###       otherwise "succeeded"). See fpga/docs/VIVADO_MSG_GATE.md.
###-----------------------------------------------------------------------------

###-----------------------------------------------------------------------------
### Vivado message gate
###-----------------------------------------------------------------------------
### Background: 2026-05-21 we lost a day to a silent constraint failure.
### Multiple CRITICAL WARNING classes were emitted at synth/impl time, the
### build still "PASSED", and the resulting bitstream produced 0/16 lane
### lock on hardware vs 14/16 on the previous bitstream. Observed in the
### broken build log (synth_1 + impl_1 runme.log):
###   [Constraints 18-359]  create_generated_clock: > 1 master pin matched
###   [Vivado 12-4739]      set_input/output_delay: No valid object(s)
###   [Designutils 20-1307] Command 'if'/'catch'/'file'/'info'/'get_files'
###                         not supported in XDC -> silently skipped
###   [Common 17-55]        set_property: empty selector
###   [Vivado 12-1411]      get_pins/get_cells empty filter result
###
### These are all classes of "the constraint was silently dropped". Treat
### them as hard errors so the build dies at the source, not on the bench.
###
### Gate has TWO layers:
###   1. set_msg_config -severity ERROR for each known-bad message ID
###      (always on, cannot be disabled by env-var; the IDs are surgical).
###   2. Post-synth / post-impl CRITICAL_WARNING count check (skippable via
###      FPGA_ALLOW_CRITICAL_WARNINGS=1 for exploratory builds).
###
### To add a new promotion: append to the list below with a comment
### explaining the failure mode it guards. To intentionally suppress a
### legitimate CRITICAL WARNING: use `set_msg_config -id <ID> -suppress`
### immediately after the promotion block, with a justification comment.
###
### See fpga/docs/VIVADO_MSG_GATE.md for the canonical list + rationale.
###-----------------------------------------------------------------------------
if {![info exists ::tidelink_msg_gate_installed]} {
    puts "==========================================="
    puts " Installing TideLink Vivado message gate"
    puts "==========================================="

    # [Constraints 18-359] create_generated_clock: > 1 master pin matched
    # -> derived clock is silently NOT created, downstream timing breaks.
    set_msg_config -id "Constraints 18-359"  -new_severity ERROR

    # [Vivado 12-4739] set_input/output_delay: No valid object(s) for -clock
    # or -ports -> the constraint becomes a no-op (clock or port unknown).
    set_msg_config -id "Vivado 12-4739"      -new_severity ERROR

    # [Designutils 20-1307] Procedural TCL ('if' / 'catch' / 'file' / 'info'
    # / 'get_files') is not supported inside an XDC. Anything guarded by
    # these is silently skipped.
    set_msg_config -id "Designutils 20-1307" -new_severity ERROR

    # [Common 17-55] 'set_property' expects at least one object - originally
    # promoted here for the same silent-drop class, but it has false-positives
    # at scale: Xilinx XPM IP (xpm_memory_xdc.tcl etc.) emits many benign
    # 17-55s during OOC IP synth. Symptomatic from 9+ SmartConnect MIs (see
    # docs/PHC_ALL_MIRROR_LOG.md). The other 4 promotions above
    # (Designutils 20-1307, Vivado 12-4739, 12-1411, Constraints 18-359) are
    # surgical and caught every real silent-drop seen in the lane-lock saga:
    #   - lindex/get_files in user XDC -> Designutils 20-1307
    #   - cascade from a dropped clock  -> Vivado 12-4739
    #   - empty get_pins/get_cells      -> Vivado 12-1411
    #   - multi-master generated_clock  -> Constraints 18-359
    # Common 17-55 adds little surgical coverage on top, so suppress it to
    # let Xilinx-IP OOC synth scale cleanly. Removing the ERROR promotion is
    # not enough on its own: tidelink_check_cw_count counts all CWs, and the
    # Xilinx-IP 17-55s would tip the count over 0 at scale too.
    set_msg_config -id "Common 17-55"        -suppress

    # [Vivado 12-1411] Empty result from get_pins / get_cells / get_ports
    # filter that then propagates as a silent no-op constraint.
    set_msg_config -id "Vivado 12-1411"      -new_severity ERROR

    set ::tidelink_msg_gate_installed 1
}

# Helper: check CRITICAL_WARNING count after a phase. Honours
# FPGA_ALLOW_CRITICAL_WARNINGS=1 to allow legacy/exploratory builds.
# The per-message ERROR promotions above are NOT bypassed by this env-var.
proc tidelink_check_cw_count { phase_name } {
    set cw_count [get_msg_config -count -severity {CRITICAL WARNING}]
    puts "\[tidelink_msg_gate\] CRITICAL_WARNING count after $phase_name : $cw_count"

    if { $cw_count <= 0 } {
        return
    }

    if { [info exists ::env(FPGA_ALLOW_CRITICAL_WARNINGS)]
         && $::env(FPGA_ALLOW_CRITICAL_WARNINGS) == "1" } {
        puts "\[tidelink_msg_gate\] FPGA_ALLOW_CRITICAL_WARNINGS=1 set - proceeding despite $cw_count CRITICAL WARNING(s)."
        return
    }

    puts "==========================================="
    puts " TideLink Vivado message gate FAILED"
    puts " Phase   : $phase_name"
    puts " CW count: $cw_count"
    puts "-------------------------------------------"
    puts " Dumping WARNING + CRITICAL WARNING rules"
    puts " (look in $phase_name/runme.log for the"
    puts "  exact messages and their IDs)."
    puts "-------------------------------------------"
    if { [catch { puts [get_msg_config -rules] } _err] } {
        puts "(get_msg_config -rules unavailable: $_err)"
    }
    puts "-------------------------------------------"
    puts " To bypass this check for an exploratory"
    puts " build, set FPGA_ALLOW_CRITICAL_WARNINGS=1"
    puts " in the environment. This does NOT disable"
    puts " the per-message ERROR promotions - those"
    puts " IDs will still hard-fail the build."
    puts " See fpga/docs/VIVADO_MSG_GATE.md."
    puts "==========================================="
    exit 1
}

set part        $env(FPGA_PART)
set project_dir $env(FPGA_PROJECT_DIR)
set ip_repo     $env(FPGA_IP_REPO)
# PHC IP repo (packaged separately from tidelink). Optional — if unset, the
# PHC IP is assumed absent and the BD's PHC tie-off path is used. Block
# designs that instantiate the PHC IP will fail update_ip_catalog without it.
if { [info exists env(FPGA_PHC_IP_REPO)] && $env(FPGA_PHC_IP_REPO) ne "" } {
    set phc_ip_repo $env(FPGA_PHC_IP_REPO)
} else {
    set phc_ip_repo ""
}
set target_dir  $env(FPGA_TARGET_DIR)
set output_dir  $env(FPGA_OUTPUT_DIR)

if { [info exists env(FPGA_NUM_JOBS)] } {
    set num_jobs $env(FPGA_NUM_JOBS)
} else {
    set num_jobs 4
}

puts "==========================================="
puts " TideLink Chiplet Subsystem FPGA Build"
puts " Part:    $part"
puts " Project: $project_dir"
puts " IP Repo: $ip_repo"
puts " Target:  $target_dir"
puts " Output:  $output_dir"
puts " Jobs:    $num_jobs"
puts "==========================================="

# STEP 1: Create Vivado project
create_project tidelink_project $project_dir -part $part -force

# STEP 2: Add IP repositories (tidelink + optional PHC)
if { $phc_ip_repo ne "" } {
    set_property ip_repo_paths [list $ip_repo $phc_ip_repo] [current_project]
} else {
    set_property ip_repo_paths $ip_repo [current_project]
}
update_ip_catalog

# STEP 3: Source block design
source $target_dir/tidelink_design.tcl

set design_name tidelink_design
create_bd_design $design_name
create_root_design ""

# STEP 4: Add board-level wrapper
add_files $target_dir/tidelink_design_wrapper.v
set_property top tidelink_design_wrapper [current_fileset]

# STEP 5: Add constraints
# Pin assignment XDC — used in synthesis and implementation
set pin_xdc [lindex [glob -nocomplain $target_dir/*_tidelink.xdc] 0]
if { $pin_xdc ne "" } {
    add_files -fileset constrs_1 $pin_xdc
} else {
    puts "WARNING: no pin XDC found at $target_dir/*_tidelink.xdc"
}

# Timing XDC — implementation only (set_property USED_IN_SYNTHESIS false)
set timing_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_timing.xdc] 0]
if { $timing_xdc ne "" } {
    add_files -fileset constrs_1 $timing_xdc
    set_property USED_IN_SYNTHESIS false \
        [get_files $timing_xdc]
    set_property USED_IN_IMPLEMENTATION true \
        [get_files $timing_xdc]
} else {
    puts "WARNING: no timing XDC found at $target_dir/*_tidelink_timing.xdc"
}

# DRC waiver XDC — separate file so save_constraints (which rewrites the
# timing XDC during debug-core insertion) can't strip our SEVERITY +
# ALLOW_COMBINATORIAL_LOOPS overrides. Applied during impl only (the
# combinatorial loop is post-route DRC).
set drc_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_drc.xdc] 0]
if { $drc_xdc ne "" } {
    add_files -fileset constrs_1 $drc_xdc
    set_property USED_IN_SYNTHESIS false \
        [get_files $drc_xdc]
    set_property USED_IN_IMPLEMENTATION true \
        [get_files $drc_xdc]
}

# IDELAY XDC — SoC Labs §9 structural fix. Separate file (NOT *_timing.xdc,
# which another agent owns). Carries the IODELAY_GROUP binding for the
# per-lane IDELAYE2 + IDELAYCTRL and the IOB-policy for pad_rx[*]. Applied
# in BOTH synth and impl so the IODELAY_GROUP string attribute on the cells
# is honoured by the placer/router.
#
# INCLUSION GATE (2026-05-21, fix/xdc-declarative): on a USE_IDELAY=0 build
# there are NO IDELAYE2 / IDELAYCTRL cells, so the get_cells selectors inside
# the XDC would return empty and the msg gate would hard-fail with
# Common 17-55 / Vivado 12-1411. Add the file ONLY when FPGA_USE_IDELAY=1.
# Default = 0 (preserves current pair-all/pair-flip-all behaviour where the
# RTL parameter USE_IDELAY defaults to 0). Set FPGA_USE_IDELAY=1 in the
# environment (Makefile) on builds that instantiate IDELAYE2.
set fpga_use_idelay 0
if { [info exists env(FPGA_USE_IDELAY)] && $env(FPGA_USE_IDELAY) == "1" } {
    set fpga_use_idelay 1
}
set idelay_xdc [lindex [glob -nocomplain $target_dir/*_tidelink_idelay.xdc] 0]
if { $idelay_xdc ne "" && $fpga_use_idelay == 1 } {
    add_files -fileset constrs_1 $idelay_xdc
    set_property USED_IN_SYNTHESIS true \
        [get_files $idelay_xdc]
    set_property USED_IN_IMPLEMENTATION true \
        [get_files $idelay_xdc]
    puts "INFO: FPGA_USE_IDELAY=1 - including $idelay_xdc"
} elseif { $idelay_xdc ne "" } {
    puts "INFO: FPGA_USE_IDELAY!=1 - skipping $idelay_xdc (no IDELAYE2 cells expected)"
}

# STEP 6: Generate block design outputs
# Be specific about WHICH BD - using *.bd matches nested SmartConnect
# sub-designs which can only be generated by their parent.
generate_target all [get_files ${design_name}.bd]

# STEP 7: Update compile order
update_compile_order -fileset sources_1

# STEP 8: Synthesis
puts "Starting synthesis..."
launch_runs synth_1 -jobs $num_jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if { [string match "*ERROR*" $synth_status] } {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Message gate: fail-fast if any CRITICAL WARNING slipped through synth.
# Per-message ERROR promotions above will already have hard-errored the
# run; this count check catches the long tail of CW classes we have not
# yet enumerated. Bypassable via FPGA_ALLOW_CRITICAL_WARNINGS=1.
tidelink_check_cw_count "synth_1"

# STEP 8.5: Insert ILA debug core for nets marked (* mark_debug = "true" *).
# Skipped silently if no marks present.
if { [info exists env(FPGA_INSERT_DEBUG_CORE)] && $env(FPGA_INSERT_DEBUG_CORE) == "1" } {
    set debug_tcl [file join [file dirname [info script]] insert_debug_core.tcl]
    if { [file exists $debug_tcl] } {
        puts "Inserting debug core via $debug_tcl..."
        source $debug_tcl
    }
}

# STEP 9: Implementation + Bitstream
puts "Starting implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs $num_jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"
if { [string match "*ERROR*" $impl_status] } {
    puts "ERROR: Implementation failed!"
    exit 1
}

# Message gate: fail-fast if any CRITICAL WARNING slipped through impl.
# Impl re-evaluates the *_timing.xdc and *_drc.xdc constraints, so a new
# crop of constraint-mismatch CWs can appear here that did not in synth.
# Bypassable via FPGA_ALLOW_CRITICAL_WARNINGS=1.
tidelink_check_cw_count "impl_1"

# STEP 10: Export outputs (.bit, .hwh for PYNQ, .xsa for Vitis)
file mkdir $output_dir

set bit_file [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*.bit]
if { $bit_file ne "" } {
    file copy -force $bit_file $output_dir/tidelink.bit
    puts "Bitstream copied to $output_dir/tidelink.bit"
}

# STEP 10b: Refresh .ltx from POST-IMPL design state (Build #10 fix).
# The previous .ltx was written inside insert_debug_core.tcl during the
# synth stage, BEFORE impl_1 placed/routed the debug core. Impl can
# renumber probes and drop unrouted ones, leaving a stale .ltx that
# triggers HW Manager "design has no supported soft debug core" +
# "probes file mismatch" errors. Open the impl_1 routed DCP and emit a
# fresh .ltx that matches what's actually on the device.
if { [info exists env(FPGA_INSERT_DEBUG_CORE)] && $env(FPGA_INSERT_DEBUG_CORE) == "1" } {
    set routed_dcp [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_routed.dcp]
    if { [llength $routed_dcp] > 0 } {
        puts "Refreshing .ltx from post-impl design state..."
        # Close the current in-memory project + open the routed DCP so
        # get_debug_cores / write_debug_probes operate on the FINAL netlist.
        if {[catch {
            close_design -quiet
            open_checkpoint [lindex $routed_dcp 0]
            write_debug_probes -force [file join $output_dir tidelink_design_wrapper.ltx]
            puts "Refreshed .ltx written to $output_dir/tidelink_design_wrapper.ltx"
            close_design -quiet
        } refresh_err]} {
            puts "WARN: post-impl .ltx refresh failed: $refresh_err"
            puts "WARN: continuing with synth-stage .ltx (may mismatch device)"
        }
    }
}

# .hwh is required for PYNQ - it's the IP-XACT flat hardware description.
# Look for it in the BD's hw_handoff directory.
set hwh_file [glob -nocomplain $project_dir/tidelink_project.gen/sources_1/bd/$design_name/hw_handoff/${design_name}.hwh]
if { $hwh_file eq "" } {
    # Fallback path used by older Vivado versions
    set hwh_file [glob -nocomplain $project_dir/tidelink_project.srcs/sources_1/bd/$design_name/hw_handoff/${design_name}.hwh]
}
if { $hwh_file ne "" } {
    file copy -force $hwh_file $output_dir/tidelink.hwh
    puts ".hwh copied to $output_dir/tidelink.hwh"
} else {
    puts "WARNING: .hwh file not found - PYNQ overlay loading will fail"
}

# Export hardware platform (.xsa) - useful for Vitis and as a self-contained
# bundle (the .xsa is just a zip containing .bit + .hwh + metadata).
write_hw_platform -fixed -include_bit -force $output_dir/tidelink_design.xsa

# 2026-05-24 (Agent C recommendation): preserve the routed DCP + timing
# summary report alongside the bitstream, so post-build report_timing
# analysis works without needing to re-run the build. The next build's
# launch_runs would otherwise wipe these from tidelink_project.runs/impl_1/
# (Agent C found build #18 DCP was already lost to build #19's startup
# the same day).
set routed_dcp [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_routed.dcp]
if { $routed_dcp ne "" } {
    file copy -force [lindex $routed_dcp 0] $output_dir/tidelink_design_wrapper_routed.dcp
    puts "Routed DCP copied to $output_dir/tidelink_design_wrapper_routed.dcp"
}
set timing_rpt [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*_timing_summary_routed.rpt]
if { $timing_rpt ne "" } {
    file copy -force [lindex $timing_rpt 0] $output_dir/tidelink_design_wrapper_timing_summary_routed.rpt
    puts "Timing summary copied to $output_dir/tidelink_design_wrapper_timing_summary_routed.rpt"
}

puts "==========================================="
puts " Build complete!"
puts " Bitstream: $output_dir/tidelink.bit"
puts " HWH:       $output_dir/tidelink.hwh"
puts " XSA:       $output_dir/tidelink_design.xsa"
puts "==========================================="

close_project
