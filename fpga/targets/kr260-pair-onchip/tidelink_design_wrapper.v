//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge - KR260 On-Chip PAIR Board Wrapper (kr260-pair-onchip)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Synthesis top read by build_design.tcl (STEP 4: add_files + set_property top).
// Instantiates the tidelink_design block design. The module name MUST stay
// `tidelink_design_wrapper` (build_design.tcl:305-306 hardcodes it as the top).
//
// TWO complete TideLink instances live in ONE xck26 bitstream, cross-connected
// ENTIRELY through the fabric. tidelink_0 = die_a (role-strap 0, master-by-
// priority); tidelink_1 = die_b (role-strap 1, slave-by-priority). NO PHY
// signal reaches a pin and NO I2C signal reaches a pin.
//
// Unlike the Z2 PS7 wrapper, there are NO DDR / FIXED_IO ports: on the MPSoC the
// PS DDR4 + MIO are bonded to the K26 SOM and configured by the board preset
// inside the BD — they are not brought out as PL top-level ports. This matches
// the single-instance kr260-pair-ptp / kr260-pair-nptp wrappers exactly.
//
//=============================================================================
// KEY DESIGN DECISION (binding contract for W5, the BD author) — READ THIS
//=============================================================================
// The TX->RX data/forwarded-clock cross-connect AND the I2C wired-AND sideband
// live INSIDE the block design (a set of connect_bd_net calls + two
// util_vector_logic AND cells), NOT in this wrapper. Reasoning:
//
//   * The pynq-z2-loopback wrapper folded TX back to RX at the WRAPPER level
//     because it had ONE BD cell whose own outputs had to meet its own inputs —
//     two ports of the SAME instance only meet outside the BD, so a wrapper wire
//     was the only place to join them.
//   * Here the cross-connect is between TWO different BD cells (tidelink_0 and
//     tidelink_1), and both cells already live inside the BD. Joining two BD
//     cells is naturally connect_bd_net with NO external port at all. Promoting
//     those nets to wrapper ports would be strictly worse (extra boundary,
//     zero benefit). See KR260_PAIR_ONCHIP_PLAN.md sections 3.1 / 3.6 / 3.7.
//   * Consequence (a GOOD outcome the plan calls for): this wrapper is
//     intentionally THIN — PS ports (none on the K26 SOM) + LEDs only.
//
// Therefore W5's block design `tidelink_design` MUST expose EXACTLY these four
// external ports and NOTHING else on its boundary:
//       led0, led1, led2, led3   (all `output wire`, active-high)
// with the four PHY channel nets (TX clock, TX data, RX clock, RX data) and the
// I2C SCL/SDA sideband all cross-connected internally (never surfaced as BD or
// wrapper ports). If W5 surfaces any PHY-channel or I2C port on the BD boundary,
// this instantiation will fail to bind and the on-chip-pair contract is broken.
//
//=============================================================================
// LED MAP (the cheapest on-bench proof that BOTH dies came up with OPPOSITE
// roles). W5 drives these BD nets to match:
//   led0 = tidelink_0 (die_a, strap 0) link_active
//   led1 = tidelink_0 (die_a) role_is_master        -> expected 1 (master)
//   led2 = tidelink_1 (die_b, strap 1) link_active
//   led3 = tidelink_1 (die_b) role_is_master        -> expected 0 (slave)
// Bench read: led0 & led2 both lit  => both links up.
//             led1 XOR led3         => exactly one master (complementary roles).
// Grouped "2 per die" per plan section 3.1; led2/led3 replace the forked
// kr260-pair-nptp wrapper's inherited tidelink_0 wlink_irq / released_credits
// LED nets (W5 deletes those first to avoid double-drive).
//-----------------------------------------------------------------------------

module tidelink_design_wrapper (
    // Board status LEDs (PMOD0, active-high). See kr260_tidelink.xdc.
    // No PHY channel ports and no I2C ports exist on this wrapper: the entire
    // cross-connect is internal to the block design (see contract above).
    output wire        led0,              // tidelink_0 (die_a) link_active
    output wire        led1,              // tidelink_0 (die_a) role_is_master
    output wire        led2,              // tidelink_1 (die_b) link_active
    output wire        led3               // tidelink_1 (die_b) role_is_master
);

    //=========================================================================
    // Block Design Instance
    //
    // Only led0..led3 are wired. Everything else — both PS master fan-outs, the
    // TX->RX data/clock cross-connect, the I2C open-drain wired-AND, both strap
    // and debug-unlock GPIOs, both ahb_mng BRAM termini, and every tie-off
    // (tl_bcast_ack_i, tc_axis_*, tc_qos_priority, scan/DFT, the PHC inputs
    // while PTP is off) — is driven INSIDE the block design via connect_bd_net
    // and xlconstant cells. Those nets are not exposed as BD external ports, so
    // they do not appear in this instantiation.
    //=========================================================================
    tidelink_design tidelink_design_i (
        .led0                     (led0),
        .led1                     (led1),
        .led2                     (led2),
        .led3                     (led3)
    );

endmodule
