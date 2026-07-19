// =============================================================================
// eye_fault.sv — MARGINAL-EYE fault injector for the V2 pair tb (HARNESS ONLY)
//
// The ideal sim PHY models cross-lane skew as a CLEAN whole-word shift
// (pad_skid). On silicon the eye is marginal: each lane also suffers
// occasional bit errors / metastable samples under sustained data, and the
// training-exit content edge the epoch anchor keys on can be corrupted. The
// clean-skew sim therefore PASSES with EPOCH_ANCHOR_EN=1 (the anchor latches
// the right per-lane offset) where real silicon FAILS.
//
// This module sits on a lane bus (post-skid) and XORs a per-lane bit error
// onto pad_data when ERR_EN is asserted by cocotb. Two cocotb-driven controls
// (hierarchical force, no port wiring needed):
//
//   err_en        : 1 = injection active this pad_clk window
//   err_mask[7:0] : which lanes to corrupt (one bit per lane)
//   err_burst[3:0]: how many CONSECUTIVE pad_clk bits to flip on each
//                   corrupted lane when a "hit" fires (>3 within one 16-bit
//                   word pushes that word's Hamming distance past the anchor's
//                   EPOCH_MATCH_THRESH=3 -> the matcher scores a NON-match)
//   err_period[15:0]: a hit fires every err_period pad_clk cycles (the lane
//                   BER cadence). 0 disables the periodic engine; cocotb can
//                   instead pulse err_en directly for a one-shot burst.
//
// pad_clk is forwarded unchanged. All registers init to "no injection" so a
// module that is instantiated but never enabled is a pure passthrough (every
// existing test is bit-identical).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module eye_fault #(
    parameter int LANES = 8
) (
    input  wire             pad_clk_in,
    input  wire [LANES-1:0] pad_data_in,
    output wire             pad_clk_out,
    output wire [LANES-1:0] pad_data_out
);
    assign pad_clk_out = pad_clk_in;

    // cocotb-driven controls (deposited hierarchically from the test). These
    // are NOT written by any always block, so cocotb's value-set is the only
    // driver. Declaration-time init = "no injection".
    logic              err_en     = 1'b0;
    logic [LANES-1:0]  err_mask   = '0;
    logic [3:0]        err_burst  = 4'd0;
    logic [15:0]       err_period = 16'd0;

    // Periodic hit engine: every err_period pad_clk cycles, arm a burst of
    // err_burst flips. burst_ctr counts down the active-flip window. Driven
    // ONLY by this always block (no decl-time init -> single procedural
    // driver; err_en defaults 0 so the first edge zeroes both before any
    // flip can fire).
    logic [15:0] period_ctr;
    logic [3:0]  burst_ctr;

    always @(posedge pad_clk_in) begin
        if (!err_en || err_period == 16'd0) begin
            period_ctr <= 16'd0;
            burst_ctr  <= 4'd0;
        end else begin
            if (period_ctr >= err_period - 1) begin
                period_ctr <= 16'd0;
                burst_ctr  <= err_burst;   // (re)arm a burst
            end else begin
                period_ctr <= period_ctr + 1'b1;
                if (burst_ctr != 4'd0) burst_ctr <= burst_ctr - 1'b1;
            end
        end
    end

    // Flip the masked lanes whenever a burst is active.
    wire flip_now = err_en && (burst_ctr != 4'd0);
    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_flip
            assign pad_data_out[l] = (flip_now && err_mask[l])
                                     ? ~pad_data_in[l]
                                     : pad_data_in[l];
        end
    endgenerate

endmodule

`default_nettype wire
