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
#-----------------------------------------------------------------------------

set tidelink_home $::env(TIDELINK_HOME)
set top_module    $::env(MODULE)
set flist         $::env(FLIST)
set target_lib    $::env(TARGET_LIB)
set link_libs     $::env(LINK_LIBS)
set clk_name      $::env(CLK_NAME)
set clk_period    $::env(CLK_PERIOD)
set rst_name      $::env(RST_NAME)

# ── Library setup ──────────────────────────────────────────────────────────
set_app_var target_library $target_lib
set_app_var link_library   "* $link_libs"
set_app_var search_path    "$tidelink_home/src/rtl"

# ── Read design ────────────────────────────────────────────────────────────
analyze -format sverilog -f $flist
elaborate $top_module

# ── Design constraints ─────────────────────────────────────────────────────
create_clock -name $clk_name -period $clk_period [get_ports $clk_name]

# Reset: treat as asynchronous, don't time it
set_false_path -from [get_ports $rst_name]

# Input/output delays (25% of clock period as default estimate)
set io_delay [expr {$clk_period * 0.25}]
set all_inputs  [remove_from_collection [all_inputs] [get_ports [list $clk_name $rst_name]]]
set all_outputs [all_outputs]

set_input_delay  -clock $clk_name $io_delay $all_inputs
set_output_delay -clock $clk_name $io_delay $all_outputs

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
