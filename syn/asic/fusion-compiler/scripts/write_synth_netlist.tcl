#-----------------------------------------------------------------------------
# Write a post-synthesis (compile.design) gate-level netlist.
#
# Used by the Formality lec_synth target as the implementation reference.
# The post-synth netlist is intermediate between RTL and the post-route
# deliverable: it has all of synthesis' optimisations baked in (logic_opto,
# initial_opto, final_opto, including ICG insertion) but NOT the
# additional sequential opto + clock-gate transformations FC applies
# during CTS / route. This makes it the "tightest" netlist that LEC
# can still reach from RTL with the per-stage SVF guidance.
#
# Run via: cd $FC_WORK && fc_shell -f scripts/write_synth_netlist.tcl
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fc_outputs       $::env(FC_OUTPUTS)

file mkdir $fc_outputs

open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/compile.design

puts "INFO: \[synth_netlist\] write_verilog ${fc_outputs}/${top_module}.synth.v"
write_verilog ${fc_outputs}/${top_module}.synth.v

puts "FC_STAGE_OK: synth_netlist"
exit
