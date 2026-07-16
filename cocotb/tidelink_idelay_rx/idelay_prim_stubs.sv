// =============================================================================
// idelay_prim_stubs.sv — minimal behavioural IDELAYE2 / IDELAYCTRL sim stubs
// =============================================================================
//
// SoC Labs 2026-06-25 (FULL-RANGE IDELAY TAP gate). VCS cannot elaborate the
// Xilinx unisim IDELAYE2/IDELAYCTRL cells, so the tidelink_idelay_rx PRIMITIVE
// arm (`g_idelay`, USE_IDELAY=1, NO `TIDELINK_IDELAY_NO_PRIMITIVE) is normally
// untestable in sim. These tiny stubs model JUST enough of the two cells for a
// tap-wiring unit test: IDELAYE2 forwards IDATAIN->DATAOUT and EXPOSES the
// loaded CNTVALUEIN (the effective tap) on CNTVALUEOUT, so the testbench can
// confirm lane_tap == {nibble, lsb} == 2*nibble + lsb across the full 0..31
// range (odd taps + upper half reachable).
//
// These stubs are ONLY compiled by the cocotb/tidelink_idelay_rx FULL-RANGE
// target (make MODULE=test_idelay_fullrange); they NEVER reach any FPGA/ASIC
// build (those use the real unisim / passthrough). The port lists match the
// subset tidelink_idelay_rx instantiates.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module IDELAYCTRL (
    output wire RDY,
    input  wire REFCLK,
    input  wire RST
);
    assign RDY = ~RST;   // trivially "ready" out of reset; unused by the DUT
endmodule

module IDELAYE2 #(
    parameter CINVCTRL_SEL          = "FALSE",
    parameter DELAY_SRC             = "IDATAIN",
    parameter HIGH_PERFORMANCE_MODE = "TRUE",
    parameter IDELAY_TYPE           = "VAR_LOAD",
    parameter integer IDELAY_VALUE  = 0,
    parameter PIPE_SEL              = "FALSE",
    parameter integer REFCLK_FREQUENCY = 200,
    parameter SIGNAL_PATTERN        = "DATA"
) (
    output wire [4:0] CNTVALUEOUT,
    output wire       DATAOUT,
    input  wire       C,
    input  wire       CE,
    input  wire       CINVCTRL,
    input  wire [4:0] CNTVALUEIN,
    input  wire       DATAIN,
    input  wire       IDATAIN,
    input  wire       INC,
    input  wire       LD,
    input  wire       LDPIPEEN,
    input  wire       REGRST
);
    // VAR_LOAD: when LD=1 the tap is the CNTVALUEIN value. The DUT holds LD=1,
    // so CNTVALUEOUT continuously mirrors the loaded tap (= lane_tap). That is
    // exactly the value the unit test introspects to prove the full-range tap.
    reg [4:0] tap_q;
    always @(*) if (LD) tap_q = CNTVALUEIN;
    assign CNTVALUEOUT = tap_q;
    // Behavioural delay-line model is irrelevant to the tap-wiring test; pass
    // the data straight through so the datapath still elaborates/connects.
    assign DATAOUT = IDATAIN;
endmodule

`default_nettype wire
