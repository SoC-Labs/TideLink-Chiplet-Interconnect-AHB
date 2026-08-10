// =============================================================================
// tidelink_idelay_rx.sv — Per-lane IDELAYE2 RX delay element, calibrator-driven
// =============================================================================
//
// SoC Labs §9 FPGA bring-up — structural fix for the slave-RX-lock determinism
// blocker (see /tmp/timing_determinism_investigation_brief.md §"Concrete XDC
// constraints" point 4, and project_tidelink_fpga_bringup memory).
//
// PROBLEM (proven in HW, v4/v6/v7/v7-slow): the Wav GPIO PHY is source-
// synchronous with NO ISERDES/static IODELAY centering. The runtime
// calibrator (tidelink_phy_align_calibrator.sv) sweeps a per-lane bit-slip
// (0..7) + per-lane sub-bit phase (0..15) and drives the PHY deserialiser's
// bit-position selector. Its capture window is finite: it only locks if the
// build-time per-lane clk-to-data routing skew lands inside that window.
// Vivado has zero constraint on that skew (set_input/output_delay disabled,
// pad_clk_rx async-grouped), so it places the 8 capture paths with arbitrary,
// build-varying delay. Today the calibrator's "phase" only moves a
// deserialiser bit-SELECT — it is NOT a physical delay; it cannot shift the
// actual clk-to-data relationship at the IOB. The result is build-to-build
// nondeterminism — the slave is the systematically-unlucky side.
//
// THIS MODULE converts "hope the routing skew lands in the calibrator's
// window" into an explicit, characterised delay line: one Xilinx IDELAYE2
// (VAR_LOAD) per pad_rx[n], its 5-bit tap LOADED from the calibrator's
// existing per-lane 4-bit phase value (swi_phase_offset_w[4N +: 4], range
// 0..15, scaled into the 0..31 IDELAY tap space). One IDELAYCTRL calibrates
// the bank's delay taps against a 200 MHz reference. The calibrator now
// drives a REAL sub-tap-precision delay (≈ tap × IDELAY tap resolution) on
// the data, on TOP of its existing deserialiser bit-select — giving it a
// monotone, characterised lever over the actual clk-to-data eye position.
//
// ADDITIVE & PARAMETER-GATED. The USE_IDELAY parameter is the SINGLE source
// of truth. USE_IDELAY defaults to 0:
//   * USE_IDELAY=0  → pure combinational passthrough (pad_rx_o = pad_rx_i).
//                     NO Xilinx primitive is referenced. Bit-exact to the
//                     pre-change netlist. This is what every HDL simulator
//                     and the ASIC flist all elaborate (the constant
//                     generate-if prunes the IDELAY branch entirely, so the
//                     unisim primitive text is never elaborated/resolved).
//   * USE_IDELAY=1  → per-lane IDELAYE2 + IDELAYCTRL (Xilinx 7-series only).
//                     The FPGA IP wrapper sets this to 1; it is carried into
//                     the packaged IP's component.xml as the parameter
//                     default and reaches the IP's out-of-context synthesis
//                     with NO preprocessor cooperation required.
//
// HISTORY — why this is parameter-only now: a prior revision ALSO required a
// preprocessor `ifdef TIDELINK_USE_IDELAY (opt-IN) set via a packaging-project
// `set_property verilog_define`. That define is NOT baked into the IP-XACT
// core, so it never reached the IP's OOC synth — the `ifdef was always false
// and the IDELAYE2 primitive was silently dropped from EVERY FPGA build
// (proven: an "IDELAY-off" build was byte-identical to the "on" build).
// Fixed by deleting that opt-in guard. The belt-and-braces escape hatch is
// preserved but INVERTED to opt-OUT: a non-Vivado flow that deliberately
// forces USE_IDELAY=1 without a unisim library can define
// TIDELINK_IDELAY_NO_PRIMITIVE to fall back to passthrough. Default
// (undefined) = real IDELAYE2 whenever USE_IDELAY=1 — safe by default.
//
// IDELAYE2 / IDELAYCTRL constraints (handled in pynq_z2_tidelink_idelay.xdc):
//   * IDELAYCTRL needs a stable 200 MHz REFCLK; we expose idelay_ref_clk and
//     a create_clock for it lives in the new *_idelay.xdc. The FPGA target
//     adds a clk_wiz output (see report / tidelink_design.tcl change spec).
//   * IDELAYE2 + its IDELAYCTRL must share an IODELAY_GROUP (string attr +
//     XDC). pad_rx[*] are Bank 13 (HR) on xc7z020-clg400 — IDELAYE2 is
//     available on every 7-series HR/HP I/O; one IDELAYCTRL serves the bank.
//   * REFCLK_FREQUENCY must equal the actual idelay_ref_clk frequency.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tidelink_idelay_rx #(
    // 0 = passthrough (bit-exact, no Xilinx primitive — sim/ASIC default).
    // 1 = per-lane IDELAYE2 + IDELAYCTRL (Xilinx 7-series FPGA only). The
    //     FPGA IP wrapper sets this to 1; carried via the packaged IP's
    //     component.xml. No preprocessor define is needed (see header).
    parameter bit          USE_IDELAY = 1'b0,
    // Number of RX data lanes (GPIO PHY = 8).
    parameter int          NUM_LANES  = 8,
    // IODELAY_GROUP shared by every IDELAYE2 and the IDELAYCTRL. NOTE: the
    // (* IODELAY_GROUP *) attributes below use a STRING LITERAL, not this
    // parameter — Vivado synthesis rejects a SystemVerilog `string`-typed
    // (unpacked) parameter in an attribute expression ([Synth 8-281]
    // "expression must be of a packed type"; this only ever surfaced once
    // the propagation fix made the IDELAY branch actually synthesize). This
    // parameter is kept untyped + documentary; its value, the literal in
    // the attributes, and `_idelay_grp` in pynq_z2_tidelink_idelay.xdc MUST
    // all be the same string.
    parameter              IDELAY_GRP = "tidelink_rx_idelay",
    // IDELAYCTRL reference-clock frequency in MHz. 200.0 is the standard
    // 7-series value (≈ 78 ps/tap at 200 MHz, 32 taps). Must equal the
    // actual frequency of idelay_ref_clk and the create_clock in the XDC.
    // NOTE: Was 'real' for FPGA build; changed to integer for ASIC FC2
    // elaboration (VER-177: real declarations are not supported by
    // synthesis). The only downstream use is at IDELAYE2.REFCLK_FREQUENCY
    // inside the `ifndef TIDELINK_IDELAY_NO_PRIMITIVE` arm which the ASIC
    // build does not exercise. Vivado XPM accepts integer-valued
    // REFCLK_FREQUENCY (200 == 200.0).
    parameter integer      REFCLK_MHZ = 200
) (
    // 200 MHz IDELAYCTRL reference clock (from clk_wiz). Tie to 1'b0 in
    // environments where USE_IDELAY=0 — it is then completely unused.
    input  wire                       idelay_ref_clk,
    // Active-high reset for IDELAYCTRL (hold until idelay_ref_clk is stable;
    // wire to the Wlink/app reset). Unused when USE_IDELAY=0.
    input  wire                       idelay_rst,

    // Per-lane phase from the calibrator OR Region 8 SW-override, packed
    // 8 lanes x 4 bits — lane N at [4N+3:4N], value 0..15. Identical packing
    // to the swi_phase_offset_in path the calibrator already drives into the
    // Wlink deserialiser (this is the calibrator->tap wiring: SAME source).
    input  wire [4*NUM_LANES-1:0]     phase_tap_i,

    // FULL-RANGE IDELAY TAP (SoC Labs 2026-06-25): per-lane tap LSB. The
    // coarse nibble phase_tap_i[4N +: 4] supplies the high 4 bits of a 5-bit
    // IDELAY tap; lsb_i[N] supplies bit[0], so the effective tap spans the
    // FULL 0..31 IDELAYE2 range (odd taps + the upper half) instead of the
    // even-only {nibble,1'b0} (0,2,..30). lane N at bit N.
    //   tap[N] = {phase_tap_i[4N +: 4], lsb_i[N]} = 2*nibble + lsb.
    // DEFAULT 0 (the SW reg POR value) => tap = {nibble,1'b0} = the old
    // even-only behaviour, BIT-IDENTICAL to the pre-change module. The odd
    // taps + upper half are unreachable until SW programs the LSBs. Threaded
    // from the new SWI_PHASE_LSB APB register (SoC 0x4403_21B4), mirroring the
    // swi_phase_offset (0x118) path.
    input  wire [NUM_LANES-1:0]       lsb_i,

    // Raw pad_rx[*] straight from the top-level FPGA input pads.
    input  wire [NUM_LANES-1:0]       pad_rx_i,
    // Delayed pad_rx[*] feeding the Wlink GPIO PHY RX deserialiser.
    output wire [NUM_LANES-1:0]       pad_rx_o
);

    genvar gl;

    generate
        if (USE_IDELAY) begin : g_idelay
`ifndef TIDELINK_IDELAY_NO_PRIMITIVE
            // ---------------------------------------------------------------
            // One IDELAYCTRL for the whole pad_rx bank. RDY is intentionally
            // left unconnected: IDELAYCTRL not asserting RDY only means the
            // taps are uncalibrated (still functional, just less precise) —
            // it must NOT gate the RX datapath or the calibrator. The XDC
            // ties this IDELAYCTRL to the IDELAYE2s via IODELAY_GROUP.
            // ---------------------------------------------------------------
            // Dead-end sink for the IDELAYCTRL RDY output (see below).
            wire idelayctrl_rdy_nc;
            // Literal (not the IDELAY_GRP param) — Vivado synth requires a
            // packed/literal attribute value. MUST equal IDELAY_GRP default
            // and _idelay_grp in pynq_z2_tidelink_idelay.xdc.
            // RDY is an OUTPUT of IDELAYCTRL (UG471/UG953: RDY out, REFCLK in,
            // RST in). Routed to a named dead-end net rather than left as an
            // empty `.RDY()`: the lint flow resolves pin direction from the
            // module port table, and the unisim primitive is not in the lint
            // file set, so an empty connection here is indistinguishable from
            // a floating INPUT — which is a gating class. Naming the net makes
            // the openness explicit and provably inert.
            (* IODELAY_GROUP = "tidelink_rx_idelay" *)
            IDELAYCTRL u_idelayctrl (
                .RDY    (idelayctrl_rdy_nc),
                .REFCLK (idelay_ref_clk),
                .RST    (idelay_rst)
            );

            for (gl = 0; gl < NUM_LANES; gl = gl + 1) begin : g_lane
                // Calibrator nibble for this lane (0..15). Map the 4-bit
                // phase into the 5-bit IDELAY tap space (0..31) with a x2
                // scale so the calibrator's full 0..15 sweep spans roughly
                // half the delay line (≈ 0..2.4 ns at 200 MHz / 78 ps tap),
                // comfortably covering one 25 MHz UI's worth of routing skew
                // while leaving headroom and keeping a 1:1 monotone mapping.
                wire [3:0] lane_phase = phase_tap_i[4*gl +: 4];
                // FULL-RANGE TAP (2026-06-25): low bit from the per-lane LSB
                // strap so the tap reaches ODD values + the upper half of the
                // 0..31 range. lsb_i[gl]=0 => {lane_phase,1'b0} = the historical
                // even-only x2 mapping (0,2,..30), bit-identical default.
                wire [4:0] lane_tap   = {lane_phase, lsb_i[gl]}; // 2*nibble + lsb, 0..31
                // CNTVALUEOUT is an OUTPUT of IDELAYE2 (UG471/UG953) reporting
                // the loaded tap back. Unused: the tap is written, never read
                // back. Named dead-end net rather than an empty connection, for
                // the same reason as IDELAYCTRL.RDY above.
                wire [4:0] cntvalueout_nc;

                // VAR_LOAD: CNTVALUEIN is loaded into the tap when LD=1.
                // We hold LD high so the tap continuously tracks the
                // calibrator's per-lane phase (it changes slowly, well
                // within the IDELAYE2 load timing — the calibrator dwells
                // many cycles per phase). DATAIN/IDATAIN: IDATAIN is the
                // pad path (IBUF output inside the BD/IOB); the tool infers
                // the IBUF->IDELAYE2 connection from the top-level port.
                // Literal IODELAY_GROUP (see IDELAYCTRL note above).
                (* IODELAY_GROUP = "tidelink_rx_idelay" *)
                IDELAYE2 #(
                    .CINVCTRL_SEL          ("FALSE"),
                    .DELAY_SRC             ("IDATAIN"),
                    .HIGH_PERFORMANCE_MODE ("TRUE"),
                    .IDELAY_TYPE           ("VAR_LOAD"),
                    .IDELAY_VALUE          (0),
                    .PIPE_SEL              ("FALSE"),
                    .REFCLK_FREQUENCY      (REFCLK_MHZ),
                    .SIGNAL_PATTERN        ("DATA")
                ) u_idelaye2 (
                    .CNTVALUEOUT (cntvalueout_nc),
                    .DATAOUT     (pad_rx_o[gl]),
                    .C           (idelay_ref_clk),
                    .CE          (1'b0),
                    .CINVCTRL    (1'b0),
                    .CNTVALUEIN  (lane_tap),
                    .DATAIN      (1'b0),
                    .IDATAIN     (pad_rx_i[gl]),
                    .INC         (1'b0),
                    .LD          (1'b1),
                    .LDPIPEEN    (1'b0),
                    .REGRST      (idelay_rst)
                );
            end
`else
            // OPT-OUT escape hatch: reached only if a non-Vivado flow both
            // forces USE_IDELAY=1 AND defines TIDELINK_IDELAY_NO_PRIMITIVE
            // (no unisim library). Falls back to passthrough so elaboration
            // never fails on a missing IDELAYE2 cell. Default builds never
            // define this macro, so the FPGA path needs zero preprocessor
            // cooperation — the USE_IDELAY parameter alone selects IDELAY.
            assign pad_rx_o = pad_rx_i;
            // Reference the would-be-unused ports so lint stays quiet.
            wire _unused_idelay = idelay_ref_clk & idelay_rst &
                                  (|phase_tap_i) & (|lsb_i);
`endif
        end else begin : g_passthru
            // -------------------------------------------------------------
            // Bit-exact passthrough. No Xilinx primitive. This is the path
            // every HDL simulator and the ASIC flist take.
            // -------------------------------------------------------------
            assign pad_rx_o = pad_rx_i;
            // Tie-off references so `default_nettype none + lint don't warn
            // on the (legitimately unused in this mode) control inputs.
            wire _unused_idelay = idelay_ref_clk & idelay_rst &
                                  (|phase_tap_i) & (|lsb_i);
        end
    endgenerate

endmodule

`default_nettype wire
