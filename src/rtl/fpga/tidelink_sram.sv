//-----------------------------------------------------------------------------
// SoCLabs TideLink SRAM Wrapper (FPGA variant)
// - Wraps cmsdk_fpga_sram with a TideLink-owned module name so the SRAM
//   implementation can be substituted for ASIC flows by replacing this
//   single file in the filelist.
//
// For ASIC: replace this file with an equivalent tidelink_sram.sv that
// instantiates the target SRAM macro (e.g. single-port compiled SRAM).
// The interface is identical — only the internal implementation changes.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_sram #(
    parameter AW = 14
)(
    input  wire          CLK,
    input  wire [AW-1:2] ADDR,
    input  wire [31:0]   WDATA,
    input  wire [3:0]    WREN,
    input  wire          CS,
    output wire [31:0]   RDATA
);

    cmsdk_fpga_sram #(
        .AW (AW)
    ) u_sram (
        .CLK   (CLK),
        .ADDR  (ADDR),
        .WDATA (WDATA),
        .WREN  (WREN),
        .CS    (CS),
        .RDATA (RDATA)
    );

endmodule
