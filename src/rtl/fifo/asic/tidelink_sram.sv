//-----------------------------------------------------------------------------
// SoCLabs TideLink SRAM Wrapper (ASIC variant)
// - Instantiates the rf_16k compiled register file macro (TSMC 65nm).
// - Maps the tidelink_sram interface to the rf_16k port convention:
//     * Active-low CEN  (chip enable)  ← inverted from active-high CS
//     * Active-low WEN  (per-bit)      ← expanded & inverted from WREN byte enables
//     * Active-low GWEN (global write) ← low when any write is active
//     * EMA = 3'b010, EMAW = 2'b00: the macro defaults (rf_08k.v/rf_16k.v warn
//       "Default value 2" / "Default value 0"). EMA was tied 3'b000 (minimum
//       read margin) under a "default" comment until 2026-10-03; the other
//       compute macros all use 3'b010.
//     * RET1N = 1 (normal operation, no retention)
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

    // ── macro instantiation, SELECTED BY AW ──────────────────────────────
    //
    // A1 (2026-09-28). This used to hardcode `rf_16k` whatever AW said, and that
    // cost real area: nanosoc_compute_chiplet.sv:226 has set TL_RAM_ADDR_W = 13
    // (8 KB) since 2026-09-23, but the wrapper kept instantiating the 16 KB part.
    // MEASURED on the rsyn5 netlist: the FIFO macros' top address bit A[11] is
    // FE_OFN69_LTIE_LTIELO_3_NET, which resolves through CKND6 <- INVD1 <- TIEL to
    // 0 -- so only A[10:0] was ever addressable. Half of each 16 KB macro was
    // unreachable, at 88,941 um2 each against rf_08k's 48,045.
    //
    // Do NOT read the tie's value from its name: `_LTIELO_` records which tie the
    // net descends from, not what it carries. Resolve to the TIEL/TIEH cell and
    // XOR by the parity of inverting stages.
    //
    // AW is the BYTE address width, so the word address is AW-1:2:
    //     AW = 14  ->  A[11:0] 12 bits  ->  4,096 words = 16 KB  ->  rf_16k
    //     AW = 13  ->  A[10:0] 11 bits  ->  2,048 words =  8 KB  ->  rf_08k

    generate
        if (AW == 13) begin : gen_rf_08k
            rf_08k u_rf (
                .CLK   (CLK),
                .CEN   (cen),
                .A     (ADDR[AW-1:2]),   // 11-bit word address
                .D     (WDATA),
                .GWEN  (gwen),
                .WEN   (wen),
                .Q     (RDATA),
                .EMA   (3'b010),   // macro default
                .EMAW  (2'b00),
                .RET1N (1'b1)
            );
        end else if (AW == 14) begin : gen_rf_16k
            rf_16k u_rf (
                .CLK   (CLK),
                .CEN   (cen),
                .A     (ADDR[AW-1:2]),   // 12-bit word address
                .D     (WDATA),
                .GWEN  (gwen),
                .WEN   (wen),
                .Q     (RDATA),
                .EMA   (3'b010),   // macro default
                .EMAW  (2'b00),
                .RET1N (1'b1)
            );
        end else begin : gen_bad_aw
            // Fail loudly at elaboration. A silently-wrong macro is how the 16 KB
            // part survived a parameter change for five days.
            $fatal(1, "tidelink_sram: AW=%0d has no macro mapping (expect 13 or 14)", AW);
        end
    endgenerate

endmodule
