// =============================================================================
// tb_top.sv — standalone unit testbench for WavD2DGpioRx T3a comma-hunt
// =============================================================================
//
// Purpose: pin the T3a self-aligning RX (USE_T3A=1) at unit level so a future
// edit that breaks the comma-hunt FSM is caught in seconds (not by a 22-minute
// FPGA build that already burned 12 deploys characterising the lottery).
//
// Instantiates 8 parallel WavD2DGpioRx DUTs (USE_T3A=1, USE_CLKBUF=0), one
// per lane with its lane-specific TRAINING_BYTE. All 8 share the io_pad_clk
// and io_por_reset; each gets its own io_pad input stream driven by cocotb.
// This way ONE simv covers all 8 lane bytes (0xA3, 0xB5, 0xC9, 0xD3, 0x65,
// 0x4B, 0x59, 0x2D) without rebuild.
//
// The cocotb test, for each lane and each of 4 random initial count-skew
// values, applies POR, drives the lane's TRAINING_BYTE in a repeating
// stream on io_pad with the chosen bit offset, and then samples
// io_link_data after the hunt FSM has had time to settle. The assertion
// is that the sampled value is INVARIANT across the 4 skews for a given
// lane — proving T3a aligned `count` to the same byte boundary regardless
// of where the io_por_reset deassertion landed in the bit stream. That is
// the T3a contract: kill the per-deploy 16-cycle word-boundary lottery.
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
    // Shared inputs.
    input  wire        io_pad_clk,
    input  wire        io_por_reset,
    // Per-lane pad inputs (8 lanes, each driven independently by cocotb).
    input  wire [7:0]  io_pad,
    // Per-lane link-clock + 16-bit deserialised data observed by cocotb.
    output wire [7:0]  io_link_clk,
    output wire [127:0] io_link_data
);

    // Same per-lane training bytes as WavD2DGpio.v wires up to gpiotx_<N>.
    // Period-8 aperiodic (unique under cyclic rotation) — see WavD2DGpio.v
    // header comment. Lane 0 = 0xA3 ... lane 7 = 0x2D.
    localparam [7:0] LANE_BYTE_0 = 8'hA3;
    localparam [7:0] LANE_BYTE_1 = 8'hB5;
    localparam [7:0] LANE_BYTE_2 = 8'hC9;
    localparam [7:0] LANE_BYTE_3 = 8'hD3;
    localparam [7:0] LANE_BYTE_4 = 8'h65;
    localparam [7:0] LANE_BYTE_5 = 8'h4B;
    localparam [7:0] LANE_BYTE_6 = 8'h59;
    localparam [7:0] LANE_BYTE_7 = 8'h2D;

    // Tie-offs for the alignment-control inputs we are NOT testing.
    wire        scan_mode             = 1'b0;
    wire        scan_asyncrst_ctrl    = 1'b0;
    wire        scan_clk              = 1'b0;
    wire        io_pol                = 1'b0;
    wire [3:0]  io_phase_offset       = 4'h0;
    wire [2:0]  io_bit_slip           = 3'h0;

    // 8-lane DUT array. Each is a fresh WavD2DGpioRx with USE_T3A=1 and a
    // lane-specific TRAINING_BYTE. They share clock+reset; each has its
    // own io_pad input and link_data output. Using a generate so the lane
    // count is one constant and a regression sweep is just changing the
    // localparams above + adding another DUT line.
    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : g_lane
            wire scan_out_w;
            // Per-lane TRAINING_BYTE override: select via the lane index.
            // Using a localparam constant expression keeps it as a true
            // compile-time parameter override (not a runtime mux).
            localparam [7:0] LB = (lane == 0) ? LANE_BYTE_0 :
                                  (lane == 1) ? LANE_BYTE_1 :
                                  (lane == 2) ? LANE_BYTE_2 :
                                  (lane == 3) ? LANE_BYTE_3 :
                                  (lane == 4) ? LANE_BYTE_4 :
                                  (lane == 5) ? LANE_BYTE_5 :
                                  (lane == 6) ? LANE_BYTE_6 :
                                                LANE_BYTE_7;
            WavD2DGpioRx #(
                .USE_CLKBUF    (1'b0),
                .TRAINING_BYTE (LB),
                .USE_T3A       (1'b1)
            ) u_dut (
                .io_scan_mode          (scan_mode),
                .io_scan_asyncrst_ctrl (scan_asyncrst_ctrl),
                .io_scan_clk           (scan_clk),
                .io_scan_out           (scan_out_w),
                .io_por_reset          (io_por_reset),
                .io_pol                (io_pol),
                .io_phase_offset       (io_phase_offset),
                .io_bit_slip           (io_bit_slip),
                .io_link_clk           (io_link_clk[lane]),
                .io_link_data          (io_link_data[16*lane +: 16]),
                .io_pad_clk            (io_pad_clk),
                .io_pad                (io_pad[lane])
            );
        end
    endgenerate

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
