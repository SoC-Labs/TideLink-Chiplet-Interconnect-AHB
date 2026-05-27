// =============================================================================
// wlink_lane_checker.sv — Per-lane training-pattern lock detector
// =============================================================================
//
// BRINGUP_REPORT.md §9 RTL changes for FPGA bring-up.
//
// One single-lane instance: samples the 16-bit deserialised lane word, compares
// it to {expected_byte, expected_byte} (since the training pattern repeats
// within the 16-bit serialiser frame). On match, increments a 5-bit
// match_count; on mismatch, resets it. When match_count reaches LOCK_THRESH
// (default 16), the `locked` output is asserted.
//
// The 16-bit wide compare is intentional: with the WavD2DGpioRx bit-slip
// applying a right-rotation by 0..7 bits within the captured 16-bit word, the
// "aligned" output is byte-aligned when both upper and lower bytes match the
// expected pattern. Any other slip value leaves the word unequal.
//
// The wrapper `wlink_lane_checker` instantiates 8 of these in parallel, one
// per lane, and packs the per-lane `locked` outputs into `lane_locked[7:0]`.
// =============================================================================

`timescale 1ns/1ps

module tidelink_lane_checker_single #(
    parameter int LOCK_THRESH = 16
)(
    input  logic        clk,
    input  logic        rst,         // active-high
    input  logic [15:0] word_in,
    input  logic [7:0]  expected_byte,
    output logic        locked
);

    logic [4:0] match_count;
    // §9.11e (2026-05-28): match {P, ~P} instead of {P, P} to align with
    // WavD2DGpioTx's new training emission. The complement at the
    // byte-boundary forces an always-transition 8-bit pattern, exercising
    // the high-ISI conditions real data has. Lock criterion preserved:
    // 16 consecutive 16-bit-word matches (=256 consecutive correctly-
    // decoded bits) — same protocol, only the expected sequence changes.
    wire  [15:0] expected_word = {expected_byte, ~expected_byte};
    wire         is_match      = (word_in == expected_word);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            match_count <= 5'd0;
        end else if (is_match) begin
            if (match_count < 5'd31)
                match_count <= match_count + 5'd1;
        end else begin
            match_count <= 5'd0;
        end
    end

    assign locked = (match_count >= LOCK_THRESH[4:0]);

endmodule


module tidelink_lane_checker #(
    parameter int LOCK_THRESH = 16
)(
    input  logic         clk,
    input  logic         rst,
    // Per-lane deserialised 16-bit words (one per lane, 8 lanes).
    input  logic [127:0] lane_data,   // {lane7_word, ..., lane0_word}, each 16 bits
    output logic [7:0]   lane_locked
);

    // Per-lane training patterns — must match WavD2DGpio's hard-wired
    // io_training_pattern values. We use period-8 bytes (no byte equals any
    // of its rotations by 1..7) so that the 16-bit {P,P} word is matched by
    // exactly one slip value in [0..7]. The original spec's (N+1)*8'h11
    // patterns have period 4, which aliased slip detection: at SKID=1 the
    // matching slip was 7 mod 4 = 3 and at SKID=5 it was 3 mod 4 = 3, but
    // also slip=7 matched, causing wrong calibration. Period-8 patterns
    // give unambiguous calibration.
    localparam logic [7:0] PATTERNS [0:7] = '{
        8'hA3, 8'hB5, 8'hC9, 8'hD3,
        8'h65, 8'h4B, 8'h59, 8'h2D
    };

    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : g_lane
            tidelink_lane_checker_single #(.LOCK_THRESH(LOCK_THRESH)) u_check (
                .clk          (clk),
                .rst          (rst),
                .word_in      (lane_data[16*i +: 16]),
                .expected_byte(PATTERNS[i]),
                .locked       (lane_locked[i])
            );
        end
    endgenerate

endmodule
