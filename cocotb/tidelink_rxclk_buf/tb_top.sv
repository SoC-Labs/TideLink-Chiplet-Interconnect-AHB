// =============================================================================
// tb_top.sv — standalone unit testbench for tidelink_rxclk_buf
// =============================================================================
//
// Purpose: pin the recovered-RX-clock boundary BUFG buffer's passthrough
// behaviour in the two sim-friendly corners:
//
//   (a) USE_CLKBUF=0 (sim/ASIC/UVM default)
//       The g_passthru branch elaborates `assign clk_o = clk_i;`. NO Xilinx
//       primitive referenced — every HDL simulator, UVM, and ASIC flist
//       takes this path.
//
//   (b) USE_CLKBUF=1 + `+define+TIDELINK_RXCLK_NO_PRIMITIVE
//       The g_bufg branch elaborates, but its `ifndef takes the `else
//       belt-and-braces opt-OUT arm: `assign clk_o = clk_i;`. This is the
//       inverted safety net the non-Vivado flow takes when forcing
//       USE_CLKBUF=1 without a unisim library (so VCS doesn't try to
//       resolve BUFG). Bit-exact passthrough on a DIFFERENT generate branch.
//
// USE_CLKBUF=1 WITHOUT the opt-OUT define would elaborate the real Xilinx
// BUFG cell — VCS cannot do that without the unisim library, so that corner
// is INTENTIONALLY not exercised here. The FPGA build flow (Vivado synth +
// the routed netlist) covers it.
//
// Pattern mirrors cocotb/tidelink_idelay_rx/tb_top.sv exactly — that test
// pins the equivalent USE_IDELAY OPT-OUT corner of tidelink_idelay_rx.
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
    input  wire clk_i,
    output wire clk_o_passthru,   // USE_CLKBUF=0 g_passthru branch
    output wire clk_o_optout      // USE_CLKBUF=1 g_bufg/`else opt-OUT branch
);

    // ----- (a) USE_CLKBUF=0 — sim/ASIC default ------------------------------
    // The constant generate-if selects g_passthru. No Xilinx primitive
    // is referenced; clk_o is a pure combinational alias of clk_i.
    tidelink_rxclk_buf #(
        .USE_CLKBUF (1'b0)
    ) u_passthru (
        .clk_i (clk_i),
        .clk_o (clk_o_passthru)
    );

    // ----- (b) USE_CLKBUF=1 + `TIDELINK_RXCLK_NO_PRIMITIVE — opt-OUT --------
    // Forces the g_bufg branch to elaborate, but the Makefile's
    // `+define+TIDELINK_RXCLK_NO_PRIMITIVE selects the `else inside
    // g_bufg, which is also `assign clk_o = clk_i;`. This proves the
    // inverted safety net works without pulling in a unisim BUFG cell.
    // USE_CLKBUF is hard-set to 1'b1 here (not a parameter sweep) —
    // the whole point of this DUT instance is the USE_CLKBUF=1 corner.
    tidelink_rxclk_buf #(
        .USE_CLKBUF (1'b1)
    ) u_optout (
        .clk_i (clk_i),
        .clk_o (clk_o_optout)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
