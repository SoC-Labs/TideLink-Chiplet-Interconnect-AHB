//-----------------------------------------------------------------------------
// SoCLabs TideLink Clock-Frequency Cross-Check — cocotb testbench top
//
// Small WINDOW_BITS + tight TOL keep the simulation fast while still
// exercising the Gray-coded CDC path and the window comparator.
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_top #(
    parameter int WINDOW_BITS = 8,    // 256-cycle window for fast sim
    parameter int CNT_W       = 16,
    parameter int SYNC_STAGES = 2,
    parameter int TOL_COUNTS  = 8
)(
    input  wire                 local_clk,
    input  wire                 local_rst_n,
    input  wire                 link_clk,
    input  wire                 link_rst_n,
    input  wire                 link_up,

    output logic                freq_match,
    output logic                freq_mismatch_sticky,
    output logic                measured_once,
    output logic [CNT_W-1:0]    local_window_count,
    output logic [CNT_W-1:0]    link_window_count,
    output logic                measurement_valid
);

    tidelink_clkfreq_check #(
        .WINDOW_BITS (WINDOW_BITS),
        .CNT_W       (CNT_W),
        .SYNC_STAGES (SYNC_STAGES),
        .TOL_COUNTS  (TOL_COUNTS)
    ) u_dut (
        .local_clk            (local_clk),
        .local_rst_n          (local_rst_n),
        .link_clk             (link_clk),
        .link_rst_n           (link_rst_n),
        .link_up              (link_up),
        .freq_match           (freq_match),
        .freq_mismatch_sticky (freq_mismatch_sticky),
        .measured_once        (measured_once),
        .local_window_count   (local_window_count),
        .link_window_count    (link_window_count),
        .measurement_valid    (measurement_valid)
    );

endmodule
