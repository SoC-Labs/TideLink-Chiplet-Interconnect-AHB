//-----------------------------------------------------------------------------
// TideLink PHY link/pad clock /2 divider (7-series / Zynq-7000)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Purpose: halve the GPIO-PHY link/pad clock (user_ref_clk) from the clk_wiz
// MMCM floor of 4.687 MHz (213.333 ns) down to 2.343 MHz (426.666 ns) to widen
// the marginal A->B receive eye, WITHOUT slowing the rest of the system. The
// clk_wiz MMCM cannot emit below 4.687 MHz, so a post-MMCM /2 is the only way to
// reach 2.343 MHz on this fabric.
//
// Wiring (see tidelink_design.tcl): clk_wiz_0/clk_out1 (4.687 MHz) feeds clk_in;
// clk_out (2.343 MHz) drives ONLY tidelink_0/user_ref_clk and tidelink_0/scan_clk.
// hclk and every AXI ACLK stay on clk_out1 directly at 4.687 MHz. The hclk<->PHY
// crossings are already 2-flop CDC'd in RTL and are declared asynchronous in the
// timing XDC (the 2.343 user_ref_clk domain is added to the async clock_groups),
// so making user_ref_clk a separate /2 domain is safe.
//
// IMPLEMENTATION NOTE — why a toggle-FF + BUFG and NOT BUFGCE_DIV:
//   BUFGCE_DIV is an UltraScale / UltraScale+ primitive ONLY; the PYNQ-Z2 part
//   (xc7z020clg400-1, Zynq-7000 / Artix-7 fabric) does NOT support it (Vivado
//   reports Netlist 29-180 "not a supported primitive for zynq part ... treated
//   as a black box"). util_ds_buf:2.2 likewise has no divide mode (BUFGCE only
//   gates). The portable 7-series /2 is a toggle flip-flop on clk_in (rising-edge
//   /2, exact 50% duty) re-buffered onto a global clock net by an explicit BUFG so
//   the divided clock reaches the PHY capture/serializer flops on a dedicated
//   clock-spine net (not LUT/general routing). Vivado infers a generated clock at
//   the BUFG output, period 2 x the source.
//
// The toggle FF has no reset (free-running /2, phase is don't-care: the PHY
// calibrator + the async clock_groups absorb the start-up phase) and CE tied
// high (always dividing).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
module tidelink_phy_clk_div2 (
    input  wire clk_in,
    output wire clk_out
);

    // /2 toggle flop on the source clock. (* keep *) so synthesis does not merge
    // or retime it; it is the clock-generation register.
    (* keep = "true" *) reg div_q = 1'b0;

    always @(posedge clk_in) begin
        div_q <= ~div_q;
    end

    // Re-buffer the divided clock onto a global clock net (7-series BUFG).
    BUFG u_div_bufg (
        .I (div_q),
        .O (clk_out)
    );

endmodule
