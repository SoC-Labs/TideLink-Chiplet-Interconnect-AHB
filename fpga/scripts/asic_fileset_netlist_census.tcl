# Post-synthesis netlist census of the FIVE divergent AXI FC nodes.
#
# A netlist grep for a `wire` is an unconditional zero (synthesis collapses
# combinational names), so every marker used here is a FLOP that must survive
# synthesis, and every "absent" claim is paired with a must-be-present control
# on the SAME hierarchy path.
open_checkpoint $env(TL_DCP)
puts "CENSUS: checkpoint [current_project]"

set nodes {wlink_axiawFC wlink_axiwFC wlink_axibFC wlink_axiarFC wlink_axirFC}

# --- CONTROL: a flop that MUST exist in every FC node, in BOTH file sets.
# If this is 0 the hierarchy path is wrong and every count below is vacuous.
foreach n $nodes {
    set ctl [llength [get_cells -quiet -hier -filter "NAME =~ *${n}*state_reg*"]]
    puts "CENSUS_CONTROL ${n}.state_reg = $ctl"
}

# --- The recovery markers. All are COUNTERS or registers in
# src/rtl/local_overrides/WlinkGenericFCSM*.v, i.e. real flops with
# netlist-searchable names. ZERO on the tapeout file set.
foreach m {socl_l7_wdog_cnt socl_l6_cr_emit_count socl_l7_crack_emit_count \
           socl_l7_bringup_forgive socl_reack_idle_cnt} {
    set tot 0
    foreach n $nodes {
        set c [llength [get_cells -quiet -hier -filter "NAME =~ *${n}*${m}*"]]
        incr tot $c
    }
    set all [llength [get_cells -quiet -hier -filter "NAME =~ *${m}*"]]
    puts "CENSUS_MARKER ${m} in_axi_nodes=$tot anywhere_in_design=$all"
}

# --- CROSS-CHECK: FCSM_6 (wlink_tidelinktl) is taken from local_overrides by
# BOTH flists and DOES carry the watchdog. It must be NON-ZERO. This proves the
# search string itself works -- a zero here would mean the grep is dead and the
# zeros above prove nothing.
set six [llength [get_cells -quiet -hier -filter "NAME =~ *wlink_tidelinktl*socl_*"]]
puts "CENSUS_XCHECK FCSM_6(wlink_tidelinktl) socl_* cells = $six"

# --- The substituted memory.
set rf [llength [get_cells -quiet -hier -filter "NAME =~ *u_rf*" ]]
set bram [llength [get_cells -quiet -hier -filter "REF_NAME =~ RAMB*"]]
puts "CENSUS_SRAM u_rf_cells=$rf RAMB_primitives=$bram"
puts "CENSUS_DONE"
