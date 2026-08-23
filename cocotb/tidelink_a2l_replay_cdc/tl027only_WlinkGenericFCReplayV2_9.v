// SPDX-License-Identifier: Apache-2.0
//
// Copyright 2021 Wavious, Inc.
// Copyright 2026 SoC Labs, University of Southampton
//
// Derived from the Wavious "wlink" chiplet interconnect (Apache-2.0). MODIFIED by
// SoC Labs: this is the R (read-data, data_id 0x84) data-plane a2l replay node
// WlinkGenericFCReplayV2_9 with the a2l ACK-ptr CDC self-heal PORTED from
// WlinkGenericFCReplayV2_13.v (David Mapstone 2026-07-07) for TL-027, via the
// matching sibling override WlinkGenericFCReplayV2_3.v (same pointer geometry).
// Same 3-part fix, 6-bit ptr / depth-32 widths (window bound 6'h20):
//   (1) ACK-window guard (a2l_ack_valid); (2) continuous w_inc(=1) self-heal;
//   (3) gated latch. REPRODUCE-FIRST proven in cocotb/tidelink_a2l_replay_cdc
//   NODE=9: pristine deps _9 FAILS (a2l_full=1 after a lap-ahead ACK(33));
//   this override PASSES. Idle single-clock sim never tears -> silicon verifies w_inc.
//
// TL-027-ONLY BASELINE (bench artefact, NOT the shipping override): the TL-032
//   revert-aware rewind has been REMOVED so the revert test has a non-vacuous
//   'before'. Selected with `make NODE=9 USE_PREFIX_DUT=1`.
//
// TL-043-ARR (2026-08-23): _1/_3/_5 (AW/W/B) and _12/_13 (sideband) carried this
//   hardening since 2026-08-08; the READ path (_7 AR, _9 R) had NO override file
//   at all and shipped RAW from deps/. This file closes that gap for _9.
//   Node-specific instances preserved from the deps source (NOT copied from
//   _3): fifo = WavFIFO_14, RAM = wlink_wlink_axi_rFC_a2l_47x32,
//   addr sync = WlinkGenericFCReplayAddrSync_3.
//
module WlinkGenericFCReplayV2_9(
  input         app_clk,
  input         app_reset,
  input         app_enable,
  input  [46:0] app_data,
  input         app_valid,
  output        app_ready,
  input         link_clk,
  input         link_reset,
  input         link_ack_update,
  input  [5:0]  link_ack_addr,
  input         link_revert,
  input  [5:0]  link_revert_addr,
  output [5:0]  link_cur_addr,
  output [46:0] link_data,
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
  wire  fifo_io_rrevert; // @[FC.scala 743:20]
  wire [5:0] fifo_io_rrevert_addr; // @[FC.scala 743:20]
  wire [46:0] fifo_io_wdata; // @[FC.scala 743:20]
  wire [46:0] fifo_io_rdata; // @[FC.scala 743:20]
  wire  fifo_io_wfull; // @[FC.scala 743:20]
  wire  fifo_io_rempty; // @[FC.scala 743:20]
  wire [5:0] fifo_io_rbin_ptr; // @[FC.scala 743:20]
  wire [5:0] fifo_io_wbin_ptr; // @[FC.scala 743:20]
  wire  link_addr_to_app_clk_w_clk; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_w_reset; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_w_inc; // @[FC.scala 773:37]
  wire [5:0] link_addr_to_app_clk_w_addr; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_r_clk; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_r_reset; // @[FC.scala 773:37]
  wire [5:0] link_addr_to_app_clk_r_addr; // @[FC.scala 773:37]
  wire [5:0] a2l_app_addr = fifo_io_wbin_ptr; // @[FC.scala 725:29 FC.scala 749:25]
  wire [5:0] a2l_link_addr_app_clk = link_addr_to_app_clk_r_addr; // @[FC.scala 723:41 FC.scala 781:33]
  wire  a2l_full = a2l_app_addr[5] != a2l_link_addr_app_clk[5] & a2l_app_addr[4:0] == a2l_link_addr_app_clk[4:0]; // @[FC.scala 727:88]
  reg [5:0] a2l_link_addr; // @[FC.scala 770:103]
  // TIDELINK LOCAL OVERRIDE (TL-027 a2l ACK-ptr CDC self-heal, R-node port)
  wire [5:0] a2l_ack_off_req = link_ack_addr    - a2l_link_addr; // requested advance (mod 64)
  wire [5:0] a2l_ack_off_max = fifo_io_rbin_ptr - a2l_link_addr; // outstanding window (mod 64)
  wire  a2l_ack_valid = link_ack_update
                        & (a2l_ack_off_req <= a2l_ack_off_max)
                        & (a2l_ack_off_max <= 6'h20);
  wire [5:0] a2l_link_addr_in = a2l_ack_valid ? link_ack_addr : a2l_link_addr; // gated ACK (window guard)
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
  WavFIFO_14 fifo ( // @[FC.scala 743:20]
    .io_wclk(fifo_io_wclk),
    .io_wreset(fifo_io_wreset),
    .io_winc(fifo_io_winc),
    .io_rclk(fifo_io_rclk),
    .io_rreset(fifo_io_rreset),
    .io_rinc(fifo_io_rinc),
    .io_rrevert(fifo_io_rrevert),
    .io_rrevert_addr(fifo_io_rrevert_addr),
    .io_wdata(fifo_io_wdata),
    .io_rdata(fifo_io_rdata),
    .io_wfull(fifo_io_wfull),
    .io_rempty(fifo_io_rempty),
    .io_rbin_ptr(fifo_io_rbin_ptr),
    .io_wbin_ptr(fifo_io_wbin_ptr)
  );
  WlinkGenericFCReplayAddrSync_3 link_addr_to_app_clk ( // @[FC.scala 773:37]
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
  assign fifo_io_rrevert = link_revert; // @[FC.scala 757:29]
  assign fifo_io_rrevert_addr = link_revert_addr; // @[FC.scala 758:29]
  assign fifo_io_wdata = app_data; // @[FC.scala 747:25]
  assign link_addr_to_app_clk_w_clk = link_clk; // @[FC.scala 774:45]
  assign link_addr_to_app_clk_w_reset = link_reset; // @[FC.scala 775:33]
  assign link_addr_to_app_clk_w_inc = 1'b1; // TL-027 port: continuous resend (self-heal)
  assign link_addr_to_app_clk_w_addr = a2l_link_addr_in; // TL-027 port: gated ACK (guard-clamped)
  assign link_addr_to_app_clk_r_clk = app_clk; // @[FC.scala 779:44]
  assign link_addr_to_app_clk_r_reset = app_reset; // @[FC.scala 780:33]
  always @(posedge link_clk or posedge link_reset) begin
    if (link_reset) begin
      a2l_link_addr <= 6'h0;
    end else if (a2l_ack_valid) begin     // TL-027 port: gated ACK advance
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
  a2l_link_addr = _RAND_0[5:0];
`endif // RANDOMIZE_REG_INIT
  if (link_reset) begin
    a2l_link_addr = 6'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
