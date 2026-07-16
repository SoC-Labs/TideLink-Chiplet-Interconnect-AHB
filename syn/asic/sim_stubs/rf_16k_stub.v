// ---------------------------------------------------------------------------
// rf_16k_stub.v  —  SIM/ELABORATION-ONLY behavioural stub for the compiled
// rf_16k SRAM hard-macro.
//
// PURPOSE: the ASIC flists (flists/tidelink_top_full_asic*.flist) instantiate
// the rf_16k compiled macro (src/rtl/fifo/asic/tidelink_sram.sv:48). Fusion
// Compiler binds the real macro from the TSMC65 memory-compiler library at
// read_design time, so no Verilog model ships in the flist. To let plain VCS
// *elaborate* the ASIC flist for a build-integrity check (the `asic_v1_elab`
// sim_gate suite) we bind this behavioural stub instead.
//
// DO NOT add this file to any synthesis / PnR flist — it exists only so the
// pre-build gate can elaborate the ASIC file list end-to-end and catch
// port-list / flist-selection breakage (e.g. the a405809 obs-port class where
// a local_overrides module gains a port the submodule copy the ASIC flist
// still sources does not have). Ports mirror tidelink_sram.sv:48 exactly.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module rf_16k (
    input         CLK,
    input         CEN,     // chip enable, active low
    input  [11:0] A,       // 12-bit word address (4096 x 32b = 16 KB)
    input  [31:0] D,       // write data
    input         GWEN,    // global write enable, active low
    input  [31:0] WEN,     // per-bit write enable, active low
    output [31:0] Q,       // read data
    input  [2:0]  EMA,
    input  [1:0]  EMAW,
    input         RET1N
);
    // Behavioural single-port RAM — functionally faithful enough for
    // elaboration and light sim; the real timing/margin comes from the macro.
    reg [31:0] mem [0:4095];
    reg [31:0] q_r;
    always @(posedge CLK) begin
        if (!CEN) begin
            if (!GWEN) mem[A] <= (mem[A] & WEN) | (D & ~WEN);
            q_r <= mem[A];
        end
    end
    assign Q = q_r;
endmodule
