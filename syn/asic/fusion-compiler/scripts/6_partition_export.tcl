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

puts "FC_STAGE_OK: abstract"
exit
