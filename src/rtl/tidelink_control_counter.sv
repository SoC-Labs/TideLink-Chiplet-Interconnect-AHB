//-----------------------------------------------------------------------------
// SoCLabs TideLink Control Counter
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module accepts commands via a register interface and drives AXI-Stream
// control and data outputs to the tidelink_sram_manager.
//-----------------------------------------------------------------------------
module tidelink_control_counter #(
    parameter RAM_ADDR_W = 14,
    parameter WORD_LEN_W = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // Register Interface (from ahb_to_reg)
    input  logic           [11:0] reg_addr,
    input  logic                  reg_write,
    input  logic                  reg_read,
    input  logic           [31:0] reg_wdata,
    output logic           [31:0] reg_rdata,

    // AXI-Stream Control Out (to sram_manager ctrl port)
    output logic           [22:0] ctrl_tdata,
    output logic                  ctrl_tvalid,
    input  logic                  ctrl_tready,

    // AXI-Stream Data Out (to sram_manager din port)
    output logic           [31:0] dout_tdata,
    output logic                  dout_tvalid,
    output logic                  dout_tlast,
    input  logic                  dout_tready,

    // AXI-Stream Data In (from sram_manager dout port)
    input  logic           [31:0] din_tdata,
    input  logic                  din_tvalid,
    input  logic                  din_tlast,
    output logic                  din_tready
);

    // ------------------------------------------
    // Default Register Outputs (stub)
    // ------------------------------------------
    assign reg_rdata = 32'h0;

    // ------------------------------------------
    // Default AXI-Stream Outputs (stub)
    // ------------------------------------------
    assign ctrl_tdata  = 23'h0;
    assign ctrl_tvalid = 1'b0;

    assign dout_tdata  = 32'h0;
    assign dout_tvalid = 1'b0;
    assign dout_tlast  = 1'b0;

    assign din_tready  = 1'b0;

endmodule
