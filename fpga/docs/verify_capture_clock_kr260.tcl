# verify_capture_clock_kr260.tcl — post-route structural check of the RX
# capture-clock tree on the KR260 tidelink targets.
#
# WHY: the #1 bring-up reliability defect is a placement lottery — the 8 per-lane
# RX capture mux chains are lane-identical, so Vivado merges them into ONE LUT and
# fans a fanout-372 GENERAL-ROUTING net to all 8 capture flops. That
# placement-varying inter-lane clock skew is the lottery. The proven fix (phaseB
# parent hoist, commit 2c32c2b, param USE_SHARED_CAP_BUFG) replaces that LUT with
# 2 shared BUFGs. THIS SCRIPT tells you which one you built:
#   * capture clock driven by a global buffer (BUFG/BUFGCE/BUFGCTRL) -> FIXED
#   * capture clock driven by a LUT / general route                  -> DEFECTIVE
#
# It is a CHECK, not a fix — it changes nothing in the design.
#
# NOTE (author could not execute this — no Vivado/route available at write time).
# Validate the exact property/command names on the first bench route; the verdict
# logic (driver ref-name is a global buffer or not) is device-independent and the
# best-effort blocks are wrapped in `catch` so they can never mask the verdict.
#
# USAGE (routed design must be open):
#   vivado -mode batch -source fpga/docs/verify_capture_clock_kr260.tcl \
#          -tclargs <routed_design.dcp>
# or, inside an interactive session with the run already open:
#   source fpga/docs/verify_capture_clock_kr260.tcl
# Exit code: 0 = capture clock is on a global buffer; 1 = LUT/general route
# (RTL shared-BUFG fix absent) or the capture flops could not be found.

set _dcp ""
if {[llength $argv] >= 1} { set _dcp [lindex $argv 0] }
if {$_dcp ne "" && [file exists $_dcp]} {
    puts "INFO: opening checkpoint $_dcp"
    open_checkpoint $_dcp
}

# --- locate the capture flops (same pattern the pblock uses) -----------------
set caps [get_cells -quiet -hier -filter {NAME =~ "*gpiorx_*/link_data_pad_clk_reg[*]"}]
if {[llength $caps] == 0} {
    puts "FAIL: found 0 gpiorx capture flops (*gpiorx_*/link_data_pad_clk_reg\[*\])."
    puts "      The netlist name may have drifted, or no design is open."
    puts "      -> the pblock_rx_act mitigation is ALSO inert (it uses this pattern)."
    exit 1
}
puts "INFO: found [llength $caps] capture flops."

# --- identify the capture-clock net + its driver -----------------------------
set ff0     [lindex $caps 0]
set clkpin  [get_pins -quiet "$ff0/C"]
set clknet  [get_nets -quiet -of_objects $clkpin]
set srcpin  [get_pins -quiet -leaf -of_objects $clknet -filter {DIRECTION == OUT}]
set drvcell [get_cells -quiet -of_objects $srcpin]

set drv_ref "UNKNOWN"
if {[llength $drvcell]} { set drv_ref [get_property -quiet REF_NAME $drvcell] }
set fo [llength [get_pins -quiet -leaf -of_objects $clknet -filter {DIRECTION == IN}]]

puts "INFO: capture-clock net   = [get_property -quiet NAME $clknet]"
puts "INFO: capture-clock driver= [get_property -quiet NAME $drvcell]  (REF_NAME=$drv_ref)"
puts "INFO: capture-clock fanout= $fo load pins"

# --- best-effort: per-lane routed insertion-delay spread ---------------------
# (informational; wrapped so a property/API mismatch cannot change the verdict)
catch {
    set dmin 1e9 ; set dmax -1e9
    foreach ff $caps {
        set p [get_pins -quiet "$ff/C"]
        set nd [get_net_delays -quiet -interconnect_only -of_objects $clknet -to $p]
        if {[llength $nd]} {
            set d [get_property -quiet SLOW_MAX_DELAY [lindex $nd 0]]
            if {$d ne "" && $d < $dmin} { set dmin $d }
            if {$d ne "" && $d > $dmax} { set dmax $d }
        }
    }
    if {$dmax > $dmin} {
        puts [format "INFO: per-lane capture-clock route delay spread = %.3f ns (min %.3f / max %.3f)" \
              [expr {$dmax - $dmin}] $dmin $dmax]
        puts "INFO: (target after the shared-BUFG fix: ~0.24 ns; LUT/general-route baseline: ~1.8 ns)"
    }
}
# task-named reports for the engineer to eyeball
catch { report_clock_utilization -quiet -file capture_clock_util.rpt
        puts "INFO: wrote report_clock_utilization -> capture_clock_util.rpt" }
catch { report_route_status -quiet -of_objects $clknet -file capture_clock_route_status.rpt
        puts "INFO: wrote report_route_status (capture clock net) -> capture_clock_route_status.rpt" }

# --- verdict -----------------------------------------------------------------
# A global-clock buffer ref-name on US+ is one of BUFGCE / BUFGCE_DIV / BUFGCTRL /
# BUFG / BUFGCE_HDIO. Anything else (LUT*, CARRY, general route) = defective.
if {[regexp {^BUFG} $drv_ref]} {
    puts "PASS: capture clock is driven by a global buffer ($drv_ref)."
    puts "      -> the shared-BUFG capture-clock fix is present. Lottery mitigated."
    exit 0
} else {
    puts "FAIL: capture clock is driven by '$drv_ref' (not a BUFG*), fanout $fo."
    puts "      -> the RTL shared-BUFG fix (USE_SHARED_CAP_BUFG / commit 2c32c2b) is"
    puts "         ABSENT. This build has the placement-lottery defect. Land the RTL"
    puts "         fix (cherry-pick 2c32c2b onto integ + package_ip TIDELINK_PHY_V2=1),"
    puts "         or accept lottery bring-up. Do NOT enable USE_CAP_CLKBUF (kills link)."
    exit 1
}
