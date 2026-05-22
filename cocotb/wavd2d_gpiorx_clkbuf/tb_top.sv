// =============================================================================
// tb_top.sv — standalone unit testbench for WavD2DGpioRx USE_CLKBUF=0 path
// =============================================================================
//
// Purpose: pin functional equivalence of the WavD2DGpioRx in-PHY BUFG
// restructure (§9 clock fix, 2026-05-19) WHEN USE_CLKBUF=0. With the new
// USE_CLKBUF parameter, the per-lane clock distribution is gated by a
// generate block that EITHER:
//   * USE_CLKBUF=0 → aliases w_cnt_clk, w_pad_clk, w_lnk_clk to the original
//                    WavClockMux outputs (bit-exact to pre-restructure RTL); OR
//   * USE_CLKBUF=1 → BUFGs the recovered clocks (kills 7× Place 30-568).
//
// This TB exercises ONLY the USE_CLKBUF=0 corner — the path every HDL
// simulator, UVM, and the ASIC flist take. The contract under test is:
//   "the restructure did NOT regress the legacy capture chain". A future
// edit that breaks the USE_CLKBUF=0 alias arm of the generate (e.g. an
// inverted `w_pad_clk` assignment) would corrupt deserialisation in sim
// silently — this fast unit test catches it in seconds.
//
// We instantiate ONE WavD2DGpioRx with USE_CLKBUF=0 + USE_T3A=0 (the
// strict-legacy combination — no comma-hunt, no BUFG). The cocotb test
// drives a known training byte (period-8 aperiodic, like the per-lane
// constants WavD2DGpio.v uses) on io_pad and asserts io_link_data is
// well-formed two-equal-byte (hi==lo) — i.e. the deserialiser pipeline
// produced a periodic byte word after enough warm-up, exactly as the
// pre-restructure RTL would have.
//
// Pattern mirrors cocotb/wavd2d_gpiorx_t3a/tb_top.sv. The difference is
// USE_T3A=1 there → exercises the comma-hunt FSM; here USE_T3A=0 →
// exercises the bit-exact legacy free-running `count` arm.
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

    // Tie-offs for the alignment-control inputs we are NOT testing. Scan
    // path and pol mux all static-0 (these are the static-0 conditions the
    // §9 USE_CLKBUF=1 path's BUFG bypass relies on; for USE_CLKBUF=0 they
    // are the natural sim/UVM defaults).
    wire        scan_mode             = 1'b0;
    wire        scan_asyncrst_ctrl    = 1'b0;
    wire        scan_clk              = 1'b0;
    wire        io_pol                = 1'b0;
    wire [3:0]  io_phase_offset       = 4'h0;
    wire [2:0]  io_bit_slip           = 3'h0;

    wire        scan_out_w;

    // USE_CLKBUF=0 + USE_T3A=0: the strict-legacy combination. Any future
    // RTL edit that breaks bit-exact behaviour on this path is what this
    // TB is designed to catch.
    WavD2DGpioRx #(
        .USE_CLKBUF    (1'b0),
        .TRAINING_BYTE (8'hA3),    // unused with USE_T3A=0; set for clarity
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
