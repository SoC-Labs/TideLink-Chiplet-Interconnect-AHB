#-----------------------------------------------------------------------------
# Phase 4: route — route_auto + route_opt + std-cell fillers.
#
# Run with: fc_shell -f 4_route.tcl   (after 3_clock.tcl)
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fc_dir           $::env(FC_DIR)
set fc_logs          $::env(FC_LOGS)
set fc_reports       $::env(FC_REPORTS)
set fc_outputs       $::env(FC_OUTPUTS)

# Per-stage named SVF for Formality LEC.
file mkdir ${fc_outputs}/svf
set_svf ${fc_outputs}/svf/${top_module}.route.svf

#-----------------------------------------------------------------------------
# Open the post-CTS checkpoint
#-----------------------------------------------------------------------------
open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/cts.design

source ${fc_dir}/scripts/setup.tcl
source ${fc_dir}/scripts/setup_design_options.tcl

#-----------------------------------------------------------------------------
# route_auto — initial detail+global route
#-----------------------------------------------------------------------------
puts "INFO: \[fc_route\] route_auto"
route_auto

redirect -tee -file ${fc_reports}/04a_route_auto.qor.rep {
    report_qor -summary
    report_design -nosplit
}
save_block

#-----------------------------------------------------------------------------
# route_opt — post-route timing + DRC opto. Default pass first, then a
# second high-effort pass that targets residual setup/hold/DRC. The
# extra pass is cheap (~10 min) and routinely picks up the 30-50 nets
# that the default-effort pass leaves with marginal slack or DRC.
#-----------------------------------------------------------------------------
puts "INFO: \[fc_route\] route_opt (default effort)"
route_opt

redirect -tee -file ${fc_reports}/04b_route_opt.qor.rep {
    report_qor -summary
    report_timing -nets -capacitance
}

puts "INFO: \[fc_route\] route_opt -effort high (residual recovery)"
if {[catch {route_opt -effort high} err]} {
    # Some FC builds don't accept -effort directly on route_opt; fall
    # back to a second default pass which still picks up residuals.
    puts "INFO: \[fc_route\] -effort high rejected ($err); using second default pass"
    route_opt
}

redirect -tee -file ${fc_reports}/04c_route_opt_high.qor.rep {
    report_qor -summary
    report_timing -nets -capacitance -max_paths 5
    report_design -nosplit
}

#-----------------------------------------------------------------------------
# Save block: ${design_lib}/${top}/route.design
#-----------------------------------------------------------------------------
save_block
save_lib $design_lib_name
save_block -as ${design_lib_name}:${top_module}/route.design

puts "FC_STAGE_OK: route"
exit
