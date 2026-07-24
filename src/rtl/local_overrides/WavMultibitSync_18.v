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
module WavMultibitSync_18(
  input        w_clk,
  input        w_reset,
  input        w_inc,
  input  [4:0] w_data,
  output       w_ready,
  input        r_clk,
  input        r_reset,
  input        r_inc,
  output [4:0] r_data,
  output       r_ready
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
  reg [31:0] _RAND_3;
`endif // RANDOMIZE_REG_INIT
  wire  wptr_rclk_demet_clock; // @[Stdcell.scala 58:23]
  wire  wptr_rclk_demet_reset; // @[Stdcell.scala 58:23]
  wire  wptr_rclk_demet_io_in; // @[Stdcell.scala 58:23]
  wire  wptr_rclk_demet_io_out; // @[Stdcell.scala 58:23]
  wire  rptr_wclk_demet_clock; // @[Stdcell.scala 58:23]
  wire  rptr_wclk_demet_reset; // @[Stdcell.scala 58:23]
  wire  rptr_wclk_demet_io_in; // @[Stdcell.scala 58:23]
  wire  rptr_wclk_demet_io_out; // @[Stdcell.scala 58:23]
  reg [4:0] mem_0; // @[Components.scala 614:73]
  reg [4:0] mem_1; // @[Components.scala 614:73]
  reg  wptr; // @[Components.scala 617:73]
  reg  rptr; // @[Components.scala 622:73]
  wire  we = w_inc & w_ready; // @[Components.scala 630:24]

  // ===========================================================================
  // TIDELINK LOCAL OVERRIDE (cross-domain-coherent mailbox reset) 2026-07-07
  //
  // SILICON BUG (a2l ACK-ptr sync, obs 0x2158): after ~6 A->B words the app-side
  // synced ACK wedges at raddr=0x1f (a full lap ahead of wbin=15) -> false
  // a2l_full -> app_ready=0 -> die_a TX permanently stalls (A->B caps at 6).
  // Neither a raddr forward-clamp NOR continuous resend (w_inc=1) recovered it,
  // because the corruption is a PING-PONG POINTER-PARITY DESYNC, not a torn
  // value: this mailbox's two halves reset from DIFFERENT clock domains
  // (w_reset=link_reset, r_reset=app_reset). A mid-stream single-domain reset
  // re-pulse (SWI_RECAL / L9b re-anchor / data-mode swreset) or a skewed re-
  // release leaves wptr/rptr at inconsistent parity while mem holds a stale
  // (pre-wrap, bit[4]=1) value. The reader then latches r_data from the wrong/
  // stale slot (=0x1f) AND the ping-pong can land in w_ready=0 & r_ready=0
  // simultaneously -> DEADLOCK: the writer can't push (we=w_inc & w_ready=0) so
  // even w_inc=1 cannot re-deliver -> permanent. The b969537 fix guarded only
  // the raddr reset VALUE in the wrapper, not this mailbox's internal pointers.
  //
  // FIX: reset synchronisers (async-assert / sync-deassert) carry each domain's
  // reset into the other; reset BOTH halves only when BOTH domains' resets have
  // released. A single-domain reset now resets wptr, rptr, both mems and both
  // demets COHERENTLY -> the pointers can never emerge at inconsistent parity ->
  // no stale-slot read, no deadlock. Data never flows until both resets are long
  // released, so holding the mailbox at a clean 0 across the skew window loses no
  // ACK. Shared module (a2l + l2a syncs, both dies) -> only hardens; die_b's
  // working B->A cannot regress. Idle single-clock sim never desyncs the pointers
  // (passes either way) -> silicon is the verifier.
  // ===========================================================================
  reg wrst_meta_r, wrst_sync_r;               // w_reset (link) -> r_clk domain
  always @(posedge r_clk or posedge w_reset) begin
    if (w_reset) begin wrst_meta_r <= 1'b1; wrst_sync_r <= 1'b1; end
    else         begin wrst_meta_r <= 1'b0; wrst_sync_r <= wrst_meta_r; end
  end
  reg rrst_meta_w, rrst_sync_w;               // r_reset (app)  -> w_clk domain
  always @(posedge w_clk or posedge r_reset) begin
    if (r_reset) begin rrst_meta_w <= 1'b1; rrst_sync_w <= 1'b1; end
    else         begin rrst_meta_w <= 1'b0; rrst_sync_w <= rrst_meta_w; end
  end
  wire w_reset_coh = w_reset | rrst_sync_w;   // write half: reset until BOTH released
  wire r_reset_coh = r_reset | wrst_sync_r;   // read  half: reset until BOTH released

  WavDemetReset wptr_rclk_demet ( // @[Stdcell.scala 58:23]
    .clock(wptr_rclk_demet_clock),
    .reset(wptr_rclk_demet_reset),
    .io_in(wptr_rclk_demet_io_in),
    .io_out(wptr_rclk_demet_io_out)
  );
  WavDemetReset rptr_wclk_demet ( // @[Stdcell.scala 58:23]
    .clock(rptr_wclk_demet_clock),
    .reset(rptr_wclk_demet_reset),
    .io_in(rptr_wclk_demet_io_in),
    .io_out(rptr_wclk_demet_io_out)
  );
  assign w_ready = ~(rptr_wclk_demet_io_out ^ wptr); // @[Components.scala 629:18]
  assign r_data = rptr ? mem_1 : mem_0; // @[Components.scala 636:15 Components.scala 636:15]
  assign r_ready = rptr ^ wptr_rclk_demet_io_out; // @[Components.scala 634:23]
  assign wptr_rclk_demet_clock = r_clk;
  assign wptr_rclk_demet_reset = r_reset_coh; // @[Components.scala 623:52] (coherent)
  assign wptr_rclk_demet_io_in = wptr; // @[Stdcell.scala 59:17]
  assign rptr_wclk_demet_clock = w_clk;
  assign rptr_wclk_demet_reset = w_reset_coh; // @[Components.scala 626:52] (coherent)
  assign rptr_wclk_demet_io_in = rptr; // @[Stdcell.scala 59:17]
  always @(posedge w_clk or posedge w_reset_coh) begin
    if (w_reset_coh) begin
      mem_0 <= 5'h0;
    end else if (we) begin
      if (~rptr) begin
        mem_0 <= w_data;
      end
    end
  end
  always @(posedge w_clk or posedge w_reset_coh) begin
    if (w_reset_coh) begin
      mem_1 <= 5'h0;
    end else if (we) begin
      if (rptr) begin
        mem_1 <= w_data;
      end
    end
  end
  always @(posedge w_clk or posedge w_reset_coh) begin
    if (w_reset_coh) begin
      wptr <= 1'h0;
    end else begin
      wptr <= we ^ wptr;
    end
  end
  always @(posedge r_clk or posedge r_reset_coh) begin
    if (r_reset_coh) begin
      rptr <= 1'h0;
    end else begin
      rptr <= rptr ^ r_inc & r_ready;
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
  mem_0 = _RAND_0[4:0];
  _RAND_1 = {1{`RANDOM}};
  mem_1 = _RAND_1[4:0];
  _RAND_2 = {1{`RANDOM}};
  wptr = _RAND_2[0:0];
  _RAND_3 = {1{`RANDOM}};
  rptr = _RAND_3[0:0];
`endif // RANDOMIZE_REG_INIT
  if (w_reset) begin
    mem_0 = 5'h0;
  end
  if (w_reset) begin
    mem_1 = 5'h0;
  end
  if (w_reset) begin
    wptr = 1'h0;
  end
  if (r_reset) begin
    rptr = 1'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
