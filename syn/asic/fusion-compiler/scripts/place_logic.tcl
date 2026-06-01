#-----------------------------------------------------------------------------
# Logic-region constraints — anchor the GPIO RX source-sync capture flops
# (u_chiplet_controller/u_wlink/phy/gpio/gpiorx_*/link_data_pad_clk_reg*)
# to a narrow strip hugging the LEFT edge, so pad_clk_rx -> capture-FF
# clock-network delay fits inside the input_delay -min budget.
#
# Why surgical (128 FFs, not the whole 1728-cell gpio hierarchy):
#   * Build #6 (soft bound, 28% width, all gpio cells) honored the bound
#     but the capture flops still landed at median x=227 µm vs pad_clk_rx
#     pin at x=0 µm — 0.57 ns of clock latency, only 0.01 ns better than
#     unconstrained build #1 (-0.58 ns).
#   * Only the 128 link_data_pad_clk capture FFs matter for the hold arc;
#     constraining all 1728 gpio cells to the same strip just bloated the
#     area without helping the critical endpoints.
#   * Hard bound + tighter 10% strip forces median x <~100 µm, targeting
#     ≤0.3 ns clock latency.
#
# Diagnosis trail (kept for later observers):
#   FC2 aspect-1.0 (~737×736 µm) closed hold clean — gpiorx_* auto-placed
#   close to pad_clk_rx without any anchor. Aspect 2.0 widens X to
#   ~1035 µm; FC's natural placement scatters gpiorx_* eastward and
#   the constraint set_input_delay -min -1.00 (constraints.sdc §1) can't
#   tolerate that much capture-clock latency.
#
# Sourced by 1_init_design.tcl AFTER place_memories.tcl and BEFORE
# place_pins.tcl / pg_mesh.tcl / pre-compile sanity check.
#-----------------------------------------------------------------------------

set cap_cells [get_cells -hier -quiet \
                   -filter "full_name =~ *u_wlink/phy/gpio/gpiorx_*/link_data_pad_clk_reg*"]

if {[sizeof_collection $cap_cells] == 0} {
    puts "WARN: \[place_logic\] no gpiorx_*/link_data_pad_clk_reg* capture flops resolved"
    puts "WARN: \[place_logic\] source-sync RX hold may regress — verify after fc_init"
    return
}

# Use block bbox so the bound scales with any future floorplan change.
# fc_shell U-2022.12: `bbox` attribute returns {{xmin ymin} {xmax ymax}}.
# create_bound (singular) — `create_bounds` plural is unknown in this
# release (probed via `help -verbose create_bound`).
set bb       [get_attribute [current_block] bbox]
set bb_xmin  [lindex $bb 0 0]
set bb_ymin  [lindex $bb 0 1]
set bb_xmax  [lindex $bb 1 0]
set bb_ymax  [lindex $bb 1 1]
set bb_w     [expr {$bb_xmax - $bb_xmin}]
set bb_h     [expr {$bb_ymax - $bb_ymin}]

# Tight 10% strip at the LEFT edge. Span ~90% of height (5% margins
# top/bottom) so the placer has Y freedom — 128 FFs × ~5 µm² need only
# ~640 µm² in this ~10500 µm² strip (~6% utilization).
set bx_min [expr {$bb_xmin + 0.01 * $bb_w}]
set bx_max [expr {$bb_xmin + 0.10 * $bb_w}]
set by_min [expr {$bb_ymin + 0.05 * $bb_h}]
set by_max [expr {$bb_ymax - 0.05 * $bb_h}]

puts [format "INFO: \[place_logic\] block bbox = (%.1f %.1f) (%.1f %.1f)  W=%.1f H=%.1f" \
        $bb_xmin $bb_ymin $bb_xmax $bb_ymax $bb_w $bb_h]
puts [format "INFO: \[place_logic\] gpio capture anchor = (%.1f %.1f) (%.1f %.1f) — leftmost 9%% of width" \
        $bx_min $by_min $bx_max $by_max]
puts [format "INFO: \[place_logic\] anchoring %d capture flops (HARD)" \
        [sizeof_collection $cap_cells]]

create_bound -name gpio_rx_capture_left \
             -boundary [list [list $bx_min $by_min] [list $bx_max $by_max]] \
             -type hard \
             $cap_cells

puts "INFO: \[place_logic\] gpio_rx_capture_left bound created (hard)"
