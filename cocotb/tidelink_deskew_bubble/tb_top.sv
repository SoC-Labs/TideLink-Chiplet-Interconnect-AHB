// =============================================================================
// tb_top.sv — UNIT testbench for tidelink_lane_deskew (bubble-bug red->green)
//
// Instantiates tidelink_lane_deskew alone (LANES=8, WIDTH=16, DEPTH_LOG=3).
// The cocotb driver supplies 8 FREQUENCY-LOCKED but PHASE-OFFSET (+ bounded
// zero-mean jitter) lane write clocks plus a free-running out_clk (the framer's
// word clock). Because the downstream framer (WlinkRxLinkLayer) is clocked by
// out_clk and has NO valid/flow-control input, this TB has NO back-pressure
// either: every out_clk edge is a "framer consume". When the deskew read holds
// out_data (all_ready low), a free-running consumer re-samples the same word —
// a DUPLICATE/bubble. This TB exposes the internal all_ready, lane_has_data and
// primed so cocotb can correlate each bubble with an all_ready-low edge and
// confirm the prime-and-continuous fix keeps all_ready high post-prime.
//
// This TB references ONLY ports/internals that exist in BOTH the unfixed and
// fixed RTL (all_ready, lane_has_data, wr_ptr_sync1, rd_ptr) so the SAME TB
// elaborates against either version for the red->green gate. The fixed RTL's
// `primed` flag is NOT aliased here (it is absent in the unfixed RTL); the
// cocotb test infers prime latency from the first real read instead.
// =============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_top #(
    parameter int LANES     = 8,
    parameter int WIDTH     = 16,
    parameter int DEPTH_LOG = 3
) (
    input  wire                       rst_n,
    // Per-lane scalar clocks + per-lane word data, driven INDEPENDENTLY by
    // cocotb (avoids read-modify-write races on a packed bus from 8 tasks).
    input  wire                       lane_clk_0,
    input  wire                       lane_clk_1,
    input  wire                       lane_clk_2,
    input  wire                       lane_clk_3,
    input  wire                       lane_clk_4,
    input  wire                       lane_clk_5,
    input  wire                       lane_clk_6,
    input  wire                       lane_clk_7,
    input  wire [WIDTH-1:0]           lane_data_0,
    input  wire [WIDTH-1:0]           lane_data_1,
    input  wire [WIDTH-1:0]           lane_data_2,
    input  wire [WIDTH-1:0]           lane_data_3,
    input  wire [WIDTH-1:0]           lane_data_4,
    input  wire [WIDTH-1:0]           lane_data_5,
    input  wire [WIDTH-1:0]           lane_data_6,
    input  wire [WIDTH-1:0]           lane_data_7,
    input  wire                       training_mode,
    input  wire                       out_clk,
    output wire [LANES*WIDTH-1:0]     out_data,
    // surfaced internals (the DUT has no out_valid port — that is the bug)
    output wire                       all_ready_o,
    output wire [LANES-1:0]           lane_has_data_o,
    output wire [4*LANES-1:0]         occ_o
);

    wire [LANES-1:0]       lane_clk  = {lane_clk_7, lane_clk_6, lane_clk_5,
                                        lane_clk_4, lane_clk_3, lane_clk_2,
                                        lane_clk_1, lane_clk_0};
    wire [LANES*WIDTH-1:0] lane_data = {lane_data_7, lane_data_6, lane_data_5,
                                        lane_data_4, lane_data_3, lane_data_2,
                                        lane_data_1, lane_data_0};

    tidelink_lane_deskew #(
        .LANES     (LANES),
        .WIDTH     (WIDTH),
        .DEPTH_LOG (DEPTH_LOG)
    ) u_deskew (
        .rst_n         (rst_n),
        .lane_clk      (lane_clk),
        .lane_data     (lane_data),
        .training_mode (training_mode),
        .out_clk       (out_clk),
        .out_data      (out_data)
    );

    // Hierarchical aliases to DUT internals. Read-only; do not alter behaviour.
    assign all_ready_o     = u_deskew.all_ready;
    assign lane_has_data_o = u_deskew.lane_has_data;

    // Per-lane synced occupancy (wr_ptr_sync1 - rd_ptr), for diagnostics.
    genvar oi;
    generate
        for (oi = 0; oi < LANES; oi = oi + 1) begin : g_occ
            assign occ_o[oi*4 +: 4] =
                (u_deskew.wr_ptr_sync1[oi] - u_deskew.rd_ptr);
        end
    endgenerate

endmodule

`default_nettype wire
