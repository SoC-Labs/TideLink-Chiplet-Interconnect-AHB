//-----------------------------------------------------------------------------
// TideLink PHY link/pad clock /8 divider (KR260 / Zynq UltraScale+)
//   ON-CHIP PAIR variant: parameterised power-up phase (INIT_PHASE).
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Purpose: derive the slow GPIO-PHY link/pad clock (user_ref_clk) from the
// system clock without fighting the MPSoC MMCME4 output-frequency floor.
//
// On the KR260 (Zynq UltraScale+, K26 SOM) the MMCME4 cannot cleanly emit
// ~4.7 MHz (the required output divider exceeds the primitive's range), so the
// clk_wiz clk_out1 is set to a comfortably-in-range 25 MHz and this module
// divides it by 8 to give a 3.125 MHz / 320 ns PHY bit clock:
//   PHY rate = clk_out1 / 8  (here 25 MHz / 8 = 3.125 MHz, 320 ns UI).
// (The module keeps its historical `_div2` name — it was a /2 on the Z2 — so the
// BD `create_bd_cell -type module -reference tidelink_phy_clk_div2` still binds.)
//
//-----------------------------------------------------------------------------
// WHY THIS COPY EXISTS (the on-chip-pair zero-skew trap):
//
// The kr260-pair-onchip target instantiates TWO complete TideLink cores in one
// bitstream and cross-connects their PHY pads THROUGH THE FABRIC (no pin). Each
// core gets its OWN /8 divider, both fed from the same clk_wiz clk_out1.
//
// DEFINITIVE FACT (verified against kr260-pair-ptp/tidelink_phy_clk_div2.v:51):
// on UltraScale+ `reg [2:0] div_cnt = 3'b000` is a real FF INIT loaded by GSR at
// end-of-configuration. Two identical-INIT copies clocked by the SAME clk_out1
// power up at the same value and increment in lockstep FOREVER -> their BUFG
// outputs are bit-identical -> ZERO relative skew, even though they are separate
// nets. So "one divider per instance" ALONE does NOT decorrelate the two dies:
// it would silently re-create the shared-ref_clk, zero-skew condition that lets
// the deskew/calibrator/CDC pass for the wrong reason.
//
// MITIGATION: give each instance's counter a DIFFERENT power-up value via the
// INIT_PHASE parameter. inst0 (die_a) uses INIT_PHASE=3'b000; inst1 (die_b) uses
// 3'b011 (see tidelink_phy_clk_div2_b.v). Because both counters are GSR-loaded
// and clocked identically, div_cnt_b(t) = div_cnt_a(t) + 3 (mod 8) for all t, a
// CONSTANT, STATIC offset. The /8 tap is bit[2], so the two recovered clocks are
// phase-shifted by:
//     dphi = ((INIT1 - INIT0) mod 8) * T_clk_in
//          = 3 counts * 40 ns  = 120 ns
//          = 120 / 320 = 0.375 UI = 135 deg  of the 3.125 MHz output.
// 120 ns is comfortably non-zero and non-degenerate (NOT 0, NOT 180 deg / half-UI
// which an inverted-but-aligned tool model could alias), and it sits inside the
// PHY's +/-half-word (+/-160 ns) static-skew absorption window (WavD2DGpioRx.v:
// 385-396), so the intra-die RX<->TX deskew/CDC runs with REAL static skew while
// the capture eye stays closeable. gcd(3,8)=1 -> a genuinely distinct phase, not
// a harmonic alias.
//
// This exercises a fixed mesochronous skew + the deskew FIFO. It does NOT model
// oscillator drift (one MMCM => 0 ppm) or POR skew (one reset) -- those are
// phase-2 levers (W12/W13). See KR260_PAIR_ONCHIP_PLAN.md sec 4.
//-----------------------------------------------------------------------------
// IMPLEMENTATION NOTE: a free-running counter + explicit BUFG (portable, and
// identical in spirit to the proven Z2 toggle-FF+BUFG) rather than BUFGCE_DIV.
// On UltraScale+ a `BUFG` instance maps to a BUFGCE (fully supported) and re-
// buffers the divided clock onto a global clock spine so it reaches the PHY
// capture/serialiser flops on dedicated clock routing. Vivado infers a generated
// clock at the BUFG output, period 8 x the source.
//
// (* keep, dont_touch *) on the counter is LOAD-BEARING here: dont_touch stops
// opt_design merging the two per-instance counters (which, sharing a clock and
// differing only in INIT, are otherwise merge candidates) and keep preserves the
// div_cnt_reg name so the post-synth zero-skew proof can read its INIT.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none
module tidelink_phy_clk_div2 #(
    // Power-up value of the /8 counter -> the FF INIT attribute (GSR-loaded).
    // Default 3'b000 keeps this byte-behaviour-identical to the non-parameterised
    // single-instance copy, so inst0 (die_a) needs no override.
    parameter [2:0] INIT_PHASE = 3'b000
) (
    input  wire clk_in,
    output wire clk_out
);

    // /8 free-running counter on the source clock. bit[2] toggles every 4 clk_in
    // cycles -> period 8 -> clk_in/8 at exact 50% duty. INIT_PHASE sets the GSR
    // power-up value so a second instance can hold a static phase offset.
    // (* keep + dont_touch *): keep the div_cnt_reg name and forbid opt_design
    // from merging/retiming/absorbing this clock-generation register (a second
    // instance differing only in INIT must NOT be collapsed into this one).
    (* keep = "true", dont_touch = "true" *) reg [2:0] div_cnt = INIT_PHASE;

    always @(posedge clk_in) begin
        div_cnt <= div_cnt + 3'b001;
    end

    // Re-buffer the divided clock onto a global clock net (maps to BUFGCE on US+).
    BUFG u_div_bufg (
        .I (div_cnt[2]),
        .O (clk_out)
    );

endmodule
`default_nettype wire
