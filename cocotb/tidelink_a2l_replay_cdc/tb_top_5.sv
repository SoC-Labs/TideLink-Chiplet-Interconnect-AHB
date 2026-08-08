// ---------------------------------------------------------------------------
// tb_top_5.sv  --  unit testbench for the B-channel (0x82) a2l replay FIFO node
// WlinkGenericFCReplayV2_5 (14-bit data / 4-bit ptr / depth-8).
//
// Data-plane analogue of tb_top.sv (which drives the 48/5/16 _13 sideband node).
// Same standalone harness: independent app_clk/link_clk and independently
// controllable app_reset/link_reset, all link-side inputs driveable from cocotb,
// so the ACK-lap-ahead false-FULL self-latch can be reproduced on the B node.
//
// The instance name is `dut` and the aliased internal nets match tb_top.sv so
// the shared cocotb probes (dut.dut.a2l_full etc.) work unchanged.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top (
    input  logic        app_clk,
    input  logic        link_clk,
    input  logic        app_reset,
    input  logic        link_reset,

    // App-side (write) interface — 14-bit data
    input  logic        app_enable,
    input  logic [13:0] app_data,
    input  logic        app_valid,
    output logic        app_ready,

    // Link-side (read) interface — 4-bit ptrs
    input  logic        link_ack_update,
    input  logic [3:0]  link_ack_addr,
    input  logic        link_revert,
    input  logic [3:0]  link_revert_addr,
    input  logic        link_advance,
    output logic [3:0]  link_cur_addr,
    output logic [13:0] link_data,
    output logic        link_valid,
    output logic        link_empty
);

    WlinkGenericFCReplayV2_5 dut (
        .app_clk          (app_clk),
        .app_reset        (app_reset),
        .app_enable       (app_enable),
        .app_data         (app_data),
        .app_valid        (app_valid),
        .app_ready        (app_ready),
        .link_clk         (link_clk),
        .link_reset       (link_reset),
        .link_ack_update  (link_ack_update),
        .link_ack_addr    (link_ack_addr),
        .link_revert      (link_revert),
        .link_revert_addr (link_revert_addr),
        .link_cur_addr    (link_cur_addr),
        .link_data        (link_data),
        .link_valid       (link_valid),
        .link_advance     (link_advance),
        .link_empty       (link_empty)
    );

    // ── Convenience aliases for the internal nets the tests probe ──────────
    wire [3:0] tb_wbin_ptr        = dut.fifo_io_wbin_ptr;        // app-clk write ptr (binary)
    wire [3:0] tb_synced_ack      = dut.a2l_link_addr_app_clk;   // ACK ptr synced into app_clk
    wire       tb_a2l_full        = dut.a2l_full;                // false-full indicator
    wire       tb_app_ready       = dut.app_ready;
    wire       tb_link_empty      = dut.link_empty;
    wire [3:0] tb_link_ack_reg    = dut.a2l_link_addr;          // link-clk ACK accumulator

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
