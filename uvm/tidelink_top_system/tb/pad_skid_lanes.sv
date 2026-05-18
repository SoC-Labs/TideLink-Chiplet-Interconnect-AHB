// =============================================================================
// pad_skid_lanes.sv — Per-lane parameterised bit-slip skid for the UVM TB
//
// Models the FPGA-side serial-to-parallel boundary misalignment observed on
// the Pynq-Z2 pair (see BRINGUP_REPORT.md §6, §8.1, §8.4, §9), but unlike the
// cocotb `pad_skid.sv` (which has a single SKID_BITS parameter applied
// uniformly to all lanes), this variant accepts a per-lane skew so the
// realistic PCB routing case can be exercised in UVM:
//
//     skid_bits_per_lane[lane] = 3'd0..3'd7   // independent per lane
//
// Default port-level driven value is 0 across the board (set in the testbench
// interface initialiser) → pure passthrough → existing tests continue to pass.
//
// The implementation is structurally identical to the cocotb pad_skid for
// each non-zero lane: a SKID-deep shift register clocked by pad_clk_in.
// Because SKID is now run-time configurable (not an elaboration parameter),
// every lane carries a fixed depth of 7 register stages, and a mux selects
// the active tap. Lanes whose skid is 0 fall through to the pass-through
// path.
//
// This module sits BETWEEN the per-lane perturb mux in the UVM tb top and
// the cross-wire to the peer's RX, so the order is:
//
//   DUT_A.pad_tx --> [a2b_lane_perturb] --> [pad_skid_lanes] --> DUT_B.pad_rx
//
// =============================================================================
`timescale 1ns/1ps

module pad_skid_lanes #(
    parameter int LANES = 8
) (
    input  wire                  pad_clk_in,
    input  wire [LANES-1:0]      pad_data_in,
    // Per-lane 3-bit skid amount (0..7).  Driven by the UVM TB top, ultimately
    // sourced from a virtual interface signal that tests can set before the
    // link comes up.
    input  wire [LANES-1:0][2:0] skid_bits_per_lane,
    output wire                  pad_clk_out,
    output wire [LANES-1:0]      pad_data_out
);

    // Clock is forwarded unchanged — the bug being modelled is data-vs-clock
    // skew, not a clock dropout.
    assign pad_clk_out = pad_clk_in;

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
            // Always carry 7 stages — the deepest skid the lane checker can
            // disambiguate. Mux on skid_bits_per_lane[lane] picks the tap.
            reg [6:0] sr;
            initial sr = 7'h0;

            always @(posedge pad_clk_in) begin
                sr <= {sr[5:0], pad_data_in[lane]};
            end

            // Tap select. skid==0 → passthrough (combinational), skid==N →
            // output of stage N-1 of the shift register (i.e. delay of N
            // pad_clk cycles).
            reg lane_out;
            always @(*) begin
                case (skid_bits_per_lane[lane])
                    3'd0:    lane_out = pad_data_in[lane];
                    3'd1:    lane_out = sr[0];
                    3'd2:    lane_out = sr[1];
                    3'd3:    lane_out = sr[2];
                    3'd4:    lane_out = sr[3];
                    3'd5:    lane_out = sr[4];
                    3'd6:    lane_out = sr[5];
                    3'd7:    lane_out = sr[6];
                    default: lane_out = pad_data_in[lane];
                endcase
            end
            assign pad_data_out[lane] = lane_out;
        end
    endgenerate

endmodule
