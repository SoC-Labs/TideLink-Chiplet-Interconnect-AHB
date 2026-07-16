# =============================================================================
# measure_capture_clock.tcl — per-lane RX capture-clock arrival measurement
#
# Purpose: prove/disprove the capture-clock BUFG fix STATICALLY, with no
# hardware. Capture-clock insertion delay is rate-independent routing delay,
# so this measurement is valid at any link rate.
#
# Mirrors the measurement that produced the lane-7 = 15.281 ns figure vs
# ~8.2-8.8 ns on its siblings (routed die_a, 2026-07-14).
#
# Method: for each lane, take the capture flops (link_data_pad_clk_reg), grab
# a timing path ending on them, and read ENDPOINT_CLOCK_DELAY — Vivado's
# "Destination Clock Delay", i.e. the capture-clock arrival at the flop C pin.
# Also reports the clock-net DRIVER type per lane, which is the structural
# tell: BUFG => global net (fixed), LUT* => WavClockMux + general routing.
#
# Usage: vivado -mode batch -source measure_capture_clock.tcl -tclargs <routed.dcp>
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================

if { $argc < 1 } { error "usage: -tclargs <routed_dcp>" }
set dcp [lindex $argv 0]
if { ![file exists $dcp] } { error "no such DCP: $dcp" }

puts "MCC: opening $dcp"
open_checkpoint $dcp

puts ""
puts "MCC: ============================================================"
puts "MCC:  PER-LANE RX CAPTURE-CLOCK ARRIVAL (Destination Clock Delay)"
puts "MCC: ============================================================"
puts [format "MCC: %-5s %-7s %-11s %-9s %s" "lane" "flops" "arrival_ns" "driver" "driver_cell"]

set arrivals [dict create]

for {set lane 0} {$lane < 8} {incr lane} {
    set cells [get_cells -quiet -hier -filter "NAME =~ *gpiorx_${lane}/link_data_pad_clk_reg*"]
    set ncell [llength $cells]
    if { $ncell == 0 } {
        puts [format "MCC: %-5s %-7s %-11s %-9s %s" $lane 0 "NO-CELLS" "-" "-"]
        continue
    }

    # --- structural: what drives the capture clock net for this lane? -------
    set cpins [get_pins -quiet -of_objects $cells -filter {REF_PIN_NAME == C}]
    set drv_ref "-"
    set drv_name "-"
    if { [llength $cpins] > 0 } {
        set cnet [get_nets -quiet -of_objects [lindex $cpins 0]]
        if { [llength $cnet] > 0 } {
            set dpin [get_pins -quiet -of_objects $cnet -filter {DIRECTION == OUT}]
            if { [llength $dpin] > 0 } {
                set dcell [get_cells -quiet -of_objects [lindex $dpin 0]]
                if { [llength $dcell] > 0 } {
                    set drv_ref  [get_property -quiet REF_NAME [lindex $dcell 0]]
                    set drv_name [get_property -quiet NAME     [lindex $dcell 0]]
                }
            }
        }
    }

    # --- timing: capture-clock arrival at the endpoint ----------------------
    # ENDPOINT_CLOCK_DELAY is exactly the "Destination Clock Delay" line in
    # report_timing -path_type full_clock_expanded.
    set dpins [get_pins -quiet -of_objects $cells -filter {REF_PIN_NAME == D}]
    set arr "n/a"
    if { [llength $dpins] > 0 } {
        set paths [get_timing_paths -quiet -to $dpins -max_paths 1 -nworst 1 -setup]
        if { [llength $paths] > 0 } {
            set arr [get_property -quiet ENDPOINT_CLOCK_DELAY [lindex $paths 0]]
            dict set arrivals $lane $arr
        }
    }

    puts [format "MCC: %-5s %-7s %-11s %-9s %s" $lane $ncell $arr $drv_ref $drv_name]
}

# --- spread: the number that decides PROVEN / NOT PROVEN --------------------
if { [dict size $arrivals] > 1 } {
    set vals [dict values $arrivals]
    set mn [lindex [lsort -real $vals] 0]
    set mx [lindex [lsort -real $vals] end]
    puts "MCC: ------------------------------------------------------------"
    puts [format "MCC: min=%.3f ns  max=%.3f ns  SPREAD=%.3f ns" $mn $mx [expr {$mx - $mn}]]
    puts "MCC: (pre-fix reference: lane7=15.281 vs siblings ~8.2-8.8 => spread ~7.05 ns)"
    puts "MCC: PASS criterion: all lanes ~8 ns, sub-ns spread"
}

# --- BUFG budget: the fix costs 8; xc7z020 has 32 --------------------------
set nbufg [llength [get_cells -quiet -hier -filter {REF_NAME == BUFG}]]
puts "MCC: ------------------------------------------------------------"
puts "MCC: BUFG count in design = $nbufg (xc7z020 budget = 32)"
puts "MCC: done"
