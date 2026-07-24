###-----------------------------------------------------------------------------
### nanosoc_eth_chiplet - Vivado IP Packaging Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Packages nanosoc_eth_chiplet_vivado_wrapper (the WHOLE multicore+ethernet
### SoC + internal TideLink) as a Vivado IP for the KR260 eth-chiplet target.
###
### This is also the SCOPING SYNTH: ipx::package_project runs OOC elaboration
### of the entire SoC on xck26, which is the first proof of whether the design
### fits/synthesises. Expect it to surface FPGA memory-model gaps (behavioural
### SRAM -> BRAM) — that is the intended scoping outcome.
###
### Required environment variables:
###   FPGA_COMPONENT_FILELIST - Path to the eth-chiplet Vivado filelist tcl
###   FPGA_COMPONENT_LIB      - Output directory for packaged IP component.xml
###   NANOSOC_ETH_CHIPLET_DIR - Parent repo root (used by the filelist)
###   SOCLABS_TIDELINK_DIR    - tidelink submodule root
###   FPGA_VENDOR / FPGA_CORE_REV - optional IP metadata
###-----------------------------------------------------------------------------

# Vivado message gate — mirror package_tidelink_ip.tcl / build_design.tcl
if {![info exists ::tidelink_msg_gate_installed]} {
    set_msg_config -id "Constraints 18-359"  -new_severity ERROR
    set_msg_config -id "Vivado 12-4739"      -new_severity ERROR
    set_msg_config -id "Designutils 20-1307" -new_severity ERROR
    set_msg_config -id "Common 17-55"        -new_severity ERROR
    set_msg_config -id "Vivado 12-1411"      -new_severity ERROR
    set ::tidelink_msg_gate_installed 1
}

set component_lib $env(FPGA_COMPONENT_LIB)

if {[info exists env(FPGA_VENDOR)]} { set fpga_vendor $env(FPGA_VENDOR) } else { set fpga_vendor "soclabs.org" }
if {[info exists env(FPGA_CORE_REV)]} { set fpga_core_rev $env(FPGA_CORE_REV) } else { set fpga_core_rev 1 }

# STEP 0: Read design sources (the parent-repo SoC + tidelink + integration)
source $env(FPGA_COMPONENT_FILELIST)

# Add the wrapper (next to this script)
set wrapper_dir [file dirname [info script]]
read_verilog $wrapper_dir/nanosoc_eth_chiplet_vivado_wrapper.v

set_property top nanosoc_eth_chiplet_vivado_wrapper [current_fileset]
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
    -name tmp_edit_project \
    -directory $component_lib \
    $component_lib/component.xml
update_compile_order -fileset sources_1

# STEP 2: Core metadata
set core [ipx::current_core]
set_property display_name        "nanoSoC Ethernet Chiplet (TideLink D2D)" $core
set_property description          "Full nanoSoC multicore + ethernet subsystem + internal TideLink die-to-die link, for the KR260 two-board demo. eth_ss_0 AHB backdoor, GPIO-PHY pads, CoreSight SWD, PHC/eth interrupts." $core
set_property vendor_display_name "SoC Labs" $core
set_property company_url         "https://www.soclabs.org" $core
set_property core_revision       $fpga_core_rev $core
set_property supported_families {
    zynquplus  Production
    zynq       Production
    kintexu    Production
} $core

# phc/user_ref clocks are board-specific; skip static FREQ_HZ DRC
set_property ipi_drc {ignore_freq_hz true} $core

# STEP 3: Let IPI infer bus interfaces from the wrapper's X_INTERFACE_INFO
ipx::merge_project_changes -verbose files $core

# STEP 4: Memory map for the one addressable slave (eth_ss_0).
#   The SoC's internal AHB matrix decodes the full 32-bit space, so the IPI
#   memory map covers 4 GB (range 0x1_0000_0000) — the address editor then
#   assigns the PS aperture base (KR260 HPM0 = 0x8000_0000).
proc add_memory_map_32 {iface_name range_bytes core_obj} {
    ipx::add_memory_map $iface_name $core_obj
    set_property slave_memory_map_ref $iface_name \
        [ipx::get_bus_interfaces $iface_name -of_objects $core_obj]
    ipx::add_address_block Reg \
        [ipx::get_memory_maps $iface_name -of_objects $core_obj]
    set_property range $range_bytes \
        [ipx::get_address_blocks Reg -of_objects [ipx::get_memory_maps $iface_name -of_objects $core_obj]]
    set_property width 32 \
        [ipx::get_address_blocks Reg -of_objects [ipx::get_memory_maps $iface_name -of_objects $core_obj]]
}
add_memory_map_32 eth_ss_0 4294967296 $core

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
puts " nanosoc_eth_chiplet IP packaged"
puts " Output: $component_lib"
puts "==========================================="
