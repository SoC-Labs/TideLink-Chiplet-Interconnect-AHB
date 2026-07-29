// Cocotb wrapper for tidelink_axinode_obs standalone testing (item I4).
// A thin pass-through so cocotb can drive every AXI-channel handshake and read
// the packed observability word. WEDGE_LOG2 is shrunk to 4 (16 cycles) so the
// wedge witness is reachable in a short unit test; the shipping default is 12.
`timescale 1ns/1ps
`default_nettype none

module tb_top (
    input  wire        app_clk,
    input  wire        apb_clk,
    input  wire        resetn,

    input  wire        tgt_aw_valid, input wire tgt_aw_ready,
    input  wire        tgt_w_valid,  input wire tgt_w_ready,
    input  wire        tgt_b_valid,  input wire tgt_b_ready, input wire tgt_b_err,
    input  wire        tgt_ar_valid, input wire tgt_ar_ready,
    input  wire        tgt_r_valid,  input wire tgt_r_ready, input wire tgt_r_err,

    input  wire        ini_aw_valid, input wire ini_aw_ready,
    input  wire        ini_w_valid,  input wire ini_w_ready,
    input  wire        ini_b_valid,  input wire ini_b_ready, input wire ini_b_err,
    input  wire        ini_ar_valid, input wire ini_ar_ready,
    input  wire        ini_r_valid,  input wire ini_r_ready, input wire ini_r_err,

    output wire [31:0] obs_axinodes
);

    tidelink_axinode_obs #(.WEDGE_LOG2(4)) u_dut (
        .app_clk      (app_clk),
        .apb_clk      (apb_clk),
        .resetn       (resetn),
        .tgt_aw_valid (tgt_aw_valid), .tgt_aw_ready (tgt_aw_ready),
        .tgt_w_valid  (tgt_w_valid),  .tgt_w_ready  (tgt_w_ready),
        .tgt_b_valid  (tgt_b_valid),  .tgt_b_ready  (tgt_b_ready), .tgt_b_err (tgt_b_err),
        .tgt_ar_valid (tgt_ar_valid), .tgt_ar_ready (tgt_ar_ready),
        .tgt_r_valid  (tgt_r_valid),  .tgt_r_ready  (tgt_r_ready), .tgt_r_err (tgt_r_err),
        .ini_aw_valid (ini_aw_valid), .ini_aw_ready (ini_aw_ready),
        .ini_w_valid  (ini_w_valid),  .ini_w_ready  (ini_w_ready),
        .ini_b_valid  (ini_b_valid),  .ini_b_ready  (ini_b_ready), .ini_b_err (ini_b_err),
        .ini_ar_valid (ini_ar_valid), .ini_ar_ready (ini_ar_ready),
        .ini_r_valid  (ini_r_valid),  .ini_r_ready  (ini_r_ready), .ini_r_err (ini_r_err),
        .obs_axinodes (obs_axinodes)
    );

endmodule

`default_nettype wire
