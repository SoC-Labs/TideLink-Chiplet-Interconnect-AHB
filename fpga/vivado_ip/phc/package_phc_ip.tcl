###-----------------------------------------------------------------------------
### PHC Hardware Clock - Vivado IP Packaging Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Packages phc_vivado_wrapper (+ phc_fpga_top + phc_clock_core + phc_apb_regs)
### as a Vivado IP-XACT core with an APB slave bus interface, clock/reset
### associations, and two interrupt ports. The packaged component is consumed
### by the block design in fpga/targets/pynq-z2-pair*/tidelink_design.tcl.
###
### Required environment variables:
###   PHC_REPO_DIR    - Root of the sibling ptp-hardware-clock-ahb repository
###                     (defaults to ~/SoCLabs/ptp-hardware-clock-ahb)
###   PHC_COMPONENT_LIB - Output directory for the packaged component.xml
###   FPGA_VENDOR    - IP vendor (default: soclabs.org)
###   FPGA_CORE_REV  - IP core revision (default: 1)
###-----------------------------------------------------------------------------

# Mirror the tidelink_ip msg-gate so OOC synth promotes the same XDC errors.
if {![info exists ::tidelink_msg_gate_installed]} {
    set_msg_config -id "Constraints 18-359"  -new_severity ERROR
    set_msg_config -id "Vivado 12-4739"      -new_severity ERROR
    set_msg_config -id "Designutils 20-1307" -new_severity ERROR
    set_msg_config -id "Common 17-55"        -new_severity ERROR
    set_msg_config -id "Vivado 12-1411"      -new_severity ERROR
    set ::tidelink_msg_gate_installed 1
}

if {[info exists env(PHC_REPO_DIR)]} {
    set phc_repo $env(PHC_REPO_DIR)
} else {
    set phc_repo "$env(HOME)/SoCLabs/ptp-hardware-clock-ahb"
}

if {![file isdirectory $phc_repo]} {
    error "PHC source repo not found at $phc_repo — set PHC_REPO_DIR"
}

set component_lib $env(PHC_COMPONENT_LIB)

if {[info exists env(FPGA_VENDOR)]} {
    set fpga_vendor $env(FPGA_VENDOR)
} else {
    set fpga_vendor "soclabs.org"
}
if {[info exists env(FPGA_CORE_REV)]} {
    set fpga_core_rev $env(FPGA_CORE_REV)
} else {
    set fpga_core_rev 1
}

set wrapper_dir [file dirname [info script]]

# STEP 0: Read PHC RTL + the FPGA-friendly top + the wrapper
read_verilog -sv [list \
    $phc_repo/src/rtl/phc_clock_core.sv \
    $phc_repo/src/rtl/phc_apb_regs.sv \
]
read_verilog -sv [list \
    $wrapper_dir/phc_fpga_top.sv \
]
read_verilog [list \
    $wrapper_dir/phc_vivado_wrapper.v \
]

set_property top phc_vivado_wrapper [current_fileset]
update_compile_order -fileset sources_1

# STEP 1: Package as IP
ipx::package_project -root_dir $component_lib \
    -vendor   $fpga_vendor \
    -library  user \
    -taxonomy /UserIP \
    -import_files \
    -set_current false \
    -force \
    -force_update_compile_order

ipx::unload_core $component_lib/component.xml
ipx::edit_ip_in_project -upgrade true \
    -name tmp_edit_phc_ip \
    -directory $component_lib \
    $component_lib/component.xml

update_compile_order -fileset sources_1

# STEP 2: Core metadata
set core [ipx::current_core]

set_property display_name    "SoC Labs PHC Hardware Clock" $core
set_property description     "SoC Labs PTP Hardware Clock (phc_fpga_top): APB-configurable IEEE-1588 timestamp counter with two hardware servo sources, Ethernet capture inputs, PPS output, and alarm/PPS interrupts. FPGA-friendly wrapper exposes current seconds/nanoseconds for autonomous-SYNC consumers (e.g. TideLink PTP)." $core
set_property vendor_display_name "SoC Labs" $core
set_property company_url     "https://www.soclabs.org" $core
set_property core_revision   $fpga_core_rev $core
set_property supported_families {
    zynq            Production
    zynquplus       Production
    artix7          Production
    kintex7         Production
    kintexu         Production
    spartan7        Production
    virtex7         Production
} $core

set_property ipi_drc {ignore_freq_hz true} $core

# STEP 3: Merge auto-inferred bus interfaces from X_INTERFACE_INFO
ipx::merge_project_changes -verbose files $core

# STEP 4: Memory map for the APB slave (4 KB — 12-bit internal PADDR)
proc add_memory_map_32 {iface_name range_bytes core_obj} {
    ipx::add_memory_map $iface_name $core_obj
    set_property slave_memory_map_ref $iface_name \
        [ipx::get_bus_interfaces $iface_name -of_objects $core_obj]
    ipx::add_address_block Reg \
        [ipx::get_memory_maps $iface_name -of_objects $core_obj]
    set_property range $range_bytes \
        [ipx::get_address_blocks Reg \
            -of_objects [ipx::get_memory_maps $iface_name -of_objects $core_obj]]
    set_property width 32 \
        [ipx::get_address_blocks Reg \
            -of_objects [ipx::get_memory_maps $iface_name -of_objects $core_obj]]
}

# apb — 4 KB (APB_ADDR_W=12 -> 2^12 byte addresses)
add_memory_map_32 apb 4096 $core

# STEP 5: Finalise
ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core

ipx::save_core $core
ipx::check_integrity -quiet -xrt $core
ipx::move_temp_component_back -component $core
close_project

update_ip_catalog
close_project

puts "==========================================="
puts " PHC Hardware Clock IP packaged"
puts " Output: $component_lib"
puts "==========================================="
