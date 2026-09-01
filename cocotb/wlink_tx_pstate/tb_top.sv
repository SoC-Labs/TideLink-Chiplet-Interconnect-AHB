//-----------------------------------------------------------------------------
// tb_top.sv -- unit bench for WlinkTxPstateCtrl, the Wlink TX power-state
// controller.
//
// WHY (2026-08-26)
//   FSM 0.00% -- 1 of 3 states, 0 of 4 transitions -- in ALL 42 coverage
//   databases that contain the module.  The TX power-state controller has
//   never changed state in any simulation in this repository.
//
//   It is not dormant logic.  swi_delay_cycles RESETS TO 16'h6a4 (1700), so
//   the idle timeout is ARMED OUT OF RESET, and Wlink.v:1702 wires its output
//   straight to the PHY:
//       assign phy_link_tx_tx_en = txpstate_io_tx_en;   // = ~req_pstate
//   So 1700 idle cycles after the last packet this block backpressures the
//   upstream TX path (auto_in_advance forced 0), injects PREQ packets of its
//   own, and then DROPS THE PHY TX ENABLE until new traffic arrives.  Nothing
//   has ever simulated that sequence.  Every existing bench either keeps the
//   link busy or ends before 1700 quiet cycles elapse.
//
//   swi_delay_cycles is a port here so the timeout can be shortened; the
//   shipping reset value is asserted separately, in the test that would
//   otherwise be the only thing standing between "we shortened it" and "we
//   proved something about silicon".
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_top (
    input  logic          clock,
    input  logic          reset,          // ACTIVE HIGH, async (Chisel)

    input  logic          auto_in_sop,
    input  logic [7:0]    auto_in_data_id,
    input  logic [15:0]   auto_in_word_count,
    input  logic [111:0]  auto_in_data,
    input  logic [15:0]   auto_in_crc,
    output logic          auto_in_advance,

    output logic          auto_out_sop,
    output logic [7:0]    auto_out_data_id,
    output logic [15:0]   auto_out_word_count,
    output logic [111:0]  auto_out_data,
    output logic [15:0]   auto_out_crc,
    input  logic          auto_out_advance,

    input  logic [15:0]   io_swi_delay_cycles,
    input  logic [2:0]    io_swi_num_preq_send,
    input  logic [7:0]    io_swi_preq_data_id,
    input  logic [7:0]    io_swi_cycles_post_preq,
    input  logic          io_tx_ready,
    output logic          io_tx_en,
    output logic [1:0]    io_state_o
);

    WlinkTxPstateCtrl u_dut (
        .clock                  (clock),
        .reset                  (reset),
        .auto_in_sop            (auto_in_sop),
        .auto_in_data_id        (auto_in_data_id),
        .auto_in_word_count     (auto_in_word_count),
        .auto_in_data           (auto_in_data),
        .auto_in_crc            (auto_in_crc),
        .auto_in_advance        (auto_in_advance),
        .auto_out_sop           (auto_out_sop),
        .auto_out_data_id       (auto_out_data_id),
        .auto_out_word_count    (auto_out_word_count),
        .auto_out_data          (auto_out_data),
        .auto_out_crc           (auto_out_crc),
        .auto_out_advance       (auto_out_advance),
        .io_swi_delay_cycles    (io_swi_delay_cycles),
        .io_swi_num_preq_send   (io_swi_num_preq_send),
        .io_swi_preq_data_id    (io_swi_preq_data_id),
        .io_swi_cycles_post_preq(io_swi_cycles_post_preq),
        .io_tx_ready            (io_tx_ready),
        .io_tx_en               (io_tx_en),
        .io_state_o             (io_state_o)
    );

`ifndef TB_TOP_NO_DUMP
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end
`endif

endmodule
