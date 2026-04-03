//-----------------------------------------------------------------------------
// SoCLabs TideLink SRAM Wrapper (Generic variant)
// - Implements SRAM as register-based storage for simulation and synthesis
//   targets without dedicated SRAM macros or block RAM.
//
// Behaviour matches cmsdk_fpga_sram:
// - Pipelined read (1-cycle address latency, read data appears next cycle)
// - Non-pipelined write (same-cycle write)
// - Byte-enable writes via WREN[3:0]
// - CS gates both writes and read data output
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

    localparam DEPTH = 1 << (AW - 2);

    // Memory array — 32-bit words
    reg [31:0] mem [0:DEPTH-1];

    // Pipelined read address and CS (1-cycle latency to match cmsdk_fpga_sram)
    reg [AW-3:0] addr_q;
    reg          cs_q;

    // Write with byte enables
    wire [3:0] we = WREN & {4{CS}};

    always @(posedge CLK) begin
        // Byte-lane writes
        if (we[0]) mem[ADDR][7:0]   <= WDATA[7:0];
        if (we[1]) mem[ADDR][15:8]  <= WDATA[15:8];
        if (we[2]) mem[ADDR][23:16] <= WDATA[23:16];
        if (we[3]) mem[ADDR][31:24] <= WDATA[31:24];

        // Pipeline the read address and chip select
        addr_q <= ADDR;
        cs_q   <= CS;
    end

    // Read data — gated by registered CS to match cmsdk_fpga_sram behaviour
    assign RDATA = cs_q ? mem[addr_q] : 32'h0000_0000;

endmodule
