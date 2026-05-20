#-----------------------------------------------------------------------------
# Port-to-side assignment for tidelink_top as a chip-top partition.
#
# Convention (per partition integration spec):
#   TOP    — external PHY pads (off-chip Wlink GPIO/SerDes lanes)
#   BOTTOM — system AHB bus (regular subordinate + manager + TX aperture
#            + FIFO data window + PTP write port)
#   LEFT   — system APB bus (register access) + PHC time inputs/outputs
#   RIGHT  — clocks, resets, DFT scan
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

# ── TOP — external PHY pads (Wlink off-chip interface) ───────────────────
constrain_pins_on_side {
    pad_clk_tx
    pad_clk_rx
    pad_tx*
    pad_rx*
} top "Wlink PHY pads"

# ── BOTTOM — AHB busses ──────────────────────────────────────────────────
constrain_pins_on_side {
    ahb_sub_*
    ahb_tx_*
    ahb_fifo_*
    ahb_mng_*
    ahb_ptp_*
} bottom "AHB busses"

# ── LEFT — APB + PHC time interface ──────────────────────────────────────
constrain_pins_on_side {
    apb_*
    phc_seconds*
    phc_nanoseconds*
    phc_pps
    phc_hw_capture
} left "APB + PHC time"

# ── RIGHT — clocks / resets / DFT ────────────────────────────────────────
constrain_pins_on_side {
    hclk
    hresetn
    poresetn
    phc_clk
    phc_resetn
    user_ref_clk
    scan_mode
    scan_asyncrst_ctrl
    scan_clk
    scan_shift
    scan_in
    scan_out
} right "clocks + resets + DFT"

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
