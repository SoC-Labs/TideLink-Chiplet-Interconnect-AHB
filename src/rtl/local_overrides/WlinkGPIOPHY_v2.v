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
// WlinkGPIOPHY — SoC Labs LOCAL OVERRIDE of deps/tidelink-phy/rtl/wav/
// WlinkGPIOPHY.v (submodule copy stays pristine — the tidelink_lane_deskew_v2
// override idiom). Wired in by flists/tidelink_fpga_v2.flist in place of the
// deps file. ONE deviation from the submodule: the R-A FINALIZE
// ANCHOR-VERIFY pass-through port `anchor_verified` (2026-07-04) — pure
// read-side fan-out of WavD2DGpio.io_anchor_verified (see the WavD2DGpio_v2
// local-override header for the mechanism). No existing net is rewired.
// =============================================================================
// L1 OWNED FORK — TideLink GPIO PHY vendor-layer split (PLAN §1)
//
// Upstream (L0): axi-chiplet-controller @ efe5623, logical/wlink/WlinkGPIOPHY.v
//                Pristine reference twin: rtl/wav/upstream/WlinkGPIOPHY.v
// Drift guard:   scripts/check_wav_drift.sh
//
// Carried fix families vs upstream (thin PHY wrapper):
//   * Parameter threading — USE_CLKBUF (§9 clock fix), USE_T3A (§9 T3a
//     comma-hunt) and WORD_PIN_AUTO (FIX-R-proper) pass-throughs to
//     WavD2DGpio.
//   * SoC Labs §9 — alignment-control input ports sourced from the TideLink
//     chiplet; §9.7 per-lane 4-bit phase-offset port (8 lanes x 4 bits).
//   * FIX-R seed + FIX-R-proper (2026-06-10) — GLOBAL word-window pin port
//     (swi_word_pin_in) and runtime auto-pin select (swi_word_pin_auto_en)
//     threaded into WavD2DGpio.
//
// RULE: regenerating from Chisel must NEVER overwrite this file. Regenerate
// into a scratch area, refresh rtl/wav/upstream/, then port the patches
// forward into this fork by hand.
// =============================================================================
module WlinkGPIOPHY #(
  // SoC Labs §9 clock fix: pass-through to WavD2DGpio.USE_CLKBUF.
  parameter USE_CLKBUF = 1'b0,
  // SoC Labs §9 T3a: pass-through to WavD2DGpio.USE_T3A (per-lane comma-hunt
  // self-aligning RX). Default 0 = sim/ASIC bit-exact; FPGA wrapper sets 1.
  parameter USE_T3A   = 1'b0,
  // SoC Labs FIX-R-proper (2026-06-10): pass-through to
  // WavD2DGpio.WORD_PIN_AUTO (per-lane autonomous word-window pin matcher;
  // see WavD2DGpioRx). Default 1 = present; runtime select below.
  parameter WORD_PIN_AUTO = 1'b1,
  // SoC Labs epoch anchor (2026-06-12, V37 fix #1): pass-through to
  // WavD2DGpio.EPOCH_ANCHOR_EN (training-exit-anchored cross-lane word-EPOCH
  // deskew priming in tidelink_lane_deskew). Default 1 = the fix is IN the
  // datapath; set 0 only for A/B regression against the occupancy-only deskew.
  // DEFAULT 0 (2026-07-17 plumbing fix): matches WavD2DGpio_v2.EPOCH_ANCHOR_EN.
  // Before the fix this defaulted 1 but the value was dropped at the u_deskew
  // instance (hard 1'b0) — a dead knob (banner "master=1 (deskew: m=0)"). Now the
  // param reaches u_deskew, so the default must be 0 to keep the shipping build on
  // SYNC_REANCHOR (the corrector the winscan/autoneg autonomy stack requires).
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
  input          scan_mode,
  input          scan_asyncrst_ctrl,
  input          scan_clk,
  output         scan_out,
  input          por_reset,
  input          link_tx_tx_en,
  output         link_tx_tx_ready,
  input  [127:0] link_tx_tx_link_data,
  input  [7:0]   link_tx_tx_lane_mask,
  output         link_tx_tx_link_clk,
  output [127:0] link_rx_rx_link_data,
  input  [7:0]   link_rx_rx_lane_mask,
  output         link_rx_rx_link_clk,
  output         pad_clk_tx,
  output         pad_tx_0,
  output         pad_tx_1,
  output         pad_tx_2,
  output         pad_tx_3,
  output         pad_tx_4,
  output         pad_tx_5,
  output         pad_tx_6,
  output         pad_tx_7,
  input          pad_clk_rx,
  input          pad_rx_0,
  input          pad_rx_1,
  input          pad_rx_2,
  input          pad_rx_3,
  input          pad_rx_4,
  input          pad_rx_5,
  input          pad_rx_6,
  input          pad_rx_7,
  input          user_hsclk,
  // SoC Labs §9: alignment-control inputs sourced from the TideLink chiplet
  // controller's APB register block (per staging/i2c_train/I2C_TRAIN_PROTOCOL.md).
  // Tie to 0 in environments without the chiplet controller — default OR-mux
  // path inside WavD2DGpio preserves cocotb hierarchical-force behaviour.
  input  [23:0]  swi_bit_slip_in,
  input          swi_training_mode_in,
  // SoC Labs §9.7: per-lane 4-bit phase offset, 8 lanes x 4 bits (lane N
  // at bits [4N+3:4N]). Pass-through to WavD2DGpio, mirroring
  // swi_bit_slip_in. Tie 0 → legacy single-global-phase APB path.
  input  [31:0]  swi_phase_offset_in,
  // SoC Labs FIX-R seed (2026-06-10): GLOBAL word-window pin (third
  // alignment dimension — see WavD2DGpio/WavD2DGpioRx). Tie 4'h0 = legacy.
  input  [3:0]   swi_word_pin_in,
  // SoC Labs FIX-R-proper (2026-06-10): runtime auto-pin select (1 = each
  // lane applies its training-derived window pin; 0 = swi_word_pin_in /
  // legacy). Tie 0 for bit-exact pre-FIX-R-proper behaviour.
  input          swi_word_pin_auto_en,
  // SoC Labs SYNC-insert (V2 LL re-hunt beacon, 2026-06-15) — DEFAULT-OFF.
  //   link_tx_tx_idle  : WlinkTxLinkLayer io_link_idle (inter-packet idle),
  //                      so the SYNC beacon is only inserted in genuine idle.
  //   swi_sync_insert_en: APB feature enable, DEFAULT 0 (Region 8 slot 0 bit[2]
  //                      SWI_SYNC_INSERT_EN, SoC addr 0x44032100). With it 0 the
  //                      inserter is a PURE passthrough and TX is bit-identical
  //                      to today. Tie 0 in environments without the chiplet
  //                      controller — preserves legacy behaviour.
  input          link_tx_tx_idle,
  input          swi_sync_insert_en,
  // SoC Labs SYNC-insert GATE FIX (2026-06-15, PART 2) — DEFAULT-OFF.
  //   swi_sync_force_always: APB control bit (Region 8 slot 0 bit[3]
  //   SWI_SYNC_FORCE_ALWAYS, SoC addr 0x44032100). Pass-through to WavD2DGpio.
  //   Tie 0 = original idle-gated production behaviour (bit-identical).
  input          swi_sync_force_always,
  // SoC Labs HAZARD-3 / N2 fix (2026-08-18) — AUTO_ANCHOR's OWN idle-qualified
  // force path, structurally separate from swi_sync_force_always above. Pure
  // pass-through to WavD2DGpio.io_swi_auto_anchor_force_in; see that port's
  // header comment (WavD2DGpio_v2.v) for the full rationale. Tie 0 in
  // environments without the chiplet controller (bit-identical default-off).
  input          swi_auto_anchor_force,
  // SoC Labs SYNC-insert TX OBSERVABILITY (2026-06-15, PART 1) — read-only.
  //   Pass-through from WavD2DGpio. 16-bit saturating SYNC-insert count + two
  //   live level bits, all in the TX word-clk domain (CDC'd to apb_clk in the
  //   chiplet controller). 0 / quiescent in V1 builds.
  output [15:0]  tx_sync_ins_cnt,
  output         tx_link_idle_level,
  output         tx_training_level,
  // Epoch-anchor engagement observables (fix2, 2026-06-14). Pass-through from
  // WavD2DGpio to the PHY status APB regfile (SWI_EPOCH_STATUS) at tidelink_top.
  // link_rx_clk domain. 0 when EPOCH_ANCHOR_EN=0.
  output         epoch_anchored,
  output [5:0]   epoch_span,
  // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 1/2/3) —
  // pass-through from WavD2DGpio. sync_lane_mask_in is the SW LANE_MASK strap
  // (PART 3, default 0xFF). sync_seen_cnt (16-bit saturating) + sync_seen_lane
  // (8-bit sticky "ever-matched") are the per-lane diagnostics (PART 1);
  // sync_seen_pulse is the live 1-cycle mask-aware match feeding the PART 2
  // robust re-hunt OR in Wlink.v. All RX-link-clk domain. Tie mask 0xFF / leave
  // outputs unconnected in environments without the chiplet controller.
  input  [7:0]   sync_lane_mask_in,
  // SoC Labs RX SYNC-detect Hamming TOLERANCE (2026-06-17) — pass-through to
  // WavD2DGpio.io_sync_tol_in. 0 = EXACT (bit-identical). SW strap (SoC
  // 0x4403_2128 [12:8]). Tie 5'h0 where the chiplet controller is absent.
  input  [4:0]   sync_tol_in,
  output [15:0]  sync_seen_cnt,
  output [7:0]   sync_seen_lane,
  output         sync_seen_pulse,
  // SoC Labs RX RAW-WORD + PERMUTATION observability (2026-06-15, rawobs) —
  // pure read-side pass-through from WavD2DGpio. Decodes the silicon
  // "TX inserts but per_lane_sticky=0" defect: the BEST-MATCH-latched raw
  // post-deskew word + the per-RX-lane carried-slice-index map. All RX-link-clk
  // domain; CDC'd to apb_clk in axi_chiplet_controller.sv. Leave unconnected in
  // environments without the chiplet controller.
  output [127:0] dbg_raw_word,
  output [7:0]   dbg_lane_any_match,
  output [3:0]   dbg_best_popcount,
  output [31:0]  dbg_slice_idx,
  // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override (2026-06-16,
  // perlane-wp) — pass-through to/from WavD2DGpio. sync_obs_clr_in is the APB
  // W1-pulse clear for the CLEARABLE per-lane match oracle (SoC 0x44032100[5]);
  // sync_lane_live is the LIVE per-lane "matched since clear" vector (SoC
  // 0x44032144). word_pin_ovr_in / word_pin_ovr_en_in are the 8x4-bit per-lane
  // word-pin override + 8-bit enable (SoC 0x44032148). Tie {clr=0,ovr=0,en=0}
  // for bit-exact legacy framing.
  input          sync_obs_clr_in,
  output [7:0]   sync_lane_live,
  input  [31:0]  word_pin_ovr_in,
  input  [7:0]   word_pin_ovr_en_in,
  // STICKY-POISON per-lane sync_seen observability (2026-06-23) — pass-through
  // from WavD2DGpio.io_sync_seen_vec. Per-lane deskew SYNC re-anchor sync_seen
  // (which lanes committed a periodic-confirmed SYNC index). RX-link-clk domain;
  // CDC'd to apb_clk in axi_chiplet_controller. SoC 0x4403_215C. 0 unless
  // SYNC_REANCHOR_EN. Leave unconnected where the chiplet controller is absent.
  output [7:0]   sync_seen_vec,
  // DATA-MODE per-lane SYNC HAMMING-DISTANCE OBS (2026-06-25, the winscan
  // metric) — pass-through from WavD2DGpio.io_sync_dist_vec. Per-lane 5-bit
  // Hamming distance of the current word to that lane's SYNC slice. RX-link-clk
  // domain; CDC'd to apb_clk in axi_chiplet_controller. SoC 0x4403_21AC
  // (lane-selected). 0 unless SYNC_REANCHOR_EN. Leave unconnected where the
  // chiplet controller is absent.
  output [39:0]  sync_dist_vec,
  // R-A FINALIZE ANCHOR-VERIFY (2026-07-04, LOCAL OVERRIDE — see file header)
  // — pass-through from WavD2DGpio.io_anchor_verified: sticky "engaged
  // re-anchor delivered >=1 all-active-lane EXACT SYNC word" (cleared by POR /
  // the F3 sync_obs_clr). RX-link-clk domain; 2-FF synced to apb_clk in
  // axi_chiplet_controller (ws_verify_q, the WS_FINALIZE release gate). Leave
  // unconnected where the chiplet controller is absent.
  output         anchor_verified
);
  wire  gpio_clock; // @[PHY.scala 376:27]
  wire  gpio_reset; // @[PHY.scala 376:27]
  wire  gpio_auto_in_psel; // @[PHY.scala 376:27]
  wire  gpio_auto_in_penable; // @[PHY.scala 376:27]
  wire  gpio_auto_in_pwrite; // @[PHY.scala 376:27]
  wire [31:0] gpio_auto_in_pwdata; // @[PHY.scala 376:27]
  wire [3:0] gpio_auto_in_pstrb; // @[PHY.scala 376:27]
  wire  gpio_auto_in_pready; // @[PHY.scala 376:27]
  wire [31:0] gpio_auto_in_prdata; // @[PHY.scala 376:27]
  wire  gpio_io_scan_mode; // @[PHY.scala 376:27]
  wire  gpio_io_scan_asyncrst_ctrl; // @[PHY.scala 376:27]
  wire  gpio_io_scan_clk; // @[PHY.scala 376:27]
  wire  gpio_io_scan_out; // @[PHY.scala 376:27]
  wire  gpio_io_link_tx_tx_en; // @[PHY.scala 376:27]
  wire  gpio_io_link_tx_tx_ready; // @[PHY.scala 376:27]
  wire [127:0] gpio_io_link_tx_tx_link_data; // @[PHY.scala 376:27]
  wire [7:0] gpio_io_link_tx_tx_lane_mask; // @[PHY.scala 376:27]
  wire  gpio_io_link_tx_tx_link_clk; // @[PHY.scala 376:27]
  wire [127:0] gpio_io_link_rx_rx_link_data; // @[PHY.scala 376:27]
  wire [7:0] gpio_io_link_rx_rx_lane_mask; // @[PHY.scala 376:27]
  wire  gpio_io_link_rx_rx_link_clk; // @[PHY.scala 376:27]
  wire  gpio_io_hsclk; // @[PHY.scala 376:27]
  wire  gpio_io_por_reset; // @[PHY.scala 376:27]
  wire  gpio_io_pad_clk_tx; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_0; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_1; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_2; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_3; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_4; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_5; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_6; // @[PHY.scala 376:27]
  wire  gpio_io_pad_tx_7; // @[PHY.scala 376:27]
  wire  gpio_io_pad_clk_rx; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_0; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_1; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_2; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_3; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_4; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_5; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_6; // @[PHY.scala 376:27]
  wire  gpio_io_pad_rx_7; // @[PHY.scala 376:27]
  WavD2DGpio #(.USE_CLKBUF(USE_CLKBUF), .USE_T3A(USE_T3A), .WORD_PIN_AUTO(WORD_PIN_AUTO), .EPOCH_ANCHOR_EN(EPOCH_ANCHOR_EN)) gpio ( // @[PHY.scala 376:27]
    .clock(gpio_clock),
    .reset(gpio_reset),
    .auto_in_psel(gpio_auto_in_psel),
    .auto_in_penable(gpio_auto_in_penable),
    .auto_in_pwrite(gpio_auto_in_pwrite),
    .auto_in_pwdata(gpio_auto_in_pwdata),
    .auto_in_pstrb(gpio_auto_in_pstrb),
    .auto_in_pready(gpio_auto_in_pready),
    .auto_in_prdata(gpio_auto_in_prdata),
    .io_scan_mode(gpio_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpio_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpio_io_scan_clk),
    .io_scan_out(gpio_io_scan_out),
    .io_link_tx_tx_en(gpio_io_link_tx_tx_en),
    .io_link_tx_tx_ready(gpio_io_link_tx_tx_ready),
    .io_link_tx_tx_link_data(gpio_io_link_tx_tx_link_data),
    .io_link_tx_tx_lane_mask(gpio_io_link_tx_tx_lane_mask),
    .io_link_tx_tx_link_clk(gpio_io_link_tx_tx_link_clk),
    .io_link_rx_rx_link_data(gpio_io_link_rx_rx_link_data),
    .io_link_rx_rx_lane_mask(gpio_io_link_rx_rx_lane_mask),
    .io_link_rx_rx_link_clk(gpio_io_link_rx_rx_link_clk),
    .io_hsclk(gpio_io_hsclk),
    .io_por_reset(gpio_io_por_reset),
    .io_pad_clk_tx(gpio_io_pad_clk_tx),
    .io_pad_tx_0(gpio_io_pad_tx_0),
    .io_pad_tx_1(gpio_io_pad_tx_1),
    .io_pad_tx_2(gpio_io_pad_tx_2),
    .io_pad_tx_3(gpio_io_pad_tx_3),
    .io_pad_tx_4(gpio_io_pad_tx_4),
    .io_pad_tx_5(gpio_io_pad_tx_5),
    .io_pad_tx_6(gpio_io_pad_tx_6),
    .io_pad_tx_7(gpio_io_pad_tx_7),
    .io_pad_clk_rx(gpio_io_pad_clk_rx),
    .io_pad_rx_0(gpio_io_pad_rx_0),
    .io_pad_rx_1(gpio_io_pad_rx_1),
    .io_pad_rx_2(gpio_io_pad_rx_2),
    .io_pad_rx_3(gpio_io_pad_rx_3),
    .io_pad_rx_4(gpio_io_pad_rx_4),
    .io_pad_rx_5(gpio_io_pad_rx_5),
    .io_pad_rx_6(gpio_io_pad_rx_6),
    .io_pad_rx_7(gpio_io_pad_rx_7),
    // SoC Labs §9: APB-driven alignment-control inputs.
    // Pass-through to module boundary so the TideLink chiplet controller
    // drives them from its APB register block (per staging/i2c_train/
    // I2C_TRAIN_PROTOCOL.md §3.1). cocotb hierarchical-force path still
    // works via the OR-mux inside WavD2DGpio.
    .io_swi_bit_slip_in(swi_bit_slip_in),
    .io_swi_training_mode_in(swi_training_mode_in),
    .io_swi_phase_offset_in(swi_phase_offset_in),
    .io_swi_word_pin_in(swi_word_pin_in), // FIX-R seed: global window pin
    .io_swi_word_pin_auto_en(swi_word_pin_auto_en), // FIX-R-proper: runtime auto-pin select
    .io_link_tx_tx_idle(link_tx_tx_idle),          // SYNC-insert: LL inter-packet idle gate
    .io_swi_sync_insert_en_in(swi_sync_insert_en), // SYNC-insert: APB feature enable (DEFAULT 0)
    .io_swi_sync_force_always_in(swi_sync_force_always), // PART2 gate fix: drop idle term (DEFAULT 0)
    .io_swi_auto_anchor_force_in(swi_auto_anchor_force), // HAZARD-3/N2 fix: auto_anchor's own idle-qualified force (DEFAULT 0)
    .io_tx_sync_ins_cnt(tx_sync_ins_cnt),          // PART1 obs: TX SYNC-insert sat. count
    .io_tx_link_idle_level(tx_link_idle_level),    // PART1 obs: live tx_idle level
    .io_tx_training_level(tx_training_level),       // PART1 obs: live training level
    .io_epoch_anchored(epoch_anchored),  // fix2: epoch-anchor obs -> APB status
    .io_epoch_span(epoch_span),
    // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 1/2/3)
    .io_sync_lane_mask_in(sync_lane_mask_in),         // PART3 SW LANE_MASK strap
    .io_sync_tol_in(sync_tol_in),                     // 2026-06-17 Hamming tolerance (0=exact)
    .io_sync_seen_cnt(sync_seen_cnt),                 // PART1 obs: mask-aware sat. count
    .io_sync_seen_lane_sticky(sync_seen_lane),        // PART1 obs: per-lane sticky vector
    .io_sync_seen_pulse(sync_seen_pulse),             // PART2 robust re-hunt source
    .io_dbg_raw_word(dbg_raw_word),                   // rawobs: best-match raw word
    .io_dbg_lane_any_match(dbg_lane_any_match),       // rawobs: fixed-pos match vector
    .io_dbg_best_popcount(dbg_best_popcount),         // rawobs: popcount of that vector
    .io_dbg_slice_idx(dbg_slice_idx),                 // rawobs: per-lane carried-slice map
    // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override (perlane-wp)
    .io_sync_obs_clr_in(sync_obs_clr_in),             // perlane-wp: clearable-oracle clear pulse
    .io_sync_lane_live(sync_lane_live),               // perlane-wp: live per-lane match vector
    .io_word_pin_ovr_in(word_pin_ovr_in),             // perlane-wp: 8x4b per-lane window pin
    .io_word_pin_ovr_en_in(word_pin_ovr_en_in),       // perlane-wp: 8b per-lane override enable
    .io_sync_seen_vec(sync_seen_vec),                 // sticky-poison: per-lane deskew sync_seen -> APB
    .io_sync_dist_vec(sync_dist_vec),                 // winscan metric: per-lane SYNC Hamming distance -> APB
    .io_anchor_verified(anchor_verified)              // R-A anchor-verify: engaged-anchor exact-beacon sticky -> winscan gate
  );
  assign auto_in_pready = gpio_auto_in_pready; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign auto_in_prdata = gpio_auto_in_prdata; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign scan_out = 1'h0;
  assign link_tx_tx_ready = gpio_io_link_tx_tx_ready; // @[PHY.scala 408:32]
  assign link_tx_tx_link_clk = gpio_io_link_tx_tx_link_clk; // @[PHY.scala 408:32]
  assign link_rx_rx_link_data = gpio_io_link_rx_rx_link_data; // @[PHY.scala 409:32]
  assign link_rx_rx_link_clk = gpio_io_link_rx_rx_link_clk; // @[PHY.scala 409:32]
  assign pad_clk_tx = gpio_io_pad_clk_tx; // @[PHY.scala 410:32]
  assign pad_tx_0 = gpio_io_pad_tx_0; // @[PHY.scala 410:32]
  assign pad_tx_1 = gpio_io_pad_tx_1; // @[PHY.scala 410:32]
  assign pad_tx_2 = gpio_io_pad_tx_2; // @[PHY.scala 410:32]
  assign pad_tx_3 = gpio_io_pad_tx_3; // @[PHY.scala 410:32]
  assign pad_tx_4 = gpio_io_pad_tx_4; // @[PHY.scala 410:32]
  assign pad_tx_5 = gpio_io_pad_tx_5; // @[PHY.scala 410:32]
  assign pad_tx_6 = gpio_io_pad_tx_6; // @[PHY.scala 410:32]
  assign pad_tx_7 = gpio_io_pad_tx_7; // @[PHY.scala 410:32]
  assign gpio_clock = clock;
  assign gpio_reset = reset;
  assign gpio_auto_in_psel = auto_in_psel; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign gpio_auto_in_penable = auto_in_penable; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign gpio_auto_in_pwrite = auto_in_pwrite; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign gpio_auto_in_pwdata = auto_in_pwdata; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign gpio_auto_in_pstrb = auto_in_pstrb; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign gpio_io_scan_mode = scan_mode; // @[Bundles.scala 19:19]
  assign gpio_io_scan_asyncrst_ctrl = scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpio_io_scan_clk = scan_clk; // @[Bundles.scala 21:19]
  assign gpio_io_link_tx_tx_en = link_tx_tx_en; // @[PHY.scala 408:32]
  assign gpio_io_link_tx_tx_link_data = link_tx_tx_link_data; // @[PHY.scala 408:32]
  assign gpio_io_link_tx_tx_lane_mask = link_tx_tx_lane_mask; // @[PHY.scala 408:32]
  assign gpio_io_link_rx_rx_lane_mask = link_rx_rx_lane_mask; // @[PHY.scala 409:32]
  assign gpio_io_hsclk = user_hsclk; // @[PHY.scala 407:32]
  assign gpio_io_por_reset = por_reset; // @[PHY.scala 406:32]
  assign gpio_io_pad_clk_rx = pad_clk_rx; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_0 = pad_rx_0; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_1 = pad_rx_1; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_2 = pad_rx_2; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_3 = pad_rx_3; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_4 = pad_rx_4; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_5 = pad_rx_5; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_6 = pad_rx_6; // @[PHY.scala 410:32]
  assign gpio_io_pad_rx_7 = pad_rx_7; // @[PHY.scala 410:32]
endmodule
