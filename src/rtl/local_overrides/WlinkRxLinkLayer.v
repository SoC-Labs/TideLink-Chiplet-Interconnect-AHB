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
// =============================================================================
// Local override of deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v
//
// Override reason (tdif-08, Layer 4 fix): post-reset hunt-holdoff for the
// byte-align FSM to prevent the slave-side asymmetric stuck-at-state==1 bug.
//
// L5 strengthening (tdif-10, 2026-05-25)
// --------------------------------------
// The L4-v3 "first_short_pkt_seen" sticky gate was previously bootstrapping
// on stray bytes (e.g. corrected_ph[7:0]=0x0c) which are NOT in the SWI
// data_id whitelist {cr_id=0x44, crack_id=0x45, ack_id=0x46, nack_id=0x47}.
// Assessment test_05 in feat/assessment-driven-tests proved this: the framer
// committed to long-packet state on garbage, master's cr_pkt_seen then failed
// to latch, link diverged asymmetric.
//
// L5 fix: strengthen first_short_pkt_seen update so it ONLY latches when:
//   (1) state==0 (bootstrap window)
//   (2) is_short_pkt asserted (length <= short_packet_max)
//   (3) ecc_check_corrupted is FALSE (clean OR ECC-corrected header)
//   (4) corrected_ph[7:0] matches one of the four SWI bringup IDs
// Condition (3) is already in is_short_pkt; condition (4) is the new gate.
//
// Module now exposes io_swi_cr_id / io_swi_crack_id / io_swi_ack_id /
// io_swi_nack_id input ports; the single instance in Wlink.v wires these
// to the FCSM compile-time defaults (0x44/0x45/0x46/0x47) which matches
// WlinkGenericFCSM_6 reset values for swi_cr_id, out_prepend_swi_crack_id,
// out_prepend_swi_ack_id, out_prepend_swi_nack_id.
//
// Background
// ----------
// The bringup sequence is: set training mode, recal cycle, drop training,
// swreset LL ctrl. During the early window of this sequence (before master
// emits structured Wlink framing), master sends per-lane TRAINING_BYTE
// filler (0xa3, 0xb5, ...). Slave's WavD2DGpio deserialises these. Then
// slave's WlinkRxLinkLayer framer sees ph[7:0]=0xa3 > short_packet_max=0x7F
// → is_long_pkt asserts → state 0→1 latches a phony long packet expecting
// ~163 words that never arrive. State stays at 1 forever, ignoring every
// subsequent valid CR packet from master.
//
// Bisect evidence (cocotb/wlink_pair/test_ll_rx_bisect.py 2026-05-25):
//   sample-cyc 91-93: state=0 ph=0xc9b5a3 is_long_pkt=1
//   sample-cyc 94: state=1 (LATCHED on training filler)
//   sample-cyc 94..3099: state==1 for entire remaining 3006 cycles
//   master.io_link_data has cr_byte=16, slave.io_link_data has cr_byte=16
//   → master TX OK, slave RX deserialiser OK; bug is in framer state FSM
//
// Fix (tdif-08, Layer 4)
// ----------------------
// Add a 6-bit hunt_holdoff counter that resets to 6'h3F (=63) on every
// `reset` (POR + LL swreset both wire here through llrx_reset). While
// state==0 and hunt_holdoff!=0, the counter decrements; the is_long_pkt →
// state==1 transition is GATED until hunt_holdoff reaches 0. Gives upstream
// PHY/byte-window 64 link_clk cycles to drain training filler bytes before
// the framer commits to a long-packet branch. On real CR packets (post-
// training, structured framing), the holdoff has expired and the FSM
// operates normally.
//
// Sim coverage gate
// -----------------
// cocotb/wlink_pair/test_paired_recal_to_link_data.py::test_01_symmetric
// (and the 12/12 fuzz in test_asymmetric_failure_fuzz.py) MUST flip from
// FAIL → PASS after this override is applied.
//
// Author: SoC Labs (2026-05-25)
// =============================================================================
module WlinkRxLinkLayer(
  input          clock,
  input          reset,
  output         auto_out_sop,
  output [7:0]   auto_out_data_id,
  output [15:0]  auto_out_word_count,
  output [111:0] auto_out_data,
  output         auto_out_valid,
  output [15:0]  auto_out_crc,
  input          io_enable,
  input  [7:0]   io_swi_short_packet_max,
  // SoC Labs L5 (tdif-10, 2026-05-25): SWI bringup-packet data_id whitelist
  // — gates first_short_pkt_seen so only real CR/CRACK/ACK/NACK shorts can
  // bootstrap the framer (not stray bytes like 0x0c that happen to be < 0x7F).
  input  [7:0]   io_swi_cr_id,
  input  [7:0]   io_swi_crack_id,
  input  [7:0]   io_swi_ack_id,
  input  [7:0]   io_swi_nack_id,
  input  [7:0]   io_active_lanes,
  input  [7:0]   io_lane_mask,
  output         io_ecc_corrected,
  output         io_ecc_corrupted,
  input  [127:0] io_link_data,
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 2) — DEFAULT-OFF
  // ROBUST framer re-hunt source. The internal full-128 sync_detected (:295)
  // never fires on silicon if any lane's SYNC slice is off the eye. The PHY's
  // mask-aware per-lane detector (tidelink_phy_sync_detect, on the same
  // post-deskew word) fires even then, and Wlink.v gates its pulse by the
  // SWI_SYNC_ROBUST_DETECT control bit (Region 8 slot 0 bit[4], default 0)
  // before driving this port. With it 0 the port is held 0 (Wlink.v drives 0),
  // so sync_resync (:299) is BIT-IDENTICAL to the full-128-only behaviour. When
  // 1 a mask-aware match additionally triggers the framer re-hunt — but never
  // STRIPS the word (effective_link_data still keys off the local full-128
  // sync_detected only), so a robust-but-not-exact match re-aligns the framer
  // without zeroing a beat. Tie 0 in environments without the chiplet
  // controller (V1 / cocotb default) — preserves legacy behaviour exactly.
  input          io_robust_sync_seen,
  output         io_in_error_state,
  // SoC Labs credit-path observability (read-only APB exposure of the
  // byte-align FSM internals — replaces the ILA debug core). These mirror
  // existing internal nets; promoting them to outputs is structurally
  // free, downstream connections inside this module are unchanged. All in
  // the `clock` (recovered RX link clock) domain — 2-flop-synced into
  // apb_clk by axi_chiplet_controller.sv.
  output [1:0]   io_obs_state,        // byte-align FSM state (==2 -> error)
  output         io_obs_is_short_pkt, // short-packet detect
  output         io_obs_is_long_pkt,  // long-packet detect
  output         io_obs_valid,        // LL_RX has a valid packet
  // SoC Labs 2026-06-08: cross-lane-skew observability. One-cycle pulse each
  // time the assembled 128-bit RX word equals the PHY SYNC delimiter
  // (sync_detected, :289). Lets SW confirm the RX ever sees a COHERENT SYNC on
  // HW — the direct indicator that the lane-deskew is delivering aligned words.
  // Counted (16-bit saturating) in the RX-link-clock domain up in Wlink.v.
  output         io_obs_sync_detected, // assembled word == SYNC_WORD (1-cy pulse)
  // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — localises
  // exactly WHERE a sustained A->B multi-beat long-DATA packet dies on silicon.
  // The slow APB-OBS poll (~0.5 s/sample vs ~4.7 MHz link) MISSES the
  // first-long-packet transient; these latch it in the `clock` (recovered RX
  // link clock) domain so a later APB read still sees it. Two packed 32-bit
  // words, 2-flop-synced to apb_clk by axi_chiplet_controller.sv, read at the
  // new Region D (SoC MMIO 0x4403_21A0 / 0x4403_21A4). Pure read-only fan-outs
  // of internal framer nets — datapath unchanged. See the rxcap block below.
  //   io_obs_rxcap0 = {marker 0xC0, ever flags, state, captured corrected_ph}
  //   io_obs_rxcap1 = {max_byte_count, long-pkt-start sat. counter}
  output [31:0]  io_obs_rxcap0,
  output [31:0]  io_obs_rxcap1
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
  reg [31:0] _RAND_17;
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
`endif // RANDOMIZE_REG_INIT
  wire  enable_ff2_demet_clock; // @[Stdcell.scala 58:23]
  wire  enable_ff2_demet_reset; // @[Stdcell.scala 58:23]
  wire  enable_ff2_demet_io_in; // @[Stdcell.scala 58:23]
  wire  enable_ff2_demet_io_out; // @[Stdcell.scala 58:23]
  wire [23:0] ecc_check_ph_in; // @[LinkLayer.scala 639:35]
  wire [7:0] ecc_check_rx_ecc; // @[LinkLayer.scala 639:35]
  wire [7:0] ecc_check_calc_ecc; // @[LinkLayer.scala 639:35]
  wire [23:0] ecc_check_corrected_ph; // @[LinkLayer.scala 639:35]  SoC Labs ILA — ECC-corrected PH (feat/phc-ila-debug)
  wire  ecc_check_corrected; // @[LinkLayer.scala 639:35]  SoC Labs ILA — ECC corrected flag (feat/phc-ila-debug)
  wire  ecc_check_corrupted; // @[LinkLayer.scala 639:35]  SoC Labs ILA — ECC fail flag (feat/phc-ila-debug)
  reg [1:0] state; // @[LinkLayer.scala 611:44]  SoC Labs ILA (feat/phc-ila-debug)
  // SoC Labs tdif-08 L4 fix v3 (2026-05-25): "first_short_pkt_seen" gate.
  // ----- NEUTRALISED 2026-05-25 by option (c) in Wlink.v override -----
  // The v3 consumer-side gate (commit 92c2ec7) was partial (5/12 fuzz
  // PASS). Superseded by producer-side fix: Wlink.v override now holds
  // llrx_reset HIGH for the entire training/recal window
  // (swi_training_mode_rxsync_1). By the time reset deasserts, the
  // master TX is in FC data mode, so the long_pkt_gate is no longer
  // necessary -- the very first observable byte is a real CR short
  // packet.
  //
  // We keep the register declaration so the always-block below still
  // synthesises, but force `long_pkt_gate=1'b1` so this file becomes a
  // functional no-op vs the base Wlink RTL. Keeping the file in the
  // flist preserves the attributes used by
  // the ILA capture pipeline (see reference_phc_ila_capture.md). The
  // dead `first_short_pkt_seen` reg will be pruned by synthesis.
  // tdif-10 visibility (2026-05-25): expose first_short_pkt_seen to the
  // ILA. The bit is currently a no-op (long_pkt_gate forced to 1) but
  // observing it on HW confirms whether the framer has ever seen a real
  // short CR packet (1) or has been stuck on filler the whole time (0).
  reg       first_short_pkt_seen;        // tdif-10 ILA — L4-v3 gate witness
  // L5 (tdif-10, 2026-05-25): re-enable the v3 sticky gate. Long-packet
  // entry is gated until a whitelisted SHORT bringup packet has been
  // observed in state==0 — see strengthened latch logic below.
  //
  // SoC Labs P1 fix stage 2 (2026-07-03): a WELL-FORMED LONG HEADER opens
  // the gate itself, combinationally. Silicon proof sequence: with the
  // widened short whitelist, the gate re-latched from keepalives and the
  // NACK/replay chain then recovered ALL previously swallowed words
  // (exp 0x01->0x04, sack=4) — but under continuous burst pressure the
  // opening short never crossed and 64/64 longs were swallowed with the
  // gate stuck 0. An ECC-clean long header (is_long_pkt includes
  // ~ecc_check_corrupted) with a KNOWN FC data_id and a sane word_count is
  // itself the "link is well-framed" evidence L5 wanted: accept it and let
  // it latch the gate for the 0-lane path too. Known long data_ids: the
  // Wlink FC node families aw/w/b/ar/r = 0x80-0x84, gb = 0xa0, tl = 0xa1.
  wire      wellformed_long_hdr;  // assigned below, after is_long_pkt/len_ok/ph decls
  wire      long_pkt_gate = first_short_pkt_seen | wellformed_long_hdr;
  wire  _io_in_error_state_T = state == 2'h2; // @[LinkLayer.scala 614:53]
  reg  io_in_error_state_REG; // @[LinkLayer.scala 614:45]
  reg [7:0] ll_byte_index_0; // @[LinkLayer.scala 622:32]  SoC Labs ILA — decoded data_id
  reg [7:0] ll_byte_index_1; // @[LinkLayer.scala 622:32]  SoC Labs ILA — per-lane byte index
  reg [7:0] ll_byte_index_2; // @[LinkLayer.scala 622:32]  SoC Labs ILA — per-lane byte index
  reg [7:0] ll_byte_index_3; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_4; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_5; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_6; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_7; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_8; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_9; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_10; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_11; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_12; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_13; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_14; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_15; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_16; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_17; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_18; // @[LinkLayer.scala 622:32]
  reg [7:0] ll_byte_index_19; // @[LinkLayer.scala 622:32]
  reg [7:0] byte0_reg; // @[LinkLayer.scala 633:36]  SoC Labs ILA
  reg [7:0] byte1_reg; // @[LinkLayer.scala 635:36]  SoC Labs ILA
  // tdif-10 visibility (2026-05-25): valid_byte_reg gates every framer
  // state transition. ILA-visible so we can correlate state==1 hangs with
  // whether the framer is still receiving bytes from the deser front-end.
  wire  valid_byte_reg = |byte0_reg | |byte1_reg; // @[LinkLayer.scala 636:43]  tdif-10 ILA — byte-valid gate
  wire [23:0] corrected_ph = ecc_check_corrected_ph; // @[LinkLayer.scala 641:33 LinkLayer.scala 642:27]  SoC Labs ILA — corrected packet header (feat/phc-ila-debug)
  wire  _is_short_pkt_T_5 = ~ecc_check_corrupted; // @[LinkLayer.scala 643:111]
  wire  is_short_pkt = corrected_ph[7:0] <= io_swi_short_packet_max & corrected_ph[7:0] != 8'h0 & ~ecc_check_corrupted; // @[LinkLayer.scala 643:108]  SoC Labs ILA — short packet detect (feat/phc-ila-debug)
  wire  is_long_pkt = corrected_ph[7:0] > io_swi_short_packet_max & _is_short_pkt_T_5; // @[LinkLayer.scala 644:76]  SoC Labs ILA — long packet detect (feat/phc-ila-debug)
  // SoC Labs S->M framer-wedge fix (2026-06-03): bound the candidate
  // long-packet word_count before allowing the framer to commit to
  // state==1 (long-packet mode). Root cause: the MASTER's framer latched
  // a TRAINING-FILLER word as a giant long packet with a phantom
  // word_count (~60180). Its only exit (endOfPacket) needs ~word_count+6
  // bytes (~20k cycles) so the framer never returned to hunt (state 0),
  // auto_out_valid never asserted, and the master never decoded slave
  // packets (tl_fc_l2a_valid=0, pair_credit_counter stuck at 0).
  //
  // The candidate length about to be loaded into word_count is
  // ecc_check_corrected_ph[23:8] (see _GEN_8/_GEN_38). The real link's
  // max packet is small (FCSM credit/FIFO depth is a handful of words),
  // so any header claiming more words than LONG_PKT_WORD_MAX is a
  // mis-aligned filler, not a legitimate long packet. 64 words is a
  // comfortable bound above the largest legal AHB burst payload while
  // still rejecting the ~60k phantom lengths seen on filler.
  localparam [15:0] LONG_PKT_WORD_MAX = 16'd64; // S->M wedge guard
  wire long_pkt_len_ok = ecc_check_corrected_ph[23:8] <= LONG_PKT_WORD_MAX; // candidate word_count plausible
  // SoC Labs P1 fix stage 2 (2026-07-03): assignment for the forward-declared
  // wellformed_long_hdr (see the long_pkt_gate declaration above for the full
  // rationale). ECC-clean long header + sane word_count + KNOWN FC long
  // data_id (aw/w/b/ar/r 0x80-0x84, gb 0xa0, tl 0xa1) self-opens the gate.
  assign wellformed_long_hdr = is_long_pkt && long_pkt_len_ok &&
                               ((corrected_ph[7:0] >= 8'h80 &&
                                 corrected_ph[7:0] <= 8'h84) ||
                                (corrected_ph[7:0] == 8'ha0) ||
                                (corrected_ph[7:0] == 8'ha1));
  reg  is_short_pkt_prev; // @[LinkLayer.scala 646:36]  SoC Labs ILA (feat/phc-ila-debug)
  reg  valid; // @[LinkLayer.scala 650:36]  SoC Labs ILA — LL_RX has valid packet (feat/phc-ila-debug)
  // tdif-10 visibility (2026-05-25): word_count is the framer's "how far
  // through the long packet am I" counter -- when state latches state==1 on
  // training filler this counts up toward word_count_in (~163 for filler
  // 0xa3) and never wraps. ILA-visible so we see the false-long-pkt depth.
  reg [15:0] word_count; // @[LinkLayer.scala 652:36]  tdif-10 ILA — long-pkt progress counter
  reg [16:0] byte_count; // @[LinkLayer.scala 657:36]
  wire [7:0] _bytesPerCycle_T_1 = io_active_lanes + 8'h1; // @[LinkLayer.scala 658:44]
  wire [8:0] bytesPerCycle = {_bytesPerCycle_T_1, 1'h0}; // @[LinkLayer.scala 658:51]  SoC Labs ILA — bytes per cycle (lane count)
  wire  _T = state == 2'h0; // @[LinkLayer.scala 693:16]
  wire  _T_5 = ~is_short_pkt_prev; // @[LinkLayer.scala 706:33]
  wire [15:0] _GEN_8 = is_long_pkt & ~is_short_pkt_prev ? ecc_check_corrected_ph[23:8] : word_count; // @[LinkLayer.scala 706:52 LinkLayer.scala 711:37 LinkLayer.scala 686:29]
  wire [15:0] _GEN_17 = valid_byte_reg ? _GEN_8 : word_count; // @[LinkLayer.scala 697:31 LinkLayer.scala 686:29]
  wire [15:0] _GEN_38 = is_long_pkt ? ecc_check_corrected_ph[23:8] : word_count; // @[LinkLayer.scala 725:30 LinkLayer.scala 731:37 LinkLayer.scala 686:29]
  wire [15:0] _GEN_51 = io_active_lanes == 8'h0 ? _GEN_17 : _GEN_38; // @[LinkLayer.scala 696:35]
  wire [15:0] _GEN_72 = enable_ff2_demet_io_out ? _GEN_51 : word_count; // @[LinkLayer.scala 695:41 LinkLayer.scala 686:29]
  wire [15:0] word_count_in = state == 2'h0 ? _GEN_72 : word_count; // @[LinkLayer.scala 693:40 LinkLayer.scala 686:29]
  wire [15:0] topIndex = word_count_in + 16'h6; // @[LinkLayer.scala 661:43]
  wire [16:0] _GEN_887 = {{8'd0}, bytesPerCycle}; // @[LinkLayer.scala 659:48]
  wire [16:0] _endOfPacket_T_1 = byte_count + _GEN_887; // @[LinkLayer.scala 659:48]
  wire [16:0] _GEN_888 = {{1'd0}, topIndex}; // @[LinkLayer.scala 662:43]
  wire  endOfPacket = _endOfPacket_T_1 >= _GEN_888; // @[LinkLayer.scala 662:43]
  wire [1:0] _rxLanePos_T_59 = io_lane_mask[1] + io_lane_mask[2]; // @[Bitwise.scala 47:55]
  wire [1:0] _GEN_889 = {{1'd0}, io_lane_mask[0]}; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLanePos_T_61 = _GEN_889 + _rxLanePos_T_59; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLanePos_T_63 = io_lane_mask[3] + io_lane_mask[4]; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLanePos_T_65 = io_lane_mask[5] + io_lane_mask[6]; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLanePos_T_67 = _rxLanePos_T_63 + _rxLanePos_T_65; // @[Bitwise.scala 47:55]
  wire [2:0] _GEN_890 = {{1'd0}, _rxLanePos_T_61[1:0]}; // @[Bitwise.scala 47:55]
  wire [3:0] _rxLanePos_T_69 = _GEN_890 + _rxLanePos_T_67; // @[Bitwise.scala 47:55]
  wire [2:0] rxLanePos_6 = _rxLanePos_T_69[2:0]; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLaneCount_T_8 = io_lane_mask[0] + io_lane_mask[1]; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLaneCount_T_10 = io_lane_mask[2] + io_lane_mask[3]; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLaneCount_T_12 = _rxLaneCount_T_8 + _rxLaneCount_T_10; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLaneCount_T_14 = io_lane_mask[4] + io_lane_mask[5]; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLaneCount_T_16 = io_lane_mask[6] + io_lane_mask[7]; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLaneCount_T_18 = _rxLaneCount_T_14 + _rxLaneCount_T_16; // @[Bitwise.scala 47:55]
  wire [3:0] rxLaneCount = _rxLaneCount_T_12 + _rxLaneCount_T_18; // @[Bitwise.scala 47:55]
  wire [3:0] _GEN_891 = {{1'd0}, rxLanePos_6}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_97 = _GEN_891 + rxLaneCount; // @[LinkLayer.scala 774:44]
  // ===========================================================================
  // SoC Labs SYNC re-align (2026-06-06): periodic in-band re-sync delimiter.
  //
  // ROOT CAUSE (silicon, sustained load): this RX framer locks byte-alignment
  // once via the byte-counter FSM (state/byte_count/word_count) and has NO
  // delimiter to re-hunt with. A single mid-stream word SLIP (deskew bubble /
  // dropped word) permanently desyncs byte_count; thereafter every packet —
  // including the credit-return ACKs — is mis-framed and silently dropped
  // (ECC stays 0, it is NOT corruption). The credit ring then fills and the
  // link wedges.
  //
  // FIX (Interlaken metaframe / Aurora sync-header / 802.3 alignment-marker
  // class): the TX glue (WavD2DGpio.v) injects ONE payload-unique 128-bit
  // SYNC word every N link words during DATA mode, in an idle/gap slot so it
  // never displaces real data. Here on RX we detect that exact word, and on a
  // match we (a) STRIP it (substitute an all-zero idle word so it is never
  // framed — low byte 0x00 makes is_short_pkt=0 and is_long_pkt=0), and (b)
  // pulse `sync_resync` for one cycle, which synchronously resets state /
  // byte_count / word_count back to the hunt/packet-start. The very next
  // real link word therefore re-aligns to a known packet boundary.
  //
  // SYNC_WORD payload-uniqueness: a real link word produced by the LL TX
  // always carries a valid ECC-checkable Wlink header in its low bytes
  // (data_id ∈ {0x44 cr, 0x45 crack, 0x46 ack, 0x47 nack, 0xa1 data} with a
  // matching length+ECC). SYNC_WORD's low byte is 0x00 (an invalid length, so
  // it cannot be a legitimate header) and the upper 120 bits are a fixed
  // descending nibble ramp the encoder never emits — so the full 128-bit
  // constant cannot collide with any encodable packet word.
  // ===========================================================================
  localparam [127:0] SYNC_WORD =
      128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00;
  // SoC Labs MASK-AWARE SYNC detect (2026-06-22): the original full-128 equality
  // `io_link_data == SYNC_WORD` can NEVER fire under a reduced-lane mask, because
  // the PHY TX zeroes masked lanes on the wire (tidelink_gpio_phy_tx.sv:71-72
  // `lane_mask[gi] ? sel_w : 0`). Under e.g. 0xE4 (lanes {2,5,6,7} active) the
  // received SYNC beat carries 16'h0000 on lanes {0,1,3,4}, so the full-128
  // constant compare is geometrically dead -> sync_detected never pulses -> both
  // the STRIP (effective_link_data below) and the re-hunt (sync_resync below) are
  // dead, and the framer cannot re-align after any byte/word boundary slip on a
  // reduced-lane link. Compare ONLY the active-lane 16-bit slices, selected by
  // io_lane_mask[7:0] (an input at :85): a masked-out lane is a don't-care
  // (~io_lane_mask[L] forces its term to 1). This REDUCES EXACTLY to the prior
  // full-128 compare when io_lane_mask == 8'hFF (every ~mask term is 0, so each
  // lane_match[L] is the bare slice equality and the AND is the full-128 ==), so
  // the default full-mask path is bit-identical. SYNC-slice uniqueness still holds
  // on the active subset: SYNC_WORD's low byte is 0x00 (an invalid Wlink length,
  // so a SYNC beat can never alias a real header) and the upper-lane slices are a
  // fixed descending-nibble ramp the encoder never emits, so even without lane 0
  // the active-lane slices cannot collide with any encodable packet word.
  wire [7:0] sync_lane_match;
  genvar sync_li;
  generate
    for (sync_li = 0; sync_li < 8; sync_li = sync_li + 1) begin : g_sync_lane_match
      assign sync_lane_match[sync_li] =
          ~io_lane_mask[sync_li] |
          (io_link_data[16*sync_li +: 16] == SYNC_WORD[16*sync_li +: 16]);
    end
  endgenerate
  wire        sync_detected = &sync_lane_match;
  // Re-sync pulse: only meaningful in data mode (io_enable high, training
  // gating is upstream in the PHY glue — SYNC is never injected during
  // training so this is naturally quiescent then).
  // SoC Labs PART 2 (2026-06-15): OR the PHY's mask-aware per-lane SYNC match
  // (io_robust_sync_seen, already gated by SWI_SYNC_ROBUST_DETECT up in Wlink.v
  // — held 0 by default) into the re-hunt term ONLY. The full-128 sync_detected
  // still solely drives the STRIP (effective_link_data below), so a robust match
  // re-aligns the framer without zeroing a beat. Default 0 -> bit-identical.
  wire        sync_resync   = (sync_detected | io_robust_sync_seen) & io_enable; // SoC Labs 2026-06-07: always reset to hunt on SYNC. Safe because the TX data==0 gate (WavD2DGpio.v) inserts SYNC ONLY between real packets (bus truly idle), so a reset never lands inside a real packet — and it re-aligns the framer even from a post-slip fake state==1 (which a state!=1 guard would wrongly skip)
  // SoC Labs P2 mid-packet-abort fix (2026-07-03): honor the SYNC re-hunt ONLY
  // at a framer BOUNDARY (state 0 hunt / state 2 error), NEVER inside a long-
  // packet BODY (state 1). The :379 "SYNC only in idle slots" premise holds for
  // the idle-gated inserter, but SWI_SYNC_FORCE_ALWAYS (deps/tidelink-phy
  // WavD2DGpio.v drops the idle term) emits a SYNC every 32 words regardless of
  // idle, so a beacon can land mid-body; the old unconditional reset then forced
  // state 1->0 and zeroed byte/word_count, SILENTLY discarding the half-parsed
  // long packet (no valid/eop/CRC/error -> FCSM-blind, same class as P1).
  // Deferring the re-hunt past state==1 lets the packet reach endOfPacket; the
  // next inter-packet SYNC (state 0) still re-aligns; slipped state==1 still
  // self-recovers via the wedge guard (word_count>LONG_PKT_WORD_MAX) and the
  // monotone byte_count -> endOfPacket. INERT on the proven data path: with SYNC
  // insert OFF sync_resync==0, so sync_resync_boundary==0 identically.
  wire        sync_resync_boundary = sync_resync & (state != 2'h1);
  // Strip: feed the framer an all-zero idle word on the SYNC cycle so the
  // delimiter itself is never interpreted as packet bytes.
  wire [127:0] effective_link_data = sync_detected ? 128'h0 : io_link_data;
  wire [15:0] link_data_lane_index_7 = effective_link_data[127:112]; // @[LinkLayer.scala 781:46]
  wire [1:0] _rxLanePos_T_42 = io_lane_mask[1] + io_lane_mask[2]; // @[Bitwise.scala 47:55]
  wire [1:0] _GEN_892 = {{1'd0}, io_lane_mask[0]}; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLanePos_T_44 = _GEN_892 + _rxLanePos_T_42; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLanePos_T_46 = io_lane_mask[4] + io_lane_mask[5]; // @[Bitwise.scala 47:55]
  wire [1:0] _GEN_893 = {{1'd0}, io_lane_mask[3]}; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLanePos_T_48 = _GEN_893 + _rxLanePos_T_46; // @[Bitwise.scala 47:55]
  wire [2:0] rxLanePos_5 = _rxLanePos_T_44[1:0] + _rxLanePos_T_48[1:0]; // @[Bitwise.scala 47:55]
  wire [3:0] _GEN_894 = {{1'd0}, rxLanePos_5}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_94 = _GEN_894 + rxLaneCount; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_6 = effective_link_data[111:96]; // @[LinkLayer.scala 781:46]
  wire [1:0] _rxLanePos_T_28 = io_lane_mask[0] + io_lane_mask[1]; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLanePos_T_30 = io_lane_mask[3] + io_lane_mask[4]; // @[Bitwise.scala 47:55]
  wire [1:0] _GEN_895 = {{1'd0}, io_lane_mask[2]}; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLanePos_T_32 = _GEN_895 + _rxLanePos_T_30; // @[Bitwise.scala 47:55]
  wire [2:0] rxLanePos_4 = _rxLanePos_T_28 + _rxLanePos_T_32[1:0]; // @[Bitwise.scala 47:55]
  wire [3:0] _GEN_896 = {{1'd0}, rxLanePos_4}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_91 = _GEN_896 + rxLaneCount; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_5 = effective_link_data[95:80]; // @[LinkLayer.scala 781:46]
  wire [1:0] _rxLanePos_T_17 = io_lane_mask[0] + io_lane_mask[1]; // @[Bitwise.scala 47:55]
  wire [1:0] _rxLanePos_T_19 = io_lane_mask[2] + io_lane_mask[3]; // @[Bitwise.scala 47:55]
  wire [2:0] rxLanePos_3 = _rxLanePos_T_17 + _rxLanePos_T_19; // @[Bitwise.scala 47:55]
  wire [3:0] _GEN_897 = {{1'd0}, rxLanePos_3}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_88 = _GEN_897 + rxLaneCount; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_4 = effective_link_data[79:64]; // @[LinkLayer.scala 781:46]
  wire [1:0] _rxLanePos_T_9 = io_lane_mask[1] + io_lane_mask[2]; // @[Bitwise.scala 47:55]
  wire [1:0] _GEN_898 = {{1'd0}, io_lane_mask[0]}; // @[Bitwise.scala 47:55]
  wire [2:0] _rxLanePos_T_11 = _GEN_898 + _rxLanePos_T_9; // @[Bitwise.scala 47:55]
  wire [1:0] rxLanePos_2 = _rxLanePos_T_11[1:0]; // @[Bitwise.scala 47:55]
  wire [3:0] _GEN_899 = {{2'd0}, rxLanePos_2}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_85 = _GEN_899 + rxLaneCount; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_3 = effective_link_data[63:48]; // @[LinkLayer.scala 781:46]
  wire [1:0] rxLanePos_1 = io_lane_mask[0] + io_lane_mask[1]; // @[Bitwise.scala 47:55]
  wire [3:0] _GEN_900 = {{2'd0}, rxLanePos_1}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_82 = _GEN_900 + rxLaneCount; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_2 = effective_link_data[47:32]; // @[LinkLayer.scala 781:46]
  wire [3:0] _GEN_901 = {{3'd0}, io_lane_mask[0]}; // @[LinkLayer.scala 774:44]
  wire [3:0] _T_79 = _GEN_901 + rxLaneCount; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_1 = effective_link_data[31:16]; // @[LinkLayer.scala 781:46]
  wire [4:0] _T_75 = {{1'd0}, rxLaneCount}; // @[LinkLayer.scala 774:44]
  wire [15:0] link_data_lane_index_0 = effective_link_data[15:0]; // @[LinkLayer.scala 781:46]
  wire [7:0] _GEN_479 = 4'h0 == _T_75[3:0] ? link_data_lane_index_0[15:8] : link_data_lane_index_0[7:0]; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_495 = io_lane_mask[0] ? _GEN_479 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_511 = ~io_lane_mask[0] ? link_data_lane_index_1[7:0] : _GEN_495; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_527 = 4'h0 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_511; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_543 = io_lane_mask[1] ? _GEN_527 : _GEN_495; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_559 = 2'h0 == rxLanePos_1 ? link_data_lane_index_2[7:0] : _GEN_543; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_575 = 4'h0 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_559; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_591 = io_lane_mask[2] ? _GEN_575 : _GEN_543; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_607 = 2'h0 == rxLanePos_2 ? link_data_lane_index_3[7:0] : _GEN_591; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_623 = 4'h0 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_607; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_639 = io_lane_mask[3] ? _GEN_623 : _GEN_591; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_655 = 3'h0 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_639; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_671 = 4'h0 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_655; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_687 = io_lane_mask[4] ? _GEN_671 : _GEN_639; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_703 = 3'h0 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_687; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_719 = 4'h0 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_703; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_735 = io_lane_mask[5] ? _GEN_719 : _GEN_687; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_751 = 3'h0 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_735; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_767 = 4'h0 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_751; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_783 = io_lane_mask[6] ? _GEN_767 : _GEN_735; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_799 = 3'h0 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_783; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_815 = 4'h0 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_799; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_0 = io_lane_mask[7] ? _GEN_815 : _GEN_783; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_480 = 4'h1 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_496 = io_lane_mask[0] ? _GEN_480 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_512 = io_lane_mask[0] ? link_data_lane_index_1[7:0] : _GEN_496; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_528 = 4'h1 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_512; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_544 = io_lane_mask[1] ? _GEN_528 : _GEN_496; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_560 = 2'h1 == rxLanePos_1 ? link_data_lane_index_2[7:0] : _GEN_544; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_576 = 4'h1 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_560; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_592 = io_lane_mask[2] ? _GEN_576 : _GEN_544; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_608 = 2'h1 == rxLanePos_2 ? link_data_lane_index_3[7:0] : _GEN_592; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_624 = 4'h1 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_608; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_640 = io_lane_mask[3] ? _GEN_624 : _GEN_592; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_656 = 3'h1 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_640; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_672 = 4'h1 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_656; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_688 = io_lane_mask[4] ? _GEN_672 : _GEN_640; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_704 = 3'h1 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_688; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_720 = 4'h1 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_704; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_736 = io_lane_mask[5] ? _GEN_720 : _GEN_688; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_752 = 3'h1 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_736; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_768 = 4'h1 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_752; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_784 = io_lane_mask[6] ? _GEN_768 : _GEN_736; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_800 = 3'h1 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_784; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_816 = 4'h1 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_800; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_1 = io_lane_mask[7] ? _GEN_816 : _GEN_784; // @[LinkLayer.scala 772:32]
  wire [23:0] _ecc_check_ph_in_T = {link_data_byte_index_0,byte1_reg,byte0_reg}; // @[Cat.scala 30:58]
  wire  _T_4 = is_short_pkt & _T_5; // @[LinkLayer.scala 700:31]
  wire [7:0] _GEN_1 = is_short_pkt & _T_5 ? ecc_check_corrected_ph[7:0] : ll_byte_index_0; // @[LinkLayer.scala 700:53 LinkLayer.scala 702:37 LinkLayer.scala 622:32]
  wire [7:0] _GEN_2 = is_short_pkt & _T_5 ? ecc_check_corrected_ph[15:8] : ll_byte_index_1; // @[LinkLayer.scala 700:53 LinkLayer.scala 703:37 LinkLayer.scala 622:32]
  wire [7:0] _GEN_3 = is_short_pkt & _T_5 ? ecc_check_corrected_ph[23:16] : ll_byte_index_2; // @[LinkLayer.scala 700:53 LinkLayer.scala 704:37 LinkLayer.scala 622:32]
  wire [2:0] _GEN_4 = is_long_pkt & ~is_short_pkt_prev ? 3'h4 : 3'h0; // @[LinkLayer.scala 706:52 LinkLayer.scala 707:37 LinkLayer.scala 694:35]
  wire [7:0] _GEN_5 = is_long_pkt & ~is_short_pkt_prev ? ecc_check_corrected_ph[7:0] : _GEN_1; // @[LinkLayer.scala 706:52 LinkLayer.scala 708:37]
  wire [7:0] _GEN_6 = is_long_pkt & ~is_short_pkt_prev ? ecc_check_corrected_ph[15:8] : _GEN_2; // @[LinkLayer.scala 706:52 LinkLayer.scala 709:37]
  wire [7:0] _GEN_7 = is_long_pkt & ~is_short_pkt_prev ? ecc_check_corrected_ph[23:16] : _GEN_3; // @[LinkLayer.scala 706:52 LinkLayer.scala 710:37]
  wire [1:0] _GEN_9 = is_long_pkt & ~is_short_pkt_prev ? 2'h1 : state; // @[LinkLayer.scala 706:52 LinkLayer.scala 712:37 LinkLayer.scala 684:29]
  wire [23:0] _GEN_10 = valid_byte_reg ? _ecc_check_ph_in_T : 24'h0; // @[LinkLayer.scala 697:31 LinkLayer.scala 698:37 LinkLayer.scala 690:29]
  wire [7:0] _GEN_11 = valid_byte_reg ? link_data_byte_index_1 : 8'h0; // @[LinkLayer.scala 697:31 LinkLayer.scala 699:37 LinkLayer.scala 691:29]
  wire  _GEN_12 = valid_byte_reg & _T_4; // @[LinkLayer.scala 697:31 LinkLayer.scala 685:29]
  wire [2:0] _GEN_16 = valid_byte_reg ? _GEN_4 : 3'h0; // @[LinkLayer.scala 697:31 LinkLayer.scala 694:35]
  wire [7:0] _GEN_481 = 4'h2 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_497 = io_lane_mask[0] ? _GEN_481 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [1:0] _GEN_902 = {{1'd0}, io_lane_mask[0]}; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_513 = 2'h2 == _GEN_902 ? link_data_lane_index_1[7:0] : _GEN_497; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_529 = 4'h2 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_513; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_545 = io_lane_mask[1] ? _GEN_529 : _GEN_497; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_561 = 2'h2 == rxLanePos_1 ? link_data_lane_index_2[7:0] : _GEN_545; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_577 = 4'h2 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_561; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_593 = io_lane_mask[2] ? _GEN_577 : _GEN_545; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_609 = 2'h2 == rxLanePos_2 ? link_data_lane_index_3[7:0] : _GEN_593; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_625 = 4'h2 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_609; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_641 = io_lane_mask[3] ? _GEN_625 : _GEN_593; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_657 = 3'h2 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_641; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_673 = 4'h2 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_657; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_689 = io_lane_mask[4] ? _GEN_673 : _GEN_641; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_705 = 3'h2 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_689; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_721 = 4'h2 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_705; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_737 = io_lane_mask[5] ? _GEN_721 : _GEN_689; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_753 = 3'h2 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_737; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_769 = 4'h2 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_753; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_785 = io_lane_mask[6] ? _GEN_769 : _GEN_737; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_801 = 3'h2 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_785; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_817 = 4'h2 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_801; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_2 = io_lane_mask[7] ? _GEN_817 : _GEN_785; // @[LinkLayer.scala 772:32]
  wire [23:0] _ecc_check_ph_in_T_1 = {link_data_byte_index_2,link_data_byte_index_1,link_data_byte_index_0}; // @[Cat.scala 30:58]
  wire [7:0] _GEN_20 = is_short_pkt ? ecc_check_corrected_ph[7:0] : ll_byte_index_0; // @[LinkLayer.scala 719:31 LinkLayer.scala 721:37 LinkLayer.scala 622:32]
  wire [7:0] _GEN_21 = is_short_pkt ? ecc_check_corrected_ph[15:8] : ll_byte_index_1; // @[LinkLayer.scala 719:31 LinkLayer.scala 722:37 LinkLayer.scala 622:32]
  wire [7:0] _GEN_22 = is_short_pkt ? ecc_check_corrected_ph[23:16] : ll_byte_index_2; // @[LinkLayer.scala 719:31 LinkLayer.scala 723:37 LinkLayer.scala 622:32]
  wire [16:0] _byte_count_in_T_2 = endOfPacket ? 17'h0 : _endOfPacket_T_1; // @[LinkLayer.scala 732:43]
  wire  _nstate_T = endOfPacket ? 1'h0 : 1'h1; // @[LinkLayer.scala 734:43]
  wire [7:0] _GEN_494 = 4'hf == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_510 = io_lane_mask[0] ? _GEN_494 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_526 = 4'hf == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_510; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_542 = 4'hf == _T_79 ? link_data_lane_index_1[15:8] : _GEN_526; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_558 = io_lane_mask[1] ? _GEN_542 : _GEN_510; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_574 = 4'hf == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_558; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_590 = 4'hf == _T_82 ? link_data_lane_index_2[15:8] : _GEN_574; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_606 = io_lane_mask[2] ? _GEN_590 : _GEN_558; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_622 = 4'hf == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_606; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_638 = 4'hf == _T_85 ? link_data_lane_index_3[15:8] : _GEN_622; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_654 = io_lane_mask[3] ? _GEN_638 : _GEN_606; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_670 = 4'hf == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_654; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_686 = 4'hf == _T_88 ? link_data_lane_index_4[15:8] : _GEN_670; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_702 = io_lane_mask[4] ? _GEN_686 : _GEN_654; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_718 = 4'hf == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_702; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_734 = 4'hf == _T_91 ? link_data_lane_index_5[15:8] : _GEN_718; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_750 = io_lane_mask[5] ? _GEN_734 : _GEN_702; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_766 = 4'hf == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_750; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_782 = 4'hf == _T_94 ? link_data_lane_index_6[15:8] : _GEN_766; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_798 = io_lane_mask[6] ? _GEN_782 : _GEN_750; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_814 = 4'hf == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_798; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_830 = 4'hf == _T_97 ? link_data_lane_index_7[15:8] : _GEN_814; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_15 = io_lane_mask[7] ? _GEN_830 : _GEN_798; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_493 = 4'he == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_509 = io_lane_mask[0] ? _GEN_493 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_525 = 4'he == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_509; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_541 = 4'he == _T_79 ? link_data_lane_index_1[15:8] : _GEN_525; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_557 = io_lane_mask[1] ? _GEN_541 : _GEN_509; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_573 = 4'he == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_557; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_589 = 4'he == _T_82 ? link_data_lane_index_2[15:8] : _GEN_573; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_605 = io_lane_mask[2] ? _GEN_589 : _GEN_557; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_621 = 4'he == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_605; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_637 = 4'he == _T_85 ? link_data_lane_index_3[15:8] : _GEN_621; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_653 = io_lane_mask[3] ? _GEN_637 : _GEN_605; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_669 = 4'he == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_653; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_685 = 4'he == _T_88 ? link_data_lane_index_4[15:8] : _GEN_669; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_701 = io_lane_mask[4] ? _GEN_685 : _GEN_653; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_717 = 4'he == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_701; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_733 = 4'he == _T_91 ? link_data_lane_index_5[15:8] : _GEN_717; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_749 = io_lane_mask[5] ? _GEN_733 : _GEN_701; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_765 = 4'he == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_749; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_781 = 4'he == _T_94 ? link_data_lane_index_6[15:8] : _GEN_765; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_797 = io_lane_mask[6] ? _GEN_781 : _GEN_749; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_813 = 4'he == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_797; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_829 = 4'he == _T_97 ? link_data_lane_index_7[15:8] : _GEN_813; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_14 = io_lane_mask[7] ? _GEN_829 : _GEN_797; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_492 = 4'hd == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_508 = io_lane_mask[0] ? _GEN_492 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_524 = 4'hd == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_508; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_540 = 4'hd == _T_79 ? link_data_lane_index_1[15:8] : _GEN_524; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_556 = io_lane_mask[1] ? _GEN_540 : _GEN_508; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_572 = 4'hd == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_556; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_588 = 4'hd == _T_82 ? link_data_lane_index_2[15:8] : _GEN_572; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_604 = io_lane_mask[2] ? _GEN_588 : _GEN_556; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_620 = 4'hd == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_604; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_636 = 4'hd == _T_85 ? link_data_lane_index_3[15:8] : _GEN_620; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_652 = io_lane_mask[3] ? _GEN_636 : _GEN_604; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_668 = 4'hd == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_652; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_684 = 4'hd == _T_88 ? link_data_lane_index_4[15:8] : _GEN_668; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_700 = io_lane_mask[4] ? _GEN_684 : _GEN_652; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_716 = 4'hd == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_700; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_732 = 4'hd == _T_91 ? link_data_lane_index_5[15:8] : _GEN_716; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_748 = io_lane_mask[5] ? _GEN_732 : _GEN_700; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_764 = 4'hd == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_748; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_780 = 4'hd == _T_94 ? link_data_lane_index_6[15:8] : _GEN_764; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_796 = io_lane_mask[6] ? _GEN_780 : _GEN_748; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_812 = 4'hd == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_796; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_828 = 4'hd == _T_97 ? link_data_lane_index_7[15:8] : _GEN_812; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_13 = io_lane_mask[7] ? _GEN_828 : _GEN_796; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_491 = 4'hc == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_507 = io_lane_mask[0] ? _GEN_491 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_523 = 4'hc == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_507; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_539 = 4'hc == _T_79 ? link_data_lane_index_1[15:8] : _GEN_523; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_555 = io_lane_mask[1] ? _GEN_539 : _GEN_507; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_571 = 4'hc == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_555; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_587 = 4'hc == _T_82 ? link_data_lane_index_2[15:8] : _GEN_571; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_603 = io_lane_mask[2] ? _GEN_587 : _GEN_555; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_619 = 4'hc == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_603; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_635 = 4'hc == _T_85 ? link_data_lane_index_3[15:8] : _GEN_619; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_651 = io_lane_mask[3] ? _GEN_635 : _GEN_603; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_667 = 4'hc == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_651; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_683 = 4'hc == _T_88 ? link_data_lane_index_4[15:8] : _GEN_667; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_699 = io_lane_mask[4] ? _GEN_683 : _GEN_651; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_715 = 4'hc == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_699; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_731 = 4'hc == _T_91 ? link_data_lane_index_5[15:8] : _GEN_715; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_747 = io_lane_mask[5] ? _GEN_731 : _GEN_699; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_763 = 4'hc == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_747; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_779 = 4'hc == _T_94 ? link_data_lane_index_6[15:8] : _GEN_763; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_795 = io_lane_mask[6] ? _GEN_779 : _GEN_747; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_811 = 4'hc == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_795; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_827 = 4'hc == _T_97 ? link_data_lane_index_7[15:8] : _GEN_811; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_12 = io_lane_mask[7] ? _GEN_827 : _GEN_795; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_490 = 4'hb == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_506 = io_lane_mask[0] ? _GEN_490 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_522 = 4'hb == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_506; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_538 = 4'hb == _T_79 ? link_data_lane_index_1[15:8] : _GEN_522; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_554 = io_lane_mask[1] ? _GEN_538 : _GEN_506; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_570 = 4'hb == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_554; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_586 = 4'hb == _T_82 ? link_data_lane_index_2[15:8] : _GEN_570; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_602 = io_lane_mask[2] ? _GEN_586 : _GEN_554; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_618 = 4'hb == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_602; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_634 = 4'hb == _T_85 ? link_data_lane_index_3[15:8] : _GEN_618; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_650 = io_lane_mask[3] ? _GEN_634 : _GEN_602; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_666 = 4'hb == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_650; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_682 = 4'hb == _T_88 ? link_data_lane_index_4[15:8] : _GEN_666; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_698 = io_lane_mask[4] ? _GEN_682 : _GEN_650; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_714 = 4'hb == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_698; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_730 = 4'hb == _T_91 ? link_data_lane_index_5[15:8] : _GEN_714; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_746 = io_lane_mask[5] ? _GEN_730 : _GEN_698; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_762 = 4'hb == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_746; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_778 = 4'hb == _T_94 ? link_data_lane_index_6[15:8] : _GEN_762; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_794 = io_lane_mask[6] ? _GEN_778 : _GEN_746; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_810 = 4'hb == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_794; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_826 = 4'hb == _T_97 ? link_data_lane_index_7[15:8] : _GEN_810; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_11 = io_lane_mask[7] ? _GEN_826 : _GEN_794; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_489 = 4'ha == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_505 = io_lane_mask[0] ? _GEN_489 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_521 = 4'ha == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_505; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_537 = 4'ha == _T_79 ? link_data_lane_index_1[15:8] : _GEN_521; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_553 = io_lane_mask[1] ? _GEN_537 : _GEN_505; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_569 = 4'ha == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_553; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_585 = 4'ha == _T_82 ? link_data_lane_index_2[15:8] : _GEN_569; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_601 = io_lane_mask[2] ? _GEN_585 : _GEN_553; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_617 = 4'ha == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_601; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_633 = 4'ha == _T_85 ? link_data_lane_index_3[15:8] : _GEN_617; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_649 = io_lane_mask[3] ? _GEN_633 : _GEN_601; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_665 = 4'ha == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_649; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_681 = 4'ha == _T_88 ? link_data_lane_index_4[15:8] : _GEN_665; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_697 = io_lane_mask[4] ? _GEN_681 : _GEN_649; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_713 = 4'ha == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_697; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_729 = 4'ha == _T_91 ? link_data_lane_index_5[15:8] : _GEN_713; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_745 = io_lane_mask[5] ? _GEN_729 : _GEN_697; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_761 = 4'ha == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_745; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_777 = 4'ha == _T_94 ? link_data_lane_index_6[15:8] : _GEN_761; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_793 = io_lane_mask[6] ? _GEN_777 : _GEN_745; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_809 = 4'ha == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_793; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_825 = 4'ha == _T_97 ? link_data_lane_index_7[15:8] : _GEN_809; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_10 = io_lane_mask[7] ? _GEN_825 : _GEN_793; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_488 = 4'h9 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_504 = io_lane_mask[0] ? _GEN_488 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_520 = 4'h9 == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_504; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_536 = 4'h9 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_520; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_552 = io_lane_mask[1] ? _GEN_536 : _GEN_504; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_568 = 4'h9 == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_552; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_584 = 4'h9 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_568; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_600 = io_lane_mask[2] ? _GEN_584 : _GEN_552; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_616 = 4'h9 == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_600; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_632 = 4'h9 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_616; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_648 = io_lane_mask[3] ? _GEN_632 : _GEN_600; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_664 = 4'h9 == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_648; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_680 = 4'h9 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_664; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_696 = io_lane_mask[4] ? _GEN_680 : _GEN_648; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_712 = 4'h9 == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_696; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_728 = 4'h9 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_712; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_744 = io_lane_mask[5] ? _GEN_728 : _GEN_696; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_760 = 4'h9 == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_744; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_776 = 4'h9 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_760; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_792 = io_lane_mask[6] ? _GEN_776 : _GEN_744; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_808 = 4'h9 == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_792; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_824 = 4'h9 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_808; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_9 = io_lane_mask[7] ? _GEN_824 : _GEN_792; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_487 = 4'h8 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_503 = io_lane_mask[0] ? _GEN_487 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_519 = 4'h8 == _GEN_901 ? link_data_lane_index_1[7:0] : _GEN_503; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_535 = 4'h8 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_519; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_551 = io_lane_mask[1] ? _GEN_535 : _GEN_503; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_567 = 4'h8 == _GEN_900 ? link_data_lane_index_2[7:0] : _GEN_551; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_583 = 4'h8 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_567; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_599 = io_lane_mask[2] ? _GEN_583 : _GEN_551; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_615 = 4'h8 == _GEN_899 ? link_data_lane_index_3[7:0] : _GEN_599; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_631 = 4'h8 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_615; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_647 = io_lane_mask[3] ? _GEN_631 : _GEN_599; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_663 = 4'h8 == _GEN_897 ? link_data_lane_index_4[7:0] : _GEN_647; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_679 = 4'h8 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_663; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_695 = io_lane_mask[4] ? _GEN_679 : _GEN_647; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_711 = 4'h8 == _GEN_896 ? link_data_lane_index_5[7:0] : _GEN_695; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_727 = 4'h8 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_711; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_743 = io_lane_mask[5] ? _GEN_727 : _GEN_695; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_759 = 4'h8 == _GEN_894 ? link_data_lane_index_6[7:0] : _GEN_743; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_775 = 4'h8 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_759; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_791 = io_lane_mask[6] ? _GEN_775 : _GEN_743; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_807 = 4'h8 == _GEN_891 ? link_data_lane_index_7[7:0] : _GEN_791; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_823 = 4'h8 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_807; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_8 = io_lane_mask[7] ? _GEN_823 : _GEN_791; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_486 = 4'h7 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_502 = io_lane_mask[0] ? _GEN_486 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [2:0] _GEN_960 = {{2'd0}, io_lane_mask[0]}; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_518 = 3'h7 == _GEN_960 ? link_data_lane_index_1[7:0] : _GEN_502; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_534 = 4'h7 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_518; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_550 = io_lane_mask[1] ? _GEN_534 : _GEN_502; // @[LinkLayer.scala 772:32]
  wire [2:0] _GEN_961 = {{1'd0}, rxLanePos_1}; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_566 = 3'h7 == _GEN_961 ? link_data_lane_index_2[7:0] : _GEN_550; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_582 = 4'h7 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_566; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_598 = io_lane_mask[2] ? _GEN_582 : _GEN_550; // @[LinkLayer.scala 772:32]
  wire [2:0] _GEN_962 = {{1'd0}, rxLanePos_2}; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_614 = 3'h7 == _GEN_962 ? link_data_lane_index_3[7:0] : _GEN_598; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_630 = 4'h7 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_614; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_646 = io_lane_mask[3] ? _GEN_630 : _GEN_598; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_662 = 3'h7 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_646; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_678 = 4'h7 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_662; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_694 = io_lane_mask[4] ? _GEN_678 : _GEN_646; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_710 = 3'h7 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_694; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_726 = 4'h7 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_710; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_742 = io_lane_mask[5] ? _GEN_726 : _GEN_694; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_758 = 3'h7 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_742; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_774 = 4'h7 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_758; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_790 = io_lane_mask[6] ? _GEN_774 : _GEN_742; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_806 = 3'h7 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_790; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_822 = 4'h7 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_806; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_7 = io_lane_mask[7] ? _GEN_822 : _GEN_790; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_485 = 4'h6 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_501 = io_lane_mask[0] ? _GEN_485 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_517 = 3'h6 == _GEN_960 ? link_data_lane_index_1[7:0] : _GEN_501; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_533 = 4'h6 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_517; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_549 = io_lane_mask[1] ? _GEN_533 : _GEN_501; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_565 = 3'h6 == _GEN_961 ? link_data_lane_index_2[7:0] : _GEN_549; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_581 = 4'h6 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_565; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_597 = io_lane_mask[2] ? _GEN_581 : _GEN_549; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_613 = 3'h6 == _GEN_962 ? link_data_lane_index_3[7:0] : _GEN_597; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_629 = 4'h6 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_613; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_645 = io_lane_mask[3] ? _GEN_629 : _GEN_597; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_661 = 3'h6 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_645; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_677 = 4'h6 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_661; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_693 = io_lane_mask[4] ? _GEN_677 : _GEN_645; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_709 = 3'h6 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_693; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_725 = 4'h6 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_709; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_741 = io_lane_mask[5] ? _GEN_725 : _GEN_693; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_757 = 3'h6 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_741; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_773 = 4'h6 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_757; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_789 = io_lane_mask[6] ? _GEN_773 : _GEN_741; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_805 = 3'h6 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_789; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_821 = 4'h6 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_805; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_6 = io_lane_mask[7] ? _GEN_821 : _GEN_789; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_484 = 4'h5 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_500 = io_lane_mask[0] ? _GEN_484 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_516 = 3'h5 == _GEN_960 ? link_data_lane_index_1[7:0] : _GEN_500; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_532 = 4'h5 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_516; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_548 = io_lane_mask[1] ? _GEN_532 : _GEN_500; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_564 = 3'h5 == _GEN_961 ? link_data_lane_index_2[7:0] : _GEN_548; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_580 = 4'h5 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_564; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_596 = io_lane_mask[2] ? _GEN_580 : _GEN_548; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_612 = 3'h5 == _GEN_962 ? link_data_lane_index_3[7:0] : _GEN_596; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_628 = 4'h5 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_612; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_644 = io_lane_mask[3] ? _GEN_628 : _GEN_596; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_660 = 3'h5 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_644; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_676 = 4'h5 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_660; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_692 = io_lane_mask[4] ? _GEN_676 : _GEN_644; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_708 = 3'h5 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_692; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_724 = 4'h5 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_708; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_740 = io_lane_mask[5] ? _GEN_724 : _GEN_692; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_756 = 3'h5 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_740; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_772 = 4'h5 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_756; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_788 = io_lane_mask[6] ? _GEN_772 : _GEN_740; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_804 = 3'h5 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_788; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_820 = 4'h5 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_804; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_5 = io_lane_mask[7] ? _GEN_820 : _GEN_788; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_483 = 4'h4 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_499 = io_lane_mask[0] ? _GEN_483 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_515 = 3'h4 == _GEN_960 ? link_data_lane_index_1[7:0] : _GEN_499; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_531 = 4'h4 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_515; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_547 = io_lane_mask[1] ? _GEN_531 : _GEN_499; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_563 = 3'h4 == _GEN_961 ? link_data_lane_index_2[7:0] : _GEN_547; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_579 = 4'h4 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_563; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_595 = io_lane_mask[2] ? _GEN_579 : _GEN_547; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_611 = 3'h4 == _GEN_962 ? link_data_lane_index_3[7:0] : _GEN_595; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_627 = 4'h4 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_611; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_643 = io_lane_mask[3] ? _GEN_627 : _GEN_595; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_659 = 3'h4 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_643; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_675 = 4'h4 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_659; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_691 = io_lane_mask[4] ? _GEN_675 : _GEN_643; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_707 = 3'h4 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_691; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_723 = 4'h4 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_707; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_739 = io_lane_mask[5] ? _GEN_723 : _GEN_691; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_755 = 3'h4 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_739; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_771 = 4'h4 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_755; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_787 = io_lane_mask[6] ? _GEN_771 : _GEN_739; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_803 = 3'h4 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_787; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_819 = 4'h4 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_803; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_4 = io_lane_mask[7] ? _GEN_819 : _GEN_787; // @[LinkLayer.scala 772:32]
  wire  _GEN_40 = is_long_pkt ? endOfPacket : is_short_pkt; // @[LinkLayer.scala 725:30 LinkLayer.scala 733:37]
  wire [23:0] _GEN_44 = io_active_lanes == 8'h0 ? _GEN_10 : _ecc_check_ph_in_T_1; // @[LinkLayer.scala 696:35 LinkLayer.scala 717:37]
  wire [7:0] _GEN_482 = 4'h3 == _T_75[3:0] ? link_data_lane_index_0[15:8] : 8'h0; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59 LinkLayer.scala 628:72]
  wire [7:0] _GEN_498 = io_lane_mask[0] ? _GEN_482 : 8'h0; // @[LinkLayer.scala 772:32 LinkLayer.scala 628:72]
  wire [7:0] _GEN_514 = 2'h3 == _GEN_902 ? link_data_lane_index_1[7:0] : _GEN_498; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_530 = 4'h3 == _T_79 ? link_data_lane_index_1[15:8] : _GEN_514; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_546 = io_lane_mask[1] ? _GEN_530 : _GEN_498; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_562 = 2'h3 == rxLanePos_1 ? link_data_lane_index_2[7:0] : _GEN_546; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_578 = 4'h3 == _T_82 ? link_data_lane_index_2[15:8] : _GEN_562; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_594 = io_lane_mask[2] ? _GEN_578 : _GEN_546; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_610 = 2'h3 == rxLanePos_2 ? link_data_lane_index_3[7:0] : _GEN_594; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_626 = 4'h3 == _T_85 ? link_data_lane_index_3[15:8] : _GEN_610; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_642 = io_lane_mask[3] ? _GEN_626 : _GEN_594; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_658 = 3'h3 == rxLanePos_3 ? link_data_lane_index_4[7:0] : _GEN_642; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_674 = 4'h3 == _T_88 ? link_data_lane_index_4[15:8] : _GEN_658; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_690 = io_lane_mask[4] ? _GEN_674 : _GEN_642; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_706 = 3'h3 == rxLanePos_4 ? link_data_lane_index_5[7:0] : _GEN_690; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_722 = 4'h3 == _T_91 ? link_data_lane_index_5[15:8] : _GEN_706; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_738 = io_lane_mask[5] ? _GEN_722 : _GEN_690; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_754 = 3'h3 == rxLanePos_5 ? link_data_lane_index_6[7:0] : _GEN_738; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_770 = 4'h3 == _T_94 ? link_data_lane_index_6[15:8] : _GEN_754; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] _GEN_786 = io_lane_mask[6] ? _GEN_770 : _GEN_738; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_802 = 3'h3 == rxLanePos_6 ? link_data_lane_index_7[7:0] : _GEN_786; // @[LinkLayer.scala 773:59 LinkLayer.scala 773:59]
  wire [7:0] _GEN_818 = 4'h3 == _T_97 ? link_data_lane_index_7[15:8] : _GEN_802; // @[LinkLayer.scala 774:59 LinkLayer.scala 774:59]
  wire [7:0] link_data_byte_index_3 = io_lane_mask[7] ? _GEN_818 : _GEN_786; // @[LinkLayer.scala 772:32]
  wire [7:0] _GEN_45 = io_active_lanes == 8'h0 ? _GEN_11 : link_data_byte_index_3; // @[LinkLayer.scala 696:35 LinkLayer.scala 718:37]
  wire  _GEN_46 = io_active_lanes == 8'h0 ? _GEN_12 : _GEN_40; // @[LinkLayer.scala 696:35]
  wire [23:0] _GEN_65 = enable_ff2_demet_io_out ? _GEN_44 : 24'h0; // @[LinkLayer.scala 695:41 LinkLayer.scala 690:29]
  wire [7:0] _GEN_66 = enable_ff2_demet_io_out ? _GEN_45 : 8'h0; // @[LinkLayer.scala 695:41 LinkLayer.scala 691:29]
  wire  _GEN_67 = enable_ff2_demet_io_out & _GEN_46; // @[LinkLayer.scala 695:41 LinkLayer.scala 685:29]
  wire [16:0] _T_10 = byte_count + 17'hf; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_86 = 5'h0 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_0; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_87 = 5'h1 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_1; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_88 = 5'h2 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_2; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_89 = 5'h3 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_3; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_90 = 5'h4 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_4; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_91 = 5'h5 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_5; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_92 = 5'h6 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_6; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_93 = 5'h7 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_7; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_94 = 5'h8 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_8; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_95 = 5'h9 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_9; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_96 = 5'ha == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_10; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_97 = 5'hb == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_11; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_98 = 5'hc == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_12; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_99 = 5'hd == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_13; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_100 = 5'he == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_14; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_101 = 5'hf == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_15; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_102 = 5'h10 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_16; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_103 = 5'h11 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_17; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_104 = 5'h12 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_18; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [7:0] _GEN_105 = 5'h13 == _T_10[4:0] ? link_data_byte_index_15 : ll_byte_index_19; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49 LinkLayer.scala 622:32]
  wire [16:0] _T_14 = byte_count + 17'he; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_106 = 5'h0 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_86; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_107 = 5'h1 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_87; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_108 = 5'h2 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_88; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_109 = 5'h3 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_89; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_110 = 5'h4 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_90; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_111 = 5'h5 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_91; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_112 = 5'h6 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_92; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_113 = 5'h7 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_93; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_114 = 5'h8 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_94; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_115 = 5'h9 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_95; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_116 = 5'ha == _T_14[4:0] ? link_data_byte_index_14 : _GEN_96; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_117 = 5'hb == _T_14[4:0] ? link_data_byte_index_14 : _GEN_97; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_118 = 5'hc == _T_14[4:0] ? link_data_byte_index_14 : _GEN_98; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_119 = 5'hd == _T_14[4:0] ? link_data_byte_index_14 : _GEN_99; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_120 = 5'he == _T_14[4:0] ? link_data_byte_index_14 : _GEN_100; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_121 = 5'hf == _T_14[4:0] ? link_data_byte_index_14 : _GEN_101; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_122 = 5'h10 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_102; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_123 = 5'h11 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_103; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_124 = 5'h12 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_104; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_125 = 5'h13 == _T_14[4:0] ? link_data_byte_index_14 : _GEN_105; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_18 = byte_count + 17'hd; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_126 = 5'h0 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_106; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_127 = 5'h1 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_107; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_128 = 5'h2 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_108; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_129 = 5'h3 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_109; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_130 = 5'h4 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_110; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_131 = 5'h5 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_111; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_132 = 5'h6 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_112; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_133 = 5'h7 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_113; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_134 = 5'h8 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_114; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_135 = 5'h9 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_115; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_136 = 5'ha == _T_18[4:0] ? link_data_byte_index_13 : _GEN_116; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_137 = 5'hb == _T_18[4:0] ? link_data_byte_index_13 : _GEN_117; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_138 = 5'hc == _T_18[4:0] ? link_data_byte_index_13 : _GEN_118; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_139 = 5'hd == _T_18[4:0] ? link_data_byte_index_13 : _GEN_119; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_140 = 5'he == _T_18[4:0] ? link_data_byte_index_13 : _GEN_120; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_141 = 5'hf == _T_18[4:0] ? link_data_byte_index_13 : _GEN_121; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_142 = 5'h10 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_122; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_143 = 5'h11 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_123; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_144 = 5'h12 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_124; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_145 = 5'h13 == _T_18[4:0] ? link_data_byte_index_13 : _GEN_125; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_22 = byte_count + 17'hc; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_146 = 5'h0 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_126; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_147 = 5'h1 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_127; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_148 = 5'h2 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_128; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_149 = 5'h3 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_129; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_150 = 5'h4 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_130; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_151 = 5'h5 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_131; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_152 = 5'h6 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_132; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_153 = 5'h7 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_133; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_154 = 5'h8 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_134; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_155 = 5'h9 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_135; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_156 = 5'ha == _T_22[4:0] ? link_data_byte_index_12 : _GEN_136; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_157 = 5'hb == _T_22[4:0] ? link_data_byte_index_12 : _GEN_137; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_158 = 5'hc == _T_22[4:0] ? link_data_byte_index_12 : _GEN_138; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_159 = 5'hd == _T_22[4:0] ? link_data_byte_index_12 : _GEN_139; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_160 = 5'he == _T_22[4:0] ? link_data_byte_index_12 : _GEN_140; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_161 = 5'hf == _T_22[4:0] ? link_data_byte_index_12 : _GEN_141; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_162 = 5'h10 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_142; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_163 = 5'h11 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_143; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_164 = 5'h12 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_144; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_165 = 5'h13 == _T_22[4:0] ? link_data_byte_index_12 : _GEN_145; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_26 = byte_count + 17'hb; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_166 = 5'h0 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_146; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_167 = 5'h1 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_147; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_168 = 5'h2 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_148; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_169 = 5'h3 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_149; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_170 = 5'h4 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_150; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_171 = 5'h5 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_151; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_172 = 5'h6 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_152; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_173 = 5'h7 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_153; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_174 = 5'h8 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_154; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_175 = 5'h9 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_155; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_176 = 5'ha == _T_26[4:0] ? link_data_byte_index_11 : _GEN_156; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_177 = 5'hb == _T_26[4:0] ? link_data_byte_index_11 : _GEN_157; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_178 = 5'hc == _T_26[4:0] ? link_data_byte_index_11 : _GEN_158; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_179 = 5'hd == _T_26[4:0] ? link_data_byte_index_11 : _GEN_159; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_180 = 5'he == _T_26[4:0] ? link_data_byte_index_11 : _GEN_160; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_181 = 5'hf == _T_26[4:0] ? link_data_byte_index_11 : _GEN_161; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_182 = 5'h10 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_162; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_183 = 5'h11 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_163; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_184 = 5'h12 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_164; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_185 = 5'h13 == _T_26[4:0] ? link_data_byte_index_11 : _GEN_165; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_30 = byte_count + 17'ha; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_186 = 5'h0 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_166; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_187 = 5'h1 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_167; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_188 = 5'h2 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_168; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_189 = 5'h3 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_169; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_190 = 5'h4 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_170; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_191 = 5'h5 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_171; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_192 = 5'h6 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_172; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_193 = 5'h7 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_173; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_194 = 5'h8 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_174; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_195 = 5'h9 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_175; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_196 = 5'ha == _T_30[4:0] ? link_data_byte_index_10 : _GEN_176; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_197 = 5'hb == _T_30[4:0] ? link_data_byte_index_10 : _GEN_177; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_198 = 5'hc == _T_30[4:0] ? link_data_byte_index_10 : _GEN_178; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_199 = 5'hd == _T_30[4:0] ? link_data_byte_index_10 : _GEN_179; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_200 = 5'he == _T_30[4:0] ? link_data_byte_index_10 : _GEN_180; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_201 = 5'hf == _T_30[4:0] ? link_data_byte_index_10 : _GEN_181; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_202 = 5'h10 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_182; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_203 = 5'h11 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_183; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_204 = 5'h12 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_184; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_205 = 5'h13 == _T_30[4:0] ? link_data_byte_index_10 : _GEN_185; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_34 = byte_count + 17'h9; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_206 = 5'h0 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_186; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_207 = 5'h1 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_187; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_208 = 5'h2 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_188; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_209 = 5'h3 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_189; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_210 = 5'h4 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_190; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_211 = 5'h5 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_191; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_212 = 5'h6 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_192; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_213 = 5'h7 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_193; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_214 = 5'h8 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_194; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_215 = 5'h9 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_195; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_216 = 5'ha == _T_34[4:0] ? link_data_byte_index_9 : _GEN_196; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_217 = 5'hb == _T_34[4:0] ? link_data_byte_index_9 : _GEN_197; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_218 = 5'hc == _T_34[4:0] ? link_data_byte_index_9 : _GEN_198; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_219 = 5'hd == _T_34[4:0] ? link_data_byte_index_9 : _GEN_199; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_220 = 5'he == _T_34[4:0] ? link_data_byte_index_9 : _GEN_200; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_221 = 5'hf == _T_34[4:0] ? link_data_byte_index_9 : _GEN_201; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_222 = 5'h10 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_202; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_223 = 5'h11 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_203; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_224 = 5'h12 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_204; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_225 = 5'h13 == _T_34[4:0] ? link_data_byte_index_9 : _GEN_205; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_38 = byte_count + 17'h8; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_226 = 5'h0 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_206; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_227 = 5'h1 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_207; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_228 = 5'h2 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_208; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_229 = 5'h3 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_209; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_230 = 5'h4 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_210; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_231 = 5'h5 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_211; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_232 = 5'h6 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_212; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_233 = 5'h7 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_213; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_234 = 5'h8 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_214; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_235 = 5'h9 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_215; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_236 = 5'ha == _T_38[4:0] ? link_data_byte_index_8 : _GEN_216; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_237 = 5'hb == _T_38[4:0] ? link_data_byte_index_8 : _GEN_217; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_238 = 5'hc == _T_38[4:0] ? link_data_byte_index_8 : _GEN_218; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_239 = 5'hd == _T_38[4:0] ? link_data_byte_index_8 : _GEN_219; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_240 = 5'he == _T_38[4:0] ? link_data_byte_index_8 : _GEN_220; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_241 = 5'hf == _T_38[4:0] ? link_data_byte_index_8 : _GEN_221; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_242 = 5'h10 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_222; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_243 = 5'h11 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_223; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_244 = 5'h12 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_224; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_245 = 5'h13 == _T_38[4:0] ? link_data_byte_index_8 : _GEN_225; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_42 = byte_count + 17'h7; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_246 = 5'h0 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_226; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_247 = 5'h1 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_227; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_248 = 5'h2 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_228; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_249 = 5'h3 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_229; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_250 = 5'h4 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_230; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_251 = 5'h5 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_231; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_252 = 5'h6 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_232; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_253 = 5'h7 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_233; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_254 = 5'h8 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_234; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_255 = 5'h9 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_235; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_256 = 5'ha == _T_42[4:0] ? link_data_byte_index_7 : _GEN_236; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_257 = 5'hb == _T_42[4:0] ? link_data_byte_index_7 : _GEN_237; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_258 = 5'hc == _T_42[4:0] ? link_data_byte_index_7 : _GEN_238; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_259 = 5'hd == _T_42[4:0] ? link_data_byte_index_7 : _GEN_239; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_260 = 5'he == _T_42[4:0] ? link_data_byte_index_7 : _GEN_240; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_261 = 5'hf == _T_42[4:0] ? link_data_byte_index_7 : _GEN_241; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_262 = 5'h10 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_242; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_263 = 5'h11 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_243; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_264 = 5'h12 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_244; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_265 = 5'h13 == _T_42[4:0] ? link_data_byte_index_7 : _GEN_245; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_46 = byte_count + 17'h6; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_266 = 5'h0 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_246; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_267 = 5'h1 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_247; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_268 = 5'h2 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_248; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_269 = 5'h3 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_249; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_270 = 5'h4 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_250; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_271 = 5'h5 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_251; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_272 = 5'h6 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_252; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_273 = 5'h7 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_253; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_274 = 5'h8 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_254; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_275 = 5'h9 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_255; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_276 = 5'ha == _T_46[4:0] ? link_data_byte_index_6 : _GEN_256; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_277 = 5'hb == _T_46[4:0] ? link_data_byte_index_6 : _GEN_257; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_278 = 5'hc == _T_46[4:0] ? link_data_byte_index_6 : _GEN_258; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_279 = 5'hd == _T_46[4:0] ? link_data_byte_index_6 : _GEN_259; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_280 = 5'he == _T_46[4:0] ? link_data_byte_index_6 : _GEN_260; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_281 = 5'hf == _T_46[4:0] ? link_data_byte_index_6 : _GEN_261; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_282 = 5'h10 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_262; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_283 = 5'h11 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_263; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_284 = 5'h12 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_264; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_285 = 5'h13 == _T_46[4:0] ? link_data_byte_index_6 : _GEN_265; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_50 = byte_count + 17'h5; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_286 = 5'h0 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_266; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_287 = 5'h1 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_267; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_288 = 5'h2 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_268; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_289 = 5'h3 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_269; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_290 = 5'h4 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_270; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_291 = 5'h5 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_271; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_292 = 5'h6 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_272; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_293 = 5'h7 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_273; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_294 = 5'h8 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_274; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_295 = 5'h9 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_275; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_296 = 5'ha == _T_50[4:0] ? link_data_byte_index_5 : _GEN_276; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_297 = 5'hb == _T_50[4:0] ? link_data_byte_index_5 : _GEN_277; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_298 = 5'hc == _T_50[4:0] ? link_data_byte_index_5 : _GEN_278; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_299 = 5'hd == _T_50[4:0] ? link_data_byte_index_5 : _GEN_279; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_300 = 5'he == _T_50[4:0] ? link_data_byte_index_5 : _GEN_280; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_301 = 5'hf == _T_50[4:0] ? link_data_byte_index_5 : _GEN_281; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_302 = 5'h10 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_282; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_303 = 5'h11 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_283; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_304 = 5'h12 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_284; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_305 = 5'h13 == _T_50[4:0] ? link_data_byte_index_5 : _GEN_285; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_54 = byte_count + 17'h4; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_306 = 5'h0 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_286; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_307 = 5'h1 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_287; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_308 = 5'h2 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_288; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_309 = 5'h3 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_289; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_310 = 5'h4 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_290; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_311 = 5'h5 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_291; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_312 = 5'h6 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_292; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_313 = 5'h7 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_293; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_314 = 5'h8 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_294; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_315 = 5'h9 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_295; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_316 = 5'ha == _T_54[4:0] ? link_data_byte_index_4 : _GEN_296; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_317 = 5'hb == _T_54[4:0] ? link_data_byte_index_4 : _GEN_297; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_318 = 5'hc == _T_54[4:0] ? link_data_byte_index_4 : _GEN_298; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_319 = 5'hd == _T_54[4:0] ? link_data_byte_index_4 : _GEN_299; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_320 = 5'he == _T_54[4:0] ? link_data_byte_index_4 : _GEN_300; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_321 = 5'hf == _T_54[4:0] ? link_data_byte_index_4 : _GEN_301; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_322 = 5'h10 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_302; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_323 = 5'h11 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_303; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_324 = 5'h12 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_304; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_325 = 5'h13 == _T_54[4:0] ? link_data_byte_index_4 : _GEN_305; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_58 = byte_count + 17'h3; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_326 = 5'h0 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_306; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_327 = 5'h1 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_307; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_328 = 5'h2 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_308; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_329 = 5'h3 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_309; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_330 = 5'h4 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_310; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_331 = 5'h5 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_311; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_332 = 5'h6 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_312; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_333 = 5'h7 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_313; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_334 = 5'h8 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_314; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_335 = 5'h9 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_315; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_336 = 5'ha == _T_58[4:0] ? link_data_byte_index_3 : _GEN_316; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_337 = 5'hb == _T_58[4:0] ? link_data_byte_index_3 : _GEN_317; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_338 = 5'hc == _T_58[4:0] ? link_data_byte_index_3 : _GEN_318; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_339 = 5'hd == _T_58[4:0] ? link_data_byte_index_3 : _GEN_319; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_340 = 5'he == _T_58[4:0] ? link_data_byte_index_3 : _GEN_320; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_341 = 5'hf == _T_58[4:0] ? link_data_byte_index_3 : _GEN_321; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_342 = 5'h10 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_322; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_343 = 5'h11 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_323; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_344 = 5'h12 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_324; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_345 = 5'h13 == _T_58[4:0] ? link_data_byte_index_3 : _GEN_325; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_62 = byte_count + 17'h2; // @[LinkLayer.scala 674:34]
  wire [7:0] _GEN_346 = 5'h0 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_326; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_347 = 5'h1 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_327; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_348 = 5'h2 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_328; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_349 = 5'h3 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_329; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_350 = 5'h4 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_330; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_351 = 5'h5 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_331; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_352 = 5'h6 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_332; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_353 = 5'h7 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_333; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_354 = 5'h8 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_334; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_355 = 5'h9 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_335; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_356 = 5'ha == _T_62[4:0] ? link_data_byte_index_2 : _GEN_336; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_357 = 5'hb == _T_62[4:0] ? link_data_byte_index_2 : _GEN_337; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_358 = 5'hc == _T_62[4:0] ? link_data_byte_index_2 : _GEN_338; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_359 = 5'hd == _T_62[4:0] ? link_data_byte_index_2 : _GEN_339; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_360 = 5'he == _T_62[4:0] ? link_data_byte_index_2 : _GEN_340; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_361 = 5'hf == _T_62[4:0] ? link_data_byte_index_2 : _GEN_341; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_362 = 5'h10 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_342; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_363 = 5'h11 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_343; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_364 = 5'h12 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_344; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [7:0] _GEN_365 = 5'h13 == _T_62[4:0] ? link_data_byte_index_2 : _GEN_345; // @[LinkLayer.scala 674:49 LinkLayer.scala 674:49]
  wire [16:0] _T_66 = byte_count + 17'h1; // @[LinkLayer.scala 674:34]
  wire [17:0] _T_69 = {{1'd0}, byte_count}; // @[LinkLayer.scala 674:34]
  wire [1:0] _GEN_428 = {{1'd0}, _nstate_T}; // @[LinkLayer.scala 746:27 LinkLayer.scala 751:31 LinkLayer.scala 684:29]
  wire  _GEN_451 = state == 2'h1 & endOfPacket; // @[LinkLayer.scala 745:46 LinkLayer.scala 685:29]
  wire [55:0] bundleOut_0_data_lo = {ll_byte_index_10,ll_byte_index_9,ll_byte_index_8,ll_byte_index_7,ll_byte_index_6,
    ll_byte_index_5,ll_byte_index_4}; // @[LinkLayer.scala 793:36]
  wire [55:0] bundleOut_0_data_hi = {ll_byte_index_17,ll_byte_index_16,ll_byte_index_15,ll_byte_index_14,
    ll_byte_index_13,ll_byte_index_12,ll_byte_index_11}; // @[LinkLayer.scala 793:36]
  wire [16:0] byte_index_crc = {{1'd0}, word_count}; // @[LinkLayer.scala 653:33 LinkLayer.scala 688:29]
  wire [16:0] _bundleOut_0_crc_T_1 = byte_index_crc + 17'h5; // @[LinkLayer.scala 795:55]
  wire [16:0] _bundleOut_0_crc_T_4 = byte_index_crc + 17'h4; // @[LinkLayer.scala 795:92]
  wire [7:0] _GEN_848 = 5'h1 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_1 : ll_byte_index_0; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_849 = 5'h2 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_2 : _GEN_848; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_850 = 5'h3 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_3 : _GEN_849; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_851 = 5'h4 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_4 : _GEN_850; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_852 = 5'h5 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_5 : _GEN_851; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_853 = 5'h6 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_6 : _GEN_852; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_854 = 5'h7 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_7 : _GEN_853; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_855 = 5'h8 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_8 : _GEN_854; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_856 = 5'h9 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_9 : _GEN_855; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_857 = 5'ha == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_10 : _GEN_856; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_858 = 5'hb == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_11 : _GEN_857; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_859 = 5'hc == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_12 : _GEN_858; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_860 = 5'hd == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_13 : _GEN_859; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_861 = 5'he == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_14 : _GEN_860; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_862 = 5'hf == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_15 : _GEN_861; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_863 = 5'h10 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_16 : _GEN_862; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_864 = 5'h11 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_17 : _GEN_863; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_865 = 5'h12 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_18 : _GEN_864; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_866 = 5'h13 == _bundleOut_0_crc_T_1[4:0] ? ll_byte_index_19 : _GEN_865; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_868 = 5'h1 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_1 : ll_byte_index_0; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_869 = 5'h2 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_2 : _GEN_868; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_870 = 5'h3 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_3 : _GEN_869; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_871 = 5'h4 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_4 : _GEN_870; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_872 = 5'h5 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_5 : _GEN_871; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_873 = 5'h6 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_6 : _GEN_872; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_874 = 5'h7 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_7 : _GEN_873; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_875 = 5'h8 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_8 : _GEN_874; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_876 = 5'h9 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_9 : _GEN_875; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_877 = 5'ha == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_10 : _GEN_876; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_878 = 5'hb == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_11 : _GEN_877; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_879 = 5'hc == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_12 : _GEN_878; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_880 = 5'hd == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_13 : _GEN_879; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_881 = 5'he == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_14 : _GEN_880; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_882 = 5'hf == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_15 : _GEN_881; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_883 = 5'h10 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_16 : _GEN_882; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_884 = 5'h11 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_17 : _GEN_883; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_885 = 5'h12 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_18 : _GEN_884; // @[Cat.scala 30:58 Cat.scala 30:58]
  wire [7:0] _GEN_886 = 5'h13 == _bundleOut_0_crc_T_4[4:0] ? ll_byte_index_19 : _GEN_885; // @[Cat.scala 30:58 Cat.scala 30:58]
  WavDemetReset enable_ff2_demet ( // @[Stdcell.scala 58:23]
    .clock(enable_ff2_demet_clock),
    .reset(enable_ff2_demet_reset),
    .io_in(enable_ff2_demet_io_in),
    .io_out(enable_ff2_demet_io_out)
  );
  WlinkEccSyndrome ecc_check ( // @[LinkLayer.scala 639:35]
    .ph_in(ecc_check_ph_in),
    .rx_ecc(ecc_check_rx_ecc),
    .calc_ecc(ecc_check_calc_ecc),
    .corrected_ph(ecc_check_corrected_ph),
    .corrected(ecc_check_corrected),
    .corrupted(ecc_check_corrupted)
  );
  assign auto_out_sop = valid; // @[Nodes.scala 1207:84 LinkLayer.scala 785:19]
  assign auto_out_data_id = ll_byte_index_0; // @[Nodes.scala 1207:84 LinkLayer.scala 786:19]
  assign auto_out_word_count = {ll_byte_index_2,ll_byte_index_1}; // @[Cat.scala 30:58]
  assign auto_out_data = {bundleOut_0_data_hi,bundleOut_0_data_lo}; // @[LinkLayer.scala 793:36]
  assign auto_out_valid = valid; // @[Nodes.scala 1207:84 LinkLayer.scala 784:19]
  assign auto_out_crc = {_GEN_866,_GEN_886}; // @[Cat.scala 30:58]
  assign io_ecc_corrected = ecc_check_corrected; // @[LinkLayer.scala 797:23]
  assign io_ecc_corrupted = ecc_check_corrupted; // @[LinkLayer.scala 798:23]
  assign io_in_error_state = io_in_error_state_REG; // @[LinkLayer.scala 614:35]
  // SoC Labs credit-path observability taps (byte-align FSM internals).
  assign io_obs_state        = state;
  assign io_obs_is_short_pkt = is_short_pkt;
  assign io_obs_is_long_pkt  = is_long_pkt;
  assign io_obs_valid        = valid;
  // SoC Labs 2026-06-08: SYNC-word seen on the assembled RX bus (sync_detected
  // is combinational, :289). Saturating-counted in the RX link-clock domain in
  // Wlink.v and 2-flop-synced to apb_clk for SW read.
  assign io_obs_sync_detected = sync_detected;
  assign enable_ff2_demet_clock = clock;
  assign enable_ff2_demet_reset = reset;
  assign enable_ff2_demet_io_in = io_enable; // @[Stdcell.scala 59:17]
  assign ecc_check_ph_in = state == 2'h0 ? _GEN_65 : 24'h0; // @[LinkLayer.scala 693:40 LinkLayer.scala 690:29]
  assign ecc_check_rx_ecc = state == 2'h0 ? _GEN_66 : 8'h0; // @[LinkLayer.scala 693:40 LinkLayer.scala 691:29]
  // SoC Labs tdif-08 L4 fix v3: first_short_pkt_seen sticky gate.
  // L5 strengthening (tdif-10, 2026-05-25): added data_id whitelist.
  // ---------------------------------------------------------------
  // The v3 latch (state==0 && is_short_pkt) bootstrapped on ANY value
  // <=short_packet_max, including stray bytes like 0x0c that survive ECC
  // but are not bringup packets. Assessment test_05 proved the framer then
  // committed to a phony long-packet branch on subsequent garbage and
  // master->slave CR/CRACK never converged.
  //
  // L5: latch ONLY when corrected_ph[7:0] matches a real bringup data_id
  // (cr_id / crack_id / ack_id / nack_id). `is_short_pkt` already includes
  // (~ecc_check_corrupted) so the ECC-validity gate is implicit. Whitelist
  // values come from io_swi_* inputs (set to 0x44/0x45/0x46/0x47 by the
  // single Wlink.v instantiation -- matches FCSM defaults).
  //
  // `reset` (POR + LL swreset) clears the flag so each bringup window
  // re-bootstraps from a whitelisted short pkt.
  //
  // SoC Labs P1 fix (2026-07-03): the 0x44-47-only whitelist DEADLOCKS the
  // long path in steady state. Silicon-proven sequence: the gate opens
  // during bootstrap (CR/CRACK), the bootstrap data packet crosses, then a
  // post-bringup LL soft reset clears it -- and it can NEVER re-latch,
  // because steady-state wire traffic is only the OTHER FC nodes' shorts
  // (bFC ACK 0x12 / CR 0x10 keepalives), none of which match. Every
  // subsequent data long is then silently swallowed at the hunt acceptance
  // guard (RXCAP read: GATE=0, BLOCKED=1, ph_at_first=0x07a1 = a perfectly
  // clean header). Fix: accept the FULL set of REAL short-packet id
  // families as re-latch evidence -- Wlink FC nodes aw 0x08-0x0b, w 0x0c-0f,
  // b 0x10-13, ar 0x14-17, r 0x18-1b, gb 0x40-43, tl 0x44-47 (the original
  // four), and the ShortPacket channel 0x50-0x51. All are ECC-clean by
  // is_short_pkt; misframed garbage stays excluded, preserving the L5
  // intent while making the gate self-healing from any live traffic.
  wire whitelisted_short_data_id = (corrected_ph[7:0] == io_swi_cr_id) ||
                                   (corrected_ph[7:0] == io_swi_crack_id) ||
                                   (corrected_ph[7:0] == io_swi_ack_id) ||
                                   (corrected_ph[7:0] == io_swi_nack_id) ||
                                   (corrected_ph[7:0] >= 8'h08 &&
                                    corrected_ph[7:0] <= 8'h1b) ||   // aw/w/b/ar/r FC families
                                   (corrected_ph[7:0] >= 8'h40 &&
                                    corrected_ph[7:0] <= 8'h43) ||   // gb FC family
                                   (corrected_ph[7:0] == 8'h50) ||
                                   (corrected_ph[7:0] == 8'h51);     // ShortPacket ch7
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      first_short_pkt_seen <= 1'b0;
    end else if (state == 2'h0 &&
                 ((is_short_pkt && whitelisted_short_data_id) ||
                  wellformed_long_hdr)) begin
      // P1 fix stage 2: a wellformed long header also latches the sticky.
      first_short_pkt_seen <= 1'b1;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      state <= 2'h0;
    end else if (sync_resync_boundary) begin
      // SoC Labs SYNC re-align (2026-06-06): a SYNC delimiter forces the
      // byte-align FSM back to hunt (state 0) at a known packet boundary.
      state <= 2'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (io_active_lanes == 8'h0) begin
          if (valid_byte_reg) begin
            // SoC Labs tdif-08 L4: gate 0-lane path with long_pkt_gate too.
            // _GEN_9 = is_long_pkt & ~is_short_pkt_prev ? 2'h1 : state, so
            // an unguarded long-packet entry can still latch state==1 in
            // the 0-lane code path; force-keep state if gate is closed.
            // S->M wedge fix (2026-06-03): also require a plausible
            // candidate word_count (long_pkt_len_ok) before entering
            // long-packet mode, else hold state to keep hunting.
            state <= (long_pkt_gate && long_pkt_len_ok) ? _GEN_9 : state;
          end
        end else if (is_long_pkt && long_pkt_gate && long_pkt_len_ok) begin  // SoC Labs tdif-08 L4 v3: gated; +S->M len bound 2026-06-03
          state <= {{1'd0}, _nstate_T};
        end
      end
    end else if (state == 2'h1) begin
      // SoC Labs S->M wedge fix (Option A belt-and-braces, 2026-06-03):
      // if an implausible long packet did get latched (word_count beyond
      // LONG_PKT_WORD_MAX), self-recover to hunt (state 0) immediately
      // instead of waiting ~20k cycles for an endOfPacket that may never
      // come during the brief real S->M data window.
      if (word_count > LONG_PKT_WORD_MAX) begin
        state <= 2'h0;
      end else begin
        state <= _GEN_428;
      end
    end else if (_io_in_error_state_T) begin
      state <= 2'h2;
    end else begin
      state <= 2'h0;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      io_in_error_state_REG <= 1'h0;
    end else begin
      io_in_error_state_REG <= state == 2'h2;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_0 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (io_active_lanes == 8'h0) begin
          if (valid_byte_reg) begin
            ll_byte_index_0 <= _GEN_5;
          end
        end else if (is_long_pkt) begin
          ll_byte_index_0 <= ecc_check_corrected_ph[7:0];
        end else begin
          ll_byte_index_0 <= _GEN_20;
        end
      end
    end else if (state == 2'h1) begin
      if (5'h0 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_0 <= _GEN_815;
        end else begin
          ll_byte_index_0 <= _GEN_783;
        end
      end else if (5'h0 == _T_66[4:0]) begin
        ll_byte_index_0 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_0 <= _GEN_346;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_1 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (io_active_lanes == 8'h0) begin
          if (valid_byte_reg) begin
            ll_byte_index_1 <= _GEN_6;
          end
        end else if (is_long_pkt) begin
          ll_byte_index_1 <= ecc_check_corrected_ph[15:8];
        end else begin
          ll_byte_index_1 <= _GEN_21;
        end
      end
    end else if (state == 2'h1) begin
      if (5'h1 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_1 <= _GEN_815;
        end else begin
          ll_byte_index_1 <= _GEN_783;
        end
      end else if (5'h1 == _T_66[4:0]) begin
        ll_byte_index_1 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_1 <= _GEN_347;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_2 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (io_active_lanes == 8'h0) begin
          if (valid_byte_reg) begin
            ll_byte_index_2 <= _GEN_7;
          end
        end else if (is_long_pkt) begin
          ll_byte_index_2 <= ecc_check_corrected_ph[23:16];
        end else begin
          ll_byte_index_2 <= _GEN_22;
        end
      end
    end else if (state == 2'h1) begin
      if (5'h2 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_2 <= _GEN_815;
        end else begin
          ll_byte_index_2 <= _GEN_783;
        end
      end else if (5'h2 == _T_66[4:0]) begin
        ll_byte_index_2 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_2 <= _GEN_348;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_3 <= 8'h0;
    end else if (!(state == 2'h0)) begin
      if (state == 2'h1) begin
        if (5'h3 == _T_69[4:0]) begin
          if (io_lane_mask[7]) begin
            ll_byte_index_3 <= _GEN_815;
          end else begin
            ll_byte_index_3 <= _GEN_783;
          end
        end else if (5'h3 == _T_66[4:0]) begin
          ll_byte_index_3 <= link_data_byte_index_1;
        end else begin
          ll_byte_index_3 <= _GEN_349;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_4 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_4 <= link_data_byte_index_4;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'h4 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_4 <= _GEN_815;
        end else begin
          ll_byte_index_4 <= _GEN_783;
        end
      end else if (5'h4 == _T_66[4:0]) begin
        ll_byte_index_4 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_4 <= _GEN_350;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_5 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_5 <= link_data_byte_index_5;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'h5 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_5 <= _GEN_815;
        end else begin
          ll_byte_index_5 <= _GEN_783;
        end
      end else if (5'h5 == _T_66[4:0]) begin
        ll_byte_index_5 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_5 <= _GEN_351;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_6 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_6 <= link_data_byte_index_6;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'h6 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_6 <= _GEN_815;
        end else begin
          ll_byte_index_6 <= _GEN_783;
        end
      end else if (5'h6 == _T_66[4:0]) begin
        ll_byte_index_6 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_6 <= _GEN_352;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_7 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_7 <= link_data_byte_index_7;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'h7 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_7 <= _GEN_815;
        end else begin
          ll_byte_index_7 <= _GEN_783;
        end
      end else if (5'h7 == _T_66[4:0]) begin
        ll_byte_index_7 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_7 <= _GEN_353;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_8 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_8 <= link_data_byte_index_8;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'h8 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_8 <= _GEN_815;
        end else begin
          ll_byte_index_8 <= _GEN_783;
        end
      end else if (5'h8 == _T_66[4:0]) begin
        ll_byte_index_8 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_8 <= _GEN_354;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_9 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_9 <= link_data_byte_index_9;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'h9 == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_9 <= _GEN_815;
        end else begin
          ll_byte_index_9 <= _GEN_783;
        end
      end else if (5'h9 == _T_66[4:0]) begin
        ll_byte_index_9 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_9 <= _GEN_355;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_10 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_10 <= link_data_byte_index_10;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'ha == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_10 <= _GEN_815;
        end else begin
          ll_byte_index_10 <= _GEN_783;
        end
      end else if (5'ha == _T_66[4:0]) begin
        ll_byte_index_10 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_10 <= _GEN_356;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_11 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_11 <= link_data_byte_index_11;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'hb == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_11 <= _GEN_815;
        end else begin
          ll_byte_index_11 <= _GEN_783;
        end
      end else if (5'hb == _T_66[4:0]) begin
        ll_byte_index_11 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_11 <= _GEN_357;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_12 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_12 <= link_data_byte_index_12;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'hc == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_12 <= _GEN_815;
        end else begin
          ll_byte_index_12 <= _GEN_783;
        end
      end else if (5'hc == _T_66[4:0]) begin
        ll_byte_index_12 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_12 <= _GEN_358;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_13 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_13 <= link_data_byte_index_13;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'hd == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_13 <= _GEN_815;
        end else begin
          ll_byte_index_13 <= _GEN_783;
        end
      end else if (5'hd == _T_66[4:0]) begin
        ll_byte_index_13 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_13 <= _GEN_359;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_14 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_14 <= link_data_byte_index_14;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'he == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_14 <= _GEN_815;
        end else begin
          ll_byte_index_14 <= _GEN_783;
        end
      end else if (5'he == _T_66[4:0]) begin
        ll_byte_index_14 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_14 <= _GEN_360;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_15 <= 8'h0;
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (!(io_active_lanes == 8'h0)) begin
          if (is_long_pkt) begin
            ll_byte_index_15 <= link_data_byte_index_15;
          end
        end
      end
    end else if (state == 2'h1) begin
      if (5'hf == _T_69[4:0]) begin
        if (io_lane_mask[7]) begin
          ll_byte_index_15 <= _GEN_815;
        end else begin
          ll_byte_index_15 <= _GEN_783;
        end
      end else if (5'hf == _T_66[4:0]) begin
        ll_byte_index_15 <= link_data_byte_index_1;
      end else begin
        ll_byte_index_15 <= _GEN_361;
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_16 <= 8'h0;
    end else if (!(state == 2'h0)) begin
      if (state == 2'h1) begin
        if (5'h10 == _T_69[4:0]) begin
          if (io_lane_mask[7]) begin
            ll_byte_index_16 <= _GEN_815;
          end else begin
            ll_byte_index_16 <= _GEN_783;
          end
        end else if (5'h10 == _T_66[4:0]) begin
          ll_byte_index_16 <= link_data_byte_index_1;
        end else begin
          ll_byte_index_16 <= _GEN_362;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_17 <= 8'h0;
    end else if (!(state == 2'h0)) begin
      if (state == 2'h1) begin
        if (5'h11 == _T_69[4:0]) begin
          if (io_lane_mask[7]) begin
            ll_byte_index_17 <= _GEN_815;
          end else begin
            ll_byte_index_17 <= _GEN_783;
          end
        end else if (5'h11 == _T_66[4:0]) begin
          ll_byte_index_17 <= link_data_byte_index_1;
        end else begin
          ll_byte_index_17 <= _GEN_363;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_18 <= 8'h0;
    end else if (!(state == 2'h0)) begin
      if (state == 2'h1) begin
        if (5'h12 == _T_69[4:0]) begin
          if (io_lane_mask[7]) begin
            ll_byte_index_18 <= _GEN_815;
          end else begin
            ll_byte_index_18 <= _GEN_783;
          end
        end else if (5'h12 == _T_66[4:0]) begin
          ll_byte_index_18 <= link_data_byte_index_1;
        end else begin
          ll_byte_index_18 <= _GEN_364;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      ll_byte_index_19 <= 8'h0;
    end else if (!(state == 2'h0)) begin
      if (state == 2'h1) begin
        if (5'h13 == _T_69[4:0]) begin
          if (io_lane_mask[7]) begin
            ll_byte_index_19 <= _GEN_815;
          end else begin
            ll_byte_index_19 <= _GEN_783;
          end
        end else if (5'h13 == _T_66[4:0]) begin
          ll_byte_index_19 <= link_data_byte_index_1;
        end else begin
          ll_byte_index_19 <= _GEN_365;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      byte0_reg <= 8'h0;
    end else if (_T) begin
      if (io_lane_mask[7]) begin
        if (4'h0 == _T_97) begin
          byte0_reg <= link_data_lane_index_7[15:8];
        end else if (3'h0 == rxLanePos_6) begin
          byte0_reg <= link_data_lane_index_7[7:0];
        end else begin
          byte0_reg <= _GEN_783;
        end
      end else begin
        byte0_reg <= _GEN_783;
      end
    end else begin
      byte0_reg <= 8'h0;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      byte1_reg <= 8'h0;
    end else if (_T) begin
      if (io_lane_mask[7]) begin
        if (4'h1 == _T_97) begin
          byte1_reg <= link_data_lane_index_7[15:8];
        end else if (3'h1 == rxLanePos_6) begin
          byte1_reg <= link_data_lane_index_7[7:0];
        end else begin
          byte1_reg <= _GEN_784;
        end
      end else begin
        byte1_reg <= _GEN_784;
      end
    end else begin
      byte1_reg <= 8'h0;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      is_short_pkt_prev <= 1'h0;
    end else if (is_short_pkt_prev) begin
      is_short_pkt_prev <= 1'h0;
    end else begin
      is_short_pkt_prev <= is_short_pkt;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      valid <= 1'h0;
    end else if (state == 2'h0) begin
      valid <= _GEN_67;
    end else begin
      valid <= _GEN_451;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      word_count <= 16'h0;
    end else if (sync_resync_boundary) begin
      word_count <= 16'h0;        // SoC Labs SYNC re-align (2026-06-06)
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (io_active_lanes == 8'h0) begin
          if (valid_byte_reg) begin
            word_count <= _GEN_8;
          end
        end else if (is_long_pkt) begin
          word_count <= ecc_check_corrected_ph[23:8];
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      byte_count <= 17'h0;
    end else if (sync_resync_boundary) begin
      byte_count <= 17'h0;        // SoC Labs SYNC re-align (2026-06-06)
    end else if (state == 2'h0) begin
      if (enable_ff2_demet_io_out) begin
        if (io_active_lanes == 8'h0) begin
          byte_count <= {{14'd0}, _GEN_16};
        end else if (is_long_pkt) begin
          byte_count <= _byte_count_in_T_2;
        end else begin
          byte_count <= 17'h0;
        end
      end else begin
        byte_count <= 17'h0;
      end
    end else if (state == 2'h1) begin
      byte_count <= _byte_count_in_T_2;
    end
  end
  // ===========================================================================
  // SoC Labs ILA snapshot regs (feat/phy-v2-integration, 2026-06-18)
  // ---------------------------------------------------------------------------
  // Purely OBSERVATIONAL: register-snapshots of the framer's combinational
  // header-decode nets so they can be probed by the auto-inserted ILA debug
  // core (fpga/insert_debug_core.tcl gathers MARK_DEBUG==1 nets, sets
  // DONT_TOUCH, and wires one probe per base reg). NONE of these feed back
  // into functional logic — they only drive the ILA. Same clock/reset domain
  // (RX link clock `clock`, async active-high `reset`) as every other always
  // block in this module. Question under investigation: does the die_b CR
  // header data_id 0x44 ever land on link_data_byte_index_0 on die_a, and what
  // does is_short/is_long/ECC decode it as (vs the CRACK 0x45 which frames OK)?
  // ===========================================================================
  reg [7:0]  dbg_link_data_byte_index_0; // gathered header data_id byte
  reg        dbg_is_short_pkt;
  reg        dbg_is_long_pkt;
  reg        dbg_sync_detected;
  reg        dbg_sync_resync;
  reg        dbg_ecc_check_corrupted;
  reg [7:0]  dbg_ecc_corrected_ph;       // corrected header data_id (ph[7:0])
  reg [7:0]  dbg_io_lane_mask;
  reg        dbg_io_robust_sync_seen;
  reg [23:0] dbg_io_link_data_lo;        // low 3 header bytes pre-gather
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      dbg_link_data_byte_index_0 <= 8'h0;
      dbg_is_short_pkt           <= 1'h0;
      dbg_is_long_pkt            <= 1'h0;
      dbg_sync_detected          <= 1'h0;
      dbg_sync_resync            <= 1'h0;
      dbg_ecc_check_corrupted    <= 1'h0;
      dbg_ecc_corrected_ph       <= 8'h0;
      dbg_io_lane_mask           <= 8'h0;
      dbg_io_robust_sync_seen    <= 1'h0;
      dbg_io_link_data_lo        <= 24'h0;
    end else begin
      dbg_link_data_byte_index_0 <= link_data_byte_index_0;
      dbg_is_short_pkt           <= is_short_pkt;
      dbg_is_long_pkt            <= is_long_pkt;
      dbg_sync_detected          <= sync_detected;
      dbg_sync_resync            <= sync_resync;
      dbg_ecc_check_corrupted    <= ecc_check_corrupted;
      dbg_ecc_corrected_ph       <= ecc_check_corrected_ph[7:0];
      dbg_io_lane_mask           <= io_lane_mask;
      dbg_io_robust_sync_seen    <= io_robust_sync_seen;
      dbg_io_link_data_lo        <= io_link_data[23:0];
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
  state = _RAND_0[1:0];
  _RAND_1 = {1{`RANDOM}};
  io_in_error_state_REG = _RAND_1[0:0];
  _RAND_2 = {1{`RANDOM}};
  ll_byte_index_0 = _RAND_2[7:0];
  _RAND_3 = {1{`RANDOM}};
  ll_byte_index_1 = _RAND_3[7:0];
  _RAND_4 = {1{`RANDOM}};
  ll_byte_index_2 = _RAND_4[7:0];
  _RAND_5 = {1{`RANDOM}};
  ll_byte_index_3 = _RAND_5[7:0];
  _RAND_6 = {1{`RANDOM}};
  ll_byte_index_4 = _RAND_6[7:0];
  _RAND_7 = {1{`RANDOM}};
  ll_byte_index_5 = _RAND_7[7:0];
  _RAND_8 = {1{`RANDOM}};
  ll_byte_index_6 = _RAND_8[7:0];
  _RAND_9 = {1{`RANDOM}};
  ll_byte_index_7 = _RAND_9[7:0];
  _RAND_10 = {1{`RANDOM}};
  ll_byte_index_8 = _RAND_10[7:0];
  _RAND_11 = {1{`RANDOM}};
  ll_byte_index_9 = _RAND_11[7:0];
  _RAND_12 = {1{`RANDOM}};
  ll_byte_index_10 = _RAND_12[7:0];
  _RAND_13 = {1{`RANDOM}};
  ll_byte_index_11 = _RAND_13[7:0];
  _RAND_14 = {1{`RANDOM}};
  ll_byte_index_12 = _RAND_14[7:0];
  _RAND_15 = {1{`RANDOM}};
  ll_byte_index_13 = _RAND_15[7:0];
  _RAND_16 = {1{`RANDOM}};
  ll_byte_index_14 = _RAND_16[7:0];
  _RAND_17 = {1{`RANDOM}};
  ll_byte_index_15 = _RAND_17[7:0];
  _RAND_18 = {1{`RANDOM}};
  ll_byte_index_16 = _RAND_18[7:0];
  _RAND_19 = {1{`RANDOM}};
  ll_byte_index_17 = _RAND_19[7:0];
  _RAND_20 = {1{`RANDOM}};
  ll_byte_index_18 = _RAND_20[7:0];
  _RAND_21 = {1{`RANDOM}};
  ll_byte_index_19 = _RAND_21[7:0];
  _RAND_22 = {1{`RANDOM}};
  byte0_reg = _RAND_22[7:0];
  _RAND_23 = {1{`RANDOM}};
  byte1_reg = _RAND_23[7:0];
  _RAND_24 = {1{`RANDOM}};
  is_short_pkt_prev = _RAND_24[0:0];
  _RAND_25 = {1{`RANDOM}};
  valid = _RAND_25[0:0];
  _RAND_26 = {1{`RANDOM}};
  word_count = _RAND_26[15:0];
  _RAND_27 = {1{`RANDOM}};
  byte_count = _RAND_27[16:0];
`endif // RANDOMIZE_REG_INIT
  if (reset) begin
    state = 2'h0;
  end
  if (reset) begin
    io_in_error_state_REG = 1'h0;
  end
  if (reset) begin
    ll_byte_index_0 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_1 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_2 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_3 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_4 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_5 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_6 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_7 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_8 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_9 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_10 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_11 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_12 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_13 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_14 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_15 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_16 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_17 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_18 = 8'h0;
  end
  if (reset) begin
    ll_byte_index_19 = 8'h0;
  end
  if (reset) begin
    byte0_reg = 8'h0;
  end
  if (reset) begin
    byte1_reg = 8'h0;
  end
  if (reset) begin
    is_short_pkt_prev = 1'h0;
  end
  if (reset) begin
    valid = 1'h0;
  end
  if (reset) begin
    word_count = 16'h0;
  end
  if (reset) begin
    byte_count = 17'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS

  // ===========================================================================
  // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap)
  //
  //   Localises exactly WHERE a sustained A->B multi-beat long-DATA packet dies
  //   on die_b. The slow APB poll (~0.5 s/sample) cannot catch the first
  //   long-packet START transient at ~4.7 MHz link rate; this block LATCHES it
  //   in the `clock` (recovered RX link) domain so a later APB read still sees:
  //     (a) whether the framer EVER saw a long packet (is_long_ever);
  //     (b) the corrected_ph (decoded header: [7:0]=length byte, [23:8]=cand.
  //         word_count) captured AT THE FIRST is_long — garbage here => EYE
  //         corruption of the header word;
  //     (c) how far byte_count ever climbed (max_byte_count) — if it stalls
  //         far below (length+1)*16 the stream is dying mid-packet;
  //     (d) a saturating count of long-packet starts (long_start_count);
  //     (e) sticky endOfPacket-ever / framer-error-ever / valid-ever.
  //
  //   Pure read-only fan-out of existing framer nets — the datapath is
  //   bit-identical. Reset is the framer `reset` (same as the FSM regs). The
  //   captured fields stay valid until reset (a fresh POR / link reset). All
  //   sticky, monotonic, or capture-once -> safe to 2-flop-sync per-field into
  //   apb_clk (same quasi-static treatment as the other obs snapshots).
  // ===========================================================================
  reg        rxcap_is_long_ever;
  reg        rxcap_eop_ever;
  reg        rxcap_err_ever;        // framer state == 2'h2 (byte-align error)
  reg        rxcap_valid_ever;
  reg [15:0] rxcap_ph_at_first;     // corrected_ph[15:0] at FIRST is_long
  reg [16:0] rxcap_max_byte_count;  // max byte_count ever reached
  reg [14:0] rxcap_long_start_cnt;  // saturating count of long-packet starts

  // A "long-packet start" = is_long asserted while the framer is hunting.
  // SoC Labs 2026-07-03 P1/P2 discriminator: the original condition borrowed
  // valid_byte_reg from the 0-LANE FSM guard; the multi-lane acceptance at
  // the hunt transition has no such term, so the counter was structurally
  // blind to idle-preceded multi-lane long starts (silicon read ever=1/cnt=0
  // for the dying isolated packet). Drop it so the counter tracks is_long
  // decodes, and separately latch WHY the acceptance guard rejected: the
  // sticky rxcap_long_blocked + live long_pkt_gate go out on RXCAP0[17:16].
  // gate=0 -> P1 (first_short_pkt_seen re-armed closed by a post-bringup
  // llrx reset; the 0x44-47-only whitelist can never re-latch on bFC
  // keepalives); gate=1 with garbage ph_at_first {wc,id} -> P2 (idle-edge
  // header rotation failing long_pkt_len_ok).
  wire rxcap_long_start    = is_long_pkt & (state == 2'h0);
  wire rxcap_long_rejected = is_long_pkt & (state == 2'h0)
                             & ~(long_pkt_gate & long_pkt_len_ok);
  reg  rxcap_long_blocked;

  always @(posedge clock or posedge reset) begin
    if (reset) begin
      rxcap_is_long_ever   <= 1'b0;
      rxcap_eop_ever       <= 1'b0;
      rxcap_err_ever       <= 1'b0;
      rxcap_valid_ever     <= 1'b0;
      rxcap_ph_at_first    <= 16'h0;
      rxcap_max_byte_count <= 17'h0;
      rxcap_long_start_cnt <= 15'h0;
      rxcap_long_blocked   <= 1'b0;
    end else begin
      // Sticky "ever" flags.
      if (is_long_pkt)        rxcap_is_long_ever <= 1'b1;
      if (endOfPacket)        rxcap_eop_ever     <= 1'b1;
      if (state == 2'h2)      rxcap_err_ever     <= 1'b1;
      if (valid)              rxcap_valid_ever   <= 1'b1;
      if (rxcap_long_rejected) rxcap_long_blocked <= 1'b1;
      // Capture the decoded header at the FIRST is_long decode (was gated on
      // valid_byte_reg -> never captured for the dying packet; see above).
      if (is_long_pkt & ~rxcap_is_long_ever)
        rxcap_ph_at_first <= corrected_ph[15:0];
      // Track the deepest byte_count the framer ever reached.
      if (byte_count > rxcap_max_byte_count)
        rxcap_max_byte_count <= byte_count;
      // Saturating long-packet-start counter.
      if (rxcap_long_start & (rxcap_long_start_cnt != 15'h7FFF))
        rxcap_long_start_cnt <= rxcap_long_start_cnt + 15'h1;
    end
  end

  // rxcap0 = {marker 0xC0, ever-flags[3:0], framer state[1:0], 2'b0, ph[15:0]}
  assign io_obs_rxcap0 = {8'hC0,
                          rxcap_is_long_ever,  // [23] long packet EVER seen
                          rxcap_eop_ever,      // [22] endOfPacket EVER fired
                          rxcap_err_ever,      // [21] framer error-state EVER
                          rxcap_valid_ever,    // [20] LL_RX valid EVER
                          state,               // [19:18] live framer state
                          rxcap_long_blocked,  // [17] long REJECTED by hunt guard EVER (sticky)
                          long_pkt_gate,       // [16] live first_short_pkt_seen (gate)
                          rxcap_ph_at_first};  // [15:0] corrected_ph {wc_lo,id} @ first long
  // rxcap1 = {max_byte_count[16:0], long_start_count[14:0]}
  assign io_obs_rxcap1 = {rxcap_max_byte_count, rxcap_long_start_cnt};

endmodule
