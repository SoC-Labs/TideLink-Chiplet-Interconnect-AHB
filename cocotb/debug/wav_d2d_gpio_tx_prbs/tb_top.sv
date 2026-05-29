// =============================================================================
// tb_top.sv — wraps the LOCAL_OVERRIDE WavD2DGpioTx with USE_PRBS_TRAINING=1
//             for the feat/calibrator-prbs eye-data unit test.
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

    wire        scan_mode          = 1'b0;
    wire        scan_asyncrst_ctrl = 1'b0;
    wire        scan_clk           = 1'b0;
    wire        scan_out_w;

    WavD2DGpioTx #(
        .WORD_ALIGN_MUX   (1'b1),
        .USE_PRBS_TRAINING(1'b1)
    ) u_dut (
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
