// SPDX-License-Identifier: Apache-2.0
//
// Copyright 2021 Wavious, Inc.
// Copyright 2026 SoC Labs, University of Southampton
//
// Derived from the Wavious "wlink" chiplet interconnect
// (https://github.com/Wavious/wlink), licensed under the Apache License,
// Version 2.0. This file has been MODIFIED by SoC Labs. See NOTICE and
// THIRD_PARTY_NOTICES.md for the nature of those modifications; the git
// history of this repository is the per-line record.
//
// You may obtain a copy of the License at:
//     http://www.apache.org/licenses/LICENSE-2.0
//
module WlinkGenericFCReplayV2_12(
  input         app_clk,
  input         app_reset,
  input         app_enable,
  input  [47:0] app_data,
  input         app_valid,
  output        app_ready,
  input         link_clk,
  input         link_reset,
  input  [4:0]  link_ack_addr,
  output [4:0]  link_cur_addr,
  output [47:0] link_data,
  output        link_valid,
  input         link_advance,
  output        link_empty
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
`endif // RANDOMIZE_REG_INIT
  wire  enable_app_clk_demet_clock; // @[Stdcell.scala 58:23]
  wire  enable_app_clk_demet_reset; // @[Stdcell.scala 58:23]
  wire  enable_app_clk_demet_io_in; // @[Stdcell.scala 58:23]
  wire  enable_app_clk_demet_io_out; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_clock; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_reset; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_io_in; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_io_out; // @[Stdcell.scala 58:23]
  wire  fifo_io_wclk; // @[FC.scala 743:20]
  wire  fifo_io_wreset; // @[FC.scala 743:20]
  wire  fifo_io_winc; // @[FC.scala 743:20]
  wire  fifo_io_rclk; // @[FC.scala 743:20]
  wire  fifo_io_rreset; // @[FC.scala 743:20]
  wire  fifo_io_rinc; // @[FC.scala 743:20]
  wire [47:0] fifo_io_wdata; // @[FC.scala 743:20]
  wire [47:0] fifo_io_rdata; // @[FC.scala 743:20]
  wire  fifo_io_wfull; // @[FC.scala 743:20]
  wire  fifo_io_rempty; // @[FC.scala 743:20]
  wire [4:0] fifo_io_rbin_ptr; // @[FC.scala 743:20]
  wire [4:0] fifo_io_wbin_ptr; // @[FC.scala 743:20]
  wire  link_addr_to_app_clk_w_clk; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_w_reset; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_w_inc; // @[FC.scala 773:37]
  wire [4:0] link_addr_to_app_clk_w_addr; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_r_clk; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_r_reset; // @[FC.scala 773:37]
  wire [4:0] link_addr_to_app_clk_r_addr; // @[FC.scala 773:37]
  wire [4:0] a2l_app_addr = fifo_io_wbin_ptr; // @[FC.scala 725:29 FC.scala 749:25]
  wire [4:0] a2l_link_addr_app_clk = link_addr_to_app_clk_r_addr; // @[FC.scala 723:41 FC.scala 781:33]
  wire  a2l_full = a2l_app_addr[4] != a2l_link_addr_app_clk[4] & a2l_app_addr[3:0] == a2l_link_addr_app_clk[3:0]; // @[FC.scala 727:88]
  reg [4:0] a2l_link_addr; // @[FC.scala 770:103]
  WavDemetReset enable_app_clk_demet ( // @[Stdcell.scala 58:23]
    .clock(enable_app_clk_demet_clock),
    .reset(enable_app_clk_demet_reset),
    .io_in(enable_app_clk_demet_io_in),
    .io_out(enable_app_clk_demet_io_out)
  );
  WavDemetReset enable_link_clk_demet ( // @[Stdcell.scala 58:23]
    .clock(enable_link_clk_demet_clock),
    .reset(enable_link_clk_demet_reset),
    .io_in(enable_link_clk_demet_io_in),
    .io_out(enable_link_clk_demet_io_out)
  );
  WavFIFO_18 fifo ( // @[FC.scala 743:20]
    .io_wclk(fifo_io_wclk),
    .io_wreset(fifo_io_wreset),
    .io_winc(fifo_io_winc),
    .io_rclk(fifo_io_rclk),
    .io_rreset(fifo_io_rreset),
    .io_rinc(fifo_io_rinc),
    .io_wdata(fifo_io_wdata),
    .io_rdata(fifo_io_rdata),
    .io_wfull(fifo_io_wfull),
    .io_rempty(fifo_io_rempty),
    .io_rbin_ptr(fifo_io_rbin_ptr),
    .io_wbin_ptr(fifo_io_wbin_ptr)
  );
  WlinkGenericFCReplayAddrSync_18 link_addr_to_app_clk ( // @[FC.scala 773:37]
    .w_clk(link_addr_to_app_clk_w_clk),
    .w_reset(link_addr_to_app_clk_w_reset),
    .w_inc(link_addr_to_app_clk_w_inc),
    .w_addr(link_addr_to_app_clk_w_addr),
    .r_clk(link_addr_to_app_clk_r_clk),
    .r_reset(link_addr_to_app_clk_r_reset),
    .r_addr(link_addr_to_app_clk_r_addr)
  );
  assign app_ready = ~a2l_full & enable_app_clk_demet_io_out; // @[FC.scala 728:36]
  assign link_cur_addr = fifo_io_rbin_ptr; // @[FC.scala 763:25]
  assign link_data = fifo_io_rdata; // @[FC.scala 754:25]
  assign link_valid = enable_link_clk_demet_io_out & ~link_empty; // @[FC.scala 740:39]
  assign link_empty = fifo_io_rempty; // @[FC.scala 738:39 FC.scala 755:25]
  assign enable_app_clk_demet_clock = app_clk; // @[FC.scala 721:51]
  assign enable_app_clk_demet_reset = app_reset; // @[FC.scala 721:70]
  assign enable_app_clk_demet_io_in = app_enable; // @[Stdcell.scala 59:17]
  assign enable_link_clk_demet_clock = link_clk; // @[FC.scala 734:53]
  assign enable_link_clk_demet_reset = link_reset; // @[FC.scala 734:73]
  assign enable_link_clk_demet_io_in = app_enable; // @[Stdcell.scala 59:17]
  assign fifo_io_wclk = app_clk; // @[FC.scala 744:25]
  assign fifo_io_wreset = app_reset; // @[FC.scala 745:25]
  assign fifo_io_winc = app_ready & app_valid; // @[FC.scala 729:35]
  assign fifo_io_rclk = link_clk; // @[FC.scala 751:25]
  assign fifo_io_rreset = link_reset; // @[FC.scala 752:25]
  assign fifo_io_rinc = link_valid & link_advance; // @[FC.scala 741:46]
  assign fifo_io_wdata = app_data; // @[FC.scala 747:25]
  assign link_addr_to_app_clk_w_clk = link_clk; // @[FC.scala 774:45]
  assign link_addr_to_app_clk_w_reset = link_reset; // @[FC.scala 775:33]
  // ===========================================================================
  // TIDELINK LOCAL OVERRIDE (l2a RX-buffer ACK-ptr CDC self-heal) 2026-07-07
  //
  // This is the l2a_fc_replay instance (WlinkGenericFCSM_6.v:936) -- die_b's
  // A->B RECEIVE buffer. It is the UNFIXED TWIN of the a2l TX buffer (_13):
  // identical false-full mechanism (a2l_full = wbin vs synced-ACK -> app_ready
  // -> fifo_io_winc) but its ACK-ptr sync w_inc was left EDGE-triggered.
  //
  // SILICON BUG (A->B caps at exactly ~6): on die_b the RX io_rx_clk is recovered
  // from die_a's (pathological-ratio) TX clock. The WavMultibitSync ACK-ptr
  // mailbox delivers a TORN synced value -> a2l_full=1 (false) -> app_ready=0 ->
  // fifo_io_winc=0 -> the FCSM's committed RX words (6..N) are SILENTLY DROPPED at
  // the l2a FIFO write. The FCSM still advances exp_pkt_num + ACKs 0..N (commit
  // gate is independent of this app_ready), so die_a transmits all N (rbin=N) and
  // the far-end credit ring stays healthy (fe_rx_is_full=0) -- the RX ring simply
  // holds words 0..5 in order then zeros. Edge-triggered w_inc means once the
  // synced ACK is torn it is NEVER re-pushed -> permanent drop. B->A is fine
  // because die_a's l2a RX clock is recovered from die_b's benign TX clock.
  //
  // FIX (parity with the proven a2l _13 self-heal, WlinkGenericFCReplayV2_13.v:210,
  // and the already-silicon-proven l2a sibling FCSM:1081 which ties w_inc=1'h1):
  // drive w_inc CONTINUOUSLY so the mailbox re-pushes link_ack_addr every w_ready
  // and the app side drains it every app_clk -> a torn synced-ACK self-heals within
  // ~1 round-trip -> the false-full clears -> RX words resume committing.
  // The shared coherent mailbox reset (WavMultibitSync_18, 07332e6) + reset-skew
  // gate reach this instance too, curing the bring-up desync. Idle single-clock sim
  // never tears (passes either way) -> silicon is the verifier.
  // ===========================================================================
  assign link_addr_to_app_clk_w_inc = 1'b1; // @[FC.scala 776:50] continuous resend (self-heal)
  assign link_addr_to_app_clk_w_addr = link_ack_addr; // @[FC.scala 771:39]
  assign link_addr_to_app_clk_r_clk = app_clk; // @[FC.scala 779:44]
  assign link_addr_to_app_clk_r_reset = app_reset; // @[FC.scala 780:33]
  always @(posedge link_clk or posedge link_reset) begin
    if (link_reset) begin
      a2l_link_addr <= 5'h0;
    end else begin
      a2l_link_addr <= link_ack_addr;
    end
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  a2l_link_addr = _RAND_0[4:0];
`endif // RANDOMIZE_REG_INIT
  if (link_reset) begin
    a2l_link_addr = 5'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
