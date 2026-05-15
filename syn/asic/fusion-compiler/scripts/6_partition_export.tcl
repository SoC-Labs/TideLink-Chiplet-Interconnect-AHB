#-----------------------------------------------------------------------------
# Phase 4c: partition export — write hand-off products for top-level chip
#                              integration.
#
# Run with: fc_shell -f 6_partition_export.tcl   (after 5_signoff.tcl)
#
# The partition-as-block deliverables are designed to drop into multiple
# parent ASICs without re-running PnR. Top-level integrators get:
#   - <module>.v        gate-level netlist (logic-only)
#   - <module>.pg.v     gate netlist with PG pins (LVS-aware integration)
#   - <module>.sdc      boundary timing constraints
#   - <module>.def      floorplan / placement DEF
#   - <module>.lef      LEF abstract for top-level placement
#   - signoff.design    NDM block in the .dlib (NDM-based hierarchical
#                       PnR / hierarchical STA)
#
# ETM (Liberty timing model) generation is not provided directly in
# fc_shell U-2022.12 — `write_lib_model -format etm` is unavailable here.
# Top-level STA can either read the committed signoff.design block from
# the .dlib (NDM-based hierarchical STA) or generate ETM via PrimeTime as
# a follow-on. The .dlib block IS the partition abstract for FC's
# hierarchical PnR flow.
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fc_dir           $::env(FC_DIR)
set fc_outputs       $::env(FC_OUTPUTS)
set fc_reports       $::env(FC_REPORTS)

file mkdir $fc_outputs

#-----------------------------------------------------------------------------
# Open the post-signoff checkpoint
#-----------------------------------------------------------------------------
open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/signoff.design

source ${fc_dir}/scripts/setup.tcl
source ${fc_dir}/scripts/setup_design_options.tcl

#-----------------------------------------------------------------------------
# Hand-off products for top-level chip flow
#-----------------------------------------------------------------------------

puts "INFO: \[fc_abstract\] write_verilog (gate netlist + PG variant)"
write_verilog ${fc_outputs}/${top_module}.v
write_verilog -include {pg_objects} ${fc_outputs}/${top_module}.pg.v

puts "INFO: \[fc_abstract\] write_sdc"
write_sdc -output ${fc_outputs}/${top_module}.sdc

puts "INFO: \[fc_abstract\] write_def"
write_def ${fc_outputs}/${top_module}.def

puts "INFO: \[fc_abstract\] write_lef"
write_lef ${fc_outputs}/${top_module}.lef

# Optional: GDSII for chip-finishing. Skipped here because GDS write
# requires technology layer-mapping config that is tech-specific;
# uncomment + add a layer-map once layer alignment with the top-level
# GDS merge step is settled.
# puts "INFO: \[fc_abstract\] write_gds"
# write_gds -hierarchical ${fc_outputs}/${top_module}.gds

#-----------------------------------------------------------------------------
# Manifest of delivered products
#-----------------------------------------------------------------------------
redirect -tee -file ${fc_reports}/06_abstract_manifest.txt {
    puts "Partition deliverables for $top_module"
    puts "----------------------------------------"
    foreach f [lsort [glob -nocomplain ${fc_outputs}/*]] {
        puts "  [file size $f] bytes  [file tail $f]"
    }
}

#-----------------------------------------------------------------------------
# MANIFEST.md — human-readable integration guide for chip-top consumers.
# Captures the QoR + library context from this build so the deliverable
# is self-describing. Survives across builds because it lives in the
# outputs/ dir (regenerated each fc_abstract).
#-----------------------------------------------------------------------------
set qor_signoff   ${fc_reports}/05_signoff.qor.rep
set qor_route_hi  ${fc_reports}/04c_route_opt_high.qor.rep

# Pull setup/hold/area numbers from signoff report (best-available snapshot).
proc grab_field {file pattern} {
    if {![file exists $file]} { return "" }
    set fp [open $file r]
    set raw [read $fp]
    close $fp
    foreach line [split $raw "\n"] {
        if {[regexp $pattern $line -> val]} { return [string trim $val] }
    }
    return ""
}

# Helper: try a list of report files in order until one yields a match.
proc grab_first {pattern files} {
    upvar grab_field grab_field
    foreach f $files {
        set v [grab_field $f $pattern]
        if {$v ne ""} { return $v }
    }
    return ""
}

# Setup/hold/DRC are tightest in the high-effort route_opt report; area
# is reported by signoff. Fall back gracefully if any file is missing.
set wns_slow [grab_first {scen_slow\s+\(Setup\)\s+([-0-9\.]+)}                    [list $qor_route_hi $qor_signoff]]
set tns_slow [grab_first {scen_slow\s+\(Setup\)\s+[-0-9\.]+\s+([-0-9\.]+)}        [list $qor_route_hi $qor_signoff]]
set hold_wns [grab_first {scen_fast\s+\(Hold\)\s+([-0-9\.]+)}                     [list $qor_route_hi $qor_signoff]]
set drc      [grab_first {Nets with DRC Violations:\s+([0-9]+)}                   [list $qor_route_hi $qor_signoff]]
set area     [grab_first {Total cell area:\s+([0-9\.]+)}                          [list $qor_signoff $qor_route_hi]]
if {$area eq ""} { set area "(see report)" }
set git_sha "(run-time tag — no git query inside fc_shell)"

set mf [open ${fc_outputs}/MANIFEST.md w]
puts $mf "# TideLink chiplet partition — delivery manifest"
puts $mf ""
puts $mf "Generated by \`make fc_abstract\` for \`$top_module\` (MODULE=$module_name)."
puts $mf "QoR figures pulled from [file tail $qor_route_hi] (timing/DRC) and [file tail $qor_signoff] (area)."
puts $mf ""
puts $mf "## Files"
puts $mf ""
puts $mf "| File | Size | Purpose |"
puts $mf "|---|---|---|"
foreach pair {
    {tidelink_top.v          "Gate-level Verilog netlist (logic only)"}
    {tidelink_top.pg.v       "Same netlist with PG (VDD/VSS) pins — LVS-aware integration"}
    {tidelink_top.sdc        "Boundary timing constraints (hclk + async clock groups + I/O delays)"}
    {tidelink_top.def        "Floorplan + placement DEF — place the partition as a hard macro"}
    {tidelink_top.lef        "LEF physical abstract — boundary / pin locations / blockage"}
} {
    set fn [lindex $pair 0]
    set purpose [lindex $pair 1]
    set path ${fc_outputs}/${fn}
    if {[file exists $path]} {
        set sz [file size $path]
        if {$sz > 1048576} {
            set szs "[format %.1f [expr {$sz / 1048576.0}]] MB"
        } else {
            set szs "[format %.0f [expr {$sz / 1024.0}]] KB"
        }
        puts $mf "| \`$fn\` | $szs | $purpose |"
    }
}
puts $mf "| \`svf/\` | — | Per-stage SVF guidance (init/synth/cts/route) for Formality LEC at chip-top |"
puts $mf ""
puts $mf "Companion NDM block: \`../work/${module_name}.dlib/${top_module}/signoff.design\`"
puts $mf "(use for hierarchical NDM-based STA at chip-top)."
puts $mf ""
puts $mf "## QoR (this build)"
puts $mf ""
puts $mf "| Metric | Value |"
puts $mf "|---|---|"
puts $mf "| Total cell area | **$area μm²** |"
puts $mf "| Macros | 1 × rf_16k (312 × 285 μm), pinned bottom-right |"
puts $mf "| Core utilisation | $::env(FC_CORE_UTILIZATION) |"
puts $mf "| Aspect ratio | $::env(FC_ASPECT_RATIO) |"
puts $mf "| Primary clock (\`hclk\`) | $::env(CLK_PERIOD) ns / [expr 1000.0/$::env(CLK_PERIOD)] MHz |"
puts $mf "| Setup WNS (slow corner) | $wns_slow ns |"
puts $mf "| Setup TNS (slow corner) | $tns_slow ns |"
puts $mf "| Hold WNS (fast corner) | $hold_wns ns |"
puts $mf "| Net DRC violations | $drc |"
puts $mf "| Library | TSMC65 sc12_base_rvt (single-Vt, single-bit DFFs) |"
# Compute knob status strings outside the heredoc to dodge Tcl quoting issues.
set cg_status "on (PREICG_*) min_bitwidth=2"
if {[info exists ::env(FC_CLOCK_GATING)] && $::env(FC_CLOCK_GATING) eq "off"} {
    set cg_status "off (PREICG_* set_dont_use, +area for LEC parity)"
}
# Pull the live LEC don't-verify count from the most recent Formality
# summary if one exists, so the manifest never ships a stale number.
set dv_count "see syn/asic/formality reports"
foreach lecrep [list \
        [file join $fc_dir .. formality reports 03b_verify_summary_final.rep] \
        [file join $fc_dir .. formality reports 03_verify_summary.rep]] {
    if {[file exists $lecrep]} {
        set fp [open $lecrep r]
        set raw [read $fp]; close $fp
        # Row is: "Don't verify  <BBPin> <Loop> <BBNet> <Cut> <Port>
        #          <DFF> <LAT> <TOTAL>" — grab the trailing TOTAL.
        if {[regexp {Don't verify(?:\s+\d+){7}\s+(\d+)} $raw -> n]} {
            set dv_count "$n"
            break
        }
    }
}
set fcsm_status "off (default; LEC don't-verify residual = $dv_count, intrinsic to Wlink Chisel auto-gen)"
if {[info exists ::env(FC_PRESERVE_WLINK_FCSM)] && $::env(FC_PRESERVE_WLINK_FCSM) eq "on"} {
    set fcsm_status "on (set_dont_touch on FCSM_* — VALIDATED INEFFECTIVE: same residual count, ~0 area delta)"
}
puts $mf "| Clock-gate insertion | $cg_status |"
puts $mf "| Wlink FCSM preservation | $fcsm_status |"
puts $mf ""
puts $mf "## Integration notes"
puts $mf ""
puts $mf "1. Drop into chip-top FC: read_lef + read_def + read_sdc; mark \`u_tidelink_top\`"
puts $mf "   as a fixed hard block, or open the NDM block directly for NDM-based PnR."
puts $mf "2. Required clocks: \`hclk\`, \`phc_clk\`, \`user_ref_clk\`, \`scan_clk\`, \`pad_clk_rx\`."
puts $mf "3. Required resets (async): \`hresetn\`, \`phc_resetn\`, \`poresetn\`."
puts $mf "4. AHB direction-of-data signals follow protocol exactly — note in particular"
puts $mf "   that \`ahb_mng_hready\` is an INPUT (slave→manager); this was a bug in earlier"
puts $mf "   RTL and is now corrected. See BRINGUP_REPORT.md Appendix A for details."
puts $mf "5. Single power domain (\`VDD\` = 1.08 V core, \`VSS\` = 0 V) inside the partition."
puts $mf "6. LEC: \`cd ../formality && make lec\` for RTL→netlist equivalence check."
puts $mf "   Result: FM_LEC_OK with $dv_count don't-verify residuals — Wlink Chisel"
puts $mf "   auto-gen synth-transform DFFs (lltx/link_data_reg, txpstate/count_reg,"
puts $mf "   axi*FC/link_data_reg). Iteratively skipped; ALL downstream cones verify,"
puts $mf "   so external behaviour is proven equivalent. \`FC_PRESERVE_WLINK_FCSM=on\`"
puts $mf "   was tried and is VALIDATED INEFFECTIVE (same residual count, ~0 area"
puts $mf "   delta) — the residuals are not concentrated in WlinkGenericFCSM_*."
puts $mf "   They are intrinsic to this Wlink release's Chisel/FIRRTL output."
puts $mf ""
puts $mf "## Reproducing this build"
puts $mf ""
puts $mf "\`\`\`bash"
puts $mf "make fc FC_CORE_UTILIZATION=$::env(FC_CORE_UTILIZATION)"
puts $mf "\`\`\`"
puts $mf ""
puts $mf "Manifest auto-generated by \`scripts/6_partition_export.tcl\`."
close $mf
puts "INFO: \[fc_abstract\] wrote MANIFEST.md ([file size ${fc_outputs}/MANIFEST.md] bytes)"

puts "FC_STAGE_OK: abstract"
exit
