//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB-to-Register Interface
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module implements an AHB slave interface that converts AHB transactions
// into a simple register read/write interface. Based on the ARM CMSDK
// cmsdk_ahb_eg_slave_interface pattern, rewritten in SystemVerilog.
//
// Features:
// - Zero wait-state AHB slave (HREADYOUT always high)
// - Supports byte, halfword, and word transfers via byte-lane strobes
// - Address-phase to data-phase pipeline for AHB protocol compliance
// - Parameterized address width for flexible register bank sizing
//-----------------------------------------------------------------------------
module tidelink_ahb_to_reg #(
    parameter ADDR_W = 12  // Register address width (byte-addressed)
)(
    input  logic                hclk,
    input  logic                hresetn,

    // AHB Slave Interface
    input  logic                hsel,
    input  logic                hready,
    input  logic  [1:0]         htrans,
    input  logic  [2:0]         hsize,
    input  logic                hwrite,
    input  logic  [ADDR_W-1:0]  haddr,
    input  logic  [31:0]        hwdata,
    output logic                hreadyout,
    output logic                hresp,
    output logic  [31:0]        hrdata,

    // Register Interface
    output logic  [ADDR_W-1:0]  reg_addr,
    output logic                reg_read_en,
    output logic                reg_write_en,
    output logic  [3:0]         reg_byte_strobe,
    output logic  [31:0]        reg_wdata,
    input  logic  [31:0]        reg_rdata
);

    // ----------------------------------------------------------
    // AHB transfer detection
    // ----------------------------------------------------------
    // A valid AHB access requires hsel, hready, and a non-IDLE/BUSY transfer
    logic ahb_access;
    assign ahb_access = hsel & hready & htrans[1];

    logic ahb_write;
    assign ahb_write = ahb_access & hwrite;

    logic ahb_read;
    assign ahb_read = ahb_access & ~hwrite;

    // ----------------------------------------------------------
    // Address-phase to data-phase pipeline registers
    // ----------------------------------------------------------
    // AHB is a pipelined protocol: address phase signals must be
    // registered and used in the following data phase.
    logic                reg_write_en_r;   // Data-phase write enable
    logic                reg_read_en_r;    // Data-phase read enable
    logic  [ADDR_W-1:0]  reg_addr_r;       // Data-phase address
    logic  [3:0]         reg_byte_strobe_r; // Data-phase byte strobes

    // ----------------------------------------------------------
    // Byte lane decoder
    // ----------------------------------------------------------
    // Decode hsize and haddr[1:0] to generate byte-lane write strobes.
    // This determines which bytes within the 32-bit word are active.
    logic tx_byte, tx_half, tx_word;
    assign tx_byte = ~hsize[1] & ~hsize[0];  // hsize == 3'b000 (8-bit)
    assign tx_half = ~hsize[1] &  hsize[0];  // hsize == 3'b001 (16-bit)
    assign tx_word =  hsize[1];              // hsize == 3'b01x (32-bit)

    // Individual byte select signals
    logic byte_at_00, byte_at_01, byte_at_10, byte_at_11;
    assign byte_at_00 = tx_byte & ~haddr[1] & ~haddr[0];
    assign byte_at_01 = tx_byte & ~haddr[1] &  haddr[0];
    assign byte_at_10 = tx_byte &  haddr[1] & ~haddr[0];
    assign byte_at_11 = tx_byte &  haddr[1] &  haddr[0];

    // Halfword select signals
    logic half_at_00, half_at_10;
    assign half_at_00 = tx_half & ~haddr[1];
    assign half_at_10 = tx_half &  haddr[1];

    // Compose per-byte strobes
    logic [3:0] byte_strobe_nxt;
    assign byte_strobe_nxt[0] = tx_word | half_at_00 | byte_at_00;
    assign byte_strobe_nxt[1] = tx_word | half_at_00 | byte_at_01;
    assign byte_strobe_nxt[2] = tx_word | half_at_10 | byte_at_10;
    assign byte_strobe_nxt[3] = tx_word | half_at_10 | byte_at_11;

    // ----------------------------------------------------------
    // Pipeline registers (address phase -> data phase)
    // ----------------------------------------------------------
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            reg_write_en_r    <= 1'b0;
            reg_read_en_r     <= 1'b0;
            reg_addr_r        <= '0;
            reg_byte_strobe_r <= 4'b0000;
        end else if (hready) begin
            reg_write_en_r    <= ahb_write;
            reg_read_en_r     <= ahb_read;
            reg_addr_r        <= haddr;
            reg_byte_strobe_r <= byte_strobe_nxt & {4{ahb_write}};
        end
    end

    // ----------------------------------------------------------
    // Output assignments
    // ----------------------------------------------------------

    // Register interface outputs (active in data phase)
    assign reg_addr        = reg_addr_r;
    assign reg_read_en     = reg_read_en_r;
    assign reg_write_en    = reg_write_en_r;
    assign reg_byte_strobe = reg_byte_strobe_r;
    assign reg_wdata       = hwdata;

    // AHB read data comes directly from the register bank
    assign hrdata = reg_rdata;

    // Zero wait-state slave: always ready
    assign hreadyout = 1'b1;

    // Always OKAY response (no error support)
    assign hresp = 1'b0;

endmodule
