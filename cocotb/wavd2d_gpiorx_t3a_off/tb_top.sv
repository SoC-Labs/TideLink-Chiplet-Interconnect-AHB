// =============================================================================
// tb_top.sv — standalone unit testbench for WavD2DGpioRx USE_T3A=0 path
// =============================================================================
//
// Purpose: pin the USE_T3A=0 (sim/ASIC/UVM default) bit-exact behaviour of
// the WavD2DGpioRx T3a comma-hunt restructure. With USE_T3A=0:
//   * The g_t3a_passthru arm of the generate is selected.
//   * `count` resets to 4'hf and free-runs (+1 every w_cnt_clk cycle).
//   * NO realign_shifter, NO align_state FSM, NO hunt counter, NO slip
//     arithmetic — those flops/luts are pruned by the constant
//     generate-if.
//
// We instantiate ONE WavD2DGpioRx with USE_T3A=0 + USE_CLKBUF=0 (the strict
// legacy combination — also covered by cocotb/wavd2d_gpiorx_clkbuf/ on the
// data-path side; here we focus on the count free-run side).
//
// The test:
//   1. Confirms the generate-if picked g_t3a_passthru (via parameter value
//      and absence of g_t3a_realign-scoped child names).
//   2. Observes the count register through many POR cycles and confirms it
//      always resets to 4'hf and increments monotonically every w_cnt_clk
//      cycle (mod 16). This is the exact pre-restructure behaviour.
//
// Pattern mirrors cocotb/wavd2d_gpiorx_t3a/tb_top.sv (the USE_T3A=1
// companion). The difference is USE_T3A=0 → legacy free-running count.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_top (
    input  wire        io_pad_clk,
    input  wire        io_por_reset,
    input  wire        io_pad,
    output wire        io_link_clk,
    output wire [15:0] io_link_data
);

    // Tie-offs.
    wire        scan_mode             = 1'b0;
    wire        scan_asyncrst_ctrl    = 1'b0;
    wire        scan_clk              = 1'b0;
    wire        io_pol                = 1'b0;
    wire [3:0]  io_phase_offset       = 4'h0;
    wire [2:0]  io_bit_slip           = 3'h0;

    wire        scan_out_w;

    // USE_T3A=0 + USE_CLKBUF=0: the strict-legacy combination — `count`
    // free-runs from 4'hf, no realign FSM. TRAINING_BYTE is irrelevant
    // on this path (the constant generate-if prunes its only user) but
    // is set to a representative lane byte for clarity.
    WavD2DGpioRx #(
        .USE_CLKBUF    (1'b0),
        .TRAINING_BYTE (8'hA3),
        .USE_T3A       (1'b0)
    ) u_dut (
        .io_scan_mode          (scan_mode),
        .io_scan_asyncrst_ctrl (scan_asyncrst_ctrl),
        .io_scan_clk           (scan_clk),
        .io_scan_out           (scan_out_w),
        .io_por_reset          (io_por_reset),
        .io_pol                (io_pol),
        .io_phase_offset       (io_phase_offset),
        .io_bit_slip           (io_bit_slip),
        .io_link_clk           (io_link_clk),
        .io_link_data          (io_link_data),
        .io_pad_clk            (io_pad_clk),
        .io_pad                (io_pad)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
