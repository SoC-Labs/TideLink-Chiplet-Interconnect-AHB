#-----------------------------------------------------------------------------
# TideLink — FC Read Design Script (shared between RTL Architect and
# Fusion Compiler). Reads RTL via the project filelist, elaborates the
# partition top, and applies MCMM + clock + parasitic + I/O delay setup.
#
# Sourced after a design library exists (so a current block is available
# when create_clock / set_input_delay / scenario commands run).
#
# Environment variables (set by Makefile via common.mk):
#   TIDELINK_HOME    - Repo root
#   MODULE / TOP     - Partition module name + elaboration top
#   FLIST            - Path to the ASIC filelist (tidelink_top_full_asic.flist)
#   CLK_NAME         - Primary (AHB) clock port
#   CLK_PERIOD       - Primary clock period (ns)
#   CLK_UNCERTAINTY  - Setup/hold uncertainty (ns)
#   RST_NAME         - Primary reset port (treated as async)
#   TLUPLUS_PATH     - TLU+ extraction-model dir
#   TLUPLUS_MAP      - TLU+ layer map
#   MEM_DBS_SS/FF    - Macro Liberty .db lists (optional)
#-----------------------------------------------------------------------------

set tidelink_home $::env(TIDELINK_HOME)
# TOP is the elaboration top; MODULE is the flist/partition name.
# common.mk maps MODULE → TOP (e.g. tidelink_top_full → tidelink_top).
set top_module    $::env(TOP)
set flist         $::env(FLIST)
set clk_name      $::env(CLK_NAME)
set clk_period    $::env(CLK_PERIOD)
set clk_uncert    $::env(CLK_UNCERTAINTY)
set rst_name      $::env(RST_NAME)
set tluplus_path  $::env(TLUPLUS_PATH)
set tluplus_map   $::env(TLUPLUS_MAP)

#-----------------------------------------------------------------------------
# Read design from filelist (handles +incdir+, +define+, nested -f)
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: parsing filelist $flist"

set include_dirs   [list]
set defines        [list]
set verilog_files  [list]
set sverilog_files [list]

proc parse_flist {filepath} {
    upvar include_dirs   include_dirs
    upvar defines        defines
    upvar verilog_files  verilog_files
    upvar sverilog_files sverilog_files

    set fp [open $filepath r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]

        # Skip blank / comment lines
        if {$line eq "" || [string match "//*" $line] || [string index $line 0] eq "#"} { continue }

        # Expand ${VAR} and $(VAR) env references
        set skip 0
        while {[regexp {\$\{(\w+)\}|\$\((\w+)\)} $line -> v1 v2]} {
            set vn [expr {$v1 ne "" ? $v1 : $v2}]
            if {[info exists ::env($vn)]} {
                set line [regsub {\$[\{\(]\w+[\}\)]} $line $::env($vn)]
            } else {
                puts "WARNING: env var $vn not set, skipping: $line"
                set skip 1
                break
            }
        }
        if {$skip} { continue }

        if {[string match "+incdir+*" $line]} {
            lappend include_dirs [string range $line 8 end]
            continue
        }
        if {[string match "+define+*" $line]} {
            lappend defines [string range $line 8 end]
            continue
        }
        if {[string match "+libext+*" $line]} { continue }

        if {[string match "-f *" $line] || [string match "-f\t*" $line]} {
            set nested [string trim [string range $line 2 end]]
            if {[file exists $nested]} {
                parse_flist $nested
            } else {
                puts "WARNING: nested filelist not found: $nested"
            }
            continue
        }

        if {[string match "*.v" $line]} {
            lappend verilog_files $line
        } elseif {[string match "*.sv" $line]} {
            lappend sverilog_files $line
        }
    }
    close $fp
}

parse_flist $flist

if {[llength $include_dirs] > 0} {
    set_app_var search_path [concat [get_app_var search_path] $include_dirs]
}

#-----------------------------------------------------------------------------
# Analyze RTL — treat all sources as SystemVerilog. The Wlink/XHB500 drops
# include both .v and .sv, and several `.v` files use compilation-unit-scope
# constructs that the Verilog-2001 parser rejects (VER-720). SV is a strict
# superset, so the union analyses cleanly.
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: analyze"

set all_rtl [concat $verilog_files $sverilog_files]
set define_args [list]
foreach def $defines { lappend define_args $def }

if {[llength $all_rtl] > 0} {
    puts "INFO: Analyzing [llength $verilog_files] .v + [llength $sverilog_files] .sv as SystemVerilog"
    if {[llength $define_args] > 0} {
        analyze -format sverilog -define $define_args $all_rtl
    } else {
        analyze -format sverilog $all_rtl
    }
}

#-----------------------------------------------------------------------------
# Elaborate
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: elaborate $top_module"
elaborate $top_module
set_top_module $top_module

#-----------------------------------------------------------------------------
# MCMM (Multi-Corner Multi-Mode) setup — tcbn65lpbwp12t 200a operating
# conditions (12-track).
#   tcbn65lpbwp12twc  worst case  V_LO T_HI  → SS (max-delay) → scen_slow
#   tcbn65lpbwp12ttc  typical case            → TT             → scen_typ
#   tcbn65lpbwp12tbc  best  case  V_HI T_LO  → FF (min-delay) → scen_fast
# Library names match the .db filenames (without extension); env-
# overridable via FC_LIB_NAME_SS / FC_LIB_NAME_FF if STANDARD_CELL_BASE_PATH
# is repointed at the legacy 9-track install (tcbn65lpwc/tcbn65lpbc).
# Operating-condition labels WCCOM/BCCOM are foundry-standard, same for
# 9-track and 12-track libraries.
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: MCMM"

set _lib_name_ss [expr {[info exists ::env(FC_LIB_NAME_SS)] && $::env(FC_LIB_NAME_SS) ne "" ? $::env(FC_LIB_NAME_SS) : "tcbn65lpbwp12twc"}]
set _lib_name_ff [expr {[info exists ::env(FC_LIB_NAME_FF)] && $::env(FC_LIB_NAME_FF) ne "" ? $::env(FC_LIB_NAME_FF) : "tcbn65lpbwp12tbc"}]
puts "INFO: \[MCMM\] -library SS=$_lib_name_ss  FF=$_lib_name_ff"

create_mode func
create_corner slow
create_scenario -mode func -corner slow -name scen_slow
set_operating_conditions \
    -analysis_type on_chip_variation \
    -max WCCOM -min WCCOM \
    -library $_lib_name_ss

create_corner fast
create_scenario -mode func -corner fast -name scen_fast
set_operating_conditions \
    -analysis_type on_chip_variation \
    -max BCCOM -min BCCOM \
    -library $_lib_name_ff

#-----------------------------------------------------------------------------
# Parasitic extraction (TLU+) — cln65lp 1p05m+alrdl, top2 = 9lm_T2 stack
# (12-track tcbn65lpbwp12t convention; 9-track tcbn65lp shipped as
# 1p09m+alrdl). Env-overridable via FC_TLU_STACK if you re-point
# STANDARD_CELL_BASE_PATH at a library family that uses a different
# stack name.
#-----------------------------------------------------------------------------
set _stack [expr {[info exists ::env(FC_TLU_STACK)] && $::env(FC_TLU_STACK) ne "" ? $::env(FC_TLU_STACK) : "cln65lp_1p05m+alrdl"}]
puts "INFO: \[MCMM\] TLU+ stack = $_stack"
read_parasitic_tech -name typical -tlup ${tluplus_path}/${_stack}_typical_top2.tluplus -layermap ${tluplus_map}
read_parasitic_tech -name rcbest  -tlup ${tluplus_path}/${_stack}_rcbest_top2.tluplus  -layermap ${tluplus_map}
read_parasitic_tech -name rcworst -tlup ${tluplus_path}/${_stack}_rcworst_top2.tluplus -layermap ${tluplus_map}

set_parasitic_parameters -corners slow \
    -early_spec rcworst -early_temperature -40 \
    -late_spec  rcworst -late_temperature  125
set_parasitic_parameters -corners fast \
    -early_spec rcbest -early_temperature -40 \
    -late_spec  rcbest -late_temperature  125

#-----------------------------------------------------------------------------
# Clock + I/O delay constraints. Partition exposes hclk as the primary
# system clock; secondary domain clocks (phc_clk, scan_clk, user_ref_clk,
# pad_clk_rx) are layered on by inputs/constraints.sdc which is sourced
# from 1_init_design.tcl AFTER this script.
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: clock constraints"

create_clock -name $clk_name -period $clk_period \
    -waveform "0 [expr {$clk_period / 2.0}]" [get_ports $clk_name]

# Separate setup vs hold uncertainty. The CLK_UNCERTAINTY env var sets
# setup margin (~10% of clock period for jitter + skew). Hold uncertainty
# is independent and must be much smaller — typical chip clocks see
# 50-100 ps of inter-flop skew, not 350 ps.
#
# History on this knob: a single 0.35 ns uncertainty applied to both
# setup and hold kept hold WNS pinned at −0.34 ns regardless of opto.
# Dropping hold to 0.05 closed hold completely but gave synth too much
# freedom on output cones, regressing LEC equivalence (40 port failures
# + 968 don't-verify). 0.10 is the industry-standard middle ground —
# closes hold without triggering aggressive opto on outputs.
set hold_uncert 0.10
puts "INFO: clock uncertainty: setup=$clk_uncert  hold=$hold_uncert"
set_clock_uncertainty -setup $clk_uncert [get_clocks $clk_name]
set_clock_uncertainty -hold  $hold_uncert [get_clocks $clk_name]

if {[sizeof_collection [get_ports $rst_name -quiet]] > 0} {
    set_false_path -from [get_ports $rst_name]
}

set io_delay [expr {$clk_period * 0.25}]

set all_inputs_raw [all_inputs]
set exclude_ports [list]
if {[sizeof_collection [get_ports $clk_name -quiet]] > 0} { lappend exclude_ports $clk_name }
if {[sizeof_collection [get_ports $rst_name -quiet]] > 0} { lappend exclude_ports $rst_name }

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

set_scenario_status -setup true -leakage_power false *

# NOTE: floorplan is initialised by the calling flow (rtl-architect or
# fusion-compiler each pick their own shape) — not done here.

echo "FC_RTL_SCRIPT: done"
