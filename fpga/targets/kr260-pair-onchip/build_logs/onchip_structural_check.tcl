# onchip_structural_check.tcl — per-die capture-clock + BUFG/clock-region check
# for the TWO-die kr260-pair-onchip routed design. The stock
# fpga/docs/verify_capture_clock_kr260.tcl assumes ONE instance (it takes the
# first gpiorx flop it finds), so this walks tidelink_0 and tidelink_1 separately.
open_checkpoint [lindex $argv 0]

puts "\n================ PER-DIE RX CAPTURE-CLOCK CHECK ================"
foreach die {tidelink_0 tidelink_1} {
    puts "\n---- $die ----"
    set caps [get_cells -quiet -hier -filter "NAME =~ *${die}/*gpiorx_*/link_data_pad_clk_reg\[*\]"]
    puts "capture flops found: [llength $caps]"
    if {[llength $caps] == 0} { puts "FAIL: no capture flops for $die"; continue }

    set ff0 [lindex $caps 0]
    set clkpin [get_pins -quiet "$ff0/C"]
    set clknet [get_nets -quiet -of_objects $clkpin]
    set srcpin [get_pins -quiet -leaf -of_objects $clknet -filter {DIRECTION == OUT}]
    set drvcell [get_cells -quiet -of_objects $srcpin]
    set drv_ref "UNKNOWN"
    if {$drvcell ne ""} { set drv_ref [get_property -quiet REF_NAME $drvcell] }
    set fo [llength [get_pins -quiet -leaf -of_objects $clknet -filter {DIRECTION == IN}]]
    puts "capture-clock net    : $clknet"
    puts "driver cell / REF    : $drvcell / $drv_ref"
    puts "clock-net fanout     : $fo"
    if {[regexp {^BUFG} $drv_ref]} {
        puts "VERDICT($die): PASS — capture clock on a GLOBAL BUFFER ($drv_ref)"
    } else {
        puts "VERDICT($die): DEFECTIVE — capture clock driven by '$drv_ref' (LUT/general route)"
    }

    # per-lane capture-clock insertion-delay spread (the lottery metric)
    set mn 1e9 ; set mx -1e9 ; set n 0
    foreach ff $caps {
        set p [get_pins -quiet "$ff/C"]
        if {$p eq ""} { continue }
        set d [get_property -quiet FAST_MAX $p]
        if {$d eq "" || $d eq "NONE"} { continue }
        if {$d < $mn} { set mn $d } ; if {$d > $mx} { set mx $d } ; incr n
    }
    if {$n > 0} { puts [format "per-lane clk insertion spread: %.3f ns over %d pins" [expr {$mx-$mn}] $n] }
}

puts "\n================ CLOCK / BUFG BUDGET (risk M2) ================"
set bufgs [get_cells -quiet -hier -filter {REF_NAME =~ BUFG*}]
puts "total BUFG* cells: [llength $bufgs]"
array unset perreg
foreach b $bufgs {
    set site [get_property -quiet SITE $b]
    set cr "UNPLACED"
    if {$site ne ""} { set cr [get_property -quiet CLOCK_REGION [get_sites -quiet $site]] }
    if {$cr eq ""} { set cr "UNKNOWN" }
    if {[info exists perreg($cr)]} { incr perreg($cr) } else { set perreg($cr) 1 }
}
puts "--- BUFG* per clock region (US+ limit = 24 per region) ---"
set worst 0
foreach cr [lsort [array names perreg]] {
    puts [format "  %-12s %d" $cr $perreg($cr)]
    if {$perreg($cr) > $worst} { set worst $perreg($cr) }
}
puts "worst region occupancy: $worst / 24"
if {$worst > 24} {
    puts "VERDICT(M2): EXCEEDED — a region is over the 24-BUFG limit"
} else {
    puts "VERDICT(M2): OK — no clock region exceeds 24 BUFGs"
}

puts "\n================ ZERO-SKEW-TRAP NETLIST PROOF ================"
# The two /8 dividers must survive as TWO distinct un-merged FFs with INIT 000/011.
foreach d {phy_clk_div_0 phy_clk_div_1} {
    set cells [get_cells -quiet -hier -filter "NAME =~ *${d}/*div_cnt_reg\[*\]"]
    puts "$d: [llength $cells] div_cnt FFs"
    foreach c $cells {
        puts "   [get_property -quiet NAME $c]  INIT=[get_property -quiet INIT $c]"
    }
}
exit
