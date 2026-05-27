// =============================================================================
// pad_skid.sv — Parameterised bit-level skid for the Wlink GPIO PHY pads
//
// Models the FPGA-side serial-to-parallel boundary misalignment observed on
// the Pynq-Z2 pair (see BRINGUP_REPORT.md §6, §8.1, §8.4): the recovered
// pad_clk at the receiver is skewed relative to pad_data by ~3 bit periods,
// so the receiver's `count` indexes the wrong bit-position within the byte.
//
// This module sits between TX and RX:
//   - pad_clk is forwarded unchanged.
//   - pad_data[lane] is delayed by SKID_BITS_LANE<lane> pad_clk cycles.
//
// PER-LANE OPERATION (2026-05-14)
// -------------------------------
// To exercise asymmetric misalignment patterns (different skid per lane —
// the realistic FPGA case, where each routing trace has a unique delay),
// the module accepts EIGHT independent per-lane parameters:
//
//     SKID_BITS_LANE0 .. SKID_BITS_LANE7   (each 0..7, default 0)
//
// Each lane's data goes through a shift register sized to MAX_SKID
// (= 7 to cover the worst case) and a multiplexer selects the tap matching
// that lane's chosen skid depth. A lane with skid=0 is a pure passthrough
// (tap = input).
//
// BACKWARD COMPATIBILITY
// ----------------------
// The legacy `SKID_BITS` parameter is still honoured. When the testbench
// instantiates pad_skid with `SKID_BITS = N`, the eight per-lane parameters
// default to N — i.e. uniform skew across all lanes, identical to the pre-
// 2026-05-14 behaviour. Existing tests that set `+define+TB_TOP_SKID_BITS=3`
// (via the wlink_pair Makefile's `SKID_BITS=3` knob) continue to work
// unchanged.
//
// To override per-lane, the testbench top instantiates pad_skid with each
// SKID_BITS_LANE<n> set from a corresponding +define+ plusarg. Mixing the
// two is allowed: any lane that isn't explicitly overridden falls back to
// the uniform `SKID_BITS` default.
//
// Examples
// --------
//   SKID_BITS = 0     → all lanes passthrough
//   SKID_BITS = 3     → all lanes delayed by 3 (legacy uniform mode)
//   SKID_BITS_LANE0 = 3, SKID_BITS_LANE1 = 5, ...  → asymmetric per-lane skew
// =============================================================================
`timescale 1ns/1ps

module pad_skid #(
    // Uniform fallback — used when a per-lane override is not provided.
    parameter int SKID_BITS = 0,
    parameter int LANES     = 8,
    // Per-lane overrides. Default each to the uniform SKID_BITS so legacy
    // call sites (single SKID_BITS) keep their old behaviour.
    parameter int SKID_BITS_LANE0 = SKID_BITS,
    parameter int SKID_BITS_LANE1 = SKID_BITS,
    parameter int SKID_BITS_LANE2 = SKID_BITS,
    parameter int SKID_BITS_LANE3 = SKID_BITS,
    parameter int SKID_BITS_LANE4 = SKID_BITS,
    parameter int SKID_BITS_LANE5 = SKID_BITS,
    parameter int SKID_BITS_LANE6 = SKID_BITS,
    parameter int SKID_BITS_LANE7 = SKID_BITS,
    // Per-lane "stuck-at-zero" mask. Each set bit forces the corresponding
    // lane's output to constant 0, modelling a permanently broken trace
    // or a lane that cannot be calibrated to lock. Used by the partial-
    // failure cocotb test to confirm that a single mis-calibrated lane is
    // correctly reported as un-locked without preventing the §9 sweep from
    // running across all 8 lanes. Default: no lanes stuck.
    parameter [7:0] STUCK_LANES_MASK = 8'h00
) (
    input  wire             pad_clk_in,
    input  wire [LANES-1:0] pad_data_in,
    output wire             pad_clk_out,
    output wire [LANES-1:0] pad_data_out
);

    // Clock is forwarded directly — the bug is data-vs-clock skew, not a
    // clock dropout.
    assign pad_clk_out = pad_clk_in;

    // Pack the per-lane skid depths into a parameter array so the generate
    // loop can index them. Maximum supported skid is 7 (3-bit) for parity
    // with the WavD2DGpio swi_bit_slip field.
    localparam int MAX_SKID = 7;
    localparam int LANE_SKID [0:7] = '{
        SKID_BITS_LANE0, SKID_BITS_LANE1, SKID_BITS_LANE2, SKID_BITS_LANE3,
        SKID_BITS_LANE4, SKID_BITS_LANE5, SKID_BITS_LANE6, SKID_BITS_LANE7
    };

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
            if (STUCK_LANES_MASK[lane]) begin : g_stuck
                // Stuck-at-zero — overrides any skid configuration. Models
                // a broken trace; this lane will never lock to its
                // training pattern at any slip value.
                assign pad_data_out[lane] = 1'b0;
            end else if (LANE_SKID[lane] == 0) begin : g_pt
                assign pad_data_out[lane] = pad_data_in[lane];
            end else begin : g_sr
                // One shift register per lane, depth = that lane's skid.
                reg [LANE_SKID[lane]-1:0] sr;
                initial sr = '0;
                if (LANE_SKID[lane] == 1) begin : g_d1
                    always @(posedge pad_clk_in) sr <= pad_data_in[lane];
                end else begin : g_dn
                    always @(posedge pad_clk_in)
                        sr <= {sr[LANE_SKID[lane]-2:0], pad_data_in[lane]};
                end
                assign pad_data_out[lane] = sr[LANE_SKID[lane]-1];
            end
        end
    endgenerate

endmodule
