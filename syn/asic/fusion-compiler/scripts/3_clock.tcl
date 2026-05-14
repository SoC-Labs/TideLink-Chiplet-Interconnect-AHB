#-----------------------------------------------------------------------------
# Phase 3: clock — clock_opt build / route / final, plus post-cts opto.
#
# Run with: fc_shell -f 3_clock.tcl   (after 2_synthesis.tcl)
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
set_svf ${fc_outputs}/svf/${top_module}.cts.svf

#-----------------------------------------------------------------------------
# Open the post-synthesis checkpoint
#-----------------------------------------------------------------------------
open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/compile.design

source ${fc_dir}/scripts/setup.tcl
source ${fc_dir}/scripts/setup_design_options.tcl

#-----------------------------------------------------------------------------
# clock_opt is split into three sub-stages so QoR can be reported between:
#   build_clock  — physical CTS (build the clock tree)
#   route_clock  — route the clock nets
#   final_opto   — post-CTS timing/area opto with skew known
#
# set_qor_strategy in U-2022.12 only accepts -metric
# {timing, leakage_power, total_power} — no `area` value — so the
# area-first stance is carried by set_max_area 0 (set in
# setup_design_options.tcl). Default-effort -metric timing closes the
# clock without over-spending area on slack.
#-----------------------------------------------------------------------------

puts "INFO: \[fc_cts\] clock_opt -from build_clock -to build_clock"
clock_opt -from build_clock -to build_clock

redirect -tee -file ${fc_reports}/03a_cts_build.qor.rep {
    report_qor -summary
    report_clock_qor -type summary
}
save_block

puts "INFO: \[fc_cts\] clock_opt -from route_clock -to route_clock"
clock_opt -from route_clock -to route_clock

redirect -tee -file ${fc_reports}/03b_cts_route.qor.rep {
    report_qor -summary
    report_timing -nets -capacitance
}
save_block

puts "INFO: \[fc_cts\] clock_opt -from final_opto -to final_opto"
clock_opt -from final_opto -to final_opto

redirect -tee -file ${fc_reports}/03c_cts_final.qor.rep {
    report_qor -summary
    report_timing -nets -capacitance
    report_area -hierarchy
}

#-----------------------------------------------------------------------------
# Save block: ${design_lib}/${top}/cts.design
#-----------------------------------------------------------------------------
save_block
save_lib $design_lib_name
save_block -as ${design_lib_name}:${top_module}/cts.design

puts "FC_STAGE_OK: cts"
exit
