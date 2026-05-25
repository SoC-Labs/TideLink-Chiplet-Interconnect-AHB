// =============================================================================
// tb_top.sv — standalone unit testbench for WavD2DGpioTx training-mode mux
// =============================================================================
//
// Purpose: characterise the PHY-level mux at WavD2DGpioTx.v:43-45:
//
//     wire [15:0] _link_data_eff = io_training_mode
//                                ? {io_training_pattern, io_training_pattern}
//                                : io_link_data;
//
// This combinatorial mux replaces io_link_data with the repeated training byte
// when io_training_mode=1. The serialiser (one bit per io_clk via the `count`
// register, bits 0..15) emits _link_data_eff one bit at a time on io_pad.
//
// Diagnostic objectives (see test_wav_tx_training_mux.py):
//   * confirm the mux behaviour in isolation (training vs FC data)
//   * characterise the 1→0 transition cycle-by-cycle
//   * characterise the gap behaviour when no FC data is queued
//   * confirm there is NO TX-enable gating at the WAV TX level — the module
//     has NO io_link_tx_tx_en port; the serialiser is always live.
//
// We expose io_pad + the parallel _link_data_eff parents on the dut so the
// cocotb test can sample both the serial pad and the parallel word.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top (
    input  wire        io_clk,
    input  wire        io_reset,
    input  wire        io_clk_en,
    input  wire        io_training_mode,
    input  wire [7:0]  io_training_pattern,
    input  wire [15:0] io_link_data,
    output wire        io_pad,
    output wire        io_pad_clk,
    output wire        io_link_clk
);

    // Tie-offs for the scan path (we are not testing scan here).
    wire        scan_mode          = 1'b0;
    wire        scan_asyncrst_ctrl = 1'b0;
    wire        scan_clk           = 1'b0;
    wire        scan_out_w;

    WavD2DGpioTx u_dut (
        .io_scan_mode          (scan_mode),
        .io_scan_asyncrst_ctrl (scan_asyncrst_ctrl),
        .io_scan_clk           (scan_clk),
        .io_scan_out           (scan_out_w),
        .io_clk                (io_clk),
        .io_reset              (io_reset),
        .io_clk_en             (io_clk_en),
        .io_link_data          (io_link_data),
        .io_training_mode      (io_training_mode),
        .io_training_pattern   (io_training_pattern),
        .io_link_clk           (io_link_clk),
        .io_pad                (io_pad),
        .io_pad_clk            (io_pad_clk)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
