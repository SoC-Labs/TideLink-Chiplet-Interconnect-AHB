// =============================================================================
// tb_top.sv — standalone unit testbench for tidelink_idelay_rx
// =============================================================================
//
// Purpose: exercise the IDELAY OPT-OUT escape hatch that has ZERO coverage
// elsewhere. The DUT is instantiated with USE_IDELAY = 1'b1 so the constant
// generate-if selects the `g_idelay` branch (NOT `g_passthru`). The Makefile
// compiles with `+define+TIDELINK_IDELAY_NO_PRIMITIVE`, so inside `g_idelay`
// the `ifndef takes the `else arm: a bit-exact `assign pad_rx_o = pad_rx_i;`
// passthrough WITHOUT any Xilinx unisim primitive (which VCS cannot
// elaborate). This proves the inverted safety net works:
//
//   USE_IDELAY=1  +  `TIDELINK_IDELAY_NO_PRIMITIVE  =>  bit-exact passthrough
//
// This is distinct from the USE_IDELAY=0 `g_passthru` case that
// cocotb/phy_align/test_idelay_tap_wiring.py already covers (that test runs
// the full wlink_pair TB which hard-wires USE_IDELAY=0). A future edit that
// re-breaks the gating (e.g. reinstating an opt-IN `ifdef, or breaking the
// opt-OUT `else) is caught here in seconds instead of by a 22-minute build.
//
// USE_IDELAY is hard-set to 1'b1 in the instantiation (not a TB parameter):
// the whole point of THIS testbench is the USE_IDELAY=1 corner, so there is
// nothing to sweep — keeping it literal removes any chance of a Makefile
// override silently flipping it back to the already-covered =0 case.
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

module tb_top #(
    // Lane count is the only knob worth exposing (default matches the GPIO
    // PHY's 8 lanes). USE_IDELAY is deliberately NOT a parameter here — see
    // the header: this TB exists specifically for the USE_IDELAY=1 corner.
    parameter int NUM_LANES = 8
) (
    input  wire                       idelay_ref_clk,
    input  wire                       idelay_rst,
    input  wire [4*NUM_LANES-1:0]     phase_tap_i,
    input  wire [NUM_LANES-1:0]       pad_rx_i,
    output wire [NUM_LANES-1:0]       pad_rx_o
);

    // USE_IDELAY = 1'b1 forces the constant generate-if to elaborate the
    // `g_idelay` branch. With `+define+TIDELINK_IDELAY_NO_PRIMITIVE the
    // `ifndef inside it falls to the `else => `assign pad_rx_o = pad_rx_i;`.
    tidelink_idelay_rx #(
        .USE_IDELAY (1'b1),
        .NUM_LANES  (NUM_LANES)
    ) u_dut (
        .idelay_ref_clk (idelay_ref_clk),
        .idelay_rst     (idelay_rst),
        .phase_tap_i    (phase_tap_i),
        .pad_rx_i       (pad_rx_i),
        .pad_rx_o       (pad_rx_o)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
