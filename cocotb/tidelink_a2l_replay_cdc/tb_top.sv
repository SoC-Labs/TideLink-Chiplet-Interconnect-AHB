// ---------------------------------------------------------------------------
// tb_top.sv  --  unit testbench for the TideLink a2l (app->link) replay FIFO
//
// Instantiates WlinkGenericFCReplayV2_13 standalone with INDEPENDENT app_clk
// and link_clk and INDEPENDENTLY-controllable app_reset / link_reset, so the
// cocotb tests can reproduce the silicon "a2l replay FIFO false-FULL on the
// first write" bug (synced ACK ptr a full lap ahead of the write ptr) by
// sweeping the relative reset-deassert skew of the two clock domains.
//
// All DUT ports are wired; link-side inputs are individually controllable from
// cocotb (link_advance / link_ack_update / link_ack_addr / link_revert /
// link_revert_addr) so Phase-2 functional traffic can be driven too.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top (
    // Clocks (driven by cocotb)
    input  logic        app_clk,
    input  logic        link_clk,

    // Independently controllable resets (active HIGH, like the DUT)
    input  logic        app_reset,
    input  logic        link_reset,

    // App-side (write) interface
    input  logic        app_enable,
    input  logic [47:0] app_data,
    input  logic        app_valid,
    output logic        app_ready,

    // Link-side (read) interface
    input  logic        link_ack_update,
    input  logic [4:0]  link_ack_addr,
    input  logic        link_revert,
    input  logic [4:0]  link_revert_addr,
    input  logic        link_advance,
    output logic [4:0]  link_cur_addr,
    output logic [47:0] link_data,
    output logic        link_valid,
    output logic        link_empty
);

    WlinkGenericFCReplayV2_13 dut (
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
    // (hierarchical probing also works directly via dut.<...> from cocotb)
    wire [4:0] tb_wbin_ptr        = dut.fifo_io_wbin_ptr;        // app-clk write ptr (binary)
    wire [4:0] tb_synced_ack      = dut.a2l_link_addr_app_clk;   // ACK ptr synced into app_clk
    wire       tb_a2l_full        = dut.a2l_full;                // false-full indicator
    wire       tb_app_ready       = dut.app_ready;
    wire       tb_link_empty      = dut.link_empty;
    wire [4:0] tb_link_ack_reg    = dut.a2l_link_addr;          // link-clk ACK accumulator

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
