// =============================================================================
// tb_fullrange.sv — unit TB for the FULL-RANGE IDELAY tap (odd + upper half)
// =============================================================================
//
// SoC Labs 2026-06-25. Instantiates tidelink_idelay_rx with USE_IDELAY=1 and
// the PRIMITIVE arm SELECTED (NO `TIDELINK_IDELAY_NO_PRIMITIVE), against the
// behavioural idelay_prim_stubs.sv IDELAYE2/IDELAYCTRL. The stub IDELAYE2
// mirrors the loaded CNTVALUEIN onto CNTVALUEOUT, so per-lane lane_tap is
// observable via the DUT's g_idelay.g_lane[N].u_idelaye2.CNTVALUEOUT
// hierarchical path. The test drives phase_tap_i (coarse nibble) + lsb_i and
// asserts lane_tap == 2*nibble + lsb across the full 0..31 range, and that
// lsb=0 reproduces the historical even-only {nibble,1'b0} mapping.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license. Contributors: David Mapstone (d.a.mapstone@soton.ac.uk).
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top #(
    parameter int NUM_LANES = 8
) (
    input  wire                       idelay_ref_clk,
    input  wire                       idelay_rst,
    input  wire [4*NUM_LANES-1:0]     phase_tap_i,
    input  wire [NUM_LANES-1:0]       lsb_i,
    input  wire [NUM_LANES-1:0]       pad_rx_i,
    output wire [NUM_LANES-1:0]       pad_rx_o
);

    // USE_IDELAY=1 selects g_idelay; with NO `TIDELINK_IDELAY_NO_PRIMITIVE the
    // `ifndef arm instantiates the (stubbed) IDELAYE2/IDELAYCTRL so lane_tap is
    // observable on CNTVALUEOUT.
    tidelink_idelay_rx #(
        .USE_IDELAY (1'b1),
        .NUM_LANES  (NUM_LANES)
    ) u_dut (
        .idelay_ref_clk (idelay_ref_clk),
        .idelay_rst     (idelay_rst),
        .phase_tap_i    (phase_tap_i),
        .lsb_i          (lsb_i),
        .pad_rx_i       (pad_rx_i),
        .pad_rx_o       (pad_rx_o)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
