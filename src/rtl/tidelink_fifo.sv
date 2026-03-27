//-----------------------------------------------------------------------------
// SoCLabs TideLink Token-based FIFO Interface
// - A FIFO interface over AHB for transferring variable-length packets of data
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_fifo #(
    // System Parameters
    parameter SYS_DATA_W = 32,  // System Data Width
    parameter RAM_ADDR_W = 14,  // Size of SRAM
    parameter RAM_DATA_W = 32   // Data Width of RAM
)(
    // --------------------------------------------------------------------------
    // Port Definitions
    // --------------------------------------------------------------------------
    input  logic                  hclk,      // system bus clock
    input  logic                  hresetn,   // system bus reset
    input  logic                  hsel,      // AHB peripheral select
    input  logic                  hready,    // AHB ready input
    input  logic            [1:0] htrans,    // AHB transfer type
    input  logic            [2:0] hsize,     // AHB hsize
    input  logic                  hwrite,    // AHB hwrite
    input  logic [RAM_ADDR_W-1:0] haddr,     // AHB address bus
    input  logic [SYS_DATA_W-1:0] hwdata,    // AHB write data bus
    output logic                  hreadyout, // AHB ready output to S->M mux
    output logic                  hresp,     // AHB response
    output logic [SYS_DATA_W-1:0] hrdata,    // AHB read data bus

    // Completion pulse: fires when a read packet finishes (drives returner)
    output logic                  read_complete,

    output logic [RAM_ADDR_W-2:0] current_token_count,

    // Sideband outputs for returner
    output logic [RAM_ADDR_W-1:0] packet_word_length_out
);

    // --------------------------------------------------------------------------
    // Internal Wiring
    // --------------------------------------------------------------------------
    logic [RAM_ADDR_W-3:0] addr;
    logic [RAM_DATA_W-1:0] wdata;
    logic [RAM_DATA_W-1:0] rdata;
    logic            [3:0] wen;
    logic                  cs;
    logic [RAM_ADDR_W-3:0] translated_addr;
    logic [RAM_ADDR_W-1:0] translated_haddr;

    // Testbench-visible signal aliases (preserve cocotb probe paths)
    logic [RAM_ADDR_W-1:0] write_ptr;
    logic [RAM_ADDR_W-1:0] read_ptr;
    logic [RAM_ADDR_W-1:0] write_target_addr;
    logic [RAM_ADDR_W-1:0] read_target_addr;
    logic [RAM_ADDR_W-1:0] packet_word_length;
    logic [RAM_ADDR_W-2:0] token_count;

    // --------------------------------------------------------------------------
    // FIFO Control Logic
    // --------------------------------------------------------------------------
    tidelink_fifo_ctrl #(
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .RAM_DATA_W (RAM_DATA_W)
    ) u_fifo_ctrl (
        .hclk                (hclk),
        .hresetn             (hresetn),
        .hsel                (hsel),
        .htrans              (htrans),
        .hready              (hready),
        .hwrite              (hwrite),
        .haddr               (haddr),
        .hwdata              (hwdata),
        .rdata               (rdata),
        .addr                (addr),
        .translated_addr     (translated_addr),
        .translated_haddr    (translated_haddr),
        .read_complete       (read_complete),
        .current_token_count (current_token_count),
        .write_ptr           (write_ptr),
        .read_ptr            (read_ptr),
        .write_target_addr   (write_target_addr),
        .read_target_addr    (read_target_addr),
        .packet_word_length  (packet_word_length),
        .token_count         (token_count)
    );

    // --------------------------------------------------------------------------
    // AHB to SRAM Conversion
    // --------------------------------------------------------------------------
    cmsdk_ahb_to_sram #(
        .AW (RAM_ADDR_W)
    ) u_ahb_to_sram (
        // AHB Inputs
        .HCLK       (hclk),
        .HRESETn    (hresetn),
        .HSEL       (hsel),
        .HADDR      (translated_haddr),
        .HTRANS     (htrans),
        .HSIZE      (hsize),
        .HWRITE     (hwrite),
        .HWDATA     (hwdata),
        .HREADY     (hready),

        // AHB Outputs
        .HREADYOUT  (hreadyout),
        .HRDATA     (hrdata),
        .HRESP      (hresp),

        // SRAM input
        .SRAMRDATA  (rdata),

        // SRAM Outputs
        .SRAMADDR   (addr),
        .SRAMWDATA  (wdata),
        .SRAMWEN    (wen),
        .SRAMCS     (cs)
   );

    // --------------------------------------------------------------------------
    // FPGA SRAM Model
    // --------------------------------------------------------------------------
    cmsdk_fpga_sram #(
        .AW (RAM_ADDR_W)
    ) u_sram (
        // SRAM Inputs
        .CLK        (hclk),
        .ADDR       (translated_addr),
        .WDATA      (wdata),
        .WREN       (wen),
        .CS         (cs),

        // SRAM Output
        .RDATA      (rdata)
    );

    // Sideband: expose packet_word_length for returner
    assign packet_word_length_out = packet_word_length;

endmodule
