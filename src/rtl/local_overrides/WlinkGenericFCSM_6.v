// =============================================================================
// SoC Labs L7 sticky-NACK bringup recovery (2026-05-26): forgive send_nack_req
// during the credit-handshake window so a transient isNotExpPacket from the
// bringup recal sequence cannot wedge the FCSM at SEND_NACK (state 7).
// -----------------------------------------------------------------------------
// HW failure mode observed on tdif-12 (sub 1353f83 + L6 producer fix, build
// post-2026-05-26 bringup_pair_converge):
//   * Both peers now exchange CR + CRACK successfully (cr_pkt_seen_rx=1 and
//     crack_pkt_seen_rx=1 on both sides — the asymmetric CR-loss class from
//     L6 is eliminated).
//   * BUT master FCSM wedges at state 7 (SEND_NACK) with CRC error counter =
//     0.  Slave FCSM sits at state 4 (LINK_IDLE) waiting for master to leave
//     SEND_NACK.  Polarity flipped vs tdif-05 (which had slave stuck at 7).
//   * Both sides observe NO actual CRC error and NO actual packet corruption
//     in the steady-state baseline — yet send_nack_req is latched high.
//
// Root cause (FC.scala lines ~439, 505, 538, 571, 586; this file lines
// ~911-925 of upstream and ~981-995 here):
//   reg send_nack_req;
//   always @(posedge io_tx_clk) begin
//     if (_ack_seen_before_T) send_nack_req <= send_nack_req | (crcCorruptSeen | isNotExpPacket_l7) /* SoC Labs L7 masked NotExp */;
//     else if (state == 3'h1) ... same OR-only set ...
//     else if (state == 3'h2) ... same ...
//     else if (state == 3'h3) ... same ...
//     else                    send_nack_req <= _GEN_172;  // GEN_172 only clears in state==4
//   end
// Whenever the rx framer transitions during bringup (slot0 recal flip, IDELAY
// re-tap, demet metastability), the rx_pkt sequence can momentarily decode
// as not-the-expected-sequence-position.  The FC layer enqueues a notifier
// with pkttypenotifier=3'h1 into ack_nack_fifo.  Once that readout fires
// (`ack_nack_fifo_io_rinc = ack_nack_fifo_valid & state != 3'h0`),
// `isNotExpPacket` pulses for one cycle and latches `send_nack_req <= 1`.
//
// The recovery path (state 4 → state 7 → emit NACK → auto_tx_out_advance →
// state 4 → _GEN_71 clears send_nack_req) IS implemented, but on HW it does
// not converge because:
//   (a) bringup_pair_converge's recal cycle keeps pushing fresh isNotExpPacket
//       notifiers into the fifo faster than state 7 can drain them, AND
//   (b) the peer is at LINK_IDLE waiting to see normal data-id traffic, so
//       it does not acknowledge NACK packets in a way that lets either side
//       progress to LINK_DATA — the link is bidirectionally healthy but the
//       FCSM is wedged on a stale bringup artifact.
//
// L7 fix: introduce a "bringup forgive" gate that
//   (1) latches `socl_l7_reached_link_data` once FCSM has ever observed
//       state == LINK_DATA (state 5) — this permanently disarms the gate
//       after a successful initial bringup, so steady-state errors behave
//       exactly like upstream.
//   (2) computes `socl_l7_bringup_forgive = !reached_link_data &
//                 cr_pkt_seen_tx_demet_io_out & crack_pkt_seen_tx_demet_io_out`
//       — only forgives once the bidirectional credit-handshake observation
//       sticky bits prove the link is structurally healthy.
//   (3) AND-clears `send_nack_req` synchronously in ALL states whenever
//       forgive is asserted, draining the bringup latches.
//   (4) ALSO masks `isNotExpPacket` while forgive is asserted, so a fresh
//       readout from a stale fifo entry cannot re-latch send_nack_req on
//       the same cycle.  `crcCorruptSeen` is NOT masked — a real CRC error
//       during bringup still latches NACK (correct behaviour).
//
// Safety properties:
//   * Steady-state behaviour unchanged once state 5 has been observed once.
//   * Genuine CRC errors during bringup still latch send_nack_req.
//   * The forgive gate is gated on the same observation sticky bits that
//     proved the asymmetric-CR-loss bug is gone — so L7 only activates in
//     a regime where the link IS already healthy and the NACK is a stale
//     bringup artifact.
//   * No new clock domain crossings: forgive is driven from existing
//     io_tx_clk-domain synchronized sticky bits.
//
// =============================================================================
// SoC Labs L6 producer-side fix (2026-05-26): minimum CR-emit hold in state==1
// -----------------------------------------------------------------------------
// Bug class observed in cocotb wlink_pair fuzz (6/12 scenarios fail):
//   * Master starts bring-up 2 cycles before slave (lock_master then lock_slave)
//   * Slave's RX framer (WlinkRxLinkLayer / LL_RX) byte-aligns FIRST and decodes
//     master's CR(0x44) packets — cr_pkt_seen_rx latches on slave side.
//   * That tx-synchronizes to cr_pkt_seen_tx_demet_io_out=1 → _GEN_34 fires →
//     slave's FCSM transitions state 1 → state 2 within ~500 master clks of
//     entering state 1.  Slave then stops emitting CR(0x44) (state 2 only
//     emits CRACK(0x45)).
//   * Master's RX framer is still hunting for byte-align at that point.  By
//     the time master's framer locks, slave is no longer producing CR, so
//     master.cr_pkt_seen_rx never latches.  Master's FCSM stalls at LINK_IDLE
//     because credits never properly cross.
//
// Root cause: state 1 → state 2 transition (FC.scala _GEN_34) fires as soon as
// EITHER cr_seen OR crack_seen latches on the tx-domain synchronizer.  This
// is correct in the SYMMETRIC case (both RX framers lock within the same CR
// burst) but fails ASYMMETRICALLY when one side's framer locks much earlier
// than the other.  Master's RX framer needs time to byte-align; slave's
// state 1 exit is too aggressive and "shuts the door" on master's framer.
//
// Producer-side fix (this file): introduce socl_l6_cr_emit_count counter
// that increments on each (auto_tx_out_advance & sop & state==1) cycle, and
// gate _GEN_34 on that count reaching at least SOCL_L6_MIN_CR_EMITS.  This
// guarantees the FCSM emits a minimum number of CR packets before allowing
// state 1 exit — giving the peer's RX framer time to lock onto a CR packet.
//
// This does NOT change behavior in the symmetric case: in steady state both
// sides will emit at least MIN CR before any cr_seen/crack_seen latches; with
// the synchronizer+framer latency the gate is already met by the time the
// peer reaches state 2.  In the asymmetric case the gate keeps slave emitting
// CR for the full MIN window, ensuring master's RX framer (now byte-aligning)
// can latch onto a CR.
//
// MIN value (32) chosen: well below the ~500-cycle state 1 window in the
// failing scenarios (slave naturally stayed in state 1 for cyc 67..563 = 496
// cycles in the failing fuzz scenario, so 32 is comfortably within that
// window and adds <5% to the bring-up critical path).  Synthesizable as a
// localparam.
//
// =============================================================================
// SoC Labs F-1 state-7 watchdog (2026-05-29): self-recovering NACK clear
// -----------------------------------------------------------------------------
// HW failure mode observed on build #4 (ILA-inserted, 5/5 deploys wedged):
//   * Master FCSM wedges at state 7 (SEND_NACK), slave at state 4, both
//     sides report 0 real CRC errors -- send_nack_req latched by a spurious
//     bring-up isNotExpPacket notifier that the L7 forgive gate above did
//     NOT manage to clear in time.
//   * The existing L7 `socl_l7_bringup_forgive` gate ANDs two rx-domain
//     demet stickies (cr_pkt_seen_tx_demet & crack_pkt_seen_tx_demet).
//     Build #4's P&R/ILA-insertion placement moved master's crack_pkt_seen_rx
//     latch downstream of slave's state-2 exit, so the AND never fires.
//     Build #3 won the routing lottery; build #4 lost it.  ASIC will draw
//     a fresh ticket: the existing gate is not reliable post-CTS.
//   * See docs/BUILD4_HW_VALIDATION_2026_05_29.md and
//     docs/FCSM_L7_WEDGE_FIX_PROPOSAL_2026_05_29.md.
//
// Watchdog mechanism:
//   (1) `socl_l7_real_crc_seen` is a sticky bit that latches if a real
//       crcCorruptSeen pulse is ever observed in any state since reset.
//       Once high, stays high until reset -- production silicon with
//       genuine link errors disarms the watchdog permanently.
//   (2) `socl_l7_wdog_cnt` is a 16-bit counter that increments while
//       state == 3'h7 AND the real-CRC sticky is low.  The counter resets
//       to 0 the cycle state != 3'h7, and saturates at the threshold.
//       (Saturating rather than wrapping avoids a second false-trip.)
//   (3) `socl_l7_wdog_force_clear` fires when the counter reaches
//       SOCL_L7_WDOG_THRESHOLD = 16'h4000 (~660 us @ 100 MHz; ~30 us @
//       2 GHz ASIC) and the real-CRC sticky is still low.  When asserted,
//       it AND-clears send_nack_req in the synchronous state machine.
//
// Threshold rationale (16'h4000 = 16384 cycles):
//   * State 7 dwell on a healthy link is ~tens of cycles (emit NACK,
//     auto_tx_out_advance, fall to state 4).  16'h4000 is ~500x that
//     dwell, so legitimate NACK transmissions are never affected.
//   * 660 us @ 100 MHz is well above PHY-align settling time (single
//     digit ms typical) and well below any reasonable upper-layer
//     timeout, so the recovery is invisible to AHB/AXI fabric.
//
// Why crcCorruptSeen masks the watchdog:
//   * `crcCorruptSeen` (line 322) is the only ack_nack_fifo dequeue tag
//     (3'h4) that proves a real link error (CRC mismatch).  If ANY real
//     CRC error has ever occurred since reset, the watchdog stays disarmed
//     forever -- so the SEND_NACK state is never spuriously short-circuited
//     in production silicon with genuine link corruption.
//   * `isNotExpPacket` (tag 3'h1) is NOT a CRC error -- it is a pkt-num
//     sequencing notifier that can fire spuriously during bring-up while
//     the demet/framer is settling.  The watchdog is designed to clear
//     exactly that spurious-NACK class.
//
// Steady-state safety:
//   * The watchdog only ticks while state == 3'h7.  On a healthy link,
//     state 7 is exited within tens of cycles, the counter resets, and
//     the watchdog never fires.
//   * After the first state-5 visit (LINK_DATA reached), the existing
//     `socl_l7_reached_link_data` sticky also disarms the bringup_forgive
//     gate.  Behaviour is identical to upstream once steady state begins.
//   * If a real CRC error EVER occurs (even after first LINK_DATA),
//     `socl_l7_real_crc_seen` latches and the watchdog stays disarmed
//     for the lifetime of the reset cycle.
//
// =============================================================================
module WlinkGenericFCSM_6 #(
  parameter [7:0]  SOCL_L6_MIN_CR_EMITS    = 8'd32,
  // SoC Labs L7 (2026-06-19): minimum CRACK-emit hold, symmetric to the L6
  // min-CR-emit gate. See socl_l7_crack_release below for the deadlock it fixes.
  parameter [7:0]  SOCL_L7_MIN_CRACK_EMITS = 8'd32,
  parameter [15:0] SOCL_L7_WDOG_THRESHOLD  = 16'h4000,
  // SoC Labs credit-recovery (2026-06-05): receiver-side periodic ACK
  // re-emission idle threshold (io_tx_clk cycles). Chosen comfortably larger
  // than the healthy ACK cadence (~tens of io_tx_clk cycles between data
  // packets) so it only fires after the credit-return stream has truly stopped
  // (sustained ACK loss), never disturbing a live link.
  parameter [15:0] SOCL_REACK_THRESHOLD    = 16'h0100,
  // SoC Labs L9b BOUNDED FORWARD RE-ANCHOR (2026-06-28): the forward-gap window
  // and the post-re-anchor hold-down. SOCL_L9B_FWD_WINDOW=4 forgives an isolated
  // dropped/corrupted packet (or a short run of dropped slots inside one eye
  // glitch) but NOT a wild far jump or a backward stale-replay echo.
  // SOCL_L9B_HOLD_PKTS=8 rate-limits re-anchors to at most one per 8 data
  // packets so a sustained-skew burst cannot silently walk exp forward
  // one-slot-per-packet across the whole stream.
  parameter [3:0]  SOCL_L9B_FWD_WINDOW     = 4'd4,
  parameter [3:0]  SOCL_L9B_HOLD_PKTS      = 4'd8
) (
  input         clock,
  input         reset,
  input         auto_in_psel,
  input         auto_in_penable,
  input         auto_in_pwrite,
  input  [12:0] auto_in_paddr,
  input  [31:0] auto_in_pwdata,
  input  [3:0]  auto_in_pstrb,
  output        auto_in_pready,
  output [31:0] auto_in_prdata,
  input         auto_rx_in_sop,
  input  [7:0]  auto_rx_in_data_id,
  input  [15:0] auto_rx_in_word_count,
  input  [55:0] auto_rx_in_data,
  input         auto_rx_in_valid,
  input  [15:0] auto_rx_in_crc,
  output        auto_tx_out_sop,
  output [7:0]  auto_tx_out_data_id,
  output [15:0] auto_tx_out_word_count,
  output [55:0] auto_tx_out_data,
  output [15:0] auto_tx_out_crc,
  input         auto_tx_out_advance,
  input         io_app_clk,
  input         io_app_reset,
  input         io_app_enable,
  input         io_app_a2l_valid,
  input  [47:0] io_app_a2l_data,
  output        io_app_a2l_ready,
  output        io_app_l2a_valid,
  output [47:0] io_app_l2a_data,
  input         io_app_l2a_accept,
  input         io_tx_clk,
  input         io_tx_reset,
  input         io_rx_clk,
  input         io_rx_reset,
  output        io_rx_crc_err,
  // SoC Labs credit-path observability (read-only APB exposure of the FC
  // state machine — replaces the ILA debug core). These mirror existing
  // internal nets; promoting them to outputs is structurally free.
  //   io_obs_state          : FC state machine `state` (io_tx_clk domain;
  //                           wedges at 1 in the bring-up failure).
  //   io_obs_cr_pkt_seen_rx : sticky cr-pkt-seen (io_rx_clk domain; the
  //                           0e126b0 sticky-reset fix is read as-is).
  //   io_obs_crack_pkt_seen_rx : sticky crack-pkt-seen (io_rx_clk).
  //   io_obs_pkt_is_cr_pkt / io_obs_pkt_is_crack_pkt : combinational
  //                           decode off auto_rx_in_* (io_rx_clk domain).
  // 2-flop-synced into apb_clk by axi_chiplet_controller.sv.
  output [2:0]  io_obs_state,
  output        io_obs_cr_pkt_seen_rx,
  output        io_obs_crack_pkt_seen_rx,
  output        io_obs_pkt_is_cr_pkt,
  output        io_obs_pkt_is_crack_pkt,
  // SoC Labs Bug-A FCSM observation 2026-06-02: expose the three signals that
  // gate the state 4→5 (LINK_IDLE → LINK_DATA) transition. Build #15 ILA
  // showed FCSM stuck at state 4 with skid loaded but ~ready; need to know
  // which gate is the cause.
  //   io_obs_a2l_replay_link_valid : link-clock-domain validity of TX FIFO
  //                                  data (a2l_fc_replay_link_valid, L321).
  //   io_obs_fe_rx_credit_max[7:0] : captured fe_rx_credit_max from CR/CRACK
  //                                  (rx-clk domain reg, L367).
  //   io_obs_fe_rx_is_full         : combinational full-gate (L436).
  output        io_obs_a2l_replay_link_valid,
  output [7:0]  io_obs_fe_rx_credit_max,
  output        io_obs_fe_rx_is_full,
  // SoC Labs Bug-A FCSM observation 2026-06-03: APP side of the a2l FIFO.
  // Build #20 showed link side stuck at 0; need app side to know whether
  // master fc_adapter is pushing pulses that the FIFO CDC then drops.
  output        io_obs_a2l_replay_app_valid,
  // SoC Labs V2 data-send observation 2026-06-21: the a2l replay buffer's
  // true `app_ready` and `link_empty`. Build evidence: a2l_replay_app_valid=1
  // (skid presents word) but a2l_replay_link_valid=0 (word never crossed into
  // the async FIFO). These two taps localize whether the FIFO write never
  // fires (app side: app_ready stuck low) vs. word crosses but link stalls
  // (link_empty). Both are PURE read-only fan-outs of existing internal nets.
  //   io_obs_a2l_replay_app_ready  : a2l_fc_replay_app_ready  (app-clk domain,
  //                                  wire L343, drives io_app_a2l_ready L942).
  //   io_obs_a2l_replay_link_empty : a2l_fc_replay_link_empty (link-clk domain,
  //                                  wire L354, from replay buffer link_empty).
  output        io_obs_a2l_replay_app_ready,
  output        io_obs_a2l_replay_link_empty,
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21: the a2l replay
  // buffer's raw internal pointers + both terms of app_ready. app_ready alone
  // did not localize the silicon false-FULL (two sim-proven fixes failed on
  // silicon), so expose the raw write ptr, the app-clk-synced ACK ptr, the
  // a2l_full flag, and the enable demet term. All app-clk domain, pure RO
  // fan-outs of WlinkGenericFCReplayV2_13 internals (NO functional change).
  //   io_obs_a2l_wptr[4:0]        : a2l_fc_replay.fifo_io_wbin_ptr (write ptr)
  //   io_obs_a2l_synced_ack[4:0]  : a2l_fc_replay.a2l_link_addr_app_clk (ACK ptr)
  //   io_obs_a2l_full             : a2l_fc_replay.a2l_full (false-FULL flag)
  //   io_obs_a2l_enable_app_demet : a2l_fc_replay.enable_app_clk_demet_io_out
  output [4:0]  io_obs_a2l_wptr,
  output [4:0]  io_obs_a2l_synced_ack,
  output        io_obs_a2l_full,
  output        io_obs_a2l_enable_app_demet,
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21:
  // the a2l replay buffer's raw read-side reset and LINK read binary pointer.
  // app_ready/wptr localized the false-FULL to the write side; these two say
  // whether the read side is HELD in reset (link_empty=1 forever) vs the write-
  // ptr sync into the read domain is broken. Pure RO fan-outs of
  // WlinkGenericFCReplayV2_13 internals (NO functional change).
  //   io_obs_a2l_rreset          : a2l_fc_replay.link_reset (== fifo_io_rreset)
  //   io_obs_a2l_rptr[4:0]       : a2l_fc_replay.fifo_io_rbin_ptr (link read ptr)
  output        io_obs_a2l_rreset,
  output [4:0]  io_obs_a2l_rptr,
  // SoC Labs FC credit observation 2026-06-12: far-end RX credit pointer
  // (io_tx_clk domain reg, updated from ACK/NACK packets at L1293). Together
  // with io_obs_fe_rx_credit_max this lets SW see a CR credit value that
  // garbled to a SMALL NONZERO number (fe_rx_is_full only flags the ==0
  // case) — the link "works" for 1-4 packets then wedges.
  output [7:0]  io_obs_fe_rx_ptr,
  // SoC Labs PER-BEAT PKTNUM CAPTURE 2026-07-01 (beatcap) — a 32-entry, ONE-
  // ENTRY-PER-io_rx_clk-cycle-while-auto_rx_in_valid ring that FREEZES when full.
  // Purpose: root-cause the silicon multi-packet A->B OVER-ADVANCE where
  // exp_pkt_num races ~5x per app packet. This gives CYCLE-ACCURATE per-beat
  // visibility of {ll_rx_pktnum, exp_pkt_num, flags} so SW can see whether the
  // received pktnum WALKS across the ~5 held-valid word-beats of one packet.
  //
  //   io_cap_arm      : LEVEL from an apb_clk-domain SWI reg (axi_chiplet_
  //                     controller swi_capbeat_arm_r). 2-flop synced into
  //                     io_rx_clk here; a RISING EDGE clears wptr/frozen and
  //                     re-arms the ring. Holding it high keeps the (already
  //                     frozen) buffer stable for readout.
  //   io_cap_rptr     : LEVEL from an apb_clk-domain read pointer (axi_chiplet_
  //                     controller capbeat_rptr_r). Selects which of the 32
  //                     frozen entries io_obs_capdata presents. The buffer is
  //                     FROZEN before readout, so this is a slow pointer into
  //                     stable data — CDC-safe (quasi-static, same treatment as
  //                     swi_dist_lane_sel_r).
  //   io_obs_capdata  : the selected 32-bit packed entry (see bit-packing below).
  //   io_obs_capstat  : {frozen, 2'b0, wptr[5:0]} status (wptr is the fill count,
  //                     0..32). 2-flop-synced to apb_clk by the controller.
  input         io_cap_arm,
  input  [4:0]  io_cap_rptr,
  output [31:0] io_obs_capdata,
  output [8:0]  io_obs_capstat,
  // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap) — one
  // packed 32-bit word that latches, in the io_rx_clk domain (recovered RX,
  // same domain as cr_pkt_seen_rx), the FCSM-side delivery events for a
  // sustained A->B long-DATA send. Distinguishes the FCSM one-shot-resync
  // failure mode (SOP fine but pktnum mismatch after pkt1) from a clean
  // delivery. Pure read-only fan-out of internal FCSM nets — datapath
  // unchanged. 2-flop-synced to apb_clk by axi_chiplet_controller.sv and read
  // at the new Region D (SoC MMIO 0x4403_21A8). See the rxcap block below.
  output [31:0] io_obs_fcsmcap
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
  reg [31:0] _RAND_3;
  reg [31:0] _RAND_4;
  reg [31:0] _RAND_5;
  reg [31:0] _RAND_6;
  reg [31:0] _RAND_7;
  reg [31:0] _RAND_8;
  reg [31:0] _RAND_9;
  reg [31:0] _RAND_10;
  reg [31:0] _RAND_11;
  reg [31:0] _RAND_12;
  reg [31:0] _RAND_13;
  reg [31:0] _RAND_14;
  reg [31:0] _RAND_15;
  reg [31:0] _RAND_16;
  reg [63:0] _RAND_17;
  reg [31:0] _RAND_18;
  reg [31:0] _RAND_19;
  reg [31:0] _RAND_20;
  reg [31:0] _RAND_21;
  reg [31:0] _RAND_22;
  reg [31:0] _RAND_23;
  reg [31:0] _RAND_24;
  reg [31:0] _RAND_25;
  reg [31:0] _RAND_26;
  reg [31:0] _RAND_27;
  reg [31:0] _RAND_28;
  reg [31:0] _RAND_29;
  reg [31:0] _RAND_30;
  reg [31:0] _RAND_31;
`endif // RANDOMIZE_REG_INIT
  wire [55:0] rx_crc_computed_crcgen_io_in; // @[LinkLayer.scala 1274:24]
  wire [15:0] rx_crc_computed_crcgen_io_out; // @[LinkLayer.scala 1274:24]
  wire  en_ff2_rx_demet_clock; // @[Stdcell.scala 58:23]
  wire  en_ff2_rx_demet_reset; // @[Stdcell.scala 58:23]
  wire  en_ff2_rx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  en_ff2_rx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  l2a_fc_replay_app_clk; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_reset; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_enable; // @[FC.scala 219:43]
  wire [47:0] l2a_fc_replay_app_data; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_valid; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_ready; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_clk; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_reset; // @[FC.scala 219:43]
  wire [4:0] l2a_fc_replay_link_ack_addr; // @[FC.scala 219:43]
  wire [4:0] l2a_fc_replay_link_cur_addr; // @[FC.scala 219:43]
  wire [47:0] l2a_fc_replay_link_data; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_valid; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_advance; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_empty; // @[FC.scala 219:43]
  wire  l2a_fifo_addr_to_tx_w_clk; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_w_reset; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_w_inc; // @[FC.scala 241:43]
  wire [4:0] l2a_fifo_addr_to_tx_w_addr; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_r_clk; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_r_reset; // @[FC.scala 241:43]
  wire [4:0] l2a_fifo_addr_to_tx_r_addr; // @[FC.scala 241:43]
  wire  ack_nack_fifo_io_wclk; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_wreset; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_winc; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rclk; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rreset; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rinc; // @[FC.scala 260:41]
  wire [18:0] ack_nack_fifo_io_wdata; // @[FC.scala 260:41]
  wire [18:0] ack_nack_fifo_io_rdata; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_wfull; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rempty; // @[FC.scala 260:41]
  wire [2:0] ack_nack_fifo_io_swi_almost_empty; // @[FC.scala 260:41]
  wire [2:0] ack_nack_fifo_io_swi_almost_full; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_half_full; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_almost_empty; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_almost_full; // @[FC.scala 260:41]
  wire  a2l_fc_replay_app_clk; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_reset; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_enable; // @[FC.scala 297:43]
  wire [47:0] a2l_fc_replay_app_data; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_valid; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_ready; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_clk; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_reset; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_ack_update; // @[FC.scala 297:43]
  wire [4:0] a2l_fc_replay_link_ack_addr; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_revert; // @[FC.scala 297:43]
  wire [4:0] a2l_fc_replay_link_revert_addr; // @[FC.scala 297:43]
  wire [4:0] a2l_fc_replay_link_cur_addr; // @[FC.scala 297:43]
  wire [47:0] a2l_fc_replay_link_data; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_valid; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_advance; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_empty; // @[FC.scala 297:43]
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 (read-only fan-outs)
  wire [4:0] a2l_fc_replay_obs_a2l_wptr;
  wire [4:0] a2l_fc_replay_obs_a2l_synced_ack;
  wire  a2l_fc_replay_obs_a2l_full;
  wire  a2l_fc_replay_obs_enable_app_clk_demet;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  wire  a2l_fc_replay_obs_a2l_rreset;
  wire [4:0] a2l_fc_replay_obs_a2l_rptr;
  wire  en_ff2_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire [55:0] bundleOut_0_crc_crcgen_io_in; // @[LinkLayer.scala 1274:24]
  wire [15:0] bundleOut_0_crc_crcgen_io_out; // @[LinkLayer.scala 1274:24]
  wire [7:0] ll_rx_pktnum = auto_rx_in_data[7:0]; // @[FC.scala 123:33]
  reg [2:0] state; // @[FC.scala 143:91]
  wire  _crc_corrupt_T = auto_rx_in_sop & auto_rx_in_valid; // @[FC.scala 157:52]
  reg [7:0] swi_data_id_1; // @[SW.scala 83:22]
  wire  _crc_corrupt_T_2 = auto_rx_in_sop & auto_rx_in_valid & auto_rx_in_data_id == swi_data_id_1; // @[FC.scala 157:67]
  reg  out_prepend_swi_disable_crc; // @[SW.scala 83:22]
  wire  crc_corrupt = auto_rx_in_sop & auto_rx_in_valid & auto_rx_in_data_id == swi_data_id_1 & ~
    out_prepend_swi_disable_crc & rx_crc_computed_crcgen_io_out != auto_rx_in_crc; // @[FC.scala 157:40]
  reg [15:0] crc_errors; // @[FC.scala 160:107]
  wire  pkt_is_data_pkt = _crc_corrupt_T_2 & ~crc_corrupt; // @[FC.scala 166:85]
  // SoC Labs L9 consumer-side pktnum resync (2026-05-31): one-shot fast-
  // forward of exp_pkt_num to first observed ll_rx_pktnum + 1. Closes the
  // exp_pkt_num re-zero-vs-link_cur_addr race that latches send_nack_req
  // post L7 disarm. The masked-isNotExpPacket wire lives near the
  // isNotExpPacket_l7 declaration (see L450 region). Reg+wire declared
  // here for forward-reference by exp_pkt_not_seen_l9 at L373 and the
  // l2a_fc_replay_app_valid OR at L803.
  reg  socl_l9_first_data_seen_rx;
  // SoC Labs L9b BOUNDED FORWARD RE-ANCHOR (2026-06-28): re-armable hold-down
  // counter for the isolated-gap re-anchor. Decremented each io_rx_clk data
  // packet after a re-anchor fires; while non-zero the re-anchor is DISARMED
  // (so a burst of consecutive mismatches cannot thrash exp_pkt_num forward
  // one-per-packet). Declared here (bare reg, no init expr -> no forward-ref);
  // the combinational re-anchor wires that read exp_pkt_num/ll_rx_pktnum/
  // fe_tx_credit_max are defined AFTER those regs (~L483) to satisfy VCS
  // default_nettype none declaration-before-use (the prior L9b forward-ref bug).
  reg  [3:0] socl_l9b_hold;
  // SoC Labs 2026-06-21: L9b (re-anchor on ANY pktnum gap) REVERTED. It referenced
  // exp_pkt_num/ll_rx_pktnum BEFORE their declaration; Vivado tolerated the forward-ref
  // (so the L9b bitstreams built) but VCS rejects it -> it silently broke the V2 sim
  // compile, i.e. L9b was deployed without ever passing a sim gate. Moreover the real
  // data blocker is the marginal EYE, not pktnum: test_v2_reduced_lane delivers the long
  // packet byte-correct over the 0xE4 mask in bit-perfect sim (framer/gather/commit sound).
  // L9 one-shot first-data resync restored (sim-clean, no forward reference).
  wire socl_l9_resync_now = pkt_is_data_pkt & ~socl_l9_first_data_seen_rx;
  wire  valid_rx_pkt_crc_err = _crc_corrupt_T_2 & crc_corrupt; // @[FC.scala 167:85]
  reg [7:0] swi_cr_id; // @[SW.scala 83:22]
  wire  pkt_is_cr_pkt = _crc_corrupt_T & auto_rx_in_data_id == swi_cr_id; // @[FC.scala 169:50]
  reg [7:0] out_prepend_swi_crack_id; // @[SW.scala 83:22]
  wire  pkt_is_crack_pkt = _crc_corrupt_T & auto_rx_in_data_id == out_prepend_swi_crack_id; // @[FC.scala 170:50]
  reg [7:0] out_prepend_swi_ack_id; // @[SW.scala 83:22]
  wire  pkt_is_ack_pkt = _crc_corrupt_T & auto_rx_in_data_id == out_prepend_swi_ack_id; // @[FC.scala 171:50]
  reg [7:0] out_prepend_swi_nack_id; // @[SW.scala 83:22]
  wire  pkt_is_nack_pkt = _crc_corrupt_T & auto_rx_in_data_id == out_prepend_swi_nack_id; // @[FC.scala 172:50]
  reg [7:0] last_good_pkt; // @[FC.scala 179:107]
  reg [7:0] fe_rx_credit_max; // @[FC.scala 183:107]
  // SoC Labs credit-ring CDC fix (Bug-C, 2026-06-05): fe_rx_credit_max is
  // WRITTEN in the io_rx_clk domain (loaded from the CR/CRACK 0x1f1f word_count)
  // but READ in the io_tx_clk domain to size the ne_rx_ptr / fe_rx_ptr credit
  // ring (ne_rx_ptr_next + fe_rx_ptr_msb below). That cross-domain read had NO
  // synchronizer. Add a 2-flop io_tx_clk synchronizer and route the tx-domain
  // ring math through fe_rx_credit_max_txsync so the ring modulus is sampled
  // cleanly in the tx domain.
  reg [7:0] fe_rx_credit_max_txsync_meta;
  reg [7:0] fe_rx_credit_max_txsync;
  reg  cr_pkt_seen_rx; // @[FC.scala 186:107]
  reg  crack_pkt_seen_rx; // @[FC.scala 188:107]
  reg [7:0] exp_pkt_num; // @[FC.scala 193:44]
  wire [15:0] _crc_errors_in_T_2 = crc_errors + 16'h1; // @[FC.scala 196:123]
  wire [15:0] _crc_errors_in_T_3 = crc_errors == 16'hffff ? crc_errors : _crc_errors_in_T_2; // @[FC.scala 196:73]
  wire [15:0] _crc_errors_in_T_4 = crc_corrupt ? _crc_errors_in_T_3 : crc_errors; // @[FC.scala 196:56]
  wire [15:0] crc_errors_in = en_ff2_rx_demet_io_out ? _crc_errors_in_T_4 : 16'h0; // @[FC.scala 196:41]
  reg [7:0] fe_tx_credit_max; // @[FC.scala 200:44]
  wire  _fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out; // @[FC.scala 201:42]
  wire  _fe_tx_credit_max_in_T_1 = pkt_is_cr_pkt | pkt_is_crack_pkt; // @[FC.scala 201:77]
  wire  exp_pkt_seen = pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num; // @[FC.scala 210:54]
  wire  exp_pkt_not_seen = pkt_is_data_pkt & ll_rx_pktnum != exp_pkt_num; // @[FC.scala 211:54]
  // SoC Labs L9: suppress spurious mismatch enqueue on the resync cycle so
  // the ack_nack_fifo does not carry a stale isNotExpPacket entry forward.
  //
  // SoC Labs L9b BOUNDED FORWARD RE-ANCHOR (2026-06-28) — RX-side wedge-immunity
  // for the marginal A->B GPIO eye.
  // ---------------------------------------------------------------------------
  // PROBLEM (silicon): under the marginal eye an isolated bit error corrupts a
  // received pktnum -> exp_pkt_not_seen -> ack_nack_fifo carries a 3'h1
  // (isNotExpPacket) entry -> send_nack_req -> FCSM state 7 -> NACK to die_a ->
  // die_a's a2l replay reverts its read pointer (a2l_fc_replay_link_revert) and
  // re-walks. exp_pkt_num is FROZEN on a mismatch (it only advances on
  // exp_pkt_seen), so every replayed packet mismatches the frozen exp -> a
  // NACK->revert->re-walk REPLAY STORM ratchets the credit ring to credit-max
  // -> sticky wedge (POR-only clear).
  //
  // LEVER: on an ISOLATED FORWARD gap (ll_rx_pktnum is a small number of slots
  // AHEAD of exp_pkt_num, the signature of a dropped/corrupted packet — NOT a
  // stale replay which carries a LOWER/equal pktnum), RE-ANCHOR exp_pkt_num
  // forward to ll_rx_pktnum+1 (accept the gap as best-effort loss), COMMIT the
  // freshly-anchored packet, and SUPPRESS the mismatch enqueue so NO NACK is
  // emitted -> die_a (unmodified old build) sees no NACK and never reverts ->
  // the storm cannot start. This is a pure RX (die_b) decision; die_a TX is
  // unchanged. Trades strict reliable-delivery for best-effort GPIO robustness.
  //
  // BOUNDING (anti-thrash, anti-garbage):
  //   * FORWARD-ONLY + WINDOWED: only fires when the modular distance
  //     (ll_rx_pktnum - exp_pkt_num) mod (fe_tx_credit_max+1) is in
  //     1..SOCL_L9B_FWD_WINDOW. A backward/equal mismatch (stale replay echo,
  //     or a wild corruption that lands far away) is NOT re-anchored -> it
  //     still NACKs exactly as upstream (correct: a real replay must be honoured,
  //     and a wild jump must not silently skip the whole credit ring of data).
  //   * RATE-LIMITED: after a re-anchor, socl_l9b_hold holds the re-anchor
  //     DISARMED for SOCL_L9B_HOLD_PKTS subsequent data packets, so a run of
  //     consecutive mismatches (e.g. a sustained skew, not an isolated glitch)
  //     cannot walk exp forward one-slot-per-packet (which would silently drop
  //     a long run of data). At most one re-anchor per HOLD_PKTS window.
  //   * NOT the first packet: the first-data case is already handled by the L9
  //     one-shot resync (socl_l9_resync_now); L9b only arms AFTER first data.
  //
  // Note vs the prior reverted L9b: that version forward-referenced
  // exp_pkt_num/ll_rx_pktnum and broke the VCS compile (never sim-gated). This
  // version is defined here, AFTER those regs, and is sim-gated (see
  // test_v2_multipkt_pktnum: clean 16/16 unchanged; eye-fault repro below).
  wire exp_pkt_not_seen_l9 = exp_pkt_not_seen & ~socl_l9_resync_now;
  // Modular forward distance of the received pktnum past the expected one, in
  // the credit-ring modulus (fe_tx_credit_max+1). fe_tx_credit_max is the wrap
  // bound used by exp_pkt_num itself (L1251), so this matches the ring the TX
  // walks. Computed on the {pktnum,exp} 8-bit values; the ring is <=32 so 8b is
  // ample headroom and no value can alias.
  wire [8:0] socl_l9b_ring_mod   = {1'b0, fe_tx_credit_max} + 9'h1;
  wire [8:0] socl_l9b_fwd_raw    = {1'b0, ll_rx_pktnum} + socl_l9b_ring_mod
                                   - {1'b0, exp_pkt_num};
  wire [8:0] socl_l9b_fwd_dist   = (socl_l9b_fwd_raw >= socl_l9b_ring_mod)
                                   ? (socl_l9b_fwd_raw - socl_l9b_ring_mod)
                                   : socl_l9b_fwd_raw;
  // Bounded, re-armable forward re-anchor decision (one io_rx_clk pulse):
  //   * a real data-pkt mismatch (exp_pkt_not_seen) that is NOT the L9 one-shot,
  //   * within the small forward window (1..SOCL_L9B_FWD_WINDOW),
  //   * with the hold-down counter expired (re-arm budget available),
  //   * and only after the link has actually started delivering (L9 one-shot
  //     already happened: socl_l9_first_data_seen_rx high).
  wire socl_l9b_reanchor_now = exp_pkt_not_seen
                               & ~socl_l9_resync_now
                               & socl_l9_first_data_seen_rx
                               & (socl_l9b_hold == 4'h0)
                               & (socl_l9b_fwd_dist >= 9'h1)
                               & (socl_l9b_fwd_dist <= {{5{1'b0}}, SOCL_L9B_FWD_WINDOW});
  wire [7:0] _exp_pkt_num_in_T_3 = exp_pkt_num + 8'h1; // @[FC.scala 212:132]
  wire [7:0] _last_good_pkt_in_T_1 = exp_pkt_seen ? exp_pkt_num : last_good_pkt; // @[FC.scala 213:62]
  wire [7:0] last_good_pkt_in = _fe_tx_credit_max_in_T ? 8'h0 : _last_good_pkt_in_T_1; // @[FC.scala 213:41]
  wire  ack_nack_fifo_valid = ~ack_nack_fifo_io_rempty; // @[FC.scala 261:35]
  wire  _ack_nack_fifo_io_winc_T = pkt_is_ack_pkt | pkt_is_nack_pkt; // @[FC.scala 264:51]
  // SoC Labs L9b: on a forward re-anchor cycle ALSO drop the mismatch from the
  // notifier so no isNotExpPacket (3'h1) entry is enqueued -> the TX side never
  // latches send_nack_req -> no NACK -> die_a never reverts. (The enqueue itself
  // is suppressed below via ack_nack_fifo_io_winc, so this is belt-and-braces:
  // even if an entry were written it would carry tag 3'h0, not 3'h1.)
  wire exp_pkt_not_seen_l9b = exp_pkt_not_seen_l9 & ~socl_l9b_reanchor_now;
  wire [2:0] _pkttypenotifier_T_1 = valid_rx_pkt_crc_err ? 3'h4 : {{2'd0}, exp_pkt_not_seen_l9b}; // SoC Labs L9/L9b masked mismatch
  wire [2:0] _pkttypenotifier_T_2 = pkt_is_nack_pkt ? 3'h3 : _pkttypenotifier_T_1; // @[FC.scala 275:40]
  wire [2:0] pkttypenotifier = pkt_is_ack_pkt ? 3'h2 : _pkttypenotifier_T_2; // @[FC.scala 274:39]
  wire [18:0] _ack_nack_fifo_io_wdata_T_1 = {pkttypenotifier,auto_rx_in_word_count}; // @[Cat.scala 30:58]
  wire [18:0] _ack_nack_fifo_io_wdata_T_2 = {pkttypenotifier,8'h0,last_good_pkt_in}; // @[Cat.scala 30:58]
  wire  isExpPacket = ack_nack_fifo_io_rdata[18:16] == 3'h0 & ack_nack_fifo_valid; // @[FC.scala 287:73]
  wire  isNotExpPacket = ack_nack_fifo_io_rdata[18:16] == 3'h1 & ack_nack_fifo_valid; // @[FC.scala 288:73]
  wire  isAckPacket = ack_nack_fifo_io_rdata[18:16] == 3'h2 & ack_nack_fifo_valid; // @[FC.scala 289:73]
  wire  isNackPacket = ack_nack_fifo_io_rdata[18:16] == 3'h3 & ack_nack_fifo_valid; // @[FC.scala 290:73]
  wire  crcCorruptSeen = ack_nack_fifo_io_rdata[18:16] == 3'h4 & ack_nack_fifo_valid; // @[FC.scala 291:73]
  reg  sop; // @[FC.scala 318:48]
  reg [7:0] data_id; // @[FC.scala 320:48]
  reg [15:0] word_count; // @[FC.scala 322:48]
  reg [55:0] link_data; // @[FC.scala 324:48]
  reg [7:0] count; // @[FC.scala 331:48]
  wire [4:0] link_ack_addr = ack_nack_fifo_io_rdata[4:0]; // @[FC.scala 334:64]
  reg  ack_seen_before; // @[FC.scala 340:48]
  wire  _ack_seen_before_T = state == 3'h0; // @[FC.scala 341:53]
  wire [7:0] _GEN_315 = {{3'd0}, link_ack_addr}; // @[FC.scala 348:89]
  wire [4:0] _link_revert_addr_T_5 = link_ack_addr + 5'h1; // @[FC.scala 348:158]
  wire [4:0] _link_revert_addr_T_6 = _GEN_315 == 8'h1f ? 5'h0 : _link_revert_addr_T_5; // @[FC.scala 348:47]
  reg [7:0] fe_rx_ptr; // @[FC.scala 362:48]
  wire  _fe_rx_ptr_in_T = ~en_ff2_tx_demet_io_out; // @[FC.scala 363:46]
  reg [7:0] ne_rx_ptr; // @[FC.scala 366:48]
  wire [7:0] _ne_rx_ptr_next_T_2 = ne_rx_ptr + 8'h1; // @[FC.scala 368:95]
  // SoC Labs credit-ring CDC fix: tx-domain credit ring math reads the
  // io_tx_clk-synchronized copy fe_rx_credit_max_txsync (NOT the raw io_rx_clk
  // register fe_rx_credit_max) so the ring modulus is stable in the tx domain.
  wire [7:0] ne_rx_ptr_next = ne_rx_ptr == fe_rx_credit_max_txsync ? 8'h0 : _ne_rx_ptr_next_T_2; // @[FC.scala 368:45]
  wire [1:0] _GEN_2 = fe_rx_credit_max_txsync[2] ? 2'h2 : {{1'd0}, fe_rx_credit_max_txsync[1]}; // @[FC.scala 376:34 FC.scala 377:39]
  wire [1:0] _GEN_3 = fe_rx_credit_max_txsync[3] ? 2'h3 : _GEN_2; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] _GEN_4 = fe_rx_credit_max_txsync[4] ? 3'h4 : {{1'd0}, _GEN_3}; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] _GEN_5 = fe_rx_credit_max_txsync[5] ? 3'h5 : _GEN_4; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] _GEN_6 = fe_rx_credit_max_txsync[6] ? 3'h6 : _GEN_5; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] fe_rx_ptr_msb = fe_rx_credit_max_txsync[7] ? 3'h7 : _GEN_6; // @[FC.scala 376:34 FC.scala 377:39]
  wire  _GEN_8 = ne_rx_ptr_next[0] != fe_rx_ptr[0] ? 1'h0 : 1'h1; // @[FC.scala 387:51 FC.scala 388:41 FC.scala 384:39]
  wire  _GEN_9 = 3'h0 < fe_rx_ptr_msb ? _GEN_8 : 1'h1; // @[FC.scala 386:39 FC.scala 384:39]
  wire  _GEN_10 = ne_rx_ptr_next[1] != fe_rx_ptr[1] ? 1'h0 : _GEN_9; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_11 = 3'h1 < fe_rx_ptr_msb ? _GEN_10 : _GEN_9; // @[FC.scala 386:39]
  wire  _GEN_12 = ne_rx_ptr_next[2] != fe_rx_ptr[2] ? 1'h0 : _GEN_11; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_13 = 3'h2 < fe_rx_ptr_msb ? _GEN_12 : _GEN_11; // @[FC.scala 386:39]
  wire  _GEN_14 = ne_rx_ptr_next[3] != fe_rx_ptr[3] ? 1'h0 : _GEN_13; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_15 = 3'h3 < fe_rx_ptr_msb ? _GEN_14 : _GEN_13; // @[FC.scala 386:39]
  wire  _GEN_16 = ne_rx_ptr_next[4] != fe_rx_ptr[4] ? 1'h0 : _GEN_15; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_17 = 3'h4 < fe_rx_ptr_msb ? _GEN_16 : _GEN_15; // @[FC.scala 386:39]
  wire  _GEN_18 = ne_rx_ptr_next[5] != fe_rx_ptr[5] ? 1'h0 : _GEN_17; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_19 = 3'h5 < fe_rx_ptr_msb ? _GEN_18 : _GEN_17; // @[FC.scala 386:39]
  wire  _GEN_20 = ne_rx_ptr_next[6] != fe_rx_ptr[6] ? 1'h0 : _GEN_19; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_21 = 3'h6 < fe_rx_ptr_msb ? _GEN_20 : _GEN_19; // @[FC.scala 386:39]
  wire [7:0] _T_44 = ne_rx_ptr_next >> fe_rx_ptr_msb; // @[FC.scala 393:26]
  wire [7:0] _T_46 = fe_rx_ptr >> fe_rx_ptr_msb; // @[FC.scala 393:55]
  wire  fe_rx_is_full = _T_44[0] == _T_46[0] ? 1'h0 : _GEN_21; // @[FC.scala 393:71 FC.scala 394:39]
  reg [4:0] l2a_fifo_raddr_txclk_prev; // @[FC.scala 400:48]
  wire [4:0] l2a_fifo_raddr_txclk = l2a_fifo_addr_to_tx_r_addr; // @[FC.scala 240:41 FC.scala 249:35]
  wire  l2a_fifo_raddr_txclk_update = l2a_fifo_raddr_txclk_prev != l2a_fifo_raddr_txclk; // @[FC.scala 401:67]
  reg  send_ack_req; // @[FC.scala 407:48]
  reg  send_nack_req; // @[FC.scala 409:48]
  reg [7:0] last_good_pkt_from_rx; // @[FC.scala 414:48]
  wire [7:0] _last_good_pkt_from_rx_in_T_2 = isExpPacket ? ack_nack_fifo_io_rdata[7:0] : last_good_pkt_from_rx; // @[FC.scala 415:66]
  wire [7:0] last_good_pkt_from_rx_in = _fe_rx_ptr_in_T ? 8'h0 : _last_good_pkt_from_rx_in_T_2; // @[FC.scala 415:45]
  reg [7:0] last_ack_pkt_sent; // @[FC.scala 418:48]
  wire  _GEN_25 = en_ff2_tx_demet_io_out | sop; // @[FC.scala 449:24 FC.scala 450:39 FC.scala 427:39]
  // SoC Labs L6 producer-side fix: count CR emissions in state==1, gate exit.
  reg  [7:0] socl_l6_cr_emit_count; // counts (advance & sop) cycles while state==1
  wire socl_l6_cr_emit_gate_ok = (socl_l6_cr_emit_count >= SOCL_L6_MIN_CR_EMITS);
  // SoC Labs L7 (2026-06-19): minimum-CRACK-emit hold (mirror of the L6 gate).
  // ROOT CAUSE (4-agent root-cause + adversarial verify, clean-PHY bilateral
  // deadlock a[fcsm=4 cr=0 ck=1] b[fcsm=2 cr=1 ck=0]): the state-1->2 exit fires
  // on (cr_seen | crack_seen) (the OR-term in _GEN_34), but the state-2->3 exit
  // (_GEN_45) releases the instant crack_seen latches, with NO emit floor. A die
  // that left state 1 because it had ALREADY latched the peer's CRACK enters
  // state 2 with crack_pkt_seen already HIGH, so it emits exactly ONE CRACK then
  // runs 2->3->4 and parks in LINK_IDLE -- which never re-emits CRACK. That
  // one-shot CRACK is too short for the peer's (independently, later-aligning) RX
  // framer to capture, so the peer wedges in state 2 forever awaiting a CRACK
  // that is never re-sent. Fix: hold state 2 (and keep emitting CRACK) until BOTH
  // crack_seen AND a guaranteed minimum CRACK-emit count, exactly as the L6 gate
  // hardened the CR direction. socl_l7_crack_release replaces the bare
  // crack_pkt_seen_tx_demet_io_out in the state-2 advance muxes (_GEN_40..45).
  reg  [7:0] socl_l7_crack_emit_count; // counts (advance & sop) cycles while state==2
  wire socl_l7_crack_emit_gate_ok = (socl_l7_crack_emit_count >= SOCL_L7_MIN_CRACK_EMITS);
  wire socl_l7_crack_release = crack_pkt_seen_tx_demet_io_out & socl_l7_crack_emit_gate_ok;
  // SoC Labs L7 sticky-NACK bringup recovery:
  //   * socl_l7_reached_link_data : once high, disarms the forgive gate
  //     permanently for the lifetime of this reset cycle (steady-state).
  //   * socl_l7_bringup_forgive   : combinational; when high, clear
  //     send_nack_req and mask isNotExpPacket. See header comment.
  reg  socl_l7_reached_link_data;
  wire socl_l7_bringup_forgive = (~socl_l7_reached_link_data)
                                 & cr_pkt_seen_tx_demet_io_out
                                 & crack_pkt_seen_tx_demet_io_out;
  // Masked isNotExpPacket: while forgive is active, suppress the spurious
  // bringup-transient notifier so it cannot re-latch send_nack_req on the
  // same cycle the synchronous AND-clear is applied.
  wire isNotExpPacket_l7 = isNotExpPacket & ~socl_l7_bringup_forgive;
  // SoC Labs L9: isNotExpPacket masked with resync-now (sticky+wire
  // declarations live earlier in the file, near pkt_is_data_pkt at L347,
  // for declaration-before-use ordering — VCS strict on
  // `default_nettype none`).
  wire isNotExpPacket_l9  = isNotExpPacket_l7 & ~socl_l9_resync_now;
  // SoC Labs F-1 state-7 watchdog: see header comment.  Backup recovery
  // path for the case where the demet stickies fail to align (P&R lottery
  // / ILA insertion / ASIC post-CTS).  Forward declarations; sequential
  // logic lives in the always blocks below.
  reg         socl_l7_real_crc_seen;   // sticky: any real CRC error since reset
  reg  [15:0] socl_l7_wdog_cnt;        // saturating counter, ticks in state 7
  wire        socl_l7_wdog_force_clear =
                (socl_l7_wdog_cnt == SOCL_L7_WDOG_THRESHOLD)
                & ~socl_l7_real_crc_seen;
  // ===========================================================================
  // SoC Labs credit-recovery: receiver-side periodic ACK re-emission
  //   (2026-06-05).
  //
  // Problem class (test_14_sustained_ack_drop_wedge):
  //   The credit-return ACK is CUMULATIVE and the sender applies it ABSOLUTELY
  //   (fe_rx_ptr <= ack_nack_fifo_io_rdata[15:8] at the fe_rx_ptr always-block).
  //   Recovery from a *single* dropped ACK is automatic because fresh M->S data
  //   keeps minting fresh cumulative ACKs (test_13). But a SUSTAINED loss of the
  //   S->M credit-return stream is fatal: with every ACK lost, the sender's
  //   fe_rx_ptr never advances, the credit ring fills, fe_rx_is_full latches,
  //   the sender STOPS emitting data -> the receiver gets no new data -> the
  //   receiver mints NO fresh ACK -> the link is PERMANENTLY WEDGED with no
  //   escape (the state-7 NACK watchdog only recovers from CRC / unexpected-pkt
  //   errors, not from a silently-vanished ACK).
  //
  // Fix (RECEIVER side, IDEMPOTENT, SAFE):
  //   Periodically RE-EMIT the cumulative last_good ACK that this side already
  //   owns once (a) this receiver has accepted in-order data it can re-ACK
  //   (last_good_pkt_from_rx != 0) AND (b) no ACK has been emitted and no fresh
  //   data has arrived for a long idle window (SOCL_REACK_THRESHOLD io_tx_clk
  //   cycles). It re-emits AT MOST ONCE per idle window (socl_reack_fired
  //   sticky) so it does not spam a healthy-but-quiescent link.
  //
  // Why it is safe:
  //   * It re-sends an ACK carrying the EXISTING last_good_pkt_from_rx value
  //     (the highest IN-ORDER packet this receiver actually got). It NEVER
  //     fabricates a higher number, so it can NEVER advance the peer's
  //     fe_rx_ptr past data the receiver did not receive, and NEVER frees
  //     credit for un-received packets. Re-emitting the same cumulative value
  //     the peer already holds is a harmless idempotent no-op write.
  //   * It only RE-ARMS send_ack_req (ORed into the existing assignment); the
  //     normal state-5 -> state-6 emit path, ack payload (last_good_pkt_from_rx)
  //     and last_ack_pkt_sent bookkeeping are unchanged.
  //   * The threshold is far larger than the healthy ACK cadence and the idle
  //     counter is reset by every fresh-data event, so on a live link -- where
  //     data and ACKs keep flowing -- the counter never reaches threshold and
  //     the re-arm NEVER fires.
  //
  // The counter lives in the io_tx_clk domain (same as send_ack_req / state /
  // last_ack_pkt_sent). It is reset whenever fresh in-order data arrives
  // (socl_reack_fresh_data) or the FCSM leaves the data-phase states (4/5); it
  // saturates at SOCL_REACK_THRESHOLD.
  // ---------------------------------------------------------------------------
  reg  [15:0] socl_reack_idle_cnt;     // io_tx_clk idle counter since last ACK/data
  // "have we received in-order data we can re-ACK": last_good_pkt_from_rx != 0
  // means this receiver has accepted at least one in-order data packet whose
  // cumulative ACK it owns and can safely RE-EMIT.  We deliberately do NOT gate
  // on (last_good_pkt_from_rx != last_ack_pkt_sent): under sustained ACK loss
  // the receiver has ALREADY "sent" the ACK (last_ack_pkt_sent == last_good)
  // from its own viewpoint -- the peer simply never received it -- so that
  // predicate is false exactly when we most need to re-emit.  Re-emitting the
  // SAME cumulative value is IDEMPOTENT (it can only re-write the peer's
  // fe_rx_ptr to a value the receiver already legitimately owns, never higher),
  // so it is safe to re-emit unconditionally.
  wire socl_reack_have_rx = (last_good_pkt_from_rx != 8'h0);
  // Fresh in-order data / l2a progress -- the normal send_ack_req arming event.
  wire socl_reack_fresh_data  = isExpPacket | l2a_fifo_raddr_txclk_update;
  // Sticky: a re-emit has fired since the last fresh-data / real-ACK activity.
  // Limits the periodic re-emit to AT MOST ONCE per idle window so a healthy
  // but quiescent link is never spammed -- it re-emits a single refresh ACK to
  // unstick the peer, then waits for the peer to resume (fresh data -> real ACK
  // -> this sticky clears).  Declared here; cleared/set in the always block.
  reg  socl_reack_fired;
  // socl_reack_ack_emitted / socl_reack_rearm depend on _T_57 (declared later,
  // VCS default_nettype none requires declaration-before-use) -- see below,
  // just after the _T_57 definition.
  // Original Chisel-emitted _GEN_34 (kept as comment for review):
  //   wire [2:0] _GEN_34 = crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out ? 3'h2 : state;
  // Patched: only allow state 1 -> state 2 once minimum CR-emit count reached.
  wire [2:0] _GEN_34 = (crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out) & socl_l6_cr_emit_gate_ok
                       ? 3'h2 : state; // SoC Labs L6 gate
  wire  _GEN_35 = auto_tx_out_advance | sop; // @[FC.scala 459:28 FC.scala 427:39]
  wire [55:0] _GEN_38 = auto_tx_out_advance ? 56'h0 : link_data; // @[FC.scala 459:28 FC.scala 430:39]
  // SoC Labs L7: the state-2 advance muxes are gated on socl_l7_crack_release
  // (= crack_seen & min-CRACK-emit-met) instead of the bare crack_seen, so the
  // die keeps emitting CRACK (sop/data_id/word_count) and holds state 2 until the
  // CRACK-emit floor is reached. Mirrors the L6 fix to _GEN_34 / state-1 data_id.
  wire  _GEN_40 = socl_l7_crack_release ? 1'h0 : 1'h1; // @[FC.scala 476:34 FC.scala 477:39 FC.scala 484:39]
  wire [7:0] _GEN_41 = socl_l7_crack_release ? 8'h0 : out_prepend_swi_crack_id; // @[FC.scala 476:34 FC.scala 478:39 FC.scala 485:39]
  wire [15:0] _GEN_42 = socl_l7_crack_release ? 16'h0 : 16'h1f1f; // @[FC.scala 476:34 FC.scala 479:39 FC.scala 486:39]
  reg [7:0] swi_link_en_wait; // @[SW.scala 83:22]
  wire [7:0] _GEN_44 = socl_l7_crack_release ? swi_link_en_wait : count; // @[FC.scala 476:34 FC.scala 481:39 FC.scala 425:39]
  wire [2:0] _GEN_45 = socl_l7_crack_release ? 3'h3 : state; // @[FC.scala 476:34 FC.scala 482:39 FC.scala 424:39]
  wire [2:0] _GEN_51 = auto_tx_out_advance ? _GEN_45 : state; // @[FC.scala 475:28 FC.scala 424:39]
  wire  _T_54 = count == 8'h0; // @[FC.scala 495:20]
  wire [7:0] _count_in_T_1 = count - 8'h1; // @[FC.scala 498:48]
  wire [2:0] _GEN_52 = count == 8'h0 ? 3'h4 : state; // @[FC.scala 495:28 FC.scala 496:39 FC.scala 424:39]
  wire [7:0] _GEN_53 = count == 8'h0 ? count : _count_in_T_1; // @[FC.scala 495:28 FC.scala 425:39 FC.scala 498:39]
  wire [7:0] _count_in_T_5 = _T_54 ? 8'h0 : _count_in_T_1; // @[FC.scala 504:45]
  wire  _T_57 = send_ack_req & _T_54; // @[FC.scala 514:33]
  // SoC Labs credit-recovery (2026-06-05): deferred re-ACK re-arm (needs _T_57
  // indirectly via send_ack_req gating; declared here after _T_57 for VCS
  // declaration-before-use under default_nettype none).
  // Re-arm pulse: idle window elapsed AND we own received data to re-ACK AND we
  // have not already fired a refresh this idle window.  Only in data-phase
  // states (>=4); never during bring-up (states 0..3); suppressed while a NACK
  // is pending (NACK already re-syncs) or send_ack_req is already armed.
  wire socl_reack_rearm =
         (socl_reack_idle_cnt == SOCL_REACK_THRESHOLD)
         & socl_reack_have_rx
         & ~socl_reack_fired
         & (state >= 3'h4)
         & ~send_nack_req
         & ~send_ack_req;
  wire [7:0] _GEN_61 = send_ack_req & _T_54 ? last_good_pkt_from_rx_in : last_ack_pkt_sent; // @[FC.scala 514:50 FC.scala 515:39 FC.scala 436:39]
  wire [7:0] _GEN_70 = send_nack_req ? last_good_pkt_from_rx_in : _GEN_61; // @[FC.scala 505:28 FC.scala 506:39]
  wire [7:0] _GEN_104 = auto_tx_out_advance ? _GEN_70 : last_ack_pkt_sent; // @[FC.scala 537:28 FC.scala 436:39]
  wire [7:0] _GEN_122 = send_nack_req ? last_good_pkt_from_rx_in : last_ack_pkt_sent; // @[FC.scala 586:30 FC.scala 587:39 FC.scala 436:39]
  wire [7:0] _GEN_131 = auto_tx_out_advance ? _GEN_122 : last_ack_pkt_sent; // @[FC.scala 582:28 FC.scala 436:39]
  wire [7:0] _GEN_140 = state == 3'h6 ? _GEN_131 : last_ack_pkt_sent; // @[FC.scala 578:57 FC.scala 436:39]
  wire [7:0] _GEN_152 = state == 3'h7 ? last_ack_pkt_sent : _GEN_140; // @[FC.scala 571:58 FC.scala 436:39]
  wire [7:0] _GEN_160 = state == 3'h5 ? _GEN_104 : _GEN_152; // @[FC.scala 534:58]
  wire [7:0] _GEN_171 = state == 3'h4 ? _GEN_70 : _GEN_160; // @[FC.scala 501:58]
  wire [7:0] _GEN_183 = state == 3'h3 ? last_ack_pkt_sent : _GEN_171; // @[FC.scala 491:61 FC.scala 436:39]
  wire [7:0] _GEN_198 = state == 3'h2 ? last_ack_pkt_sent : _GEN_183; // @[FC.scala 473:62 FC.scala 436:39]
  wire [7:0] _GEN_209 = state == 3'h1 ? last_ack_pkt_sent : _GEN_198; // @[FC.scala 457:62 FC.scala 436:39]
  wire [7:0] word_count_in_lo = _ack_seen_before_T ? 8'h0 : _GEN_209; // @[FC.scala 444:47 FC.scala 446:39]
  wire [12:0] _word_count_in_T_4 = {l2a_fifo_raddr_txclk,word_count_in_lo}; // @[Cat.scala 30:58]
  wire  _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full; // @[FC.scala 523:45]
  wire [7:0] link_data_in_lo = {{3'd0}, a2l_fc_replay_link_cur_addr}; // @[FC.scala 350:45 FC.scala 351:39]
  wire [55:0] _link_data_in_T = {a2l_fc_replay_link_data,link_data_in_lo}; // @[Cat.scala 30:58]
  wire  _GEN_55 = a2l_fc_replay_link_valid & ~fe_rx_is_full | sop; // @[FC.scala 523:63 FC.scala 525:39 FC.scala 427:39]
  wire [7:0] _GEN_56 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? swi_data_id_1 : data_id; // @[FC.scala 523:63 FC.scala 526:39 FC.scala 428:39]
  wire [15:0] _GEN_57 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 16'h7 : word_count; // @[FC.scala 523:63 FC.scala 527:39 FC.scala 429:39]
  wire [55:0] _GEN_58 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? _link_data_in_T : link_data; // @[FC.scala 523:63 FC.scala 528:39 FC.scala 430:39]
  wire [7:0] _GEN_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? ne_rx_ptr_next : ne_rx_ptr; // @[FC.scala 523:63 FC.scala 530:39 FC.scala 434:39]
  wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state; // @[FC.scala 523:63 FC.scala 531:39 FC.scala 424:39]
  wire  _GEN_62 = send_ack_req & _T_54 ? 1'h0 : send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update); // @[FC.scala 514:50 FC.scala 516:39 FC.scala 438:39]
  wire  _GEN_63 = send_ack_req & _T_54 | _GEN_55; // @[FC.scala 514:50 FC.scala 517:39]
  wire [7:0] _GEN_64 = send_ack_req & _T_54 ? out_prepend_swi_ack_id : _GEN_56; // @[FC.scala 514:50 FC.scala 518:39]
  wire [15:0] _GEN_65 = send_ack_req & _T_54 ? {{3'd0}, _word_count_in_T_4} : _GEN_57; // @[FC.scala 514:50 FC.scala 519:39]
  wire [55:0] _GEN_66 = send_ack_req & _T_54 ? 56'h0 : _GEN_58; // @[FC.scala 514:50 FC.scala 520:39]
  wire [2:0] _GEN_67 = send_ack_req & _T_54 ? 3'h6 : _GEN_60; // @[FC.scala 514:50 FC.scala 521:39]
  wire  _GEN_68 = send_ack_req & _T_54 ? 1'h0 : _T_59; // @[FC.scala 514:50 FC.scala 441:39]
  wire [7:0] _GEN_69 = send_ack_req & _T_54 ? ne_rx_ptr : _GEN_59; // @[FC.scala 514:50 FC.scala 434:39]
  wire  _GEN_71 = send_nack_req ? 1'h0 : send_nack_req | (crcCorruptSeen | isNotExpPacket_l9) /* SoC Labs L7 masked NotExp */; // @[FC.scala 505:28 FC.scala 507:39 FC.scala 439:39]
  wire  _GEN_72 = send_nack_req | _GEN_63; // @[FC.scala 505:28 FC.scala 508:39]
  wire [7:0] _GEN_73 = send_nack_req ? out_prepend_swi_nack_id : _GEN_64; // @[FC.scala 505:28 FC.scala 509:39]
  wire [15:0] _GEN_74 = send_nack_req ? {{3'd0}, _word_count_in_T_4} : _GEN_65; // @[FC.scala 505:28 FC.scala 510:39]
  wire [55:0] _GEN_75 = send_nack_req ? 56'h0 : _GEN_66; // @[FC.scala 505:28 FC.scala 511:39]
  wire [2:0] _GEN_76 = send_nack_req ? 3'h7 : _GEN_67; // @[FC.scala 505:28 FC.scala 512:39]
  wire  _GEN_77 = send_nack_req ? send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update) : _GEN_62; // @[FC.scala 505:28 FC.scala 438:39]
  wire  _GEN_78 = send_nack_req ? 1'h0 : _GEN_68; // @[FC.scala 505:28 FC.scala 441:39]
  wire [7:0] _GEN_79 = send_nack_req ? ne_rx_ptr : _GEN_69; // @[FC.scala 505:28 FC.scala 434:39]
  wire [2:0] _GEN_85 = _T_59 ? 3'h5 : 3'h4; // @[FC.scala 555:65 FC.scala 563:39 FC.scala 566:39]
  wire  _GEN_88 = _T_57 | _T_59; // @[FC.scala 546:52 FC.scala 549:39]
  wire [2:0] _GEN_92 = _T_57 ? 3'h6 : _GEN_85; // @[FC.scala 546:52 FC.scala 553:39]
  wire  _GEN_96 = send_nack_req | _GEN_88; // @[FC.scala 538:30 FC.scala 541:39]
  wire [2:0] _GEN_100 = send_nack_req ? 3'h7 : _GEN_92; // @[FC.scala 538:30 FC.scala 545:39]
  wire  _GEN_105 = auto_tx_out_advance ? _GEN_71 : send_nack_req | (crcCorruptSeen | isNotExpPacket_l9) /* SoC Labs L7 masked NotExp */; // @[FC.scala 537:28 FC.scala 439:39]
  wire  _GEN_106 = auto_tx_out_advance ? _GEN_96 : sop; // @[FC.scala 537:28 FC.scala 427:39]
  wire [7:0] _GEN_107 = auto_tx_out_advance ? _GEN_73 : data_id; // @[FC.scala 537:28 FC.scala 428:39]
  wire [15:0] _GEN_108 = auto_tx_out_advance ? _GEN_74 : word_count; // @[FC.scala 537:28 FC.scala 429:39]
  wire [55:0] _GEN_109 = auto_tx_out_advance ? _GEN_75 : link_data; // @[FC.scala 537:28 FC.scala 430:39]
  wire [2:0] _GEN_110 = auto_tx_out_advance ? _GEN_100 : state; // @[FC.scala 537:28 FC.scala 424:39]
  wire  _GEN_111 = auto_tx_out_advance ? _GEN_77 : send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update); // @[FC.scala 537:28 FC.scala 438:39]
  wire  _GEN_112 = auto_tx_out_advance & _GEN_78; // @[FC.scala 537:28 FC.scala 441:39]
  wire [7:0] _GEN_113 = auto_tx_out_advance ? _GEN_79 : ne_rx_ptr; // @[FC.scala 537:28 FC.scala 434:39]
  wire  _GEN_114 = auto_tx_out_advance ? 1'h0 : sop; // @[FC.scala 573:28 FC.scala 574:39 FC.scala 427:39]
  wire [2:0] _GEN_115 = auto_tx_out_advance ? 3'h4 : state; // @[FC.scala 573:28 FC.scala 575:39 FC.scala 424:39]
  wire  _GEN_123 = send_nack_req | _T_59; // @[FC.scala 586:30 FC.scala 589:39]
  wire [7:0] _GEN_124 = send_nack_req ? out_prepend_swi_nack_id : _GEN_56; // @[FC.scala 586:30 FC.scala 590:39]
  wire [15:0] _GEN_125 = send_nack_req ? {{3'd0}, _word_count_in_T_4} : _GEN_57; // @[FC.scala 586:30 FC.scala 591:39]
  wire [55:0] _GEN_126 = send_nack_req ? 56'h0 : _GEN_58; // @[FC.scala 586:30 FC.scala 592:39]
  wire [2:0] _GEN_127 = send_nack_req ? 3'h7 : _GEN_85; // @[FC.scala 586:30 FC.scala 593:39]
  wire  _GEN_128 = send_nack_req ? 1'h0 : _T_59; // @[FC.scala 586:30 FC.scala 441:39]
  wire [7:0] _GEN_129 = send_nack_req ? ne_rx_ptr : _GEN_59; // @[FC.scala 586:30 FC.scala 434:39]
  reg [7:0] out_prepend_swi_ack_dly_count; // @[SW.scala 83:22]
  wire [7:0] _GEN_130 = auto_tx_out_advance ? out_prepend_swi_ack_dly_count : count; // @[FC.scala 582:28 FC.scala 584:39 FC.scala 425:39]
  wire  _GEN_132 = auto_tx_out_advance ? _GEN_123 : sop; // @[FC.scala 582:28 FC.scala 427:39]
  wire [7:0] _GEN_133 = auto_tx_out_advance ? _GEN_124 : data_id; // @[FC.scala 582:28 FC.scala 428:39]
  wire [15:0] _GEN_134 = auto_tx_out_advance ? _GEN_125 : word_count; // @[FC.scala 582:28 FC.scala 429:39]
  wire [55:0] _GEN_135 = auto_tx_out_advance ? _GEN_126 : link_data; // @[FC.scala 582:28 FC.scala 430:39]
  wire [2:0] _GEN_136 = auto_tx_out_advance ? _GEN_127 : state; // @[FC.scala 582:28 FC.scala 424:39]
  wire  _GEN_137 = auto_tx_out_advance & _GEN_128; // @[FC.scala 582:28 FC.scala 441:39]
  wire [7:0] _GEN_138 = auto_tx_out_advance ? _GEN_129 : ne_rx_ptr; // @[FC.scala 582:28 FC.scala 434:39]
  wire [7:0] _GEN_139 = state == 3'h6 ? _GEN_130 : count; // @[FC.scala 578:57 FC.scala 425:39]
  wire  _GEN_141 = state == 3'h6 ? _GEN_105 : send_nack_req | (crcCorruptSeen | isNotExpPacket_l9) /* SoC Labs L7 masked NotExp */; // @[FC.scala 578:57 FC.scala 439:39]
  wire  _GEN_142 = state == 3'h6 ? _GEN_132 : sop; // @[FC.scala 578:57 FC.scala 427:39]
  wire [7:0] _GEN_143 = state == 3'h6 ? _GEN_133 : data_id; // @[FC.scala 578:57 FC.scala 428:39]
  wire [15:0] _GEN_144 = state == 3'h6 ? _GEN_134 : word_count; // @[FC.scala 578:57 FC.scala 429:39]
  wire [55:0] _GEN_145 = state == 3'h6 ? _GEN_135 : link_data; // @[FC.scala 578:57 FC.scala 430:39]
  wire [2:0] _GEN_146 = state == 3'h6 ? _GEN_136 : 3'h0; // @[FC.scala 578:57 FC.scala 612:37]
  wire  _GEN_147 = state == 3'h6 & _GEN_137; // @[FC.scala 578:57 FC.scala 441:39]
  wire [7:0] _GEN_148 = state == 3'h6 ? _GEN_138 : ne_rx_ptr; // @[FC.scala 578:57 FC.scala 434:39]
  wire  _GEN_149 = state == 3'h7 ? _GEN_114 : _GEN_142; // @[FC.scala 571:58]
  wire [2:0] _GEN_150 = state == 3'h7 ? _GEN_115 : _GEN_146; // @[FC.scala 571:58]
  wire [7:0] _GEN_151 = state == 3'h7 ? count : _GEN_139; // @[FC.scala 571:58 FC.scala 425:39]
  wire  _GEN_153 = state == 3'h7 ? send_nack_req | (crcCorruptSeen | isNotExpPacket_l9) /* SoC Labs L7 masked NotExp */ : _GEN_141; // @[FC.scala 571:58 FC.scala 439:39]
  wire [7:0] _GEN_154 = state == 3'h7 ? data_id : _GEN_143; // @[FC.scala 571:58 FC.scala 428:39]
  wire [15:0] _GEN_155 = state == 3'h7 ? word_count : _GEN_144; // @[FC.scala 571:58 FC.scala 429:39]
  wire [55:0] _GEN_156 = state == 3'h7 ? link_data : _GEN_145; // @[FC.scala 571:58 FC.scala 430:39]
  wire  _GEN_157 = state == 3'h7 ? 1'h0 : _GEN_147; // @[FC.scala 571:58 FC.scala 441:39]
  wire [7:0] _GEN_158 = state == 3'h7 ? ne_rx_ptr : _GEN_148; // @[FC.scala 571:58 FC.scala 434:39]
  wire [7:0] _GEN_159 = state == 3'h5 ? _count_in_T_5 : _GEN_151; // @[FC.scala 534:58 FC.scala 536:39]
  wire  _GEN_161 = state == 3'h5 ? _GEN_105 : _GEN_153; // @[FC.scala 534:58]
  wire  _GEN_162 = state == 3'h5 ? _GEN_106 : _GEN_149; // @[FC.scala 534:58]
  wire [7:0] _GEN_163 = state == 3'h5 ? _GEN_107 : _GEN_154; // @[FC.scala 534:58]
  wire [15:0] _GEN_164 = state == 3'h5 ? _GEN_108 : _GEN_155; // @[FC.scala 534:58]
  wire [55:0] _GEN_165 = state == 3'h5 ? _GEN_109 : _GEN_156; // @[FC.scala 534:58]
  wire [2:0] _GEN_166 = state == 3'h5 ? _GEN_110 : _GEN_150; // @[FC.scala 534:58]
  wire  _GEN_167 = state == 3'h5 ? _GEN_111 : send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update); // @[FC.scala 534:58 FC.scala 438:39]
  wire  _GEN_168 = state == 3'h5 ? _GEN_112 : _GEN_157; // @[FC.scala 534:58]
  wire [7:0] _GEN_169 = state == 3'h5 ? _GEN_113 : _GEN_158; // @[FC.scala 534:58]
  wire [7:0] _GEN_170 = state == 3'h4 ? _count_in_T_5 : _GEN_159; // @[FC.scala 501:58 FC.scala 504:39]
  wire  _GEN_172 = state == 3'h4 ? _GEN_71 : _GEN_161; // @[FC.scala 501:58]
  wire  _GEN_173 = state == 3'h4 ? _GEN_72 : _GEN_162; // @[FC.scala 501:58]
  wire [7:0] _GEN_174 = state == 3'h4 ? _GEN_73 : _GEN_163; // @[FC.scala 501:58]
  wire [15:0] _GEN_175 = state == 3'h4 ? _GEN_74 : _GEN_164; // @[FC.scala 501:58]
  wire [55:0] _GEN_176 = state == 3'h4 ? _GEN_75 : _GEN_165; // @[FC.scala 501:58]
  wire [2:0] _GEN_177 = state == 3'h4 ? _GEN_76 : _GEN_166; // @[FC.scala 501:58]
  wire  _GEN_178 = state == 3'h4 ? _GEN_77 : _GEN_167; // @[FC.scala 501:58]
  wire  _GEN_179 = state == 3'h4 ? _GEN_78 : _GEN_168; // @[FC.scala 501:58]
  wire [7:0] _GEN_180 = state == 3'h4 ? _GEN_79 : _GEN_169; // @[FC.scala 501:58]
  wire [2:0] _GEN_181 = state == 3'h3 ? _GEN_52 : _GEN_177; // @[FC.scala 491:61]
  wire  _GEN_190 = state == 3'h3 ? 1'h0 : _GEN_179; // @[FC.scala 491:61 FC.scala 441:39]
  wire [7:0] _GEN_191 = state == 3'h3 ? ne_rx_ptr : _GEN_180; // @[FC.scala 491:61 FC.scala 434:39]
  wire  _GEN_201 = state == 3'h2 ? 1'h0 : _GEN_190; // @[FC.scala 473:62 FC.scala 441:39]
  wire  _GEN_212 = state == 3'h1 ? 1'h0 : _GEN_201; // @[FC.scala 457:62 FC.scala 441:39]
  reg [2:0] out_prepend_swi_almost_full; // @[SW.scala 83:22]
  reg [2:0] out_prepend_swi_almost_empty; // @[SW.scala 83:22]
  wire [5:0] in_bits_index = auto_in_paddr[7:2]; // @[RegisterNodes.scala 228:18 RegisterNodes.scala 237:19]
  wire [5:0] out_findex = in_bits_index & 6'h30; // @[RegisterNodes.scala 229:24]
  wire  _out_T = out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire [3:0] in_bits_mask = auto_in_pwrite ? auto_in_pstrb : 4'hf; // @[RegisterNodes.scala 239:25]
  wire [7:0] out_frontMask_lo_lo = in_bits_mask[0] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [7:0] out_frontMask_lo_hi = in_bits_mask[1] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [7:0] out_frontMask_hi_lo = in_bits_mask[2] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [7:0] out_frontMask_hi_hi = in_bits_mask[3] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [31:0] out_frontMask = {out_frontMask_hi_hi,out_frontMask_hi_lo,out_frontMask_lo_hi,out_frontMask_lo_lo}; // @[Cat.scala 30:58]
  wire  out_wimask = &out_frontMask[7:0]; // @[RegisterNodes.scala 229:24]
  reg  taken; // @[RegisterNodes.scala 232:24]
  wire  in_valid = auto_in_psel & ~taken; // @[RegisterNodes.scala 241:26]
  wire  in_bits_read = ~auto_in_pwrite; // @[RegisterNodes.scala 236:22]
  wire  out_oindex_hi_hi = in_bits_index[3]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_hi_lo = in_bits_index[2]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_lo_hi = in_bits_index[1]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_lo_lo = in_bits_index[0]; // @[RegisterNodes.scala 229:24]
  wire [3:0] out_oindex = {out_oindex_hi_hi,out_oindex_hi_lo,out_oindex_lo_hi,out_oindex_lo_lo}; // @[Cat.scala 30:58]
  wire [15:0] _out_frontSel_T = 16'h1 << out_oindex; // @[OneHot.scala 58:35]
  wire  out_frontSel_0 = _out_frontSel_T[0]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_0 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_0 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid = out_wivalid_0 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_1 = &out_frontMask[15:8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_1 = out_wivalid_0 & out_wimask_1; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_2 = &out_frontMask[23:16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_2 = out_wivalid_0 & out_wimask_2; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_3 = &out_frontMask[31:24]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_3 = out_wivalid_0 & out_wimask_3; // @[RegisterNodes.scala 229:24]
  wire [31:0] out_prepend_2 = {out_prepend_swi_nack_id,out_prepend_swi_ack_id,out_prepend_swi_crack_id,swi_cr_id}; // @[Cat.scala 30:58]
  wire  out_frontSel_5 = _out_frontSel_T[5]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_4 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_5 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_4 = out_wivalid_4 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_5 = out_wivalid_4 & out_wimask_1; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_6 = &out_frontMask[16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_6 = out_wivalid_4 & out_wimask_6; // @[RegisterNodes.scala 229:24]
  wire [16:0] out_prepend_4 = {out_prepend_swi_disable_crc,out_prepend_swi_ack_dly_count,swi_link_en_wait}; // @[Cat.scala 30:58]
  wire  out_frontSel_1 = _out_frontSel_T[1]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_7 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_1 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_7 = out_wivalid_7 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  readval = a2l_fc_replay_link_empty; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_frontSel_4 = _out_frontSel_T[4]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_10 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_4 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  readval_1 = ack_nack_fifo_io_rempty; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi = ack_nack_fifo_io_wfull; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi_1 = ack_nack_fifo_io_half_full; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi_2 = ack_nack_fifo_io_almost_empty; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi_3 = ack_nack_fifo_io_almost_full; // @[SW.scala 199:25 SW.scala 200:15]
  wire [5:0] out_prepend_9 = {1'h0,out_prepend_hi_3,out_prepend_hi_2,out_prepend_hi_1,out_prepend_hi,readval_1}; // @[Cat.scala 30:58]
  wire [7:0] out_prepend_lo_10 = {{2'd0}, out_prepend_9}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_16 = &out_frontMask[10:8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_16 = out_wivalid_10 & out_wimask_16; // @[RegisterNodes.scala 229:24]
  wire [11:0] out_prepend_11 = {1'h0,out_prepend_swi_almost_full,out_prepend_lo_10}; // @[Cat.scala 30:58]
  wire [15:0] out_prepend_lo_12 = {{4'd0}, out_prepend_11}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_18 = &out_frontMask[18:16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_18 = out_wivalid_10 & out_wimask_18; // @[RegisterNodes.scala 229:24]
  wire [18:0] out_prepend_12 = {out_prepend_swi_almost_empty,out_prepend_lo_12}; // @[Cat.scala 30:58]
  wire  _out_out_bits_data_T = 4'h0 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_1 = 4'h1 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_2 = 4'h2 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_3 = 4'h4 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_4 = 4'h5 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_5 = 4'h8 == out_oindex; // @[Conditional.scala 37:30]
  wire  _GEN_301 = _out_out_bits_data_T_5 ? _out_T : 1'h1; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_302 = _out_out_bits_data_T_4 ? _out_T : _GEN_301; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_303 = _out_out_bits_data_T_3 ? _out_T : _GEN_302; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_304 = _out_out_bits_data_T_2 ? _out_T : _GEN_303; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_305 = _out_out_bits_data_T_1 ? _out_T : _GEN_304; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  out_out_bits_data_out = _out_out_bits_data_T ? _out_T : _GEN_305; // @[Conditional.scala 40:58 MuxLiteral.scala 53:32]
  wire [15:0] _GEN_307 = _out_out_bits_data_T_5 ? crc_errors_in : 16'h0; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [16:0] _GEN_308 = _out_out_bits_data_T_4 ? out_prepend_4 : {{1'd0}, _GEN_307}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [18:0] _GEN_309 = _out_out_bits_data_T_3 ? out_prepend_12 : {{2'd0}, _GEN_308}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [18:0] _GEN_310 = _out_out_bits_data_T_2 ? {{18'd0}, readval} : _GEN_309; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [18:0] _GEN_311 = _out_out_bits_data_T_1 ? {{11'd0}, swi_data_id_1} : _GEN_310; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] out_out_bits_data_out_1 = _out_out_bits_data_T ? out_prepend_2 : {{13'd0}, _GEN_311}; // @[Conditional.scala 40:58 MuxLiteral.scala 53:32]
  wire  _T_70 = auto_in_penable & in_valid; // @[Decoupled.scala 40:37]
  wire  _GEN_313 = _T_70 | taken; // @[RegisterNodes.scala 233:23 RegisterNodes.scala 233:31 RegisterNodes.scala 232:24]
  WlinkCrcGen_8 rx_crc_computed_crcgen ( // @[LinkLayer.scala 1274:24]
    .io_in(rx_crc_computed_crcgen_io_in),
    .io_out(rx_crc_computed_crcgen_io_out)
  );
  WavDemetReset en_ff2_rx_demet ( // @[Stdcell.scala 58:23]
    .clock(en_ff2_rx_demet_clock),
    .reset(en_ff2_rx_demet_reset),
    .io_in(en_ff2_rx_demet_io_in),
    .io_out(en_ff2_rx_demet_io_out)
  );
  WlinkGenericFCReplayV2_12 l2a_fc_replay ( // @[FC.scala 219:43]
    .app_clk(l2a_fc_replay_app_clk),
    .app_reset(l2a_fc_replay_app_reset),
    .app_enable(l2a_fc_replay_app_enable),
    .app_data(l2a_fc_replay_app_data),
    .app_valid(l2a_fc_replay_app_valid),
    .app_ready(l2a_fc_replay_app_ready),
    .link_clk(l2a_fc_replay_link_clk),
    .link_reset(l2a_fc_replay_link_reset),
    .link_ack_addr(l2a_fc_replay_link_ack_addr),
    .link_cur_addr(l2a_fc_replay_link_cur_addr),
    .link_data(l2a_fc_replay_link_data),
    .link_valid(l2a_fc_replay_link_valid),
    .link_advance(l2a_fc_replay_link_advance),
    .link_empty(l2a_fc_replay_link_empty)
  );
  WlinkGenericFCReplayAddrSync_18 l2a_fifo_addr_to_tx ( // @[FC.scala 241:43]
    .w_clk(l2a_fifo_addr_to_tx_w_clk),
    .w_reset(l2a_fifo_addr_to_tx_w_reset),
    .w_inc(l2a_fifo_addr_to_tx_w_inc),
    .w_addr(l2a_fifo_addr_to_tx_w_addr),
    .r_clk(l2a_fifo_addr_to_tx_r_clk),
    .r_reset(l2a_fifo_addr_to_tx_r_reset),
    .r_addr(l2a_fifo_addr_to_tx_r_addr)
  );
  WavFIFO_1 ack_nack_fifo ( // @[FC.scala 260:41]
    .io_wclk(ack_nack_fifo_io_wclk),
    .io_wreset(ack_nack_fifo_io_wreset),
    .io_winc(ack_nack_fifo_io_winc),
    .io_rclk(ack_nack_fifo_io_rclk),
    .io_rreset(ack_nack_fifo_io_rreset),
    .io_rinc(ack_nack_fifo_io_rinc),
    .io_wdata(ack_nack_fifo_io_wdata),
    .io_rdata(ack_nack_fifo_io_rdata),
    .io_wfull(ack_nack_fifo_io_wfull),
    .io_rempty(ack_nack_fifo_io_rempty),
    .io_swi_almost_empty(ack_nack_fifo_io_swi_almost_empty),
    .io_swi_almost_full(ack_nack_fifo_io_swi_almost_full),
    .io_half_full(ack_nack_fifo_io_half_full),
    .io_almost_empty(ack_nack_fifo_io_almost_empty),
    .io_almost_full(ack_nack_fifo_io_almost_full)
  );
  WlinkGenericFCReplayV2_13 a2l_fc_replay ( // @[FC.scala 297:43]
    .app_clk(a2l_fc_replay_app_clk),
    .app_reset(a2l_fc_replay_app_reset),
    .app_enable(a2l_fc_replay_app_enable),
    .app_data(a2l_fc_replay_app_data),
    .app_valid(a2l_fc_replay_app_valid),
    .app_ready(a2l_fc_replay_app_ready),
    .link_clk(a2l_fc_replay_link_clk),
    .link_reset(a2l_fc_replay_link_reset),
    .link_ack_update(a2l_fc_replay_link_ack_update),
    .link_ack_addr(a2l_fc_replay_link_ack_addr),
    .link_revert(a2l_fc_replay_link_revert),
    .link_revert_addr(a2l_fc_replay_link_revert_addr),
    .link_cur_addr(a2l_fc_replay_link_cur_addr),
    .link_data(a2l_fc_replay_link_data),
    .link_valid(a2l_fc_replay_link_valid),
    .link_advance(a2l_fc_replay_link_advance),
    .link_empty(a2l_fc_replay_link_empty),
    // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 (read-only)
    .obs_a2l_wptr(a2l_fc_replay_obs_a2l_wptr),
    .obs_a2l_synced_ack(a2l_fc_replay_obs_a2l_synced_ack),
    .obs_a2l_full(a2l_fc_replay_obs_a2l_full),
    .obs_enable_app_clk_demet(a2l_fc_replay_obs_enable_app_clk_demet),
    // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER obs 2026-06-21 (RO)
    .obs_a2l_rreset(a2l_fc_replay_obs_a2l_rreset),
    .obs_a2l_rptr(a2l_fc_replay_obs_a2l_rptr)
  );
  WavDemetReset en_ff2_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(en_ff2_tx_demet_clock),
    .reset(en_ff2_tx_demet_reset),
    .io_in(en_ff2_tx_demet_io_in),
    .io_out(en_ff2_tx_demet_io_out)
  );
  WavDemetReset cr_pkt_seen_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(cr_pkt_seen_tx_demet_clock),
    .reset(cr_pkt_seen_tx_demet_reset),
    .io_in(cr_pkt_seen_tx_demet_io_in),
    .io_out(cr_pkt_seen_tx_demet_io_out)
  );
  WavDemetReset crack_pkt_seen_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(crack_pkt_seen_tx_demet_clock),
    .reset(crack_pkt_seen_tx_demet_reset),
    .io_in(crack_pkt_seen_tx_demet_io_in),
    .io_out(crack_pkt_seen_tx_demet_io_out)
  );
  WlinkCrcGen_8 bundleOut_0_crc_crcgen ( // @[LinkLayer.scala 1274:24]
    .io_in(bundleOut_0_crc_crcgen_io_in),
    .io_out(bundleOut_0_crc_crcgen_io_out)
  );
  assign auto_in_pready = auto_in_psel & ~taken; // @[RegisterNodes.scala 241:26]
  assign auto_in_prdata = out_out_bits_data_out ? out_out_bits_data_out_1 : 32'h0; // @[RegisterNodes.scala 229:24]
  assign auto_tx_out_sop = sop; // @[Nodes.scala 1207:84 FC.scala 624:25]
  assign auto_tx_out_data_id = data_id; // @[Nodes.scala 1207:84 FC.scala 625:25]
  assign auto_tx_out_word_count = word_count; // @[Nodes.scala 1207:84 FC.scala 626:25]
  assign auto_tx_out_data = link_data; // @[Nodes.scala 1207:84 FC.scala 627:25]
  assign auto_tx_out_crc = bundleOut_0_crc_crcgen_io_out; // @[Nodes.scala 1207:84 FC.scala 630:25]
  assign io_app_a2l_ready = a2l_fc_replay_app_ready; // @[FC.scala 303:35]
  assign io_app_l2a_valid = l2a_fc_replay_link_valid; // @[FC.scala 230:35]
  assign io_app_l2a_data = l2a_fc_replay_link_data; // @[FC.scala 231:35]
  assign io_rx_crc_err = |crc_errors; // @[FC.scala 161:49]
  // SoC Labs credit-path observability taps (FC state machine internals).
  assign io_obs_state             = state;
  assign io_obs_cr_pkt_seen_rx    = cr_pkt_seen_rx;
  assign io_obs_crack_pkt_seen_rx = crack_pkt_seen_rx;
  assign io_obs_pkt_is_cr_pkt     = pkt_is_cr_pkt;
  assign io_obs_pkt_is_crack_pkt  = pkt_is_crack_pkt;
  // SoC Labs Bug-A FCSM observation 2026-06-02
  assign io_obs_a2l_replay_link_valid = a2l_fc_replay_link_valid;
  assign io_obs_fe_rx_credit_max      = fe_rx_credit_max;
  assign io_obs_fe_rx_is_full         = fe_rx_is_full;
  // SoC Labs Bug-A FCSM observation 2026-06-03
  assign io_obs_a2l_replay_app_valid  = a2l_fc_replay_app_valid;
  // SoC Labs V2 data-send observation 2026-06-21 (read-only fan-out)
  assign io_obs_a2l_replay_app_ready  = a2l_fc_replay_app_ready;
  assign io_obs_a2l_replay_link_empty = a2l_fc_replay_link_empty;
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 (read-only fan-out)
  assign io_obs_a2l_wptr              = a2l_fc_replay_obs_a2l_wptr;
  assign io_obs_a2l_synced_ack        = a2l_fc_replay_obs_a2l_synced_ack;
  assign io_obs_a2l_full              = a2l_fc_replay_obs_a2l_full;
  assign io_obs_a2l_enable_app_demet  = a2l_fc_replay_obs_enable_app_clk_demet;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  assign io_obs_a2l_rreset            = a2l_fc_replay_obs_a2l_rreset;
  assign io_obs_a2l_rptr              = a2l_fc_replay_obs_a2l_rptr;
  // SoC Labs FC credit observation 2026-06-12
  assign io_obs_fe_rx_ptr             = fe_rx_ptr;
  assign rx_crc_computed_crcgen_io_in = auto_rx_in_data; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign en_ff2_rx_demet_clock = io_rx_clk; // @[FC.scala 191:33]
  assign en_ff2_rx_demet_reset = io_rx_reset; // @[FC.scala 191:54]
  assign en_ff2_rx_demet_io_in = io_app_enable; // @[Stdcell.scala 59:17]
  assign l2a_fc_replay_app_clk = io_rx_clk; // @[FC.scala 220:35]
  assign l2a_fc_replay_app_reset = io_rx_reset; // @[FC.scala 221:35]
  assign l2a_fc_replay_app_enable = io_app_enable; // @[FC.scala 222:35]
  assign l2a_fc_replay_app_data = auto_rx_in_data[55:8]; // @[FC.scala 122:33]
  // SoC Labs L9: accept the FIRST observed DATA pkt regardless of pktnum
  // alignment so the resync write lands in the L2A FIFO.
  // SoC Labs L9b: ALSO commit the packet on a bounded forward re-anchor — the
  // newly-anchored stream is delivered (the gap is the only loss), instead of
  // wedging on a NACK/revert storm.
  assign l2a_fc_replay_app_valid = (pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num)
                                  | socl_l9_resync_now
                                  | socl_l9b_reanchor_now;
  assign l2a_fc_replay_link_clk = io_app_clk; // @[FC.scala 227:35]
  assign l2a_fc_replay_link_reset = io_app_reset; // @[FC.scala 228:35]
  assign l2a_fc_replay_link_ack_addr = l2a_fc_replay_link_cur_addr; // @[FC.scala 237:35]
  assign l2a_fc_replay_link_advance = io_app_l2a_accept; // @[FC.scala 232:35]
  assign l2a_fifo_addr_to_tx_w_clk = io_app_clk; // @[FC.scala 242:49]
  assign l2a_fifo_addr_to_tx_w_reset = io_app_reset; // @[FC.scala 243:35]
  assign l2a_fifo_addr_to_tx_w_inc = 1'h1; // @[FC.scala 244:35]
  assign l2a_fifo_addr_to_tx_w_addr = l2a_fc_replay_link_cur_addr; // @[FC.scala 245:35]
  assign l2a_fifo_addr_to_tx_r_clk = io_tx_clk; // @[FC.scala 247:48]
  assign l2a_fifo_addr_to_tx_r_reset = io_tx_reset; // @[FC.scala 248:35]
  assign ack_nack_fifo_io_wclk = io_rx_clk; // @[FC.scala 262:33]
  assign ack_nack_fifo_io_wreset = io_rx_reset; // @[FC.scala 263:33]
  // SoC Labs L9b: suppress the ack_nack_fifo write on a forward re-anchor cycle.
  // The mismatch is being forgiven (exp_pkt_num jumps forward and the packet is
  // committed), so it must NOT enqueue a notifier at all — neither a 3'h1
  // (would NACK) nor a stray 3'h0 (would clobber last_good_pkt_from_rx). The
  // re-anchored packet's credit is accounted by exp_pkt_seen on subsequent
  // in-order packets exactly as a clean stream.
  assign ack_nack_fifo_io_winc = pkt_is_ack_pkt | pkt_is_nack_pkt | exp_pkt_seen |
    (exp_pkt_not_seen & ~socl_l9b_reanchor_now) |
    valid_rx_pkt_crc_err; // @[FC.scala 264:106]
  assign ack_nack_fifo_io_rclk = io_tx_clk; // @[FC.scala 282:33]
  assign ack_nack_fifo_io_rreset = io_tx_reset; // @[FC.scala 283:33]
  assign ack_nack_fifo_io_rinc = ack_nack_fifo_valid & state != 3'h0; // @[FC.scala 284:56]
  assign ack_nack_fifo_io_wdata = _ack_nack_fifo_io_winc_T ? _ack_nack_fifo_io_wdata_T_1 : _ack_nack_fifo_io_wdata_T_2; // @[FC.scala 278:39]
  assign ack_nack_fifo_io_swi_almost_empty = out_prepend_swi_almost_empty; // @[SW.scala 117:16]
  assign ack_nack_fifo_io_swi_almost_full = out_prepend_swi_almost_full; // @[SW.scala 117:16]
  assign a2l_fc_replay_app_clk = io_app_clk; // @[FC.scala 298:35]
  assign a2l_fc_replay_app_reset = io_app_reset; // @[FC.scala 299:35]
  assign a2l_fc_replay_app_enable = io_app_enable; // @[FC.scala 300:35]
  assign a2l_fc_replay_app_data = io_app_a2l_data; // @[FC.scala 301:35]
  assign a2l_fc_replay_app_valid = io_app_a2l_valid; // @[FC.scala 302:35]
  assign a2l_fc_replay_link_clk = io_tx_clk; // @[FC.scala 304:35]
  assign a2l_fc_replay_link_reset = io_tx_reset; // @[FC.scala 305:35]
  assign a2l_fc_replay_link_ack_update = ack_nack_fifo_io_rdata[18:16] == 3'h2 & ack_nack_fifo_valid; // @[FC.scala 289:73]
  assign a2l_fc_replay_link_ack_addr = ack_nack_fifo_io_rdata[4:0]; // @[FC.scala 334:64]
  assign a2l_fc_replay_link_revert = ack_nack_fifo_io_rdata[18:16] == 3'h3 & ack_nack_fifo_valid; // @[FC.scala 290:73]
  assign a2l_fc_replay_link_revert_addr = ~ack_seen_before ? 5'h0 : _link_revert_addr_T_6; // @[FC.scala 347:45]
  assign a2l_fc_replay_link_advance = _ack_seen_before_T ? 1'h0 : _GEN_212; // @[FC.scala 444:47 FC.scala 441:39]
  assign en_ff2_tx_demet_clock = io_tx_clk; // @[FC.scala 314:33]
  assign en_ff2_tx_demet_reset = io_tx_reset; // @[FC.scala 314:54]
  assign en_ff2_tx_demet_io_in = io_app_enable; // @[Stdcell.scala 59:17]
  assign cr_pkt_seen_tx_demet_clock = io_tx_clk; // @[FC.scala 314:33]
  assign cr_pkt_seen_tx_demet_reset = io_tx_reset; // @[FC.scala 314:54]
  assign cr_pkt_seen_tx_demet_io_in = cr_pkt_seen_rx; // @[Stdcell.scala 59:17]
  assign crack_pkt_seen_tx_demet_clock = io_tx_clk; // @[FC.scala 314:33]
  assign crack_pkt_seen_tx_demet_reset = io_tx_reset; // @[FC.scala 314:54]
  assign crack_pkt_seen_tx_demet_io_in = crack_pkt_seen_rx; // @[Stdcell.scala 59:17]
  assign bundleOut_0_crc_crcgen_io_in = link_data; // @[Nodes.scala 1207:84 FC.scala 627:25]
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      state <= 3'h0;
    end else if (_fe_rx_ptr_in_T) begin
      state <= 3'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        state <= 3'h1;
      end
    end else if (state == 3'h1) begin
      if (auto_tx_out_advance) begin
        state <= _GEN_34;
      end
    end else if (state == 3'h2) begin
      state <= _GEN_51;
    end else begin
      state <= _GEN_181;
    end
  end
  // -------------------------------------------------------------------------
  // SoC Labs F-1.5 was attempted here in commit 09cc0ec but caused master PS
  // kernel-hang on first doorbell ring post-deploy on build #6 — see
  // docs/BUILD6_HW_VALIDATION_2026_05_30.md. The "force state→4 on watchdog"
  // priority clause synthesized in a way that wedges the AHB bridge
  // catastrophically (not just a sticky bit). Re-design needed before
  // re-attempting; the current file ships F-1 only.
  // -------------------------------------------------------------------------
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_data_id_1 <= 8'ha1;
    end else if (out_f_wivalid_7) begin
      swi_data_id_1 <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      // SoC Labs 2026-06-14: default disable_crc=1 (GPIO-speed deployment).
      // Silicon-confirmed: V2 long DATA packets arrive but header-CRC fails
      // (crc_errors saturates) -> FCSM SEND_NACK -> no enqueue. At 6.25 MHz the
      // BER is negligible so CRC is pure overhead (REGISTER_MAP.md "key register
      // for GPIO-speed deployments"). Default-on also sidesteps die_b's
      // hardware-unwritable SM Control reg. SW can still re-enable via bit[16].
      out_prepend_swi_disable_crc <= 1'h1;
    end else if (out_f_wivalid_6) begin
      out_prepend_swi_disable_crc <= auto_in_pwdata[16];
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      crc_errors <= 16'h0;
    end else if (en_ff2_rx_demet_io_out) begin
      if (crc_corrupt) begin
        if (!(crc_errors == 16'hffff)) begin
          crc_errors <= _crc_errors_in_T_2;
        end
      end
    end else begin
      crc_errors <= 16'h0;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_cr_id <= 8'h44;
    end else if (out_f_wivalid) begin
      swi_cr_id <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_crack_id <= 8'h45;
    end else if (out_f_wivalid_1) begin
      out_prepend_swi_crack_id <= auto_in_pwdata[15:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_ack_id <= 8'h46;
    end else if (out_f_wivalid_2) begin
      out_prepend_swi_ack_id <= auto_in_pwdata[23:16];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_nack_id <= 8'h47;
    end else if (out_f_wivalid_3) begin
      out_prepend_swi_nack_id <= auto_in_pwdata[31:24];
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      last_good_pkt <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      last_good_pkt <= 8'h0;
    end else if (exp_pkt_seen) begin
      last_good_pkt <= exp_pkt_num;
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      fe_rx_credit_max <= 8'h0;
    // SoC Labs credit-ring fix (Bug-C, 2026-06-05): the synchronous re-zero
    //   end else if (_fe_tx_credit_max_in_T) fe_rx_credit_max <= 8'h0;
    // (where _fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out, the demet'd
    // app-enable) is REMOVED. On silicon swi_enable can dip low for a few
    // cycles during the LL-swreset / data-mode bootstrap AFTER the CR/CRACK
    // grant (0x1f) has loaded the ring; the re-zero then collapsed the credit
    // ring to 0 and sustained delivery wedged ("credit decays, never
    // replenishes"). The grant is established by CR/CRACK and only a real
    // io_rx_reset or a fresh CR/CRACK should change it.
    end else if (_fe_tx_credit_max_in_T_1) begin
      fe_rx_credit_max <= auto_rx_in_word_count[15:8];
    end
  end
  // SoC Labs credit-ring CDC fix: 2-flop io_tx_clk synchronizer for the
  // rx-written credit modulus. The tx-domain ring math (ne_rx_ptr_next /
  // fe_rx_ptr_msb above) reads fe_rx_credit_max_txsync, never the raw
  // fe_rx_credit_max register, which crosses from io_rx_clk to io_tx_clk.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      fe_rx_credit_max_txsync_meta <= 8'h0;
      fe_rx_credit_max_txsync      <= 8'h0;
    end else begin
      fe_rx_credit_max_txsync_meta <= fe_rx_credit_max;
      fe_rx_credit_max_txsync      <= fe_rx_credit_max_txsync_meta;
    end
  end
  // SoC Labs (FPGA bring-up fix, 2026-05-08): make cr_pkt_seen_rx and
  // crack_pkt_seen_rx fully sticky once set. On FPGA the proc_sys_reset
  // re-pulses io_rx_reset until clk_wiz locks; the original code would
  // clear the latched bit, leaving the master never seeing the slave's
  // crack and the FCSM wedging at state=1. The synchronous clear via
  // `_fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out` is also dropped
  // because the swi_enable-rx synchronizer can dip low transiently during
  // the same reset window. These latches are pure "have I ever seen a
  // cr/crack pkt?" markers used only to advance state 1 -> 2; channel
  // disable/re-enable is normally handled by full POR (`reset` here),
  // which still asynchronously re-zeroes them. Normal sim bring-up is
  // unaffected because in steady state these signals don't toggle.
  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      cr_pkt_seen_rx <= 1'h0;
    end else begin
      cr_pkt_seen_rx <= pkt_is_cr_pkt | cr_pkt_seen_rx;
    end
  end
  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      crack_pkt_seen_rx <= 1'h0;
    end else begin
      crack_pkt_seen_rx <= pkt_is_crack_pkt | crack_pkt_seen_rx;
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      exp_pkt_num <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      exp_pkt_num <= 8'h0;
    end else if (socl_l9_resync_now) begin
      // SoC Labs L9: jump exp_pkt_num to ll_rx_pktnum + 1 (wrap on fe_tx_credit_max).
      if (ll_rx_pktnum == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= ll_rx_pktnum + 8'h1;
      end
    end else if (socl_l9b_reanchor_now) begin
      // SoC Labs L9b: BOUNDED FORWARD RE-ANCHOR. An isolated forward gap is
      // forgiven: jump exp_pkt_num to ll_rx_pktnum + 1 (same wrap as L9), accept
      // the skipped slot(s) as best-effort loss, and keep committing. No NACK is
      // emitted for this cycle (enqueue suppressed above), so die_a does not
      // revert -> no replay storm. The hold-down counter (below) then disarms
      // the re-anchor for SOCL_L9B_HOLD_PKTS packets.
      if (ll_rx_pktnum == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= ll_rx_pktnum + 8'h1;
      end
    end else if (exp_pkt_seen) begin
      if (exp_pkt_num == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= _exp_pkt_num_in_T_3;
      end
    end
  end
  // SoC Labs L9b (2026-06-01): bind first_data_seen_rx reset domain to
  // io_rx_reset (matching the exp_pkt_num always block at L980). Without
  // this, an LL-swreset pulse during bringup re-zeros exp_pkt_num while
  // leaving the POR-domain sticky high -> L9 is permanently disarmed at
  // exactly the moment it's needed. Also re-arm on the sync app-enable
  // demet de-assertion, which is the other path that re-zeros exp_pkt_num.
  // Both reset sources here exactly match the two zero-paths in the
  // exp_pkt_num always block so the two regs are guaranteed to clear
  // together. POR is still implicit via io_rx_reset wiring.
  // See docs/BUGC_DEEP_DEBUG_2026_06_01.md §3.1.
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      socl_l9_first_data_seen_rx <= 1'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      socl_l9_first_data_seen_rx <= 1'h0;
    end else begin
      socl_l9_first_data_seen_rx <= pkt_is_data_pkt
                                    | socl_l9_first_data_seen_rx;
    end
  end
  // SoC Labs L9b BOUNDED FORWARD RE-ANCHOR hold-down counter (io_rx_clk domain,
  // same reset/zero domains as exp_pkt_num so it tracks the credit-ring state).
  //   * Reloads to SOCL_L9B_HOLD_PKTS the cycle a re-anchor fires -> the
  //     re-anchor is DISARMED (socl_l9b_reanchor_now gated on hold==0) for the
  //     next SOCL_L9B_HOLD_PKTS data packets. This bounds re-anchors to at most
  //     one per window so a sustained mismatch burst cannot walk exp forward
  //     packet-by-packet (which would silently drop a long run of data); after
  //     a window without a re-anchor the link is presumed re-synced.
  //   * Otherwise DECREMENTS by one on each DATA packet (pkt_is_data_pkt), so
  //     the disarm window is measured in delivered packets, not raw clocks.
  //   * Cleared to 0 on reset / credit-ring re-zero so a fresh stream arms
  //     immediately.
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      socl_l9b_hold <= 4'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      socl_l9b_hold <= 4'h0;
    end else if (socl_l9b_reanchor_now) begin
      socl_l9b_hold <= SOCL_L9B_HOLD_PKTS;
    end else if (pkt_is_data_pkt & (socl_l9b_hold != 4'h0)) begin
      socl_l9b_hold <= socl_l9b_hold - 4'h1;
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      fe_tx_credit_max <= 8'h0;
    end else if (~en_ff2_rx_demet_io_out) begin
      fe_tx_credit_max <= 8'h0;
    end else if (pkt_is_cr_pkt | pkt_is_crack_pkt) begin
      fe_tx_credit_max <= auto_rx_in_word_count[7:0];
    end
  end
  // SoC Labs L6 producer-side fix: CR-emit counter.  Increments on every
  // (auto_tx_out_advance & sop) cycle while state==1, saturates at 0xFF.
  // Reset to 0 on tx_reset OR whenever FCSM is not in state 1 (so a return to
  // state 0 / a fresh enable pulse re-arms the gate).
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_l6_cr_emit_count <= 8'h0;
    end else if (state != 3'h1) begin
      socl_l6_cr_emit_count <= 8'h0;
    end else if (auto_tx_out_advance & sop) begin
      if (socl_l6_cr_emit_count != 8'hff)
        socl_l6_cr_emit_count <= socl_l6_cr_emit_count + 8'h1;
    end
  end
  // SoC Labs L7 min-CRACK-emit counter (mirror of socl_l6_cr_emit_count):
  // counts (auto_tx_out_advance & sop) cycles while state==2, saturates at 0xFF,
  // resets to 0 whenever the FCSM is not in state 2 (so a fresh entry re-arms it).
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_l7_crack_emit_count <= 8'h0;
    end else if (state != 3'h2) begin
      socl_l7_crack_emit_count <= 8'h0;
    end else if (auto_tx_out_advance & sop) begin
      if (socl_l7_crack_emit_count != 8'hff)
        socl_l7_crack_emit_count <= socl_l7_crack_emit_count + 8'h1;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      sop <= 1'h0;
    end else if (_ack_seen_before_T) begin
      sop <= _GEN_25;
    end else if (state == 3'h1) begin
      sop <= _GEN_35;
    end else if (state == 3'h2) begin
      if (auto_tx_out_advance) begin
        sop <= _GEN_40;
      end
    end else if (!(state == 3'h3)) begin
      sop <= _GEN_173;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      data_id <= 8'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        data_id <= swi_cr_id;
      end
    end else if (state == 3'h1) begin
      if (auto_tx_out_advance) begin
        // SoC Labs L6: keep emitting CR while the L6 min-emit gate is
        // un-met, even if cr_seen/crack_seen have already latched on the
        // synchronizer.  Once the gate is met the original Chisel mux
        // applies (transition to CRACK on cr/crack seen, else CR).
        if ((crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out)
            & socl_l6_cr_emit_gate_ok) begin
          data_id <= out_prepend_swi_crack_id;
        end else begin
          data_id <= swi_cr_id;
        end
      end
    end else if (state == 3'h2) begin
      if (auto_tx_out_advance) begin
        data_id <= _GEN_41;
      end
    end else if (!(state == 3'h3)) begin
      data_id <= _GEN_174;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      word_count <= 16'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        word_count <= 16'h1f1f;
      end
    end else if (state == 3'h1) begin
      if (auto_tx_out_advance) begin
        word_count <= 16'h1f1f;
      end
    end else if (state == 3'h2) begin
      if (auto_tx_out_advance) begin
        word_count <= _GEN_42;
      end
    end else if (!(state == 3'h3)) begin
      word_count <= _GEN_175;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      link_data <= 56'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        link_data <= 56'h0;
      end
    end else if (state == 3'h1) begin
      link_data <= _GEN_38;
    end else if (state == 3'h2) begin
      link_data <= _GEN_38;
    end else if (!(state == 3'h3)) begin
      link_data <= _GEN_176;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      count <= 8'h0;
    end else if (!(_ack_seen_before_T)) begin
      if (!(state == 3'h1)) begin
        if (state == 3'h2) begin
          if (auto_tx_out_advance) begin
            count <= _GEN_44;
          end
        end else if (state == 3'h3) begin
          count <= _GEN_53;
        end else begin
          count <= _GEN_170;
        end
      end
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      ack_seen_before <= 1'h0;
    end else if (state == 3'h0) begin
      ack_seen_before <= 1'h0;
    end else begin
      ack_seen_before <= isAckPacket | ack_seen_before;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      fe_rx_ptr <= 8'h0;
    end else if (~en_ff2_tx_demet_io_out) begin
      fe_rx_ptr <= 8'h0;
    end else if (isAckPacket | isNackPacket) begin
      fe_rx_ptr <= ack_nack_fifo_io_rdata[15:8];
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      ne_rx_ptr <= 8'h0;
    end else if (isNackPacket) begin
      ne_rx_ptr <= ack_nack_fifo_io_rdata[15:8];
    end else if (_ack_seen_before_T) begin
      ne_rx_ptr <= 8'h0;
    end else if (!(state == 3'h1)) begin
      if (!(state == 3'h2)) begin
        ne_rx_ptr <= _GEN_191;
      end
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      l2a_fifo_raddr_txclk_prev <= 5'h0;
    end else begin
      l2a_fifo_raddr_txclk_prev <= l2a_fifo_addr_to_tx_r_addr;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      send_ack_req <= 1'h0;
    end else if (_ack_seen_before_T) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else if (state == 3'h1) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else if (state == 3'h2) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else if (state == 3'h3) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else begin
      // SoC Labs credit-recovery (2026-06-05): OR the periodic re-emit re-arm
      // into the data-state send_ack_req assignment.  socl_reack_rearm only
      // pulses in states >=4 once the idle window elapses AND the peer is
      // behind (un-acked received packets) AND no NACK is pending -- so it
      // re-arms a fresh cumulative-ACK emit carrying last_good_pkt_from_rx,
      // unsticking the peer's fe_rx_ptr without advancing it past real data.
      send_ack_req <= _GEN_178 | socl_reack_rearm;
    end
  end
  // SoC Labs L7: AND-clear send_nack_req every cycle while bringup_forgive
  // is asserted, in every state.  This ensures a stale isNotExpPacket fifo
  // readout that latched before forgive armed still gets cleared.
  //
  // SoC Labs F-1: ALSO AND-clear with ~socl_l7_wdog_force_clear so the
  // state-7 watchdog provides a routing-insensitive backup recovery path
  // for the case where the demet stickies fail to align in time.  Real
  // CRC errors disarm the watchdog via socl_l7_real_crc_seen so this AND
  // is harmless once any genuine link error has been observed.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      send_nack_req <= 1'h0;
    end else if (_ack_seen_before_T) begin
      send_nack_req <= (send_nack_req | (crcCorruptSeen | isNotExpPacket_l9)) & ~socl_l7_bringup_forgive & ~socl_l7_wdog_force_clear;
    end else if (state == 3'h1) begin
      send_nack_req <= (send_nack_req | (crcCorruptSeen | isNotExpPacket_l9)) & ~socl_l7_bringup_forgive & ~socl_l7_wdog_force_clear;
    end else if (state == 3'h2) begin
      send_nack_req <= (send_nack_req | (crcCorruptSeen | isNotExpPacket_l9)) & ~socl_l7_bringup_forgive & ~socl_l7_wdog_force_clear;
    end else if (state == 3'h3) begin
      send_nack_req <= (send_nack_req | (crcCorruptSeen | isNotExpPacket_l9)) & ~socl_l7_bringup_forgive & ~socl_l7_wdog_force_clear;
    end else begin
      send_nack_req <= _GEN_172 & ~socl_l7_bringup_forgive & ~socl_l7_wdog_force_clear;
    end
  end
  // SoC Labs L7: sticky "have we ever reached LINK_DATA" register.  Latches
  // on the first cycle FCSM observes state==5.  Permanently disarms the
  // bringup_forgive gate so steady-state behaviour matches upstream.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_l7_reached_link_data <= 1'h0;
    end else if (state == 3'h5) begin
      socl_l7_reached_link_data <= 1'h1;
    end
  end
  // SoC Labs F-1: sticky "real CRC error ever observed" register.
  // Latches on the first cycle the ack_nack_fifo dequeues a 3'h4 tag
  // (crcCorruptSeen).  Once high, permanently disarms the state-7
  // watchdog for the lifetime of this reset cycle -- production silicon
  // with genuine link errors continues to NACK exactly per upstream.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_l7_real_crc_seen <= 1'h0;
    end else if (crcCorruptSeen) begin
      socl_l7_real_crc_seen <= 1'h1;
    end
  end
  // SoC Labs F-1: state-7 dwell counter.  Increments every cycle the FCSM
  // is in state 7 with no real CRC observed since reset.  Resets to 0
  // whenever state != 3'h7 -- so a transient legitimate visit to state 7
  // never accumulates count.  Saturates at SOCL_L7_WDOG_THRESHOLD so the
  // force-clear holds steady until the FCSM advances out of state 7,
  // then the counter resets back to 0 on the next cycle.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_l7_wdog_cnt <= 16'h0;
    end else if (state != 3'h7) begin
      socl_l7_wdog_cnt <= 16'h0;
    end else if (socl_l7_real_crc_seen) begin
      socl_l7_wdog_cnt <= 16'h0;
    end else if (socl_l7_wdog_cnt != SOCL_L7_WDOG_THRESHOLD) begin
      socl_l7_wdog_cnt <= socl_l7_wdog_cnt + 16'h1;
    end
  end
  // SoC Labs credit-recovery (2026-06-05): receiver-side periodic ACK
  // re-emission idle counter (io_tx_clk domain).  Counts only while the link is
  // in a data state (>=4) and this side owns received data to re-ACK
  // (socl_reack_have_rx).  Resets to 0 whenever fresh in-order data arrives
  // (socl_reack_fresh_data) -- i.e. whenever the credit-return stream is alive
  // and minting fresh cumulative ACKs.  Crucially it does NOT reset on a
  // re-emitted ACK alone, so once the idle window elapses the saturated count
  // holds and socl_reack_rearm pulses (gated to at most once per window by the
  // socl_reack_fired sticky).  Saturates at SOCL_REACK_THRESHOLD.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_reack_idle_cnt <= 16'h0;
    end else if (socl_reack_fresh_data | (state != 3'h4 & state != 3'h5)) begin
      // Reset whenever fresh in-order data arrives (credit-return stream alive)
      // or we leave the data-phase states (4/5). have_rx is enforced only at
      // re-arm time, not here, to keep this reset path purely a function of
      // defined registers.
      socl_reack_idle_cnt <= 16'h0;
    end else if (socl_reack_idle_cnt != SOCL_REACK_THRESHOLD) begin
      socl_reack_idle_cnt <= socl_reack_idle_cnt + 16'h1;
    end
  end
  // SoC Labs credit-recovery (2026-06-05): "refresh already fired this idle
  // window" sticky.  SET when a re-emit re-arm fires (socl_reack_rearm), so the
  // periodic refresh emits AT MOST ONCE per idle window and never spams a
  // healthy-but-quiescent link.  CLEARED whenever fresh in-order data arrives
  // (the peer has resumed and is minting real ACKs again) -- arming the next
  // refresh only if the stall recurs.
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_reack_fired <= 1'h0;
    end else if (socl_reack_fresh_data | (state < 3'h4)) begin
      socl_reack_fired <= 1'h0;
    end else if (socl_reack_rearm) begin
      socl_reack_fired <= 1'h1;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      last_good_pkt_from_rx <= 8'h0;
    end else if (_fe_rx_ptr_in_T) begin
      last_good_pkt_from_rx <= 8'h0;
    end else if (isExpPacket) begin
      last_good_pkt_from_rx <= ack_nack_fifo_io_rdata[7:0];
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      last_ack_pkt_sent <= 8'h0;
    end else if (_ack_seen_before_T) begin
      last_ack_pkt_sent <= 8'h0;
    end else if (!(state == 3'h1)) begin
      if (!(state == 3'h2)) begin
        if (!(state == 3'h3)) begin
          last_ack_pkt_sent <= _GEN_171;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_link_en_wait <= 8'h8;
    end else if (out_f_wivalid_4) begin
      swi_link_en_wait <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_ack_dly_count <= 8'h7;
    end else if (out_f_wivalid_5) begin
      out_prepend_swi_ack_dly_count <= auto_in_pwdata[15:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_almost_full <= 3'h6;
    end else if (out_f_wivalid_16) begin
      out_prepend_swi_almost_full <= auto_in_pwdata[10:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_almost_empty <= 3'h2;
    end else if (out_f_wivalid_18) begin
      out_prepend_swi_almost_empty <= auto_in_pwdata[18:16];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      taken <= 1'h0;
    end else if (_T_70) begin
      taken <= 1'h0;
    end else begin
      taken <= _GEN_313;
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
  state = _RAND_0[2:0];
  _RAND_1 = {1{`RANDOM}};
  swi_data_id_1 = _RAND_1[7:0];
  _RAND_2 = {1{`RANDOM}};
  out_prepend_swi_disable_crc = _RAND_2[0:0];
  _RAND_3 = {1{`RANDOM}};
  crc_errors = _RAND_3[15:0];
  _RAND_4 = {1{`RANDOM}};
  swi_cr_id = _RAND_4[7:0];
  _RAND_5 = {1{`RANDOM}};
  out_prepend_swi_crack_id = _RAND_5[7:0];
  _RAND_6 = {1{`RANDOM}};
  out_prepend_swi_ack_id = _RAND_6[7:0];
  _RAND_7 = {1{`RANDOM}};
  out_prepend_swi_nack_id = _RAND_7[7:0];
  _RAND_8 = {1{`RANDOM}};
  last_good_pkt = _RAND_8[7:0];
  _RAND_9 = {1{`RANDOM}};
  fe_rx_credit_max = _RAND_9[7:0];
  fe_rx_credit_max_txsync_meta = _RAND_9[7:0];
  fe_rx_credit_max_txsync = _RAND_9[7:0];
  _RAND_10 = {1{`RANDOM}};
  cr_pkt_seen_rx = _RAND_10[0:0];
  _RAND_11 = {1{`RANDOM}};
  crack_pkt_seen_rx = _RAND_11[0:0];
  _RAND_12 = {1{`RANDOM}};
  exp_pkt_num = _RAND_12[7:0];
  _RAND_13 = {1{`RANDOM}};
  fe_tx_credit_max = _RAND_13[7:0];
  _RAND_14 = {1{`RANDOM}};
  sop = _RAND_14[0:0];
  _RAND_15 = {1{`RANDOM}};
  data_id = _RAND_15[7:0];
  _RAND_16 = {1{`RANDOM}};
  word_count = _RAND_16[15:0];
  _RAND_17 = {2{`RANDOM}};
  link_data = _RAND_17[55:0];
  _RAND_18 = {1{`RANDOM}};
  count = _RAND_18[7:0];
  _RAND_19 = {1{`RANDOM}};
  ack_seen_before = _RAND_19[0:0];
  _RAND_20 = {1{`RANDOM}};
  fe_rx_ptr = _RAND_20[7:0];
  _RAND_21 = {1{`RANDOM}};
  ne_rx_ptr = _RAND_21[7:0];
  _RAND_22 = {1{`RANDOM}};
  l2a_fifo_raddr_txclk_prev = _RAND_22[4:0];
  _RAND_23 = {1{`RANDOM}};
  send_ack_req = _RAND_23[0:0];
  _RAND_24 = {1{`RANDOM}};
  send_nack_req = _RAND_24[0:0];
  _RAND_25 = {1{`RANDOM}};
  last_good_pkt_from_rx = _RAND_25[7:0];
  _RAND_26 = {1{`RANDOM}};
  last_ack_pkt_sent = _RAND_26[7:0];
  _RAND_27 = {1{`RANDOM}};
  swi_link_en_wait = _RAND_27[7:0];
  _RAND_28 = {1{`RANDOM}};
  out_prepend_swi_ack_dly_count = _RAND_28[7:0];
  _RAND_29 = {1{`RANDOM}};
  out_prepend_swi_almost_full = _RAND_29[2:0];
  _RAND_30 = {1{`RANDOM}};
  out_prepend_swi_almost_empty = _RAND_30[2:0];
  _RAND_31 = {1{`RANDOM}};
  taken = _RAND_31[0:0];
`endif // RANDOMIZE_REG_INIT
  if (io_tx_reset) begin
    state = 3'h0;
  end
  if (reset) begin
    swi_data_id_1 = 8'ha1;
  end
  if (reset) begin
    out_prepend_swi_disable_crc = 1'h0;
  end
  if (io_rx_reset) begin
    crc_errors = 16'h0;
  end
  if (reset) begin
    swi_cr_id = 8'h44;
  end
  if (reset) begin
    out_prepend_swi_crack_id = 8'h45;
  end
  if (reset) begin
    out_prepend_swi_ack_id = 8'h46;
  end
  if (reset) begin
    out_prepend_swi_nack_id = 8'h47;
  end
  if (io_rx_reset) begin
    last_good_pkt = 8'h0;
  end
  if (io_rx_reset) begin
    fe_rx_credit_max = 8'h0;
  end
  if (io_tx_reset) begin
    fe_rx_credit_max_txsync_meta = 8'h0;
    fe_rx_credit_max_txsync = 8'h0;
  end
  if (io_rx_reset) begin
    cr_pkt_seen_rx = 1'h0;
  end
  if (io_rx_reset) begin
    crack_pkt_seen_rx = 1'h0;
  end
  if (io_rx_reset) begin
    exp_pkt_num = 8'h0;
  end
  if (io_rx_reset) begin
    fe_tx_credit_max = 8'h0;
  end
  if (io_tx_reset) begin
    sop = 1'h0;
  end
  if (io_tx_reset) begin
    data_id = 8'h0;
  end
  if (io_tx_reset) begin
    word_count = 16'h0;
  end
  if (io_tx_reset) begin
    link_data = 56'h0;
  end
  if (io_tx_reset) begin
    count = 8'h0;
  end
  if (io_tx_reset) begin
    ack_seen_before = 1'h0;
  end
  if (io_tx_reset) begin
    fe_rx_ptr = 8'h0;
  end
  // SoC Labs credit-recovery (2026-06-05): init the periodic re-ACK regs so
  // they hold defined values from time 0 even before the first io_tx_reset.
  socl_reack_idle_cnt = 16'h0;
  socl_reack_fired    = 1'h0;
  if (io_tx_reset) begin
    ne_rx_ptr = 8'h0;
  end
  if (io_tx_reset) begin
    l2a_fifo_raddr_txclk_prev = 5'h0;
  end
  if (io_tx_reset) begin
    send_ack_req = 1'h0;
  end
  if (io_tx_reset) begin
    send_nack_req = 1'h0;
  end
  if (io_tx_reset) begin
    last_good_pkt_from_rx = 8'h0;
  end
  if (io_tx_reset) begin
    last_ack_pkt_sent = 8'h0;
  end
  if (reset) begin
    swi_link_en_wait = 8'h8;
  end
  if (reset) begin
    out_prepend_swi_ack_dly_count = 8'h7;
  end
  if (reset) begin
    out_prepend_swi_almost_full = 3'h6;
  end
  if (reset) begin
    out_prepend_swi_almost_empty = 3'h2;
  end
  if (reset) begin
    taken = 1'h0;
  end
  // SoC Labs L9: sticky reg POR-init (RANDOMIZE_REG_INIT clean — matches
  // socl_l7_reached_link_data convention; no _RAND_NN needed because the
  // sticky tracks a strictly monotonic observation).
  if (reset) begin
    socl_l9_first_data_seen_rx = 1'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS

  // ===========================================================================
  // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap)
  //
  //   For a sustained A->B long-DATA send, latch (io_rx_clk domain — recovered
  //   RX, same as cr_pkt_seen_rx) whether the FCSM ever:
  //     - saw a DATA packet decode (pkt_is_data_pkt: header data_id == 0xa1);
  //     - accepted one via the L9 one-shot resync (socl_l9_resync_now);
  //     - hit a pktnum MISMATCH on a data packet after the resync
  //       (exp_pkt_not_seen_l9) -> the FCSM one-shot-resync failure mode;
  //     - drove l2a_fc_replay_app_valid (a data word actually enqueued to the
  //       L2A replay buffer = delivery succeeded);
  //   plus the FIRST observed ll_rx_pktnum and the last exp_pkt_num, so SW can
  //   read the actual numbers that mismatched.
  //
  //   Decode (io_obs_fcsmcap):
  //     (b) FCSM one-shot resync : data_ever=1, l9_resync_ever=1,
  //         pktnum_mismatch_ever=1, l2a_valid_ever=0 (or only the 1st enqueued)
  //     (a) EYE/framer (header never decodes as data) : data_ever=0
  //     clean delivery : data_ever=1, l2a_valid_ever=1, mismatch_ever=0
  //
  //   Pure read-only fan-out of FCSM nets — datapath bit-identical. Reset is
  //   the FCSM async `reset` (full POR), same as cr_pkt_seen_rx. Sticky /
  //   capture-once -> safe per-field 2-flop sync into apb_clk.
  // ===========================================================================
  reg        fcsmcap_data_ever;
  reg        fcsmcap_l9_resync_ever;
  reg        fcsmcap_mismatch_ever;
  reg        fcsmcap_l2a_valid_ever;
  reg        fcsmcap_first_pktnum_seen;
  reg [7:0]  fcsmcap_first_pktnum;
  reg [7:0]  fcsmcap_last_exp_pktnum;

  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      fcsmcap_data_ever         <= 1'b0;
      fcsmcap_l9_resync_ever    <= 1'b0;
      fcsmcap_mismatch_ever     <= 1'b0;
      fcsmcap_l2a_valid_ever    <= 1'b0;
      fcsmcap_first_pktnum_seen <= 1'b0;
      fcsmcap_first_pktnum      <= 8'h0;
      fcsmcap_last_exp_pktnum   <= 8'h0;
    end else begin
      if (pkt_is_data_pkt)       fcsmcap_data_ever      <= 1'b1;
      if (socl_l9_resync_now)    fcsmcap_l9_resync_ever <= 1'b1;
      if (exp_pkt_not_seen_l9)   fcsmcap_mismatch_ever  <= 1'b1;
      if (l2a_fc_replay_app_valid) fcsmcap_l2a_valid_ever <= 1'b1;
      // Capture the FIRST data-packet pktnum, and snapshot the live exp_pkt_num
      // each time a data packet decodes (so SW reads the mismatching pair).
      if (pkt_is_data_pkt & ~fcsmcap_first_pktnum_seen) begin
        fcsmcap_first_pktnum_seen <= 1'b1;
        fcsmcap_first_pktnum      <= ll_rx_pktnum;
      end
      if (pkt_is_data_pkt)
        fcsmcap_last_exp_pktnum <= exp_pkt_num;
    end
  end

  // io_obs_fcsmcap = {marker 0xC1, ever-flags[3:0], 4'b0,
  //                   first_pktnum[7:0], last_exp_pktnum[7:0]}
  assign io_obs_fcsmcap = {8'hC1,
                           fcsmcap_data_ever,       // [23] DATA pkt EVER decoded
                           fcsmcap_l9_resync_ever,  // [22] L9 one-shot resync EVER
                           fcsmcap_mismatch_ever,   // [21] pktnum MISMATCH EVER
                           fcsmcap_l2a_valid_ever,  // [20] L2A app_valid EVER (enqueued)
                           4'b0,                    // [19:16] reserved
                           fcsmcap_first_pktnum,    // [15:8] first observed ll_rx_pktnum
                           fcsmcap_last_exp_pktnum};// [7:0]  last exp_pkt_num (data pkt)

  // ===========================================================================
  // SoC Labs PER-BEAT PKTNUM CAPTURE 2026-07-01 (beatcap)
  //
  //   A 32-entry buffer in the io_rx_clk domain (recovered RX clock — the exact
  //   domain in which ll_rx_pktnum / exp_pkt_num / auto_rx_in_valid live, so the
  //   capture is bit-cycle-accurate to the FCSM's own view of the wire). One
  //   entry is written per io_rx_clk cycle WHILE auto_rx_in_valid (data present),
  //   starting from an ARM rising edge, until the 32nd entry is written — then
  //   the buffer FREEZES (frozen=1, wptr saturates at 32) so the FIRST 32 valid
  //   beats of the armed burst are preserved for readout.
  //
  //   Entry bit-packing (io_obs_capdata[31:0]) — MSB..LSB:
  //     [31:24] ll_rx_pktnum[7:0]      received pktnum on this beat (auto_rx_in_data[7:0])
  //     [23:16] exp_pkt_num[7:0]       FCSM expected pktnum at this beat
  //     [15]    exp_pkt_seen           pkt_is_data_pkt & pktnum==exp (a MATCH/advance beat)
  //     [14]    exp_pkt_not_seen       pkt_is_data_pkt & pktnum!=exp (a MISMATCH beat)
  //     [13]    auto_rx_in_sop         start-of-packet on this beat
  //     [12]    auto_rx_in_valid       always 1 for a captured beat (sanity)
  //     [11]    pkt_is_data_pkt        header decoded as a DATA packet
  //     [10]    socl_l9b_reanchor_now  L9b bounded forward re-anchor fired this beat
  //     [9:8]   2'b0                   reserved
  //     [7:0]   entry_index[7:0]       the wptr at capture (0..31) — ordering marker
  //
  //   Pure read-only observer of existing FCSM nets — NO functional change to the
  //   FC datapath (disable_crc / L9b untouched). Reset is the FCSM async POR.
  // ===========================================================================
  reg  [31:0] beatcap_mem [0:31];
  reg  [5:0]  beatcap_wptr;      // fill count 0..32 (6b so 32 is representable)
  reg         beatcap_frozen;
  // arm rising-edge detect: 2-flop sync io_cap_arm (apb_clk level) into io_rx_clk
  reg         beatcap_arm_meta;
  reg         beatcap_arm_sync;
  reg         beatcap_arm_sync_q;
  wire        beatcap_arm_rise = beatcap_arm_sync & ~beatcap_arm_sync_q;
  wire        beatcap_capturing = ~beatcap_frozen & (beatcap_wptr < 6'd32);
  wire        beatcap_do_write  = beatcap_capturing & auto_rx_in_valid;

  wire [31:0] beatcap_entry = {ll_rx_pktnum,          // [31:24]
                               exp_pkt_num,           // [23:16]
                               exp_pkt_seen,          // [15]
                               exp_pkt_not_seen,      // [14]
                               auto_rx_in_sop,        // [13]
                               auto_rx_in_valid,      // [12]
                               pkt_is_data_pkt,       // [11]
                               socl_l9b_reanchor_now, // [10]
                               2'b0,                  // [9:8]
                               2'b0, beatcap_wptr[5:0]};// [7:0] entry_index = wptr (zero-ext)

  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      beatcap_wptr       <= 6'd0;
      beatcap_frozen     <= 1'b0;
      beatcap_arm_meta   <= 1'b0;
      beatcap_arm_sync   <= 1'b0;
      beatcap_arm_sync_q <= 1'b0;
    end else begin
      beatcap_arm_meta   <= io_cap_arm;
      beatcap_arm_sync   <= beatcap_arm_meta;
      beatcap_arm_sync_q <= beatcap_arm_sync;
      if (beatcap_arm_rise) begin
        // Re-arm: clear the ring and unfreeze.
        beatcap_wptr   <= 6'd0;
        beatcap_frozen <= 1'b0;
      end else if (beatcap_do_write) begin
        beatcap_mem[beatcap_wptr[4:0]] <= beatcap_entry;
        if (beatcap_wptr == 6'd31)
          beatcap_frozen <= 1'b1;   // 32nd write -> freeze
        beatcap_wptr <= beatcap_wptr + 6'd1;
      end
    end
  end

  // Readout mux: present the rptr-selected entry. Buffer is frozen before the
  // controller walks rptr, so this reads stable data across the CDC.
  assign io_obs_capdata = beatcap_mem[io_cap_rptr];
  assign io_obs_capstat = {beatcap_frozen, 2'b0, beatcap_wptr};

endmodule
