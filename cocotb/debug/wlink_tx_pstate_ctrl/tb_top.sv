// =============================================================================
// tb_top.sv -- standalone unit testbench for WlinkTxPstateCtrl
// =============================================================================
//
// Purpose: definitively prove (or refute) the FSM-deadlock hypothesis for the
// pstate controller. The audit asserted:
//   * io_tx_en = ~req_pstate                                  (line 58)
//   * state==2 holds while io_tx_ready=LOW (no auto_in_sop)   (line 76)
//   * once req_pstate latches HIGH in state==2 it persists    (line 114)
//
// At the wrapper level io_tx_ready feeds back through io_tx_en (the lane gate)
// so the loop becomes circular -- but at the unit level we control io_tx_ready
// directly, which lets us isolate the FSM's stuck-state behaviour.
//
// We expose every input/output port plus the internal `state` reg so the
// cocotb test can sample state, req_pstate, io_tx_en, and io_tx_ready every
// io_clk.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top (
    input  wire         clock,
    input  wire         reset,
    input  wire         auto_in_sop,
    input  wire [7:0]   auto_in_data_id,
    input  wire [15:0]  auto_in_word_count,
    input  wire [111:0] auto_in_data,
    input  wire [15:0]  auto_in_crc,
    output wire         auto_in_advance,
    output wire         auto_out_sop,
    output wire [7:0]   auto_out_data_id,
    output wire [15:0]  auto_out_word_count,
    output wire [111:0] auto_out_data,
    output wire [15:0]  auto_out_crc,
    input  wire         auto_out_advance,
    input  wire [15:0]  io_swi_delay_cycles,
    input  wire [2:0]   io_swi_num_preq_send,
    input  wire [7:0]   io_swi_preq_data_id,
    input  wire [7:0]   io_swi_cycles_post_preq,
    input  wire         io_tx_ready,
    output wire         io_tx_en,
    output wire [1:0]   io_state_o
);

    WlinkTxPstateCtrl u_dut (
        .clock                   (clock),
        .reset                   (reset),
        .auto_in_sop             (auto_in_sop),
        .auto_in_data_id         (auto_in_data_id),
        .auto_in_word_count      (auto_in_word_count),
        .auto_in_data            (auto_in_data),
        .auto_in_crc             (auto_in_crc),
        .auto_in_advance         (auto_in_advance),
        .auto_out_sop            (auto_out_sop),
        .auto_out_data_id        (auto_out_data_id),
        .auto_out_word_count     (auto_out_word_count),
        .auto_out_data           (auto_out_data),
        .auto_out_crc            (auto_out_crc),
        .auto_out_advance        (auto_out_advance),
        .io_swi_delay_cycles     (io_swi_delay_cycles),
        .io_swi_num_preq_send    (io_swi_num_preq_send),
        .io_swi_preq_data_id     (io_swi_preq_data_id),
        .io_swi_cycles_post_preq (io_swi_cycles_post_preq),
        .io_tx_ready             (io_tx_ready),
        .io_tx_en                (io_tx_en),
        .io_state_o              (io_state_o)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
