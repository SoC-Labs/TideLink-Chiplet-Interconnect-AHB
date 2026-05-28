// =============================================================================
// tidelink_lane_checker.sv — Per-lane training-pattern lock detector
// =============================================================================
//
// BRINGUP_REPORT.md §9 RTL changes for FPGA bring-up.
//
// EYE-DATA UPDATE (2026-05-28, feat/calibrator-prbs)
// --------------------------------------------------
// Pre-change: lane_checker matched a constant {expected_byte, expected_byte}
// 16-bit word against the deserialised lane word. With a constant-byte
// training stream the calibrator scored the eye for a period-2 byte —
// narrower data-eyes (arbitrary bit transitions) failed silently on HW.
//
// Post-change: TX (WavD2DGpioTx local_override) emits a PRBS-7 stream
// XORed with a per-lane io_training_pattern tag. The lane_checker now
// runs a per-lane PRBS-7 PREDICTOR (sync-by-prediction, approach (b) of
// the task) — on mismatch it RE-SEEDS the LFSR state from the observed
// data (XOR-stripped of the per-lane tag), then verifies that the next
// K cycles predict correctly.
//
// Lane-uniqueness preservation:
//   * Same PRBS-7 polynomial across lanes (x^7 + x^6 + 1), so all lanes
//     are cyclic shifts of the SAME maximum-length sequence.
//   * Per-lane LANE_TAG (= PATTERNS[i], the existing 8 distinct period-8
//     bytes) is XORed into every emitted bit (byte-cyclic mod 8).
//   * Two lanes' streams therefore differ in PHASE (different seeds) AND
//     in TAG. The lane-i predictor strips LANE_TAG[i] before re-seeding;
//     on a wrong-lane stream the strip removes the WRONG tag, the LFSR
//     re-seeds into a wrong state, and subsequent predictions diverge.
//
// Sync time: re-seed takes 1 cycle, then up to LOCK_THRESH cycles to
// confirm. PRBS-7 period = 127 bits = ~8 words, so worst-case the
// re-seeded state is within 1 word of the true TX state.
// =============================================================================

`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// PRBS-7 16-step lookahead helper (Fibonacci form, poly x^7 + x^6 + 1).
// Returns the 16-bit word emitted by advancing the LFSR 16 times AND the
// 7-bit state after those 16 advances. Bit 0 of `word_out` is the FIRST
// emitted bit; this matches the TX serialiser order (count==0 emits
// _link_data_eff[0]).
// -----------------------------------------------------------------------------
module tidelink_prbs7_lookahead16 (
    input  logic [6:0]  state_in,
    output logic [15:0] word_out,
    output logic [6:0]  state_out
);
    logic [6:0] s [0:16];
    always_comb begin
        s[0] = state_in;
        for (int k = 0; k < 16; k++) begin
            s[k+1] = {s[k][5:0], s[k][6] ^ s[k][5]};
        end
        for (int k = 0; k < 16; k++) begin
            word_out[k] = s[k][6];
        end
        state_out = s[16];
    end
endmodule


module tidelink_lane_checker_single #(
    parameter int       LOCK_THRESH = 16,
    // Per-lane LANE_TAG: 8-bit constant XORed into the predicted/observed
    // word as {tag, tag}. Must match the TX-side io_training_pattern.
    parameter logic [7:0] LANE_TAG  = 8'h00
)(
    input  logic        clk,
    input  logic        rst,         // active-high
    input  logic [15:0] word_in,
    output logic        locked,
    // v2 EYE: one-cycle pulse on every mismatch — ANDable with the
    // calibrator's (sweep_slip, sweep_phase) to score per-cell fails.
    output logic        mismatch_pulse,
    // v2 EYE: saturating 8-bit CRC-error counter (mismatch run-length
    // proxy; resets on clear).  Reaches 0xFF and holds.
    input  logic        crc_err_cnt_clr,
    output logic [7:0]  crc_err_cnt
);

    // Initial PRBS-7 seed = (LANE_TAG >> 1) | 7'h01 (matches TX guard).
    localparam logic [7:0] _seed_full = (LANE_TAG >> 1) | 8'h01;
    localparam logic [6:0] PRBS_SEED_INIT = _seed_full[6:0];
    localparam logic [15:0] LANE_TAG_WORD = {LANE_TAG, LANE_TAG};

    logic [6:0]  prbs_state;
    logic [15:0] predicted_word;
    logic [6:0]  prbs_next_state;
    logic [4:0]  match_count;

    tidelink_prbs7_lookahead16 u_la (
        .state_in (prbs_state),
        .word_out (predicted_word),
        .state_out(prbs_next_state)
    );

    wire [15:0] expected_word = predicted_word ^ LANE_TAG_WORD;
    wire        is_match      = (word_in == expected_word);

    // On mismatch, reseed state from observed bits [6:0] (stripped of tag).
    wire [15:0] word_stripped = word_in ^ LANE_TAG_WORD;
    // Reseed value: ensure non-zero (PRBS-7 stuck at zero) by OR-ing 1
    // into the LSB. Cost: one bit of seed degeneracy; acceptable, as
    // re-seed retries every mismatch cycle so we converge in O(period).
    wire [6:0]  reseed_state  = word_stripped[6:0] | 7'h01;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            prbs_state  <= PRBS_SEED_INIT;
            match_count <= 5'd0;
        end else if (is_match) begin
            prbs_state <= prbs_next_state;
            if (match_count < 5'd31)
                match_count <= match_count + 5'd1;
        end else begin
            // Re-sync: jump LFSR to a state derived from the observed
            // word, drop the streak.
            prbs_state  <= reseed_state;
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
    // of its rotations by 1..7) so the per-lane LANE_TAG XOR mask gives
    // unambiguous lane-stream identification (the calibrator's slip sweep
    // disambiguates byte alignment; the PRBS predictor's re-seed logic
    // disambiguates lane identity via the tag-XOR strip step).
    localparam logic [7:0] PATTERNS [0:7] = '{
        8'hA3, 8'hB5, 8'hC9, 8'hD3,
        8'h65, 8'h4B, 8'h59, 8'h2D
    };

    wire [7:0] crc_err_cnt_w [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : g_lane
            tidelink_lane_checker_single #(
                .LOCK_THRESH(LOCK_THRESH),
                .LANE_TAG   (PATTERNS[i])
            ) u_check (
                .clk            (clk),
                .rst            (rst),
                .word_in        (lane_data[16*i +: 16]),
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
