//-----------------------------------------------------------------------------
// TideLink PHY link/pad clock /8 divider - INST1 (die_b) phase-offset copy.
//   ON-CHIP PAIR fallback for OQ3: a DISTINCT module name whose DEFAULT INIT
//   already carries the +3-count power-up offset, so inst1 needs NO CONFIG
//   override on its `-type module` BD cell.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This is byte-for-byte the same logic as tidelink_phy_clk_div2.v EXCEPT:
//   1. the module name is `tidelink_phy_clk_div2_b` (a second module-reference
//      target, so the BD can bind inst1 to it directly), and
//   2. the INIT_PHASE default is 3'b011 (not 3'b000).
//
// WHY A SECOND FILE (OQ3 / AR4 recommendation): a `-type module` BD cell CAN in
// principle expose the RTL parameter as CONFIG.INIT_PHASE and override it per
// instance, but for a *sized vector* parameter [2:0] the BD stores CONFIG as a
// string and vector-parameter inference is a documented Vivado-version hazard
// (value-format / width truncation, less battle-tested than integer params).
// Rather than risk a mid-build surprise, inst1 references THIS module: the +3
// offset comes from the module DEFAULT, needing zero CONFIG plumbing. inst0
// (die_a) references tidelink_phy_clk_div2 (default INIT_PHASE=3'b000). See
// KR260_PAIR_ONCHIP_PLAN.md W3 "Fallback (OQ3)" and sec 4.
//
// PHASE OFFSET (25 MHz clk_in -> 3.125 MHz /8 output, 320 ns UI):
//   dphi = (3 - 0) mod 8 * 40 ns = 120 ns = 0.375 UI = 135 deg. Non-zero, non-
//   degenerate, inside the PHY +/-160 ns absorption window (WavD2DGpioRx.v:385-396).
//
// BUILD NOTE (handoff to W9 / build_design.tcl): build_design.tcl:255 globs the
// EXACT filename `tidelink_phy_clk_div2.v` only -- there is no *.v wildcard, so
// THIS file is NOT auto-added. W9 must add an explicit `add_files` for it (mirror
// build_design.tcl:255-262) or the inst1 module-reference will fail to resolve.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none
module tidelink_phy_clk_div2_b #(
    // Default carries the inst1 (die_b) power-up offset with no override needed.
    parameter [2:0] INIT_PHASE = 3'b011
) (
    input  wire clk_in,
    output wire clk_out
);

    // See tidelink_phy_clk_div2.v for the full rationale. keep + dont_touch is
    // load-bearing: it stops opt_design merging this counter with inst0's (they
    // share a clock and differ only in INIT) and preserves div_cnt_reg for the
    // post-synth zero-skew proof.
    (* keep = "true", dont_touch = "true" *) reg [2:0] div_cnt = INIT_PHASE;

    always @(posedge clk_in) begin
        div_cnt <= div_cnt + 3'b001;
    end

    BUFG u_div_bufg (
        .I (div_cnt[2]),
        .O (clk_out)
    );

endmodule
`default_nettype wire
