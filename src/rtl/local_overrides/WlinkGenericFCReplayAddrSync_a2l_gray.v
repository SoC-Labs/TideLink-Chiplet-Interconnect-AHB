// =============================================================================
// TIDELINK a2l ACK-pointer GRAY-CODED sync (structural fix) -- David Mapstone 2026-07-08
//
// The stock WlinkGenericFCReplayAddrSync_18 wraps WavMultibitSync (a 2-deep
// ping-pong mailbox) to carry the 5-bit a2l ACK pointer link_clk -> app_clk.
// On die_a's async clock ratio the multibit transfer TEARS, delivering an
// all-ones lap-ahead value (synced_ack=0x1f) into the app domain -> the gray
// "exactly-full" test reads FALSE-FULL -> app_ready=0 -> die_a TX stalls after
// ~6-15 words (the persistent A->B blocker). Three recovery-style fixes (raddr
// clamp, w_inc=1 self-heal, coherent mailbox reset) each sim-validated but did
// NOT hold on silicon: a torn multibit binary value can lap, and once app_ready
// drops the mailbox can deadlock so nothing re-delivers.
//
// STRUCTURAL FIX (make the tear IMPOSSIBLE, not merely recoverable): sync a
// GRAY-CODED pointer with a plain 2-flop synchroniser. Provided the source
// advances by AT MOST ONE per step (guaranteed by the +1/step SERIALISER in
// WlinkGenericFCReplayV2_13.v that drives w_addr), exactly one Gray bit changes
// per step, so a metastable capture can only resolve to the CURRENT or the
// IMMEDIATELY-PREVIOUS value -- an off-by-one, NEVER a lap-ahead 0x1f. An
// off-by-one errs on the CONSERVATIVE side (ACK appears one behind -> over-
// reports fullness by one slot -> a harmless 1-cycle backpressure), and can
// never appear AHEAD of the true value, so it can never falsely assert full.
// This eliminates the class. w_inc is accepted for port-compatibility but
// unused (a Gray 2-flop sync is free-running). Keeps the b969537 reset-skew
// gate. A2L-SCOPED ONLY -- the l2a / FCSM AddrSync instances feed pointers with
// no +1 rate limiter and must keep the stock module (Gray without the +1
// guarantee would tear THERE).
// =============================================================================
module WlinkGenericFCReplayAddrSync_a2l_gray(
  input        w_clk,
  input        w_reset,
  input        w_inc,     // unused (free-running Gray sync); kept for port compat
  input  [4:0] w_addr,
  input        r_clk,
  input        r_reset,
  output [4:0] r_addr
);
  function [4:0] b2g(input [4:0] b);
    b2g = b ^ (b >> 1);
  endfunction
  function [4:0] g2b(input [4:0] g);
    integer i; reg [4:0] bb;
    begin
      bb[4] = g[4];
      for (i = 3; i >= 0; i = i - 1) bb[i] = bb[i+1] ^ g[i];
      g2b = bb;
    end
  endfunction

  wire _unused_w_inc = w_inc;

  // Write side: Gray-encode the (+1/step) pointer in the link domain.
  reg [4:0] w_gray;
  always @(posedge w_clk or posedge w_reset) begin
    if (w_reset) w_gray <= 5'h0;
    else         w_gray <= b2g(w_addr);
  end

  // b969537 reset-skew gate: hold the read side in reset until BOTH the write
  // (link) and read (app) domain resets have released (async-assert/sync-
  // deassert of w_reset into r_clk), so a skewed release cannot latch garbage.
  reg wrst_meta, wrst_sync;
  always @(posedge r_clk or posedge w_reset) begin
    if (w_reset) begin wrst_meta <= 1'b1; wrst_sync <= 1'b1; end
    else         begin wrst_meta <= 1'b0; wrst_sync <= wrst_meta; end
  end
  wire sync_rst = r_reset | wrst_sync;

  // Read side: plain 2-flop synchroniser of the Gray value, then decode.
  reg [4:0] g_meta, g_sync;
  always @(posedge r_clk or posedge sync_rst) begin
    if (sync_rst) begin g_meta <= 5'h0; g_sync <= 5'h0; end
    else          begin g_meta <= w_gray; g_sync <= g_meta; end
  end
  assign r_addr = g2b(g_sync);
endmodule
