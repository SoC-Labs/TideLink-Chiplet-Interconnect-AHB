//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB to AXI-Stream Bridge
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module bridges an AHB slave port to AXI-Stream control and data
// interfaces for the tidelink_sram_manager.
//-----------------------------------------------------------------------------
module tidelink_ahb_stream_bridge #(
    parameter RAM_ADDR_W = 14,
    parameter WORD_LEN_W = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // AHB Slave Port
    input  logic                  hsel,
    input  logic           [31:0] haddr,
    input  logic            [1:0] htrans,
    input  logic            [2:0] hsize,
    input  logic                  hwrite,
    input  logic           [31:0] hwdata,
    input  logic                  hready,
    output logic                  hreadyout,
    output logic           [31:0] hrdata,
    output logic                  hresp,

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
    // Default AHB Responses (stub)
    // ------------------------------------------
    assign hreadyout = 1'b1;
    assign hrdata    = 32'h0;
    assign hresp     = 1'b0; // OKAY

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
