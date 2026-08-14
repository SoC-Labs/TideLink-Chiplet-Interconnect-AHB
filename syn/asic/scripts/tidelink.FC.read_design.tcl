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
# TOP is the elaboration top; MODULE is the flists/partition name.
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
# MCMM (Multi-Corner Multi-Mode) setup.
#   FC_LIB_NAME_SS  worst case  V_LO T_HI  → SS (max-delay) → scen_slow
#   FC_LIB_NAME_FF  best  case  V_HI T_LO  → FF (min-delay) → scen_fast
#
# These are the Liberty LIBRARY NAMES as they appear inside the .db (normally
# the .db filename without its extension), not paths. The stems encode the PVT
# characterisation corner and therefore differ per library family and per
# release, so they are set in <repo>/site.env (see site.env.example) — deriving
# them here from DB_SS/DB_FF would be a guess, and a wrong -library name is
# reported by fc_shell as a missing library rather than as a misconfiguration.
#
# Operating-condition labels WCCOM/BCCOM are foundry-standard across families.
#-----------------------------------------------------------------------------
echo "FC_RTL_SCRIPT: MCMM"

proc _fc_lib_name {var corner} {
    if {[info exists ::env($var)] && $::env($var) ne ""} { return $::env($var) }
    error "\[MCMM\] $var is not set — it is the $corner-corner Liberty library\n\
           \      name as it appears inside the .db (usually the .db filename\n\
           \      without its extension). Set it in <repo>/site.env (see\n\
           \      site.env.example) or export it. There is no default."
}
set _lib_name_ss [_fc_lib_name FC_LIB_NAME_SS slow]
set _lib_name_ff [_fc_lib_name FC_LIB_NAME_FF fast]
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
# Parasitic extraction (TLU+).
# FC_TLU_STACK is the filename stem the TLU+ files in TLUPLUS_PATH are named
# with. It encodes the metal-stack option, which differs per library family and
# per release, so it is set in <repo>/site.env (see site.env.example) rather
# than committed. It must describe the same stack as TF_FILE: a mismatched
# TLU+ set is read without complaint and extracts the wrong parasitics.
#-----------------------------------------------------------------------------
if {![info exists ::env(FC_TLU_STACK)] || $::env(FC_TLU_STACK) eq ""} {
    error "\[MCMM\] FC_TLU_STACK is not set — it is the filename stem of the TLU+\n\
           \      files in TLUPLUS_PATH, encoding the metal stack (the flow reads\n\
           \      <stem>_typical_top2.tluplus and its rcbest/rcworst siblings).\n\
           \      Set it in <repo>/site.env (see site.env.example). No default."
}
set _stack $::env(FC_TLU_STACK)
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

#-----------------------------------------------------------------------------
# PER-SCENARIO application (blocker ASIC-2, fixed 2026-08-14).
#
# set_clock_uncertainty / set_input_delay / set_output_delay are applied
# to the CURRENT SCENARIO in fc_shell U-2022.12 — they are not shared
# across the scenarios of a mode the way create_clock is. Until now this
# block ran once, with no current_scenario call, so everything landed in
# whichever scenario happened to be current — scen_fast, because it is
# created last (:170 above).
#
# What that cost, MEASURED on the shipping 2026-06-03 signoff.design:
#   get_attribute [get_clocks hclk] setup_uncertainty
#     scen_slow (WCCOM, THE setup-signoff corner) : 0.000000
#     scen_fast (BCCOM)                           : 0.350000
#   check_timing TCK-012 "input port has no clock_relative delay"
#     Corner 'slow' : 607 ports      Corner 'fast' : 1 port (hresetn,
#                                    the one this script excludes)
# i.e. scen_slow was placed, CTS'd, routed and signed off with zero
# clock uncertainty and zero boundary I/O constraints. Its reported
# Setup WNS of -0.00 had no margin subtracted from it at all.
#
# The pad_rx[*] delays were never affected — 1_init_design.tcl already
# loops read_sdc over both scenarios, which is the control that proves
# the split was real (pad_rx appears in neither corner's TCK-012 list).
#-----------------------------------------------------------------------------
set _scen_list [list]
foreach_in_collection _s [get_scenarios -quiet] {
    lappend _scen_list [get_attribute $_s name]
}
if {[llength $_scen_list] == 0} { set _scen_list [list ""] }

foreach _scen $_scen_list {
    if {$_scen ne ""} { current_scenario $_scen }

    set_clock_uncertainty -setup $clk_uncert [get_clocks $clk_name]
    set_clock_uncertainty -hold  $hold_uncert [get_clocks $clk_name]

    if {[sizeof_collection $all_inputs] > 0} {
        set_input_delay  -clock $clk_name $io_delay $all_inputs
    }
    if {[sizeof_collection $all_outputs] > 0} {
        set_output_delay -clock $clk_name $io_delay $all_outputs
    }

    #-------------------------------------------------------------------------
    # OCV timing derate. There was NO set_timing_derate anywhere in the
    # repo before 2026-08-14 ("Clock derating is disabled",
    # reports/07_check_clock_trees.rep:11), on a 65 nm design signed off
    # with on_chip_variation analysis — so OCV analysis was running with
    # a derate factor of exactly 1.0, i.e. no on-chip variation at all.
    #
    # These are conventional 65 nm flat-derate starting values, NOT
    # characterised numbers. They are deliberately modest so that
    # re-enabling them is a margin change, not a redesign. Replace with
    # foundry AOCV/POCV tables before tapeout.
    #   cell/net late  +5%   early -5%
    #   clock late     +7%   early -7%   (clock trees see more variation)
    # Override with FC_DERATE_LATE / FC_DERATE_EARLY, or set
    # FC_TIMING_DERATE=off to reproduce the pre-2026-08-14 behaviour.
    #-------------------------------------------------------------------------
    set _derate on
    if {[info exists ::env(FC_TIMING_DERATE)]} { set _derate $::env(FC_TIMING_DERATE) }
    if {$_derate eq "off"} {
        puts "WARNING: \[read_design\] $_scen: FC_TIMING_DERATE=off — OCV runs with derate 1.0"
    } else {
        set _d_late  1.05
        set _d_early 0.95
        if {[info exists ::env(FC_DERATE_LATE)]  && $::env(FC_DERATE_LATE)  ne ""} { set _d_late  $::env(FC_DERATE_LATE) }
        if {[info exists ::env(FC_DERATE_EARLY)] && $::env(FC_DERATE_EARLY) ne ""} { set _d_early $::env(FC_DERATE_EARLY) }
        set _d_clk_late  [expr {1.0 + ($_d_late  - 1.0) * 1.4}]
        set _d_clk_early [expr {1.0 - (1.0 - $_d_early) * 1.4}]

        set_timing_derate -cell_delay -late  $_d_late
        set_timing_derate -cell_delay -early $_d_early
        set_timing_derate -net_delay  -late  $_d_late
        set_timing_derate -net_delay  -early $_d_early
        set_timing_derate -clock -cell_delay -late  $_d_clk_late
        set_timing_derate -clock -cell_delay -early $_d_clk_early
        set_timing_derate -clock -net_delay  -late  $_d_clk_late
        set_timing_derate -clock -net_delay  -early $_d_clk_early
        puts [format "INFO: \[read_design\] %s: derate data %.3f/%.3f  clock %.3f/%.3f (late/early)" \
                $_scen $_d_late $_d_early $_d_clk_late $_d_clk_early]
    }

    puts "INFO: \[read_design\] $_scen: uncertainty + I/O delay + derate applied"
}

set_scenario_status -setup true -leakage_power false *

# NOTE: floorplan is initialised by the calling flow (rtl-architect or
# fusion-compiler each pick their own shape) — not done here.

echo "FC_RTL_SCRIPT: done"
