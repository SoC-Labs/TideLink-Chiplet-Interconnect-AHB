#-----------------------------------------------------------------------------
# Memory macro placement — pin the rf_16k FIFO RAM to the bottom-right
# corner so the std-cell region is one cohesive rectangle on the left and
# top. Without this anchoring, FC's auto-place tends to drop the macro
# somewhere in the interior, which fragments std-cell space and hurts the
# area-tight (0.85 util) floorplan.
#
# Layout strategy (aspect 1.0 partition):
#   Bottom-right corner — 1× rf_16k (~312 × 285 μm)
#   Std cells           — fill the L-shape left + top
#
# Sourced by 1_init_design.tcl AFTER initialize_floorplan and BEFORE the
# pre-compile sanity check.
#
# Hierarchy reference (tidelink_top → rf_16k):
#   u_tidelink_fifo / u_fifo_mem / u_sram / u_rf
#-----------------------------------------------------------------------------

set fifo_ram {u_tidelink_fifo/u_fifo_mem/u_sram/u_rf}

# Older / smaller MODULE cuts (e.g. tidelink_top without the FIFO wrapper)
# may resolve the macro under a slightly different parent. Probe a couple
# of fallback paths so place_memories doesn't hard-fail on those flists.
set candidates [list \
    $fifo_ram \
    {u_tidelink_fifo/u_sram/u_rf} \
    {u_tidelink_fifo_ahb/u_tidelink_fifo/u_fifo_mem/u_sram/u_rf}]

set fifo_ram_resolved ""
foreach path $candidates {
    if {[sizeof_collection [get_cells -quiet $path]] > 0} {
        set fifo_ram_resolved $path
        break
    }
}

if {$fifo_ram_resolved eq ""} {
    puts "WARN: \[place_memories\] no rf_16k instance resolved from candidates: $candidates"
    puts "WARN: \[place_memories\] FC will auto-place macros — check report_placement after fc_init"
    return
}

puts "INFO: \[place_memories\] anchoring rf_16k at $fifo_ram_resolved"

#-----------------------------------------------------------------------------
# Anchor the FIFO RAM at the bottom-right corner. set_macro_relative_location
# places the cell relative to a die corner; offsets are fractional with
# offset_type=scalable so the placement scales with the floorplan size.
#-----------------------------------------------------------------------------
set_macro_relative_location \
    -target_object   [get_cells $fifo_ram_resolved] \
    -target_orientation R0 \
    -target_corner   br \
    -anchor_corner   br \
    -offset          {-0.02 0.02} \
    -offset_type     scalable

create_macro_relative_location_placement

# Lock the macro so place_opt / clock_opt / route_opt don't relocate it.
set_attribute -objects [get_cells $fifo_ram_resolved] \
    -name physical_status -value fixed

# 5 μm hard keepout / 8 μm soft around the macro — gives the router clean
# channels along the macro edges.
set ref [get_attribute [get_cells $fifo_ram_resolved] ref_block]
create_keepout_margin -type hard -outer {5 5 5 5} $ref
create_keepout_margin -type soft -outer {8 8 8 8} $ref

puts "INFO: \[place_memories\] rf_16k pinned + locked at bottom-right"
