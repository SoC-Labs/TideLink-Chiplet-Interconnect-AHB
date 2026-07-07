// ---------------------------------------------------------------------------
// tb_cdc_tear_l2a.sv  --  the l2a twin of tb_cdc_tear.sv.
//
// DUT = WlinkGenericFCReplayV2_12, die_b's RX replay buffer -- the ACTUAL
// silicon offender for the A->B "false-FULL after ~6 words" data drop, and the
// module that currently has NO local_override on this branch (so it ships the
// edge-triggered w_inc unfixed).
//
// _12 is the same FC replay generator as _13 with an identical ACK-pointer
// mailbox path (WlinkGenericFCReplayAddrSync_18.raddr inside WavMultibitSync_18)
// and the same EDGE-TRIGGERED push-enable
//     assign link_addr_to_app_clk_w_inc = a2l_link_addr != link_ack_addr;
// The only interface difference is the ACK side: _12 has NO link_ack_update /
// link_revert strobes -- the link-domain accumulator simply follows link_ack_addr
// (a2l_link_addr <= link_ack_addr), which on silicon is the reader's consumed
// pointer.  The tear mechanism, the false-FULL, and the w_inc=1 self-heal fix
// are byte-for-byte identical to the a2l case; see tb_cdc_tear.sv for the full
// rationale.  The sim-only tear_arm/tear_val and winc_force1 hooks are the same.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_cdc_tear_l2a (
    input  logic        app_clk,
    input  logic        link_clk,
    input  logic        app_reset,
    input  logic        link_reset,

    input  logic        app_enable,
    input  logic [47:0] app_data,
    input  logic        app_valid,
    output logic        app_ready,

    // _12 link side: ack is a plain addr (no update/revert strobes)
    input  logic [4:0]  link_ack_addr,
    input  logic        link_advance,
    output logic [4:0]  link_cur_addr,
    output logic [47:0] link_data,
    output logic        link_valid,
    output logic        link_empty,

    // ── SIM-ONLY control ports (NOT part of the DUT) ──────────────────────
    input  logic        tear_arm,
    input  logic [4:0]  tear_val,
    input  logic        winc_force1,

    // ── Debug observables ─────────────────────────────────────────────────
    output logic [4:0]  dbg_wbin_ptr,
    output logic [4:0]  dbg_synced_ack,
    output logic        dbg_a2l_full,
    output logic [4:0]  dbg_link_ack,
    output logic        dbg_w_inc
);

    WlinkGenericFCReplayV2_12 u_dut (
        .app_clk          (app_clk),
        .app_reset        (app_reset),
        .app_enable       (app_enable),
        .app_data         (app_data),
        .app_valid        (app_valid),
        .app_ready        (app_ready),
        .link_clk         (link_clk),
        .link_reset       (link_reset),
        .link_ack_addr    (link_ack_addr),
        .link_cur_addr    (link_cur_addr),
        .link_data        (link_data),
        .link_valid       (link_valid),
        .link_advance     (link_advance),
        .link_empty       (link_empty)
    );

    assign dbg_wbin_ptr   = u_dut.fifo_io_wbin_ptr;
    assign dbg_synced_ack  = u_dut.a2l_link_addr_app_clk;   // == raddr
    assign dbg_a2l_full    = u_dut.a2l_full;
    assign dbg_link_ack    = u_dut.a2l_link_addr;
    assign dbg_w_inc       = u_dut.link_addr_to_app_clk_w_inc;

    always @(winc_force1) begin
        if (winc_force1)
            force u_dut.link_addr_to_app_clk_w_inc = 1'b1;
        else
            release u_dut.link_addr_to_app_clk_w_inc;
    end

    always @(tear_arm) begin
        if (tear_arm)
            force u_dut.link_addr_to_app_clk.raddr = tear_val;
        else
            release u_dut.link_addr_to_app_clk.raddr;
    end

    initial begin
        if ($test$plusargs("TL_DUMP")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_cdc_tear_l2a);
        end
    end

endmodule
