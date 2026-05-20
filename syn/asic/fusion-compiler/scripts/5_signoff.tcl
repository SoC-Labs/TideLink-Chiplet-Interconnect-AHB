#-----------------------------------------------------------------------------
# Phase 4b: signoff — final QoR + chip-finish (fillers).
#
# Run with: fc_shell -f 5_signoff.tcl   (after 4_route.tcl)
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fc_dir           $::env(FC_DIR)
set fc_logs          $::env(FC_LOGS)
set fc_reports       $::env(FC_REPORTS)

#-----------------------------------------------------------------------------
# Open the post-route-PG checkpoint. pg.design = route.design after the
# Phase-4a std-cell rail rebind (pg_rails.tcl). Signoff QoR / SPEF must
# be on the stitched PG, not the pre-stitch route.design — otherwise
# the per-scenario SPEF that 6_partition_export.tcl writes is on a
# block whose M1 PG rails are not bound to VDD/VSS.
#-----------------------------------------------------------------------------
open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/pg.design

source ${fc_dir}/scripts/setup.tcl
source ${fc_dir}/scripts/setup_design_options.tcl

#-----------------------------------------------------------------------------
# Signoff-quality parasitic extraction. fc_shell U-2022.12 has no
# standalone `extract_parasitics` command — RC extraction is driven
# implicitly by a full timing update against the bound TLU+ tech.
# `update_timing -full` forces that recompute across every active
# scenario so the QoR below and the SPEF written in
# 6_partition_export.tcl are on real extracted RC, not the route-
# estimate carried over from route.design.
#
# Guarded: a TLU+ binding / extraction failure must not silently
# produce a signoff block with stale RC — fail the stage loudly
# instead.
#-----------------------------------------------------------------------------
puts "INFO: \[fc_signoff\] update_timing -full (signoff RC for QoR + SPEF)"
if {[catch {update_timing -full} ep_err]} {
    puts "ERROR: \[fc_signoff\] update_timing -full failed: $ep_err"
    puts "ERROR: \[fc_signoff\] signoff QoR + exported SPEF would be on stale"
    puts "ERROR: \[fc_signoff\] route-estimate RC — not touching FC_STAGE_OK."
    exit 1
}

#-----------------------------------------------------------------------------
# Per-scenario timing reports. Without an explicit current_scenario /
# -delay_type loop, report_qor only emits the current-scenario setup
# view; we'd lose visibility on the fast/min hold corner.
#-----------------------------------------------------------------------------
set active_scenarios [list]
foreach_in_collection s [get_scenarios -quiet -filter active==true] {
    lappend active_scenarios [get_attribute $s name]
}
puts "INFO: \[fc_signoff\] active scenarios: $active_scenarios"

redirect -tee -file ${fc_reports}/05_signoff.qor.rep {
    report_qor -summary
    report_timing -nets -capacitance -max_paths 5
    report_area -hierarchy
    report_power
}

foreach scen $active_scenarios {
    current_scenario $scen
    redirect -tee -file ${fc_reports}/05_signoff.${scen}.setup.rep {
        puts "=== Scenario $scen — setup ==="
        report_timing -delay_type max -nets -capacitance -max_paths 5
    }
    redirect -tee -file ${fc_reports}/05_signoff.${scen}.hold.rep {
        puts "=== Scenario $scen — hold ==="
        report_timing -delay_type min -nets -capacitance -max_paths 5
    }
}

#-----------------------------------------------------------------------------
# Save block: ${design_lib}/${top}/signoff.design
#-----------------------------------------------------------------------------
save_block
save_lib $design_lib_name
save_block -as ${design_lib_name}:${top_module}/signoff.design

puts "FC_STAGE_OK: signoff"
exit
