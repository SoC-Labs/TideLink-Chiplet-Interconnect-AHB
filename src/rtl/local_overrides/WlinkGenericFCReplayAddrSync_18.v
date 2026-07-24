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
module WlinkGenericFCReplayAddrSync_18(
  input        w_clk,
  input        w_reset,
  input        w_inc,
  input  [4:0] w_addr,
  input        r_clk,
  input        r_reset,
  output [4:0] r_addr
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
`endif // RANDOMIZE_REG_INIT
  wire  addrsync_w_clk; // @[FC.scala 826:29]
  wire  addrsync_w_reset; // @[FC.scala 826:29]
  wire  addrsync_w_inc; // @[FC.scala 826:29]
  wire [4:0] addrsync_w_data; // @[FC.scala 826:29]
  wire  addrsync_w_ready; // @[FC.scala 826:29]
  wire  addrsync_r_clk; // @[FC.scala 826:29]
  wire  addrsync_r_reset; // @[FC.scala 826:29]
  wire  addrsync_r_inc; // @[FC.scala 826:29]
  wire [4:0] addrsync_r_data; // @[FC.scala 826:29]
  wire  addrsync_r_ready; // @[FC.scala 826:29]
  reg [4:0] raddr; // @[FC.scala 823:73]
  WavMultibitSync_18 addrsync ( // @[FC.scala 826:29]
    .w_clk(addrsync_w_clk),
    .w_reset(addrsync_w_reset),
    .w_inc(addrsync_w_inc),
    .w_data(addrsync_w_data),
    .w_ready(addrsync_w_ready),
    .r_clk(addrsync_r_clk),
    .r_reset(addrsync_r_reset),
    .r_inc(addrsync_r_inc),
    .r_data(addrsync_r_data),
    .r_ready(addrsync_r_ready)
  );
  assign r_addr = raddr; // @[FC.scala 838:21]
  assign addrsync_w_clk = w_clk; // @[FC.scala 827:21]
  assign addrsync_w_reset = w_reset; // @[FC.scala 828:21]
  assign addrsync_w_inc = w_inc; // @[FC.scala 829:21]
  assign addrsync_w_data = w_addr; // @[FC.scala 830:21]
  assign addrsync_r_clk = r_clk; // @[FC.scala 832:21]
  assign addrsync_r_reset = r_reset; // @[FC.scala 833:21]
  assign addrsync_r_inc = addrsync_r_ready; // @[FC.scala 834:21]

  // ===========================================================================
  // TIDELINK LOCAL OVERRIDE (a2l ACK-ptr reset-skew fix) -- David Mapstone 2026-07
  //
  // SILICON BUG (obs 0x2158): after autonomous bring-up the link is HEALTHY
  // (cal=1, anchored, credit_max=31, fe_rx_is_full=0) yet die_a's a2l replay is
  // wedged: synced_ack(=raddr)=0x1f (a FULL LAP ahead of wbin_ptr=15) while the
  // link read ptr rbin_ptr=0 -> a2l_full=1 -> app_ready=0 -> TX never emits ->
  // peer RX FIFO never written. The link-domain a2l_link_addr is guard-clamped
  // correct (<= rbin_ptr = 0), so the corruption is in THIS CDC, not the guard.
  //
  // ROOT CAUSE: r_reset (= app_reset) and w_reset (= link_reset) are in DIFFERENT
  // domains. On silicon app_reset deasserts BEFORE link_reset (asymmetric reset-
  // release skew). The original raddr flop below released with r_reset while the
  // write side (WavMultibitSync mem/pointers) was still in / just leaving w_reset,
  // so a spurious addrsync_r_ready latched a not-yet-valid, lap-ahead value into
  // raddr. Because no legitimate ACK follows at bring-up (rbin_ptr stays 0, guard
  // suppresses w_inc), raddr NEVER self-corrects -> permanent false-FULL. The
  // idealised single-/coherent-clock sim (incl. the reset-skew repro) resolves
  // the demets cleanly and never exposes it.
  //
  // FIX: synchronise w_reset (link_reset) into the r_clk domain (async-assert /
  // sync-deassert) and hold raddr in reset until BOTH domains' resets have
  // released. During bring-up the ACK ptr is legitimately 0, so holding raddr=0
  // across the whole skew window is always correct and cannot lose a real ACK
  // (data does not flow until after both resets are long released). Once the
  // write side is valid, raddr syncs the real (0) value and tracks ACKs as before.
  // ===========================================================================
  reg  wrst_meta;
  reg  wrst_sync;
  always @(posedge r_clk or posedge w_reset) begin
    if (w_reset) begin
      wrst_meta <= 1'b1;
      wrst_sync <= 1'b1;
    end else begin
      wrst_meta <= 1'b0;
      wrst_sync <= wrst_meta;
    end
  end
  wire raddr_rst = r_reset | wrst_sync;

  // ===========================================================================
  // TIDELINK LOCAL OVERRIDE #2 (SUPERSEDED 2026-07-07): a forward-distance clamp
  // used to sit here. It was built + deployed + REFUTED on silicon (A->B still
  // 6/28, synced_ack still 31). It was wrong TWO ways: (1) it BLOCKS the heal --
  // once raddr is torn to 31, the correcting value ~15 is a -16 (=+16 mod-32)
  // "backward" jump that the <16 test rejects, so it holds garbage forever;
  // (2) a sub-16 torn step still walks raddr up past the write ptr. Removed.
  //
  // Recovery is now handled UPSTREAM by CONTINUOUS RESEND (w_inc=1) at
  // WlinkGenericFCReplayV2_13.v:193 -- exactly matching the already-silicon-
  // PROVEN sibling l2a sync (WlinkGenericFCSM_6.v:1081 ties w_inc=1'h1) that
  // instantiates this same shared module. With the source re-pushing the correct
  // value every cycle, a torn raddr self-heals within ~1 round-trip, so this
  // latch must accept EVERY fresh delivery unconditionally. The b969537 reset-
  // skew gate (raddr_rst) above is RETAINED (cures the bring-up instance).
  // ===========================================================================
  always @(posedge r_clk or posedge raddr_rst) begin
    if (raddr_rst) begin
      raddr <= 5'h0;
    end else if (addrsync_r_ready) begin
      raddr <= addrsync_r_data;
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
  raddr = _RAND_0[4:0];
`endif // RANDOMIZE_REG_INIT
  if (raddr_rst) begin
    raddr = 5'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
