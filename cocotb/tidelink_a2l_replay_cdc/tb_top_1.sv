// ---------------------------------------------------------------------------
// tb_top_1.sv  --  unit testbench for the AW-channel (0x80) a2l replay FIFO node
// WlinkGenericFCReplayV2_1 (101-bit data / 4-bit ptr / depth-8).
//
// Data-plane analogue of tb_top_5.sv (same depth-8 geometry, wider datum). The
// aliased internal nets + `dut` instance name match so the shared cocotb probes
// work unchanged.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top (
    input  logic         app_clk,
    input  logic         link_clk,
    input  logic         app_reset,
    input  logic         link_reset,

    // App-side (write) interface — 101-bit data
    input  logic         app_enable,
    input  logic [100:0] app_data,
    input  logic         app_valid,
    output logic         app_ready,

    // Link-side (read) interface — 4-bit ptrs
    input  logic         link_ack_update,
    input  logic [3:0]   link_ack_addr,
    input  logic         link_revert,
    input  logic [3:0]   link_revert_addr,
    input  logic         link_advance,
    output logic [3:0]   link_cur_addr,
    output logic [100:0] link_data,
    output logic         link_valid,
    output logic         link_empty
);

    WlinkGenericFCReplayV2_1 dut (
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
    wire [3:0] tb_wbin_ptr        = dut.fifo_io_wbin_ptr;
    wire [3:0] tb_synced_ack      = dut.a2l_link_addr_app_clk;
    wire       tb_a2l_full        = dut.a2l_full;
    wire       tb_app_ready       = dut.app_ready;
    wire       tb_link_empty      = dut.link_empty;
    wire [3:0] tb_link_ack_reg    = dut.a2l_link_addr;

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
