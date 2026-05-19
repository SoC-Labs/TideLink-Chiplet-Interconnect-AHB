###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Vivado IP Packaging Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Packages tidelink_vivado_wrapper as a Vivado IP with properly defined bus
### interfaces (AHB-Lite slaves/master, APB slave, AXI-Stream, clock/reset,
### interrupt) for use in the Vivado IP Integrator.
###
### Required environment variables:
###   FPGA_COMPONENT_FILELIST - Path to TCL filelist for RTL source files
###   FPGA_COMPONENT_LIB      - Output directory for packaged IP component.xml
###   FPGA_VENDOR             - IP vendor string (default: soclabs.org)
###   FPGA_CORE_REV           - IP core revision number (default: 1)
###-----------------------------------------------------------------------------

set component_lib $env(FPGA_COMPONENT_LIB)

# Use defaults for optional env vars (Vivado TCL has no 'env_default' helper)
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

# STEP 0: Read in design sources
source $env(FPGA_COMPONENT_FILELIST)

# Add the wrapper source file (located next to this script)
set wrapper_dir [file dirname [info script]]
read_verilog $wrapper_dir/tidelink_vivado_wrapper.v

set_property top tidelink_vivado_wrapper [current_fileset]

# SoC Labs §9 structural fix: the Xilinx IDELAYE2 RX delay primitive is now
# gated SOLELY by the USE_IDELAY parameter of tidelink_vivado_wrapper
# (default 1'b1). ipx::package_project records that wrapper parameter default
# in the IP's component.xml, so the IP's out-of-context synthesis elaborates
# the IDELAY branch with NO preprocessor cooperation.
#
# DO NOT reintroduce `set_property verilog_define {TIDELINK_USE_IDELAY=1}`
# here: a fileset verilog_define set on this PACKAGING project is NOT baked
# into the IP-XACT core, so it never reached the IP's OOC synth — the old
# `ifdef was always false and the IDELAYE2 primitive was silently dropped
# from EVERY FPGA build (proven byte-identical to an IDELAY-off build,
# 2026-05-19). The opt-in `ifdef has been deleted in tidelink_idelay_rx.sv;
# the parameter is the single source of truth.

update_compile_order -fileset sources_1

# STEP 1: Package the project as IP
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

set_property display_name    "TideLink Chiplet Bridge" $core
set_property description     "SoC Labs TideLink chiplet communication subsystem: AHB sub/tx/fifo/ptp/mng slaves and master, APB config, AXI-Stream TideChart port, GPIO PHY pads, PTP hardware clock interface, and auto-negotiation." $core
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

# Suppress MMCM/PLL frequency-check DRC — phc_clk and user_ref_clk are
# board-specific and will not have static FREQ_HZ info at package time.
set_property ipi_drc {ignore_freq_hz true} $core

# STEP 3: Let IPI auto-infer bus interfaces from X_INTERFACE_INFO attributes
# on the wrapper — merge rather than strip.
ipx::merge_project_changes -verbose files $core

# STEP 4: Define memory maps for all addressable slave interfaces.
#
# Without memory maps, validate_bd_design errors with
# "addressable slave interface without an associated memory map".
#
# ahb_sub : Full 4 GB (2^32) — tidelink_top contains an address translator
#            that maps the local aperture to the remote address space.  The IPI
#            memory map should cover the full 32-bit range so the address editor
#            can assign any base address.  Range = 0x1_0000_0000 = 4294967296.
#
# ahb_tx  : 16 KB — the TX FIFO aperture equals the SRAM depth.
#            RAM_ADDR_W defaults to 14, giving 2^14 = 16384 byte addresses
#            at 32-bit (word) granularity.  Range = 0x4000 = 16384.
#
# ahb_fifo: 16 KB — mirrors the TX aperture; same RAM_ADDR_W = 14.
#            Range = 0x4000 = 16384.
#
# ahb_ptp : 16 B  — the PTP TX write port has a 4-bit address (2^4 = 16 B).
#            Range = 0x10 = 16.
#
# apb     : 24 KB — unified config spans three 8 KB (0x2000) sub-regions:
#            0x0000-0x1FFF Wlink, 0x2000-0x3FFF TideLink+PTP, 0x4000-0x5FFF
#            addr-translator.  Top of range = 0x6000 = 24576.

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

# ahb_sub — 4 GB (full 32-bit address space; addr translator scopes remotely)
add_memory_map_32 ahb_sub 4294967296 $core

# ahb_tx  — 16 KB (RAM_ADDR_W=14 default: 2^14 byte-addressed words)
add_memory_map_32 ahb_tx 16384 $core

# ahb_fifo — 16 KB (same SRAM depth as TX side)
add_memory_map_32 ahb_fifo 16384 $core

# ahb_ptp — 16 B (4-bit address: 2^4 bytes)
add_memory_map_32 ahb_ptp 16 $core

# apb — 24 KB (three 8 KB sub-regions: 0x0000, 0x2000, 0x4000)
add_memory_map_32 apb 24576 $core

# STEP 5: Finalize and save
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
puts " TideLink Chiplet Bridge IP packaged"
puts " Output: $component_lib"
puts "==========================================="
