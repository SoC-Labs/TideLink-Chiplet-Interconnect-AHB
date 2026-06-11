//-----------------------------------------------------------------------------
// SoCLabs TideLink SRAM Wrapper (ASIC variant)
// - Instantiates the rf_16k compiled register file macro (TSMC 65nm).
// - Maps the tidelink_sram interface to the rf_16k port convention:
//     * Active-low CEN  (chip enable)  ← inverted from active-high CS
//     * Active-low WEN  (per-bit)      ← expanded & inverted from WREN byte enables
//     * Active-low GWEN (global write) ← low when any write is active
//     * EMA/EMAW/RET1N  tied to default (normal operation, no retention)
//
// For ASIC: swap this file into the filelist via flists/tidelink_asic.flist.
// The interface is identical to the FPGA and generic variants — only the
// internal implementation changes.
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

    // ── Interface adaptation ─────────────────────────────────────────────

    // Chip enable: rf_16k CEN is active-low
    wire cen = ~CS;

    // Global write enable: active-low, asserted when any byte lane writes
    wire gwen = ~(|WREN);

    // Per-bit write enables: expand 4-bit byte enables to 32-bit, then invert
    // (rf_16k WEN is active-low, per-bit granularity)
    wire [31:0] wen = ~{{8{WREN[3]}}, {8{WREN[2]}}, {8{WREN[1]}}, {8{WREN[0]}}};

    // ── rf_16k macro instantiation ───────────────────────────────────────

    rf_16k u_rf (
        .CLK   (CLK),
        .CEN   (cen),
        .A     (ADDR[AW-1:2]),   // 12-bit word address
        .D     (WDATA),
        .GWEN  (gwen),
        .WEN   (wen),
        .Q     (RDATA),
        .EMA   (3'b000),         // Default extra margin
        .EMAW  (2'b00),          // Default extra margin (write)
        .RET1N (1'b1)            // Normal operation (not retention)
    );

endmodule
