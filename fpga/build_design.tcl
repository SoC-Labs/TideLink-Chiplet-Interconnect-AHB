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
###-----------------------------------------------------------------------------

set part        $env(FPGA_PART)
set project_dir $env(FPGA_PROJECT_DIR)
set ip_repo     $env(FPGA_IP_REPO)
set target_dir  $env(FPGA_TARGET_DIR)
set output_dir  $env(FPGA_OUTPUT_DIR)

if { [info exists env(FPGA_NUM_JOBS)] } {
    set num_jobs $env(FPGA_NUM_JOBS)
} else {
    set num_jobs 4
}

###-----------------------------------------------------------------------------
### Optional Vivado-native remote-host farming (launch_runs -host).
###
### FPGA_REMOTE_HOSTS - space-separated "host jobs" pairs, dispatched to
###                     `launch_runs -host {host jobs} ...`. Vivado SSHes to
###                     each host and runs the job in the SAME absolute run
###                     directory, so every listed host MUST see this project
###                     tree at the identical path (NFS) and have Vivado at the
###                     identical path, with passwordless SSH from here.
###                     Example: "srv03335 4 srv04936 8"
### FPGA_REMOTE_CMD   - override the SSH login command Vivado uses
###                     (default: ssh -q -o ConnectTimeout=30
###                     -o ConnectionAttempts=3 -o BatchMode=yes)
###
### Unset/empty -> unchanged behaviour: local `launch_runs -jobs $num_jobs`.
### Vivado distributes whole *runs* across hosts (a single run runs entirely
### on one host); the win here is offloading synth/impl onto a less-contended
### host, plus parallelism when multiple runs (OOC IP / strategy) exist.
###-----------------------------------------------------------------------------
if { [info exists env(FPGA_REMOTE_HOSTS)]
     && [string trim $env(FPGA_REMOTE_HOSTS)] ne "" } {
    set toks [regexp -all -inline {\S+} $env(FPGA_REMOTE_HOSTS)]
    if { [llength $toks] % 2 != 0 } {
        puts "ERROR: FPGA_REMOTE_HOSTS must be 'host jobs' pairs,\
              got: '$env(FPGA_REMOTE_HOSTS)'"
        exit 1
    }
    set launch_args {}
    foreach {rh rj} $toks {
        lappend launch_args -host [list $rh $rj]
    }
    if { [info exists env(FPGA_REMOTE_CMD)]
         && [string trim $env(FPGA_REMOTE_CMD)] ne "" } {
        lappend launch_args -remote_cmd $env(FPGA_REMOTE_CMD)
    }
    puts "Remote-host farming ENABLED: launch_runs $launch_args"
} else {
    set launch_args [list -jobs $num_jobs]
    puts "Remote-host farming disabled - local launch_runs -jobs $num_jobs"
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

# STEP 2: Add IP repository
set_property ip_repo_paths $ip_repo [current_project]
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

# STEP 6: Generate block design outputs
# Be specific about WHICH BD - using *.bd matches nested SmartConnect
# sub-designs which can only be generated by their parent.
generate_target all [get_files ${design_name}.bd]

# STEP 7: Update compile order
update_compile_order -fileset sources_1

# STEP 8: Synthesis
puts "Starting synthesis..."
launch_runs synth_1 {*}$launch_args
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if { [string match "*ERROR*" $synth_status] } {
    puts "ERROR: Synthesis failed!"
    exit 1
}

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
launch_runs impl_1 -to_step write_bitstream {*}$launch_args
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"
if { [string match "*ERROR*" $impl_status] } {
    puts "ERROR: Implementation failed!"
    exit 1
}

# STEP 10: Export outputs (.bit, .hwh for PYNQ, .xsa for Vitis)
file mkdir $output_dir

set bit_file [glob -nocomplain $project_dir/tidelink_project.runs/impl_1/*.bit]
if { $bit_file ne "" } {
    file copy -force $bit_file $output_dir/tidelink.bit
    puts "Bitstream copied to $output_dir/tidelink.bit"
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

puts "==========================================="
puts " Build complete!"
puts " Bitstream: $output_dir/tidelink.bit"
puts " HWH:       $output_dir/tidelink.hwh"
puts " XSA:       $output_dir/tidelink_design.xsa"
puts "==========================================="

close_project
