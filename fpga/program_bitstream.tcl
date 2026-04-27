###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - JTAG Bitstream Programming Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Programs the target FPGA PL via Vivado Hardware Manager. Requires the
### board's JTAG/USB port connected to this host.
###
### Usage:
###   vivado -mode batch -source program_bitstream.tcl -tclargs <bitfile> [<jtag_device>]
###
### Arguments:
###   <bitfile>       Path to the .bit file to program (required)
###   <jtag_device>   JTAG device name as seen by Vivado (optional)
###                   Defaults to xc7z020_1 for Pynq-Z2 targets.
###                   MPS3 (AN552, KU115) example: xcku115_0
###                   Check `get_hw_devices` in hw_manager for the exact name.
###-----------------------------------------------------------------------------

set bitfile [lindex $argv 0]
if { $bitfile eq "" || ![file exists $bitfile] } {
    if { $bitfile eq "" } {
        puts "ERROR: no bitfile argument supplied"
    } else {
        puts "ERROR: bitfile not found: $bitfile"
    }
    exit 1
}

# Optional device override; default to xc7z020_1 (Pynq-Z2)
if { [llength $argv] >= 2 } {
    set jtag_device [lindex $argv 1]
} else {
    set jtag_device xc7z020_1
}

puts "Programming $bitfile via JTAG (device: $jtag_device)..."

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set device [lindex [get_hw_devices $jtag_device] 0]
if { $device eq "" } {
    puts "ERROR: JTAG device '$jtag_device' not found."
    puts "       Connected devices: [get_hw_devices *]"
    close_hw_manager
    exit 1
}
current_hw_device $device
refresh_hw_device $device

set_property PROGRAM.FILE $bitfile $device
program_hw_devices $device
refresh_hw_device $device

close_hw_manager
puts "Programmed $bitfile via JTAG."
