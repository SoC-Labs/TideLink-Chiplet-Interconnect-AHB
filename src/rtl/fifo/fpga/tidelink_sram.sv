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

    // -------------------------------------------------------------------------
    // SILICON-FAITHFUL POWER-UP STATE (simulation only) — added 2026-07-14.
    //
    // Xilinx BRAM powers up ALL-ZERO on the FPGA. The vendor sim model
    // (cmsdk_fpga_sram) leaves its BRAM0..3 byte arrays at X until written, so
    // simulation did NOT model the real power-up state. That gap made sim BLIND
    // to a genuine silicon defect: reading offset 0 of an EMPTY RX FIFO latches
    // a packet length from SRAM[0]; on hardware that reads 0 (=> a phantom
    // zero-length packet is popped, walking read_ptr by 2 words and minting
    // credit above MAX), whereas in sim it read X and the length latch never
    // resolved to 0. See the fix in tidelink_fifo_ctrl.sv (rx_fifo_empty).
    //
    // Zeroing the arrays here makes sim match the FPGA so this defect class is
    // reproducible and gate-able. translate_off: never synthesised (real BRAM
    // needs no init, and forcing one would infer an init file).
    // -------------------------------------------------------------------------
    // synthesis translate_off
    `ifndef TIDELINK_SRAM_NO_ZERO_INIT
    localparam int SRAM_AWT = (1 << (AW - 2)) - 1;
    initial begin
        for (int i = 0; i <= SRAM_AWT; i++) begin
            u_sram.BRAM0[i] = 8'h00;
            u_sram.BRAM1[i] = 8'h00;
            u_sram.BRAM2[i] = 8'h00;
            u_sram.BRAM3[i] = 8'h00;
        end
    end
    `endif
    // synthesis translate_on

endmodule
