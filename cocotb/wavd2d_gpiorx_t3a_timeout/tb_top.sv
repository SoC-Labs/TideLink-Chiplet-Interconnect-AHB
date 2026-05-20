// =============================================================================
// tb_top.sv — standalone unit testbench for WavD2DGpioRx T3a MAX_HUNT timeout
// =============================================================================
//
// Purpose: pin the MAX_HUNT timeout fallback path of the T3a comma-hunt FSM
// (USE_T3A=1). If the peer is silent (io_pad held at a constant non-training
// value), the FSM must reach S_LOCKED via the MAX_HUNT timeout instead of
// hanging in S_HUNT or asserting a spurious slip. This is the
// staggered-bring-up graceful-degradation property: the peer is in POR for
// milliseconds while master comes up; the master's RX must not livelock.
//
// We instantiate a SINGLE WavD2DGpioRx (USE_T3A=1, USE_CLKBUF=0) — NOT the
// 8-lane array the realign test uses — so the cocotb hierarchical handle
// to u_dut.g_t3a_realign.align_state is a flat path. The 8-lane array
// (cocotb/wavd2d_gpiorx_t3a/tb_top.sv) wraps each lane in
// `generate for (...) begin : g_lane`, which cocotb 2.0 + VCS exposes as a
// HierarchyArrayObject whose `g_lane[N]` index resolution is flaky on this
// VCS build (cocotb's `_discover_all` chokes on the flattened
// `g_lane[N].u_dut` child names). The single-lane TB sidesteps that.
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

    // Tie-offs (same convention as the 8-lane TB).
    wire        scan_mode             = 1'b0;
    wire        scan_asyncrst_ctrl    = 1'b0;
    wire        scan_clk              = 1'b0;
    wire        io_pol                = 1'b0;
    wire [3:0]  io_phase_offset       = 4'h0;
    wire [2:0]  io_bit_slip           = 3'h0;

    wire        scan_out_w;

    // USE_T3A=1 + USE_CLKBUF=0. TRAINING_BYTE = 0xA3 (lane 0 of WavD2DGpio).
    // The silent-peer test will drive io_pad = 0 steadily; 0x00 is NOT a
    // rotation of 0xA3 (popcount mismatch), so match_any is always 0 and
    // the FSM must exit via MAX_HUNT timeout, not via the match arm.
    WavD2DGpioRx #(
        .USE_CLKBUF    (1'b0),
        .TRAINING_BYTE (8'hA3),
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
