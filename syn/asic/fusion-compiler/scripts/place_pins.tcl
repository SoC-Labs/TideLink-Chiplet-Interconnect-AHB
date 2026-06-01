#-----------------------------------------------------------------------------
# Port-to-side assignment for tidelink_top as a chip-top partition.
#
# Convention (wide-rectangle partition, aspect ~2.0):
#   LEFT   — external chiplet interface: PHY pads (pad_*) + I2C
#            + user_ref_clk (TideLink/Wlink reference clock, drives PHY logic)
#   RIGHT  — system APB bus + hclk + hresetn + poresetn + apb_debug_unlock_i
#   TOP    — PHC time interface (phc_*) + phc_clk + phc_resetn + phc_locked_i
#   BOTTOM — system AHB bus + scan_clk + scan_mode + scan_asyncrst_ctrl
#            + scan_shift + scan_in + scan_out (DFT chain)
#
# Sourced by 1_init_design.tcl AFTER place_memories.tcl and BEFORE the
# pre-compile sanity check. Constraints attach to ports via
# set_individual_pin_constraints; pin placement runs at the end of this
# script with place_pins.
#-----------------------------------------------------------------------------

# fc_shell U-2022.12 numbers the die sides 1..4 starting at the leftmost
# vertical edge and going clockwise: 1=left, 2=top, 3=right, 4=bottom.
array set SIDE {left 1  top 2  right 3  bottom 4}

proc constrain_pins_on_side {patterns side_name label} {
    global SIDE
    set ports [get_ports -quiet $patterns]
    if {[sizeof_collection $ports] == 0} {
        puts "INFO: \[place_pins\] no ports matched for $label — skipping"
        return
    }
    set side $SIDE($side_name)
    set_individual_pin_constraints -ports $ports -sides $side
    puts "INFO: \[place_pins\] $label : [sizeof_collection $ports] ports -> $side_name (side $side)"
}

# ── LEFT — PHY pads + I2C + user_ref_clk ─────────────────────────────────
constrain_pins_on_side {
    pad_clk_tx
    pad_clk_rx
    pad_tx*
    pad_rx*
    i2c_scl_i
    i2c_scl_o
    i2c_scl_t
    i2c_sda_i
    i2c_sda_o
    i2c_sda_t
    i2c_nbsy_irq
    i2c_nrd_empty_irq
    user_ref_clk
} left "PHY pads + I2C + user_ref_clk"

# ── BOTTOM — AHB busses + DFT scan ───────────────────────────────────────
constrain_pins_on_side {
    ahb_sub_*
    ahb_tx_*
    ahb_fifo_*
    ahb_mng_*
    ahb_ptp_*
    scan_clk
    scan_mode
    scan_asyncrst_ctrl
    scan_shift
    scan_in
    scan_out
} bottom "AHB busses + DFT scan"

# ── RIGHT — APB register bus + hclk + system resets ──────────────────────
constrain_pins_on_side {
    apb_*
    apb_debug_unlock_i
    hclk
    hresetn
    poresetn
} right "APB bus + hclk + system resets"

# ── TOP — PHC time interface + PHC clock/reset ───────────────────────────
constrain_pins_on_side {
    phc_clk
    phc_resetn
    phc_seconds*
    phc_nanoseconds*
    phc_pps
    phc_hw_capture
    phc_hw_cap_*
    phc_hw_set_*
    phc_hw_adj_*
    phc_locked_i
} top "PHC time interface + phc_clk"

#-----------------------------------------------------------------------------
# Run the pin placer now so the assignments are baked into init.design and
# visible in the GUI. compile_fusion will respect the placed pins.
#-----------------------------------------------------------------------------
puts "INFO: \[place_pins\] running place_pins"
if {[catch {place_pins -ports [get_ports]} err]} {
    # place_pins is best-effort at init stage — if a port-collection or
    # pin-track constraint trips a hard error, log and continue. The
    # placer runs again inside compile_fusion which is the canonical
    # gate; this initial pass just makes the GUI view useful.
    puts "WARN: \[place_pins\] init-stage place_pins returned: $err"
    puts "WARN: \[place_pins\]   compile_fusion will re-run pin placement"
}
