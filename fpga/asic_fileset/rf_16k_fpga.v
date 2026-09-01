//-----------------------------------------------------------------------------
// rf_16k_fpga.v  —  FPGA-SYNTHESISABLE SUBSTITUTE for the TSMC65 rf_16k
//                   compiled register-file HARD MACRO.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// WHY THIS FILE EXISTS
// --------------------
// The ASIC file set (flists/tidelink_top_full_asic_v2.flist) takes the RX-FIFO
// memory from src/rtl/fifo/asic/tidelink_sram.sv, which instantiates `rf_16k` —
// a TSMC 65nm compiled register file. rf_16k is a HARD MACRO: it has NO RTL
// anywhere in the ASIC file set (Fusion Compiler binds it from the memory
// compiler's .lib/.lef/.gds at read_design time; the ASIC flist contains no
// rf_16k line at all, and syn/asic/sim_stubs/rf_16k_stub.v is explicitly
// marked "DO NOT add this file to any synthesis / PnR flist").
//
// So for an FPGA build of the ASIC file set the substitution is NOT the
// tidelink_sram wrapper — that file is compiled VERBATIM from
// src/rtl/fifo/asic/tidelink_sram.sv. The substitution is exactly ONE leaf: the
// memory macro the wrapper instantiates, which has no source to compile.
//
// WHAT IS AND IS NOT FAITHFUL
// ---------------------------
//  * Port list, widths and polarities: IDENTICAL to the macro (mirrors the
//    ports at src/rtl/fifo/asic/tidelink_sram.sv:48-60 and the stub's header).
//  * Depth/width: 4096 x 32b = 16 KiB, same as the macro.
//  * Q holds its last value while CEN is high — same as the macro and the
//    ASIC sim stub, and DIFFERENT from cmsdk_fpga_sram (which zeroes RDATA
//    when the previous-cycle CS was low). Modelled here on purpose so the
//    ASIC wrapper sees ASIC-macro output behaviour.
//  * EMA / EMAW / RET1N: accepted and IGNORED. They are margin/retention
//    controls of the compiled macro with no FPGA analogue. tidelink_sram.sv
//    ties them to their nominal constants, so nothing is lost functionally.
//  * READ-DURING-WRITE to the SAME address is UNDEFINED here (the read port
//    has a registered address into a byte-lane array that the write port
//    updates in the same cycle -> Vivado infers a simple-dual-port BRAM whose
//    same-address collision behaviour is not guaranteed). This matches the
//    cmsdk_fpga_sram behaviour that every previous TideLink FPGA image has
//    shipped with, and does NOT match the read-first ordering of
//    syn/asic/sim_stubs/rf_16k_stub.v. It is a genuine, documented deviation.
//  * NO timing/margin/retention modelling. This proves FUNCTION, not timing.
//
// PER-BIT vs PER-BYTE WRITE ENABLE
// --------------------------------
// rf_16k's WEN is per-BIT, active low. Vivado infers block RAM only from a
// byte-lane (or narrower-array) write template; a literal 32-way per-bit
// read-modify-write does not infer BRAM and would burn ~2k LUTs of distributed
// RAM per instance with a different timing profile.
//
// The SOLE instantiation of rf_16k in the design drives WEN byte-replicated:
//     wire [31:0] wen = ~{{8{WREN[3]}}, {8{WREN[2]}}, {8{WREN[1]}}, {8{WREN[0]}}};
//     -- src/rtl/fifo/asic/tidelink_sram.sv:47
// so WEN is byte-uniform BY CONSTRUCTION and byte granularity is exact. This
// model therefore keys each byte lane off WEN[8*k] and asserts (simulation
// only) that the other seven bits of that lane agree. If that assertion ever
// fires, this model is WRONG for the new caller and must be revisited.
//
// The write template below is deliberately syntax-identical to the one in
// cmsdk_fpga_sram.v (the memory every shipping TideLink FPGA image already
// uses), so the inferred BRAM primitive count and structure are unchanged from
// a normal FPGA build. Only the wrapper above it is now the ASIC source.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module rf_16k (
    input  wire         CLK,
    input  wire         CEN,     // chip enable, ACTIVE LOW
    input  wire [11:0]  A,       // word address (4096 x 32b)
    input  wire [31:0]  D,       // write data
    input  wire         GWEN,    // global write enable, ACTIVE LOW
    input  wire [31:0]  WEN,     // per-bit write enable, ACTIVE LOW
    output wire [31:0]  Q,       // read data
    input  wire [2:0]   EMA,     // margin control  - ignored on FPGA
    input  wire [1:0]   EMAW,    // margin control  - ignored on FPGA
    input  wire         RET1N    // retention       - ignored on FPGA
);

    // Byte-lane arrays. Same shape as cmsdk_fpga_sram's BRAM0..3 so Vivado
    // infers the same RAMB36E2 structure.
    reg [7:0] BRAM0 [0:4095];
    reg [7:0] BRAM1 [0:4095];
    reg [7:0] BRAM2 [0:4095];
    reg [7:0] BRAM3 [0:4095];

    reg [11:0] addr_q1;

    // Active-low -> active-high. A byte lane writes when the chip is selected,
    // the global write enable is asserted, and that lane's WEN is asserted.
    wire       sel = ~CEN;
    wire       wr  = sel & ~GWEN;
    wire [3:0] write_enable = { wr & ~WEN[24],
                                wr & ~WEN[16],
                                wr & ~WEN[8],
                                wr & ~WEN[0] };

    // Infer Block RAM - syntax is very specific (mirrors cmsdk_fpga_sram.v).
    always @ (posedge CLK) begin
        if (write_enable[0]) BRAM0[A] <= D[7:0];
        if (write_enable[1]) BRAM1[A] <= D[15:8];
        if (write_enable[2]) BRAM2[A] <= D[23:16];
        if (write_enable[3]) BRAM3[A] <= D[31:24];
        // Address register is CEN-qualified so Q HOLDS while the macro is
        // deselected, matching the compiled macro (and unlike cmsdk_fpga_sram,
        // which forces RDATA to 0 on the cycle after CS=0).
        if (sel) addr_q1 <= A;
    end

    assign Q = { BRAM3[addr_q1], BRAM2[addr_q1], BRAM1[addr_q1], BRAM0[addr_q1] };

    // ------------------------------------------------------------------
    // Simulation-only guard on the byte-uniform WEN precondition above.
    // Never synthesised.
    // ------------------------------------------------------------------
    // synthesis translate_off
    always @ (posedge CLK) begin
        if (wr) begin
            if ((WEN[7:0]   !== {8{WEN[0]}}) ||
                (WEN[15:8]  !== {8{WEN[8]}}) ||
                (WEN[23:16] !== {8{WEN[16]}}) ||
                (WEN[31:24] !== {8{WEN[24]}})) begin
                $display("%0t ERROR rf_16k_fpga(%m): NON-BYTE-UNIFORM WEN=%032b - this FPGA substitute models byte granularity ONLY.",
                         $time, WEN);
            end
        end
    end
    // synthesis translate_on

endmodule
