#-----------------------------------------------------------------------------
# TideLink FC Read Design Script for RTL Architect RM
#
# Sourced by the RM init_design.tcl when RTL_SOURCE_FORMAT = script
# Reads the design RTL, elaborates, sets up MCMM and constraints.
#
# Environment variables (set by Makefile via common.mk):
#   TIDELINK_HOME  - Root of the TideLink repository
#   MODULE         - Top-level module name
#   FLIST          - Path to the filelist
#   CLK_NAME       - Clock port name
#   CLK_PERIOD     - Clock period (ns)
#   CLK_UNCERTAINTY - Clock uncertainty (ns)
#   RST_NAME       - Reset port name
#   PHYS_IP_PATH   - Root of physical IP library
#   TLUPLUS_PATH   - Path to TLU+ extraction models
#   TLUPLUS_MAP    - Path to TLU+ layer map file
#   MEM_DB_SS      - Memory macro .db (slow-slow corner)
#   MEM_DB_FF      - Memory macro .db (fast-fast corner)
#-----------------------------------------------------------------------------

set tidelink_home $::env(TIDELINK_HOME)
set top_module    $::env(MODULE)
set flist         $::env(ASIC_FLIST)
set clk_name      $::env(CLK_NAME)
set clk_period    $::env(CLK_PERIOD)
set clk_uncert    $::env(CLK_UNCERTAINTY)
set rst_name      $::env(RST_NAME)
set tluplus_path  $::env(TLUPLUS_PATH)
set tluplus_map   $::env(TLUPLUS_MAP)

# Memory macro libraries (optional — only needed when using ASIC SRAM wrapper)
if {[info exists ::env(MEM_DB_SS)]} {
    set mem_db_ss $::env(MEM_DB_SS)
    puts "INFO: Memory macro library (SS): $mem_db_ss"
} else {
    set mem_db_ss ""
}
if {[info exists ::env(MEM_DB_FF)]} {
    set mem_db_ff $::env(MEM_DB_FF)
    puts "INFO: Memory macro library (FF): $mem_db_ff"
} else {
    set mem_db_ff ""
}

#-----------------------------------------------------------------------------
# Read design from filelist
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: parsing filelist $flist"

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

#-----------------------------------------------------------------------------
# Analyze RTL
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: analyze"

if {[llength $verilog_files] > 0} {
    puts "INFO: Analyzing [llength $verilog_files] Verilog file(s)"
    analyze -format verilog $verilog_files
}

if {[llength $sverilog_files] > 0} {
    puts "INFO: Analyzing [llength $sverilog_files] SystemVerilog file(s)"
    analyze -format sverilog $sverilog_files
}

#-----------------------------------------------------------------------------
# Elaborate
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: elaborate"

elaborate $top_module
set_top_module $top_module

#-----------------------------------------------------------------------------
# MCMM (Multi-Corner Multi-Mode) setup
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: apply MCMM constraints"

# Add memory macro libraries to link_library if available
if {$mem_db_ss ne "" || $mem_db_ff ne ""} {
    set current_link [get_app_var link_library]
    if {$mem_db_ss ne ""} { lappend current_link $mem_db_ss }
    if {$mem_db_ff ne ""} { lappend current_link $mem_db_ff }
    set_app_var link_library $current_link
    puts "INFO: Updated link_library with memory macro .db files"
}

# Slow corner (worst-case setup timing)
create_mode M1
create_corner slow
create_scenario -mode M1 -corner slow -name scen_slow
set_operating_conditions \
    -analysis_type on_chip_variation \
    -max ss_typical_max_1p08v_125c -min ss_typical_max_1p08v_125c \
    -library sc12_cln65lp_base_rvt_ss_typical_max_1p08v_125c

# Fast corner (best-case hold timing)
create_mode M2
create_corner fast
create_scenario -mode M2 -corner fast -name scen_fast
set_operating_conditions \
    -analysis_type on_chip_variation \
    -max ff_typical_min_1p32v_m40c -min ff_typical_min_1p32v_m40c \
    -library sc12_cln65lp_base_rvt_ff_typical_min_1p32v_m40c

#-----------------------------------------------------------------------------
# Parasitic extraction models (TLU+)
#-----------------------------------------------------------------------------
read_parasitic_tech -name typical -tlup ${tluplus_path}/typical.tluplus -layermap ${tluplus_map}
read_parasitic_tech -name rcbest  -tlup ${tluplus_path}/rcbest.tluplus  -layermap ${tluplus_map}
read_parasitic_tech -name rcworst -tlup ${tluplus_path}/rcworst.tluplus -layermap ${tluplus_map}

set_parasitic_parameters -corners slow \
    -early_spec rcworst -early_temperature -40 \
    -late_spec  rcworst -late_temperature  125

set_parasitic_parameters -corners fast \
    -early_spec rcbest -early_temperature -40 \
    -late_spec  rcbest -late_temperature  125

# Supply voltages
set_voltage 1.08 -corner [current_corner] -object_list [get_supply_nets VDD]
set_voltage 0.00 -corner [current_corner] -object_list [get_supply_nets VSS]

#-----------------------------------------------------------------------------
# Clock constraints
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: apply clock constraints"

create_clock -name $clk_name -period $clk_period \
    -waveform "0 [expr {$clk_period / 2.0}]" [get_ports $clk_name]
set_clock_uncertainty $clk_uncert [get_clocks $clk_name]

# Reset: treat as asynchronous, don't time it
if {[sizeof_collection [get_ports $rst_name -quiet]] > 0} {
    set_false_path -from [get_ports $rst_name]
    puts "INFO: Set false path for reset port $rst_name"
}

# Input/output delays (25% of clock period as default estimate)
set io_delay [expr {$clk_period * 0.25}]

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

if {[sizeof_collection $all_inputs] > 0} {
    set_input_delay  -clock $clk_name $io_delay $all_inputs
}
if {[sizeof_collection $all_outputs] > 0} {
    set_output_delay -clock $clk_name $io_delay $all_outputs
}

# Enable setup analysis on all scenarios
set_scenario_status -setup true -leakage_power false *

#-----------------------------------------------------------------------------
# Initialize floorplan
#-----------------------------------------------------------------------------
initialize_floorplan -side_ratio {1 1}

echo "FC_RTL_SCRIPT: done"
