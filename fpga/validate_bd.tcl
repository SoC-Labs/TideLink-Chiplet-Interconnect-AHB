###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - Block-Design Validation Driver (no synth)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Mirrors build_design.tcl STEPS 1-3 only: create project, register IP
### repos, source the target's tidelink_design.tcl and run create_root_design
### (which calls validate_bd_design + save_bd_design internally), then exits.
### Purpose: cheap (<5 min) BD-topology / parameter-propagation / address-map
### gate for BD edits, without paying for a full bitstream build.
###
### Required environment variables (same contract as build_design.tcl):
###   FPGA_PART        - Xilinx part number (e.g. xc7z020clg400-1)
###   FPGA_PROJECT_DIR - Output directory for the throwaway Vivado project
###   FPGA_IP_REPO     - Path to packaged tidelink IP repository
###   FPGA_TARGET_DIR  - Path to target dir holding tidelink_design.tcl
### Optional:
###   FPGA_PHC_IP_REPO - Path to packaged PHC IP repository
###
### Usage (from fpga/, against an existing packaged-IP tree):
###   FPGA_PART=xc7z020clg400-1 \
###   FPGA_PROJECT_DIR=../imp/fpga/project_validate/pynq-z2-pair-all \
###   FPGA_IP_REPO=../imp/fpga/tidelink_ip \
###   FPGA_PHC_IP_REPO=../imp/fpga/phc_ip \
###   FPGA_TARGET_DIR=targets/pynq-z2-pair-all \
###   vivado -mode batch -source validate_bd.tcl
###
### Exit status: 0 = validate_bd_design passed; non-zero = any error
### (validate_bd_design errors abort batch mode, so a failed validation
### exits non-zero on its own).
###-----------------------------------------------------------------------------

set part        $env(FPGA_PART)
set project_dir $env(FPGA_PROJECT_DIR)
set ip_repo     $env(FPGA_IP_REPO)
set target_dir  $env(FPGA_TARGET_DIR)
if { [info exists env(FPGA_PHC_IP_REPO)] && $env(FPGA_PHC_IP_REPO) ne "" } {
    set phc_ip_repo $env(FPGA_PHC_IP_REPO)
} else {
    set phc_ip_repo ""
}

puts "==========================================="
puts " TideLink BD validation (no synthesis)"
puts " Part:    $part"
puts " Project: $project_dir"
puts " IP Repo: $ip_repo"
puts " Target:  $target_dir"
puts "==========================================="

create_project tidelink_bd_validate $project_dir -part $part -force

if { $phc_ip_repo ne "" } {
    set_property ip_repo_paths [list $ip_repo $phc_ip_repo] [current_project]
} else {
    set_property ip_repo_paths $ip_repo [current_project]
}
update_ip_catalog

source $target_dir/tidelink_design.tcl

set design_name tidelink_design
create_bd_design $design_name
# create_root_design ends with: regenerate_bd_layout; validate_bd_design;
# save_bd_design — a validation failure raises a TCL error which aborts
# batch mode with a non-zero exit status.
create_root_design ""

set cw_count [get_msg_config -count -severity {CRITICAL WARNING}]
puts "==========================================="
puts " BD VALIDATION PASSED: $target_dir"
puts " CRITICAL_WARNING count: $cw_count"
puts "==========================================="

close_project
