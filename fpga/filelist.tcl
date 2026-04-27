###-----------------------------------------------------------------------------
### TideLink Chiplet Subsystem - Vivado Filelist
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### RTL source manifest for IP packaging. Reads flist/tidelink_fpga.flist
### (created by Agent A2) via SOCLABS_TIDELINK_DIR.
###
### Required environment variables:
###   SOCLABS_TIDELINK_DIR - Root of tidelink repository
###   CMSDK_DIR            - Root of Arm CMSDK / Corstone-101 BP210 package
###   XHB500_IP_DIR        - Root of Arm XHB-500 IP (for XHB500 bridge sources)
###-----------------------------------------------------------------------------

set TIDELINK_HOME $env(SOCLABS_TIDELINK_DIR)
set CMSDK         $env(CMSDK_DIR)
set XHB500_IP     $env(XHB500_IP_DIR)

# flist written by Agent A2
set fpga_flist [file join $TIDELINK_HOME flist tidelink_fpga.flist]
if { ![file exists $fpga_flist] } {
    error "tidelink_fpga.flist not found at $fpga_flist — run Agent A2 first"
}

# Include paths: CMSDK and XHB500 verilog headers
set_property include_dirs [list \
    $CMSDK/logical/models/cells/verilog \
    $XHB500_IP/logical/xhb500/verilog \
] [current_fileset]

# Parse flist — supports:
#   +incdir+<path>   → added to include_dirs (appended to the list above)
#   <path>           → read_verilog -sv
set fh [open $fpga_flist r]
set extra_incdirs {}
while { [gets $fh line] >= 0 } {
    set line [string trim $line]
    # Skip blank lines and comments
    if { $line eq "" || [string index $line 0] eq "#" } { continue }

    if { [string match "+incdir+*" $line] } {
        set incdir [string range $line 8 end]
        lappend extra_incdirs $incdir
    } else {
        read_verilog -sv $line
    }
}
close $fh

# Append any +incdir+ entries found in the flist
if { [llength $extra_incdirs] > 0 } {
    set existing_incdirs [get_property include_dirs [current_fileset]]
    set_property include_dirs [concat $existing_incdirs $extra_incdirs] [current_fileset]
}
