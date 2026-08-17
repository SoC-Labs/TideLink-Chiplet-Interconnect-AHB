//-----------------------------------------------------------------------------
// SoCLabs TideLink Link-Clock Divider
//
// Programmable power-of-two divider on the D2D PHY high-speed reference
// (user_ref_clk -> user_hsclk -> WlinkGPIOPHY io_hsclk). Lets the link bit
// rate be lowered at bring-up to open a marginal receive eye WITHOUT moving
// the SoC system clock and without a board change.
//
// WHY THIS EXISTS
//   WlinkGPIOPHY_v2.v:357 is `assign gpio_io_hsclk = user_hsclk` -- 1:1, no
//   PLL -- and WavD2DGpioTx.v:322 forwards a gated copy of that same clock out
//   on the pad. So whatever arrives here IS the per-lane bit rate. On the
//   ethernet chiplet user_ref_clk is additionally aliased onto sys_fclk in the
//   chip boundary spec (sys_desc/chip_boundary/nanosoc_eth_chiplet.yaml), which
//   ties the link rate to the system clock. This module breaks that tie, in the
//   downward direction only.
//
// SAFETY PROPERTIES -- these are the reasons for the shape of this RTL.
//
//   1. RESET DEFAULT IS /1 BYPASS. Out of reset this module is a wire plus one
//      mux stage, so mission-mode signoff analyses substantially the structure
//      that shipped before it existed. Divided modes are an opt-in bring-up
//      capability, NOT part of the default configuration. Changing
//      RATIO_RESET changes what STA signs off -- see the parameter comment.
//
//   2. THE DIVIDED CLOCK COMES OFF A SINGLE FLOP (clkdiv_r), so its duty cycle
//      is exactly 50% by construction, independent of the input duty cycle.
//      That matters more here than it looks: the forwarded pad clock IS the
//      far receiver's eye reference, and
//      ASIC/genus-innovus/inputs/constraints.sdc:34-39 works out that ~0.2ns of
//      the 0.35ns clock uncertainty is CDCM61001 duty-cycle distortion
//      (45%/55% ODC) against only ~0.012ns of actual jitter. Dividing
//      REGENERATES the edge instead of inheriting that distortion, so a divided
//      mode is cleaner per-UI than the ratio alone would suggest.
//
//   3. POWER-OF-TWO RATIOS ONLY. An odd divide needs a dual-edge structure to
//      hold 50% duty, and a distorted forwarded clock directly costs receive
//      eye -- the exact thing this module exists to buy. Do NOT add odd ratios
//      without also adding the negedge half.
//
//   4. THE BYPASS<->DIVIDED HANDOVER IS INTERLOCKED, NOT TRUSTED. The
//      documented discipline is to change the ratio only while the PHY is held
//      in POR (wlink_por_reset), but a software mistake must not put a runt
//      pulse into the PHY or onto the pad. This link already has a marginal-eye
//      data-drop history; 20 lines of interlock is cheap against that.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
`default_nettype none

module tidelink_link_clk_div #(
    // Ratio applied while rst_n is asserted, and the fallback for an
    // out-of-range ratio_i. 3'd0 = /1 bypass.
    //
    // DO NOT change this default to a divided value without re-reading safety
    // property 1 above. It is the difference between "the shipping
    // configuration is what we already signed off" and "the shipping
    // configuration is a new clock structure".
    parameter [2:0] RATIO_RESET = 3'd0
) (
    input  wire       clk_in,     // undivided PHY reference (user_ref_clk)
    input  wire       rst_n,      // async assert; release must be clean
    input  wire [2:0] ratio_i,    // 0=/1 1=/2 2=/4 3=/8 4=/16 (>4 clamps to /16)
    input  wire       scan_mode,  // DFT: force /1 bypass
    output wire       clk_out,    // -> user_hsclk
    output wire [2:0] ratio_o     // ratio actually in force (status readback)
);

    // ------------------------------------------------------------------------
    // Ratio capture
    // ------------------------------------------------------------------------
    // ratio_i is quasi-static -- written once at bring-up over APB, then held
    // -- and crosses from the APB/hclk domain into clk_in. Two flops handle
    // metastability. The third stage adopts a value only once it has been seen
    // IDENTICAL on two consecutive samples, so a multi-bit code caught
    // mid-transition cannot be momentarily decoded as a third, unintended
    // ratio. That is not paranoia about the CDC: a transient decode of, say,
    // /16 during a /1 -> /2 write would briefly retime the PHY reference.
    reg [2:0] ratio_meta_r;
    reg [2:0] ratio_sync_r;
    reg [2:0] ratio_r;

    always @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) begin
            ratio_meta_r <= RATIO_RESET;
            ratio_sync_r <= RATIO_RESET;
            ratio_r      <= RATIO_RESET;
        end else begin
            ratio_meta_r <= ratio_i;
            ratio_sync_r <= ratio_meta_r;
            if (ratio_sync_r == ratio_meta_r) begin
                ratio_r <= ratio_sync_r;
            end
        end
    end

    // Clamp. An out-of-range code must resolve to a DEFINED slow rate rather
    // than an undecoded case: slower is always the safe direction here.
    wire [2:0] ratio_q = (ratio_r > 3'd4) ? 3'd4 : ratio_r;

    assign ratio_o = ratio_q;

    // ------------------------------------------------------------------------
    // Divided clock
    // ------------------------------------------------------------------------
    // clkdiv_r toggles every 2^(ratio_q-1) cycles of clk_in, giving /2^ratio_q.
    // It free-runs even in bypass -- deliberately. The interlock below can only
    // hand over TO a leg whose clock is running, so parking the divided leg
    // would make bypass a one-way door.
    reg [2:0] half_c;
    always @(*) begin
        case (ratio_q)
            3'd1:    half_c = 3'd0;  // /2  : toggle every 1 cycle
            3'd2:    half_c = 3'd1;  // /4  : toggle every 2 cycles
            3'd3:    half_c = 3'd3;  // /8  : toggle every 4 cycles
            default: half_c = 3'd7;  // /16 : toggle every 8 cycles
        endcase
    end

    reg [2:0] cnt_r;
    reg       clkdiv_r;

    always @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) begin
            cnt_r    <= 3'd0;
            clkdiv_r <= 1'b0;
        end else if (cnt_r >= half_c) begin
            // `>=`, not `==`. If the ratio SHRINKS while cnt_r is already past
            // the new terminal count, `==` would strand the counter and stall
            // the divided clock until it wrapped all the way round -- which
            // with the interlock below would look like a hung link, not a
            // slow one.
            cnt_r    <= 3'd0;
            clkdiv_r <= ~clkdiv_r;
        end else begin
            cnt_r    <= cnt_r + 3'd1;
        end
    end

    // ------------------------------------------------------------------------
    // Glitchless bypass <-> divided handover
    // ------------------------------------------------------------------------
    // Two-leg interlock. Each leg's enable is retimed on the FALLING edge of
    // ITS OWN clock and is gated by the other leg being already disabled. Two
    // consequences, and they are the whole proof:
    //   - the two enables can never be high simultaneously, so the AND-OR below
    //     never merges two clocks;
    //   - an enable only ever changes while its own clock is LOW, so gating it
    //     cannot truncate a high phase into a runt.
    // Handover therefore costs at most one cycle of each leg and is glitch-free
    // for any ratio_i write at any time, including while the link is running.
    wire sel_div = (ratio_q != 3'd0) && !scan_mode;

    reg byp_en_meta_r, byp_en_r;
    reg div_en_meta_r, div_en_r;

    always @(negedge clk_in or negedge rst_n) begin
        if (!rst_n) begin
            byp_en_meta_r <= 1'b1;   // /1 bypass IS the reset configuration
            byp_en_r      <= 1'b1;
        end else begin
            byp_en_meta_r <= ~sel_div & ~div_en_r;
            byp_en_r      <= byp_en_meta_r;
        end
    end

    always @(negedge clkdiv_r or negedge rst_n) begin
        if (!rst_n) begin
            div_en_meta_r <= 1'b0;
            div_en_r      <= 1'b0;
        end else begin
            div_en_meta_r <= sel_div & ~byp_en_r;
            div_en_r      <= div_en_meta_r;
        end
    end

    // PHYSICAL NOTE FOR THE ASIC FLOW. This AND-OR is on the clock path and
    // must be mapped to clock-net cells and protected from logic
    // restructuring -- set_dont_touch / size_only on this instance, and it
    // wants to be a leaf of the CTS source, not something CCOpt reshapes. In
    // SDC this net is the -source for the TX word clocks; see the note added
    // alongside D2D_TX_CLK_0 in ASIC/genus-innovus/inputs/tidelink_constraints.sdc.
    assign clk_out = (clk_in & byp_en_r) | (clkdiv_r & div_en_r);

endmodule

`default_nettype wire
