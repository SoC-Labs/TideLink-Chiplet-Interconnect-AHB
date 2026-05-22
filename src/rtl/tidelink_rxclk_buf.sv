// =============================================================================
// tidelink_rxclk_buf.sv — Recovered-RX-clock global clock buffer (FPGA only).
//
// WHY (netlist-proven, 2026-05-19):
//   The forwarded RX clock `pad_clk_rx` enters the Wlink GPIO PHY and is then
//   distributed to all 8 lanes' deserialiser capture flops THROUGH the PHY's
//   WavClockMux scan/pol mux logic, which Vivado synthesises into fabric LUT2
//   cells. The routed netlist showed `IBUF -> BUFG -> fabric-LUT -> BUFG` and,
//   for 7 of the 8 lanes, a LUT driving the clock pin of 16 capture registers
//   on GENERAL routing (Vivado `Place 30-568`, hold-risk). A HW role/bitstream
//   SWAP test ruled out physical causes and proved the dead RX direction
//   follows the bitstream: the recovered clock simply never reaches a clean
//   dedicated clock network. Putting `pad_clk_rx` onto an explicit global
//   clock BUFG at the IP boundary (before it fans into the PHY) is the first
//   structural step to give the recovered clock a deterministic dedicated
//   route on every build, independent of the inferred-buffer placement
//   lottery that landed the Y7-MRCC direction outside the calibrator window.
//
// PATTERN: this is a faithful mirror of tidelink_idelay_rx.sv —
//   ADDITIVE & PARAMETER-GATED. USE_CLKBUF is the SINGLE source of truth.
//   * USE_CLKBUF=0 (sim/ASIC/UVM default) → pure passthrough
//                   `assign clk_o = clk_i`. NO Xilinx primitive referenced,
//                   bit-exact to the pre-fix RTL; the generate-if prunes the
//                   BUFG branch so the unisim text is never elaborated. ⇒
//                   ZERO flist / testbench / ASIC changes required.
//   * USE_CLKBUF=1 (FPGA only) → one Xilinx BUFG on the recovered clock.
//                   The FPGA IP wrapper (tidelink_vivado_wrapper) defaults
//                   this to 1; it is carried via the packaged IP's
//                   component.xml and so REACHES OOC synth with no
//                   preprocessor cooperation (this is exactly the mechanism
//                   that fixed the USE_IDELAY dead-code trap — do NOT
//                   reintroduce a packaging-project `verilog_define`).
//
//   Belt-and-braces opt-out: a non-Vivado flow that forces USE_CLKBUF=1
//   without a unisim library can define TIDELINK_RXCLK_NO_PRIMITIVE to fall
//   back to passthrough. Default (undefined) = real BUFG whenever
//   USE_CLKBUF=1 — safe by default.
//
// SCOPE NOTE: this buffers the clock at the IP boundary. If HW shows it is
//   necessary-but-insufficient (the per-lane WavClockMux LUT + the
//   ~adj_count[3] divided word-clock are INSIDE WavD2DGpioRx), the
//   documented escalation is the in-PHY clean-clock restructure — done with
//   HW evidence, not pre-emptively. See pynq_host/BRINGUP_NEXT_STEPS.md.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tidelink_rxclk_buf #(
    // 0 = passthrough (bit-exact, no Xilinx primitive — sim/ASIC default).
    // 1 = Xilinx BUFG on the recovered RX clock (7-series FPGA only). The
    //     FPGA IP wrapper sets this to 1; carried via component.xml.
    parameter bit USE_CLKBUF = 1'b0
) (
    // Raw forwarded RX clock straight from the top-level FPGA input pad
    // (post-IBUF on the BD side).
    input  wire clk_i,
    // Recovered RX clock feeding the Wlink GPIO PHY. On FPGA this is a
    // BUFG-driven global clock net; in sim/ASIC it is clk_i unchanged.
    output wire clk_o
);

    generate
        if (USE_CLKBUF) begin : g_bufg
`ifndef TIDELINK_RXCLK_NO_PRIMITIVE
            // One global clock buffer for the recovered RX clock. Forces the
            // dedicated clock network from the boundary on EVERY build,
            // removing the inferred-buffer/region placement lottery.
            BUFG u_rxclk_bufg (
                .I (clk_i),
                .O (clk_o)
            );
`else
            // OPT-OUT escape hatch: reached only if a non-Vivado flow both
            // forces USE_CLKBUF=1 AND defines TIDELINK_RXCLK_NO_PRIMITIVE
            // (no unisim library). Falls back to passthrough so elaboration
            // never fails on a missing BUFG cell. Default builds never
            // define this macro — the FPGA path needs zero preprocessor
            // cooperation; the USE_CLKBUF parameter alone selects BUFG.
            assign clk_o = clk_i;
`endif
        end else begin : g_passthru
            // -------------------------------------------------------------
            // Bit-exact passthrough. No Xilinx primitive. This is the path
            // every HDL simulator, UVM, and the ASIC flist take.
            // -------------------------------------------------------------
            assign clk_o = clk_i;
        end
    endgenerate

endmodule

`default_nettype wire
