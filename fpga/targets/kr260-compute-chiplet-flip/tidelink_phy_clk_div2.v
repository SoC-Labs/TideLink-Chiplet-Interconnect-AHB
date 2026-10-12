//-----------------------------------------------------------------------------
// TideLink PHY link/pad clock /8 divider (KR260 / Zynq UltraScale+)
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
// On the Z2 (Zynq-7000) this module was a /2 (clk_wiz clk_out1 = 4.687 MHz ->
// 2.343 MHz). On the KR260 (Zynq UltraScale+, K26 SOM) the MMCME4 cannot cleanly
// emit ~4.7 MHz (the required output divider exceeds the primitive's range), so
// the clk_wiz clk_out1 is set to a comfortably-in-range 25 MHz and this module
// divides it by 8 to give a 3.125 MHz / 320 ns PHY bit clock — conservatively
// close to the Z2's silicon-proven-slow 2.343 MHz eye-widening regime, and the
// single knob to change if the KR260 eye wants a faster/slower link:
//   PHY rate = clk_out1 / DIV  (here 25 MHz / 8 = 3.125 MHz).
//
// Wiring (see tidelink_design.tcl): clk_wiz_0/clk_out1 (25 MHz) feeds clk_in;
// clk_out (3.125 MHz) drives ONLY tidelink_0/user_ref_clk and scan_clk. hclk and
// every AXI ACLK stay on clk_out1 at 25 MHz. The hclk<->PHY crossings are 2-flop
// CDC'd in RTL and declared asynchronous in the timing XDC (the 3.125 MHz
// user_ref_clk domain is in the async clock_groups), so a separate divided
// domain is safe.
//
// IMPLEMENTATION NOTE: a free-running counter + explicit BUFG (portable, and
// identical in spirit to the proven Z2 toggle-FF+BUFG) rather than BUFGCE_DIV.
// BUFGCE_DIV is the native UltraScale+ way, but cascading it off an existing
// clk_wiz BUFG output can trip CLOCK_DEDICATED_ROUTE; the counter+BUFG has no
// such constraint and re-buffers the divided clock onto a global clock spine so
// it reaches the PHY capture/serializer flops on dedicated clock routing. On
// UltraScale+ a `BUFG` instance maps to a BUFGCE (fully supported). Vivado infers
// a generated clock at the BUFG output, period 8 x the source.
//
// The counter has no reset (free-running, phase is don't-care: the PHY
// calibrator + the async clock_groups absorb start-up phase).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
module tidelink_phy_clk_div2 (
    input  wire clk_in,
    output wire clk_out
);

    // /8 free-running counter on the source clock. bit[2] toggles every 4
    // clk_in cycles -> period 8 -> clk_in/8 at exact 50% duty. (* keep *) so
    // synthesis does not retime/merge the clock-generation register.
    (* keep = "true" *) reg [2:0] div_cnt = 3'b000;

    always @(posedge clk_in) begin
        div_cnt <= div_cnt + 3'b001;
    end

    // Re-buffer the divided clock onto a global clock net (maps to BUFGCE on US+).
    BUFG u_div_bufg (
        .I (div_cnt[2]),
        .O (clk_out)
    );

endmodule
