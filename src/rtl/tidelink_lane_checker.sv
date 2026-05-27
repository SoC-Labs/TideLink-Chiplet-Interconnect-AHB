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
    output logic        locked,
    // v2 EYE: one-cycle pulse on every mismatch — ANDable with the
    // calibrator's (sweep_slip, sweep_phase) to score per-cell fails.
    output logic        mismatch_pulse,
    // v2 EYE: saturating 8-bit CRC-error counter (mismatch run-length
    // proxy; resets on clear).  Reaches 0xFF and holds.
    input  logic        crc_err_cnt_clr,
    output logic [7:0]  crc_err_cnt
);

    logic [4:0] match_count;
    wire  [15:0] expected_word = {expected_byte, expected_byte};
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

    assign locked         = (match_count >= LOCK_THRESH[4:0]);
    assign mismatch_pulse = ~is_match;

    // Saturating 8-bit mismatch counter.  Increments on every mismatch
    // pulse; cleared on the RC strobe from tidelink_eye_regs.
    logic [7:0] crc_err_cnt_r;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            crc_err_cnt_r <= 8'd0;
        else if (crc_err_cnt_clr)
            crc_err_cnt_r <= 8'd0;
        else if (mismatch_pulse && (crc_err_cnt_r != 8'hFF))
            crc_err_cnt_r <= crc_err_cnt_r + 8'd1;
    end
    assign crc_err_cnt = crc_err_cnt_r;

endmodule


module tidelink_lane_checker #(
    parameter int LOCK_THRESH = 16
)(
    input  logic         clk,
    input  logic         rst,
    // Per-lane deserialised 16-bit words (one per lane, 8 lanes).
    input  logic [127:0] lane_data,   // {lane7_word, ..., lane0_word}, each 16 bits
    output logic [7:0]   lane_locked,
    // v2 EYE: per-lane mismatch pulse (one cycle per mismatch).  Drives
    // the calibrator's score scratchpad in conjunction with the live
    // (sweep_slip, sweep_phase) iterator.
    output logic [7:0]   mismatch_pulse,
    // v2 EYE: per-lane saturating 8-bit CRC-error counters and the
    // RC clear strobe from tidelink_eye_regs.  Packed as one word per
    // lane: lane N at bits [8*(N%4)+7 : 8*(N%4)].
    input  logic         crc_err_cnt_clr,
    output logic [7:0]   lane_crc_err_cnt_0,
    output logic [7:0]   lane_crc_err_cnt_1,
    output logic [7:0]   lane_crc_err_cnt_2,
    output logic [7:0]   lane_crc_err_cnt_3,
    output logic [7:0]   lane_crc_err_cnt_4,
    output logic [7:0]   lane_crc_err_cnt_5,
    output logic [7:0]   lane_crc_err_cnt_6,
    output logic [7:0]   lane_crc_err_cnt_7
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

    wire [7:0] crc_err_cnt_w [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : g_lane
            tidelink_lane_checker_single #(.LOCK_THRESH(LOCK_THRESH)) u_check (
                .clk            (clk),
                .rst            (rst),
                .word_in        (lane_data[16*i +: 16]),
                .expected_byte  (PATTERNS[i]),
                .locked         (lane_locked[i]),
                .mismatch_pulse (mismatch_pulse[i]),
                .crc_err_cnt_clr(crc_err_cnt_clr),
                .crc_err_cnt    (crc_err_cnt_w[i])
            );
        end
    endgenerate

    assign lane_crc_err_cnt_0 = crc_err_cnt_w[0];
    assign lane_crc_err_cnt_1 = crc_err_cnt_w[1];
    assign lane_crc_err_cnt_2 = crc_err_cnt_w[2];
    assign lane_crc_err_cnt_3 = crc_err_cnt_w[3];
    assign lane_crc_err_cnt_4 = crc_err_cnt_w[4];
    assign lane_crc_err_cnt_5 = crc_err_cnt_w[5];
    assign lane_crc_err_cnt_6 = crc_err_cnt_w[6];
    assign lane_crc_err_cnt_7 = crc_err_cnt_w[7];

endmodule
