// =============================================================================
// SoC Labs LOCAL OVERRIDE: Wlink.v
//
// Source: deps/axi-chiplet-controller/logical/wlink/Wlink.v (2324 lines)
// Override reason (tdif-04, Layer 2 fix): change reset value of
// `swi_delay_cycles` from 16'h6a4 (=1700) to 16'h0.
//
// Background
// ----------
// WlinkTxPstateCtrl uses `io_swi_delay_cycles` as the count of link-word
// cycles after a sop event before it enters PSTATE (low-power) mode. When
// the value is non-zero AND no FC traffic arrives within `swi_delay_cycles`,
// the FSM advances 0 → 1 (PRE_PREQ) → 2 (PSTATE). To recover the FSM needs
// both `~tx_ready && ll_app.sop` simultaneously — which is unreachable in
// our training→FC handoff scenario (training drops → swi_enable wiggle →
// PSTATE deadlock). Track E (2026-05-25) confirmed experimentally that
// writing `swi_delay_cycles=0` to 0x44030230 BEFORE the LL swreset cycle
// recovers the TX pstate (PSTATE=2 → APP=0, TxEn 0 → 1).
//
// Fix
// ---
// Change the default at POR/apb_reset to 0. With `swi_delay_cycles==0` the
// guard `|io_swi_delay_cycles` is FALSE, so the PSTATE FSM never advances
// past state 0 (APP). SW can still write a non-zero value via APB if PSTATE
// recovery is desired later.
//
// Diff vs base
// ------------
// Lines 2054 and 2280: 16'h6a4 → 16'h0  (the apb_reset value of
// swi_delay_cycles in both the synthesis always-block and the simulation
// initial block).
//
// Coverage
// --------
//   * Track E manual APB write at 0x44030230 confirmed the recovery.
//   * Field already SW-writable, so non-zero behaviour can be restored at
//     runtime without rebuild for any future PSTATE testing.
//
// Author: SoC Labs (2026-05-25)
// Linked to: docs/TIDELINK_HANDOFF_2026_05_25.md (Layer 2)
// =============================================================================
module Wlink #(
  // SoC Labs §9 clock fix: pass-through to WlinkGPIOPHY.USE_CLKBUF.
  parameter USE_CLKBUF = 1'b0,
  // SoC Labs §9 T3a: pass-through to WlinkGPIOPHY.USE_T3A. Default 0
  // (sim/ASIC bit-exact); FPGA wrapper sets 1 via threading.
  parameter USE_T3A   = 1'b0
) (
  input         apb_clk,
  input         apb_reset,
  input         apbport_0_psel,
  input         apbport_0_penable,
  input         apbport_0_pwrite,
  input  [12:0] apbport_0_paddr,
  input  [2:0]  apbport_0_pprot,
  input  [31:0] apbport_0_pwdata,
  input  [3:0]  apbport_0_pstrb,
  output        apbport_0_pready,
  output        apbport_0_pslverr,
  output [31:0] apbport_0_prdata,
  input         axi_ini_0_aw_ready,
  output        axi_ini_0_aw_valid,
  output [11:0] axi_ini_0_aw_bits_id,
  output [35:0] axi_ini_0_aw_bits_addr,
  output [7:0]  axi_ini_0_aw_bits_len,
  output [2:0]  axi_ini_0_aw_bits_size,
  output [1:0]  axi_ini_0_aw_bits_burst,
  output        axi_ini_0_aw_bits_lock,
  output [3:0]  axi_ini_0_aw_bits_cache,
  output [2:0]  axi_ini_0_aw_bits_prot,
  output [3:0]  axi_ini_0_aw_bits_qos,
  input         axi_ini_0_w_ready,
  output        axi_ini_0_w_valid,
  output [31:0] axi_ini_0_w_bits_data,
  output [3:0]  axi_ini_0_w_bits_strb,
  output        axi_ini_0_w_bits_last,
  output        axi_ini_0_b_ready,
  input         axi_ini_0_b_valid,
  input  [11:0] axi_ini_0_b_bits_id,
  input  [1:0]  axi_ini_0_b_bits_resp,
  input         axi_ini_0_ar_ready,
  output        axi_ini_0_ar_valid,
  output [11:0] axi_ini_0_ar_bits_id,
  output [35:0] axi_ini_0_ar_bits_addr,
  output [7:0]  axi_ini_0_ar_bits_len,
  output [2:0]  axi_ini_0_ar_bits_size,
  output [1:0]  axi_ini_0_ar_bits_burst,
  output        axi_ini_0_ar_bits_lock,
  output [3:0]  axi_ini_0_ar_bits_cache,
  output [2:0]  axi_ini_0_ar_bits_prot,
  output [3:0]  axi_ini_0_ar_bits_qos,
  output        axi_ini_0_r_ready,
  input         axi_ini_0_r_valid,
  input  [11:0] axi_ini_0_r_bits_id,
  input  [31:0] axi_ini_0_r_bits_data,
  input  [1:0]  axi_ini_0_r_bits_resp,
  input         axi_ini_0_r_bits_last,
  output        axi_tgt_0_aw_ready,
  input         axi_tgt_0_aw_valid,
  input  [11:0] axi_tgt_0_aw_bits_id,
  input  [35:0] axi_tgt_0_aw_bits_addr,
  input  [7:0]  axi_tgt_0_aw_bits_len,
  input  [2:0]  axi_tgt_0_aw_bits_size,
  input  [1:0]  axi_tgt_0_aw_bits_burst,
  input         axi_tgt_0_aw_bits_lock,
  input  [3:0]  axi_tgt_0_aw_bits_cache,
  input  [2:0]  axi_tgt_0_aw_bits_prot,
  input  [3:0]  axi_tgt_0_aw_bits_qos,
  output        axi_tgt_0_w_ready,
  input         axi_tgt_0_w_valid,
  input  [31:0] axi_tgt_0_w_bits_data,
  input  [3:0]  axi_tgt_0_w_bits_strb,
  input         axi_tgt_0_w_bits_last,
  input         axi_tgt_0_b_ready,
  output        axi_tgt_0_b_valid,
  output [11:0] axi_tgt_0_b_bits_id,
  output [1:0]  axi_tgt_0_b_bits_resp,
  output        axi_tgt_0_ar_ready,
  input         axi_tgt_0_ar_valid,
  input  [11:0] axi_tgt_0_ar_bits_id,
  input  [35:0] axi_tgt_0_ar_bits_addr,
  input  [7:0]  axi_tgt_0_ar_bits_len,
  input  [2:0]  axi_tgt_0_ar_bits_size,
  input  [1:0]  axi_tgt_0_ar_bits_burst,
  input         axi_tgt_0_ar_bits_lock,
  input  [3:0]  axi_tgt_0_ar_bits_cache,
  input  [2:0]  axi_tgt_0_ar_bits_prot,
  input  [3:0]  axi_tgt_0_ar_bits_qos,
  input         axi_tgt_0_r_ready,
  output        axi_tgt_0_r_valid,
  output [11:0] axi_tgt_0_r_bits_id,
  output [31:0] axi_tgt_0_r_bits_data,
  output [1:0]  axi_tgt_0_r_bits_resp,
  output        axi_tgt_0_r_bits_last,
  input  [31:0] generalbus_in,
  output [31:0] generalbus_out,
  input  [49:0] tidelink_in,
  output [49:0] tidelink_out,
  input  [25:0] ptp_in,
  output [25:0] ptp_out,
  input         scan_mode,
  input         scan_asyncrst_ctrl,
  input         scan_clk,
  input         scan_shift,
  input         scan_in,
  output        scan_out,
  input         por_reset,
  input         app_clk,
  input         app_clk_reset,
  output        interrupt,
  input         sb_reset_in,
  output        sb_reset_out,
  output        sb_wake,
  output        tx_link_idle,
  input         user_hsclk,
  output        pad_clk_tx,
  output        pad_tx_0,
  output        pad_tx_1,
  output        pad_tx_2,
  output        pad_tx_3,
  output        pad_tx_4,
  output        pad_tx_5,
  output        pad_tx_6,
  output        pad_tx_7,
  input         pad_clk_rx,
  input         pad_rx_0,
  input         pad_rx_1,
  input         pad_rx_2,
  input         pad_rx_3,
  input         pad_rx_4,
  input         pad_rx_5,
  input         pad_rx_6,
  input         pad_rx_7,
  // SoC Labs bring-up patch (2026-05-06): peer-mask handshake port stubs.
  // The Chisel was updated to add these (commit a40fbbb in this submodule)
  // but the generated Verilog wasn't refreshed. Add port declarations so
  // axi_chiplet_controller.sv (which already wires them) can synthesise.
  // tx_lane_mask_o / rx_lane_mask_o expose the local lane-mask registers.
  // peer_*_lane_mask_i are tied off in the wrapper for now. mask_hs_result_o
  // is unused with mask_hs_bypass_i=1 (the bring-up gate is fully bypassed).
  output [7:0]  tx_lane_mask_o,
  output [7:0]  rx_lane_mask_o,
  input  [7:0]  peer_tx_lane_mask_i,
  input  [7:0]  peer_rx_lane_mask_i,
  output [1:0]  mask_hs_result_o,
  // SoC Labs §9: alignment-control inputs sourced from the TideLink chiplet
  // controller's APB register block. Tie to 0 in environments without the
  // chiplet controller — default OR-mux path inside WavD2DGpio preserves
  // cocotb hierarchical-force behaviour.
  input  [23:0] swi_bit_slip_in,
  input         swi_training_mode_in,
  // SoC Labs §9.7: per-lane 4-bit phase offset, 8 lanes x 4 bits (lane N
  // at bits [4N+3:4N]). Pass-through to WlinkGPIOPHY, mirroring
  // swi_bit_slip_in. Tie 0 → legacy single-global-phase APB path.
  input  [31:0] swi_phase_offset_in,
`ifdef TIDELINK_PHY_V2
  // S3 PHY swap (2026-06-11): the deps/tidelink-phy WlinkGPIOPHY fork adds a
  // global word-window pin + its autonomous-mode select (FIX-R/FIX-R-proper).
  // Routed from the chiplet controller. V1 builds never see these ports.
  input   [3:0] swi_word_pin_in,
  input         swi_word_pin_auto_en,
  // SoC Labs SYNC-insert (V2 LL re-hunt beacon, 2026-06-15) — DEFAULT-OFF APB
  // enable strap, routed from the chiplet controller (Region 8 slot 0 bit[2]
  // SWI_SYNC_INSERT_EN, SoC addr 0x44032100). When 0 the PHY's SYNC inserter is
  // a pure passthrough so the TX datapath is bit-identical to today. V1 builds
  // never see this port (the V1 PHY does its own idle-gated SYNC insertion).
  input         swi_sync_insert_en_in,
  // SoC Labs SYNC-insert GATE FIX (2026-06-15, PART 2) — DEFAULT-OFF APB control
  // strap, routed from the chiplet controller (Region 8 slot 0 bit[3]
  // SWI_SYNC_FORCE_ALWAYS, SoC addr 0x44032100). When 0 the SYNC beacon keeps
  // its idle-gated production behaviour (bit-identical). When 1 the idle gate is
  // dropped so the beacon fires on enable alone (still self-gates ~training).
  input         swi_sync_force_always_in,
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 2/3) — SW
  // LANE_MASK strap for the PHY's RX SYNC detector (PART 3, default 0xFF,
  // Region 9 slot 2 SoC addr 0x44032128), routed from the chiplet controller.
  // SWI_SYNC_ROBUST_DETECT (PART 2, Region 8 slot 0 bit[4]) selects whether the
  // detector's per-lane match is OR'd into the framer re-hunt below.
  input  [7:0]  swi_sync_lane_mask_in,
  input         swi_sync_robust_detect_in,
  // SoC Labs RX SYNC-detect Hamming TOLERANCE (2026-06-17) — Region 9 slot 2
  // SoC addr 0x44032128 [12:8]. 0 = EXACT (bit-identical). Pass-through to the
  // WlinkGPIOPHY fork's sync_tol_in.
  input  [4:0]  swi_sync_tol_in,
`endif
  // SoC Labs §9 auto-cal hookup: expose the recovered RX link clock and the
  // per-lane deserialised 128-bit data so the chiplet-controller can
  // instantiate the lane-checker + calibrator FSM outside Wlink. These are
  // existing internal nets of Wlink (lines ~251/253 below) — promoting them
  // to outputs costs nothing structurally; downstream connections inside
  // Wlink continue to use the same wires.
  output [127:0] phy_link_rx_rx_link_data_o,
  output         phy_link_rx_rx_link_clk_o,
  // SoC Labs credit-path observability (read-only APB exposure, replaces
  // the ILA debug core). FCSM internals (TideLinkToWlink tl2wl) + the
  // byte-align FSM internals (WlinkRxLinkLayer llrx) + saturating ECC
  // event counters. The counters live in the phy_link_rx_rx_link_clk
  // domain (the recovered RX link clock, exposed by
  // phy_link_rx_rx_link_clk_o). All of these are 2-flop-synced into
  // apb_clk inside axi_chiplet_controller.sv (mirrors the existing
  // sync_lane_locked_* pattern).
  output [2:0]   obs_fcsm_state_o,        // FC SM state (io_tx_clk dom.)
  output         obs_cr_pkt_seen_rx_o,    // sticky cr-pkt-seen (rx dom.)
  output         obs_crack_pkt_seen_rx_o, // sticky crack-pkt-seen (rx)
  output         obs_pkt_is_cr_pkt_o,     // cr-pkt decode (rx dom.)
  output         obs_pkt_is_crack_pkt_o,  // crack-pkt decode (rx dom.)
  output [1:0]   obs_llrx_state_o,        // byte-align FSM state (rx dom.)
  output         obs_is_short_pkt_o,      // short-packet detect (rx)
  output         obs_is_long_pkt_o,       // long-packet detect (rx)
  output         obs_llrx_valid_o,        // LL_RX has valid pkt (rx)
  output [15:0]  obs_ecc_corrupted_cnt_o, // sat. ECC-corrupt count (rx)
  output [15:0]  obs_ecc_corrected_cnt_o, // sat. ECC-corrected count (rx)
  // SoC Labs 2026-06-08: saturating count of SYNC-word detections on the
  // assembled RX bus (cross-lane-deskew health). RX-link-clock domain;
  // 2-flop-synced to apb_clk in axi_chiplet_controller.sv.
  output [15:0]  obs_sync_detected_cnt_o, // sat. SYNC-detected count (rx)
  // SoC Labs Bug-A FCSM observation 2026-06-02 — gate signals for state 4→5.
  output         obs_a2l_replay_link_valid_o, // tx domain
  output [7:0]   obs_fe_rx_credit_max_o,      // rx domain
  output         obs_fe_rx_is_full_o,         // rx domain
  // SoC Labs Bug-A FCSM observation 2026-06-03
  output         obs_a2l_replay_app_valid_o,  // app domain
  // SoC Labs V2 data-send observation 2026-06-21 — a2l replay buffer's true
  // app_ready (app-clk domain) and link_empty (link-clk domain). Read-only.
  output         obs_a2l_replay_app_ready_o,  // app domain
  output         obs_a2l_replay_link_empty_o, // link domain
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 — a2l replay
  // buffer raw write ptr / app-clk-synced ACK ptr / false-FULL flag / enable
  // demet term of app_ready. All app-clk domain, read-only fan-outs.
  output [4:0]   obs_a2l_wptr_o,              // app domain (write bin ptr)
  output [4:0]   obs_a2l_synced_ack_o,        // app domain (synced ACK ptr)
  output         obs_a2l_full_o,              // app domain (false-FULL flag)
  output         obs_a2l_enable_app_demet_o,  // app domain (other app_ready term)
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  // — a2l replay buffer read-side reset (== fifo_io_rreset) and LINK read binary
  // pointer (== link_cur_addr). Both link-clk domain, read-only fan-outs.
  output         obs_a2l_rreset_o,            // link domain (read-side FIFO reset)
  output [4:0]   obs_a2l_rptr_o,              // link domain (LINK read bin ptr)
  // SoC Labs FC credit observation 2026-06-12 — far-end RX credit pointer
  output [7:0]   obs_fe_rx_ptr_o,             // tx domain
  // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — packed
  // sticky framer (llrx) + FCSM (tl2wl) words that localise where a sustained
  // A->B long-DATA packet dies. rx-link-clk / io_rx_clk domains; pure read-only
  // fan-outs. Present in V1 + V2 (the framer/FCSM are shared); only the V2
  // controller decodes them to APB (Region D), so V1 stays bit-identical.
  output [31:0]  obs_rxcap0_o,                // {marker,ever,state,ph@first_long}
  output [31:0]  obs_rxcap1_o,                // {max_byte_count, long_start_cnt}
  output [31:0]  obs_fcsmcap_o                // {marker,ever,first/last pktnum}
`ifdef TIDELINK_PHY_V2
  // SoC Labs V2 epoch-anchor engagement observable 2026-06-14 — the
  // WlinkGPIOPHY (deps/tidelink-phy fork) exports the cross-lane word-EPOCH
  // anchor state from its lane-deskew engine. Routed up through the chiplet
  // controller and 2-flop-synced to apb_clk for read at SWI_EPOCH_STATUS
  // (SoC MMIO 0x4403_2140). link_rx_rx_link_clk domain. V1 never sees these.
  ,
  output         obs_epoch_anchored_o,        // rx-link-clk dom: anchor engaged
  output [5:0]   obs_epoch_span_o,            // rx-link-clk dom: measured span
  // SoC Labs SYNC-insert TX OBSERVABILITY (2026-06-15, PART 1) — the V2
  // WlinkGPIOPHY fork exports the TX-side SYNC-insert probe (16-bit saturating
  // count of cycles the PHY physically drove a SYNC word + two live level bits:
  // tx_idle and effective_training_mode). io_link_tx_tx_link_clk domain; 2-flop
  // synced to apb_clk in axi_chiplet_controller.sv (mirrors obs_sync_detected_cnt).
  // Read at the new SYNC-OBS register (SoC MMIO 0x4403_2120). V1 never sees these.
  output [15:0]  obs_tx_sync_ins_cnt_o,       // tx-link-clk dom: SYNC-insert sat. count
  output         obs_tx_link_idle_level_o,    // tx-link-clk dom: live tx_idle
  output         obs_tx_training_level_o,     // tx-link-clk dom: live training
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 1) — the V2
  // WlinkGPIOPHY fork exports the mask-aware per-lane SYNC detector on the
  // post-deskew word. 16-bit saturating count + 8-bit sticky "ever-matched"
  // per-lane vector (THE key diagnostic). rx-link-clk domain; 2-flop-synced to
  // apb_clk in axi_chiplet_controller.sv. Read at the SYNC-DETECT register
  // (SoC MMIO 0x4403_2124). V1 never sees these.
  output [15:0]  obs_sync_seen_cnt_o,         // rx-link-clk dom: mask-aware sat. count
  output [7:0]   obs_sync_seen_lane_o,        // rx-link-clk dom: per-lane sticky vector
  // SoC Labs RX RAW-WORD + PERMUTATION observability (2026-06-15, rawobs) — the
  // V2 WlinkGPIOPHY fork exports a BEST-MATCH-latched raw post-deskew word + a
  // per-RX-lane carried-slice-index map, to decode WHY obs_sync_seen_lane_o
  // reads 0 on silicon (content-transform: permutation vs bit-rotation). All
  // rx-link-clk domain; CDC'd to apb_clk in axi_chiplet_controller.sv. Read at
  // Region 9 slots 3..7 (SoC MMIO 0x4403_212C..0x4403_213C). V1 never sees these.
  output [127:0] obs_dbg_raw_word_o,          // rx-link-clk dom: best-match raw word
  output [7:0]   obs_dbg_lane_any_match_o,    // rx-link-clk dom: fixed-pos match vector
  output [3:0]   obs_dbg_best_popcount_o,     // rx-link-clk dom: popcount of that vector
  output [31:0]  obs_dbg_slice_idx_o,         // rx-link-clk dom: per-lane carried-slice map
  // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override (2026-06-16,
  // perlane-wp) — the V2 WlinkGPIOPHY fork adds a CLEARABLE per-lane live-match
  // oracle (clear pulse in + live vector out) and a per-lane word-pin SW
  // override (8x4-bit + 8-bit enable). swi_sync_obs_clr_in is the APB W1-pulse
  // (SoC 0x44032100[5]); obs_sync_lane_live_o is the live "matched since clear"
  // vector (SoC 0x44032144); swi_word_pin_ovr_in / swi_word_pin_ovr_en_in are
  // the per-lane override (SoC 0x44032148). Tie {clr=0,ovr=0,en=0} = legacy.
  input          swi_sync_obs_clr_in,         // apb-clk strap: clearable-oracle clear pulse
  output [7:0]   obs_sync_lane_live_o,        // rx-link-clk dom: live per-lane match vector
  input  [31:0]  swi_word_pin_ovr_in,         // apb-clk strap: 8x4b per-lane window pin
  input  [7:0]   swi_word_pin_ovr_en_in,      // apb-clk strap: 8b per-lane override enable
  // STICKY-POISON per-lane sync_seen observability (2026-06-23). Per-lane deskew
  // SYNC re-anchor sync_seen vector (which lanes committed a periodic-confirmed
  // SYNC index). rx-link-clk domain; CDC'd to apb_clk in the chiplet controller.
  // SoC 0x44032144 sibling at 0x4403215C. 0 unless SYNC_REANCHOR_EN.
  output [7:0]   obs_sync_seen_vec_o,         // rx-link-clk dom: per-lane deskew sync_seen
  // DATA-MODE per-lane SYNC HAMMING-DISTANCE OBS (2026-06-25, the winscan
  // metric). Per-lane 5-bit Hamming distance of the current word to that lane's
  // SYNC slice — the DATA-mode RX-eye-quality metric the winscan centres the
  // IDELAY tap on. rx-link-clk domain; CDC'd to apb_clk in the chiplet
  // controller. SoC 0x4403_21AC (lane-selected). 0 unless SYNC_REANCHOR_EN.
  output [39:0]  obs_sync_dist_vec_o,         // rx-link-clk dom: per-lane SYNC Hamming distance
  // R-A FINALIZE ANCHOR-VERIFY (2026-07-04). Sticky from the WavD2DGpio_v2
  // local override: the ENGAGED deskew re-anchor has delivered >=1 post-deskew
  // word EXACTLY equal to TIDELINK_SYNC_WORD on every active lane
  // simultaneously (the wrong-slot mis-anchor detector — a one-slot-off lane
  // can never satisfy the simultaneous exact match). Cleared by POR / the F3
  // swi_sync_obs_clr_in. rx-link-clk domain; 2-FF synced to apb_clk in the
  // chiplet controller (ws_verify_q — the winscan WS_FINALIZE release gate).
  output         obs_anchor_verified_o        // rx-link-clk dom: engaged-anchor exact-beacon sticky
`endif
);
  // ===================================================================
  // SoC Labs credit-path observability wiring.
  //   llrx (WlinkRxLinkLayer) and tl2wl (TideLinkToWlink) expose new
  //   io_obs_* ports (added in this submodule branch). The two 16-bit
  //   saturating ECC event counters are clocked in the recovered RX
  //   link-clock domain (phy_link_rx_rx_link_clk == llrx_clock) off the
  //   existing single-cycle llrx_io_ecc_corrupted / llrx_io_ecc_corrected
  //   event pulses. The snapshot is 2-flop-synced into apb_clk by
  //   axi_chiplet_controller.sv. Declared up here (before first use) so
  //   the assignments below the instances can reference them.
  // ===================================================================
  // tdif-10 visibility (2026-05-25): mark_debug at the Wlink scope so the
  // ILA picks these up without having to bind into WlinkRxLinkLayer. The
  // underlying llrx instance already mark_debugs `state`/`is_long_pkt`/
  // `is_short_pkt`/`valid` internally; promoting at this scope adds a
  // second tap that survives even if Vivado flattens the llrx internals.
  wire [1:0] llrx_io_obs_state;
  wire       llrx_io_obs_is_short_pkt;
  wire       llrx_io_obs_is_long_pkt;
  wire       llrx_io_obs_valid;
  // SoC Labs 2026-06-08: SYNC-detected pulse from llrx (RX link-clock domain).
  wire       llrx_io_obs_sync_detected;
  // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — packed
  // sticky framer words from llrx (rx-link-clk domain), forwarded to Wlink
  // outputs below.
  wire [31:0] llrx_io_obs_rxcap0;
  wire [31:0] llrx_io_obs_rxcap1;
`ifdef TIDELINK_PHY_V2
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 1/2) — live
  // 1-cycle mask-aware match from the PHY detector (post-deskew word, RX
  // link-clock domain). PART 2: OR'd into the framer re-hunt below ONLY when
  // swi_sync_robust_detect_in=1 (default 0 -> bit-identical). Declared here so
  // the PHY instance can drive it and the llrx instance can consume it.
  wire       phy_io_sync_seen_pulse;
`endif
  // tdif-10 visibility (2026-05-25): the FCSM observability outputs
  // expose the master-side credit-handshake state that lets us see CR/CRACK
  // packets being received and the FCSM's own state advance. These nets
  // are already wired up to APB obs registers; promoting them to mark_debug
  // gives per-cycle ILA visibility (the APB version is poll-rate only).
  wire [2:0] tl2wl_io_obs_fcsm_state;          // tdif-10 ILA — FCSM state
  wire       tl2wl_io_obs_cr_pkt_seen_rx;      // tdif-10 ILA — sticky CR-rx
  wire       tl2wl_io_obs_crack_pkt_seen_rx;   // tdif-10 ILA — sticky CRACK-rx
  wire       tl2wl_io_obs_pkt_is_cr_pkt;       // tdif-10 ILA — combinational CR-detect
  wire       tl2wl_io_obs_pkt_is_crack_pkt;    // tdif-10 ILA — combinational CRACK-detect
  // SoC Labs Bug-A FCSM observation 2026-06-02
  wire       tl2wl_io_obs_a2l_replay_link_valid;
  wire [7:0] tl2wl_io_obs_fe_rx_credit_max;
  wire       tl2wl_io_obs_fe_rx_is_full;
  // SoC Labs Bug-A FCSM observation 2026-06-03
  wire       tl2wl_io_obs_a2l_replay_app_valid;
  // SoC Labs V2 data-send observation 2026-06-21
  wire       tl2wl_io_obs_a2l_replay_app_ready;
  wire       tl2wl_io_obs_a2l_replay_link_empty;
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21
  wire [4:0] tl2wl_io_obs_a2l_wptr;
  wire [4:0] tl2wl_io_obs_a2l_synced_ack;
  wire       tl2wl_io_obs_a2l_full;
  wire       tl2wl_io_obs_a2l_enable_app_demet;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  wire       tl2wl_io_obs_a2l_rreset;
  wire [4:0] tl2wl_io_obs_a2l_rptr;
  // SoC Labs FC credit observation 2026-06-12
  wire [7:0] tl2wl_io_obs_fe_rx_ptr;
  // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap) — packed
  // sticky FCSM word from tl2wl (io_rx_clk domain), forwarded to Wlink output.
  wire [31:0] tl2wl_io_obs_fcsmcap;
  reg [15:0] obs_ecc_corrupted_cnt_q;
  reg [15:0] obs_ecc_corrected_cnt_q;
  // SoC Labs 2026-06-08: saturating SYNC-detected event counter (RX link-clock).
  reg [15:0] obs_sync_detected_cnt_q;
  // Port stubs — read-only mirror of the lane-mask registers.
  // tx_lane_mask_o / rx_lane_mask_o are assigned after the reg declarations
  // (~line 720) to avoid VCS forward-reference errors.
  //
  // SHORTCOMINGS-14a/14b: link_lane_mask_hs_result @ 0x21C — the real SW
  // escape register. This was `assign mask_hs_result_o = 2'b00;` (a dead
  // stub), so a SLAVE-role die had NO hardware path to open its mask_hs
  // gate and could only "pass" via mask_hs_bypass_i / apb_debug_unlock_i —
  // i.e. a SHAM handshake. Measured on kr260-pair-onchip 2026-07-23: master
  // OBS_MASK_HS=0x0019E4E4 (match=1) but slave=0x00100000 (match=0,
  // gate forced), with the master's I2C verdict write ACKed (missed_ack=0)
  // — the verdict physically ARRIVED and was discarded by this tie.
  //
  // The autoneg master delivers the peer-mask verdict over I2C to this
  // peer's APB 0x21C (tidelink_autoneg.sv: MASK_RES_ADDR_MSB=0x02,
  // LSB=0x1C; verdict byte 0x01=match / 0x02=fail). This sniffer latches
  // that verdict so the slave drives mask_hs_result_o[0]=peer_says_match /
  // [1]=peer_says_fail, exactly as axi_chiplet_controller.sv consumes
  // wlink_mask_hs_result (:665,676-677). Self-contained APB-write decode at
  // the top-level apbport_0 (same hand-patch convention as the other SoC
  // Labs bring-up port stubs); it does not perturb the generated Chisel
  // register decode. POR-cleared, sticky thereafter (matches the autoneg's
  // own POR-cleared latch).
  //
  // Ported from deps/axi-chiplet-controller/logical/wlink/Wlink.v:209-238,
  // where this fix already existed but was never compiled: the FPGA V2
  // flist resolves `include "Wlink.v" through +incdir src/rtl/local_overrides
  // (flists/tidelink_fpga_v2.flist:43), so THIS file is the one that ships.
  localparam [12:0] LANE_MASK_HS_RESULT_ADDR = 13'h21C;
  reg        hs_result_match_q;   // peer said our crossover masks match
  reg        hs_result_fail_q;    // peer said they mismatch
  wire       hs_result_apb_wr =
                 apbport_0_psel    & apbport_0_penable &
                 apbport_0_pwrite  & apbport_0_pready  &
                 (apbport_0_paddr == LANE_MASK_HS_RESULT_ADDR);
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      hs_result_match_q <= 1'b0;
      hs_result_fail_q  <= 1'b0;
    end else if (hs_result_apb_wr) begin
      if (apbport_0_pwdata[7:0] == 8'h01) hs_result_match_q <= 1'b1;
      if (apbport_0_pwdata[7:0] == 8'h02) hs_result_fail_q  <= 1'b1;
    end
  end
  assign mask_hs_result_o = {hs_result_fail_q, hs_result_match_q};
  // synopsys translate_off
  wire _unused_peer_tx_lane_mask = |peer_tx_lane_mask_i;
  wire _unused_peer_rx_lane_mask = |peer_rx_lane_mask_i;
  // synopsys translate_on
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
`endif // RANDOMIZE_REG_INIT
  wire  xbar_auto_in_psel; // @[Wlink.scala 84:27]
  wire  xbar_auto_in_penable; // @[Wlink.scala 84:27]
  wire  xbar_auto_in_pwrite; // @[Wlink.scala 84:27]
  wire [12:0] xbar_auto_in_paddr; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_in_pwdata; // @[Wlink.scala 84:27]
  wire [3:0] xbar_auto_in_pstrb; // @[Wlink.scala 84:27]
  wire  xbar_auto_in_pready; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_in_prdata; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_4_psel; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_4_penable; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_4_pwrite; // @[Wlink.scala 84:27]
  wire [12:0] xbar_auto_out_4_paddr; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_4_pwdata; // @[Wlink.scala 84:27]
  wire [3:0] xbar_auto_out_4_pstrb; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_4_pready; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_4_prdata; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_3_psel; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_3_penable; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_3_pwrite; // @[Wlink.scala 84:27]
  wire [12:0] xbar_auto_out_3_paddr; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_3_pwdata; // @[Wlink.scala 84:27]
  wire [3:0] xbar_auto_out_3_pstrb; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_3_pready; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_3_prdata; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_2_psel; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_2_penable; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_2_pwrite; // @[Wlink.scala 84:27]
  wire [12:0] xbar_auto_out_2_paddr; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_2_pwdata; // @[Wlink.scala 84:27]
  wire [3:0] xbar_auto_out_2_pstrb; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_2_pready; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_2_prdata; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_1_psel; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_1_penable; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_1_pwrite; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_1_pwdata; // @[Wlink.scala 84:27]
  wire [3:0] xbar_auto_out_1_pstrb; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_1_pready; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_1_prdata; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_0_psel; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_0_penable; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_0_pwrite; // @[Wlink.scala 84:27]
  wire [9:0] xbar_auto_out_0_paddr; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_0_pwdata; // @[Wlink.scala 84:27]
  wire [3:0] xbar_auto_out_0_pstrb; // @[Wlink.scala 84:27]
  wire  xbar_auto_out_0_pready; // @[Wlink.scala 84:27]
  wire [31:0] xbar_auto_out_0_prdata; // @[Wlink.scala 84:27]
  wire  phy_clock; // @[Wlink.scala 87:27]
  wire  phy_reset; // @[Wlink.scala 87:27]
  wire  phy_auto_in_psel; // @[Wlink.scala 87:27]
  wire  phy_auto_in_penable; // @[Wlink.scala 87:27]
  wire  phy_auto_in_pwrite; // @[Wlink.scala 87:27]
  wire [31:0] phy_auto_in_pwdata; // @[Wlink.scala 87:27]
  wire [3:0] phy_auto_in_pstrb; // @[Wlink.scala 87:27]
  wire  phy_auto_in_pready; // @[Wlink.scala 87:27]
  wire [31:0] phy_auto_in_prdata; // @[Wlink.scala 87:27]
  wire  phy_scan_mode; // @[Wlink.scala 87:27]
  wire  phy_scan_asyncrst_ctrl; // @[Wlink.scala 87:27]
  wire  phy_scan_clk; // @[Wlink.scala 87:27]
  wire  phy_scan_out; // @[Wlink.scala 87:27]
  wire  phy_por_reset; // @[Wlink.scala 87:27]
  wire  phy_link_tx_tx_en; // @[Wlink.scala 87:27]
  wire  phy_link_tx_tx_ready; // @[Wlink.scala 87:27]
  /* mark_debug-disabled */ wire [127:0] phy_link_tx_tx_link_data; // SoC Labs ILA — LL_TX output
  /* mark_debug-disabled */ wire [7:0] phy_link_tx_tx_lane_mask; // SoC Labs ILA
  wire  phy_link_tx_tx_link_clk; // @[Wlink.scala 87:27]
  /* mark_debug-disabled */ wire [127:0] phy_link_rx_rx_link_data; // SoC Labs ILA — PHY→LL_RX
  /* mark_debug-disabled */ wire [7:0] phy_link_rx_rx_lane_mask; // SoC Labs ILA
  wire  phy_link_rx_rx_link_clk; // @[Wlink.scala 87:27]
  wire  phy_pad_clk_tx; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_0; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_1; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_2; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_3; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_4; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_5; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_6; // @[Wlink.scala 87:27]
  wire  phy_pad_tx_7; // @[Wlink.scala 87:27]
  wire  phy_pad_clk_rx; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_0; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_1; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_2; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_3; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_4; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_5; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_6; // @[Wlink.scala 87:27]
  wire  phy_pad_rx_7; // @[Wlink.scala 87:27]
  wire  phy_user_hsclk; // @[Wlink.scala 87:27]
  wire  txrouter_clock; // @[Wlink.scala 89:27]
  wire  txrouter_reset; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_7_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_7_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_7_word_count; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_7_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_6_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_6_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_6_word_count; // @[Wlink.scala 89:27]
  wire [55:0] txrouter_auto_in_6_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_6_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_6_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_5_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_5_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_5_word_count; // @[Wlink.scala 89:27]
  wire [39:0] txrouter_auto_in_5_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_5_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_5_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_4_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_4_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_4_word_count; // @[Wlink.scala 89:27]
  wire [55:0] txrouter_auto_in_4_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_4_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_4_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_3_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_3_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_3_word_count; // @[Wlink.scala 89:27]
  wire [111:0] txrouter_auto_in_3_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_3_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_3_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_2_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_2_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_2_word_count; // @[Wlink.scala 89:27]
  wire [23:0] txrouter_auto_in_2_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_2_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_2_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_1_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_1_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_1_word_count; // @[Wlink.scala 89:27]
  wire [47:0] txrouter_auto_in_1_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_1_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_1_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_0_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_in_0_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_0_word_count; // @[Wlink.scala 89:27]
  wire [111:0] txrouter_auto_in_0_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_in_0_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_in_0_advance; // @[Wlink.scala 89:27]
  wire  txrouter_auto_out_sop; // @[Wlink.scala 89:27]
  wire [7:0] txrouter_auto_out_data_id; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_out_word_count; // @[Wlink.scala 89:27]
  wire [111:0] txrouter_auto_out_data; // @[Wlink.scala 89:27]
  wire [15:0] txrouter_auto_out_crc; // @[Wlink.scala 89:27]
  wire  txrouter_auto_out_advance; // @[Wlink.scala 89:27]
  wire  txrouter_io_enable; // @[Wlink.scala 89:27]
  wire  txpstate_clock; // @[Wlink.scala 90:27]
  wire  txpstate_reset; // @[Wlink.scala 90:27]
  wire  txpstate_auto_in_sop; // @[Wlink.scala 90:27]
  wire [7:0] txpstate_auto_in_data_id; // @[Wlink.scala 90:27]
  wire [15:0] txpstate_auto_in_word_count; // @[Wlink.scala 90:27]
  wire [111:0] txpstate_auto_in_data; // @[Wlink.scala 90:27]
  wire [15:0] txpstate_auto_in_crc; // @[Wlink.scala 90:27]
  wire  txpstate_auto_in_advance; // @[Wlink.scala 90:27]
  wire  txpstate_auto_out_sop; // @[Wlink.scala 90:27]
  wire [7:0] txpstate_auto_out_data_id; // @[Wlink.scala 90:27]
  wire [15:0] txpstate_auto_out_word_count; // @[Wlink.scala 90:27]
  wire [111:0] txpstate_auto_out_data; // @[Wlink.scala 90:27]
  wire [15:0] txpstate_auto_out_crc; // @[Wlink.scala 90:27]
  wire  txpstate_auto_out_advance; // @[Wlink.scala 90:27]
  wire [15:0] txpstate_io_swi_delay_cycles; // @[Wlink.scala 90:27]
  wire [2:0] txpstate_io_swi_num_preq_send; // @[Wlink.scala 90:27]
  wire [7:0] txpstate_io_swi_preq_data_id; // @[Wlink.scala 90:27]
  wire [7:0] txpstate_io_swi_cycles_post_preq; // @[Wlink.scala 90:27]
  wire  txpstate_io_tx_ready; // @[Wlink.scala 90:27]
  wire  txpstate_io_tx_en; // @[Wlink.scala 90:27]
  wire [1:0] txpstate_io_state_o; // @[Wlink.scala 90:27]
  wire  rxrouter_auto_in_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_in_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_in_word_count; // @[Wlink.scala 92:27]
  wire [111:0] rxrouter_auto_in_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_in_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_in_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_8_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_8_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_8_word_count; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_8_valid; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_7_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_7_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_7_word_count; // @[Wlink.scala 92:27]
  wire [55:0] rxrouter_auto_out_7_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_7_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_7_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_6_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_6_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_6_word_count; // @[Wlink.scala 92:27]
  wire [39:0] rxrouter_auto_out_6_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_6_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_6_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_5_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_5_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_5_word_count; // @[Wlink.scala 92:27]
  wire [55:0] rxrouter_auto_out_5_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_5_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_5_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_4_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_4_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_4_word_count; // @[Wlink.scala 92:27]
  wire [111:0] rxrouter_auto_out_4_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_4_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_4_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_3_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_3_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_3_word_count; // @[Wlink.scala 92:27]
  wire [23:0] rxrouter_auto_out_3_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_3_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_3_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_2_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_2_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_2_word_count; // @[Wlink.scala 92:27]
  wire [47:0] rxrouter_auto_out_2_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_2_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_2_crc; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_1_sop; // @[Wlink.scala 92:27]
  wire [7:0] rxrouter_auto_out_1_data_id; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_1_word_count; // @[Wlink.scala 92:27]
  wire [111:0] rxrouter_auto_out_1_data; // @[Wlink.scala 92:27]
  wire  rxrouter_auto_out_1_valid; // @[Wlink.scala 92:27]
  wire [15:0] rxrouter_auto_out_1_crc; // @[Wlink.scala 92:27]
  wire  lltx_clock; // @[Wlink.scala 95:27]
  wire  lltx_reset; // @[Wlink.scala 95:27]
  wire  lltx_auto_in_sop; // @[Wlink.scala 95:27]
  wire [7:0] lltx_auto_in_data_id; // @[Wlink.scala 95:27]
  wire [15:0] lltx_auto_in_word_count; // @[Wlink.scala 95:27]
  wire [111:0] lltx_auto_in_data; // @[Wlink.scala 95:27]
  wire [15:0] lltx_auto_in_crc; // @[Wlink.scala 95:27]
  wire  lltx_auto_in_advance; // @[Wlink.scala 95:27]
  wire  lltx_io_enable; // @[Wlink.scala 95:27]
  wire [7:0] lltx_io_swi_short_packet_max; // @[Wlink.scala 95:27]
  wire [7:0] lltx_io_active_lanes; // @[Wlink.scala 95:27]
  wire [7:0] lltx_io_lane_mask; // @[Wlink.scala 95:27]
  wire  lltx_io_swi_err_inj; // @[Wlink.scala 95:27]
  wire [7:0] lltx_io_swi_err_inj_data_id; // @[Wlink.scala 95:27]
  wire [7:0] lltx_io_swi_err_inj_byte; // @[Wlink.scala 95:27]
  wire [2:0] lltx_io_swi_err_inj_bit; // @[Wlink.scala 95:27]
  wire  lltx_io_ll_tx_valid; // @[Wlink.scala 95:27]
  wire [127:0] lltx_io_link_data; // @[Wlink.scala 95:27]
  wire  lltx_io_link_idle; // @[Wlink.scala 95:27]
  wire  llrx_clock; // @[Wlink.scala 96:27]
  wire  llrx_reset; // @[Wlink.scala 96:27]
  wire  llrx_auto_out_sop; // @[Wlink.scala 96:27]
  wire [7:0] llrx_auto_out_data_id; // @[Wlink.scala 96:27]
  wire [15:0] llrx_auto_out_word_count; // @[Wlink.scala 96:27]
  wire [111:0] llrx_auto_out_data; // @[Wlink.scala 96:27]
  wire  llrx_auto_out_valid; // @[Wlink.scala 96:27]
  wire [15:0] llrx_auto_out_crc; // @[Wlink.scala 96:27]
  wire  llrx_io_enable; // @[Wlink.scala 96:27]
  wire [7:0] llrx_io_swi_short_packet_max; // @[Wlink.scala 96:27]
  wire [7:0] llrx_io_active_lanes; // @[Wlink.scala 96:27]
  wire [7:0] llrx_io_lane_mask; // @[Wlink.scala 96:27]
  wire  llrx_io_ecc_corrected; // @[Wlink.scala 96:27]
  wire  llrx_io_ecc_corrupted; // @[Wlink.scala 96:27]
  wire [127:0] llrx_io_link_data; // @[Wlink.scala 96:27]
  wire  llrx_io_in_error_state; // @[Wlink.scala 96:27]
  wire  axi2wl_clock; // @[AXI.scala 99:31]
  wire  axi2wl_reset; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axirFC_rx_in_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axirFC_rx_in_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axirFC_rx_in_word_count; // @[AXI.scala 99:31]
  wire [55:0] axi2wl_auto_wlink_axirFC_rx_in_data; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axirFC_rx_in_valid; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axirFC_rx_in_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axirFC_tx_out_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axirFC_tx_out_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axirFC_tx_out_word_count; // @[AXI.scala 99:31]
  wire [55:0] axi2wl_auto_wlink_axirFC_tx_out_data; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axirFC_tx_out_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axirFC_tx_out_advance; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiarFC_rx_in_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axiarFC_rx_in_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiarFC_rx_in_word_count; // @[AXI.scala 99:31]
  wire [111:0] axi2wl_auto_wlink_axiarFC_rx_in_data; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiarFC_rx_in_valid; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiarFC_rx_in_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiarFC_tx_out_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axiarFC_tx_out_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiarFC_tx_out_word_count; // @[AXI.scala 99:31]
  wire [111:0] axi2wl_auto_wlink_axiarFC_tx_out_data; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiarFC_tx_out_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiarFC_tx_out_advance; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axibFC_rx_in_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axibFC_rx_in_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axibFC_rx_in_word_count; // @[AXI.scala 99:31]
  wire [23:0] axi2wl_auto_wlink_axibFC_rx_in_data; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axibFC_rx_in_valid; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axibFC_rx_in_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axibFC_tx_out_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axibFC_tx_out_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axibFC_tx_out_word_count; // @[AXI.scala 99:31]
  wire [23:0] axi2wl_auto_wlink_axibFC_tx_out_data; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axibFC_tx_out_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axibFC_tx_out_advance; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiwFC_rx_in_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axiwFC_rx_in_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiwFC_rx_in_word_count; // @[AXI.scala 99:31]
  wire [47:0] axi2wl_auto_wlink_axiwFC_rx_in_data; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiwFC_rx_in_valid; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiwFC_rx_in_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiwFC_tx_out_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axiwFC_tx_out_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiwFC_tx_out_word_count; // @[AXI.scala 99:31]
  wire [47:0] axi2wl_auto_wlink_axiwFC_tx_out_data; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiwFC_tx_out_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiwFC_tx_out_advance; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiawFC_rx_in_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axiawFC_rx_in_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiawFC_rx_in_word_count; // @[AXI.scala 99:31]
  wire [111:0] axi2wl_auto_wlink_axiawFC_rx_in_data; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiawFC_rx_in_valid; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiawFC_rx_in_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiawFC_tx_out_sop; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_wlink_axiawFC_tx_out_data_id; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiawFC_tx_out_word_count; // @[AXI.scala 99:31]
  wire [111:0] axi2wl_auto_wlink_axiawFC_tx_out_data; // @[AXI.scala 99:31]
  wire [15:0] axi2wl_auto_wlink_axiawFC_tx_out_crc; // @[AXI.scala 99:31]
  wire  axi2wl_auto_wlink_axiawFC_tx_out_advance; // @[AXI.scala 99:31]
  wire  axi2wl_auto_xbar_in_psel; // @[AXI.scala 99:31]
  wire  axi2wl_auto_xbar_in_penable; // @[AXI.scala 99:31]
  wire  axi2wl_auto_xbar_in_pwrite; // @[AXI.scala 99:31]
  wire [12:0] axi2wl_auto_xbar_in_paddr; // @[AXI.scala 99:31]
  wire [31:0] axi2wl_auto_xbar_in_pwdata; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_xbar_in_pstrb; // @[AXI.scala 99:31]
  wire  axi2wl_auto_xbar_in_pready; // @[AXI.scala 99:31]
  wire [31:0] axi2wl_auto_xbar_in_prdata; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_aw_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_aw_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_ini_out_aw_bits_id; // @[AXI.scala 99:31]
  wire [35:0] axi2wl_auto_axi_ini_out_aw_bits_addr; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_axi_ini_out_aw_bits_len; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_ini_out_aw_bits_size; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_ini_out_aw_bits_burst; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_aw_bits_lock; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_ini_out_aw_bits_cache; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_ini_out_aw_bits_prot; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_ini_out_aw_bits_qos; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_w_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_w_valid; // @[AXI.scala 99:31]
  wire [31:0] axi2wl_auto_axi_ini_out_w_bits_data; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_ini_out_w_bits_strb; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_w_bits_last; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_b_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_b_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_ini_out_b_bits_id; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_ini_out_b_bits_resp; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_ar_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_ar_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_ini_out_ar_bits_id; // @[AXI.scala 99:31]
  wire [35:0] axi2wl_auto_axi_ini_out_ar_bits_addr; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_axi_ini_out_ar_bits_len; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_ini_out_ar_bits_size; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_ini_out_ar_bits_burst; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_ar_bits_lock; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_ini_out_ar_bits_cache; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_ini_out_ar_bits_prot; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_ini_out_ar_bits_qos; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_r_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_r_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_ini_out_r_bits_id; // @[AXI.scala 99:31]
  wire [31:0] axi2wl_auto_axi_ini_out_r_bits_data; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_ini_out_r_bits_resp; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_ini_out_r_bits_last; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_aw_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_aw_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_tgt_in_aw_bits_id; // @[AXI.scala 99:31]
  wire [35:0] axi2wl_auto_axi_tgt_in_aw_bits_addr; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_axi_tgt_in_aw_bits_len; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_tgt_in_aw_bits_size; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_tgt_in_aw_bits_burst; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_aw_bits_lock; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_tgt_in_aw_bits_cache; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_tgt_in_aw_bits_prot; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_tgt_in_aw_bits_qos; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_w_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_w_valid; // @[AXI.scala 99:31]
  wire [31:0] axi2wl_auto_axi_tgt_in_w_bits_data; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_tgt_in_w_bits_strb; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_w_bits_last; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_b_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_b_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_tgt_in_b_bits_id; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_tgt_in_b_bits_resp; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_ar_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_ar_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_tgt_in_ar_bits_id; // @[AXI.scala 99:31]
  wire [35:0] axi2wl_auto_axi_tgt_in_ar_bits_addr; // @[AXI.scala 99:31]
  wire [7:0] axi2wl_auto_axi_tgt_in_ar_bits_len; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_tgt_in_ar_bits_size; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_tgt_in_ar_bits_burst; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_ar_bits_lock; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_tgt_in_ar_bits_cache; // @[AXI.scala 99:31]
  wire [2:0] axi2wl_auto_axi_tgt_in_ar_bits_prot; // @[AXI.scala 99:31]
  wire [3:0] axi2wl_auto_axi_tgt_in_ar_bits_qos; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_r_ready; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_r_valid; // @[AXI.scala 99:31]
  wire [11:0] axi2wl_auto_axi_tgt_in_r_bits_id; // @[AXI.scala 99:31]
  wire [31:0] axi2wl_auto_axi_tgt_in_r_bits_data; // @[AXI.scala 99:31]
  wire [1:0] axi2wl_auto_axi_tgt_in_r_bits_resp; // @[AXI.scala 99:31]
  wire  axi2wl_auto_axi_tgt_in_r_bits_last; // @[AXI.scala 99:31]
  wire  axi2wl_io_app_clk; // @[AXI.scala 99:31]
  wire  axi2wl_io_app_reset; // @[AXI.scala 99:31]
  wire  axi2wl_io_app_enable; // @[AXI.scala 99:31]
  wire  axi2wl_io_tx_clk; // @[AXI.scala 99:31]
  wire  axi2wl_io_tx_reset; // @[AXI.scala 99:31]
  wire  axi2wl_io_rx_clk; // @[AXI.scala 99:31]
  wire  axi2wl_io_rx_reset; // @[AXI.scala 99:31]
  wire  axi2wl_io_rx_crc_err; // @[AXI.scala 99:31]
  wire  gb2wl_clock; // @[GeneralBus.scala 89:30]
  wire  gb2wl_reset; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_wlink_generalbusgb_rx_in_sop; // @[GeneralBus.scala 89:30]
  wire [7:0] gb2wl_auto_wlink_generalbusgb_rx_in_data_id; // @[GeneralBus.scala 89:30]
  wire [15:0] gb2wl_auto_wlink_generalbusgb_rx_in_word_count; // @[GeneralBus.scala 89:30]
  wire [39:0] gb2wl_auto_wlink_generalbusgb_rx_in_data; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_wlink_generalbusgb_rx_in_valid; // @[GeneralBus.scala 89:30]
  wire [15:0] gb2wl_auto_wlink_generalbusgb_rx_in_crc; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_wlink_generalbusgb_tx_out_sop; // @[GeneralBus.scala 89:30]
  wire [7:0] gb2wl_auto_wlink_generalbusgb_tx_out_data_id; // @[GeneralBus.scala 89:30]
  wire [15:0] gb2wl_auto_wlink_generalbusgb_tx_out_word_count; // @[GeneralBus.scala 89:30]
  wire [39:0] gb2wl_auto_wlink_generalbusgb_tx_out_data; // @[GeneralBus.scala 89:30]
  wire [15:0] gb2wl_auto_wlink_generalbusgb_tx_out_crc; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_wlink_generalbusgb_tx_out_advance; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_in_psel; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_in_penable; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_in_pwrite; // @[GeneralBus.scala 89:30]
  wire [12:0] gb2wl_auto_in_paddr; // @[GeneralBus.scala 89:30]
  wire [31:0] gb2wl_auto_in_pwdata; // @[GeneralBus.scala 89:30]
  wire [3:0] gb2wl_auto_in_pstrb; // @[GeneralBus.scala 89:30]
  wire  gb2wl_auto_in_pready; // @[GeneralBus.scala 89:30]
  wire [31:0] gb2wl_auto_in_prdata; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_app_clk; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_app_reset; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_app_enable; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_tx_clk; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_tx_reset; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_rx_clk; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_rx_reset; // @[GeneralBus.scala 89:30]
  wire  gb2wl_io_rx_crc_err; // @[GeneralBus.scala 89:30]
  wire [31:0] gb2wl_bus_out_0; // @[GeneralBus.scala 89:30]
  wire [31:0] gb2wl_bore; // @[GeneralBus.scala 89:30]
  wire  tl2wl_clock; // @[TideLink.scala 105:30]
  wire  tl2wl_reset; // @[TideLink.scala 105:30]
  wire  tl2wl_auto_wlink_tidelinktl_rx_in_sop; // @[TideLink.scala 105:30]
  wire [7:0] tl2wl_auto_wlink_tidelinktl_rx_in_data_id; // @[TideLink.scala 105:30]
  wire [15:0] tl2wl_auto_wlink_tidelinktl_rx_in_word_count; // @[TideLink.scala 105:30]
  wire [55:0] tl2wl_auto_wlink_tidelinktl_rx_in_data; // @[TideLink.scala 105:30]
  wire  tl2wl_auto_wlink_tidelinktl_rx_in_valid; // @[TideLink.scala 105:30]
  wire [15:0] tl2wl_auto_wlink_tidelinktl_rx_in_crc; // @[TideLink.scala 105:30]
  /* mark_debug-disabled */ wire  tl2wl_auto_wlink_tidelinktl_tx_out_sop; // @[TideLink.scala 105:30]  SoC Labs ILA
  /* mark_debug-disabled */ wire [7:0] tl2wl_auto_wlink_tidelinktl_tx_out_data_id; // SoC Labs ILA
  wire [15:0] tl2wl_auto_wlink_tidelinktl_tx_out_word_count; // @[TideLink.scala 105:30]
  wire [55:0] tl2wl_auto_wlink_tidelinktl_tx_out_data; // @[TideLink.scala 105:30]
  wire [15:0] tl2wl_auto_wlink_tidelinktl_tx_out_crc; // @[TideLink.scala 105:30]
  /* mark_debug-disabled */ wire  tl2wl_auto_wlink_tidelinktl_tx_out_advance; // SoC Labs ILA
  wire  tl2wl_auto_in_psel; // @[TideLink.scala 105:30]
  wire  tl2wl_auto_in_penable; // @[TideLink.scala 105:30]
  wire  tl2wl_auto_in_pwrite; // @[TideLink.scala 105:30]
  wire [12:0] tl2wl_auto_in_paddr; // @[TideLink.scala 105:30]
  wire [31:0] tl2wl_auto_in_pwdata; // @[TideLink.scala 105:30]
  wire [3:0] tl2wl_auto_in_pstrb; // @[TideLink.scala 105:30]
  wire  tl2wl_auto_in_pready; // @[TideLink.scala 105:30]
  wire [31:0] tl2wl_auto_in_prdata; // @[TideLink.scala 105:30]
  wire  tl2wl_io_app_clk; // @[TideLink.scala 105:30]
  wire  tl2wl_io_app_reset; // @[TideLink.scala 105:30]
  wire  tl2wl_io_app_enable; // @[TideLink.scala 105:30]
  wire  tl2wl_io_tx_clk; // @[TideLink.scala 105:30]
  wire  tl2wl_io_tx_reset; // @[TideLink.scala 105:30]
  wire  tl2wl_io_rx_clk; // @[TideLink.scala 105:30]
  wire  tl2wl_io_rx_reset; // @[TideLink.scala 105:30]
  wire  tl2wl_io_rx_crc_err; // @[TideLink.scala 105:30]
  wire [49:0] tl2wl_tl_bus_out_0; // @[TideLink.scala 105:30]
  wire [49:0] tl2wl_bore_1; // @[TideLink.scala 105:30]
  wire  sp2wl_auto_rx_in_sop; // @[ShortPacket.scala 87:30]
  wire [7:0] sp2wl_auto_rx_in_data_id; // @[ShortPacket.scala 87:30]
  wire [15:0] sp2wl_auto_rx_in_word_count; // @[ShortPacket.scala 87:30]
  wire  sp2wl_auto_rx_in_valid; // @[ShortPacket.scala 87:30]
  wire  sp2wl_auto_tx_out_sop; // @[ShortPacket.scala 87:30]
  wire [7:0] sp2wl_auto_tx_out_data_id; // @[ShortPacket.scala 87:30]
  wire [15:0] sp2wl_auto_tx_out_word_count; // @[ShortPacket.scala 87:30]
  wire  sp2wl_auto_tx_out_advance; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_app_clk; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_app_reset; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_app_enable; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_tx_clk; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_tx_reset; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_rx_clk; // @[ShortPacket.scala 87:30]
  wire  sp2wl_io_rx_reset; // @[ShortPacket.scala 87:30]
  wire [25:0] sp2wl_sp_bus_out_0; // @[ShortPacket.scala 87:30]
  wire [25:0] sp2wl_bore_2; // @[ShortPacket.scala 87:30]
  wire  tx_link_clk_reset_wrs_io_clk; // @[Stdcell.scala 324:21]
  wire  tx_link_clk_reset_wrs_io_scan_ctrl; // @[Stdcell.scala 324:21]
  wire  tx_link_clk_reset_wrs_io_reset_in; // @[Stdcell.scala 324:21]
  wire  tx_link_clk_reset_wrs_io_reset_out; // @[Stdcell.scala 324:21]
  wire  rx_link_clk_reset_wrs_io_clk; // @[Stdcell.scala 324:21]
  wire  rx_link_clk_reset_wrs_io_scan_ctrl; // @[Stdcell.scala 324:21]
  wire  rx_link_clk_reset_wrs_io_reset_in; // @[Stdcell.scala 324:21]
  wire  rx_link_clk_reset_wrs_io_reset_out; // @[Stdcell.scala 324:21]
  wire  app_clk_scan_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  app_clk_scan_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  app_clk_scan_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  app_clk_scan_mux_io_o_z; // @[Stdcell.scala 149:21]
  wire  app_clk_reset_scan_wrs_io_clk; // @[Stdcell.scala 324:21]
  wire  app_clk_reset_scan_wrs_io_scan_ctrl; // @[Stdcell.scala 324:21]
  wire  app_clk_reset_scan_wrs_io_reset_in; // @[Stdcell.scala 324:21]
  wire  app_clk_reset_scan_wrs_io_reset_out; // @[Stdcell.scala 324:21]
  wire  ecc_corrected_sp_io_clk_in; // @[Wlink.scala 250:34]
  wire  ecc_corrected_sp_io_clk_in_reset; // @[Wlink.scala 250:34]
  wire  ecc_corrected_sp_io_data_in; // @[Wlink.scala 250:34]
  wire  ecc_corrected_sp_io_clk_out; // @[Wlink.scala 250:34]
  wire  ecc_corrected_sp_io_clk_out_reset; // @[Wlink.scala 250:34]
  wire  ecc_corrected_sp_io_data_out; // @[Wlink.scala 250:34]
  wire  ecc_corrupted_sp_io_clk_in; // @[Wlink.scala 258:34]
  wire  ecc_corrupted_sp_io_clk_in_reset; // @[Wlink.scala 258:34]
  wire  ecc_corrupted_sp_io_data_in; // @[Wlink.scala 258:34]
  wire  ecc_corrupted_sp_io_clk_out; // @[Wlink.scala 258:34]
  wire  ecc_corrupted_sp_io_clk_out_reset; // @[Wlink.scala 258:34]
  wire  ecc_corrupted_sp_io_data_out; // @[Wlink.scala 258:34]
  wire  muxed_pre_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  muxed_pre_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  muxed_pre_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  muxed_pre_mux_io_o_z; // @[Stdcell.scala 149:21]
  wire  ff2_demet_clock; // @[Stdcell.scala 58:23]
  wire  ff2_demet_reset; // @[Stdcell.scala 58:23]
  wire  ff2_demet_io_in; // @[Stdcell.scala 58:23]
  wire  ff2_demet_io_out; // @[Stdcell.scala 58:23]
  wire  ff2_demet_1_clock; // @[Stdcell.scala 58:23]
  wire  ff2_demet_1_reset; // @[Stdcell.scala 58:23]
  wire  ff2_demet_1_io_in; // @[Stdcell.scala 58:23]
  wire  ff2_demet_1_io_out; // @[Stdcell.scala 58:23]
  wire  ff2_demet_2_clock; // @[Stdcell.scala 58:23]
  wire  ff2_demet_2_reset; // @[Stdcell.scala 58:23]
  wire  ff2_demet_2_io_in; // @[Stdcell.scala 58:23]
  wire  ff2_demet_2_io_out; // @[Stdcell.scala 58:23]
  reg [7:0] swi_tx_lane_mask; // @[SW.scala 83:22]
  wire [1:0] _tx_pop_T_8 = swi_tx_lane_mask[0] + swi_tx_lane_mask[1]; // @[Bitwise.scala 47:55]
  wire [1:0] _tx_pop_T_10 = swi_tx_lane_mask[2] + swi_tx_lane_mask[3]; // @[Bitwise.scala 47:55]
  wire [2:0] _tx_pop_T_12 = _tx_pop_T_8 + _tx_pop_T_10; // @[Bitwise.scala 47:55]
  wire [1:0] _tx_pop_T_14 = swi_tx_lane_mask[4] + swi_tx_lane_mask[5]; // @[Bitwise.scala 47:55]
  wire [1:0] _tx_pop_T_16 = swi_tx_lane_mask[6] + swi_tx_lane_mask[7]; // @[Bitwise.scala 47:55]
  wire [2:0] _tx_pop_T_18 = _tx_pop_T_14 + _tx_pop_T_16; // @[Bitwise.scala 47:55]
  wire [3:0] tx_pop = _tx_pop_T_12 + _tx_pop_T_18; // @[Bitwise.scala 47:55]
  reg [7:0] out_prepend_swi_rx_lane_mask; // @[SW.scala 83:22]
  wire [1:0] _rx_pop_T_8 = out_prepend_swi_rx_lane_mask[0] + out_prepend_swi_rx_lane_mask[1]; // @[Bitwise.scala 47:55]
  wire [1:0] _rx_pop_T_10 = out_prepend_swi_rx_lane_mask[2] + out_prepend_swi_rx_lane_mask[3]; // @[Bitwise.scala 47:55]
  wire [2:0] _rx_pop_T_12 = _rx_pop_T_8 + _rx_pop_T_10; // @[Bitwise.scala 47:55]
  wire [1:0] _rx_pop_T_14 = out_prepend_swi_rx_lane_mask[4] + out_prepend_swi_rx_lane_mask[5]; // @[Bitwise.scala 47:55]
  wire [1:0] _rx_pop_T_16 = out_prepend_swi_rx_lane_mask[6] + out_prepend_swi_rx_lane_mask[7]; // @[Bitwise.scala 47:55]
  wire [2:0] _rx_pop_T_18 = _rx_pop_T_14 + _rx_pop_T_16; // @[Bitwise.scala 47:55]
  wire [3:0] rx_pop = _rx_pop_T_12 + _rx_pop_T_18; // @[Bitwise.scala 47:55]
  wire [3:0] _active_tx_lanes_T_2 = tx_pop - 4'h1; // @[Wlink.scala 168:77]
  wire [3:0] active_tx_lanes = tx_pop == 4'h0 ? 4'h0 : _active_tx_lanes_T_2; // @[Wlink.scala 168:48]
  wire [3:0] _active_rx_lanes_T_2 = rx_pop - 4'h1; // @[Wlink.scala 169:77]
  wire [3:0] active_rx_lanes = rx_pop == 4'h0 ? 4'h0 : _active_rx_lanes_T_2; // @[Wlink.scala 169:48]
  // SoC Labs lane-mask port stubs — placed after reg declarations to avoid
  // VCS forward-reference errors. Read-only mirror of the SWI lane-mask regs.
  assign tx_lane_mask_o = swi_tx_lane_mask;
  assign rx_lane_mask_o = out_prepend_swi_rx_lane_mask;
  // SoC Labs §9 auto-cal: surface the internal recovered link-rx clock and
  // 128-bit deserialised lane data as Wlink module outputs.
  assign phy_link_rx_rx_link_data_o = phy_link_rx_rx_link_data;
  assign phy_link_rx_rx_link_clk_o  = phy_link_rx_rx_link_clk;
  // -------------------------------------------------------------------
  // SoC Labs credit-path observability: 16-bit saturating ECC event
  // counters in the recovered RX link-clock domain. They count the
  // single-cycle llrx_io_ecc_corrupted / llrx_io_ecc_corrected pulses
  // (the key "is ECC failing every word?" indicators). Saturate at
  // 0xFFFF rather than wrap so a wedged link reads a pegged max.
  // Reset shares the RX-link-clock reset (rx_link_clk_reset_wrs).
  // axi_chiplet_controller.sv 2-flop-syncs the 32-bit snapshot into
  // apb_clk.
  // -------------------------------------------------------------------
  always @(posedge phy_link_rx_rx_link_clk or posedge rx_link_clk_reset_wrs_io_reset_out) begin
    if (rx_link_clk_reset_wrs_io_reset_out) begin
      obs_ecc_corrupted_cnt_q <= 16'h0;
      obs_ecc_corrected_cnt_q <= 16'h0;
      obs_sync_detected_cnt_q <= 16'h0;
    end else begin
      if (llrx_io_ecc_corrupted && (obs_ecc_corrupted_cnt_q != 16'hffff))
        obs_ecc_corrupted_cnt_q <= obs_ecc_corrupted_cnt_q + 16'h1;
      if (llrx_io_ecc_corrected && (obs_ecc_corrected_cnt_q != 16'hffff))
        obs_ecc_corrected_cnt_q <= obs_ecc_corrected_cnt_q + 16'h1;
      // SoC Labs 2026-06-08: SYNC-detected saturating counter. sync_detected is
      // a per-RX-word combinational level (held 1 for the whole word period the
      // assembled bus equals SYNC_WORD), and the RX framer samples one word per
      // phy_link_rx_rx_link_clk, so one increment per SYNC word seen. Saturates
      // at 0xFFFF; a HW read of >0 proves the RX assembles a COHERENT SYNC word
      // (i.e. the cross-lane deskew is aligning lanes), 0 means it never does.
      if (llrx_io_obs_sync_detected && (obs_sync_detected_cnt_q != 16'hffff))
        obs_sync_detected_cnt_q <= obs_sync_detected_cnt_q + 16'h1;
    end
  end
  // Surface the observability bundle as Wlink outputs (pure combinational
  // promotion of existing nets — downstream connections unchanged).
  assign obs_fcsm_state_o        = tl2wl_io_obs_fcsm_state;
  assign obs_cr_pkt_seen_rx_o    = tl2wl_io_obs_cr_pkt_seen_rx;
  assign obs_crack_pkt_seen_rx_o = tl2wl_io_obs_crack_pkt_seen_rx;
  assign obs_pkt_is_cr_pkt_o     = tl2wl_io_obs_pkt_is_cr_pkt;
  assign obs_pkt_is_crack_pkt_o  = tl2wl_io_obs_pkt_is_crack_pkt;
  // SoC Labs Bug-A FCSM observation 2026-06-02
  assign obs_a2l_replay_link_valid_o = tl2wl_io_obs_a2l_replay_link_valid;
  assign obs_fe_rx_credit_max_o      = tl2wl_io_obs_fe_rx_credit_max;
  assign obs_fe_rx_is_full_o         = tl2wl_io_obs_fe_rx_is_full;
  // SoC Labs Bug-A FCSM observation 2026-06-03
  assign obs_a2l_replay_app_valid_o  = tl2wl_io_obs_a2l_replay_app_valid;
  // SoC Labs V2 data-send observation 2026-06-21 (read-only fan-out)
  assign obs_a2l_replay_app_ready_o  = tl2wl_io_obs_a2l_replay_app_ready;
  assign obs_a2l_replay_link_empty_o = tl2wl_io_obs_a2l_replay_link_empty;
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 (read-only fan-out)
  assign obs_a2l_wptr_o              = tl2wl_io_obs_a2l_wptr;
  assign obs_a2l_synced_ack_o        = tl2wl_io_obs_a2l_synced_ack;
  assign obs_a2l_full_o              = tl2wl_io_obs_a2l_full;
  assign obs_a2l_enable_app_demet_o  = tl2wl_io_obs_a2l_enable_app_demet;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER obs 2026-06-21 (RO fan-out)
  assign obs_a2l_rreset_o            = tl2wl_io_obs_a2l_rreset;
  assign obs_a2l_rptr_o              = tl2wl_io_obs_a2l_rptr;
  // SoC Labs FC credit observation 2026-06-12
  assign obs_fe_rx_ptr_o             = tl2wl_io_obs_fe_rx_ptr;
  assign obs_llrx_state_o        = llrx_io_obs_state;
  assign obs_is_short_pkt_o      = llrx_io_obs_is_short_pkt;
  assign obs_is_long_pkt_o       = llrx_io_obs_is_long_pkt;
  assign obs_llrx_valid_o        = llrx_io_obs_valid;
  // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap, RO fan-out)
  assign obs_rxcap0_o            = llrx_io_obs_rxcap0;
  assign obs_rxcap1_o            = llrx_io_obs_rxcap1;
  assign obs_fcsmcap_o           = tl2wl_io_obs_fcsmcap;
  assign obs_ecc_corrupted_cnt_o = obs_ecc_corrupted_cnt_q;
  assign obs_ecc_corrected_cnt_o = obs_ecc_corrected_cnt_q;
  assign obs_sync_detected_cnt_o = obs_sync_detected_cnt_q;
  reg  out_prepend_swi_swreset; // @[SW.scala 83:22]
  wire  axi2wl_io_tx_reset_tx_link_clk_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 124:36 Wlink.scala 179:43]
  wire  swi_sb_reset_in_muxed = muxed_pre_mux_io_o_z; // @[Wlink.scala 172:49 SW.scala 374:11]
  reg  out_prepend_swi_lltx_enable; // @[SW.scala 83:22]
  reg  out_prepend_swi_crc_errors_int_en; // @[SW.scala 83:22]
  reg  crc_errors_w1c_1; // @[SW.scala 145:22]
  reg  out_prepend_ecc_corrupted_w1c; // @[SW.scala 145:22]
  reg  out_prepend_swi_ecc_corrupted_int_en; // @[SW.scala 83:22]
  wire  _interrupt_T_1 = out_prepend_ecc_corrupted_w1c & out_prepend_swi_ecc_corrupted_int_en; // @[Wlink.scala 269:46]
  wire  _interrupt_T_2 = out_prepend_swi_crc_errors_int_en & crc_errors_w1c_1 | _interrupt_T_1; // @[Wlink.scala 268:70]
  reg  out_prepend_ecc_corrected_w1c; // @[SW.scala 145:22]
  reg  out_prepend_swi_ecc_corrected_int_en; // @[SW.scala 83:22]
  wire  _interrupt_T_3 = out_prepend_ecc_corrected_w1c & out_prepend_swi_ecc_corrected_int_en; // @[Wlink.scala 270:46]
  reg  swi_enable; // @[SW.scala 83:22]
  reg  out_prepend_swi_lltx_enable_1; // @[SW.scala 83:22]
  reg [7:0] out_prepend_swi_short_packet_max; // @[SW.scala 83:22]
  reg [7:0] out_prepend_swi_preq_data_id; // @[SW.scala 83:22]
  reg [15:0] swi_delay_cycles; // @[SW.scala 83:22]
  reg [2:0] out_prepend_swi_num_preq_send; // @[SW.scala 83:22]
  reg [7:0] out_prepend_swi_cycles_post_preq; // @[SW.scala 83:22]
  reg  swi_sb_reset_in; // @[SW.scala 338:22]
  reg  out_prepend_swi_sb_reset_in_mux; // @[SW.scala 341:22]
  reg [7:0] swi_err_inj_data_id; // @[SW.scala 83:22]
  reg [7:0] out_prepend_swi_err_inj_byte; // @[SW.scala 83:22]
  reg [2:0] out_prepend_swi_err_inj_bit; // @[SW.scala 83:22]
  reg  out_prepend_swi_err_inj; // @[SW.scala 83:22]
  wire  crc_errors_0 = axi2wl_io_rx_crc_err; // @[Wlink.scala 131:39 AXI.scala 223:47]
  wire  crc_errors_1 = gb2wl_io_rx_crc_err; // @[Wlink.scala 131:39 GeneralBus.scala 127:46]
  wire  crc_errors_2 = tl2wl_io_rx_crc_err; // @[Wlink.scala 131:39 TideLink.scala 141:36]
  reg  crc_errors_w1c_ff3; // @[SW.scala 150:22]
  wire  crc_errors_w1c_set = ff2_demet_io_out & ~crc_errors_w1c_ff3; // @[SW.scala 153:19]
  reg  ecc_corrected_w1c_ff3; // @[SW.scala 150:22]
  wire  ecc_corrected_w1c_set = ff2_demet_1_io_out & ~ecc_corrected_w1c_ff3; // @[SW.scala 153:19]
  reg  ecc_corrupted_w1c_ff3; // @[SW.scala 150:22]
  wire  ecc_corrupted_w1c_set = ff2_demet_2_io_out & ~ecc_corrupted_w1c_ff3; // @[SW.scala 153:19]
  wire [1:0] readval_3 = txpstate_io_state_o; // @[SW.scala 199:25 SW.scala 200:15]
  wire [9:0] bundleIn_0_paddr = xbar_auto_out_0_paddr; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  wire [5:0] in_bits_index = bundleIn_0_paddr[7:2]; // @[RegisterNodes.scala 228:18 RegisterNodes.scala 237:19]
  wire [5:0] out_findex = in_bits_index & 6'h20; // @[RegisterNodes.scala 229:24]
  wire  _out_T = out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  bundleIn_0_pwrite = xbar_auto_out_0_pwrite; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  wire [3:0] bundleIn_0_pstrb = xbar_auto_out_0_pstrb; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  wire [3:0] in_bits_mask = bundleIn_0_pwrite ? bundleIn_0_pstrb : 4'hf; // @[RegisterNodes.scala 239:25]
  wire [7:0] out_frontMask_lo_lo = in_bits_mask[0] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [7:0] out_frontMask_lo_hi = in_bits_mask[1] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [7:0] out_frontMask_hi_lo = in_bits_mask[2] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [7:0] out_frontMask_hi_hi = in_bits_mask[3] ? 8'hff : 8'h0; // @[Bitwise.scala 72:12]
  wire [31:0] out_frontMask = {out_frontMask_hi_hi,out_frontMask_hi_lo,out_frontMask_lo_hi,out_frontMask_lo_lo}; // @[Cat.scala 30:58]
  wire  bundleIn_0_psel = xbar_auto_out_0_psel; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  reg  taken; // @[RegisterNodes.scala 232:24]
  wire  in_valid = bundleIn_0_psel & ~taken; // @[RegisterNodes.scala 241:26]
  wire  bundleIn_0_penable = xbar_auto_out_0_penable; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  wire  in_bits_read = ~bundleIn_0_pwrite; // @[RegisterNodes.scala 236:22]
  wire  out_oindex_hi_hi_hi = in_bits_index[4]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_hi_hi_lo = in_bits_index[3]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_hi_lo = in_bits_index[2]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_lo_hi = in_bits_index[1]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_lo_lo = in_bits_index[0]; // @[RegisterNodes.scala 229:24]
  wire [4:0] out_oindex = {out_oindex_hi_hi_hi,out_oindex_hi_hi_lo,out_oindex_hi_lo,out_oindex_lo_hi,out_oindex_lo_lo}; // @[Cat.scala 30:58]
  wire [31:0] _out_frontSel_T = 32'h1 << out_oindex; // @[OneHot.scala 58:35]
  wire [31:0] bundleIn_0_pwdata = xbar_auto_out_0_pwdata; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  wire  out_wimask_2 = &out_frontMask[7:0]; // @[RegisterNodes.scala 229:24]
  wire  out_frontSel_5 = _out_frontSel_T[5]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_2 = in_valid & bundleIn_0_penable & ~in_bits_read & out_frontSel_5 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_2 = out_wivalid_2 & out_wimask_2; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_3 = &out_frontMask[15:8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_3 = out_wivalid_2 & out_wimask_3; // @[RegisterNodes.scala 229:24]
  wire [15:0] out_prepend_1 = {out_prepend_swi_rx_lane_mask,swi_tx_lane_mask}; // @[Cat.scala 30:58]
  wire  out_wimask_4 = &out_frontMask[0]; // @[RegisterNodes.scala 229:24]
  wire  out_frontSel_13 = _out_frontSel_T[13]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_5 = in_valid & bundleIn_0_penable & ~in_bits_read & out_frontSel_13 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_5 = out_wivalid_5 & out_wimask_4; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_6 = &out_frontMask[1]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_6 = out_wivalid_5 & out_wimask_6; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_7 = &out_frontMask[2]; // @[RegisterNodes.scala 229:24]
  wire  out_prepend_hi_2 = llrx_io_in_error_state; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_wimask_8 = &out_frontMask[3]; // @[RegisterNodes.scala 229:24]
  wire  out_prepend_hi_3 = phy_link_tx_tx_ready; // @[SW.scala 199:25 SW.scala 200:15]
  wire [4:0] out_prepend_5 = {1'h1,out_prepend_hi_3,out_prepend_hi_2,out_prepend_swi_sb_reset_in_mux,swi_sb_reset_in}; // @[Cat.scala 30:58]
  wire  out_frontSel_2 = _out_frontSel_T[2]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_10 = in_valid & bundleIn_0_penable & ~in_bits_read & out_frontSel_2 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_10 = out_wivalid_10 & out_wimask_4; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_11 = out_wivalid_10 & out_wimask_6; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_12 = out_wivalid_10 & out_wimask_7; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_13 = out_wivalid_10 & out_wimask_8; // @[RegisterNodes.scala 229:24]
  wire [4:0] out_prepend_9 = {1'h0,out_prepend_swi_swreset,out_prepend_swi_lltx_enable_1,out_prepend_swi_lltx_enable,
    swi_enable}; // @[Cat.scala 30:58]
  wire [7:0] out_prepend_lo_10 = {{3'd0}, out_prepend_9}; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_15 = out_wivalid_10 & out_wimask_3; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_16 = &out_frontMask[23:16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_16 = out_wivalid_10 & out_wimask_16; // @[RegisterNodes.scala 229:24]
  wire [23:0] out_prepend_11 = {out_prepend_swi_preq_data_id,out_prepend_swi_short_packet_max,out_prepend_lo_10}; // @[Cat.scala 30:58]
  wire  out_wimask_18 = &out_frontMask[15:0]; // @[RegisterNodes.scala 229:24]
  wire  out_frontSel_12 = _out_frontSel_T[12]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_18 = in_valid & bundleIn_0_penable & ~in_bits_read & out_frontSel_12 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_18 = out_wivalid_18 & out_wimask_18; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_19 = &out_frontMask[18:16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_19 = out_wivalid_18 & out_wimask_19; // @[RegisterNodes.scala 229:24]
  wire [19:0] out_prepend_13 = {1'h0,out_prepend_swi_num_preq_send,swi_delay_cycles}; // @[Cat.scala 30:58]
  wire [23:0] out_prepend_lo_14 = {{4'd0}, out_prepend_13}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_21 = &out_frontMask[31:24]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_21 = out_wivalid_18 & out_wimask_21; // @[RegisterNodes.scala 229:24]
  wire [31:0] out_prepend_14 = {out_prepend_swi_cycles_post_preq,out_prepend_lo_14}; // @[Cat.scala 30:58]
  wire  readval_4 = txpstate_io_tx_en; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_frontSel_16 = _out_frontSel_T[16]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_23 = in_valid & bundleIn_0_penable & ~in_bits_read & out_frontSel_16 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_23 = out_wivalid_23 & out_wimask_4; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_24 = out_wivalid_23 & out_wimask_6; // @[RegisterNodes.scala 229:24]
  wire [2:0] out_prepend_16 = {1'h0,out_prepend_swi_crc_errors_int_en,crc_errors_w1c_1}; // @[Cat.scala 30:58]
  wire [7:0] out_prepend_lo_17 = {{5'd0}, out_prepend_16}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_26 = &out_frontMask[8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_26 = out_wivalid_23 & out_wimask_26; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_27 = &out_frontMask[9]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_27 = out_wivalid_23 & out_wimask_27; // @[RegisterNodes.scala 229:24]
  wire [10:0] out_prepend_19 = {1'h0,out_prepend_swi_ecc_corrected_int_en,out_prepend_ecc_corrected_w1c,
    out_prepend_lo_17}; // @[Cat.scala 30:58]
  wire [15:0] out_prepend_lo_20 = {{5'd0}, out_prepend_19}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_29 = &out_frontMask[16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_29 = out_wivalid_23 & out_wimask_29; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_30 = &out_frontMask[17]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_30 = out_wivalid_23 & out_wimask_30; // @[RegisterNodes.scala 229:24]
  wire [17:0] out_prepend_21 = {out_prepend_swi_ecc_corrupted_int_en,out_prepend_ecc_corrupted_w1c,out_prepend_lo_20}; // @[Cat.scala 30:58]
  wire [7:0] out_prepend_22 = {active_rx_lanes,active_tx_lanes}; // @[Cat.scala 30:58]
  wire  out_frontSel_15 = _out_frontSel_T[15]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_33 = in_valid & bundleIn_0_penable & ~in_bits_read & out_frontSel_15 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_33 = out_wivalid_33 & out_wimask_2; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_34 = out_wivalid_33 & out_wimask_3; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_35 = out_wivalid_33 & out_wimask_19; // @[RegisterNodes.scala 229:24]
  wire [19:0] out_prepend_25 = {1'h0,out_prepend_swi_err_inj_bit,out_prepend_swi_err_inj_byte,swi_err_inj_data_id}; // @[Cat.scala 30:58]
  wire [23:0] out_prepend_lo_26 = {{4'd0}, out_prepend_25}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_37 = &out_frontMask[24]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_37 = out_wivalid_33 & out_wimask_37; // @[RegisterNodes.scala 229:24]
  wire [24:0] out_prepend_26 = {out_prepend_swi_err_inj,out_prepend_lo_26}; // @[Cat.scala 30:58]
  wire  _out_out_bits_data_T = 5'h0 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_1 = 5'h1 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_2 = 5'h2 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_3 = 5'h4 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_4 = 5'h5 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_5 = 5'hc == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_6 = 5'hd == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_7 = 5'hf == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_8 = 5'h10 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_9 = 5'h11 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_10 = 5'h12 == out_oindex; // @[Conditional.scala 37:30]
  wire  _GEN_148 = _out_out_bits_data_T_10 ? _out_T : 1'h1; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_149 = _out_out_bits_data_T_9 ? _out_T : _GEN_148; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_150 = _out_out_bits_data_T_8 ? _out_T : _GEN_149; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_151 = _out_out_bits_data_T_7 ? _out_T : _GEN_150; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_152 = _out_out_bits_data_T_6 ? _out_T : _GEN_151; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_153 = _out_out_bits_data_T_5 ? _out_T : _GEN_152; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_154 = _out_out_bits_data_T_4 ? _out_T : _GEN_153; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_155 = _out_out_bits_data_T_3 ? _out_T : _GEN_154; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_156 = _out_out_bits_data_T_2 ? _out_T : _GEN_155; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_157 = _out_out_bits_data_T_1 ? _out_T : _GEN_156; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  out_out_bits_data_out = _out_out_bits_data_T ? _out_T : _GEN_157; // @[Conditional.scala 40:58 MuxLiteral.scala 53:32]
  wire  _GEN_159 = _out_out_bits_data_T_10 & readval_4; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [1:0] _GEN_160 = _out_out_bits_data_T_9 ? readval_3 : {{1'd0}, _GEN_159}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [17:0] _GEN_161 = _out_out_bits_data_T_8 ? out_prepend_21 : {{16'd0}, _GEN_160}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [24:0] _GEN_162 = _out_out_bits_data_T_7 ? out_prepend_26 : {{7'd0}, _GEN_161}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [24:0] _GEN_163 = _out_out_bits_data_T_6 ? {{20'd0}, out_prepend_5} : _GEN_162; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] _GEN_164 = _out_out_bits_data_T_5 ? out_prepend_14 : {{7'd0}, _GEN_163}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] _GEN_165 = _out_out_bits_data_T_4 ? {{16'd0}, out_prepend_1} : _GEN_164; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] _GEN_166 = _out_out_bits_data_T_3 ? {{24'd0}, out_prepend_22} : _GEN_165; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] _GEN_167 = _out_out_bits_data_T_2 ? {{8'd0}, out_prepend_11} : _GEN_166; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] _GEN_168 = _out_out_bits_data_T_1 ? 32'h1 : _GEN_167; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] out_out_bits_data_out_1 = _out_out_bits_data_T ? 32'h88 : _GEN_168; // @[Conditional.scala 40:58 MuxLiteral.scala 53:32]
  wire  _T_32 = bundleIn_0_penable & in_valid; // @[Decoupled.scala 40:37]
  wire  _GEN_170 = _T_32 | taken; // @[RegisterNodes.scala 233:23 RegisterNodes.scala 233:31 RegisterNodes.scala 232:24]
  wire [31:0] gbus_in_wire = generalbus_in; // @[GeneralBus.scala 58:35 GeneralBus.scala 65:24]
  wire [49:0] tl_in_wire = tidelink_in; // @[TideLink.scala 74:33 TideLink.scala 79:22]
  wire [25:0] sp_in_wire = ptp_in; // @[ShortPacket.scala 58:33 ShortPacket.scala 63:22]
  APBFanout xbar ( // @[Wlink.scala 84:27]
    .auto_in_psel(xbar_auto_in_psel),
    .auto_in_penable(xbar_auto_in_penable),
    .auto_in_pwrite(xbar_auto_in_pwrite),
    .auto_in_paddr(xbar_auto_in_paddr),
    .auto_in_pwdata(xbar_auto_in_pwdata),
    .auto_in_pstrb(xbar_auto_in_pstrb),
    .auto_in_pready(xbar_auto_in_pready),
    .auto_in_prdata(xbar_auto_in_prdata),
    .auto_out_4_psel(xbar_auto_out_4_psel),
    .auto_out_4_penable(xbar_auto_out_4_penable),
    .auto_out_4_pwrite(xbar_auto_out_4_pwrite),
    .auto_out_4_paddr(xbar_auto_out_4_paddr),
    .auto_out_4_pwdata(xbar_auto_out_4_pwdata),
    .auto_out_4_pstrb(xbar_auto_out_4_pstrb),
    .auto_out_4_pready(xbar_auto_out_4_pready),
    .auto_out_4_prdata(xbar_auto_out_4_prdata),
    .auto_out_3_psel(xbar_auto_out_3_psel),
    .auto_out_3_penable(xbar_auto_out_3_penable),
    .auto_out_3_pwrite(xbar_auto_out_3_pwrite),
    .auto_out_3_paddr(xbar_auto_out_3_paddr),
    .auto_out_3_pwdata(xbar_auto_out_3_pwdata),
    .auto_out_3_pstrb(xbar_auto_out_3_pstrb),
    .auto_out_3_pready(xbar_auto_out_3_pready),
    .auto_out_3_prdata(xbar_auto_out_3_prdata),
    .auto_out_2_psel(xbar_auto_out_2_psel),
    .auto_out_2_penable(xbar_auto_out_2_penable),
    .auto_out_2_pwrite(xbar_auto_out_2_pwrite),
    .auto_out_2_paddr(xbar_auto_out_2_paddr),
    .auto_out_2_pwdata(xbar_auto_out_2_pwdata),
    .auto_out_2_pstrb(xbar_auto_out_2_pstrb),
    .auto_out_2_pready(xbar_auto_out_2_pready),
    .auto_out_2_prdata(xbar_auto_out_2_prdata),
    .auto_out_1_psel(xbar_auto_out_1_psel),
    .auto_out_1_penable(xbar_auto_out_1_penable),
    .auto_out_1_pwrite(xbar_auto_out_1_pwrite),
    .auto_out_1_pwdata(xbar_auto_out_1_pwdata),
    .auto_out_1_pstrb(xbar_auto_out_1_pstrb),
    .auto_out_1_pready(xbar_auto_out_1_pready),
    .auto_out_1_prdata(xbar_auto_out_1_prdata),
    .auto_out_0_psel(xbar_auto_out_0_psel),
    .auto_out_0_penable(xbar_auto_out_0_penable),
    .auto_out_0_pwrite(xbar_auto_out_0_pwrite),
    .auto_out_0_paddr(xbar_auto_out_0_paddr),
    .auto_out_0_pwdata(xbar_auto_out_0_pwdata),
    .auto_out_0_pstrb(xbar_auto_out_0_pstrb),
    .auto_out_0_pready(xbar_auto_out_0_pready),
    .auto_out_0_prdata(xbar_auto_out_0_prdata)
  );
  WlinkGPIOPHY #(.USE_CLKBUF(USE_CLKBUF), .USE_T3A(USE_T3A)) phy ( // @[Wlink.scala 87:27]
    .clock(phy_clock),
    .reset(phy_reset),
    .auto_in_psel(phy_auto_in_psel),
    .auto_in_penable(phy_auto_in_penable),
    .auto_in_pwrite(phy_auto_in_pwrite),
    .auto_in_pwdata(phy_auto_in_pwdata),
    .auto_in_pstrb(phy_auto_in_pstrb),
    .auto_in_pready(phy_auto_in_pready),
    .auto_in_prdata(phy_auto_in_prdata),
    .scan_mode(phy_scan_mode),
    .scan_asyncrst_ctrl(phy_scan_asyncrst_ctrl),
    .scan_clk(phy_scan_clk),
    .scan_out(phy_scan_out),
    .por_reset(phy_por_reset),
    .link_tx_tx_en(phy_link_tx_tx_en),
`ifndef TIDELINK_PHY_V2
    .link_tx_tx_idle(lltx_io_link_idle), // SoC Labs 2026-06-06: LL idle -> PHY gates SYNC insertion to inter-packet slots (V1 fork only; V2 fork has no such port)
`endif
    .link_tx_tx_ready(phy_link_tx_tx_ready),
    .link_tx_tx_link_data(phy_link_tx_tx_link_data),
    .link_tx_tx_lane_mask(phy_link_tx_tx_lane_mask),
    .link_tx_tx_link_clk(phy_link_tx_tx_link_clk),
    .link_rx_rx_link_data(phy_link_rx_rx_link_data),
    .link_rx_rx_lane_mask(phy_link_rx_rx_lane_mask),
    .link_rx_rx_link_clk(phy_link_rx_rx_link_clk),
    .pad_clk_tx(phy_pad_clk_tx),
    .pad_tx_0(phy_pad_tx_0),
    .pad_tx_1(phy_pad_tx_1),
    .pad_tx_2(phy_pad_tx_2),
    .pad_tx_3(phy_pad_tx_3),
    .pad_tx_4(phy_pad_tx_4),
    .pad_tx_5(phy_pad_tx_5),
    .pad_tx_6(phy_pad_tx_6),
    .pad_tx_7(phy_pad_tx_7),
    .pad_clk_rx(phy_pad_clk_rx),
    .pad_rx_0(phy_pad_rx_0),
    .pad_rx_1(phy_pad_rx_1),
    .pad_rx_2(phy_pad_rx_2),
    .pad_rx_3(phy_pad_rx_3),
    .pad_rx_4(phy_pad_rx_4),
    .pad_rx_5(phy_pad_rx_5),
    .pad_rx_6(phy_pad_rx_6),
    .pad_rx_7(phy_pad_rx_7),
    .user_hsclk(phy_user_hsclk),
    // SoC Labs §9: alignment-control inputs. INTERIM — drive directly from
    // module-port inputs (tied to 0 in chiplet controller). The Wlink-internal
    // APB regs at offsets 0x244/0x248 are disabled until decode issue resolved.
    .swi_bit_slip_in(swi_bit_slip_in),
    .swi_training_mode_in(swi_training_mode_in),
`ifdef TIDELINK_PHY_V2
    // S3 PHY swap: V2 fork adds the word-pin pair (FIX-R) and (2026-06-15) the
    // DEFAULT-OFF SYNC-insert re-hunt beacon. The V2 WlinkGPIOPHY fork now
    // exposes link_tx_tx_idle (mirroring the V1 connection at line ~1181) so the
    // LL inter-packet idle gates SYNC insertion to idle slots only, plus the
    // APB enable strap swi_sync_insert_en (DEFAULT 0 -> bit-identical TX).
    .link_tx_tx_idle(lltx_io_link_idle),       // SYNC-insert: LL inter-packet idle gate (V2)
    .swi_sync_insert_en(swi_sync_insert_en_in),// SYNC-insert: APB feature enable (DEFAULT 0)
    .swi_sync_force_always(swi_sync_force_always_in), // PART2 gate fix: drop idle term (DEFAULT 0)
    // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 1/2/3): SW
    // LANE_MASK strap in, mask-aware per-lane detect outputs out.
    .sync_lane_mask_in(swi_sync_lane_mask_in), // PART3 SW LANE_MASK strap (default 0xFF)
    .sync_tol_in(swi_sync_tol_in),             // 2026-06-17 Hamming tolerance (0=exact)
    .sync_seen_cnt(obs_sync_seen_cnt_o),       // PART1 obs: mask-aware sat. count
    .sync_seen_lane(obs_sync_seen_lane_o),     // PART1 obs: per-lane sticky vector
    .sync_seen_pulse(phy_io_sync_seen_pulse),  // PART2 robust re-hunt source
    // rawobs: BEST-MATCH raw post-deskew word + per-lane carried-slice map.
    .dbg_raw_word(obs_dbg_raw_word_o),         // rawobs: best-match raw word
    .dbg_lane_any_match(obs_dbg_lane_any_match_o), // rawobs: fixed-pos match vector
    .dbg_best_popcount(obs_dbg_best_popcount_o),   // rawobs: popcount of that vector
    .dbg_slice_idx(obs_dbg_slice_idx_o),       // rawobs: per-lane carried-slice map
    .swi_phase_offset_in(swi_phase_offset_in),
    .swi_word_pin_in(swi_word_pin_in),
    .swi_word_pin_auto_en(swi_word_pin_auto_en),
    // SoC Labs V2 epoch-anchor obs 2026-06-14: route the WlinkGPIOPHY anchor
    // engagement state out to the chiplet controller -> SWI_EPOCH_STATUS.
    .epoch_anchored(obs_epoch_anchored_o),
    .epoch_span(obs_epoch_span_o),
    // SoC Labs SYNC-insert TX obs 2026-06-15 (PART 1): route the PHY's TX-side
    // SYNC-insert probe out to the chiplet controller -> SoC MMIO 0x4403_2120.
    .tx_sync_ins_cnt(obs_tx_sync_ins_cnt_o),
    .tx_link_idle_level(obs_tx_link_idle_level_o),
    .tx_training_level(obs_tx_training_level_o),
    // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override (perlane-wp)
    .sync_obs_clr_in(swi_sync_obs_clr_in),         // clearable-oracle clear pulse
    .sync_lane_live(obs_sync_lane_live_o),         // live per-lane match vector
    .word_pin_ovr_in(swi_word_pin_ovr_in),         // 8x4b per-lane window pin
    .word_pin_ovr_en_in(swi_word_pin_ovr_en_in),   // 8b per-lane override enable
    .sync_seen_vec(obs_sync_seen_vec_o),           // sticky-poison: per-lane deskew sync_seen
    .sync_dist_vec(obs_sync_dist_vec_o),           // winscan metric: per-lane SYNC Hamming distance
    .anchor_verified(obs_anchor_verified_o)        // R-A anchor-verify: engaged-anchor exact-beacon sticky
`else
    .swi_phase_offset_in(swi_phase_offset_in)
`endif
  );
  WlinkTxRouter txrouter ( // @[Wlink.scala 89:27]
    .clock(txrouter_clock),
    .reset(txrouter_reset),
    .auto_in_7_sop(txrouter_auto_in_7_sop),
    .auto_in_7_data_id(txrouter_auto_in_7_data_id),
    .auto_in_7_word_count(txrouter_auto_in_7_word_count),
    .auto_in_7_advance(txrouter_auto_in_7_advance),
    .auto_in_6_sop(txrouter_auto_in_6_sop),
    .auto_in_6_data_id(txrouter_auto_in_6_data_id),
    .auto_in_6_word_count(txrouter_auto_in_6_word_count),
    .auto_in_6_data(txrouter_auto_in_6_data),
    .auto_in_6_crc(txrouter_auto_in_6_crc),
    .auto_in_6_advance(txrouter_auto_in_6_advance),
    .auto_in_5_sop(txrouter_auto_in_5_sop),
    .auto_in_5_data_id(txrouter_auto_in_5_data_id),
    .auto_in_5_word_count(txrouter_auto_in_5_word_count),
    .auto_in_5_data(txrouter_auto_in_5_data),
    .auto_in_5_crc(txrouter_auto_in_5_crc),
    .auto_in_5_advance(txrouter_auto_in_5_advance),
    .auto_in_4_sop(txrouter_auto_in_4_sop),
    .auto_in_4_data_id(txrouter_auto_in_4_data_id),
    .auto_in_4_word_count(txrouter_auto_in_4_word_count),
    .auto_in_4_data(txrouter_auto_in_4_data),
    .auto_in_4_crc(txrouter_auto_in_4_crc),
    .auto_in_4_advance(txrouter_auto_in_4_advance),
    .auto_in_3_sop(txrouter_auto_in_3_sop),
    .auto_in_3_data_id(txrouter_auto_in_3_data_id),
    .auto_in_3_word_count(txrouter_auto_in_3_word_count),
    .auto_in_3_data(txrouter_auto_in_3_data),
    .auto_in_3_crc(txrouter_auto_in_3_crc),
    .auto_in_3_advance(txrouter_auto_in_3_advance),
    .auto_in_2_sop(txrouter_auto_in_2_sop),
    .auto_in_2_data_id(txrouter_auto_in_2_data_id),
    .auto_in_2_word_count(txrouter_auto_in_2_word_count),
    .auto_in_2_data(txrouter_auto_in_2_data),
    .auto_in_2_crc(txrouter_auto_in_2_crc),
    .auto_in_2_advance(txrouter_auto_in_2_advance),
    .auto_in_1_sop(txrouter_auto_in_1_sop),
    .auto_in_1_data_id(txrouter_auto_in_1_data_id),
    .auto_in_1_word_count(txrouter_auto_in_1_word_count),
    .auto_in_1_data(txrouter_auto_in_1_data),
    .auto_in_1_crc(txrouter_auto_in_1_crc),
    .auto_in_1_advance(txrouter_auto_in_1_advance),
    .auto_in_0_sop(txrouter_auto_in_0_sop),
    .auto_in_0_data_id(txrouter_auto_in_0_data_id),
    .auto_in_0_word_count(txrouter_auto_in_0_word_count),
    .auto_in_0_data(txrouter_auto_in_0_data),
    .auto_in_0_crc(txrouter_auto_in_0_crc),
    .auto_in_0_advance(txrouter_auto_in_0_advance),
    .auto_out_sop(txrouter_auto_out_sop),
    .auto_out_data_id(txrouter_auto_out_data_id),
    .auto_out_word_count(txrouter_auto_out_word_count),
    .auto_out_data(txrouter_auto_out_data),
    .auto_out_crc(txrouter_auto_out_crc),
    .auto_out_advance(txrouter_auto_out_advance),
    .io_enable(txrouter_io_enable)
  );
  WlinkTxPstateCtrl txpstate ( // @[Wlink.scala 90:27]
    .clock(txpstate_clock),
    .reset(txpstate_reset),
    .auto_in_sop(txpstate_auto_in_sop),
    .auto_in_data_id(txpstate_auto_in_data_id),
    .auto_in_word_count(txpstate_auto_in_word_count),
    .auto_in_data(txpstate_auto_in_data),
    .auto_in_crc(txpstate_auto_in_crc),
    .auto_in_advance(txpstate_auto_in_advance),
    .auto_out_sop(txpstate_auto_out_sop),
    .auto_out_data_id(txpstate_auto_out_data_id),
    .auto_out_word_count(txpstate_auto_out_word_count),
    .auto_out_data(txpstate_auto_out_data),
    .auto_out_crc(txpstate_auto_out_crc),
    .auto_out_advance(txpstate_auto_out_advance),
    .io_swi_delay_cycles(txpstate_io_swi_delay_cycles),
    .io_swi_num_preq_send(txpstate_io_swi_num_preq_send),
    .io_swi_preq_data_id(txpstate_io_swi_preq_data_id),
    .io_swi_cycles_post_preq(txpstate_io_swi_cycles_post_preq),
    .io_tx_ready(txpstate_io_tx_ready),
    .io_tx_en(txpstate_io_tx_en),
    .io_state_o(txpstate_io_state_o)
  );
  WlinkRxRouter rxrouter ( // @[Wlink.scala 92:27]
    .auto_in_sop(rxrouter_auto_in_sop),
    .auto_in_data_id(rxrouter_auto_in_data_id),
    .auto_in_word_count(rxrouter_auto_in_word_count),
    .auto_in_data(rxrouter_auto_in_data),
    .auto_in_valid(rxrouter_auto_in_valid),
    .auto_in_crc(rxrouter_auto_in_crc),
    .auto_out_8_sop(rxrouter_auto_out_8_sop),
    .auto_out_8_data_id(rxrouter_auto_out_8_data_id),
    .auto_out_8_word_count(rxrouter_auto_out_8_word_count),
    .auto_out_8_valid(rxrouter_auto_out_8_valid),
    .auto_out_7_sop(rxrouter_auto_out_7_sop),
    .auto_out_7_data_id(rxrouter_auto_out_7_data_id),
    .auto_out_7_word_count(rxrouter_auto_out_7_word_count),
    .auto_out_7_data(rxrouter_auto_out_7_data),
    .auto_out_7_valid(rxrouter_auto_out_7_valid),
    .auto_out_7_crc(rxrouter_auto_out_7_crc),
    .auto_out_6_sop(rxrouter_auto_out_6_sop),
    .auto_out_6_data_id(rxrouter_auto_out_6_data_id),
    .auto_out_6_word_count(rxrouter_auto_out_6_word_count),
    .auto_out_6_data(rxrouter_auto_out_6_data),
    .auto_out_6_valid(rxrouter_auto_out_6_valid),
    .auto_out_6_crc(rxrouter_auto_out_6_crc),
    .auto_out_5_sop(rxrouter_auto_out_5_sop),
    .auto_out_5_data_id(rxrouter_auto_out_5_data_id),
    .auto_out_5_word_count(rxrouter_auto_out_5_word_count),
    .auto_out_5_data(rxrouter_auto_out_5_data),
    .auto_out_5_valid(rxrouter_auto_out_5_valid),
    .auto_out_5_crc(rxrouter_auto_out_5_crc),
    .auto_out_4_sop(rxrouter_auto_out_4_sop),
    .auto_out_4_data_id(rxrouter_auto_out_4_data_id),
    .auto_out_4_word_count(rxrouter_auto_out_4_word_count),
    .auto_out_4_data(rxrouter_auto_out_4_data),
    .auto_out_4_valid(rxrouter_auto_out_4_valid),
    .auto_out_4_crc(rxrouter_auto_out_4_crc),
    .auto_out_3_sop(rxrouter_auto_out_3_sop),
    .auto_out_3_data_id(rxrouter_auto_out_3_data_id),
    .auto_out_3_word_count(rxrouter_auto_out_3_word_count),
    .auto_out_3_data(rxrouter_auto_out_3_data),
    .auto_out_3_valid(rxrouter_auto_out_3_valid),
    .auto_out_3_crc(rxrouter_auto_out_3_crc),
    .auto_out_2_sop(rxrouter_auto_out_2_sop),
    .auto_out_2_data_id(rxrouter_auto_out_2_data_id),
    .auto_out_2_word_count(rxrouter_auto_out_2_word_count),
    .auto_out_2_data(rxrouter_auto_out_2_data),
    .auto_out_2_valid(rxrouter_auto_out_2_valid),
    .auto_out_2_crc(rxrouter_auto_out_2_crc),
    .auto_out_1_sop(rxrouter_auto_out_1_sop),
    .auto_out_1_data_id(rxrouter_auto_out_1_data_id),
    .auto_out_1_word_count(rxrouter_auto_out_1_word_count),
    .auto_out_1_data(rxrouter_auto_out_1_data),
    .auto_out_1_valid(rxrouter_auto_out_1_valid),
    .auto_out_1_crc(rxrouter_auto_out_1_crc)
  );
  WlinkTxLinkLayer lltx ( // @[Wlink.scala 95:27]
    .clock(lltx_clock),
    .reset(lltx_reset),
    .auto_in_sop(lltx_auto_in_sop),
    .auto_in_data_id(lltx_auto_in_data_id),
    .auto_in_word_count(lltx_auto_in_word_count),
    .auto_in_data(lltx_auto_in_data),
    .auto_in_crc(lltx_auto_in_crc),
    .auto_in_advance(lltx_auto_in_advance),
    .io_enable(lltx_io_enable),
    .io_swi_short_packet_max(lltx_io_swi_short_packet_max),
    .io_active_lanes(lltx_io_active_lanes),
    .io_lane_mask(lltx_io_lane_mask),
    .io_swi_err_inj(lltx_io_swi_err_inj),
    .io_swi_err_inj_data_id(lltx_io_swi_err_inj_data_id),
    .io_swi_err_inj_byte(lltx_io_swi_err_inj_byte),
    .io_swi_err_inj_bit(lltx_io_swi_err_inj_bit),
    .io_ll_tx_valid(lltx_io_ll_tx_valid),
    .io_link_data(lltx_io_link_data),
    .io_link_idle(lltx_io_link_idle)
  );
  WlinkRxLinkLayer llrx ( // @[Wlink.scala 96:27]
    .clock(llrx_clock),
    .reset(llrx_reset),
    .auto_out_sop(llrx_auto_out_sop),
    .auto_out_data_id(llrx_auto_out_data_id),
    .auto_out_word_count(llrx_auto_out_word_count),
    .auto_out_data(llrx_auto_out_data),
    .auto_out_valid(llrx_auto_out_valid),
    .auto_out_crc(llrx_auto_out_crc),
    .io_enable(llrx_io_enable),
    .io_swi_short_packet_max(llrx_io_swi_short_packet_max),
    // SoC Labs L5 whitelist (tdif-10, 2026-05-25): bringup-packet data_id
    // gate for first_short_pkt_seen. Hard-tied to FCSM compile-time defaults
    // (WlinkGenericFCSM_6.v sets these on reset and SW never rewrites them
    // before LL bringup completes). If a future revision allows runtime SW
    // remapping of these IDs, route the FCSM swi_*_id regs out instead.
    .io_swi_cr_id(8'h44),
    .io_swi_crack_id(8'h45),
    .io_swi_ack_id(8'h46),
    .io_swi_nack_id(8'h47),
    .io_active_lanes(llrx_io_active_lanes),
    .io_lane_mask(llrx_io_lane_mask),
    .io_ecc_corrected(llrx_io_ecc_corrected),
    .io_ecc_corrupted(llrx_io_ecc_corrupted),
    .io_link_data(llrx_io_link_data),
`ifdef TIDELINK_PHY_V2
    // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 2) — robust
    // re-hunt source, gated by SWI_SYNC_ROBUST_DETECT (default 0 -> 0 here ->
    // bit-identical). When the bit is 1, the PHY's mask-aware per-lane match
    // (phy_io_sync_seen_pulse) additionally triggers the framer re-hunt.
    .io_robust_sync_seen(phy_io_sync_seen_pulse & swi_sync_robust_detect_in),
`else
    .io_robust_sync_seen(1'b0), // V1: no PHY detector -> bit-identical re-hunt
`endif
    .io_in_error_state(llrx_io_in_error_state),
    .io_obs_state(llrx_io_obs_state),
    .io_obs_is_short_pkt(llrx_io_obs_is_short_pkt),
    .io_obs_is_long_pkt(llrx_io_obs_is_long_pkt),
    .io_obs_valid(llrx_io_obs_valid),
    .io_obs_sync_detected(llrx_io_obs_sync_detected), // SoC Labs 2026-06-08
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap)
    .io_obs_rxcap0(llrx_io_obs_rxcap0),
    .io_obs_rxcap1(llrx_io_obs_rxcap1)
  );
  AXI4ToWlink axi2wl ( // @[AXI.scala 99:31]
    .clock(axi2wl_clock),
    .reset(axi2wl_reset),
    .auto_wlink_axirFC_rx_in_sop(axi2wl_auto_wlink_axirFC_rx_in_sop),
    .auto_wlink_axirFC_rx_in_data_id(axi2wl_auto_wlink_axirFC_rx_in_data_id),
    .auto_wlink_axirFC_rx_in_word_count(axi2wl_auto_wlink_axirFC_rx_in_word_count),
    .auto_wlink_axirFC_rx_in_data(axi2wl_auto_wlink_axirFC_rx_in_data),
    .auto_wlink_axirFC_rx_in_valid(axi2wl_auto_wlink_axirFC_rx_in_valid),
    .auto_wlink_axirFC_rx_in_crc(axi2wl_auto_wlink_axirFC_rx_in_crc),
    .auto_wlink_axirFC_tx_out_sop(axi2wl_auto_wlink_axirFC_tx_out_sop),
    .auto_wlink_axirFC_tx_out_data_id(axi2wl_auto_wlink_axirFC_tx_out_data_id),
    .auto_wlink_axirFC_tx_out_word_count(axi2wl_auto_wlink_axirFC_tx_out_word_count),
    .auto_wlink_axirFC_tx_out_data(axi2wl_auto_wlink_axirFC_tx_out_data),
    .auto_wlink_axirFC_tx_out_crc(axi2wl_auto_wlink_axirFC_tx_out_crc),
    .auto_wlink_axirFC_tx_out_advance(axi2wl_auto_wlink_axirFC_tx_out_advance),
    .auto_wlink_axiarFC_rx_in_sop(axi2wl_auto_wlink_axiarFC_rx_in_sop),
    .auto_wlink_axiarFC_rx_in_data_id(axi2wl_auto_wlink_axiarFC_rx_in_data_id),
    .auto_wlink_axiarFC_rx_in_word_count(axi2wl_auto_wlink_axiarFC_rx_in_word_count),
    .auto_wlink_axiarFC_rx_in_data(axi2wl_auto_wlink_axiarFC_rx_in_data),
    .auto_wlink_axiarFC_rx_in_valid(axi2wl_auto_wlink_axiarFC_rx_in_valid),
    .auto_wlink_axiarFC_rx_in_crc(axi2wl_auto_wlink_axiarFC_rx_in_crc),
    .auto_wlink_axiarFC_tx_out_sop(axi2wl_auto_wlink_axiarFC_tx_out_sop),
    .auto_wlink_axiarFC_tx_out_data_id(axi2wl_auto_wlink_axiarFC_tx_out_data_id),
    .auto_wlink_axiarFC_tx_out_word_count(axi2wl_auto_wlink_axiarFC_tx_out_word_count),
    .auto_wlink_axiarFC_tx_out_data(axi2wl_auto_wlink_axiarFC_tx_out_data),
    .auto_wlink_axiarFC_tx_out_crc(axi2wl_auto_wlink_axiarFC_tx_out_crc),
    .auto_wlink_axiarFC_tx_out_advance(axi2wl_auto_wlink_axiarFC_tx_out_advance),
    .auto_wlink_axibFC_rx_in_sop(axi2wl_auto_wlink_axibFC_rx_in_sop),
    .auto_wlink_axibFC_rx_in_data_id(axi2wl_auto_wlink_axibFC_rx_in_data_id),
    .auto_wlink_axibFC_rx_in_word_count(axi2wl_auto_wlink_axibFC_rx_in_word_count),
    .auto_wlink_axibFC_rx_in_data(axi2wl_auto_wlink_axibFC_rx_in_data),
    .auto_wlink_axibFC_rx_in_valid(axi2wl_auto_wlink_axibFC_rx_in_valid),
    .auto_wlink_axibFC_rx_in_crc(axi2wl_auto_wlink_axibFC_rx_in_crc),
    .auto_wlink_axibFC_tx_out_sop(axi2wl_auto_wlink_axibFC_tx_out_sop),
    .auto_wlink_axibFC_tx_out_data_id(axi2wl_auto_wlink_axibFC_tx_out_data_id),
    .auto_wlink_axibFC_tx_out_word_count(axi2wl_auto_wlink_axibFC_tx_out_word_count),
    .auto_wlink_axibFC_tx_out_data(axi2wl_auto_wlink_axibFC_tx_out_data),
    .auto_wlink_axibFC_tx_out_crc(axi2wl_auto_wlink_axibFC_tx_out_crc),
    .auto_wlink_axibFC_tx_out_advance(axi2wl_auto_wlink_axibFC_tx_out_advance),
    .auto_wlink_axiwFC_rx_in_sop(axi2wl_auto_wlink_axiwFC_rx_in_sop),
    .auto_wlink_axiwFC_rx_in_data_id(axi2wl_auto_wlink_axiwFC_rx_in_data_id),
    .auto_wlink_axiwFC_rx_in_word_count(axi2wl_auto_wlink_axiwFC_rx_in_word_count),
    .auto_wlink_axiwFC_rx_in_data(axi2wl_auto_wlink_axiwFC_rx_in_data),
    .auto_wlink_axiwFC_rx_in_valid(axi2wl_auto_wlink_axiwFC_rx_in_valid),
    .auto_wlink_axiwFC_rx_in_crc(axi2wl_auto_wlink_axiwFC_rx_in_crc),
    .auto_wlink_axiwFC_tx_out_sop(axi2wl_auto_wlink_axiwFC_tx_out_sop),
    .auto_wlink_axiwFC_tx_out_data_id(axi2wl_auto_wlink_axiwFC_tx_out_data_id),
    .auto_wlink_axiwFC_tx_out_word_count(axi2wl_auto_wlink_axiwFC_tx_out_word_count),
    .auto_wlink_axiwFC_tx_out_data(axi2wl_auto_wlink_axiwFC_tx_out_data),
    .auto_wlink_axiwFC_tx_out_crc(axi2wl_auto_wlink_axiwFC_tx_out_crc),
    .auto_wlink_axiwFC_tx_out_advance(axi2wl_auto_wlink_axiwFC_tx_out_advance),
    .auto_wlink_axiawFC_rx_in_sop(axi2wl_auto_wlink_axiawFC_rx_in_sop),
    .auto_wlink_axiawFC_rx_in_data_id(axi2wl_auto_wlink_axiawFC_rx_in_data_id),
    .auto_wlink_axiawFC_rx_in_word_count(axi2wl_auto_wlink_axiawFC_rx_in_word_count),
    .auto_wlink_axiawFC_rx_in_data(axi2wl_auto_wlink_axiawFC_rx_in_data),
    .auto_wlink_axiawFC_rx_in_valid(axi2wl_auto_wlink_axiawFC_rx_in_valid),
    .auto_wlink_axiawFC_rx_in_crc(axi2wl_auto_wlink_axiawFC_rx_in_crc),
    .auto_wlink_axiawFC_tx_out_sop(axi2wl_auto_wlink_axiawFC_tx_out_sop),
    .auto_wlink_axiawFC_tx_out_data_id(axi2wl_auto_wlink_axiawFC_tx_out_data_id),
    .auto_wlink_axiawFC_tx_out_word_count(axi2wl_auto_wlink_axiawFC_tx_out_word_count),
    .auto_wlink_axiawFC_tx_out_data(axi2wl_auto_wlink_axiawFC_tx_out_data),
    .auto_wlink_axiawFC_tx_out_crc(axi2wl_auto_wlink_axiawFC_tx_out_crc),
    .auto_wlink_axiawFC_tx_out_advance(axi2wl_auto_wlink_axiawFC_tx_out_advance),
    .auto_xbar_in_psel(axi2wl_auto_xbar_in_psel),
    .auto_xbar_in_penable(axi2wl_auto_xbar_in_penable),
    .auto_xbar_in_pwrite(axi2wl_auto_xbar_in_pwrite),
    .auto_xbar_in_paddr(axi2wl_auto_xbar_in_paddr),
    .auto_xbar_in_pwdata(axi2wl_auto_xbar_in_pwdata),
    .auto_xbar_in_pstrb(axi2wl_auto_xbar_in_pstrb),
    .auto_xbar_in_pready(axi2wl_auto_xbar_in_pready),
    .auto_xbar_in_prdata(axi2wl_auto_xbar_in_prdata),
    .auto_axi_ini_out_aw_ready(axi2wl_auto_axi_ini_out_aw_ready),
    .auto_axi_ini_out_aw_valid(axi2wl_auto_axi_ini_out_aw_valid),
    .auto_axi_ini_out_aw_bits_id(axi2wl_auto_axi_ini_out_aw_bits_id),
    .auto_axi_ini_out_aw_bits_addr(axi2wl_auto_axi_ini_out_aw_bits_addr),
    .auto_axi_ini_out_aw_bits_len(axi2wl_auto_axi_ini_out_aw_bits_len),
    .auto_axi_ini_out_aw_bits_size(axi2wl_auto_axi_ini_out_aw_bits_size),
    .auto_axi_ini_out_aw_bits_burst(axi2wl_auto_axi_ini_out_aw_bits_burst),
    .auto_axi_ini_out_aw_bits_lock(axi2wl_auto_axi_ini_out_aw_bits_lock),
    .auto_axi_ini_out_aw_bits_cache(axi2wl_auto_axi_ini_out_aw_bits_cache),
    .auto_axi_ini_out_aw_bits_prot(axi2wl_auto_axi_ini_out_aw_bits_prot),
    .auto_axi_ini_out_aw_bits_qos(axi2wl_auto_axi_ini_out_aw_bits_qos),
    .auto_axi_ini_out_w_ready(axi2wl_auto_axi_ini_out_w_ready),
    .auto_axi_ini_out_w_valid(axi2wl_auto_axi_ini_out_w_valid),
    .auto_axi_ini_out_w_bits_data(axi2wl_auto_axi_ini_out_w_bits_data),
    .auto_axi_ini_out_w_bits_strb(axi2wl_auto_axi_ini_out_w_bits_strb),
    .auto_axi_ini_out_w_bits_last(axi2wl_auto_axi_ini_out_w_bits_last),
    .auto_axi_ini_out_b_ready(axi2wl_auto_axi_ini_out_b_ready),
    .auto_axi_ini_out_b_valid(axi2wl_auto_axi_ini_out_b_valid),
    .auto_axi_ini_out_b_bits_id(axi2wl_auto_axi_ini_out_b_bits_id),
    .auto_axi_ini_out_b_bits_resp(axi2wl_auto_axi_ini_out_b_bits_resp),
    .auto_axi_ini_out_ar_ready(axi2wl_auto_axi_ini_out_ar_ready),
    .auto_axi_ini_out_ar_valid(axi2wl_auto_axi_ini_out_ar_valid),
    .auto_axi_ini_out_ar_bits_id(axi2wl_auto_axi_ini_out_ar_bits_id),
    .auto_axi_ini_out_ar_bits_addr(axi2wl_auto_axi_ini_out_ar_bits_addr),
    .auto_axi_ini_out_ar_bits_len(axi2wl_auto_axi_ini_out_ar_bits_len),
    .auto_axi_ini_out_ar_bits_size(axi2wl_auto_axi_ini_out_ar_bits_size),
    .auto_axi_ini_out_ar_bits_burst(axi2wl_auto_axi_ini_out_ar_bits_burst),
    .auto_axi_ini_out_ar_bits_lock(axi2wl_auto_axi_ini_out_ar_bits_lock),
    .auto_axi_ini_out_ar_bits_cache(axi2wl_auto_axi_ini_out_ar_bits_cache),
    .auto_axi_ini_out_ar_bits_prot(axi2wl_auto_axi_ini_out_ar_bits_prot),
    .auto_axi_ini_out_ar_bits_qos(axi2wl_auto_axi_ini_out_ar_bits_qos),
    .auto_axi_ini_out_r_ready(axi2wl_auto_axi_ini_out_r_ready),
    .auto_axi_ini_out_r_valid(axi2wl_auto_axi_ini_out_r_valid),
    .auto_axi_ini_out_r_bits_id(axi2wl_auto_axi_ini_out_r_bits_id),
    .auto_axi_ini_out_r_bits_data(axi2wl_auto_axi_ini_out_r_bits_data),
    .auto_axi_ini_out_r_bits_resp(axi2wl_auto_axi_ini_out_r_bits_resp),
    .auto_axi_ini_out_r_bits_last(axi2wl_auto_axi_ini_out_r_bits_last),
    .auto_axi_tgt_in_aw_ready(axi2wl_auto_axi_tgt_in_aw_ready),
    .auto_axi_tgt_in_aw_valid(axi2wl_auto_axi_tgt_in_aw_valid),
    .auto_axi_tgt_in_aw_bits_id(axi2wl_auto_axi_tgt_in_aw_bits_id),
    .auto_axi_tgt_in_aw_bits_addr(axi2wl_auto_axi_tgt_in_aw_bits_addr),
    .auto_axi_tgt_in_aw_bits_len(axi2wl_auto_axi_tgt_in_aw_bits_len),
    .auto_axi_tgt_in_aw_bits_size(axi2wl_auto_axi_tgt_in_aw_bits_size),
    .auto_axi_tgt_in_aw_bits_burst(axi2wl_auto_axi_tgt_in_aw_bits_burst),
    .auto_axi_tgt_in_aw_bits_lock(axi2wl_auto_axi_tgt_in_aw_bits_lock),
    .auto_axi_tgt_in_aw_bits_cache(axi2wl_auto_axi_tgt_in_aw_bits_cache),
    .auto_axi_tgt_in_aw_bits_prot(axi2wl_auto_axi_tgt_in_aw_bits_prot),
    .auto_axi_tgt_in_aw_bits_qos(axi2wl_auto_axi_tgt_in_aw_bits_qos),
    .auto_axi_tgt_in_w_ready(axi2wl_auto_axi_tgt_in_w_ready),
    .auto_axi_tgt_in_w_valid(axi2wl_auto_axi_tgt_in_w_valid),
    .auto_axi_tgt_in_w_bits_data(axi2wl_auto_axi_tgt_in_w_bits_data),
    .auto_axi_tgt_in_w_bits_strb(axi2wl_auto_axi_tgt_in_w_bits_strb),
    .auto_axi_tgt_in_w_bits_last(axi2wl_auto_axi_tgt_in_w_bits_last),
    .auto_axi_tgt_in_b_ready(axi2wl_auto_axi_tgt_in_b_ready),
    .auto_axi_tgt_in_b_valid(axi2wl_auto_axi_tgt_in_b_valid),
    .auto_axi_tgt_in_b_bits_id(axi2wl_auto_axi_tgt_in_b_bits_id),
    .auto_axi_tgt_in_b_bits_resp(axi2wl_auto_axi_tgt_in_b_bits_resp),
    .auto_axi_tgt_in_ar_ready(axi2wl_auto_axi_tgt_in_ar_ready),
    .auto_axi_tgt_in_ar_valid(axi2wl_auto_axi_tgt_in_ar_valid),
    .auto_axi_tgt_in_ar_bits_id(axi2wl_auto_axi_tgt_in_ar_bits_id),
    .auto_axi_tgt_in_ar_bits_addr(axi2wl_auto_axi_tgt_in_ar_bits_addr),
    .auto_axi_tgt_in_ar_bits_len(axi2wl_auto_axi_tgt_in_ar_bits_len),
    .auto_axi_tgt_in_ar_bits_size(axi2wl_auto_axi_tgt_in_ar_bits_size),
    .auto_axi_tgt_in_ar_bits_burst(axi2wl_auto_axi_tgt_in_ar_bits_burst),
    .auto_axi_tgt_in_ar_bits_lock(axi2wl_auto_axi_tgt_in_ar_bits_lock),
    .auto_axi_tgt_in_ar_bits_cache(axi2wl_auto_axi_tgt_in_ar_bits_cache),
    .auto_axi_tgt_in_ar_bits_prot(axi2wl_auto_axi_tgt_in_ar_bits_prot),
    .auto_axi_tgt_in_ar_bits_qos(axi2wl_auto_axi_tgt_in_ar_bits_qos),
    .auto_axi_tgt_in_r_ready(axi2wl_auto_axi_tgt_in_r_ready),
    .auto_axi_tgt_in_r_valid(axi2wl_auto_axi_tgt_in_r_valid),
    .auto_axi_tgt_in_r_bits_id(axi2wl_auto_axi_tgt_in_r_bits_id),
    .auto_axi_tgt_in_r_bits_data(axi2wl_auto_axi_tgt_in_r_bits_data),
    .auto_axi_tgt_in_r_bits_resp(axi2wl_auto_axi_tgt_in_r_bits_resp),
    .auto_axi_tgt_in_r_bits_last(axi2wl_auto_axi_tgt_in_r_bits_last),
    .io_app_clk(axi2wl_io_app_clk),
    .io_app_reset(axi2wl_io_app_reset),
    .io_app_enable(axi2wl_io_app_enable),
    .io_tx_clk(axi2wl_io_tx_clk),
    .io_tx_reset(axi2wl_io_tx_reset),
    .io_rx_clk(axi2wl_io_rx_clk),
    .io_rx_reset(axi2wl_io_rx_reset),
    .io_rx_crc_err(axi2wl_io_rx_crc_err)
  );
  GeneralBusToWlink gb2wl ( // @[GeneralBus.scala 89:30]
    .clock(gb2wl_clock),
    .reset(gb2wl_reset),
    .auto_wlink_generalbusgb_rx_in_sop(gb2wl_auto_wlink_generalbusgb_rx_in_sop),
    .auto_wlink_generalbusgb_rx_in_data_id(gb2wl_auto_wlink_generalbusgb_rx_in_data_id),
    .auto_wlink_generalbusgb_rx_in_word_count(gb2wl_auto_wlink_generalbusgb_rx_in_word_count),
    .auto_wlink_generalbusgb_rx_in_data(gb2wl_auto_wlink_generalbusgb_rx_in_data),
    .auto_wlink_generalbusgb_rx_in_valid(gb2wl_auto_wlink_generalbusgb_rx_in_valid),
    .auto_wlink_generalbusgb_rx_in_crc(gb2wl_auto_wlink_generalbusgb_rx_in_crc),
    .auto_wlink_generalbusgb_tx_out_sop(gb2wl_auto_wlink_generalbusgb_tx_out_sop),
    .auto_wlink_generalbusgb_tx_out_data_id(gb2wl_auto_wlink_generalbusgb_tx_out_data_id),
    .auto_wlink_generalbusgb_tx_out_word_count(gb2wl_auto_wlink_generalbusgb_tx_out_word_count),
    .auto_wlink_generalbusgb_tx_out_data(gb2wl_auto_wlink_generalbusgb_tx_out_data),
    .auto_wlink_generalbusgb_tx_out_crc(gb2wl_auto_wlink_generalbusgb_tx_out_crc),
    .auto_wlink_generalbusgb_tx_out_advance(gb2wl_auto_wlink_generalbusgb_tx_out_advance),
    .auto_in_psel(gb2wl_auto_in_psel),
    .auto_in_penable(gb2wl_auto_in_penable),
    .auto_in_pwrite(gb2wl_auto_in_pwrite),
    .auto_in_paddr(gb2wl_auto_in_paddr),
    .auto_in_pwdata(gb2wl_auto_in_pwdata),
    .auto_in_pstrb(gb2wl_auto_in_pstrb),
    .auto_in_pready(gb2wl_auto_in_pready),
    .auto_in_prdata(gb2wl_auto_in_prdata),
    .io_app_clk(gb2wl_io_app_clk),
    .io_app_reset(gb2wl_io_app_reset),
    .io_app_enable(gb2wl_io_app_enable),
    .io_tx_clk(gb2wl_io_tx_clk),
    .io_tx_reset(gb2wl_io_tx_reset),
    .io_rx_clk(gb2wl_io_rx_clk),
    .io_rx_reset(gb2wl_io_rx_reset),
    .io_rx_crc_err(gb2wl_io_rx_crc_err),
    .bus_out_0(gb2wl_bus_out_0),
    .bore(gb2wl_bore)
  );
  TideLinkToWlink tl2wl ( // @[TideLink.scala 105:30]
    .clock(tl2wl_clock),
    .reset(tl2wl_reset),
    .auto_wlink_tidelinktl_rx_in_sop(tl2wl_auto_wlink_tidelinktl_rx_in_sop),
    .auto_wlink_tidelinktl_rx_in_data_id(tl2wl_auto_wlink_tidelinktl_rx_in_data_id),
    .auto_wlink_tidelinktl_rx_in_word_count(tl2wl_auto_wlink_tidelinktl_rx_in_word_count),
    .auto_wlink_tidelinktl_rx_in_data(tl2wl_auto_wlink_tidelinktl_rx_in_data),
    .auto_wlink_tidelinktl_rx_in_valid(tl2wl_auto_wlink_tidelinktl_rx_in_valid),
    .auto_wlink_tidelinktl_rx_in_crc(tl2wl_auto_wlink_tidelinktl_rx_in_crc),
    .auto_wlink_tidelinktl_tx_out_sop(tl2wl_auto_wlink_tidelinktl_tx_out_sop),
    .auto_wlink_tidelinktl_tx_out_data_id(tl2wl_auto_wlink_tidelinktl_tx_out_data_id),
    .auto_wlink_tidelinktl_tx_out_word_count(tl2wl_auto_wlink_tidelinktl_tx_out_word_count),
    .auto_wlink_tidelinktl_tx_out_data(tl2wl_auto_wlink_tidelinktl_tx_out_data),
    .auto_wlink_tidelinktl_tx_out_crc(tl2wl_auto_wlink_tidelinktl_tx_out_crc),
    .auto_wlink_tidelinktl_tx_out_advance(tl2wl_auto_wlink_tidelinktl_tx_out_advance),
    .auto_in_psel(tl2wl_auto_in_psel),
    .auto_in_penable(tl2wl_auto_in_penable),
    .auto_in_pwrite(tl2wl_auto_in_pwrite),
    .auto_in_paddr(tl2wl_auto_in_paddr),
    .auto_in_pwdata(tl2wl_auto_in_pwdata),
    .auto_in_pstrb(tl2wl_auto_in_pstrb),
    .auto_in_pready(tl2wl_auto_in_pready),
    .auto_in_prdata(tl2wl_auto_in_prdata),
    .io_app_clk(tl2wl_io_app_clk),
    .io_app_reset(tl2wl_io_app_reset),
    .io_app_enable(tl2wl_io_app_enable),
    .io_tx_clk(tl2wl_io_tx_clk),
    .io_tx_reset(tl2wl_io_tx_reset),
    .io_rx_clk(tl2wl_io_rx_clk),
    .io_rx_reset(tl2wl_io_rx_reset),
    .io_rx_crc_err(tl2wl_io_rx_crc_err),
    .tl_bus_out_0(tl2wl_tl_bus_out_0),
    .bore_1(tl2wl_bore_1),
    .io_obs_fcsm_state(tl2wl_io_obs_fcsm_state),
    .io_obs_cr_pkt_seen_rx(tl2wl_io_obs_cr_pkt_seen_rx),
    .io_obs_crack_pkt_seen_rx(tl2wl_io_obs_crack_pkt_seen_rx),
    .io_obs_pkt_is_cr_pkt(tl2wl_io_obs_pkt_is_cr_pkt),
    .io_obs_pkt_is_crack_pkt(tl2wl_io_obs_pkt_is_crack_pkt),
    // SoC Labs Bug-A FCSM observation 2026-06-02
    .io_obs_a2l_replay_link_valid(tl2wl_io_obs_a2l_replay_link_valid),
    .io_obs_fe_rx_credit_max(tl2wl_io_obs_fe_rx_credit_max),
    .io_obs_fe_rx_is_full(tl2wl_io_obs_fe_rx_is_full),
    // SoC Labs Bug-A FCSM observation 2026-06-03
    .io_obs_a2l_replay_app_valid(tl2wl_io_obs_a2l_replay_app_valid),
    // SoC Labs V2 data-send observation 2026-06-21
    .io_obs_a2l_replay_app_ready(tl2wl_io_obs_a2l_replay_app_ready),
    .io_obs_a2l_replay_link_empty(tl2wl_io_obs_a2l_replay_link_empty),
    // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21
    .io_obs_a2l_wptr(tl2wl_io_obs_a2l_wptr),
    .io_obs_a2l_synced_ack(tl2wl_io_obs_a2l_synced_ack),
    .io_obs_a2l_full(tl2wl_io_obs_a2l_full),
    .io_obs_a2l_enable_app_demet(tl2wl_io_obs_a2l_enable_app_demet),
    // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
    .io_obs_a2l_rreset(tl2wl_io_obs_a2l_rreset),
    .io_obs_a2l_rptr(tl2wl_io_obs_a2l_rptr),
    // SoC Labs FC credit observation 2026-06-12
    .io_obs_fe_rx_ptr(tl2wl_io_obs_fe_rx_ptr),
    // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap)
    .io_obs_fcsmcap(tl2wl_io_obs_fcsmcap)
  );
  ShortPacketToWlink sp2wl ( // @[ShortPacket.scala 87:30]
    .auto_rx_in_sop(sp2wl_auto_rx_in_sop),
    .auto_rx_in_data_id(sp2wl_auto_rx_in_data_id),
    .auto_rx_in_word_count(sp2wl_auto_rx_in_word_count),
    .auto_rx_in_valid(sp2wl_auto_rx_in_valid),
    .auto_tx_out_sop(sp2wl_auto_tx_out_sop),
    .auto_tx_out_data_id(sp2wl_auto_tx_out_data_id),
    .auto_tx_out_word_count(sp2wl_auto_tx_out_word_count),
    .auto_tx_out_advance(sp2wl_auto_tx_out_advance),
    .io_app_clk(sp2wl_io_app_clk),
    .io_app_reset(sp2wl_io_app_reset),
    .io_app_enable(sp2wl_io_app_enable),
    .io_tx_clk(sp2wl_io_tx_clk),
    .io_tx_reset(sp2wl_io_tx_reset),
    .io_rx_clk(sp2wl_io_rx_clk),
    .io_rx_reset(sp2wl_io_rx_reset),
    .sp_bus_out_0(sp2wl_sp_bus_out_0),
    .bore_2(sp2wl_bore_2)
  );
  WavResetSync tx_link_clk_reset_wrs ( // @[Stdcell.scala 324:21]
    .io_clk(tx_link_clk_reset_wrs_io_clk),
    .io_scan_ctrl(tx_link_clk_reset_wrs_io_scan_ctrl),
    .io_reset_in(tx_link_clk_reset_wrs_io_reset_in),
    .io_reset_out(tx_link_clk_reset_wrs_io_reset_out)
  );
  WavResetSync rx_link_clk_reset_wrs ( // @[Stdcell.scala 324:21]
    .io_clk(rx_link_clk_reset_wrs_io_clk),
    .io_scan_ctrl(rx_link_clk_reset_wrs_io_scan_ctrl),
    .io_reset_in(rx_link_clk_reset_wrs_io_reset_in),
    .io_reset_out(rx_link_clk_reset_wrs_io_reset_out)
  );
  WavClockMux app_clk_scan_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(app_clk_scan_mux_io_i_sel),
    .io_i_a(app_clk_scan_mux_io_i_a),
    .io_i_b(app_clk_scan_mux_io_i_b),
    .io_o_z(app_clk_scan_mux_io_o_z)
  );
  WavResetSync app_clk_reset_scan_wrs ( // @[Stdcell.scala 324:21]
    .io_clk(app_clk_reset_scan_wrs_io_clk),
    .io_scan_ctrl(app_clk_reset_scan_wrs_io_scan_ctrl),
    .io_reset_in(app_clk_reset_scan_wrs_io_reset_in),
    .io_reset_out(app_clk_reset_scan_wrs_io_reset_out)
  );
  WavSyncPulse ecc_corrected_sp ( // @[Wlink.scala 250:34]
    .io_clk_in(ecc_corrected_sp_io_clk_in),
    .io_clk_in_reset(ecc_corrected_sp_io_clk_in_reset),
    .io_data_in(ecc_corrected_sp_io_data_in),
    .io_clk_out(ecc_corrected_sp_io_clk_out),
    .io_clk_out_reset(ecc_corrected_sp_io_clk_out_reset),
    .io_data_out(ecc_corrected_sp_io_data_out)
  );
  WavSyncPulse ecc_corrupted_sp ( // @[Wlink.scala 258:34]
    .io_clk_in(ecc_corrupted_sp_io_clk_in),
    .io_clk_in_reset(ecc_corrupted_sp_io_clk_in_reset),
    .io_data_in(ecc_corrupted_sp_io_data_in),
    .io_clk_out(ecc_corrupted_sp_io_clk_out),
    .io_clk_out_reset(ecc_corrupted_sp_io_clk_out_reset),
    .io_data_out(ecc_corrupted_sp_io_data_out)
  );
  WavClockMux muxed_pre_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(muxed_pre_mux_io_i_sel),
    .io_i_a(muxed_pre_mux_io_i_a),
    .io_i_b(muxed_pre_mux_io_i_b),
    .io_o_z(muxed_pre_mux_io_o_z)
  );
  WavDemetReset ff2_demet ( // @[Stdcell.scala 58:23]
    .clock(ff2_demet_clock),
    .reset(ff2_demet_reset),
    .io_in(ff2_demet_io_in),
    .io_out(ff2_demet_io_out)
  );
  WavDemetReset ff2_demet_1 ( // @[Stdcell.scala 58:23]
    .clock(ff2_demet_1_clock),
    .reset(ff2_demet_1_reset),
    .io_in(ff2_demet_1_io_in),
    .io_out(ff2_demet_1_io_out)
  );
  WavDemetReset ff2_demet_2 ( // @[Stdcell.scala 58:23]
    .clock(ff2_demet_2_clock),
    .reset(ff2_demet_2_reset),
    .io_in(ff2_demet_2_io_in),
    .io_out(ff2_demet_2_io_out)
  );
  assign apbport_0_pready = xbar_auto_in_pready; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign apbport_0_pslverr = 1'h0; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign apbport_0_prdata = xbar_auto_in_prdata; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_ini_0_aw_valid = axi2wl_auto_axi_ini_out_aw_valid; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_id = axi2wl_auto_axi_ini_out_aw_bits_id; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_addr = axi2wl_auto_axi_ini_out_aw_bits_addr; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_len = axi2wl_auto_axi_ini_out_aw_bits_len; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_size = axi2wl_auto_axi_ini_out_aw_bits_size; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_burst = axi2wl_auto_axi_ini_out_aw_bits_burst; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_lock = axi2wl_auto_axi_ini_out_aw_bits_lock; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_cache = axi2wl_auto_axi_ini_out_aw_bits_cache; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_prot = axi2wl_auto_axi_ini_out_aw_bits_prot; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_aw_bits_qos = axi2wl_auto_axi_ini_out_aw_bits_qos; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_w_valid = axi2wl_auto_axi_ini_out_w_valid; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_w_bits_data = axi2wl_auto_axi_ini_out_w_bits_data; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_w_bits_strb = axi2wl_auto_axi_ini_out_w_bits_strb; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_w_bits_last = axi2wl_auto_axi_ini_out_w_bits_last; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_b_ready = axi2wl_auto_axi_ini_out_b_ready; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_valid = axi2wl_auto_axi_ini_out_ar_valid; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_id = axi2wl_auto_axi_ini_out_ar_bits_id; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_addr = axi2wl_auto_axi_ini_out_ar_bits_addr; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_len = axi2wl_auto_axi_ini_out_ar_bits_len; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_size = axi2wl_auto_axi_ini_out_ar_bits_size; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_burst = axi2wl_auto_axi_ini_out_ar_bits_burst; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_lock = axi2wl_auto_axi_ini_out_ar_bits_lock; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_cache = axi2wl_auto_axi_ini_out_ar_bits_cache; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_prot = axi2wl_auto_axi_ini_out_ar_bits_prot; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_ar_bits_qos = axi2wl_auto_axi_ini_out_ar_bits_qos; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_ini_0_r_ready = axi2wl_auto_axi_ini_out_r_ready; // @[Nodes.scala 1210:84 LazyModule.scala 296:16]
  assign axi_tgt_0_aw_ready = axi2wl_auto_axi_tgt_in_aw_ready; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_w_ready = axi2wl_auto_axi_tgt_in_w_ready; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_b_valid = axi2wl_auto_axi_tgt_in_b_valid; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_b_bits_id = axi2wl_auto_axi_tgt_in_b_bits_id; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_b_bits_resp = axi2wl_auto_axi_tgt_in_b_bits_resp; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_ar_ready = axi2wl_auto_axi_tgt_in_ar_ready; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_r_valid = axi2wl_auto_axi_tgt_in_r_valid; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_r_bits_id = axi2wl_auto_axi_tgt_in_r_bits_id; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_r_bits_data = axi2wl_auto_axi_tgt_in_r_bits_data; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_r_bits_resp = axi2wl_auto_axi_tgt_in_r_bits_resp; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign axi_tgt_0_r_bits_last = axi2wl_auto_axi_tgt_in_r_bits_last; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign generalbus_out = gb2wl_bus_out_0; // @[GeneralBus.scala 59:35]
  assign tidelink_out = tl2wl_tl_bus_out_0; // @[TideLink.scala 75:33]
  assign ptp_out = sp2wl_sp_bus_out_0; // @[ShortPacket.scala 59:33]
  assign scan_out = 1'h0;
  assign interrupt = _interrupt_T_2 | _interrupt_T_3; // @[Wlink.scala 269:70]
  assign sb_reset_out = llrx_io_in_error_state; // @[Wlink.scala 223:43]
  assign sb_wake = txpstate_io_tx_en; // @[Wlink.scala 210:43]
  assign tx_link_idle = lltx_io_link_idle; // @[Wlink.scala 190:43]
  assign pad_clk_tx = phy_pad_clk_tx; // @[Wlink.scala 239:10]
  assign pad_tx_0 = phy_pad_tx_0; // @[Wlink.scala 239:10]
  assign pad_tx_1 = phy_pad_tx_1; // @[Wlink.scala 239:10]
  assign pad_tx_2 = phy_pad_tx_2; // @[Wlink.scala 239:10]
  assign pad_tx_3 = phy_pad_tx_3; // @[Wlink.scala 239:10]
  assign pad_tx_4 = phy_pad_tx_4; // @[Wlink.scala 239:10]
  assign pad_tx_5 = phy_pad_tx_5; // @[Wlink.scala 239:10]
  assign pad_tx_6 = phy_pad_tx_6; // @[Wlink.scala 239:10]
  assign pad_tx_7 = phy_pad_tx_7; // @[Wlink.scala 239:10]
  assign xbar_auto_in_psel = apbport_0_psel; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign xbar_auto_in_penable = apbport_0_penable; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign xbar_auto_in_pwrite = apbport_0_pwrite; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign xbar_auto_in_paddr = apbport_0_paddr; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign xbar_auto_in_pwdata = apbport_0_pwdata; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign xbar_auto_in_pstrb = apbport_0_pstrb; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign xbar_auto_out_4_pready = tl2wl_auto_in_pready; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_4_prdata = tl2wl_auto_in_prdata; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_3_pready = gb2wl_auto_in_pready; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_3_prdata = gb2wl_auto_in_prdata; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_2_pready = axi2wl_auto_xbar_in_pready; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_2_prdata = axi2wl_auto_xbar_in_prdata; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_1_pready = phy_auto_in_pready; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_1_prdata = phy_auto_in_prdata; // @[LazyModule.scala 298:16]
  assign xbar_auto_out_0_pready = bundleIn_0_psel & ~taken; // @[RegisterNodes.scala 241:26]
  assign xbar_auto_out_0_prdata = out_out_bits_data_out ? out_out_bits_data_out_1 : 32'h0; // @[RegisterNodes.scala 229:24]
  assign phy_clock = apb_clk;
  assign phy_reset = apb_reset;
  assign phy_auto_in_psel = xbar_auto_out_1_psel; // @[LazyModule.scala 298:16]
  assign phy_auto_in_penable = xbar_auto_out_1_penable; // @[LazyModule.scala 298:16]
  assign phy_auto_in_pwrite = xbar_auto_out_1_pwrite; // @[LazyModule.scala 298:16]
  assign phy_auto_in_pwdata = xbar_auto_out_1_pwdata; // @[LazyModule.scala 298:16]
  assign phy_auto_in_pstrb = xbar_auto_out_1_pstrb; // @[LazyModule.scala 298:16]
  assign phy_scan_mode = scan_mode; // @[Bundles.scala 19:19]
  assign phy_scan_asyncrst_ctrl = scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign phy_scan_clk = scan_clk; // @[Bundles.scala 21:19]
  assign phy_por_reset = por_reset; // @[Wlink.scala 236:28]
  assign phy_link_tx_tx_en = txpstate_io_tx_en; // @[Wlink.scala 187:43]
  assign phy_link_tx_tx_link_data = lltx_io_link_data; // @[Wlink.scala 188:43]
  assign phy_link_tx_tx_lane_mask = swi_tx_lane_mask; // @[Wlink.scala 163:49 SW.scala 117:16]
  assign phy_link_rx_rx_lane_mask = out_prepend_swi_rx_lane_mask; // @[Wlink.scala 164:49 SW.scala 117:16]
  assign phy_pad_clk_rx = pad_clk_rx; // @[Wlink.scala 239:10]
  assign phy_pad_rx_0 = pad_rx_0; // @[Wlink.scala 239:10]
  assign phy_pad_rx_1 = pad_rx_1; // @[Wlink.scala 239:10]
  assign phy_pad_rx_2 = pad_rx_2; // @[Wlink.scala 239:10]
  assign phy_pad_rx_3 = pad_rx_3; // @[Wlink.scala 239:10]
  assign phy_pad_rx_4 = pad_rx_4; // @[Wlink.scala 239:10]
  assign phy_pad_rx_5 = pad_rx_5; // @[Wlink.scala 239:10]
  assign phy_pad_rx_6 = pad_rx_6; // @[Wlink.scala 239:10]
  assign phy_pad_rx_7 = pad_rx_7; // @[Wlink.scala 239:10]
  assign phy_user_hsclk = user_hsclk; // @[Wlink.scala 238:10]
  assign txrouter_clock = phy_link_tx_tx_link_clk; // @[Wlink.scala 202:58]
  assign txrouter_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 203:64]
  assign txrouter_auto_in_7_sop = sp2wl_auto_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_7_data_id = sp2wl_auto_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_7_word_count = sp2wl_auto_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_6_sop = tl2wl_auto_wlink_tidelinktl_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_6_data_id = tl2wl_auto_wlink_tidelinktl_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_6_word_count = tl2wl_auto_wlink_tidelinktl_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_6_data = tl2wl_auto_wlink_tidelinktl_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_6_crc = tl2wl_auto_wlink_tidelinktl_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_5_sop = gb2wl_auto_wlink_generalbusgb_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_5_data_id = gb2wl_auto_wlink_generalbusgb_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_5_word_count = gb2wl_auto_wlink_generalbusgb_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_5_data = gb2wl_auto_wlink_generalbusgb_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_5_crc = gb2wl_auto_wlink_generalbusgb_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_4_sop = axi2wl_auto_wlink_axirFC_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_4_data_id = axi2wl_auto_wlink_axirFC_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_4_word_count = axi2wl_auto_wlink_axirFC_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_4_data = axi2wl_auto_wlink_axirFC_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_4_crc = axi2wl_auto_wlink_axirFC_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_3_sop = axi2wl_auto_wlink_axiarFC_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_3_data_id = axi2wl_auto_wlink_axiarFC_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_3_word_count = axi2wl_auto_wlink_axiarFC_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_3_data = axi2wl_auto_wlink_axiarFC_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_3_crc = axi2wl_auto_wlink_axiarFC_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_2_sop = axi2wl_auto_wlink_axibFC_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_2_data_id = axi2wl_auto_wlink_axibFC_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_2_word_count = axi2wl_auto_wlink_axibFC_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_2_data = axi2wl_auto_wlink_axibFC_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_2_crc = axi2wl_auto_wlink_axibFC_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_1_sop = axi2wl_auto_wlink_axiwFC_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_1_data_id = axi2wl_auto_wlink_axiwFC_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_1_word_count = axi2wl_auto_wlink_axiwFC_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_1_data = axi2wl_auto_wlink_axiwFC_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_1_crc = axi2wl_auto_wlink_axiwFC_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_0_sop = axi2wl_auto_wlink_axiawFC_tx_out_sop; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_0_data_id = axi2wl_auto_wlink_axiawFC_tx_out_data_id; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_0_word_count = axi2wl_auto_wlink_axiawFC_tx_out_word_count; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_0_data = axi2wl_auto_wlink_axiawFC_tx_out_data; // @[LazyModule.scala 296:16]
  assign txrouter_auto_in_0_crc = axi2wl_auto_wlink_axiawFC_tx_out_crc; // @[LazyModule.scala 296:16]
  assign txrouter_auto_out_advance = txpstate_auto_in_advance; // @[LazyModule.scala 298:16]
  assign txrouter_io_enable = ~axi2wl_io_tx_reset_tx_link_clk_reset; // @[Wlink.scala 204:46]
  assign txpstate_clock = phy_link_tx_tx_link_clk; // @[Wlink.scala 206:58]
  assign txpstate_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 207:64]
  assign txpstate_auto_in_sop = txrouter_auto_out_sop; // @[LazyModule.scala 298:16]
  assign txpstate_auto_in_data_id = txrouter_auto_out_data_id; // @[LazyModule.scala 298:16]
  assign txpstate_auto_in_word_count = txrouter_auto_out_word_count; // @[LazyModule.scala 298:16]
  assign txpstate_auto_in_data = txrouter_auto_out_data; // @[LazyModule.scala 298:16]
  assign txpstate_auto_in_crc = txrouter_auto_out_crc; // @[LazyModule.scala 298:16]
  assign txpstate_auto_out_advance = lltx_auto_in_advance; // @[LazyModule.scala 298:16]
  assign txpstate_io_swi_delay_cycles = swi_delay_cycles; // @[SW.scala 117:16]
  assign txpstate_io_swi_num_preq_send = out_prepend_swi_num_preq_send; // @[SW.scala 117:16]
  assign txpstate_io_swi_preq_data_id = out_prepend_swi_preq_data_id; // @[Wlink.scala 171:49 SW.scala 117:16]
  assign txpstate_io_swi_cycles_post_preq = out_prepend_swi_cycles_post_preq; // @[SW.scala 117:16]
  assign txpstate_io_tx_ready = phy_link_tx_tx_ready; // @[Wlink.scala 209:43]
  assign rxrouter_auto_in_sop = llrx_auto_out_sop; // @[LazyModule.scala 296:16]
  assign rxrouter_auto_in_data_id = llrx_auto_out_data_id; // @[LazyModule.scala 296:16]
  assign rxrouter_auto_in_word_count = llrx_auto_out_word_count; // @[LazyModule.scala 296:16]
  assign rxrouter_auto_in_data = llrx_auto_out_data; // @[LazyModule.scala 296:16]
  assign rxrouter_auto_in_valid = llrx_auto_out_valid; // @[LazyModule.scala 296:16]
  assign rxrouter_auto_in_crc = llrx_auto_out_crc; // @[LazyModule.scala 296:16]
  assign lltx_clock = phy_link_tx_tx_link_clk; // @[Wlink.scala 191:58]
  assign lltx_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 192:64]
  assign lltx_auto_in_sop = txpstate_auto_out_sop; // @[LazyModule.scala 298:16]
  assign lltx_auto_in_data_id = txpstate_auto_out_data_id; // @[LazyModule.scala 298:16]
  assign lltx_auto_in_word_count = txpstate_auto_out_word_count; // @[LazyModule.scala 298:16]
  assign lltx_auto_in_data = txpstate_auto_out_data; // @[LazyModule.scala 298:16]
  assign lltx_auto_in_crc = txpstate_auto_out_crc; // @[LazyModule.scala 298:16]
  assign lltx_io_enable = out_prepend_swi_lltx_enable & ~swi_sb_reset_in_muxed; // @[Wlink.scala 193:62]
  assign lltx_io_swi_short_packet_max = out_prepend_swi_short_packet_max; // @[Wlink.scala 170:49 SW.scala 117:16]
  assign lltx_io_active_lanes = {{4'd0}, active_tx_lanes}; // @[Wlink.scala 168:48]
  assign lltx_io_lane_mask = swi_tx_lane_mask; // @[Wlink.scala 163:49 SW.scala 117:16]
  assign lltx_io_swi_err_inj = out_prepend_swi_err_inj; // @[SW.scala 117:16]
  assign lltx_io_swi_err_inj_data_id = swi_err_inj_data_id; // @[SW.scala 117:16]
  assign lltx_io_swi_err_inj_byte = out_prepend_swi_err_inj_byte; // @[SW.scala 117:16]
  assign lltx_io_swi_err_inj_bit = out_prepend_swi_err_inj_bit; // @[SW.scala 117:16]
  assign lltx_io_ll_tx_valid = phy_link_tx_tx_ready; // @[Wlink.scala 186:43]
  assign llrx_clock = phy_link_rx_rx_link_clk; // @[Wlink.scala 213:58]
  // ===================================================================
  // SoC Labs tdif-08 L4 option (c) (2026-05-25): hold llrx_reset HIGH for
  // the entire training/recal window so the slave's LL_RX byte-align FSM
  // never sees the asymmetric training-mode filler bytes that latch
  // state==1 prematurely.
  //
  // Root cause (commit 7a6427d on tdif-bisect-ll-rx): the slave LL framer
  // (WlinkRxLinkLayer.state) is released from reset while the master is
  // still emitting training-mode filler. Some filler bytes have
  // ph[7:0]>0x7F (is_long_pkt=1), so state 0->1 latches mid-training and
  // the framer is stuck pointing at filler instead of the first real CR
  // packet once the master drops training and enters FC data mode.
  //
  // The prior L4 attempt (commit 92c2ec7 -- first_short_pkt_seen sticky
  // gate inside WlinkRxLinkLayer.v) was a *consumer-side* heuristic that
  // partially worked (5/12 fuzz PASS) but couldn't survive every clock
  // alignment. Option (c) is a *producer-side* gate: keep llrx_reset
  // asserted while swi_training_mode_in is high. By the time it
  // deasserts, the master TX is already in FC data mode and the first
  // valid byte on the wire is the CR short packet -- state->0 is the only
  // possible transition.
  //
  // CDC: swi_training_mode_in is an apb_clk-domain signal (sourced from
  // axi_chiplet_controller.sv swi_training_mode_r OR'd with autocal's
  // cal_training_mode_w). It must be 2-flop-synced into
  // phy_link_rx_rx_link_clk (== llrx_clock) before being OR'd into
  // llrx_reset. The reset OR uses the *synced* signal so transitions are
  // safe in the rx_link_clk domain.
  //
  // Scope note: swi_recal_r (slot0 bit[1]) is NOT exposed to Wlink -- it
  // only reaches the autocal calibrator inside axi_chiplet_controller.sv.
  // Since the bringup sequence is set_slot0=0x3 -> 0x1 -> 0x0, the
  // training_mode bit (slot0 bit[0]) is held HIGH for the entire window
  // that recal is non-zero, so swi_training_mode_in alone covers the
  // same gating window. Modifying axi_chiplet_controller.sv to also pipe
  // swi_recal in is out of scope for this override (see task
  // constraints).
  // ===================================================================
  // tdif-10 visibility (2026-05-25): expose the option (c) CDC sync chain
  // (pre-CDC swi_training_mode_in, both rxsync stages, and the OR'd
  // llrx_reset itself) to the ILA so we can confirm on real silicon that:
  //   1. swi_training_mode_in is asserted/deasserted as expected by SW
  //   2. the 2-flop CDC fires in the rx_link_clk domain
  //   3. llrx_reset deasserts at the right moment relative to peer TX
  // mark_debug attributes apply at the declaration site; the always block
  // is unmodified.
  reg  swi_training_mode_rxsync_0;     // tdif-10 ILA — CDC stage 1
  reg  swi_training_mode_rxsync_1;     // tdif-10 ILA — CDC stage 2 (drives reset OR)
  always @(posedge phy_link_rx_rx_link_clk or posedge por_reset) begin
    if (por_reset) begin
      swi_training_mode_rxsync_0 <= 1'b1;  // safe default: hold gate HIGH out of POR
      swi_training_mode_rxsync_1 <= 1'b1;
    end else begin
      swi_training_mode_rxsync_0 <= swi_training_mode_in;
      swi_training_mode_rxsync_1 <= swi_training_mode_rxsync_0;
    end
  end

  // tdif-10 visibility (2026-05-25): pre-CDC swi_training_mode_in
  // (apb_clk domain) and the OR'd llrx_reset (rx_link_clk domain) -- mirror
  // these into mark_debug-attributed nets so they appear in the ILA
  // alongside the CDC chain. The mirrors are pure wires; synthesis flattens
  // them but keeps the mark_debug attribute on the resolved net.
  wire dbg_swi_training_mode_in   = swi_training_mode_in;        // tdif-10 ILA — pre-CDC (apb_clk)
  wire dbg_llrx_reset_out;                                       // tdif-10 ILA — final reset (rx_link_clk)
  // Cross-die trigger: framer is stuck post-training-drop when state==1
  // (long-pkt branch latched) AND swi_training_mode_rxsync_1 has fallen
  // back to 0 (gate released). Both dies compute this identically. ILA can
  // trigger on this signal directly in Vivado HW Manager -- no physical pin
  // is needed for the trigger because the dbg_hub is JTAG-only; a SW poll
  // of dbg_framer_stuck across both dies via JTAG gives the same evidence.
  // The signal is also routed through llrx instance hierarchy so it can be
  // used as ILA trigger condition on either side independently.
  wire dbg_framer_stuck = (llrx_io_obs_state == 2'h1) & ~swi_training_mode_rxsync_1; // tdif-10 ILA — cross-die framer-stuck flag (drives via existing llrx obs output)
  // ===================================================================
  // SoC Labs tdif-08 L4 option (c) BILATERAL ATTEMPT (2026-05-25):
  // negative result -- falling-edge holdoff counter does NOT close the
  // bilateral hole. Keeping bare option (c) as the committed behaviour
  // and documenting the failed experiment so future agents don't repeat
  // it without new evidence.
  //
  // Problem statement: bare option (c) leaves 6/12 fuzz scenarios with
  // m.cr=0 s.cr=1 (master-side framer broken). The hypothesis was that
  // when side-A drops training before side-B, A's llrx releases while B
  // is still emitting training-mode filler on the wire -- A's framer
  // latches state==1 on filler.
  //
  // Attempted fix: hold llrx_reset HIGH for N cycles AFTER the falling
  // edge of swi_training_mode_rxsync_1 to cover the peer's worst-case
  // lingering filler. Sized a 10-bit counter (1024 link_clks @ 50 MHz =
  // 20 us) -- comfortably > 1000-cycle stagger but < the 3000-cycle
  // observation window. Also tried 8/11/12-bit widths.
  //
  // Observed failure mode of the holdoff: every counter width (8 -> 12
  // bits) caused the FCSM to get stuck at SEND_CREDITS1 in nearly all
  // scenarios. The reason is *subtler* than the original hypothesis:
  //   * Holding llrx_reset past the falling edge of training causes the
  //     local LL_RX framer to miss the *initial* alignment window.
  //   * When llrx_reset releases DURING peer's FC data mode, the framer
  //     may align on the wrong byte of a real packet (instead of the
  //     first CR short packet that was on the wire at training drop).
  //   * Net effect: the holdoff *prevents* the slave-side bug option (c)
  //     was designed for but *causes* a new "framer-aligned-mid-packet"
  //     failure.
  //
  // Combo experiment (option (c) + L4-v3 first_short_pkt_seen re-enabled
  // in WlinkRxLinkLayer.v): no improvement -- same 6/12 scenarios fail
  // with same polarity. The L4-v3 gate alone latches on the very first
  // short packet which can still be a stale filler byte that happens to
  // have bit[7]=0 (training patterns 0x65/0x4B/0x59/0x2D all do).
  //
  // CONCLUSION: the bilateral structure cannot be resolved by either a
  // per-side time-based gate or a per-side first-short-packet heuristic.
  // A real fix needs one of:
  //   1. Cross-link peer-ready handshake (peer signals "I dropped training
  //      and my TX has flushed filler") -- requires protocol extension.
  //   2. Wire-level alignment beacon (periodic SYNC byte irrespective of
  //      training state) -- requires Wlink RTL change outside overrides.
  //   3. SW orchestration that guarantees BOTH sides drop training within
  //      one PHY clock cycle -- impossible across two independent dies.
  // None are achievable inside the local_overrides scope of this task.
  //
  // Recommendation: take option (c) bare to HW (closes the symmetric
  // bringup case which was the original bug) and treat the remaining
  // 6/12 fuzz failures as a protocol-extension follow-up.
  // ===================================================================
  assign llrx_reset = rx_link_clk_reset_wrs_io_reset_out | swi_training_mode_rxsync_1; // @[Wlink.scala 214:64] SoC Labs L4 option (c)
  assign dbg_llrx_reset_out = llrx_reset;  // tdif-10 ILA mirror — see declaration above
  assign llrx_io_enable = out_prepend_swi_lltx_enable_1; // @[Wlink.scala 174:49 SW.scala 117:16]
  assign llrx_io_swi_short_packet_max = out_prepend_swi_short_packet_max; // @[Wlink.scala 170:49 SW.scala 117:16]
  assign llrx_io_active_lanes = {{4'd0}, active_rx_lanes}; // @[Wlink.scala 169:48]
  assign llrx_io_lane_mask = out_prepend_swi_rx_lane_mask; // @[Wlink.scala 164:49 SW.scala 117:16]
  assign llrx_io_link_data = phy_link_rx_rx_link_data; // @[Wlink.scala 220:43]
  assign axi2wl_clock = apb_clk;
  assign axi2wl_reset = apb_reset;
  assign axi2wl_auto_wlink_axirFC_rx_in_sop = rxrouter_auto_out_5_sop; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axirFC_rx_in_data_id = rxrouter_auto_out_5_data_id; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axirFC_rx_in_word_count = rxrouter_auto_out_5_word_count; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axirFC_rx_in_data = rxrouter_auto_out_5_data; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axirFC_rx_in_valid = rxrouter_auto_out_5_valid; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axirFC_rx_in_crc = rxrouter_auto_out_5_crc; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axirFC_tx_out_advance = txrouter_auto_in_4_advance; // @[LazyModule.scala 296:16]
  assign axi2wl_auto_wlink_axiarFC_rx_in_sop = rxrouter_auto_out_4_sop; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiarFC_rx_in_data_id = rxrouter_auto_out_4_data_id; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiarFC_rx_in_word_count = rxrouter_auto_out_4_word_count; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiarFC_rx_in_data = rxrouter_auto_out_4_data; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiarFC_rx_in_valid = rxrouter_auto_out_4_valid; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiarFC_rx_in_crc = rxrouter_auto_out_4_crc; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiarFC_tx_out_advance = txrouter_auto_in_3_advance; // @[LazyModule.scala 296:16]
  assign axi2wl_auto_wlink_axibFC_rx_in_sop = rxrouter_auto_out_3_sop; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axibFC_rx_in_data_id = rxrouter_auto_out_3_data_id; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axibFC_rx_in_word_count = rxrouter_auto_out_3_word_count; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axibFC_rx_in_data = rxrouter_auto_out_3_data; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axibFC_rx_in_valid = rxrouter_auto_out_3_valid; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axibFC_rx_in_crc = rxrouter_auto_out_3_crc; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axibFC_tx_out_advance = txrouter_auto_in_2_advance; // @[LazyModule.scala 296:16]
  assign axi2wl_auto_wlink_axiwFC_rx_in_sop = rxrouter_auto_out_2_sop; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiwFC_rx_in_data_id = rxrouter_auto_out_2_data_id; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiwFC_rx_in_word_count = rxrouter_auto_out_2_word_count; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiwFC_rx_in_data = rxrouter_auto_out_2_data; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiwFC_rx_in_valid = rxrouter_auto_out_2_valid; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiwFC_rx_in_crc = rxrouter_auto_out_2_crc; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiwFC_tx_out_advance = txrouter_auto_in_1_advance; // @[LazyModule.scala 296:16]
  assign axi2wl_auto_wlink_axiawFC_rx_in_sop = rxrouter_auto_out_1_sop; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiawFC_rx_in_data_id = rxrouter_auto_out_1_data_id; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiawFC_rx_in_word_count = rxrouter_auto_out_1_word_count; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiawFC_rx_in_data = rxrouter_auto_out_1_data; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiawFC_rx_in_valid = rxrouter_auto_out_1_valid; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiawFC_rx_in_crc = rxrouter_auto_out_1_crc; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_wlink_axiawFC_tx_out_advance = txrouter_auto_in_0_advance; // @[LazyModule.scala 296:16]
  assign axi2wl_auto_xbar_in_psel = xbar_auto_out_2_psel; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_xbar_in_penable = xbar_auto_out_2_penable; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_xbar_in_pwrite = xbar_auto_out_2_pwrite; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_xbar_in_paddr = xbar_auto_out_2_paddr; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_xbar_in_pwdata = xbar_auto_out_2_pwdata; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_xbar_in_pstrb = xbar_auto_out_2_pstrb; // @[LazyModule.scala 298:16]
  assign axi2wl_auto_axi_ini_out_aw_ready = axi_ini_0_aw_ready; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_w_ready = axi_ini_0_w_ready; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_b_valid = axi_ini_0_b_valid; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_b_bits_id = axi_ini_0_b_bits_id; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_b_bits_resp = axi_ini_0_b_bits_resp; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_ar_ready = axi_ini_0_ar_ready; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_r_valid = axi_ini_0_r_valid; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_r_bits_id = axi_ini_0_r_bits_id; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_r_bits_data = axi_ini_0_r_bits_data; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_r_bits_resp = axi_ini_0_r_bits_resp; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_ini_out_r_bits_last = axi_ini_0_r_bits_last; // @[Nodes.scala 1210:84 Nodes.scala 1694:56]
  assign axi2wl_auto_axi_tgt_in_aw_valid = axi_tgt_0_aw_valid; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_id = axi_tgt_0_aw_bits_id; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_addr = axi_tgt_0_aw_bits_addr; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_len = axi_tgt_0_aw_bits_len; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_size = axi_tgt_0_aw_bits_size; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_burst = axi_tgt_0_aw_bits_burst; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_lock = axi_tgt_0_aw_bits_lock; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_cache = axi_tgt_0_aw_bits_cache; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_prot = axi_tgt_0_aw_bits_prot; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_aw_bits_qos = axi_tgt_0_aw_bits_qos; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_w_valid = axi_tgt_0_w_valid; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_w_bits_data = axi_tgt_0_w_bits_data; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_w_bits_strb = axi_tgt_0_w_bits_strb; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_w_bits_last = axi_tgt_0_w_bits_last; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_b_ready = axi_tgt_0_b_ready; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_valid = axi_tgt_0_ar_valid; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_id = axi_tgt_0_ar_bits_id; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_addr = axi_tgt_0_ar_bits_addr; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_len = axi_tgt_0_ar_bits_len; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_size = axi_tgt_0_ar_bits_size; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_burst = axi_tgt_0_ar_bits_burst; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_lock = axi_tgt_0_ar_bits_lock; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_cache = axi_tgt_0_ar_bits_cache; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_prot = axi_tgt_0_ar_bits_prot; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_ar_bits_qos = axi_tgt_0_ar_bits_qos; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_auto_axi_tgt_in_r_ready = axi_tgt_0_r_ready; // @[Nodes.scala 1207:84 Nodes.scala 1630:60]
  assign axi2wl_io_app_clk = app_clk_scan_mux_io_o_z; // @[Wlink.scala 128:36 Wlink.scala 183:43]
  assign axi2wl_io_app_reset = app_clk_reset_scan_wrs_io_reset_out; // @[Wlink.scala 129:36 Wlink.scala 184:43]
  assign axi2wl_io_app_enable = swi_enable; // @[Wlink.scala 127:36 SW.scala 117:16]
  assign axi2wl_io_tx_clk = phy_link_tx_tx_link_clk; // @[Wlink.scala 123:36 Wlink.scala 178:43]
  assign axi2wl_io_tx_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 124:36 Wlink.scala 179:43]
  assign axi2wl_io_rx_clk = phy_link_rx_rx_link_clk; // @[Wlink.scala 125:36 Wlink.scala 180:43]
  assign axi2wl_io_rx_reset = rx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 126:36 Wlink.scala 181:43]
  assign gb2wl_clock = apb_clk;
  assign gb2wl_reset = apb_reset;
  assign gb2wl_auto_wlink_generalbusgb_rx_in_sop = rxrouter_auto_out_6_sop; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_wlink_generalbusgb_rx_in_data_id = rxrouter_auto_out_6_data_id; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_wlink_generalbusgb_rx_in_word_count = rxrouter_auto_out_6_word_count; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_wlink_generalbusgb_rx_in_data = rxrouter_auto_out_6_data; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_wlink_generalbusgb_rx_in_valid = rxrouter_auto_out_6_valid; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_wlink_generalbusgb_rx_in_crc = rxrouter_auto_out_6_crc; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_wlink_generalbusgb_tx_out_advance = txrouter_auto_in_5_advance; // @[LazyModule.scala 296:16]
  assign gb2wl_auto_in_psel = xbar_auto_out_3_psel; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_in_penable = xbar_auto_out_3_penable; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_in_pwrite = xbar_auto_out_3_pwrite; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_in_paddr = xbar_auto_out_3_paddr; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_in_pwdata = xbar_auto_out_3_pwdata; // @[LazyModule.scala 298:16]
  assign gb2wl_auto_in_pstrb = xbar_auto_out_3_pstrb; // @[LazyModule.scala 298:16]
  assign gb2wl_io_app_clk = app_clk_scan_mux_io_o_z; // @[Wlink.scala 128:36 Wlink.scala 183:43]
  assign gb2wl_io_app_reset = app_clk_reset_scan_wrs_io_reset_out; // @[Wlink.scala 129:36 Wlink.scala 184:43]
  assign gb2wl_io_app_enable = swi_enable; // @[Wlink.scala 127:36 SW.scala 117:16]
  assign gb2wl_io_tx_clk = phy_link_tx_tx_link_clk; // @[Wlink.scala 123:36 Wlink.scala 178:43]
  assign gb2wl_io_tx_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 124:36 Wlink.scala 179:43]
  assign gb2wl_io_rx_clk = phy_link_rx_rx_link_clk; // @[Wlink.scala 125:36 Wlink.scala 180:43]
  assign gb2wl_io_rx_reset = rx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 126:36 Wlink.scala 181:43]
  assign gb2wl_bore = gbus_in_wire;
  assign tl2wl_clock = apb_clk;
  assign tl2wl_reset = apb_reset;
  assign tl2wl_auto_wlink_tidelinktl_rx_in_sop = rxrouter_auto_out_7_sop; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_wlink_tidelinktl_rx_in_data_id = rxrouter_auto_out_7_data_id; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_wlink_tidelinktl_rx_in_word_count = rxrouter_auto_out_7_word_count; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_wlink_tidelinktl_rx_in_data = rxrouter_auto_out_7_data; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_wlink_tidelinktl_rx_in_valid = rxrouter_auto_out_7_valid; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_wlink_tidelinktl_rx_in_crc = rxrouter_auto_out_7_crc; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_wlink_tidelinktl_tx_out_advance = txrouter_auto_in_6_advance; // @[LazyModule.scala 296:16]
  assign tl2wl_auto_in_psel = xbar_auto_out_4_psel; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_in_penable = xbar_auto_out_4_penable; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_in_pwrite = xbar_auto_out_4_pwrite; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_in_paddr = xbar_auto_out_4_paddr; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_in_pwdata = xbar_auto_out_4_pwdata; // @[LazyModule.scala 298:16]
  assign tl2wl_auto_in_pstrb = xbar_auto_out_4_pstrb; // @[LazyModule.scala 298:16]
  assign tl2wl_io_app_clk = app_clk_scan_mux_io_o_z; // @[Wlink.scala 128:36 Wlink.scala 183:43]
  assign tl2wl_io_app_reset = app_clk_reset_scan_wrs_io_reset_out; // @[Wlink.scala 129:36 Wlink.scala 184:43]
  assign tl2wl_io_app_enable = swi_enable; // @[Wlink.scala 127:36 SW.scala 117:16]
  assign tl2wl_io_tx_clk = phy_link_tx_tx_link_clk; // @[Wlink.scala 123:36 Wlink.scala 178:43]
  assign tl2wl_io_tx_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 124:36 Wlink.scala 179:43]
  assign tl2wl_io_rx_clk = phy_link_rx_rx_link_clk; // @[Wlink.scala 125:36 Wlink.scala 180:43]
  assign tl2wl_io_rx_reset = rx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 126:36 Wlink.scala 181:43]
  assign tl2wl_bore_1 = tl_in_wire;
  assign sp2wl_auto_rx_in_sop = rxrouter_auto_out_8_sop; // @[LazyModule.scala 298:16]
  assign sp2wl_auto_rx_in_data_id = rxrouter_auto_out_8_data_id; // @[LazyModule.scala 298:16]
  assign sp2wl_auto_rx_in_word_count = rxrouter_auto_out_8_word_count; // @[LazyModule.scala 298:16]
  assign sp2wl_auto_rx_in_valid = rxrouter_auto_out_8_valid; // @[LazyModule.scala 298:16]
  assign sp2wl_auto_tx_out_advance = txrouter_auto_in_7_advance; // @[LazyModule.scala 296:16]
  assign sp2wl_io_app_clk = app_clk_scan_mux_io_o_z; // @[Wlink.scala 128:36 Wlink.scala 183:43]
  assign sp2wl_io_app_reset = app_clk_reset_scan_wrs_io_reset_out; // @[Wlink.scala 129:36 Wlink.scala 184:43]
  assign sp2wl_io_app_enable = swi_enable; // @[Wlink.scala 127:36 SW.scala 117:16]
  assign sp2wl_io_tx_clk = phy_link_tx_tx_link_clk; // @[Wlink.scala 123:36 Wlink.scala 178:43]
  assign sp2wl_io_tx_reset = tx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 124:36 Wlink.scala 179:43]
  assign sp2wl_io_rx_clk = phy_link_rx_rx_link_clk; // @[Wlink.scala 125:36 Wlink.scala 180:43]
  assign sp2wl_io_rx_reset = rx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 126:36 Wlink.scala 181:43]
  assign sp2wl_bore_2 = sp_in_wire;
  assign tx_link_clk_reset_wrs_io_clk = phy_link_tx_tx_link_clk; // @[Wlink.scala 123:36 Wlink.scala 178:43]
  assign tx_link_clk_reset_wrs_io_scan_ctrl = scan_asyncrst_ctrl; // @[Stdcell.scala 327:23]
  assign tx_link_clk_reset_wrs_io_reset_in = por_reset | out_prepend_swi_swreset; // @[Wlink.scala 179:83]
  assign rx_link_clk_reset_wrs_io_clk = phy_link_rx_rx_link_clk; // @[Wlink.scala 125:36 Wlink.scala 180:43]
  assign rx_link_clk_reset_wrs_io_scan_ctrl = scan_asyncrst_ctrl; // @[Stdcell.scala 327:23]
  assign rx_link_clk_reset_wrs_io_reset_in = por_reset | out_prepend_swi_swreset; // @[Wlink.scala 181:83]
  assign app_clk_scan_mux_io_i_sel = scan_mode; // @[Stdcell.scala 150:21]
  assign app_clk_scan_mux_io_i_a = app_clk; // @[Stdcell.scala 151:21]
  assign app_clk_scan_mux_io_i_b = scan_clk; // @[Stdcell.scala 152:21]
  assign app_clk_reset_scan_wrs_io_clk = app_clk_scan_mux_io_o_z; // @[Wlink.scala 128:36 Wlink.scala 183:43]
  assign app_clk_reset_scan_wrs_io_scan_ctrl = scan_asyncrst_ctrl; // @[Stdcell.scala 327:23]
  assign app_clk_reset_scan_wrs_io_reset_in = app_clk_reset | out_prepend_swi_swreset; // @[Wlink.scala 184:88]
  assign ecc_corrected_sp_io_clk_in = phy_link_rx_rx_link_clk; // @[Wlink.scala 251:54]
  assign ecc_corrected_sp_io_clk_in_reset = rx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 252:60]
  assign ecc_corrected_sp_io_data_in = llrx_io_ecc_corrected; // @[Wlink.scala 253:39]
  assign ecc_corrected_sp_io_clk_out = apb_clk; // @[Wlink.scala 255:39]
  assign ecc_corrected_sp_io_clk_out_reset = apb_reset; // @[Wlink.scala 256:39]
  assign ecc_corrupted_sp_io_clk_in = phy_link_rx_rx_link_clk; // @[Wlink.scala 259:54]
  assign ecc_corrupted_sp_io_clk_in_reset = rx_link_clk_reset_wrs_io_reset_out; // @[Wlink.scala 260:60]
  assign ecc_corrupted_sp_io_data_in = llrx_io_ecc_corrupted; // @[Wlink.scala 261:39]
  assign ecc_corrupted_sp_io_clk_out = apb_clk; // @[Wlink.scala 263:39]
  assign ecc_corrupted_sp_io_clk_out_reset = apb_reset; // @[Wlink.scala 264:39]
  assign muxed_pre_mux_io_i_sel = out_prepend_swi_sb_reset_in_mux; // @[Stdcell.scala 150:21]
  assign muxed_pre_mux_io_i_a = sb_reset_in; // @[Stdcell.scala 151:21]
  assign muxed_pre_mux_io_i_b = swi_sb_reset_in; // @[Stdcell.scala 152:21]
  assign ff2_demet_clock = apb_clk;
  assign ff2_demet_reset = apb_reset;
  assign ff2_demet_io_in = crc_errors_0 | crc_errors_1 | crc_errors_2; // @[package.scala 72:59]
  assign ff2_demet_1_clock = apb_clk;
  assign ff2_demet_1_reset = apb_reset;
  assign ff2_demet_1_io_in = ecc_corrected_sp_io_data_out; // @[Stdcell.scala 59:17]
  assign ff2_demet_2_clock = apb_clk;
  assign ff2_demet_2_reset = apb_reset;
  assign ff2_demet_2_io_in = ecc_corrupted_sp_io_data_out; // @[Stdcell.scala 59:17]
  // SoC Labs 2026-07-01: autonomous lane-mask default, gated on a BUILD-ONLY
  // define (TD_AUTO_LANE_MASK_E4) injected by fpga/filelist.tcl's V2 shim
  // materialisation — NOT by the shared TIDELINK_PHY_V2. Why the dedicated
  // define: sims read the v2shims directly (TIDELINK_PHY_V2 defined) whereas the
  // FPGA build materialises them, so a materialisation-only define lets every V2
  // *sim* keep the historical 0xFF default (its 8-lane lock oracles stay green)
  // while only the FPGA build activates 0xE4. Rationale for 0xE4: on the
  // autonomous (nego_en) path NOBODY writes 0x214, so the local tx/rx lane mask
  // must POR to the board's good-lane set (rcp 0x30214=0xe4e4) instead of 0xFF,
  // else the mask-handshake agrees on 8 lanes and Wlink frames across the 4 dead
  // silicon lanes. The manual/SW recipe writes 0x214=0xe4e4 explicitly (rcp line
  // 91) so its behaviour is unchanged. 0xE4 = bridge1 good lanes 2,5,6,7
  // (BOARD-SPECIFIC — gate the filelist injection by a board-config once a
  // second V2 board build exists).
`ifdef TD_AUTO_LANE_MASK_E4
  localparam [7:0] LANE_MASK_RESET = 8'hE4;   // bridge1 good lanes 2,5,6,7
`else
  localparam [7:0] LANE_MASK_RESET = 8'hFF;
`endif
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      swi_tx_lane_mask <= LANE_MASK_RESET;
    end else if (out_f_wivalid_2) begin
      swi_tx_lane_mask <= bundleIn_0_pwdata[7:0];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_rx_lane_mask <= LANE_MASK_RESET;
    end else if (out_f_wivalid_3) begin
      out_prepend_swi_rx_lane_mask <= bundleIn_0_pwdata[15:8];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_swreset <= 1'h0;
    end else if (out_f_wivalid_13) begin
      out_prepend_swi_swreset <= bundleIn_0_pwdata[3];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_lltx_enable <= 1'h1;
    end else if (out_f_wivalid_11) begin
      out_prepend_swi_lltx_enable <= bundleIn_0_pwdata[1];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_crc_errors_int_en <= 1'h1;
    end else if (out_f_wivalid_24) begin
      out_prepend_swi_crc_errors_int_en <= bundleIn_0_pwdata[1];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      crc_errors_w1c_1 <= 1'h0;
    end else begin
      crc_errors_w1c_1 <= ~(~crc_errors_w1c_1 | out_f_wivalid_23 & bundleIn_0_pwdata[0]) | crc_errors_w1c_set;
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_ecc_corrupted_w1c <= 1'h0;
    end else begin
      out_prepend_ecc_corrupted_w1c <= ~(~out_prepend_ecc_corrupted_w1c | out_f_wivalid_29 & bundleIn_0_pwdata[16]) |
        ecc_corrupted_w1c_set;
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_ecc_corrupted_int_en <= 1'h1;
    end else if (out_f_wivalid_30) begin
      out_prepend_swi_ecc_corrupted_int_en <= bundleIn_0_pwdata[17];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_ecc_corrected_w1c <= 1'h0;
    end else begin
      out_prepend_ecc_corrected_w1c <= ~(~out_prepend_ecc_corrected_w1c | out_f_wivalid_26 & bundleIn_0_pwdata[8]) |
        ecc_corrected_w1c_set;
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_ecc_corrected_int_en <= 1'h0;
    end else if (out_f_wivalid_27) begin
      out_prepend_swi_ecc_corrected_int_en <= bundleIn_0_pwdata[9];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      swi_enable <= 1'h1;
    end else if (out_f_wivalid_10) begin
      swi_enable <= bundleIn_0_pwdata[0];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_lltx_enable_1 <= 1'h1;
    end else if (out_f_wivalid_12) begin
      out_prepend_swi_lltx_enable_1 <= bundleIn_0_pwdata[2];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_short_packet_max <= 8'h7f;
    end else if (out_f_wivalid_15) begin
      out_prepend_swi_short_packet_max <= bundleIn_0_pwdata[15:8];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_preq_data_id <= 8'h2;
    end else if (out_f_wivalid_16) begin
      out_prepend_swi_preq_data_id <= bundleIn_0_pwdata[23:16];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      // SoC Labs tdif-04 (2026-05-25): change reset value 16'h6a4 → 16'h0
      // to avoid WlinkTxPstateCtrl PSTATE deadlock at training→FC handoff.
      // See file header for rationale. SW may still write non-zero via APB.
      swi_delay_cycles <= 16'h0;
    end else if (out_f_wivalid_18) begin
      swi_delay_cycles <= bundleIn_0_pwdata[15:0];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_num_preq_send <= 3'h1;
    end else if (out_f_wivalid_19) begin
      out_prepend_swi_num_preq_send <= bundleIn_0_pwdata[18:16];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_cycles_post_preq <= 8'hff;
    end else if (out_f_wivalid_21) begin
      out_prepend_swi_cycles_post_preq <= bundleIn_0_pwdata[31:24];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      swi_sb_reset_in <= 1'h0;
    end else if (out_f_wivalid_5) begin
      swi_sb_reset_in <= bundleIn_0_pwdata[0];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_sb_reset_in_mux <= 1'h0;
    end else if (out_f_wivalid_6) begin
      out_prepend_swi_sb_reset_in_mux <= bundleIn_0_pwdata[1];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      swi_err_inj_data_id <= 8'h0;
    end else if (out_f_wivalid_33) begin
      swi_err_inj_data_id <= bundleIn_0_pwdata[7:0];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_err_inj_byte <= 8'h0;
    end else if (out_f_wivalid_34) begin
      out_prepend_swi_err_inj_byte <= bundleIn_0_pwdata[15:8];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_err_inj_bit <= 3'h0;
    end else if (out_f_wivalid_35) begin
      out_prepend_swi_err_inj_bit <= bundleIn_0_pwdata[18:16];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      out_prepend_swi_err_inj <= 1'h0;
    end else if (out_f_wivalid_37) begin
      out_prepend_swi_err_inj <= bundleIn_0_pwdata[24];
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      crc_errors_w1c_ff3 <= 1'h0;
    end else begin
      crc_errors_w1c_ff3 <= ff2_demet_io_out;
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      ecc_corrected_w1c_ff3 <= 1'h0;
    end else begin
      ecc_corrected_w1c_ff3 <= ff2_demet_1_io_out;
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      ecc_corrupted_w1c_ff3 <= 1'h0;
    end else begin
      ecc_corrupted_w1c_ff3 <= ff2_demet_2_io_out;
    end
  end
  always @(posedge apb_clk or posedge apb_reset) begin
    if (apb_reset) begin
      taken <= 1'h0;
    end else if (_T_32) begin
      taken <= 1'h0;
    end else begin
      taken <= _GEN_170;
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
  swi_tx_lane_mask = _RAND_0[7:0];
  _RAND_1 = {1{`RANDOM}};
  out_prepend_swi_rx_lane_mask = _RAND_1[7:0];
  _RAND_2 = {1{`RANDOM}};
  out_prepend_swi_swreset = _RAND_2[0:0];
  _RAND_3 = {1{`RANDOM}};
  out_prepend_swi_lltx_enable = _RAND_3[0:0];
  _RAND_4 = {1{`RANDOM}};
  out_prepend_swi_crc_errors_int_en = _RAND_4[0:0];
  _RAND_5 = {1{`RANDOM}};
  crc_errors_w1c_1 = _RAND_5[0:0];
  _RAND_6 = {1{`RANDOM}};
  out_prepend_ecc_corrupted_w1c = _RAND_6[0:0];
  _RAND_7 = {1{`RANDOM}};
  out_prepend_swi_ecc_corrupted_int_en = _RAND_7[0:0];
  _RAND_8 = {1{`RANDOM}};
  out_prepend_ecc_corrected_w1c = _RAND_8[0:0];
  _RAND_9 = {1{`RANDOM}};
  out_prepend_swi_ecc_corrected_int_en = _RAND_9[0:0];
  _RAND_10 = {1{`RANDOM}};
  swi_enable = _RAND_10[0:0];
  _RAND_11 = {1{`RANDOM}};
  out_prepend_swi_lltx_enable_1 = _RAND_11[0:0];
  _RAND_12 = {1{`RANDOM}};
  out_prepend_swi_short_packet_max = _RAND_12[7:0];
  _RAND_13 = {1{`RANDOM}};
  out_prepend_swi_preq_data_id = _RAND_13[7:0];
  _RAND_14 = {1{`RANDOM}};
  swi_delay_cycles = _RAND_14[15:0];
  _RAND_15 = {1{`RANDOM}};
  out_prepend_swi_num_preq_send = _RAND_15[2:0];
  _RAND_16 = {1{`RANDOM}};
  out_prepend_swi_cycles_post_preq = _RAND_16[7:0];
  _RAND_17 = {1{`RANDOM}};
  swi_sb_reset_in = _RAND_17[0:0];
  _RAND_18 = {1{`RANDOM}};
  out_prepend_swi_sb_reset_in_mux = _RAND_18[0:0];
  _RAND_19 = {1{`RANDOM}};
  swi_err_inj_data_id = _RAND_19[7:0];
  _RAND_20 = {1{`RANDOM}};
  out_prepend_swi_err_inj_byte = _RAND_20[7:0];
  _RAND_21 = {1{`RANDOM}};
  out_prepend_swi_err_inj_bit = _RAND_21[2:0];
  _RAND_22 = {1{`RANDOM}};
  out_prepend_swi_err_inj = _RAND_22[0:0];
  _RAND_23 = {1{`RANDOM}};
  crc_errors_w1c_ff3 = _RAND_23[0:0];
  _RAND_24 = {1{`RANDOM}};
  ecc_corrected_w1c_ff3 = _RAND_24[0:0];
  _RAND_25 = {1{`RANDOM}};
  ecc_corrupted_w1c_ff3 = _RAND_25[0:0];
  _RAND_26 = {1{`RANDOM}};
  taken = _RAND_26[0:0];
`endif // RANDOMIZE_REG_INIT
  if (apb_reset) begin
    swi_tx_lane_mask = 8'hff;
  end
  if (apb_reset) begin
    out_prepend_swi_rx_lane_mask = 8'hff;
  end
  if (apb_reset) begin
    out_prepend_swi_swreset = 1'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_lltx_enable = 1'h1;
  end
  if (apb_reset) begin
    out_prepend_swi_crc_errors_int_en = 1'h1;
  end
  if (apb_reset) begin
    crc_errors_w1c_1 = 1'h0;
  end
  if (apb_reset) begin
    out_prepend_ecc_corrupted_w1c = 1'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_ecc_corrupted_int_en = 1'h1;
  end
  if (apb_reset) begin
    out_prepend_ecc_corrected_w1c = 1'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_ecc_corrected_int_en = 1'h0;
  end
  if (apb_reset) begin
    swi_enable = 1'h1;
  end
  if (apb_reset) begin
    out_prepend_swi_lltx_enable_1 = 1'h1;
  end
  if (apb_reset) begin
    out_prepend_swi_short_packet_max = 8'h7f;
  end
  if (apb_reset) begin
    out_prepend_swi_preq_data_id = 8'h2;
  end
  if (apb_reset) begin
    // SoC Labs tdif-04 (2026-05-25): see synth reset above.
    swi_delay_cycles = 16'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_num_preq_send = 3'h1;
  end
  if (apb_reset) begin
    out_prepend_swi_cycles_post_preq = 8'hff;
  end
  if (apb_reset) begin
    swi_sb_reset_in = 1'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_sb_reset_in_mux = 1'h0;
  end
  if (apb_reset) begin
    swi_err_inj_data_id = 8'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_err_inj_byte = 8'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_err_inj_bit = 3'h0;
  end
  if (apb_reset) begin
    out_prepend_swi_err_inj = 1'h0;
  end
  if (apb_reset) begin
    crc_errors_w1c_ff3 = 1'h0;
  end
  if (apb_reset) begin
    ecc_corrected_w1c_ff3 = 1'h0;
  end
  if (apb_reset) begin
    ecc_corrupted_w1c_ff3 = 1'h0;
  end
  if (apb_reset) begin
    taken = 1'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
