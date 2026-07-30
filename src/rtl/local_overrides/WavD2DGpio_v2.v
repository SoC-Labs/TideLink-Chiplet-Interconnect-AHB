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
// WavD2DGpio — SoC Labs LOCAL OVERRIDE of deps/tidelink-phy/rtl/wav/
// WavD2DGpio.v (submodule copy stays pristine — the tidelink_lane_deskew_v2
// override idiom). Wired in by flists/tidelink_fpga_v2.flist in place of the
// deps file. ONE functional deviation from the submodule:
//
//   R-A FINALIZE ANCHOR-VERIFY (2026-07-04): new output io_anchor_verified —
//   a sticky, POR/clear-reset latch that sets when, WITH the deskew re-anchor
//   ENGAGED (epoch_anchored_w = the deskew `reanchored` latch), a post-deskew
//   word matches TIDELINK_SYNC_WORD EXACTLY on EVERY active lane
//   simultaneously (the framer's own zero-tolerance cross-lane acceptance
//   criterion, computed from the EXISTING rawobs dbg_lane_any_match_w
//   compares — see the anchor-verify block below the rawobs latches). A lane
//   whose sticky sync_idx latched ONE SLOT OFF (a tol-5 Hamming wrong-slot
//   confirm on a marginal eye — the die_b byte-lane[23:16] silicon
//   corruption, 0x24->0x5c) still matches its OWN slice exactly, but one
//   beat AWAY from the other lanes' beacon beat — so the SIMULTANEOUS
//   all-active-lane exact match can NEVER fire on a mis-anchored link, while
//   a correct anchor fires it on every clean beacon beat (every SYNC_PERIOD
//   words). Cleared by the same sync_obs_clr_pulse that re-arms the deskew
//   (the winscan F3 clear), so each re-anchor retry re-proves the verify
//   from scratch. This domain (gpiorx_0_io_link_clk, POR-only reset) keeps
//   observing through the Q1 LL-swreset quiesce — the LL-domain
//   obs_sync_detected_cnt counter is held in reset exactly when the verify
//   must run, which is why that existing counter could not be reused.
//   Consumed by the winscan FSM's WS_FINALIZE release gate
//   (axi_chiplet_controller.sv ws_verify_q). Default V1/manual behaviour is
//   untouched: the output is pure read-side fan-out, no existing net is
//   rewired.
// =============================================================================
// L1 OWNED FORK — TideLink GPIO PHY vendor-layer split (PLAN §1)
//
// Upstream (L0): axi-chiplet-controller @ efe5623, logical/wlink/WavD2DGpio.v
//                Pristine reference twin: rtl/wav/upstream/WavD2DGpio.v
// Drift guard:   scripts/check_wav_drift.sh
//
// Carried fix families vs upstream (top-level 8-lane SerDes wrapper):
//   * SoC Labs §9 clock fix + Target A split — USE_CLKBUF (deprecated combined
//     alias) / USE_CAP_CLKBUF / USE_LNK_CLKBUF parameter threading to the
//     per-lane WavD2DGpioRx clean recovered-clock paths.
//   * SoC Labs §9 T3a — USE_T3A pass-through (per-lane self-aligning RX
//     comma-hunt enable).
//   * SoC Labs §9 alignment-control inputs (APB-driven from Wlink.v) +
//     §9.7 per-lane 4-bit PHASE sweep (2026-05-15) + alignment patch
//     (2026-05-05): per-PHY deserialiser phase offset, bits[20:17] write
//     enable for swi_phase_offset.
//   * SoC Labs PHY refactor Steps 1-3 (2026-06-04) — owned combinational TX
//     front-end masking, owned RX demask (tidelink_phy_rx_demask, single
//     instance feeding both downstream consumers), and the DATAPATH-SPLIT
//     FIX: one post-deskew datapath for lane_checker and link consumers.
//   * Cross-lane deskew — instantiates tidelink_lane_deskew (LANES=8,
//     WIDTH=16, DEPTH_LOG=4, SYNC_REANCHOR_EN=0); free-running writes,
//     training words flow through the FIFO too.
//   * FIX-R seed + FIX-R-proper (2026-06-10) — GLOBAL word-window pin fanned
//     to all lanes, WORD_PIN_AUTO compile chicken bit and runtime
//     io_swi_word_pin_auto_en select for the autonomous per-lane window pin.
//
// RULE: regenerating from Chisel must NEVER overwrite this file. Regenerate
// into a scratch area, refresh rtl/wav/upstream/, then port the patches
// forward into this fork by hand.
// =============================================================================
module WavD2DGpio #(
  // SoC Labs §9 clock fix: pass-through to per-lane WavD2DGpioRx.USE_CLKBUF
  // (default 0 = sim/ASIC bit-exact; FPGA wrapper sets 1 via threading).
  //
  // Target A (2026-05-28, see docs/TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md):
  // USE_CLKBUF is now a DEPRECATED combined alias. It still works (callers
  // setting only USE_CLKBUF=1 get both BUFGs as before), but the new split
  // is USE_CAP_CLKBUF (BUFG on io_pad_clk capture path) and USE_LNK_CLKBUF
  // (BUFG on the derived word-clock ~adj_count[3]). The Target A FPGA
  // bring-up wants USE_CAP_CLKBUF=0 (BD handles the pad-clock BUFG via a
  // single IBUFG→BUFG so the slave's pad_clk_rx pin sees ~one BUFG-input
  // worth of load instead of 8) and USE_LNK_CLKBUF=1 (the fabric-derived
  // /16 word-clock still needs a per-lane BUFG to avoid LUT-driving-clock
  // warnings).
  parameter USE_CLKBUF     = 1'b0,
  // SoC Labs 2026-06-21: single shared capture BUFG (cap BUFGs 8->1) to cut die_b's
  // SRCC (Y9) clock jitter/skew that holds its per-lane eye at width 2 (vs die_a MRCC
  // eye=16) -> marginal data capture. Requires a clean IP re-synth (IPCACHE clears).
  parameter USE_CAP_CLKBUF = 1'b0,
  parameter USE_LNK_CLKBUF = USE_CLKBUF,
  // ==========================================================================
  // SoC Labs PHASE-B SHARED CAPTURE-CLOCK BUFG (2026-07-14).
  //
  // MEASURED DEFECT: with USE_CAP_CLKBUF=0 (the setting above — today's build)
  // each WavD2DGpioRx derives its capture clocks from its OWN local WavClockMux
  // chain. But every input to that chain is LANE-IDENTICAL by construction (see
  // the gpiorx_<N> assigns below: io_pad_clk = io_pad_clk_rx, io_scan_mode,
  // io_scan_clk, io_pol = out_prepend_swi_polarity — the same nets for all 8
  // lanes), so Vivado legally merged the 8 mux chains into ONE LUT and drove
  // all 8 lanes' capture flops from its output — a fanout-372 GENERAL-ROUTING
  // net. Routed per-lane capture-clock delay came out at lanes 2/5/6 =
  // 8.230/8.604/8.808 ns but lane 7 = 15.281 ns (~7 ns out), while data-path
  // skew across those same lanes is only 0.095 ns. That placement-varying
  // inter-lane clock skew — amplified by the all-lanes-AND commit gate — is
  // the bring-up lottery. It is PHYSICAL, not logic.
  //
  // FIX (parent hoist): because the chain is already lane-identical, compute it
  // ONCE here, buffer each of its two outputs through ONE BUFG, and fan the
  // results to all 8 lanes (WavD2DGpioRx.USE_EXT_CAP_CLK). Logically identical
  // — the SAME Stdcell modules in the SAME order with the SAME selects, so the
  // io_pol inversion is PRESERVED (unlike USE_CAP_CLKBUF, which bypasses the
  // io_pol mux and is unsafe because io_pol resets to 1 — see the WARNING in
  // WavD2DGpioRx_v2.v). Only the physical net changes: a dedicated global clock
  // net instead of a shared high-fanout routing LUT.
  //
  // BUFG BUDGET: 2 (not 16). A per-lane buffer would need 16 and take the
  // design from 15/32 to 31/32 BUFGs; the shared hoist takes it to 17/32.
  //
  // Defaults to USE_CLKBUF, so FPGA (USE_CLKBUF=1) picks it up automatically
  // and sim/ASIC (USE_CLKBUF=0) keep today's per-lane passthrough — no new
  // plumbing needed anywhere up the chain.
  parameter USE_SHARED_CAP_BUFG = USE_CLKBUF,
  // SoC Labs §9 T3a (2026-05-19): self-aligning RX comma hunt. Per-lane
  // WavD2DGpioRx hunts for the per-lane training byte in the io_pad bit
  // stream and slips `count` to align to the byte boundary. The per-lane
  // training bytes are passed via per-instance TRAINING_BYTE parameter
  // overrides on the gpiorx_<N> instances below (matching the constants
  // wired to gpiotx_<N>.io_training_pattern — lane 0 = 0xA3, ..., lane 7 =
  // 0x2D). Default 0 (sim/ASIC bit-exact); FPGA wrapper sets 1.
  parameter USE_T3A   = 1'b0,
  // SoC Labs FIX-R-proper (2026-06-10): compile chicken bit for the per-lane
  // AUTONOMOUS word-window pin (WavD2DGpioRx WORD_PIN_AUTO — the matcher that
  // re-derives the completed-word WINDOW from the per-lane 16-bit training
  // word at every training session, killing the per-carrier-session window
  // lottery the calibrator is blind to). Default 1 = matcher present; the
  // RUNTIME select is io_swi_word_pin_auto_en below. 0 = bit-exact
  // pre-FIX-R-proper (matcher pruned, io_swi_word_pin_in always applies).
  parameter WORD_PIN_AUTO = 1'b1,
  // SoC Labs epoch anchor (2026-06-12, V37_FINAL_DIAGNOSIS fix #1):
  // training-exit-anchored cross-lane word-EPOCH deskew priming in
  // tidelink_lane_deskew (see its TRAINING-ANCHORED EPOCH PRIMING header).
  // The occupancy-only deskew cannot correct whole-word per-lane CONTENT
  // epoch offsets (the v37 B->A framed-but-undecodable CR failure); the
  // anchor measures them from the simultaneous all-lane training-exit edge
  // (constant pattern -> data transition) and equalises the per-lane read
  // pointers, latched through data mode.
  // DEFAULT 0 (2026-07-17 plumbing fix): now that this param is FORWARDED to
  // u_deskew (it used to be dropped for a hard 1'b0), the default must stay 0 so
  // the shipping build keeps EPOCH off / SYNC_REANCHOR on (the corrector the
  // on-chip winscan/autoneg autonomy stack depends on — v2_winscan_fsm /
  // v2_autonomous_sync_detect require the deskew `reanchored` latch + sync_dist).
  // Set 1 (via Wlink/WlinkGPIOPHY or a defparam) to select the one-shot EPOCH
  // anchor (SYNC_REANCHOR_EN becomes its complement in the u_deskew instance).
  parameter EPOCH_ANCHOR_EN = 1'b0
) (
  input          clock,
  input          reset,
  input          auto_in_psel,
  input          auto_in_penable,
  input          auto_in_pwrite,
  input  [31:0]  auto_in_pwdata,
  input  [3:0]   auto_in_pstrb,
  output         auto_in_pready,
  output [31:0]  auto_in_prdata,
  input          io_scan_mode,
  input          io_scan_asyncrst_ctrl,
  input          io_scan_clk,
  output         io_scan_out,
  input          io_link_tx_tx_en,
  output         io_link_tx_tx_ready,
  input  [127:0] io_link_tx_tx_link_data,
  input  [7:0]   io_link_tx_tx_lane_mask,
  output         io_link_tx_tx_link_clk,
  output [127:0] io_link_rx_rx_link_data,
  input  [7:0]   io_link_rx_rx_lane_mask,
  output         io_link_rx_rx_link_clk,
  input          io_hsclk,
  input          io_por_reset,
  output         io_pad_clk_tx,
  output         io_pad_tx_0,
  output         io_pad_tx_1,
  output         io_pad_tx_2,
  output         io_pad_tx_3,
  output         io_pad_tx_4,
  output         io_pad_tx_5,
  output         io_pad_tx_6,
  output         io_pad_tx_7,
  input          io_pad_clk_rx,
  input          io_pad_rx_0,
  input          io_pad_rx_1,
  input          io_pad_rx_2,
  input          io_pad_rx_3,
  input          io_pad_rx_4,
  input          io_pad_rx_5,
  input          io_pad_rx_6,
  input          io_pad_rx_7,
  // SoC Labs §9 alignment-control inputs (APB-driven from Wlink.v).
  // Tie to 0 in environments without APB plumbing (defaults to passthrough).
  // Composed with the sim-only soft-strap regs below via OR so the legacy
  // hierarchical-force path in cocotb keeps working without changes.
  input  [23:0]  io_swi_bit_slip_in,
  input          io_swi_training_mode_in,
  // SoC Labs §9.7 per-lane PHASE sweep (2026-05-15): per-lane 4-bit
  // sub-bit sample-point adjust, packed 8 lanes x 4 bits — lane N at
  // bits [4*N+3 : 4*N]. Mirrors io_swi_bit_slip_in's per-lane packing
  // exactly (that path is the template). OR-merged per-lane with the
  // global APB-driven swi_phase_offset reg below so the existing
  // global-phase APB path (PHY ctrl reg bits[20:17]) is preserved:
  // any lane the calibrator/SW-override leaves at 0 still takes the
  // global APB phase. Tie to 0 in environments without the chiplet
  // controller — default keeps the legacy single-global-phase
  // behaviour bit-exact.
  input  [31:0]  io_swi_phase_offset_in,
  // SoC Labs FIX-R seed (2026-06-10): GLOBAL word-window pin, fanned to all
  // 8 WavD2DGpioRx lanes (the window-pin lottery is lane-identical by
  // construction — all lanes' counts share one clock and one por release).
  // Slides each lane's completed-word WINDOW by 0..15 capture cells: the
  // third alignment dimension that slip/phase rotations cannot reach (the
  // un-sweepable 1-2^-m dirty-word floor — see WavD2DGpioRx
  // g_word_reg_pure). Tie to 4'h0 for the bit-exact legacy framing.
  input  [3:0]   io_swi_word_pin_in,
  // SoC Labs FIX-R-proper (2026-06-10): RUNTIME select for the autonomous
  // window pin, fanned to all 8 lanes. 1 = each lane applies its own
  // training-derived auto pin (the deterministic bring-up default); 0 =
  // io_swi_word_pin_in applies (manual winscan/override + legacy framing).
  // Tie 0 for bit-exact pre-FIX-R-proper behaviour.
  input          io_swi_word_pin_auto_en,
  // SoC Labs SYNC-insert (V2 LL re-hunt beacon, 2026-06-15) — DEFAULT-OFF.
  //   io_link_tx_tx_idle      : WlinkTxLinkLayer io_link_idle (inter-packet
  //                             idle). SYNC is only inserted while idle so it
  //                             can never overwrite a real payload word.
  //   io_swi_sync_insert_en_in: APB feature enable, DEFAULT 0 (Region 8 slot 0
  //                             bit[2] SWI_SYNC_INSERT_EN, SoC addr 0x44032100).
  // With io_swi_sync_insert_en_in=0 the tidelink_phy_sync_insert below is a PURE
  // passthrough (data_o==data_i) so the TX datapath is BIT-IDENTICAL to today.
  // Both default to 0 (tied in cocotb / V1 builds), preserving legacy behaviour.
  input          io_link_tx_tx_idle,
  input          io_swi_sync_insert_en_in,
  // SoC Labs SYNC-insert GATE FIX (2026-06-15, PART 2) — DEFAULT-OFF.
  //   io_swi_sync_force_always_in: APB control bit (Region 8 slot 0 bit[3]
  //   SWI_SYNC_FORCE_ALWAYS, SoC addr 0x44032100). DEFAULT 0. When 0 the SYNC
  //   beacon keeps the original idle-gated PRODUCTION behaviour (tx_sync_en_w
  //   depends on io_link_tx_tx_idle). When 1, the io_link_tx_tx_idle term is
  //   DROPPED so the inserter fires on enable alone (it still self-gates on
  //   ~training internally — see tidelink_phy_sync_insert). The idle gate is
  //   sparse during the FC handshake so it rarely coincides with the 1-in-32
  //   inserter counter on silicon; force_always lets the beacon fire so the
  //   Wlink RX framer can re-hunt during bring-up. With both this AND
  //   io_swi_sync_insert_en_in = 0 (the V1 / default-V2 tie) the gate is
  //   BIT-IDENTICAL to today.
  input          io_swi_sync_force_always_in,
  // SoC Labs SYNC-insert TX OBSERVABILITY (2026-06-15, PART 1) — read-only.
  //   io_tx_sync_ins_cnt  : 16-bit SATURATING count of TX word-clock cycles the
  //                         inserter physically drove a SYNC word (saturates at
  //                         0xFFFF). Proves whether the PHY is inserting.
  //   io_tx_link_idle_level : live io_link_tx_tx_idle level (TX word-clk domain).
  //   io_tx_training_level  : live effective_training_mode_tx_raw level.
  // All in the io_link_tx_tx_link_clk domain; CDC'd to apb_clk in the chiplet
  // controller (mirrors obs_sync_detected_cnt). Read-only — never perturbs the
  // datapath. 0 / quiescent in V1 builds (ports tied off / pruned).
  output [15:0]  io_tx_sync_ins_cnt,
  output         io_tx_link_idle_level,
  output         io_tx_training_level,
  // Epoch-anchor engagement observables (fix2, 2026-06-14). Route to the PHY
  // status APB regfile (SWI_EPOCH_STATUS). link_rx_clk domain. 0 when
  // EPOCH_ANCHOR_EN=0. Unconnected/pruned where not consumed.
  output         io_epoch_anchored,
  output [5:0]   io_epoch_span,
  // STICKY-POISON per-lane sync_seen observability (2026-06-23). The deskew's
  // out_clk-synced per-lane sync_seen vector (which lanes' SYNC re-anchor latch
  // has COMMITTED a periodic-confirmed SYNC index). Surfaced to APB so silicon
  // can distinguish 'no lane armed' (0x00), 'lanes armed but indices
  // inconsistent' (set yet out_data never coheres / reanchored=0) and
  // 'armed + coherent' (set AND reanchored=1). gpiorx_0_io_link_clk domain.
  // 0 unless SYNC_REANCHOR_EN. Routed up through WlinkGPIOPHY -> Wlink ->
  // axi_chiplet_controller -> SoC 0x4403_215C (Region 10 slot 7, RO).
  output [7:0]   io_sync_seen_vec,
  // DATA-MODE per-lane SYNC HAMMING-DISTANCE OBS (2026-06-25, the winscan
  // metric). The deskew's out_clk-synced per-lane 5-bit Hamming distance of the
  // current word to that lane's SYNC slice. Surfaced to APB so a no-build
  // winscan can centre the per-lane IDELAY tap on the DATA-mode RX eye (a small
  // distance = a well-centred tap). gpiorx_0_io_link_clk domain. 0 unless
  // SYNC_REANCHOR_EN. Routed up through WlinkGPIOPHY -> Wlink ->
  // axi_chiplet_controller -> SoC 0x4403_21AC (Region D slot 3, lane-selected).
  output [39:0]  io_sync_dist_vec,
  // R-A FINALIZE ANCHOR-VERIFY (2026-07-04, LOCAL OVERRIDE — see file
  // header). Sticky "the ENGAGED re-anchor has delivered >=1 post-deskew word
  // that EXACTLY equals TIDELINK_SYNC_WORD on every active lane
  // simultaneously". gpiorx_0_io_link_clk domain, POR-only reset + the F3
  // sync_obs_clr re-arm. Routed up through WlinkGPIOPHY -> Wlink ->
  // axi_chiplet_controller (ws_verify_q, the WS_FINALIZE release gate).
  output         io_anchor_verified,
  // -------------------------------------------------------------------------
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 1/2/3).
  // Instantiates tidelink_phy_sync_detect on the POST-DESKEW 128-bit word
  // (deskew_aligned_data) in the gpiorx_0_io_link_clk (RX link-clock) domain.
  // The TX is confirmed inserting SYNC on silicon, but the Wlink RX framer's
  // full-128 exact compare (WlinkRxLinkLayer:295) NEVER detects it because a
  // single off-eye lane's SYNC slice defeats the all-128 equality. The
  // mask-aware per-lane detector ANDs only the MASKED-IN lanes' slice matches,
  // so it fires even when a marginal lane drops its slice. PRIMARY = pure
  // OBSERVABILITY (which lanes carry their SYNC slice); never perturbs the
  // datapath. Read-only (sync_en_i tied 1), so it is live in V1 / default-V2
  // too — it only reads deskew_aligned_data, which already exists.
  //   io_sync_lane_mask_in : SW-writable per-lane mask (PART 3, default 0xFF,
  //                          Region 9 slot 2 = 0x4403_2128). Masks marginal
  //                          lanes so an off-eye lane cannot defeat the match.
  //   io_sync_seen_cnt     : 16-bit SATURATING count of mask-aware SYNC matches
  //                          on the post-deskew word (RX link-clk domain). >0
  //                          proves the RX physically sees coherent SYNC.
  //   io_sync_seen_lane_sticky : 8-bit STICKY OR of every lane that has EVER
  //                          matched its SYNC slice (cleared only on POR). THE
  //                          KEY PER-LANE DIAGNOSTIC — shows which lanes deliver.
  //   io_sync_seen_pulse   : live 1-cycle mask-aware match (PART 2 robust
  //                          re-hunt source; OR'd into the framer re-hunt in
  //                          Wlink.v ONLY when SWI_SYNC_ROBUST_DETECT=1).
  // All RX-link-clk domain; CDC'd to apb_clk in axi_chiplet_controller.sv
  // (mirrors obs_sync_detected_cnt). 0 / quiescent where ports tied off.
  input  [7:0]   io_sync_lane_mask_in,
  // SoC Labs RX SYNC-detect Hamming TOLERANCE (2026-06-17). Per-lane SYNC-slice
  // Hamming budget for the mask-aware detector + the live-match oracle. 0 =
  // EXACT (bit-identical to all prior images). A non-zero value lets a marginal
  // lane that drops up to N bits/word in its SYNC slice still match, so the
  // re-anchor (io_sync_seen_pulse -> Wlink re-hunt) engages on off-eye silicon.
  // SW-writable strap (SoC 0x4403_2128 [12:8]); CDC'd in the chiplet controller.
  // DEFAULT 0 -> bit-identical. Tie 5'h0 where the controller is absent.
  input  [4:0]   io_sync_tol_in,
  output [15:0]  io_sync_seen_cnt,
  output [7:0]   io_sync_seen_lane_sticky,
  output         io_sync_seen_pulse,
  // SoC Labs RX RAW-WORD + PERMUTATION observability (2026-06-15, rawobs).
  // PURE READ-SIDE taps on deskew_aligned_data (the framer's bus) — no datapath
  // perturbation, so default-V2 / V1 are BIT-IDENTICAL. All in the RX link-clk
  // domain (gpiorx_0_io_link_clk); CDC'd to apb_clk in axi_chiplet_controller.sv.
  //   io_dbg_raw_word       : 128-bit BEST-MATCH-latched post-deskew word — the
  //                           closest-to-SYNC word the RX actually reassembled
  //                           (latched when fixed-position match popcount peaks).
  //   io_dbg_lane_any_match : 8-bit fixed-position match vector of that word.
  //   io_dbg_best_popcount  : 0..8 popcount of that vector (sticky max).
  //   io_dbg_slice_idx      : 8 x 4-bit map — for RX lane i, which TX slice j it
  //                           carries (0xF = none). Decodes identity vs
  //                           permutation vs bit-rotation. THE DECISIVE DECODER.
  output [127:0] io_dbg_raw_word,
  output [7:0]   io_dbg_lane_any_match,
  output [3:0]   io_dbg_best_popcount,
  output [31:0]  io_dbg_slice_idx,
  // -------------------------------------------------------------------------
  // SoC Labs PER-LANE SYNC-match SWEEP ORACLE + word-pin override (2026-06-16,
  // perlane-wp). The existing sync_seen_lane_sticky is POR-only — useless for a
  // live sweep. These add the CLEARABLE per-lane match oracle and the per-lane
  // word-pin SW override that together let the operator sweep each RX lane's
  // word window and read which lanes currently match.
  //
  //   io_sync_obs_clr_in : APB W1-pulse (Region 8 slot 0 bit[5] SWI_SYNC_OBS_CLR,
  //                        SoC 0x4403_2100[5]). Synchronised into the RX link
  //                        clock and edge-detected; one pulse CLEARS the per-lane
  //                        live-match counters AND the sticky "ever-matched"
  //                        vector AND the rawobs best-match latch, so the operator
  //                        can clear-then-observe per sweep step. DEFAULT 0 (no
  //                        clear) -> bit-identical (sticky still POR-clears too).
  //   io_sync_lane_live  : 8-bit LIVE per-lane "matched since the last clear"
  //                        vector — THE sweep oracle. lane[L]=1 iff lane L's
  //                        post-deskew slice has matched its SYNC slice at least
  //                        once since the last clear pulse (saturating 1-bit per
  //                        lane). Read at SoC 0x4403_2144. Pure read-only obs.
  //   io_word_pin_ovr_in : 8 x 4-bit per-lane word-pin override (lane L at
  //                        [4L+3:4L]). Drives each RX lane's window pin when its
  //                        enable bit is set. SoC 0x4403_2148 [31:0].
  //   io_word_pin_ovr_en_in : 8-bit per-lane override enable (lane L at bit L).
  //                        en[L]=1 -> lane L uses io_word_pin_ovr[L] for its
  //                        window; en[L]=0 -> lane L keeps its legacy auto/global
  //                        pin (bit-identical). SoC 0x4403_2148 [39:32] (i.e. the
  //                        enable byte is the low byte of the companion word, see
  //                        the chiplet controller layout). DEFAULT all-0 = legacy.
  // All RX-link-clk domain (counters) / quasi-static straps (override); CDC'd in
  // axi_chiplet_controller.sv. DEFAULT (clr=0, ovr=0, en=0) is BIT-IDENTICAL.
  input          io_sync_obs_clr_in,
  output [7:0]   io_sync_lane_live,
  input  [31:0]  io_word_pin_ovr_in,
  input  [7:0]   io_word_pin_ovr_en_in
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
  reg [31:0] _RAND_3;
  reg [31:0] _RAND_4;
  reg [31:0] _RAND_5;
  reg [31:0] _RAND_6;
`endif // RANDOMIZE_REG_INIT
  wire  gpiotx_0_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_0_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_0_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_1_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_1_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_2_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_2_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_3_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_3_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_4_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_4_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_5_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_5_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_6_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_6_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_scan_mode; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_scan_asyncrst_ctrl; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_scan_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_scan_out; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_reset; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_clk_en; // @[GPIO.scala 190:61]
  wire [15:0] gpiotx_7_io_link_data; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_link_clk; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_pad; // @[GPIO.scala 190:61]
  wire  gpiotx_7_io_pad_clk; // @[GPIO.scala 190:61]
  wire  gpiorx_0_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_0_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_0_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_1_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_1_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_2_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_2_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_3_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_3_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_4_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_4_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_5_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_5_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_6_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_6_io_pad; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_scan_mode; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_scan_asyncrst_ctrl; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_scan_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_scan_out; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_por_reset; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_pol; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_link_clk; // @[GPIO.scala 191:61]
  wire [15:0] gpiorx_7_io_link_data; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_pad_clk; // @[GPIO.scala 191:61]
  wire  gpiorx_7_io_pad; // @[GPIO.scala 191:61]
  wire  hsclk_scan_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  hsclk_scan_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  hsclk_scan_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  hsclk_scan_mux_io_o_z; // @[Stdcell.scala 149:21]
  wire  por_reset_scan_wrs_io_clk; // @[Stdcell.scala 324:21]
  wire  por_reset_scan_wrs_io_scan_ctrl; // @[Stdcell.scala 324:21]
  wire  por_reset_scan_wrs_io_reset_in; // @[Stdcell.scala 324:21]
  wire  por_reset_scan_wrs_io_reset_out; // @[Stdcell.scala 324:21]
  // ---------------------------------------------------------------------------
  // SoC Labs PHY refactor (Step 1, 2026-06-04) — owned combinational TX front-
  // end. The inline per-lane slices (tx_lane_data_N = io_link_tx_tx_link_data
  // [16*N+:16]) and mask AND-gates (gpiotx_N_io_link_data = tx_lane_en_N ?
  // tx_lane_data_N : 16'h0) are replaced by two owned modules:
  //   tidelink_phy_tx_segmenter : 128b -> 8x16b (lane i = [16*i+:16], lane0=LSBs)
  //   tidelink_phy_tx_mask      : masked lane -> 16'h0000 (Option-A zero-fill)
  // Behaviour-IDENTICAL: same slice polarity, same per-lane data mask. The leaf
  // training mux (WavD2DGpioTx) still overrides a masked lane during training,
  // so this masks DATA only (see tidelink_phy_tx_mask.sv ORDER DECISION note).
  // io_clk_en is NOT mask-gated. See docs/archive/PHY_REFACTOR_BLUEPRINT.md §2 + §4.
  // ---------------------------------------------------------------------------
  wire [127:0] tx_lane_segmented;
  wire [127:0] tx_lane_masked;
  // Forward-declaration: the SYNC inserter below consumes
  // effective_training_mode_tx_raw, whose continuous driver is ~300 lines down
  // (search "effective_training_mode_tx_raw ="). WavD2DGpio.v has no
  // `default_nettype none, so referencing the name at the instance port BELOW
  // would otherwise spawn an undriven implicit 1-bit wire and SHADOW the real
  // later declaration (VCS IPDW/IWNF -> training_mode stuck Z -> calibrator
  // never locks). Declaring it here (and turning the later line into a plain
  // `assign`) gives the name ONE driven net visible to the inserter instance.
  wire        effective_training_mode_tx_raw;
  // ---------------------------------------------------------------------------
  // SoC Labs SYNC-insert (V2 LL re-hunt beacon, 2026-06-15) — DEFAULT-OFF.
  // Periodically (every TIDELINK_SYNC_PERIOD=32 words) overrides ONE idle link
  // word with the cross-lane SYNC_WORD so the Wlink RX framer
  // (WlinkRxLinkLayer.v) regains a re-hunt beacon and can re-acquire packet
  // byte-phase on silicon (V1 had this via Wlink.v:1181 idle-gated insertion;
  // the V2 branch dropped it — agreed root cause). The beacon is gated by:
  //   * io_swi_sync_insert_en_in : APB feature enable, DEFAULT 0.
  //   * io_link_tx_tx_idle       : only in genuine inter-packet idle, so real
  //                                payload words are never overwritten.
  //   * ~effective_training_mode_tx_raw : never preempt a training word (the
  //                                inserter holds its counter disarmed while
  //                                training, re-arming on the training->data edge).
  // REGRESSION GUARANTEE: with io_swi_sync_insert_en_in=0 the inserter is a PURE
  // passthrough (tx_link_data_sync_w == io_link_tx_tx_link_data), so the TX
  // datapath is bit-identical to today. This is the zero-regression default and
  // is the path taken by V1 builds (port tied 0) and the cocotb default.
  // RX strip is unaffected: WlinkRxLinkLayer already substitutes 0 for SYNC and
  // resets the framer state/word/byte — shared and intact.
  // ---------------------------------------------------------------------------
  wire [127:0] tx_link_data_sync_w;
  wire         tx_sync_inserting_w;
  // Reset-gate the enable so it is a provably-stable 0 during the POR window
  // (swi_sync_insert_en_in is in a different reset domain and is X pre-POR);
  // keeps default-off X-free for lint/formal even though 0&X already folds to 0.
  //
  // GATE FIX (2026-06-15, PART 2): the idle term is now OR-bypassed by the new
  // io_swi_sync_force_always_in control bit. force_always=0 -> original
  // idle-gated production behaviour; force_always=1 -> gate on enable only (the
  // inserter still self-gates ~training internally). With io_swi_sync_insert_en_in
  // = 0 (V1 / default-V2 tie) the whole expression folds to 0 REGARDLESS of
  // force_always, so the default is bit-identical to before.
  // SoC Labs 2026-07-14: `postcount` is Chisel-generated further down (its
  // always-block driver is unchanged and still lives there). Its DECLARATION is
  // hoisted here because the serialiser-drain guard below needs it, and Verilog
  // requires declaration before use. Declaration-only move — no behaviour change.
  reg [7:0] postcount; // @[GPIO.scala 226:114]

  // ---------------------------------------------------------------------
  // SoC Labs 2026-07-14 — SERIALISER-DRAIN GUARD (postcount == 0).
  //
  // THE BUG THIS FIXES (silicon-proven): a SYNC beacon lands on a LIVE payload
  // word and corrupts it (~3 words per 28-word burst). Autonomous bring-up
  // anchored 20/20 but delivered 0/20 channels — data BOTH directions AND the
  // doorbell — because the autonomy heal pins io_swi_sync_insert_en_in=1
  // PERMANENTLY (axi_chiplet_controller.sv:2110, the D2 "NEVER BLIND-OFF"
  // state), so beacons keep firing in data mode. Bench proof, same bitstream:
  //     R8=0x14 (insert_en=1)  =>  filt=25/28, rot=-1   (corrupt)
  //     R8=0x10 (insert_en=0)  =>  GP1 RX byte-exact
  //
  // ROOT CAUSE: io_link_tx_tx_idle is NOT sufficient on its own.
  // WlinkTxLinkLayer asserts idle BEFORE the serialiser has drained, so
  // "idle=1 but serialiser still shifting" is a real window — and it is exactly
  // the window (postcount != 0) describes. A beacon fired there overwrites the
  // tail of the packet still going out.
  //
  // V1 ALREADY HAS THIS GUARD; V2 LOST IT. See WavD2DGpio.v:625 (SoC Labs
  // 2026-06-08 SYNC-guard fix), whose comment names this precise failure:
  //   "WlinkTxLinkLayer asserts idle before the serialiser drains postcount
  //    ... 'idle=1 but serialiser not finished' is EXACTLY the case
  //    postcount != 0."
  //   wire sync_insert = (sync_word_ctr_r==0) & io_link_tx_tx_idle
  //                    & (postcount == 8'h0) & ~effective_training_mode;
  // V2 declares postcount (below) but never gated the beacon with it.
  //
  // WHY THIS, AND NOT "TURN THE BEACONS OFF": D2 (axi_chiplet_controller.sv
  // :1436-1455) deleted the autonomous SYNC-OFF for a GOOD reason — a die that
  // kills its beacons on a LOCAL TIMER starves the PEER's still-running
  // re-anchor (the refill needs OUR beacons; one missed grid slot resets the
  // deskew confirm run), and no timer can bound that skew. Permanent idle-gated
  // beacons are the CORRECT autonomous state: the peer is never dark, the deskew
  // can re-confirm at any time (drift self-healing), and the anchor retries only
  // mean anything because of it. D2's design intent was right — only its
  // DATA-SAFETY claim ("idle-gated insertion is data-safe") was untrue WITHOUT
  // this guard. With the guard the claim becomes TRUE: we keep every property D2
  // wanted (including the 20/20 autonomous anchor rate) and lose the corruption.
  //
  // Scope: the guard is applied ONLY to the idle-gated path. force_always is the
  // winscan scan window (winscan_force_sync), where beacons MUST fire
  // unconditionally; gating that on postcount could starve the scan and regress
  // anchoring. Deliberately untouched.
  // ---------------------------------------------------------------------
  wire         tx_sync_en_w = ~por_reset_scan_wrs_io_reset_out
                            &  io_swi_sync_insert_en_in
                            & (io_swi_sync_force_always_in
                               | (io_link_tx_tx_idle & (postcount == 8'h0)));
  tidelink_phy_sync_insert u_tx_sync_insert (
    .clk              (io_link_tx_tx_link_clk),
    .rst_n            (~por_reset_scan_wrs_io_reset_out),
    .training_mode_i  (effective_training_mode_tx_raw),
    .sync_en_i        (tx_sync_en_w),
    .data_i           (io_link_tx_tx_link_data),
    .data_o           (tx_link_data_sync_w),
    .sync_inserting_o (tx_sync_inserting_w)
  );
  // ---------------------------------------------------------------------------
  // TX-side SYNC-insert OBSERVABILITY (2026-06-15, PART 1) — read-only probe.
  // tx_sync_inserting_w was previously dead-ended (no APB hook). It is the only
  // signal that proves the PHY is PHYSICALLY inserting a SYNC word on TX, so on
  // silicon (where the RX SYNC-detect count stays 0) it disambiguates a TX
  // not-inserting fault from an RX/CDC fault.
  //
  // tx_sync_ins_cnt_q : 16-bit SATURATING counter in the io_link_tx_tx_link_clk
  //                     domain, +1 each cycle tx_sync_inserting_w is high, held
  //                     at 0xFFFF once saturated. Reset por_reset_scan_wrs_io_reset_out.
  // The two live level bits (io_link_tx_tx_idle, effective_training_mode_tx_raw)
  // are exported combinationally; the chiplet controller double-syncs all three
  // into apb_clk. This is observability ONLY — none of it feeds the datapath.
  // ---------------------------------------------------------------------------
  reg  [15:0] tx_sync_ins_cnt_q;
  always @(posedge io_link_tx_tx_link_clk or posedge por_reset_scan_wrs_io_reset_out) begin
    if (por_reset_scan_wrs_io_reset_out) begin
      tx_sync_ins_cnt_q <= 16'h0000;
    end else if (tx_sync_inserting_w && (tx_sync_ins_cnt_q != 16'hFFFF)) begin
      tx_sync_ins_cnt_q <= tx_sync_ins_cnt_q + 16'h0001;  // saturate at 0xFFFF
    end
  end
  assign io_tx_sync_ins_cnt    = tx_sync_ins_cnt_q;
  assign io_tx_link_idle_level = io_link_tx_tx_idle;
  assign io_tx_training_level  = effective_training_mode_tx_raw;
  tidelink_phy_tx_segmenter #(.NUM_LANES(8), .WIDTH(16)) u_tx_segmenter (
    .link_tx_data (tx_link_data_sync_w),
    .lane_word_o  (tx_lane_segmented)
  );
  tidelink_phy_tx_mask #(.NUM_LANES(8), .WIDTH(16)) u_tx_mask (
    .lane_word_i (tx_lane_segmented),
    .lane_mask   (io_link_tx_tx_lane_mask),
    .lane_word_o (tx_lane_masked)
  );
  reg [7:0] precount; // @[GPIO.scala 223:114]
  wire  _precount_in_T = precount == 8'h0; // @[GPIO.scala 224:64]
  wire [7:0] _precount_in_T_2 = precount - 8'h1; // @[GPIO.scala 224:92]
  reg [7:0] swi_pream_count_1; // @[SW.scala 83:22]
  // reg [7:0] postcount;  -- DECLARATION HOISTED above (SoC Labs 2026-07-14) so the
  //                          serialiser-drain guard on tx_sync_en_w can reference it.
  //                          Its always-block driver below is UNCHANGED.
  wire  _postcount_in_T = ~io_link_tx_tx_en; // @[GPIO.scala 227:33]
  wire [7:0] _postcount_in_T_3 = postcount - 8'h1; // @[GPIO.scala 227:96]
  reg [7:0] out_prepend_swi_post_count; // @[SW.scala 83:22]
  // ---------------------------------------------------------------------------
  // SoC Labs PHY refactor (Step 2, 2026-06-04) — owned combinational RX demask.
  // The inline per-lane mux (rx_link_data_N = io_link_rx_rx_lane_mask[N] ?
  // gpiorx_N_io_link_data : 16'h0) is replaced by one owned module:
  //   tidelink_phy_rx_demask : masked lane -> 16'h0000 pre-deskew (Option-A)
  // Behaviour-IDENTICAL: same per-lane AND-to-zero, same mask polarity (bit 1 =
  // enabled). The single instance drives BOTH downstream consumers (the deskew
  // desegmenter and the flat_concat reference) via the rx_link_data_w bus, so
  // there is no double-masking. lane i = [16*i +: 16], lane 0 = LSBs. See
  // docs/archive/PHY_REFACTOR_BLUEPRINT.md §2 (RX) + §4 Step 2.
  // ---------------------------------------------------------------------------
  wire [127:0] rx_lane_raw = {gpiorx_7_io_link_data, gpiorx_6_io_link_data,
                              gpiorx_5_io_link_data, gpiorx_4_io_link_data,
                              gpiorx_3_io_link_data, gpiorx_2_io_link_data,
                              gpiorx_1_io_link_data, gpiorx_0_io_link_data};
  wire [127:0] rx_lane_demasked;
  tidelink_phy_rx_demask #(.NUM_LANES(8), .WIDTH(16)) u_rx_demask (
    .raw_lane_data    (rx_lane_raw),
    .lane_mask        (io_link_rx_rx_lane_mask),
    .masked_lane_data (rx_lane_demasked)
  );
  wire [15:0] rx_link_data_0 = rx_lane_demasked[16*0 +: 16];
  wire [15:0] rx_link_data_1 = rx_lane_demasked[16*1 +: 16];
  wire [15:0] rx_link_data_2 = rx_lane_demasked[16*2 +: 16];
  wire [15:0] rx_link_data_3 = rx_lane_demasked[16*3 +: 16];
  wire [15:0] rx_link_data_4 = rx_lane_demasked[16*4 +: 16];
  wire [15:0] rx_link_data_5 = rx_lane_demasked[16*5 +: 16];
  wire [15:0] rx_link_data_6 = rx_lane_demasked[16*6 +: 16];
  wire [15:0] rx_link_data_7 = rx_lane_demasked[16*7 +: 16];
  // ---------------------------------------------------------------------------
  // SoC Labs PHY refactor (Step 3, 2026-06-04) — DATAPATH-SPLIT FIX. See
  // docs/archive/PHY_REFACTOR_BLUEPRINT.md §3.
  //
  // OLD BUG (deleted here): a bypass mux fed the assembled link bus from a FLAT
  // CONCAT of the per-lane deserialiser words during training (deskew BYPASSED)
  // and from the deskew FIFO output only in data mode. The calibrator's
  // lane_checker oracle taps that bus, so training LOCKED a datapath (flat
  // concat, zero-skew sample-all-on-out_clk) that the real PAYLOAD never used
  // (the deskew FIFO, cross-lane realigned, with FIFO latency). On skewed
  // silicon the two paths disagree, so a lane that "locked" in training still
  // decoded garbage on data.
  //
  // FIX: there is now ONE datapath. The deskew FIFO writes FREE-RUN on each
  // lane_clk whenever rst_n (see tidelink_lane_deskew.sv) — training words flow
  // through the FIFO too — so the lane_checker scores the SAME post-deskew bus
  // the framer reads. The bypass mux + flat_concat net are deleted; the bus is
  // driven DIRECTLY from deskew_aligned_data. effective_training_mode_rx is kept
  // ONLY as the deskew's read-side re-anchor input (training_mode_i): on its
  // falling edge the read side treats the next all-lanes-ready word as the first
  // DATA word and blips out_valid low as the boundary marker. The single tap
  // means the lane_checker, the PRBS validators and the framer all read the same
  // physical (post-deskew) bus — they can no longer disagree.
  //
  // Forward declaration — driver `assign effective_training_mode_rx = ...`
  // appears further below (~line ~505); used here as the deskew re-anchor input.
  wire        effective_training_mode_rx;
  wire [127:0] deskew_aligned_data;
  wire         deskew_out_valid_w;   // high once aligned data is flowing
  // DEPTH_LOG=4 (16 entries, usable spread DEPTH-3=13) — deepened from 8 because
  // the silicon ribbon per-lane word-skew is ~7, which the DEPTH=8 (usable ~5)
  // FIFO could not absorb (HW: deskew never aligned -> constant never locked ->
  // calibrator faulted all lanes, link_up=0). 16 covers ~7 skew with margin.
  // SYNC_REANCHOR_EN: PHY-owned cross-lane SYNC-beacon deterministic re-anchor
  // (docs/IMPLEMENTATION.md §3.3). DISABLED (0) as of 2026-06-08:
  // HW + sim (test_phy_reanchor_transition) proved the re-anchor loads new per-lane
  // read offsets when the FIRST data-mode beacon arrives, SHIFTING an already-locked
  // link mid-stream → collapse at the training→data transition. It is also inert on
  // a broken-ribbon (partial-mask) link (needs all 8 lanes to see SYNC) and could
  // spuriously engage on a floating lane. The lanes lock fine via prime-and-continuous
  // + the calibrator's per-lane slip/phase, so re-anchor is net-harmful here. Re-enable
  // only after the offset-load is made non-disruptive (anchor before lock / cold-link
  // only). DEPTH_LOG is now 5 (32 entries) — V37-robust: EPOCH_OFF_MAX 8->24, 3x
  // epoch-skew margin on the marginal eye (the old DEPTH=16 budget of 8 silently
  // vetoed any spread that drifted past it -> zero-offset fallback -> data NACK).
  // EPOCH_ANCHOR_EN (2026-06-12; fix2 2026-06-14): training-exit-anchored
  // word-EPOCH priming, CONTENT-ONLY. The capture detects the PEER's real
  // pattern->data edge from the RX stream itself (a Hamming-streak on the
  // constant pattern then the first data word) — NOT gated on training_mode_i.
  // effective_training_mode_rx is this die's OWN LOCAL TX training signal and is
  // uncorrelated with the peer's RX-stream exit; the 2994848 gate keyed capture
  // to that wrong die/clock so the anchor never fired on die_a's RX (silicon
  // B->A bring-up fail). WavD2DGpioRx is byte-align-only (no RX training wire),
  // so content is the only available exit reference. Loads offsets in the idle
  // gap right after the content exit (no live framing to disrupt); a lane that
  // never anchors vetoes the load (falls back to plain prime-and-continuous;
  // never engages spuriously on a floating lane). epoch_anchored_w/epoch_span_w
  // are engagement observables, exported via io_epoch_* to the PHY status APB
  // regfile (tidelink_gpio_phy_apb_regs SWI_EPOCH_STATUS @ +0x40).
  wire       epoch_anchored_w;
  wire [5:0] epoch_span_w;
  // STICKY-POISON nets (2026-06-23) — forward-declared BEFORE the deskew instance
  // so the port connections bind the REAL nets (not implicit 1-bit nets). The
  // clear pulse sync_obs_clr_pulse is DRIVEN by the RX-link-clock 2-flop + edge
  // detect further below (its inline `wire ... =` was split into this decl + the
  // assign there); deskew_sync_seen_vec_w carries the obs vector out.
  wire       sync_obs_clr_pulse;
  wire [7:0] deskew_sync_seen_vec_w;   // re-anchor per-lane sync_seen (obs; surfaced via io_sync_seen_vec)
  wire [39:0] deskew_sync_dist_vec_w;  // per-lane SYNC Hamming distance (obs; surfaced via io_sync_dist_vec)
  tidelink_lane_deskew #(
      // SoC Labs 2026-06-24: OCCUPANCY-FALLBACK experiment REVERTED. Setting both
      // anchors off (occupancy / prime-and-continuous) was sim-REFUTED: occupancy
      // aligns only zero/sub-word skew (unit 40/40, 60/60) but SHEARS whole-word
      // cross-lane skew (unit 0/40; integrated v2_gate staircase corrupts data) —
      // it FAILS the sim-gate. V1's "byte-exact A->B" was the ~13% lottery = the
      // times the real silicon skew landed sub-word; occupancy rode the lottery,
      // it never deterministically deskewed word-skew. So SYNC_REANCHOR stays ON;
      // the open problem is making its arming robust on silicon (tol5 sync_seen_vec
      // =0x00 root cause to be re-confirmed before the next arming redesign).
      // PLUMBING FIX (2026-07-17): the two whole-word correctors are mutually
      // exclusive (deskew $fatal if both). Drive SYNC_REANCHOR_EN as the COMPLEMENT
      // of the forwarded EPOCH_ANCHOR_EN param so ONE knob selects the corrector and
      // the mutual-exclusion is satisfied by construction. Default EPOCH_ANCHOR_EN=0
      // => SYNC_REANCHOR_EN=1 (the shipping SYNC re-anchor build — BIT-IDENTICAL to
      // the historical hard `.SYNC_REANCHOR_EN(1'b1)`). Before this fix the param
      // arrived here (WlinkGPIOPHY->WavD2DGpio) but was DROPPED — u_deskew was
      // hard-wired 1'b0/1'b1, so the WlinkGPIOPHY.EPOCH_ANCHOR_EN param was a DEAD
      // KNOB (banner "master=1 (deskew: m=0)") — the NEGO_CFG_RESET failure class.
      .LANES(8), .WIDTH(16), .DEPTH_LOG(5), .SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN),
      // SYNC_REANCHOR_TOL 4->5 (2026-06-24 marginal-eye fix): match the per-lane
      // SYNC-capture Hamming tolerance to the FRAMER it feeds. The framer's
      // tidelink_phy_sync_detect runs at the runtime SWI_SYNC_TOL strap (SoC
      // 0x4403_2128[12:8] = 0x5e4 on silicon -> tol=5); the deskew's g_sync_capture
      // defaulted to 4, so it was STRICTER than the framer. On die_b's marginal eye
      // each active lane's RX SYNC slice carries a FIXED per-lane bit error: lane 6
      // lands at Hamming dist<=4 of its slice (sync_hit fired) but lanes 2/5/7 land
      // at exactly dist 5 — VISIBLE to the framer (livematch=0xE5) yet INVISIBLE to
      // the deskew, whose sync_hit never fired -> the whole periodic/gap/K=2 confirm
      // machinery (gated behind `if (sync_hit)`) was dead code on those lanes ->
      // sync_seen_vec=0x40 (lane 6 only), reanchored=0, RXW=0. At tol=5 all four
      // active lanes capture, the re-anchor engages, out_data coheres on the SYNC
      // word. The historical reason the DUT default was kept at 4 (per-lane one-shot
      // payload false-fire) NO LONGER applies: the self-gating periodic+gap+K=2
      // confirm rejects sporadic AND continuous within-tol false hits INDEPENDENTLY
      // of tol (a continuous within-tol stream keeps the gap from ever saturating,
      // so the periodic re-match never fires) — sim-proven at tol=5 (EXP2 poison
      // tests still reject the pre-SYNC poison; jitter test arms all lanes). The
      // anti-poison gate is intact; only the sync_hit tolerance changed.
      .SYNC_REANCHOR_TOL(5),
      // EPOCH_MATCH_THRESH 3->5 (2026-06-15 silicon fix5): the epoch matcher must
      // accept exactly what the lane-checker LOCK accepts. Bring-up relaxes the
      // per-lane Hamming lock threshold 3->5 for die_a's skewed RX (0x160=5);
      // with the matcher hard-wired at 3, die_a's dist-4/5 lanes LOCK (lk=0xff)
      // but never satisfy ep_match -> streak never builds -> epoch_anchored=0
      // forever (silicon-confirmed: die_a never anchors, die_b clean eye does).
      // Band becomes dist<=5 || >=11; idle (0x0000, dist 8 from PATTERN_W) stays a
      // clean non-match so training-exit detection is preserved.
      .EPOCH_MATCH_THRESH(5),
      // SoC Labs 2026-06-22: switch the BUILT deskew from training-exit EPOCH anchor
      // (degenerate on the epoch-blind training pattern, silicon span unstable 0..12)
      // to SYNC_REANCHOR (aligns per-lane SYNC slices to one beat off the SYNC content
      // that floods in data mode). Mutually exclusive with SYNC_REANCHOR_EN above
      // (DUT $fatal if both), so EPOCH must be hard-0 here. Sim-proven: tidelink_lane_
      // deskew unit test fixed_skew/index_skew/reduced_mask_e4 cohere (out_data==SYNC_WORD)
      // under reanchor where EPOCH gives 0/160. EPOCH path stays available via the param.
      //
      // PLUMBING FIX (2026-07-17): FORWARD the module param instead of the hard 1'b0.
      // Default EPOCH_ANCHOR_EN=0 => this is BIT-IDENTICAL to the historical `1'b0`
      // (SYNC re-anchor build). Setting EPOCH_ANCHOR_EN=1 at Wlink/WlinkGPIOPHY (or a
      // tb defparam on phy.EPOCH_ANCHOR_EN) now genuinely engages the one-shot
      // training-exit EPOCH anchor in u_deskew — the mesochronous/forwarded-clock
      // corrector (frozen skew measured once at training exit, no live SYNC beacon,
      // so it does NOT depend on the data-mode beacon that is the B->A corruptor).
      .EPOCH_ANCHOR_EN(EPOCH_ANCHOR_EN)
  ) u_deskew (
      .rst_n         (~io_por_reset),
      .lane_clk      ({gpiorx_7_io_link_clk, gpiorx_6_io_link_clk,
                       gpiorx_5_io_link_clk, gpiorx_4_io_link_clk,
                       gpiorx_3_io_link_clk, gpiorx_2_io_link_clk,
                       gpiorx_1_io_link_clk, gpiorx_0_io_link_clk}),
      .lane_data     ({rx_link_data_7, rx_link_data_6,
                       rx_link_data_5, rx_link_data_4,
                       rx_link_data_3, rx_link_data_2,
                       rx_link_data_1, rx_link_data_0}),
      // REDUCED-LANE link (2026-06-17): the deskew's word-read readiness +
      // epoch-anchor consensus must ignore masked-out RX lanes. Drive from the
      // SAME RX data-path lane mask the RX demask (tidelink_phy_rx_demask) and
      // the Wlink RX gather (WlinkRxLinkLayer) use — io_link_rx_rx_lane_mask
      // (Wlink swi_rx_lane_mask, SoC Wlink-block 0x214 [31:16], reset 0xFF). A
      // marginal lane SW-masks here exactly as it is dropped from the gather, so
      // a masked lane that never fills its FIFO no longer wedges the word path.
      .lane_mask     (io_link_rx_rx_lane_mask),
      // fix2: training_mode_i is interface-compat / UNUSED by the deskew (the
      // anchor is content-only). effective_training_mode_rx is still wired for
      // interface stability, but the deskew does NOT gate capture on it.
      .training_mode_i (effective_training_mode_rx),
      .out_clk         (gpiorx_0_io_link_clk),
      // STICKY-POISON re-arm (2026-06-23): the APB W1-pulse SWI_SYNC_OBS_CLR (SoC
      // 0x44032100[5]) edge-detected into the RX link clock below
      // (sync_obs_clr_pulse, gpiorx_0_io_link_clk = the deskew out_clk). Pulsing
      // it AFTER force_always SYNC is flowing re-arms each lane's sticky
      // sync_seen_l + the read-side reanchored latch so the re-anchor re-measures
      // on the CLEAN data-mode SYNC indices instead of a pre-SYNC poison word
      // grabbed out of POR. Held 0 by SW => bit-identical first-arrival capture.
      .sync_obs_clr_i  (sync_obs_clr_pulse),
      .out_data        (deskew_aligned_data),
      .out_valid       (deskew_out_valid_w),
      .epoch_anchored_o(epoch_anchored_w),
      .epoch_span_o    (epoch_span_w),
      // STICKY-POISON obs (2026-06-23): per-lane out_clk-synced sync_seen vector
      // (SoC 0x44032140 bits[14:7] when surfaced through the chiplet controller)
      // so silicon can tell 'no lane latched' (0x00) from 'latched inconsistent
      // indices' (set but never coherent) from 'latched + coherent'.
      .sync_seen_vec_o (deskew_sync_seen_vec_w),
      // DATA-MODE per-lane SYNC Hamming-distance obs (2026-06-25, winscan metric)
      .sync_dist_vec_o (deskew_sync_dist_vec_w)
  );
  // Epoch-anchor engagement observables exported to the PHY status APB regfile
  // (tidelink_gpio_phy_apb_regs SWI_EPOCH_STATUS @ +0x40). out_clk of the deskew
  // is gpiorx_0_io_link_clk = the link_rx_clk domain the regfile syncs from.
  assign io_epoch_anchored = epoch_anchored_w;
  assign io_epoch_span     = epoch_span_w;
  // STICKY-POISON per-lane sync_seen vector -> APB (SoC 0x4403_215C). Explicit
  // assign to a forward-declared net (NOT an inline wire= on the instance port)
  // so no implicit-net shadow can silently drop the connection — the exact trap
  // that killed the SW-clear routing. gpiorx_0_io_link_clk domain; CDC'd to
  // apb_clk in axi_chiplet_controller.
  assign io_sync_seen_vec  = deskew_sync_seen_vec_w;
  // DATA-MODE per-lane SYNC Hamming-distance vector -> APB (SoC 0x4403_21AC,
  // lane-selected). Explicit assign to a forward-declared net (NOT an inline
  // wire= on the instance port) so no implicit-net shadow can silently drop the
  // connection. gpiorx_0_io_link_clk domain; CDC'd to apb_clk in
  // axi_chiplet_controller.
  assign io_sync_dist_vec  = deskew_sync_dist_vec_w;
  // ---------------------------------------------------------------------------
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 1/2/3).
  // Taps the SAME post-deskew aligned 128-bit word (deskew_aligned_data) the
  // framer reads, in the gpiorx_0_io_link_clk (out_clk of the deskew) domain —
  // exactly the bus WlinkRxLinkLayer's full-128 sync_detected compares. The
  // mask-aware AND-over-masked-in-lanes detector fires even if a marginal lane
  // drops its SYNC slice (see tidelink_phy_sync_detect.sv header). Read-only:
  //   * sync_en_i = 1'b1  -> ALWAYS live (pure observability; never gated). It
  //     only READS deskew_aligned_data, so it cannot perturb the datapath, and
  //     it is identically present in V1 / default-V2 (the counters just stay
  //     quiescent until a real SYNC arrives — there is none unless the peer's
  //     TX SYNC-insert is enabled). This is a strict read-side add: no existing
  //     net is rewired, so default-V2 / V1 are BIT-IDENTICAL.
  //   * data_valid_i = deskew_out_valid_w -> qualify on the deskew's own
  //     aligned-data-flowing strobe so a bubble/idle beat is not counted.
  //   * lane_mask_i = io_sync_lane_mask_in -> SW LANE_MASK strap (PART 3).
  // sync_seen_lane is latched into an 8-bit STICKY "ever-matched" vector
  // (cleared only on POR) — the KEY per-lane diagnostic. The 16-bit saturating
  // count and the live 1-cycle pulse (PART 2 robust re-hunt source) are
  // exported too. sync_miss_* are observability-only here and left unconnected.
  // ---------------------------------------------------------------------------
  wire        sync_det_seen_w;
  wire [7:0]  sync_det_seen_lane_w;
  wire [15:0] sync_det_seen_cnt_w;
  /* verilator lint_off UNUSED */
  wire        sync_det_miss_w;       // observability only (not surfaced)
  wire [15:0] sync_det_miss_cnt_w;   // observability only (not surfaced)
  /* verilator lint_on UNUSED */
  tidelink_phy_sync_detect u_rx_sync_detect (
    .clk              (gpiorx_0_io_link_clk),
    .rst_n            (~io_por_reset),
    .sync_en_i        (1'b1),                 // pure observability — always live
    .lane_mask_i      (io_sync_lane_mask_in), // PART 3 SW LANE_MASK strap
    .sync_tol_i       (io_sync_tol_in),       // 2026-06-17 Hamming tolerance (0=exact)
    .data_i           (deskew_aligned_data),  // post-deskew word (framer's bus)
    .data_valid_i     (deskew_out_valid_w),   // deskew aligned-data strobe
    .sync_seen_o      (sync_det_seen_w),
    .sync_seen_lane_o (sync_det_seen_lane_w),
    .sync_miss_o      (sync_det_miss_w),
    .sync_seen_cnt_o  (sync_det_seen_cnt_w),
    .sync_miss_cnt_o  (sync_det_miss_cnt_w)
  );
  // ---------------------------------------------------------------------------
  // SoC Labs CLEARABLE per-lane SYNC-match SWEEP ORACLE (2026-06-16, perlane-wp).
  //
  // The sticky vector below is POR-only and so reflects "ever matched" — useless
  // for a per-window sweep where the operator needs CURRENT state. We add an APB
  // W1-pulse clear (io_sync_obs_clr_in, SoC 0x44032100[5]) that, on its rising
  // edge in the RX link-clock domain, resets the per-lane LIVE-match vector AND
  // the sticky vector AND the rawobs best-match latch. The clear is brought into
  // the RX link clock with a 2-flop synchroniser (apb_clk -> link_rx_clk) and
  // edge-detected to a single-cycle pulse so a held APB bit clears exactly once.
  //
  // The LIVE vector (io_sync_lane_live) is the oracle: lane[L]=1 iff lane L's
  // post-deskew slice has matched its SYNC slice at least once SINCE THE LAST
  // CLEAR. Operator loop: write clr=1 (W1-pulse) -> wait a few SYNC periods ->
  // read 0x2144 -> exactly the lanes that currently carry their SYNC slice. The
  // per-lane RAW slice compare (sync_det_lane_match_w) is the same pure-data
  // property the detector computes; using it (not the masked sync_seen_lane)
  // makes the oracle independent of the SW LANE_MASK so a masked lane still
  // shows its true match state during the sweep.
  //
  // DEFAULT (io_sync_obs_clr_in held 0): the clear pulse never fires, so the
  // sticky vector behaves EXACTLY as before (POR-only clear) and the rawobs
  // latch is untouched — the added clear is OR'd into the existing POR resets,
  // so default-V2 / V1 are BIT-IDENTICAL.
  // ---------------------------------------------------------------------------
  reg  sync_clr_meta_q, sync_clr_sync_q, sync_clr_d_q;
  always @(posedge gpiorx_0_io_link_clk or posedge io_por_reset) begin
    if (io_por_reset) begin
      sync_clr_meta_q <= 1'b0;
      sync_clr_sync_q <= 1'b0;
      sync_clr_d_q    <= 1'b0;
    end else begin
      sync_clr_meta_q <= io_sync_obs_clr_in;
      sync_clr_sync_q <= sync_clr_meta_q;
      sync_clr_d_q    <= sync_clr_sync_q;
    end
  end
  // Rising-edge of the synchronised clear -> one-cycle clear pulse. (Net declared
  // forward, before the deskew instance, so the .sync_obs_clr_i port binds it.)
  assign sync_obs_clr_pulse = sync_clr_sync_q & ~sync_clr_d_q;

  // Per-lane RAW slice-match (pure data property, mask-independent) recomputed
  // here for the live oracle. Mirrors the detector's lane_match exactly. The
  // SYNC constant is the shared header (guarded include — no-op if an earlier
  // file already declared it at $unit scope; the same include is repeated for
  // the rawobs block below).
`include "tidelink_sync_word.svh"
  localparam [127:0] SYNC_WORD_LIVE = TIDELINK_SYNC_WORD;
  // 2026-06-17: the live oracle uses the SAME Hamming tolerance as the detector
  // (io_sync_tol_in) so 0x2144 tracks what the re-anchor actually matches. At
  // tol=0 popcount(xor)<=0 iff xor==0, so this is bit-identical to the prior ==.
  function automatic [4:0] sync_live_popcount16(input [15:0] xv);
    reg [1:0] la [0:7];
    reg [2:0] lb [0:3];
    reg [3:0] lc [0:1];
    integer ii;
    begin
      for (ii = 0; ii < 8; ii = ii + 1)
        la[ii] = {1'b0, xv[2*ii]} + {1'b0, xv[2*ii + 1]};
      for (ii = 0; ii < 4; ii = ii + 1)
        lb[ii] = {1'b0, la[2*ii]} + {1'b0, la[2*ii + 1]};
      for (ii = 0; ii < 2; ii = ii + 1)
        lc[ii] = {1'b0, lb[2*ii]} + {1'b0, lb[2*ii + 1]};
      sync_live_popcount16 = {1'b0, lc[0]} + {1'b0, lc[1]};
    end
  endfunction
  wire [4:0] sync_live_eff_tol = io_sync_tol_in;
  wire [7:0] sync_det_lane_match_w;
  genvar slm;
  generate
    for (slm = 0; slm < 8; slm = slm + 1) begin : g_sync_live_match
      assign sync_det_lane_match_w[slm] =
          deskew_out_valid_w &
          (sync_live_popcount16(deskew_aligned_data[16*slm +: 16]
                                ^ SYNC_WORD_LIVE[16*slm +: 16]) <= sync_live_eff_tol);
    end
  endgenerate

  // LIVE per-lane "matched since last clear" vector (saturating 1-bit/lane).
  reg [7:0] sync_lane_live_q;
  always @(posedge gpiorx_0_io_link_clk or posedge io_por_reset) begin
    if (io_por_reset)
      sync_lane_live_q <= 8'h00;
    else if (sync_obs_clr_pulse)
      sync_lane_live_q <= 8'h00;
    else
      sync_lane_live_q <= sync_lane_live_q | sync_det_lane_match_w;
  end
  assign io_sync_lane_live = sync_lane_live_q;

  // STICKY per-lane "ever-matched" vector — latch each lane's match, clear on
  // POR or on the new clear pulse. This is the load-bearing diagnostic: it
  // survives a transient and shows precisely which lanes ever delivered their
  // SYNC slice on silicon. The added clear term is inert when clr is held 0.
  reg [7:0] sync_seen_lane_sticky_q;
  always @(posedge gpiorx_0_io_link_clk or posedge io_por_reset) begin
    if (io_por_reset)
      sync_seen_lane_sticky_q <= 8'h00;
    else if (sync_obs_clr_pulse)
      sync_seen_lane_sticky_q <= 8'h00;
    else
      sync_seen_lane_sticky_q <= sync_seen_lane_sticky_q | sync_det_seen_lane_w;
  end
  assign io_sync_seen_cnt         = sync_det_seen_cnt_w;
  assign io_sync_seen_lane_sticky = sync_seen_lane_sticky_q;
  assign io_sync_seen_pulse       = sync_det_seen_w;
  // ---------------------------------------------------------------------------
  // SoC Labs RX RAW-WORD + PERMUTATION observability (2026-06-15, rawobs).
  //
  // WHY: on silicon the mask-aware detector above reads sync_seen_lane_sticky
  // == 0x00 (NO lane matches its FIXED-position SYNC slice) even though the TX
  // is confirmed inserting SYNC (0x2120 TX count saturates) and DATA crosses.
  // That means the reassembled post-deskew word is content-transformed for SYNC
  // specifically (lane permutation, or per-lane bit-rotation), which the uniform
  // training pattern + byte-counter framer tolerate. To decode WHAT transform,
  // we need (A) the raw bits actually seen and (B) which TX slice each RX lane
  // carries.
  //
  // Both are PURE READ-SIDE on deskew_aligned_data (the SAME bus the framer and
  // detector read). No existing net is rewired and nothing is gated on these,
  // so default-V2 / V1 are BIT-IDENTICAL. Domain: gpiorx_0_io_link_clk (the
  // deskew out_clk = RX link-clock), CDC'd to apb_clk in the chiplet controller.
  // SYNC_WORD comes from the shared header (guarded include — no-op if an
  // earlier file already declared it at $unit scope).
  // ---------------------------------------------------------------------------
`include "tidelink_sync_word.svh"
  localparam [127:0] DBG_SYNC_WORD = TIDELINK_SYNC_WORD;

  // (A) per-RX-lane FIXED-position match (lane i vs SYNC slice i) — identical
  // compare to the detector's lane_match, recomputed here for the popcount
  // trigger + the captured match vector. Pure combinational read.
  wire [7:0] dbg_lane_any_match_w;
  genvar dgl;
  generate
    for (dgl = 0; dgl < 8; dgl = dgl + 1) begin : g_dbg_any
      assign dbg_lane_any_match_w[dgl] =
          (deskew_aligned_data[16*dgl +: 16] == DBG_SYNC_WORD[16*dgl +: 16]);
    end
  endgenerate
  // popcount of fixed-position matches (0..8) for the best-match trigger.
  wire [3:0] dbg_popcount_w =
      {3'b0, dbg_lane_any_match_w[0]} + {3'b0, dbg_lane_any_match_w[1]} +
      {3'b0, dbg_lane_any_match_w[2]} + {3'b0, dbg_lane_any_match_w[3]} +
      {3'b0, dbg_lane_any_match_w[4]} + {3'b0, dbg_lane_any_match_w[5]} +
      {3'b0, dbg_lane_any_match_w[6]} + {3'b0, dbg_lane_any_match_w[7]};

  // (B) per-RX-lane slice-index finder: for RX lane i, which TX slice j (0..7)
  // does its 16-bit content equal? 0xF if none. Pure combinational read. This
  // DIRECTLY decodes identity (i->i) vs permutation (i->perm(i)) vs garbage
  // (0xF = bit-rotation / no clean slice match).
  wire [3:0] dbg_slice_idx_w [0:7];
  genvar di, dj;
  generate
    for (di = 0; di < 8; di = di + 1) begin : g_dbg_slice_rx
      // hit[j] for this RX lane against each TX slice j
      wire [7:0] dbg_hit;
      for (dj = 0; dj < 8; dj = dj + 1) begin : g_dbg_slice_tx
        assign dbg_hit[dj] =
            (deskew_aligned_data[16*di +: 16] == DBG_SYNC_WORD[16*dj +: 16]);
      end
      // priority-encode the lowest matching slice index; 0xF if no hit. (TX
      // slices are all-distinct so at most one bit of dbg_hit is set per lane.)
      assign dbg_slice_idx_w[di] =
          dbg_hit[0] ? 4'd0 : dbg_hit[1] ? 4'd1 : dbg_hit[2] ? 4'd2 :
          dbg_hit[3] ? 4'd3 : dbg_hit[4] ? 4'd4 : dbg_hit[5] ? 4'd5 :
          dbg_hit[6] ? 4'd6 : dbg_hit[7] ? 4'd7 : 4'hF;
    end
  endgenerate
  wire [31:0] dbg_slice_idx_packed_w =
      {dbg_slice_idx_w[7], dbg_slice_idx_w[6], dbg_slice_idx_w[5],
       dbg_slice_idx_w[4], dbg_slice_idx_w[3], dbg_slice_idx_w[2],
       dbg_slice_idx_w[1], dbg_slice_idx_w[0]};

  // BEST-MATCH-triggered sticky latches (cleared on POR, or on the perlane-wp
  // clear pulse so each sweep step re-captures from the POR sentinel). Latch the
  // full raw word + its match vector + the slice-index map on the cycle whose
  // fixed-position popcount is STRICTLY GREATER than any seen so far — i.e. the
  // closest-to-SYNC word the RX physically reassembled. A valid-word qualifier
  // (deskew_out_valid_w) avoids latching bubble/idle beats. The first valid beat
  // (best=0, popcount>=0) loads an initial snapshot so the regs are never X. The
  // clear term is inert when io_sync_obs_clr_in is held 0 (bit-identical).
  reg [127:0] dbg_raw_word_q;
  reg [7:0]   dbg_lane_any_match_q;
  reg [3:0]   dbg_best_popcount_q;
  reg [31:0]  dbg_slice_idx_q;
  reg         dbg_seeded_q;
  wire        dbg_capture = deskew_out_valid_w &
                            (~dbg_seeded_q | (dbg_popcount_w > dbg_best_popcount_q));
  always @(posedge gpiorx_0_io_link_clk or posedge io_por_reset) begin
    if (io_por_reset) begin
      dbg_raw_word_q       <= 128'h0;
      dbg_lane_any_match_q <= 8'h0;
      dbg_best_popcount_q  <= 4'h0;
      dbg_slice_idx_q      <= 32'hFFFF_FFFF; // 0xF per lane = no match seen yet
      dbg_seeded_q         <= 1'b0;
    end else if (sync_obs_clr_pulse) begin
      dbg_raw_word_q       <= 128'h0;
      dbg_lane_any_match_q <= 8'h0;
      dbg_best_popcount_q  <= 4'h0;
      dbg_slice_idx_q      <= 32'hFFFF_FFFF; // re-arm: 0xF per lane = no match
      dbg_seeded_q         <= 1'b0;
    end else if (dbg_capture) begin
      dbg_raw_word_q       <= deskew_aligned_data;
      dbg_lane_any_match_q <= dbg_lane_any_match_w;
      dbg_best_popcount_q  <= dbg_popcount_w;
      dbg_slice_idx_q      <= dbg_slice_idx_packed_w;
      dbg_seeded_q         <= 1'b1;
    end
  end
  assign io_dbg_raw_word       = dbg_raw_word_q;
  assign io_dbg_lane_any_match = dbg_lane_any_match_q;
  assign io_dbg_best_popcount  = dbg_best_popcount_q;
  assign io_dbg_slice_idx      = dbg_slice_idx_q;

  // ---------------------------------------------------------------------------
  // R-A FINALIZE ANCHOR-VERIFY (2026-07-04, LOCAL OVERRIDE — see file header).
  //
  // anchor_vfy_lane_w reuses the rawobs EXACT fixed-position per-lane compares
  // (dbg_lane_any_match_w: deskew_aligned_data slice L == SYNC slice L, zero
  // tolerance). Its own named net so the sim gate can Force() it without
  // touching the dbg best-match capture (cocotb t33e models a wrong-slot
  // lane by forcing this vector low).
  //
  // anchor_vfy_word_w = the beat-simultaneous cross-lane acceptance: EVERY
  // active lane (io_link_rx_rx_lane_mask, the same mask the deskew/framer
  // use — masked lanes are don't-care via | ~mask, the standard idiom) exact
  // on ONE valid post-deskew beat. A wrong-slot-anchored lane presents its
  // slice one beat off the others, so this can never fire on a mis-anchored
  // link; a correct anchor fires it on every clean beacon beat.
  //
  // The sticky sets only while the deskew re-anchor is ENGAGED
  // (epoch_anchored_w = the read-side `reanchored` latch): the verify's
  // meaning is "the LATCHED anchor produces exact beacons", and pre-anchor
  // coincidences (skew-0 luck) must not pre-satisfy the winscan gate. Clear:
  // POR, or the F3 sync_obs_clr_pulse (the SAME edge that clears the deskew's
  // sync_seen/sync_idx and drops `reanchored`), so every winscan clear-retry
  // starts a fresh verify. Clear WINS over a same-edge set (deskew idiom).
  // ---------------------------------------------------------------------------
  // FIX-2 (2026-07-08, TOLERANT ANCHOR-VERIFY, tol-3, wrong-slot-safe): the
  // anchor COMMIT is tol-5 (per-lane sync_dist <= SYNC_REANCHOR_TOL=5 in the
  // deskew) but the anchor VERIFY was tol-0 EXACT (dbg_lane_any_match_w, ==).
  // On die_a's marginal eye a CORRECTLY-aligned lane lands at Hamming 1-5 from
  // its SYNC slice: it COMMITS (tol-5) but can never exact-VERIFY -> ws_verify_q
  // stuck at 0 forever (the iter-1 die_a verify_stuck; die_b's cleaner eye
  // verifies exact = 92%). Fix: verify with a Hamming tolerance of 3.
  //   WHY 3 (not 5): the 8 SYNC slices of TIDELINK_SYNC_WORD form a code whose
  //   MINIMUM pairwise inter-slice Hamming distance is 4, so tol-3 (< 4)
  //   PROVABLY rejects any wrong slot — a mis-aligned lane reads a whole
  //   different slice at dist >= 4 > 3 — while accepting a correctly-aligned
  //   marginal-eye lane at dist <= 3.
  //   The cross-lane simultaneity requirement is KEPT (anchor_vfy_word_w is the
  //   &-over-active-lanes on ONE valid post-deskew beat), so a TEMPORALLY
  //   mis-aligned lane still fails: one beat off it reads a whole wrong word,
  //   dist >> 3, and the simultaneous all-lane match can never fire.
  //   This is the SAME Hamming compare (sync_live_popcount16 of the per-lane
  //   XOR) the live sync detector uses above (the deskew's tidelink_popcount16
  //   is a MODULE, not callable in an expression, so this in-module function is
  //   used — bit-identical popcount). The rawobs debug capture keeps its EXACT
  //   compare (dbg_lane_any_match_w, untouched above) so the on-silicon
  //   permutation/slice-index diagnostics stay zero-tolerance; ONLY the
  //   anchor-verify uses this tolerant vector. anchor_vfy_lane_w remains a
  //   named 8-bit net the sim gate can Force() (t33e wrong-slot injection).
  localparam [4:0] VERIFY_TOL = 5'd3;
  wire [7:0] anchor_vfy_lane_w;
  genvar avl;
  generate
    for (avl = 0; avl < 8; avl = avl + 1) begin : g_anchor_vfy
      assign anchor_vfy_lane_w[avl] =
          (sync_live_popcount16(deskew_aligned_data[16*avl +: 16]
                                ^ DBG_SYNC_WORD[16*avl +: 16]) <= VERIFY_TOL);
    end
  endgenerate
  wire anchor_vfy_word_w = deskew_out_valid_w &
                           (&(anchor_vfy_lane_w | ~io_link_rx_rx_lane_mask));
  reg anchor_verified_q;
  always @(posedge gpiorx_0_io_link_clk or posedge io_por_reset) begin
    if (io_por_reset)
      anchor_verified_q <= 1'b0;
    else if (sync_obs_clr_pulse)
      anchor_verified_q <= 1'b0;
    else if (epoch_anchored_w & anchor_vfy_word_w)
      anchor_verified_q <= 1'b1;
  end
  assign io_anchor_verified = anchor_verified_q;
  wire [63:0] io_link_rx_rx_link_data_lo = deskew_aligned_data[63:0];
  wire [63:0] io_link_rx_rx_link_data_hi = deskew_aligned_data[127:64];
  reg  out_prepend_swi_polarity; // @[SW.scala 83:22]
  // SoC Labs alignment patch (2026-05-05): per-PHY 4-bit deserialiser phase
  // offset, exposed at PHY Control register bits[20:17]. Default 0 matches
  // the original RTL behaviour. SW writes 0..15 to find the alignment that
  // makes slave_count_rx + phase == master_count_tx (mod 16).
  reg [3:0] swi_phase_offset;
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
  wire  out_wivalid_0 = in_valid & auto_in_penable & ~in_bits_read; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid = out_wivalid_0 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_1 = &out_frontMask[15:8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_1 = out_wivalid_0 & out_wimask_1; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_2 = &out_frontMask[16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_2 = out_wivalid_0 & out_wimask_2; // @[RegisterNodes.scala 229:24]
  // SoC Labs: bits[20:17] write enable for swi_phase_offset
  wire  out_f_wivalid_phase = out_wivalid_0 & in_bits_mask[2];
  wire [20:0] out_prepend_1 = {swi_phase_offset,out_prepend_swi_polarity,out_prepend_swi_post_count,swi_pream_count_1}; // @[Cat.scala 30:58]
  wire  _T = auto_in_penable & in_valid; // @[Decoupled.scala 40:37]
  wire  _GEN_3 = _T | taken; // @[RegisterNodes.scala 233:23 RegisterNodes.scala 233:31 RegisterNodes.scala 232:24]
  // ---------------------------------------------------------------------------
  // SoC Labs bit-slip + training-pattern controls (2026-05-13, BRINGUP_REPORT §9)
  //
  // These are sim-only soft-strap registers: cocotb drives them via
  // hierarchical reference (no APB plumbing). Default values produce
  // bit-exact existing behaviour (slip=0, training_mode=0).
  //
  // swi_bit_slip is packed as 8 lanes x 3 bits — lane N occupies bits
  // [3*N+2 : 3*N]. Each lane's WavD2DGpioRx applies a right-rotation by its
  // 3-bit slip on the 16-bit deserialised word.
  //
  // swi_training_mode forces each WavD2DGpioTx serialiser to emit the byte
  // (N+1)*8'h11 for lane N (i.e. 0x11, 0x22, ..., 0x88), repeated within
  // the 16-bit serialiser word.
  // ---------------------------------------------------------------------------
  // Training patterns: each byte has rotational period 8 within itself (i.e.
  // no rotation in [1..7] maps the byte to itself). That makes the 16-bit
  // word {P,P} unambiguously detectable under right-rotation by 0..7 bits.
  // The spec's (N+1)*8'h11 patterns were period-4 and produced aliased lock
  // at slip values that differed by 4; we deviate to ensure correctness.
  // Lane N pattern: PAT[N], picked manually to be distinct + period-8.
  //   lane 0 -> 0xA3, lane 1 -> 0xB5, lane 2 -> 0xC9, lane 3 -> 0xD3,
  //   lane 4 -> 0x65, lane 5 -> 0x4B, lane 6 -> 0x59, lane 7 -> 0x2D.
  reg [23:0] swi_bit_slip       = 24'h0;
  reg        swi_training_mode  = 1'b0;
  // OR-mux: prefer APB-driven inputs when non-zero, fall back to sim-only
  // soft-strap regs for legacy cocotb hierarchical-force tests. In
  // production, the soft-strap regs stay at 0 and the inputs drive.
  wire [23:0] effective_bit_slip       = io_swi_bit_slip_in       | swi_bit_slip;
  // ---------------------------------------------------------------------------
  // SoC Labs Bug-FC1 fix (2026-05-25): post-training hold extension.
  //
  // ROOT CAUSE: WavD2DGpioTx.v lines 43-45 implement a 2-input combinatorial
  // mux that REPLACES io_link_data with the training pattern when
  // io_training_mode=1. There is no idle pattern injection and no buffering.
  // When SW drops swi_training_mode 1->0, the serialiser switches in ONE
  // cycle from training byte to whatever happens to be on io_link_data --
  // typically a stale word from before the FCSM has had time to push the
  // first cr_pkt. The slave RX correlator, which is locked on the training
  // byte, sees a hard discontinuity and loses byte alignment. FCSMs then
  // park at SEND_CREDITS1 because the very first cr_pkts are corrupted and
  // never observed by the peer.
  //
  // CONFIRMED by:
  //  - cocotb/wav_d2d_gpio_tx/test_wav_tx_training_mux  (unit-level mux)
  //  - cocotb/wlink_pair/test_tx_gated_by_training      (paired-Wlink sim)
  //
  // FIX (Option B): extend the effective training_mode for
  // POST_TRAIN_HOLD_CYCLES link-word cycles past the falling edge of the
  // input training_mode. During those N cycles, the FCSM (which is gated
  // by swi_enable and runs INDEPENDENTLY of training_mode) starts emitting
  // cr_pkts; once the hold expires the per-lane mux switches from training
  // pattern to live FC data with no stale-gap. The slave RX correlator
  // therefore stays locked on the training byte right up to the moment
  // valid cr_pkt bytes appear.
  //
  // PARAMETER: POST_TRAIN_HOLD_CYCLES is measured in
  // io_link_tx_tx_link_clk cycles (= one link parallel-word time). Default
  // 64 was sized to leave plenty of headroom for the FCSM to push the
  // first few cr_pkts (FCSM cycle ~= 1-2 link-word cycles per state).
  // Tune downward if a shorter hold is sufficient on silicon.
  //
  // Clock domain note: io_swi_training_mode_in / swi_training_mode are
  // both APB-domain (clock/reset). The latch trigger is sampled here on
  // the link-clock domain WITHOUT a synchroniser -- this is acceptable
  // because the existing effective_training_mode signal is already used
  // unsynchronised in exactly this way as input to the per-lane
  // WavD2DGpioTx.io_training_mode pin. We do not make the CDC posture
  // worse than the original RTL.
  // ---------------------------------------------------------------------------
  // VARIANT 2 (2026-05-25): TX/RX decouple.
  //
  // The lane_checker (observer-only, lives outside WavD2DGpio) was
  // hypothesised to benefit from a held training_mode so it stays locked
  // for N cycles after SW drops the training input. The TX-side per-lane
  // mux (WavD2DGpioTx.v:43-45) should drop IMMEDIATELY so FC bytes flow.
  //
  // This split provides:
  //   effective_training_mode_tx  = input_training_mode_w
  //                                 (no hold; per-lane mux opens immediately)
  //   effective_training_mode_rx  = input_training_mode_w | hold_ctr!=0
  //                                 (kept for documentation parity; this
  //                                 module has no RX consumer — the
  //                                 lane_checker reads its own copy of
  //                                 swi_training_mode upstream)
  //
  // The serialiser io_clk_en for each lane stays driven by the HELD
  // signal so the per-lane PLL/serialiser remains clocked through the
  // transition window (avoiding a clock glitch during the mux change).
  parameter POST_TRAIN_HOLD_CYCLES = 7'd64;
  wire        input_training_mode_w   = io_swi_training_mode_in  | swi_training_mode;
  reg  [6:0]  post_train_hold_ctr_r;
  always @(posedge io_link_tx_tx_link_clk or posedge por_reset_scan_wrs_io_reset_out) begin
    if (por_reset_scan_wrs_io_reset_out) begin
      post_train_hold_ctr_r <= 7'd0;
    end else if (input_training_mode_w) begin
      // While training input is asserted, hold the counter at its max so
      // the falling edge drops cleanly into a full count-down.
      post_train_hold_ctr_r <= POST_TRAIN_HOLD_CYCLES;
    end else if (post_train_hold_ctr_r != 7'd0) begin
      // Training input has dropped: count down link-word cycles. When the
      // counter reaches 0 the effective signal goes low and the per-lane
      // mux switches to live FC data.
      post_train_hold_ctr_r <= post_train_hold_ctr_r - 1'b1;
    end
  end
  // VARIANT 2: TX/RX decouple. TX = no hold (immediate drop); RX = held
  // (for any external observer-only consumer). For backwards compat,
  // effective_training_mode is aliased to the RX-side (held) signal —
  // explicit per-instance wiring below uses the _tx variant for the per-
  // lane mux and keeps the held signal for io_clk_en.
  // Driver for the forward-declared net above (declared near the TX segmenter
  // so the SYNC inserter instance can consume it without spawning an implicit
  // shadow wire). Continuous-assign form because the `wire ... =` declaration
  // now lives at the forward-declaration site.
  assign      effective_training_mode_tx_raw = input_training_mode_w;
  // effective_training_mode_rx is forward-declared at the deskew instance
  // (its driver here is needed before that point).
  assign      effective_training_mode_rx =
                input_training_mode_w | (post_train_hold_ctr_r != 7'd0);
  wire        effective_training_mode    = effective_training_mode_rx;

  // ---------------------------------------------------------------------------
  // SoC Labs WORD-ALIGNED training-mux transition (tdif-02 -> tdif-03)
  //
  // ROOT CAUSE (HW ILA-confirmed):
  //   The per-lane mux at WavD2DGpioTx.v:43-45 selects between training_pattern
  //   and io_link_data combinatorially. WavD2DGpioTx serialises bit-by-bit
  //   using its internal `count` register (mod 16 on the fast pad clock).
  //   When SW drops swi_training_mode in the MIDDLE of a 16-bit word (i.e.
  //   count not aligned to 0), the mux switches mid-word producing a
  //   hybrid 16-bit pattern that's neither a valid training byte nor a
  //   valid ECC long-packet header. Slave's LL_RX byte-alignment FSM
  //   (`llrx/state`) is correlating on the training byte and never sees a
  //   clean SOP after the transition, so it permanently sticks at iSTATE.
  //
  // tdif-02 (PREVIOUS, wrapper-level, partial fix):
  //   A wrapper-level mirror counter (mux_align_count_r below) mirrored
  //   gpiotx_N.count and latched effective_training_mode_tx_raw at its
  //   wrap-edge. All eight gpiotx_N.io_training_mode pins were driven from
  //   the wrapper-latched signal. On HW Build #21 this only got slave RX
  //   active; master RX stayed blind — suspected because per-lane `count`
  //   registers were NOT exactly in lock-step with the wrapper-level mirror
  //   counter (different reset arrival / hsclk skew).
  //
  // tdif-03 (CURRENT): per-lane latching INSIDE WavD2DGpioTx
  //   The latching has been MOVED INTO a local override at
  //   src/rtl/local_overrides/WavD2DGpioTx.v. Each lane samples
  //   io_training_mode using ITS OWN `count` register (count==4'hf) — so the
  //   mux flip is guaranteed to land at the per-lane word boundary regardless
  //   of cross-lane phase. The wrapper now feeds the RAW (combinatorial)
  //   effective_training_mode_tx_raw signal to each gpiotx_N.io_training_mode
  //   pin — the per-lane override does the rest.
  //
  // The wrapper-level mux_align_count_r / effective_training_mode_tx_q regs
  // below are RETAINED as inert placeholders so synth keeps consistent naming
  // for ILA debugging if needed, but they have NO functional effect on the
  // per-lane mux: effective_training_mode_tx is now aliased to the raw
  // (combinatorial) signal.
  // ---------------------------------------------------------------------------
  reg  [3:0]  mux_align_count_r;
  reg         effective_training_mode_tx_q;
  always @(posedge hsclk_scan_mux_io_o_z or posedge por_reset_scan_wrs_io_reset_out) begin
    if (por_reset_scan_wrs_io_reset_out) begin
      mux_align_count_r            <= 4'hf;
      effective_training_mode_tx_q <= 1'b0;
    end else begin
      mux_align_count_r <= mux_align_count_r + 4'h1;
      // Inert in tdif-03 — kept for ILA continuity. Per-lane latching is
      // now done inside WavD2DGpioTx using each lane's own `count`.
      if (mux_align_count_r == 4'hf) begin
        effective_training_mode_tx_q <= effective_training_mode_tx_raw;
      end
    end
  end
  // tdif-03: per-lane gpiotx_N.io_training_mode pins are driven by the RAW
  // (combinatorial) signal. The per-lane WavD2DGpioTx local override
  // (WORD_ALIGN_MUX=1 by default) latches io_training_mode using its own
  // internal `count` register so the mux flip happens at THAT lane's word
  // boundary, independent of any cross-lane phase variation.
  wire        effective_training_mode_tx = effective_training_mode_tx_raw;
  // SoC Labs §9.7 per-lane phase + §9.11d hardening (2026-05-27):
  // ------------------------------------------------------------------
  // §9.7 original intent: per-lane phase (io_swi_phase_offset_in,
  // driven by chiplet_controller from cal_phase_offset_w OR'd with
  // Region 8 swi_phase_offset_r) AND the broadcast global APB
  // swi_phase_offset reg (PHY-CTRL[20:17], legacy single-phase path).
  //
  // §9.11d Agent 3 finding (independent assessment, 2026-05-27): the
  // unconditional bitwise OR between per-lane and global was a latent
  // hazard. Example: calibrator picks lane-5 phase = 0x3 = 0011, SW
  // had previously written global = 0x5 = 0101 to the legacy PHY-CTRL
  // reg → effective lane-5 phase = 0011 | 0101 = 0111 = 0x7. The PHY
  // samples at the WRONG sub-bit point, the byte aligns by training-
  // pattern still passes (16-bit equality is too lax for this), but
  // real-data CRC fails — exactly the OVERNIGHT_2026_05_27 "training
  // criterion vs real-data eye" signature.
  //
  // Verified by APB probe on the §9.11 deployed bitstream: global
  // swi_phase_offset reads 0x0 on both M and S, so the OR was benign
  // for that specific deploy. But ANY future SW write to PHY-CTRL
  // [20:17] would re-introduce the corruption.
  //
  // Fix: AND-CLAMP semantics. If ANY per-lane nibble is non-zero
  // (meaning per-lane control is in play — calibrator and/or
  // Region 8 SW override is driving), the global broadcast is
  // SUPPRESSED for ALL lanes. Only when per-lane is uniformly zero
  // does the legacy global broadcast through. Preserves legacy
  // global behaviour for purely-global-driven flows; defeats the
  // OR-corruption when per-lane is active.
  //
  // Edge case: if the calibrator deterministically chooses
  // (0,0,0,0,0,0,0,0) for every lane AND a non-zero global has been
  // written, the global STILL broadcasts. Document and accept — in
  // normal operation global is 0 and this never fires.
  //
  // Default io_swi_phase_offset_in=0 + swi_phase_offset=0 → bit-exact
  // original behaviour (all lanes phase 0). Mirrors effective_bit_slip.
  wire        any_per_lane_phase_set = |io_swi_phase_offset_in;
  wire [3:0]  effective_global_phase =
                  any_per_lane_phase_set ? 4'h0 : swi_phase_offset;
  wire [31:0] effective_phase_offset;
  genvar gl;
  generate
    for (gl = 0; gl < 8; gl = gl + 1) begin : g_phase_lane
      // Per-lane wins when set; global is the legacy broadcast
      // fallback (suppressed by AND-clamp above when any per-lane
      // nibble is non-zero, preventing the bitwise-OR corruption).
      assign effective_phase_offset[4*gl +: 4] =
               io_swi_phase_offset_in[4*gl +: 4] | effective_global_phase;
    end
  endgenerate
  // SoC Labs tidelink-gpio-phy integration (2026-05-28): per-lane training
  // patterns set to alternating P / ~P with P = 0x12EB per
  // deps/tidelink-gpio-phy/docs/IMPLEMENTATION.md §2.3-2.4 and
  // IMPLEMENTATION.md §6.
  // USE_PRBS_TRAINING(0) + USE_TAG_PAIR(1) makes each TX emit the constant
  // 16-bit word {HI, LO}; the new tidelink_lane_checker (from the submodule)
  // matches against PATTERN_W[i] directly.
  //   lane 0,2,4,6:  HI=0x12, LO=0xEB → 0x12EB ( P)
  //   lane 1,3,5,7:  HI=0xED, LO=0x14 → 0xED14 (~P)
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'h12)) gpiotx_0 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_0_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_0_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_0_io_scan_clk),
    .io_scan_out(gpiotx_0_io_scan_out),
    .io_clk(gpiotx_0_io_clk),
    .io_reset(gpiotx_0_io_reset),
    .io_clk_en(gpiotx_0_io_clk_en),
    .io_link_data(gpiotx_0_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hEB),
    .io_link_clk(gpiotx_0_io_link_clk),
    .io_pad(gpiotx_0_io_pad),
    .io_pad_clk(gpiotx_0_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'hED)) gpiotx_1 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_1_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_1_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_1_io_scan_clk),
    .io_scan_out(gpiotx_1_io_scan_out),
    .io_clk(gpiotx_1_io_clk),
    .io_reset(gpiotx_1_io_reset),
    .io_clk_en(gpiotx_1_io_clk_en),
    .io_link_data(gpiotx_1_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h14),
    .io_link_clk(gpiotx_1_io_link_clk),
    .io_pad(gpiotx_1_io_pad),
    .io_pad_clk(gpiotx_1_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'h12)) gpiotx_2 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_2_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_2_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_2_io_scan_clk),
    .io_scan_out(gpiotx_2_io_scan_out),
    .io_clk(gpiotx_2_io_clk),
    .io_reset(gpiotx_2_io_reset),
    .io_clk_en(gpiotx_2_io_clk_en),
    .io_link_data(gpiotx_2_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hEB),
    .io_link_clk(gpiotx_2_io_link_clk),
    .io_pad(gpiotx_2_io_pad),
    .io_pad_clk(gpiotx_2_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'hED)) gpiotx_3 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_3_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_3_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_3_io_scan_clk),
    .io_scan_out(gpiotx_3_io_scan_out),
    .io_clk(gpiotx_3_io_clk),
    .io_reset(gpiotx_3_io_reset),
    .io_clk_en(gpiotx_3_io_clk_en),
    .io_link_data(gpiotx_3_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h14),
    .io_link_clk(gpiotx_3_io_link_clk),
    .io_pad(gpiotx_3_io_pad),
    .io_pad_clk(gpiotx_3_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'h12)) gpiotx_4 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_4_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_4_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_4_io_scan_clk),
    .io_scan_out(gpiotx_4_io_scan_out),
    .io_clk(gpiotx_4_io_clk),
    .io_reset(gpiotx_4_io_reset),
    .io_clk_en(gpiotx_4_io_clk_en),
    .io_link_data(gpiotx_4_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hEB),
    .io_link_clk(gpiotx_4_io_link_clk),
    .io_pad(gpiotx_4_io_pad),
    .io_pad_clk(gpiotx_4_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'hED)) gpiotx_5 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_5_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_5_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_5_io_scan_clk),
    .io_scan_out(gpiotx_5_io_scan_out),
    .io_clk(gpiotx_5_io_clk),
    .io_reset(gpiotx_5_io_reset),
    .io_clk_en(gpiotx_5_io_clk_en),
    .io_link_data(gpiotx_5_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h14),
    .io_link_clk(gpiotx_5_io_link_clk),
    .io_pad(gpiotx_5_io_pad),
    .io_pad_clk(gpiotx_5_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'h12)) gpiotx_6 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_6_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_6_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_6_io_scan_clk),
    .io_scan_out(gpiotx_6_io_scan_out),
    .io_clk(gpiotx_6_io_clk),
    .io_reset(gpiotx_6_io_reset),
    .io_clk_en(gpiotx_6_io_clk_en),
    .io_link_data(gpiotx_6_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hEB),
    .io_link_clk(gpiotx_6_io_link_clk),
    .io_pad(gpiotx_6_io_pad),
    .io_pad_clk(gpiotx_6_io_pad_clk)
  );
  WavD2DGpioTx #(.USE_PRBS_TRAINING(1'b0), .USE_TAG_PAIR(1'b1), .TRAINING_PATTERN_HI(8'hED)) gpiotx_7 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_7_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_7_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_7_io_scan_clk),
    .io_scan_out(gpiotx_7_io_scan_out),
    .io_clk(gpiotx_7_io_clk),
    .io_reset(gpiotx_7_io_reset),
    .io_clk_en(gpiotx_7_io_clk_en),
    .io_link_data(gpiotx_7_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h14),
    .io_link_clk(gpiotx_7_io_link_clk),
    .io_pad(gpiotx_7_io_pad),
    .io_pad_clk(gpiotx_7_io_pad_clk)
  );
  // ==========================================================================
  // SoC Labs PHASE-B SHARED CAPTURE-CLOCK BUFG (2026-07-14) — see the
  // USE_SHARED_CAP_BUFG parameter header for the measured root cause.
  //
  // ONE copy of the per-lane RX capture mux chain, buffered once, fanned to all
  // 8 lanes. This is an EXACT replica of the chain inside WavD2DGpioRx_v2
  // (same Stdcell modules, same port order, same selects) — the io_pol
  // inversion is preserved. It is only legal because the chain's inputs are
  // lane-identical, which the gpiorx_<N> assigns below make explicit:
  //   gpiorx_<N>_io_pad_clk   = io_pad_clk_rx              (all N)
  //   gpiorx_<N>_io_scan_mode = io_scan_mode               (all N)
  //   gpiorx_<N>_io_scan_clk  = io_scan_clk                (all N)
  //   gpiorx_<N>_io_pol       = out_prepend_swi_polarity   (all N)
  //
  // Mirrors the RX chain exactly:
  //   cnt_mux   : sel=io_scan_mode,             a=io_pad_clk_rx, b=io_scan_clk
  //   inv       : a=io_pad_clk_rx
  //   cap_mux   : sel=out_prepend_swi_polarity, a=io_pad_clk_rx, b=inv_z
  //   cap_mux_1 : sel=io_scan_mode,             a=cap_mux_z,     b=io_scan_clk
  // ==========================================================================
  wire cnt_clk_g;   // buffered pad_clk_scan_mux    output -> every lane's w_cnt_clk
  wire cap_clk_g;   // buffered pad_clk_inv_scan_mux_1 out -> every lane's w_pad_clk
  generate
    if (USE_SHARED_CAP_BUFG) begin : g_shared_cap_bufg
      wire shared_cnt_mux_z;
      wire shared_inv_z;
      wire shared_cap_mux_z;
      wire shared_cap_mux1_z;

      WavClockMux shared_pad_clk_scan_mux (
        .io_i_sel (io_scan_mode),
        .io_i_a   (io_pad_clk_rx),
        .io_i_b   (io_scan_clk),
        .io_o_z   (shared_cnt_mux_z)
      );
      WavClockInv shared_pad_clk_inv_winv (
        .io_a     (io_pad_clk_rx),
        .io_z     (shared_inv_z)
      );
      WavClockMux shared_pad_clk_inv_scan_mux (
        .io_i_sel (out_prepend_swi_polarity),
        .io_i_a   (io_pad_clk_rx),
        .io_i_b   (shared_inv_z),
        .io_o_z   (shared_cap_mux_z)
      );
      WavClockMux shared_pad_clk_inv_scan_mux_1 (
        .io_i_sel (io_scan_mode),
        .io_i_a   (shared_cap_mux_z),
        .io_i_b   (io_scan_clk),
        .io_o_z   (shared_cap_mux1_z)
      );
`ifndef TIDELINK_RXCLK_NO_PRIMITIVE
      // The whole point: get these two nets off general routing and onto a
      // dedicated global clock net, so all 8 lanes' capture flops see the same
      // edge. 2 BUFGs total (15/32 used today -> 17/32).
      BUFG u_cnt_bufg (.I(shared_cnt_mux_z),  .O(cnt_clk_g));
      BUFG u_cap_bufg (.I(shared_cap_mux1_z), .O(cap_clk_g));
`else
      // Belt-and-braces opt-out (mirrors the RX's own NO_PRIMITIVE fallback):
      // a non-Vivado flow can still elaborate with the shared chain, just
      // unbuffered. NOTE: this must stay a functional passthrough, NOT a tie-off
      // — the lanes have USE_EXT_CAP_CLK=1 in this branch, so tying these to 0
      // would leave every capture flop without a clock.
      assign cnt_clk_g = shared_cnt_mux_z;
      assign cap_clk_g = shared_cap_mux1_z;
`endif
    end else begin : g_shared_cap_off
      // USE_SHARED_CAP_BUFG=0 (sim/ASIC): every lane derives its own capture
      // clocks from its own local mux chain, exactly as before. The lanes have
      // USE_EXT_CAP_CLK=0, so these two nets are unused — tie them off.
      assign cnt_clk_g = 1'b0;
      assign cap_clk_g = 1'b0;
    end
  endgenerate

  // SoC Labs tidelink-gpio-phy integration (2026-05-28, Stage 7): force
  // USE_T3A=1'b0 on every per-lane WavD2DGpioRx instance, overriding the
  // wrapper's USE_T3A parameter coming down from the FPGA chain
  // (tidelink_vivado_wrapper.v defaults USE_T3A=1'b1 for the legacy comma
  // hunt). Rationale per
  // deps/tidelink-gpio-phy/docs/IMPLEMENTATION.md §10:
  //   The T3A self-aligning RX FSM (WavD2DGpioRx.v:400-466) needs a
  //   byte-periodic anchor pattern. The new alternating 0x12EB / 0xED14
  //   training set is full-16-bit aperiodic, so the FSM either false-locks
  //   on a random byte rotation or never locks at all. With USE_T3A=0 the
  //   per-lane count free-runs mod-16; the new tidelink-gpio-phy
  //   lane_checker + calibrator (slip, phase) sweep + S_PROBE bias picks up
  //   the alignment work that T3A used to do (and does it more reliably).
  // The wrapper's USE_T3A parameter is left in place so the legacy
  // wavd2d_gpiorx_t3a* unit tests still link, but the FPGA build will
  // ignore it at this scope.
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'hA3), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'h12EB)) gpiorx_0 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_0_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_0_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_0_io_scan_clk),
    .io_scan_out(gpiorx_0_io_scan_out),
    .io_por_reset(gpiorx_0_io_por_reset),
    .io_pol(gpiorx_0_io_pol),
    .io_phase_offset(effective_phase_offset[3:0]),
    .io_bit_slip(effective_bit_slip[2:0]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[3:0]),       // perlane-wp: lane-0 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[0]),   // perlane-wp: lane-0 override enable
    .io_link_clk(gpiorx_0_io_link_clk),
    .io_link_data(gpiorx_0_io_link_data),
    .io_pad_clk(gpiorx_0_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_0_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'hB5), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'hED14)) gpiorx_1 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_1_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_1_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_1_io_scan_clk),
    .io_scan_out(gpiorx_1_io_scan_out),
    .io_por_reset(gpiorx_1_io_por_reset),
    .io_pol(gpiorx_1_io_pol),
    .io_phase_offset(effective_phase_offset[7:4]),
    .io_bit_slip(effective_bit_slip[5:3]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[7:4]),       // perlane-wp: lane-1 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[1]),   // perlane-wp: lane-1 override enable
    .io_link_clk(gpiorx_1_io_link_clk),
    .io_link_data(gpiorx_1_io_link_data),
    .io_pad_clk(gpiorx_1_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_1_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'hC9), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'h12EB)) gpiorx_2 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_2_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_2_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_2_io_scan_clk),
    .io_scan_out(gpiorx_2_io_scan_out),
    .io_por_reset(gpiorx_2_io_por_reset),
    .io_pol(gpiorx_2_io_pol),
    .io_phase_offset(effective_phase_offset[11:8]),
    .io_bit_slip(effective_bit_slip[8:6]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[11:8]),      // perlane-wp: lane-2 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[2]),   // perlane-wp: lane-2 override enable
    .io_link_clk(gpiorx_2_io_link_clk),
    .io_link_data(gpiorx_2_io_link_data),
    .io_pad_clk(gpiorx_2_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_2_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'hD3), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'hED14)) gpiorx_3 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_3_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_3_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_3_io_scan_clk),
    .io_scan_out(gpiorx_3_io_scan_out),
    .io_por_reset(gpiorx_3_io_por_reset),
    .io_pol(gpiorx_3_io_pol),
    .io_phase_offset(effective_phase_offset[15:12]),
    .io_bit_slip(effective_bit_slip[11:9]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[15:12]),     // perlane-wp: lane-3 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[3]),   // perlane-wp: lane-3 override enable
    .io_link_clk(gpiorx_3_io_link_clk),
    .io_link_data(gpiorx_3_io_link_data),
    .io_pad_clk(gpiorx_3_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_3_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'h65), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'h12EB)) gpiorx_4 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_4_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_4_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_4_io_scan_clk),
    .io_scan_out(gpiorx_4_io_scan_out),
    .io_por_reset(gpiorx_4_io_por_reset),
    .io_pol(gpiorx_4_io_pol),
    .io_phase_offset(effective_phase_offset[19:16]),
    .io_bit_slip(effective_bit_slip[14:12]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[19:16]),     // perlane-wp: lane-4 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[4]),   // perlane-wp: lane-4 override enable
    .io_link_clk(gpiorx_4_io_link_clk),
    .io_link_data(gpiorx_4_io_link_data),
    .io_pad_clk(gpiorx_4_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_4_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'h4B), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'hED14)) gpiorx_5 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_5_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_5_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_5_io_scan_clk),
    .io_scan_out(gpiorx_5_io_scan_out),
    .io_por_reset(gpiorx_5_io_por_reset),
    .io_pol(gpiorx_5_io_pol),
    .io_phase_offset(effective_phase_offset[23:20]),
    .io_bit_slip(effective_bit_slip[17:15]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[23:20]),     // perlane-wp: lane-5 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[5]),   // perlane-wp: lane-5 override enable
    .io_link_clk(gpiorx_5_io_link_clk),
    .io_link_data(gpiorx_5_io_link_data),
    .io_pad_clk(gpiorx_5_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_5_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'h59), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'h12EB)) gpiorx_6 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_6_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_6_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_6_io_scan_clk),
    .io_scan_out(gpiorx_6_io_scan_out),
    .io_por_reset(gpiorx_6_io_por_reset),
    .io_pol(gpiorx_6_io_pol),
    .io_phase_offset(effective_phase_offset[27:24]),
    .io_bit_slip(effective_bit_slip[20:18]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[27:24]),     // perlane-wp: lane-6 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[6]),   // perlane-wp: lane-6 override enable
    .io_link_clk(gpiorx_6_io_link_clk),
    .io_link_data(gpiorx_6_io_link_data),
    .io_pad_clk(gpiorx_6_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_6_io_pad)
  );
  // USE_T3A forced to 1'b0 — see rationale at gpiorx_0 above (spec §10).
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_EXT_CAP_CLK(USE_SHARED_CAP_BUFG), .USE_T3A(1'b0), .TRAINING_BYTE(8'h2D), .WORD_PIN_AUTO(WORD_PIN_AUTO), .TRAINING_WORD16(16'hED14)) gpiorx_7 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_7_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_7_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_7_io_scan_clk),
    .io_scan_out(gpiorx_7_io_scan_out),
    .io_por_reset(gpiorx_7_io_por_reset),
    .io_pol(gpiorx_7_io_pol),
    .io_phase_offset(effective_phase_offset[31:28]),
    .io_bit_slip(effective_bit_slip[23:21]),
    .io_word_pin(io_swi_word_pin_in), // FIX-R seed: GLOBAL window pin (lane-identical by construction)
    .io_word_pin_auto_en(io_swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_word_pin_ovr(io_word_pin_ovr_in[31:28]),     // perlane-wp: lane-7 SW window pin
    .io_word_pin_ovr_en(io_word_pin_ovr_en_in[7]),   // perlane-wp: lane-7 override enable
    .io_link_clk(gpiorx_7_io_link_clk),
    .io_link_data(gpiorx_7_io_link_data),
    .io_pad_clk(gpiorx_7_io_pad_clk),
    .io_cnt_clk_ext(cnt_clk_g),  // PHASE-B: shared buffered capture clocks
    .io_cap_clk_ext(cap_clk_g),
    .io_pad(gpiorx_7_io_pad)
  );
  WavClockMux hsclk_scan_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(hsclk_scan_mux_io_i_sel),
    .io_i_a(hsclk_scan_mux_io_i_a),
    .io_i_b(hsclk_scan_mux_io_i_b),
    .io_o_z(hsclk_scan_mux_io_o_z)
  );
  WavResetSync por_reset_scan_wrs ( // @[Stdcell.scala 324:21]
    .io_clk(por_reset_scan_wrs_io_clk),
    .io_scan_ctrl(por_reset_scan_wrs_io_scan_ctrl),
    .io_reset_in(por_reset_scan_wrs_io_reset_in),
    .io_reset_out(por_reset_scan_wrs_io_reset_out)
  );
  assign auto_in_pready = auto_in_psel & ~taken; // @[RegisterNodes.scala 241:26]
  // SoC Labs: out_prepend_1 widened from 17 to 21 bits (added swi_phase_offset at [20:17])
  assign auto_in_prdata = {{11'd0}, out_prepend_1}; // @[RegisterNodes.scala 229:24 RegisterNodes.scala 229:24]
  assign io_scan_out = 1'h0; // @[GPIO.scala 188:17]
  assign io_link_tx_tx_ready = _precount_in_T & io_link_tx_tx_en; // @[GPIO.scala 230:45]
  // SoC Labs 2026-06-21: BUFG the single /16 TX word clock (gpiotx_0's ~count[3]),
  // mirroring the RX USE_LNK_CLKBUF buffering. WITHOUT a global buffer this high-fanout
  // (~285-endpoint) clock is a LUT-driven fabric net whose skew leaves the DEEP Wlink
  // a2l-read WavResetSync (async-set / sync-RELEASE) without a clean edge at those flops
  // -> io_rreset never deasserts -> a2l read side held in reset -> link_empty=1 FOREVER
  // -> FCSM never drains -> NO V2 data TX (silicon-measured: wptr laps to 17, RXW=0).
  // The XDC create_generated_clock alone did NOT fix it (Vivado declined auto-BUFG
  // promotion: "Inserted BUFG: 0, Skipped: 5"); an explicit BUFG primitive is mandatory.
  // USE_LNK_CLKBUF=1 on FPGA (packaged IP), =0 on ASIC (passthrough -> bit-exact).
  generate
    if (USE_LNK_CLKBUF) begin : g_tx_word_bufg
      BUFG u_tx_word_bufg (.I(gpiotx_0_io_link_clk), .O(io_link_tx_tx_link_clk));
    end else begin : g_tx_word_nobuf
      assign io_link_tx_tx_link_clk = gpiotx_0_io_link_clk; // @[GPIO.scala 218:31]
    end
  endgenerate
  assign io_link_rx_rx_link_data = {io_link_rx_rx_link_data_hi,io_link_rx_rx_link_data_lo}; // @[GPIO.scala 246:47]
  assign io_link_rx_rx_link_clk = gpiorx_0_io_link_clk; // @[GPIO.scala 245:31]
  assign io_pad_clk_tx = gpiotx_0_io_pad_clk; // @[GPIO.scala 219:31]
  assign io_pad_tx_0 = gpiotx_0_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_1 = gpiotx_1_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_2 = gpiotx_2_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_3 = gpiotx_3_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_4 = gpiotx_4_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_5 = gpiotx_5_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_6 = gpiotx_6_io_pad; // @[GPIO.scala 215:31]
  assign io_pad_tx_7 = gpiotx_7_io_pad; // @[GPIO.scala 215:31]
  assign gpiotx_0_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_0_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_0_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_0_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_0_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_0_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_0_io_link_data = tx_lane_masked[15:0];     // SoC Labs Step 1: segmenter+mask front-end (was tx_lane_en ? tx_lane_data : 16'h0)
  assign gpiotx_1_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_1_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_1_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_1_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_1_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_1_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_1_io_link_data = tx_lane_masked[31:16];    // SoC Labs Step 1: segmenter+mask front-end
  assign gpiotx_2_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_2_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_2_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_2_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_2_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_2_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_2_io_link_data = tx_lane_masked[47:32];    // SoC Labs Step 1: segmenter+mask front-end
  assign gpiotx_3_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_3_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_3_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_3_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_3_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_3_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_3_io_link_data = tx_lane_masked[63:48];    // SoC Labs Step 1: segmenter+mask front-end
  assign gpiotx_4_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_4_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_4_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_4_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_4_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_4_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_4_io_link_data = tx_lane_masked[79:64];    // SoC Labs Step 1: segmenter+mask front-end
  assign gpiotx_5_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_5_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_5_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_5_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_5_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_5_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_5_io_link_data = tx_lane_masked[95:80];    // SoC Labs Step 1: segmenter+mask front-end
  assign gpiotx_6_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_6_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_6_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_6_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_6_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_6_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_6_io_link_data = tx_lane_masked[111:96];   // SoC Labs Step 1: segmenter+mask front-end
  assign gpiotx_7_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_7_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_7_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_7_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_7_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_7_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_7_io_link_data = tx_lane_masked[127:112];  // SoC Labs Step 1: segmenter+mask front-end
  assign gpiorx_0_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_0_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_0_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_0_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_0_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_0_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_0_io_pad = io_pad_rx_0; // @[GPIO.scala 238:31]
  assign gpiorx_1_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_1_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_1_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_1_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_1_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_1_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_1_io_pad = io_pad_rx_1; // @[GPIO.scala 238:31]
  assign gpiorx_2_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_2_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_2_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_2_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_2_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_2_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_2_io_pad = io_pad_rx_2; // @[GPIO.scala 238:31]
  assign gpiorx_3_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_3_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_3_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_3_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_3_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_3_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_3_io_pad = io_pad_rx_3; // @[GPIO.scala 238:31]
  assign gpiorx_4_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_4_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_4_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_4_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_4_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_4_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_4_io_pad = io_pad_rx_4; // @[GPIO.scala 238:31]
  assign gpiorx_5_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_5_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_5_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_5_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_5_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_5_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_5_io_pad = io_pad_rx_5; // @[GPIO.scala 238:31]
  assign gpiorx_6_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_6_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_6_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_6_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_6_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_6_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_6_io_pad = io_pad_rx_6; // @[GPIO.scala 238:31]
  assign gpiorx_7_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiorx_7_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiorx_7_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiorx_7_io_por_reset = io_por_reset; // @[GPIO.scala 235:31]
  assign gpiorx_7_io_pol = out_prepend_swi_polarity; // @[GPIO.scala 198:31 SW.scala 117:16]
  assign gpiorx_7_io_pad_clk = io_pad_clk_rx; // @[GPIO.scala 237:31]
  assign gpiorx_7_io_pad = io_pad_rx_7; // @[GPIO.scala 238:31]
  assign hsclk_scan_mux_io_i_sel = io_scan_mode; // @[Stdcell.scala 150:21]
  assign hsclk_scan_mux_io_i_a = io_hsclk; // @[Stdcell.scala 151:21]
  assign hsclk_scan_mux_io_i_b = io_scan_clk; // @[Stdcell.scala 152:21]
  assign por_reset_scan_wrs_io_clk = hsclk_scan_mux_io_o_z; // @[Stdcell.scala 325:23]
  assign por_reset_scan_wrs_io_scan_ctrl = io_scan_asyncrst_ctrl; // @[Stdcell.scala 327:23]
  assign por_reset_scan_wrs_io_reset_in = io_por_reset; // @[Stdcell.scala 326:23]
  always @(posedge io_link_tx_tx_link_clk or posedge por_reset_scan_wrs_io_reset_out) begin
    if (por_reset_scan_wrs_io_reset_out) begin
      precount <= 8'hf;
    end else if (io_link_tx_tx_en) begin
      if (!(precount == 8'h0)) begin
        precount <= _precount_in_T_2;
      end
    end else begin
      precount <= swi_pream_count_1;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_pream_count_1 <= 8'h1;
    end else if (out_f_wivalid) begin
      swi_pream_count_1 <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge io_link_tx_tx_link_clk or posedge por_reset_scan_wrs_io_reset_out) begin
    if (por_reset_scan_wrs_io_reset_out) begin
      postcount <= 8'h0;
    end else if (~io_link_tx_tx_en) begin
      if (!(postcount == 8'h0)) begin
        postcount <= _postcount_in_T_3;
      end
    end else begin
      postcount <= out_prepend_swi_post_count;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_post_count <= 8'h7;
    end else if (out_f_wivalid_1) begin
      out_prepend_swi_post_count <= auto_in_pwdata[15:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_polarity <= 1'h1;
    end else if (out_f_wivalid_2) begin
      out_prepend_swi_polarity <= auto_in_pwdata[16];
    end
  end
  // SoC Labs alignment patch: swi_phase_offset register at PHY ctrl bits[20:17].
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_phase_offset <= 4'h0;
    end else if (out_f_wivalid_phase) begin
      swi_phase_offset <= auto_in_pwdata[20:17];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      taken <= 1'h0;
    end else if (_T) begin
      taken <= 1'h0;
    end else begin
      taken <= _GEN_3;
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
  precount = _RAND_0[7:0];
  _RAND_1 = {1{`RANDOM}};
  swi_pream_count_1 = _RAND_1[7:0];
  _RAND_2 = {1{`RANDOM}};
  postcount = _RAND_2[7:0];
  _RAND_3 = {1{`RANDOM}};
  out_prepend_swi_post_count = _RAND_3[7:0];
  _RAND_4 = {1{`RANDOM}};
  out_prepend_swi_polarity = _RAND_4[0:0];
  _RAND_5 = {1{`RANDOM}};
  taken = _RAND_5[0:0];
  _RAND_6 = {1{`RANDOM}};
  swi_phase_offset = _RAND_6[3:0];
`endif // RANDOMIZE_REG_INIT
  if (por_reset_scan_wrs_io_reset_out) begin
    precount = 8'hf;
  end
  if (reset) begin
    swi_pream_count_1 = 8'h1;
  end
  if (por_reset_scan_wrs_io_reset_out) begin
    postcount = 8'h0;
  end
  if (reset) begin
    out_prepend_swi_post_count = 8'h7;
  end
  if (reset) begin
    out_prepend_swi_polarity = 1'h1;
  end
  if (reset) begin
    taken = 1'h0;
  end
  if (reset) begin
    swi_phase_offset = 4'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
