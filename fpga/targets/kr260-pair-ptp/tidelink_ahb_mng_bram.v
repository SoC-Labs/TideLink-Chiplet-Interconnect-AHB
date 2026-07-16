// tidelink_ahb_mng_bram.v  (SoC Labs 2026-07-03)
// ---------------------------------------------------------------------------
// AHB-Lite BRAM slave that terminates TideLink's `ahb_mng` manager port -- the
// far-side terminus of the XHB500 transparent window. A peer die's remote-
// initiated access (write or read into aperture 0x4000_0000) transits the FC
// link, exits the local `ahb_mng`, and lands here so a write can be stored and
// a read can return data. Without this the window's return path floats.
//
// Single AHB-Lite slave (HSEL tied 1, HREADYOUT looped back to HREADY exactly
// like the proven `ahb_tx`/`ahb_sub` SRAM terminations). Reuses the silicon-
// proven cmsdk_ahb_to_sram + cmsdk_fpga_sram cells (byte-accurate via HSIZE->
// SRAMWEN). hclk domain (4.6875 MHz, +176 ns slack) -- zero timing risk.
// AW=12 => 4 KB => 1 RAMB36 (136 free on the xc7z020).
//
// HBURST/HPROT are carried by ahb_mng but unused by the SRAM bridge (single,
// word/byte accesses only) -- intentionally left unconnected.
`timescale 1ns/1ps
module tidelink_ahb_mng_bram #(
    parameter AW = 12
) (
    input  wire        HCLK,
    input  wire        HRESETn,
    input  wire [31:0] HADDR,
    input  wire [2:0]  HBURST,   // unused
    input  wire [6:0]  HPROT,    // unused
    input  wire [2:0]  HSIZE,
    input  wire [1:0]  HTRANS,
    input  wire [31:0] HWDATA,
    input  wire        HWRITE,
    output wire        HREADY,
    output wire [31:0] HRDATA,
    output wire        HRESP
);
    wire [31:0]   sram_rdata, sram_wdata;
    wire [AW-3:0] sram_addr;
    wire [3:0]    sram_wen;
    wire          sram_cs;
    wire          hreadyout;

    cmsdk_ahb_to_sram #(.AW(AW)) u_bridge (
        .HCLK      (HCLK),
        .HRESETn   (HRESETn),
        .HSEL      (1'b1),
        .HREADY    (hreadyout),      // single slave: HREADYOUT loops to HREADY
        .HTRANS    (HTRANS),
        .HSIZE     (HSIZE),
        .HWRITE    (HWRITE),
        .HADDR     (HADDR[AW-1:0]),
        .HWDATA    (HWDATA),
        .HREADYOUT (hreadyout),
        .HRESP     (HRESP),
        .HRDATA    (HRDATA),
        .SRAMRDATA (sram_rdata),
        .SRAMADDR  (sram_addr),
        .SRAMWEN   (sram_wen),
        .SRAMWDATA (sram_wdata),
        .SRAMCS    (sram_cs)
    );

    assign HREADY = hreadyout;

    cmsdk_fpga_sram #(.AW(AW)) u_sram (
        .CLK   (HCLK),
        .ADDR  (sram_addr),
        .WDATA (sram_wdata),
        .WREN  (sram_wen),
        .CS    (sram_cs),
        .RDATA (sram_rdata)
    );
endmodule
