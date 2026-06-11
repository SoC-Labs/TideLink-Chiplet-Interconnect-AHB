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
### RTL source manifest for IP packaging. Reads flists/tidelink_fpga.flist
### (created by Agent A2) via SOCLABS_TIDELINK_DIR.
###
### Required environment variables:
###   SOCLABS_TIDELINK_DIR - Root of tidelink repository
###   CMSDK_DIR            - Root of Arm CMSDK / Corstone-101 BP210 package
###   XHB500_IP_DIR        - Root of Arm XHB-500 IP (for XHB500 bridge sources)
###-----------------------------------------------------------------------------

# Names match the placeholders the flist actually uses (${TIDELINK_HOME},
# ${CMSDK_DIR}, ${XHB500_IP_DIR}). The [subst] in the parser below relies
# on these TCL variables existing.
set TIDELINK_HOME        $env(SOCLABS_TIDELINK_DIR)
set SOCLABS_TIDELINK_DIR $env(SOCLABS_TIDELINK_DIR)
set CMSDK_DIR            $env(CMSDK_DIR)
set XHB500_IP_DIR        $env(XHB500_IP_DIR)
# CMSDK_FPGA_SRAM_V: path to cmsdk_fpga_sram.v. Set explicitly so the flist's
# ${CMSDK_FPGA_SRAM_V} placeholder resolves under [subst]. set_env.sh derives
# this from CMSDK_DIR when not set; we mirror the same fallback here so the
# flist works under any invocation that has CMSDK_DIR set.
if { [info exists env(CMSDK_FPGA_SRAM_V)] && $env(CMSDK_FPGA_SRAM_V) ne "" } {
    set CMSDK_FPGA_SRAM_V $env(CMSDK_FPGA_SRAM_V)
} else {
    set CMSDK_FPGA_SRAM_V [file join $CMSDK_DIR logical models memories cmsdk_fpga_sram.v]
}

# Flist selection. Default = the V1 list. TIDELINK_PHY_V2=1 in the
# environment selects the V2 (deps/tidelink-phy shared component) list —
# same knob as cocotb/tidelink_top_pair. (Also fixes the flist/->flists/
# rename, which this file-join form silently missed.)
set _phy_v2 0
if { [info exists ::env(TIDELINK_PHY_V2)] && $::env(TIDELINK_PHY_V2) == 1 } { set _phy_v2 1 }
set _flist_name [expr { $_phy_v2 ? "tidelink_fpga_v2.flist" : "tidelink_fpga.flist" }]
if { $_phy_v2 } {
    # Global include = the only define mechanism that survives IP packaging.
    set _v2vh [file join $TIDELINK_HOME fpga vivado_ip tidelink_phy_v2_global.vh]
    add_files -norecurse $_v2vh
    set_property is_global_include true [get_files $_v2vh]
}
set fpga_flist [file join $TIDELINK_HOME flists $_flist_name]
if { ![file exists $fpga_flist] } {
    error "$_flist_name not found at $fpga_flist"
}

# Include paths: CMSDK and XHB500 verilog headers
set_property include_dirs [list \
    $CMSDK_DIR/logical/models/cells/verilog \
    $XHB500_IP_DIR/logical/xhb500/verilog \
] [current_fileset]

# Parse flist — supports:
#   +incdir+<path>   → added to include_dirs (appended to the list above)
#   <path>           → read_verilog -sv
# Comment markers: '#' and '//' (the FPGA flist uses Verilog-style '//').
# ${VAR} references are TCL-substituted via [subst] so the flist can carry
# literal references to ${TIDELINK_HOME}, ${CMSDK_DIR}, ${XHB500_IP_DIR}.
set fh [open $fpga_flist r]
set extra_incdirs {}
set extra_defines {}
while { [gets $fh line] >= 0 } {
    set line [string trim $line]
    if { $line eq "" } { continue }
    if { [string index $line 0] eq "#" } { continue }
    if { [string range $line 0 1] eq "//" } { continue }

    set resolved [subst $line]
    if { [string match "+incdir+*" $resolved] } {
        set incdir [string range $resolved 8 end]
        lappend extra_incdirs $incdir
    } elseif { [string match "+define+*" $resolved] } {
        # e.g. +define+TIDELINK_PHY_V2 (the V2 flist carries its define
        # inline) -> verilog_define on the fileset.
        lappend extra_defines [string range $resolved 8 end]
    } else {
        read_verilog -sv $resolved
    }
}
close $fh

# Apply any +define+ entries found in the flist
if { [llength $extra_defines] > 0 } {
    set existing_defs [get_property verilog_define [current_fileset]]
    set_property verilog_define [concat $existing_defs $extra_defines] [current_fileset]
}

# Append any +incdir+ entries found in the flist
if { [llength $extra_incdirs] > 0 } {
    set existing_incdirs [get_property include_dirs [current_fileset]]
    set_property include_dirs [concat $existing_incdirs $extra_incdirs] [current_fileset]
}
