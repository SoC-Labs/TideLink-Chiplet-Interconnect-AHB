#-----------------------------------------------------------------------------
# Synopsys RTL Architect TCL script for TideLink
#
# Usage: make -C syn/asic/rtl-architect ra MODULE=tidelink
#
# Environment variables (set by Makefile via common.mk):
#   TIDELINK_HOME  - Root of the TideLink repository
#   MODULE         - Top-level module name
#   FLIST          - Path to the filelist
#   TARGET_LIB     - Target cell library (.db)
#   LINK_LIBS      - Link libraries
#   CLK_NAME       - Clock port name
#   CLK_PERIOD     - Clock period (ns)
#   RST_NAME       - Reset port name
#   TF_FILE        - Technology file (.tf)
#   MW_REF_LIB     - Milkyway reference library
#-----------------------------------------------------------------------------

set tidelink_home $::env(TIDELINK_HOME)
set top_module    $::env(TOP)
set flist         $::env(FLIST)
set target_lib    $::env(TARGET_LIB)
set link_libs     $::env(LINK_LIBS)
set clk_name      $::env(CLK_NAME)
set clk_period    $::env(CLK_PERIOD)
set rst_name      $::env(RST_NAME)
set tf_file       $::env(TF_FILE)
set mw_ref_lib    $::env(MW_REF_LIB)

# ── Library setup ──────────────────────────────────────────────────────────
set_app_var target_library $target_lib
set_app_var link_library   "* $link_libs"

# ── Read design from filelist ─────────────────────────────────────────────
# Parse the flist manually: handle +incdir+, .v (Verilog), .sv (SystemVerilog),
# and skip blank lines / comments.

set include_dirs [list]
set verilog_files [list]
set sverilog_files [list]

set fp [open $flist r]
while {[gets $fp line] >= 0} {
    set line [string trim $line]

    # Skip blank lines and comments
    if {$line eq "" || [string index $line 0] eq "#"} { continue }

    # Expand ${VAR} references using the process environment
    set skip 0
    while {[regexp {\$\{(\w+)\}} $line -> varname]} {
        if {[info exists ::env($varname)]} {
            set line [string map [list "\${$varname}" $::env($varname)] $line]
        } else {
            puts "WARNING: Environment variable $varname not set, skipping: $line"
            set skip 1
            break
        }
    }
    if {$skip} { continue }

    # Handle +incdir+ directives
    if {[string match "+incdir+*" $line]} {
        set dir [string range $line 8 end]
        lappend include_dirs $dir
        continue
    }

    # Classify by extension
    if {[string match "*.v" $line]} {
        lappend verilog_files $line
    } else {
        lappend sverilog_files $line
    }
}
close $fp

# Set include search path
if {[llength $include_dirs] > 0} {
    set_app_var search_path [concat [get_app_var search_path] $include_dirs]
}

# Analyze Verilog files
if {[llength $verilog_files] > 0} {
    puts "INFO: Analyzing [llength $verilog_files] Verilog file(s)"
    analyze -format verilog $verilog_files
}

# Analyze SystemVerilog files
if {[llength $sverilog_files] > 0} {
    puts "INFO: Analyzing [llength $sverilog_files] SystemVerilog file(s)"
    analyze -format sverilog $sverilog_files
}

# ── Elaborate ─────────────────────────────────────────────────────────────
if {[catch {elaborate $top_module} result]} {
    puts "ERROR: Elaboration failed: $result"
    exit 1
}

# ── Create design library with technology (required by rtl_opt) ───────────
set design_lib "${top_module}_work"
file delete -force $design_lib
create_lib $design_lib -technology $tf_file -ref_libs [list $mw_ref_lib]

# RTL Architect uses set_top_module (not link) to resolve the hierarchy.
set_top_module $top_module

puts "INFO: Successfully elaborated design: [current_design]"

# ── Design constraints ─────────────────────────────────────────────────────
# Check if clock port exists before creating clock
if {[sizeof_collection [get_ports $clk_name -quiet]] > 0} {
    create_clock -name $clk_name -period $clk_period [get_ports $clk_name]
    puts "INFO: Created clock on port $clk_name with period $clk_period ns"
} else {
    puts "ERROR: Clock port '$clk_name' not found in design"
    puts "Available ports: [get_object_name [all_inputs]]"
    exit 1
}

# Reset: treat as asynchronous, don't time it
if {[sizeof_collection [get_ports $rst_name -quiet]] > 0} {
    set_false_path -from [get_ports $rst_name]
    puts "INFO: Set false path for reset port $rst_name"
} else {
    puts "WARNING: Reset port '$rst_name' not found in design"
}

# Input/output delays (25% of clock period as default estimate)
set io_delay [expr {$clk_period * 0.25}]

# Get all inputs except clock and reset
set all_inputs_raw [all_inputs]
set exclude_ports [list]
if {[sizeof_collection [get_ports $clk_name -quiet]] > 0} {
    lappend exclude_ports $clk_name
}
if {[sizeof_collection [get_ports $rst_name -quiet]] > 0} {
    lappend exclude_ports $rst_name
}

if {[llength $exclude_ports] > 0} {
    set all_inputs [remove_from_collection $all_inputs_raw [get_ports $exclude_ports]]
} else {
    set all_inputs $all_inputs_raw
}
set all_outputs [all_outputs]

# Apply I/O delays if there are any ports
if {[sizeof_collection $all_inputs] > 0} {
    set_input_delay  -clock $clk_name $io_delay $all_inputs
    puts "INFO: Applied input delay of $io_delay ns to [sizeof_collection $all_inputs] input ports"
}
if {[sizeof_collection $all_outputs] > 0} {
    set_output_delay -clock $clk_name $io_delay $all_outputs
    puts "INFO: Applied output delay of $io_delay ns to [sizeof_collection $all_outputs] output ports"
}

# ── RTL Architect exploration ──────────────────────────────────────────────
rtl_opt

# ── Reports ────────────────────────────────────────────────────────────────
set rpt_dir "${top_module}_ra_reports"
file mkdir $rpt_dir

report_timing    -max_paths 10    > ${rpt_dir}/timing.rpt
report_area                       > ${rpt_dir}/area.rpt
report_power                      > ${rpt_dir}/power.rpt
report_qor                        > ${rpt_dir}/qor.rpt
report_design                     > ${rpt_dir}/design.rpt
report_constraints -all_violators > ${rpt_dir}/constraints.rpt

# ── Save design ────────────────────────────────────────────────────────────
write_rtl_architect_design -output ${top_module}_ra_design

puts "INFO: RTL Architect run complete for ${top_module}"
puts "INFO: Reports written to ${rpt_dir}/"

# Exit unless GUI mode is requested
if { ![info exists ::env(RA_GUI)] || $::env(RA_GUI) != "1" } {
    exit
}
