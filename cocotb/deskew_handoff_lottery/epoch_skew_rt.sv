// =============================================================================
// epoch_skew_rt.sv — RUNTIME-programmable per-lane WHOLE-WORD skew injector.
//
// Purpose (cocotb/deskew_handoff_lottery): reproduce the KR260 hardware
// observation that, with both dies in data mode (fcsm=4/cal=1), the FIRST
// packet crosses byte-exact but subsequent packets read back all-zero, and
// that WHICH direction / whether-it-delivers is a per-bring-up LOTTERY.
//
// WHY A RUNTIME INJECTOR (vs the compile-time pad_skid used by the sibling
// tidelink_top_pair_v2 bench):
//   * pad_skid bakes the per-lane skew into parameters, so one compiled binary
//     models exactly ONE ribbon realization. The hardware lottery is a SWEEP
//     over realizations — to show intermittency in ONE transcript we must be
//     able to change the per-lane word offsets at RUNTIME, between trials.
//   * The "first-delivers-then-shears WITHIN one bring-up" signature needs a
//     mid-data-mode DISTURBANCE: change a lane's whole-word offset AFTER the
//     first packet has crossed. Because the shipping deskew anchors ONCE at the
//     training->data handoff (SYNC_REANCHOR is inert once latched; the EPOCH
//     anchor is one-shot), a post-first-packet re-alignment cannot be corrected
//     -> the next packet shears. A compile-time injector cannot express that.
//
// MODEL FIDELITY: a whole-word (16 pad_clk cycle) delay shifts a lane's content
// by an integer number of 16-bit link words with NO change to bit-alignment or
// clock phase (the clock is forwarded unchanged, exactly like pad_skid). So:
//   * training / IDELAY / bit-slip still lock (word-multiple skew is invisible
//     to the per-lane trainer — the lanes read 0xFF locked), and
//   * the ASSEMBLED 128-bit io_link_data is sheared by the cross-lane word
//     offsets, which is precisely what the deskew's handoff anchor must undo.
// This is the same abstraction the sibling bench documents; here it is made
// runtime-settable. See README.md for what this CAN and CANNOT prove vs the
// real ribbon (it models discrete whole-word realizations; it does NOT model
// the analog fractional-UI drift that makes the physical lottery continuous).
//
// INTERFACE
//   word_sel : 3 bits per lane (LSB-first: lane L is word_sel[3*L +: 3]),
//              value 0..MAX_WORDS. 0 = passthrough (zero skew). N = delay that
//              lane's data by N whole words (N*16 pad_clk cycles).
//   Changing word_sel while data flows slips that lane by whole words on the
//   fly — an intentional re-alignment DISTURBANCE (glitch is one transitional
//   word), the runtime analog of a per-bring-up realization change.
// =============================================================================
`timescale 1ns/1ps

module epoch_skew_rt #(
    parameter int LANES     = 8,
    parameter int MAX_WORDS = 7,     // task: ribbon skew up to ~7 word-periods
    parameter int WORD_BITS = 16
) (
    input  wire                 pad_clk_in,
    input  wire [LANES-1:0]     pad_data_in,
    input  wire [3*LANES-1:0]   word_sel,      // 3b/lane, 0..MAX_WORDS
    output wire                 pad_clk_out,
    output wire [LANES-1:0]     pad_data_out
);
    localparam int DEPTH = MAX_WORDS * WORD_BITS;   // 112 for MAX_WORDS=7

    // Clock forwarded unchanged — the defect is cross-lane WORD skew, not a
    // clock event (identical stance to pad_skid.sv).
    assign pad_clk_out = pad_clk_in;

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
            // Per-lane history shift register. sr[k] = pad_data_in delayed by
            // (k+1) pad_clk cycles (same tap convention as pad_skid: a D-cycle
            // delay reads sr[D-1]).
            reg [DEPTH-1:0] sr;
            initial sr = '0;
            always @(posedge pad_clk_in)
                sr <= {sr[DEPTH-2:0], pad_data_in[lane]};

            wire [2:0] sel   = word_sel[3*lane +: 3];
            // Delay in pad_clk cycles for this lane = sel * WORD_BITS.
            // sel==0 -> passthrough (input, zero delay).
            wire [$clog2(DEPTH+1)-1:0] tap = sel * WORD_BITS;   // 0..112
            assign pad_data_out[lane] = (sel == 3'd0)
                                        ? pad_data_in[lane]
                                        : sr[tap - 1];
        end
    endgenerate
endmodule
