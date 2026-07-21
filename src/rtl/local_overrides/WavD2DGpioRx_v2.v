// =============================================================================
// WavD2DGpioRx — SoC Labs LOCAL OVERRIDE of deps/tidelink-phy/rtl/wav/
// WavD2DGpioRx.v (submodule copy stays pristine — the WavD2DGpio_v2 /
// tidelink_lane_deskew_v2 override idiom). Wired in by
// flists/tidelink_fpga_v2.flist + flists/tidelink_top_full_asic_v2.flist in
// place of the deps file.
//
// NOTE: this is the *V2* fork. It is a DIFFERENT file from
// src/rtl/local_overrides/WavD2DGpioRx.v (the V1 override, still owned by the
// V1 flists). Same module name — never co-compile V1 and V2.
//
// ONE functional deviation from the submodule:
//
//   PHASE-B SHARED CAPTURE-CLOCK BUFG (2026-07-14): new parameter
//   USE_EXT_CAP_CLK + new inputs io_cnt_clk_ext / io_cap_clk_ext. When the
//   parameter is set, the lane takes its two capture-side clocks from the
//   PARENT (WavD2DGpio_v2), which computes the io_pol/scan mux chain ONCE and
//   drives both results through a single global buffer each.
//
//   WHY: all four mux inputs are IDENTICAL on all 8 lanes
//   (io_pad_clk=io_pad_clk_rx, io_scan_mode, io_scan_clk,
//   io_pol=out_prepend_swi_polarity), so Vivado legally merged the 8 per-lane
//   mux chains into ONE LUT and drove all 8 lanes' capture flops from its
//   fanout-372 GENERAL-ROUTING output. Measured routed capture-clock delay:
//   lanes 2/5/6 = 8.230/8.604/8.808 ns but lane 7 = 15.281 ns (~7 ns out),
//   while data-path skew across the same lanes is only 0.095 ns. The clock
//   tree — not the logic — is the defect behind the placement-varying
//   bring-up lottery. Hoisting the (already lane-identical) mux chain into the
//   parent and buffering it puts the capture clock on a global net with
//   near-zero inter-lane skew.
//
//   USE_EXT_CAP_CLK=0 (sim/ASIC default) is BIT-IDENTICAL to the submodule:
//   the two new inputs are simply unused and the existing branches are
//   untouched.
// =============================================================================
// L1 OWNED FORK — TideLink GPIO PHY vendor-layer split (PLAN §1)
//
// Upstream (L0): axi-chiplet-controller @ efe5623, logical/wlink/WavD2DGpioRx.v
//                Pristine reference twin: rtl/wav/upstream/WavD2DGpioRx.v
// Drift guard:   scripts/check_wav_drift.sh
//
// Carried fix families vs upstream (per-lane RX deserialiser):
//   * SoC Labs §9 clock fix (2026-05-19) — clean per-lane recovered-clock
//     path; GLITCH-FREE word clock: io_link_clk derived from the
//     FREE-RUNNING ~count[3] (glitch fix 2026-06-09, incl. BUFG of the
//     free-running net on the USE_CLKBUF path so live io_phase_offset
//     changes can never glitch the rx word-clock domain).
//   * SoC Labs §9 T3a (2026-05-19) — self-aligning RX comma-hunt word-
//     boundary FSM; tdif-04/tdif-06 (2026-05-25) BOUNDED continuous re-arm.
//   * SoC Labs alignment patch (2026-05-05) — software-programmable
//     deserialiser phase offset (rotated bit-position selector).
//   * SoC Labs bit-slip patch (2026-05-13, BRINGUP_REPORT §9) — per-lane
//     right-rotation by io_bit_slip.
//   * FIX-N (2026-06-10) — RACE-FREE bit->word handoff: completed word
//     registered in the BIT-CLOCK domain; sim-only skew-model hook
//     (default 0 = inert).
//   * FIX-Q-RX (2026-06-10) — REGISTERED in-flight bit in the completed-word
//     register (margins 7.5/8.5 bit-cells; chicken bit for legacy FIX-N load).
//   * FIX-R seed + FIX-R-proper / WORD_PIN_AUTO (2026-06-10) — word-window
//     pin slides the completed-word window; autonomous per-lane window-pin
//     matcher behind the WORD_PIN_AUTO compile chicken bit and the runtime
//     auto-pin select.
//
// RULE: regenerating from Chisel must NEVER overwrite this file. Regenerate
// into a scratch area, refresh rtl/wav/upstream/, then port the patches
// forward into this fork by hand.
// =============================================================================
// =============================================================================
// SoC Labs LOCAL OVERRIDE: WavD2DGpioRx.v
//
// Source: deps/axi-chiplet-controller/logical/wlink/WavD2DGpioRx.v (463 lines)
// Override reason (tdif-04, Layer 3 fix): mirror tdif-03 TX per-lane word-
// align with a per-lane RX continuous re-arm of the T3A comma-hunt FSM.
//
// Background
// ----------
// The base WavD2DGpioRx (T3A=1) implements a ONE-SHOT comma-hunt: after
// io_por_reset, S_SETTLE → S_HUNT → S_LOCKED. S_LOCKED is a sticky terminal
// state, only exited by another POR. On HW (tdif-03) the slave's
// WavD2DGpioRx.count locked once during the initial training window but did
// NOT re-arm on the post-training-drop FC data, leaving slave's llrx/valid=0
// (byte-stream-deaf). The TX-side per-lane word-align fix doesn't touch the
// RX deserialiser.
//
// Fix (tdif-06, Layer 3 — bounded re-arm)
// ---------------------------------------
// tdif-04 attempted continuous re-arm with a single-cycle S_LOCKED dwell
// and FAILED: re-arm 1 cycle later saw the same training-byte pattern
// still in the shifter and slipped repeatedly, drifting `count`. Both
// sim (cocotb/wavd2d_gpiorx_t3a/test_t3a_invariance, T3A_CONT=1) and HW
// (tdif-04 POR, 0 lanes locked) confirmed the failure.
//
// tdif-06 retains continuous re-arm but BOUNDS the S_LOCKED dwell. When
// T3A_CONTINUOUS=1 the FSM stays in S_LOCKED for DWELL_MAX (=63) cycles
// before transitioning back to S_HUNT. By that time the realign_shifter
// has refreshed past the training-byte pattern that produced the prior
// lock, so the next match (if any) reflects the CURRENT count phase:
// slip=0 during steady training (no drift), no match during FC data
// (S_HUNT's MAX_HUNT timeout returns to S_LOCKED with do_slip=0,
// preserving count — bit-exact to one-shot lock), correct slip during
// re-training with a new phase.
//
// Bit-exactness
// -------------
// With T3A_CONTINUOUS=0 the override is byte-identical behaviour of the
// base RTL: S_LOCKED is a terminal state again. ASIC/sim regression A/B.
// The DWELL_MAX counter and the dwell branch are gated by the parameter
// so synthesis prunes them out when CONTINUOUS=0.
//
// Coverage
// --------
//   * Cocotb test_t3a_realign already exercises the one-shot path; an
//     extended test should re-arm by re-asserting training pattern.
//
// Author: SoC Labs (2026-05-25)
// Linked to: docs/TIDELINK_HANDOFF_2026_05_25.md (Layer 3)
// =============================================================================
module WavD2DGpioRx #(
  // SoC Labs tdif-04 (2026-05-25): when 1, T3A FSM continuously re-arms
  // (S_LOCKED is no longer terminal) so a peer re-entering training mode
  // gets re-aligned WITHOUT needing a full io_por_reset.
  //
  // tdif-05 (2026-05-25): DEFAULT FORCED TO 0. The 1-cycle S_LOCKED dwell
  // drifts `count` between word boundaries on every re-arm — see sim
  // commit 7153727 (test_t3a_invariance fails 8/8 lanes) and HW tdif-04
  // POR (0 lanes locked). A correct continuous design needs widened
  // dwell or no-match-in-N gating.
  //
  // tdif-06 (2026-05-25): DEFAULT BACK TO 1, with BOUNDED dwell. The
  // S_LOCKED branch below now dwells DWELL_MAX (=63, see localparam) cycles
  // before re-entering S_HUNT. This refreshes the realign_shifter past the
  // tdif-04 drift bug and lets steady training re-match at slip=0. During
  // FC data, S_HUNT's MAX_HUNT timeout returns to S_LOCKED with do_slip=0
  // (count preserved). During re-training with new phase, the next match
  // applies the correct slip. Sim coverage in cocotb/wavd2d_gpiorx_t3a.
  parameter T3A_CONTINUOUS = 1'b0,
  // SoC Labs §9 clock fix (2026-05-19): per-lane clean recovered-clock path.
  // Netlist evidence (Place 30-568 ×7 on pynq-z2-pair-all) proved the
  // WavClockMux io_pol/scan muxes + the ~adj_count[3] divided word-clock
  // synthesise into fabric LUTs driving 16 capture-flop clock pins per
  // lane on general routing. io_pol = out_prepend_swi_polarity reg (reset
  // 0, never written by calibrator/deploy) and io_scan_mode are PROVEN
  // static-0 in the FPGA bring-up flow ⇒ bypassing the muxes is
  // functionally safe.
  //   USE_CLKBUF=0 (sim/ASIC/UVM default) → original behaviour through
  //                 the WavClockMux chain. Bit-exact, NO Xilinx primitive
  //                 elaborated (the generate-if prunes the BUFG branch).
  //   USE_CLKBUF=1 (FPGA only) → BUFG the two derived per-lane clocks
  //                 (capture clock = io_pad_clk; divided word clock =
  //                 ~adj_count[3]) so each lane's clock reaches its
  //                 capture flops on the dedicated clock network.
  // Param-threaded from tidelink_vivado_wrapper (default 1'b1) through
  // tidelink_top / axi_chiplet_controller / Wlink / WlinkGPIOPHY /
  // WavD2DGpio — same mechanism that put tidelink_rxclk_buf's BUFG on
  // the IP boundary; carried via the packaged IP's component.xml.
  //
  // Target A (2026-05-28, see docs/TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md):
  //   USE_CLKBUF is now a backward-compat DEPRECATED ALIAS that sets BOTH
  //   USE_CAP_CLKBUF and USE_LNK_CLKBUF when the latter aren't overridden.
  //   Splitting the parameter lets the BD do a single IBUFG→BUFG on
  //   pad_clk_rx at the boundary (one global clock net, low pad load),
  //   while still keeping the divided word-clock per-lane BUFG which is
  //   driven by a fabric-derived signal (~adj_count[3]) and therefore
  //   still needs its own BUFG inside each lane.
  //
  //   New parameters:
  //     USE_CAP_CLKBUF (default = USE_CLKBUF) — BUFG on io_pad_clk
  //                    (capture clock). Set 0 when the BD already routes
  //                    pad_clk_rx through a single global IBUFG→BUFG so
  //                    we don't multiply the pad capacitive load.
  //     USE_LNK_CLKBUF (default = USE_CLKBUF) — BUFG on ~adj_count[3]
  //                    (derived word clock). Keep 1 for FPGA (the
  //                    divided clock is fabric-LUT-driven and otherwise
  //                    triggers Place 30-568 LUT-driving-clock warnings).
  //
  //   Existing callers passing USE_CLKBUF=1 alone still get the legacy
  //   both-BUFG behaviour; Target A passes the new params directly with
  //   USE_CAP_CLKBUF=0 + USE_LNK_CLKBUF=1.
  parameter USE_CLKBUF     = 1'b0,
  parameter USE_CAP_CLKBUF = USE_CLKBUF,
  parameter USE_LNK_CLKBUF = USE_CLKBUF,
  // ==========================================================================
  // SoC Labs PHASE-B SHARED CAPTURE-CLOCK (2026-07-14): USE_EXT_CAP_CLK.
  //
  // Takes the two capture-side clocks (w_cnt_clk, w_pad_clk) straight from the
  // parent via io_cnt_clk_ext / io_cap_clk_ext, instead of re-deriving them
  // from this lane's own local WavClockMux chain. HIGHEST PRIORITY — overrides
  // USE_CAP_CLKBUF.
  //
  // This is legal ONLY because every input to the capture mux chain is
  // lane-identical by construction in WavD2DGpio_v2: io_pad_clk = io_pad_clk_rx,
  // io_scan_mode, io_scan_clk and io_pol = out_prepend_swi_polarity are all the
  // SAME nets on all 8 lanes. The parent therefore builds ONE copy of the exact
  // same chain (same Stdcell modules, same port order, same select polarity),
  // buffers each of the two outputs once, and fans them to all 8 lanes. The
  // *logical* clock each lane sees is unchanged — including the io_pol
  // inversion (see the WARNING on g_cap_bufg below). Only the physical net
  // changes: a dedicated global buffer instead of a shared fanout-372 general-
  // routing LUT output.
  //
  // Default 0 => bit-identical to the submodule (inputs unused).
  parameter USE_EXT_CAP_CLK = 1'b0,
  // SoC Labs §9 T3a self-aligning RX (2026-05-19): comma-hunt word-boundary
  // realignment. The per-lane count free-runs mod-16 starting from
  // io_por_reset, so the relative byte-boundary phase between master and
  // slave is per-deploy random in a 16-cycle window (root cause of the
  // anti-correlated lock-count lottery the HW saw 12 deploys in a row:
  // master 8/8 ↔ slave 8/8 NEVER SIMULTANEOUSLY).
  //
  // With USE_T3A=1, during the (peer-driven) training byte stream the RX
  // captures the 8 most-recent io_pad bits into a shift register, compares
  // it cyclically against all 8 rotations of TRAINING_BYTE, and when one
  // rotation matches it slips `count` by the matching rotation so the next
  // 16-bit deserialised word lines up with byte boundaries. After the slip
  // the FSM moves to S_LOCKED and never re-arms; existing
  // io_phase_offset / io_bit_slip / IDELAYE2 calibration continues normally
  // but only needs to compensate for sub-bit-cell skew, not the 16-cycle
  // count-phase lottery.
  //
  // USE_T3A=0 (sim/ASIC/UVM default) → pure passthrough: `count` behaves
  //   EXACTLY as before (4'hf init, +1 every w_cnt_clk cycle). Bit-exact;
  //   the realign FSM, shifter, and hunt-counter logic are gated out by
  //   the constant generate-if and contribute no flops/luts.
  // USE_T3A=1 (FPGA only) → one-shot realignment per io_por_reset.
  //
  // TRAINING_BYTE is the per-instance training byte the lane's peer TX
  // emits during training_mode. WavD2DGpio.v overrides this per-lane to
  // match the WavD2DGpioTx io_training_pattern wired up there (lane 0 →
  // 0xA3, …, lane 7 → 0x2D — period-8 aperiodic, unique under rotation).
  // Default 8'h00 is safe (every rotation matches all-zeros — the slip
  // would be 0, i.e. no-op, so USE_T3A=1 with a zero TRAINING_BYTE is
  // still bit-exact passthrough of the legacy free-run behaviour).
  parameter [7:0] TRAINING_BYTE = 8'h00,
  parameter USE_T3A = 1'b0,
  // SoC Labs FIX-Q-RX (2026-06-10): REGISTERED in-flight bit. 1 (default) =
  // link_data_word loads one bit-cell after the wrap (count==0 falling
  // edge) from the assembly FLOP OUTPUTS only — no combinational io_pad tap
  // in the completed-word register; value sequence bit-identical to FIX-N
  // (margins 7.5/8.5 bit-cells, was 8/8). 0 = legacy FIX-N in-flight load
  // at count==15 (A/B). See the generate block at the link_data_word
  // register for the full rationale.
  parameter RX_WORD_REG_PURE = 1'b1,
  // ==========================================================================
  // SoC Labs FIX-R-proper (2026-06-10): AUTONOMOUS word-window pin.
  //
  // ROOT CAUSE the seed knob exposed: the completed-word WINDOW is pinned by
  // the free-running `count` against the incoming stream, and that
  // relationship is a PER-CARRIER-SESSION LOTTERY mod 16 on HW — `count`
  // (clocked by the peer's GATED forwarded clock: WavD2DGpioTx io_pad_clk =
  // WavClockGate(clk_en_qual), forwarded as-is by the board ODDR) freezes
  // while the peer's gate is down, and the offset it holds vs the peer's TX
  // word boundary is (re)established by events asynchronous to that boundary
  // (POR/reset release or count INIT vs an already-running peer clock;
  // fabric-LUT clock-gate enable-edge transients / ribbon burst-boundary
  // ringing adding or losing edges per gate cycle on HW). (slip, phase) are
  // pure ROTATIONS of the captured word — no rotation can ever move the
  // WINDOW — so a lost lottery is the un-sweepable 1-2^-m dirty-word floor
  // the autonomous calibrator is structurally blind to (manual winscan/park
  // was the only cure).
  //
  // FIX (deterministic re-pin from training — design (a)): the training
  // stream is the ONLY thing that carries the TX word boundary across the
  // seam, and the per-lane 16-bit training word (TRAINING_WORD16, full
  // period-16: no nontrivial rotation maps it to itself) makes that boundary
  // OBSERVABLE in the raw serial stream. A 16-bit shifter samples io_pad on
  // the SAME w_pad_clk edges the data assembly uses; when the shifter equals
  // the as-transmitted pattern (bit-reversed: first-sent bit oldest = MSB),
  // the current edge IS the aligned window-load instant, so the required pin
  // is simply the `count` value visible at that edge. The candidate must
  // re-confirm at exactly +16-edge periodicity (same count) WPA_CONFIRM
  // consecutive times before committing — a PRBS/data false 16-bit match
  // (2^-16/word) cannot recur periodically (joint rate ~2^-64), so the
  // matcher self-gates to training with NO mode plumbing, and every training
  // session (re-arm, re-bring-up, post-restart) re-pins automatically.
  //
  // The matcher never references io_phase_offset / io_bit_slip (rotations
  // remain the calibrator's axes) and commits in <= 5 training words —
  // long before any sweep dwell scores. Aligned case commits pin 0
  // (bit-exact steady-state vs legacy framing).
  //
  // Controls:
  //   WORD_PIN_AUTO       compile chicken bit; 0 prunes the matcher and
  //                       reverts the load decode to io_word_pin (bit-exact
  //                       pre-FIX-R-proper).
  //   io_word_pin_auto_en runtime chicken bit (APB: ~BIT_SLIP_OVR[28] and
  //                       ~CTRL.cal_override_en in the BIST core). 0 =
  //                       io_word_pin applies (manual winscan path
  //                       unchanged); 1 = the committed auto pin applies.
  //   TRAINING_WORD16     per-lane as-transmitted constant training word
  //                       ({TRAINING_PATTERN_HI, io_training_pattern} of the
  //                       peer's WavD2DGpioTx). 16'h0000 disables the
  //                       matcher (idle/zero streams must never re-pin).
  // Applies to the RX_WORD_REG_PURE=1 branch only (the deployed config), as
  // io_word_pin already does.
  // ==========================================================================
  parameter WORD_PIN_AUTO = 1'b1,
  parameter [15:0] TRAINING_WORD16 = 16'h0000
) (
  input         io_scan_mode,
  input         io_scan_asyncrst_ctrl,
  input         io_scan_clk,
  output        io_scan_out,
  input         io_por_reset,
  input         io_pol,
  // SoC Labs alignment patch (2026-05-05): software-programmable phase
  // offset added to the deserialiser's bit-position selector. Default 0
  // matches the original RTL. SW sweeps 0..15 via the GPIO PHY Control
  // register to find the phase at which slave_count_rx aligns with
  // master_count_tx. Effect propagates within 16 pad_clk_rx cycles
  // without needing a full POR (which the swi_swreset path doesn't reach).
  input  [3:0]  io_phase_offset,
  // SoC Labs bit-slip patch (2026-05-13, BRINGUP_REPORT §9): per-lane bit-slip
  // applied to the captured 16-bit deserialised word *after* it leaves the
  // serial-to-parallel pipeline. This corrects sub-byte misalignment caused by
  // the FPGA's IBUF/IOFF chain (which `io_phase_offset` cannot fix because it
  // is a sub-bit-cell sample-point selector, not a bit-rotation). Default 0
  // = bit-exact passthrough of the existing RTL.
  input  [2:0]  io_bit_slip,
  // SoC Labs FIX-R seed (2026-06-10): WORD-WINDOW PIN — slides the completed-
  // word load decode (the 16-capture WINDOW cut) by 0..15 capture cells.
  // slip/phase are pure rotations and CANNOT move the window; this is the
  // third, previously-unreachable alignment dimension (the un-sweepable
  // 1-2^-m dirty-word floor). Default 4'h0 = bit-exact legacy framing.
  // See the g_word_reg_pure generate block for the full mechanism.
  input  [3:0]  io_word_pin,
  // SoC Labs FIX-R-proper (2026-06-10): runtime select for the AUTONOMOUS
  // window pin (see the WORD_PIN_AUTO parameter header). 0 = io_word_pin
  // applies (legacy/manual-override framing); 1 = the training-derived
  // auto pin applies. Tie 0 for bit-exact pre-FIX-R-proper behaviour.
  input         io_word_pin_auto_en,
  // SoC Labs PER-LANE word-pin SW override (2026-06-16, perlane-wp). A per-lane
  // 4-bit window pin + a 1-bit enable. When io_word_pin_ovr_en=1 the window load
  // decode uses io_word_pin_ovr for THIS lane, OVERRIDING both the autonomous
  // training-derived pin AND io_word_pin (highest priority). When 0 the select
  // is bit-IDENTICAL to before (auto-pin / io_word_pin per io_word_pin_auto_en).
  // The override is the per-lane sweep knob for the data-corruption bug: each RX
  // lane's word window can be slid independently to find the value that makes
  // its post-deskew slice match. Tie {ovr=0,en=0} for bit-exact legacy framing.
  input  [3:0]  io_word_pin_ovr,
  input         io_word_pin_ovr_en,
  output        io_link_clk,
  output [15:0] io_link_data,
  input         io_pad_clk,
  // SoC Labs PHASE-B SHARED CAPTURE-CLOCK (2026-07-14): parent-supplied,
  // already-muxed AND already-buffered capture clocks. Used ONLY when
  // USE_EXT_CAP_CLK=1; tie 1'b0 (and they stay unused) otherwise.
  //   io_cnt_clk_ext — parent's buffered pad_clk_scan_mux output    (-> w_cnt_clk)
  //   io_cap_clk_ext — parent's buffered pad_clk_inv_scan_mux_1 out (-> w_pad_clk)
  input         io_cnt_clk_ext,
  input         io_cap_clk_ext,
  input         io_pad
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
`endif // RANDOMIZE_REG_INIT
  wire  pad_clk_inv_winv_io_a; // @[Stdcell.scala 276:22]
  wire  pad_clk_inv_winv_io_z; // @[Stdcell.scala 276:22]
  wire  pad_clk_scan_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  pad_clk_scan_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  pad_clk_scan_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  pad_clk_scan_mux_io_o_z; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_io_o_z; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_1_io_i_sel; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_1_io_i_a; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_1_io_i_b; // @[Stdcell.scala 149:21]
  wire  pad_clk_inv_scan_mux_1_io_o_z; // @[Stdcell.scala 149:21]
  wire  por_reset_scan_wrs_io_clk; // @[Stdcell.scala 324:21]
  wire  por_reset_scan_wrs_io_scan_ctrl; // @[Stdcell.scala 324:21]
  wire  por_reset_scan_wrs_io_reset_in; // @[Stdcell.scala 324:21]
  wire  por_reset_scan_wrs_io_reset_out; // @[Stdcell.scala 324:21]
  wire  io_link_clk_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  io_link_clk_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  io_link_clk_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  io_link_clk_mux_io_o_z; // @[Stdcell.scala 149:21]
  // verilator lint_off UNOPTFLAT
  // Rationale (FIX-N, 2026-06-10): `count` legitimately drives the divided
  // word clock (~count[3] -> w_lnk_clk) whose BOTH edges are now used (rising
  // by external consumers, falling by the FIX-N sampling register below).
  // The lint tool flags the divided-clock fanout as potentially circular; it
  // is a standard ripple-divided clock, not a combinational loop.
  reg [3:0] count; // @[GPIO.scala 121:97]
  // verilator lint_on UNOPTFLAT
  reg [15:0] link_data_pad_clk; // @[GPIO.scala 130:109]
  // SoC Labs alignment patch: rotate the bit-position selector by io_phase_offset.
  // adj_count == 4'hX selects when to write bit X. With phase_offset = (master_tx_count - slave_rx_count) mod 16,
  // the deserialiser realigns to the peer's word boundary without needing a count reset.
  wire [3:0] adj_count = count + io_phase_offset;
  wire  link_data_pad_clk_in_1 = adj_count == 4'h1 ? io_pad : link_data_pad_clk[1]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_0 = adj_count == 4'h0 ? io_pad : link_data_pad_clk[0]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_3 = adj_count == 4'h3 ? io_pad : link_data_pad_clk[3]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_2 = adj_count == 4'h2 ? io_pad : link_data_pad_clk[2]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_5 = adj_count == 4'h5 ? io_pad : link_data_pad_clk[5]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_4 = adj_count == 4'h4 ? io_pad : link_data_pad_clk[4]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_7 = adj_count == 4'h7 ? io_pad : link_data_pad_clk[7]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_6 = adj_count == 4'h6 ? io_pad : link_data_pad_clk[6]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire [7:0] link_data_pad_clk_lo = {link_data_pad_clk_in_7,link_data_pad_clk_in_6,link_data_pad_clk_in_5,
    link_data_pad_clk_in_4,link_data_pad_clk_in_3,link_data_pad_clk_in_2,link_data_pad_clk_in_1,link_data_pad_clk_in_0}; // @[GPIO.scala 130:131]
  wire  link_data_pad_clk_in_9 = adj_count == 4'h9 ? io_pad : link_data_pad_clk[9]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_8 = adj_count == 4'h8 ? io_pad : link_data_pad_clk[8]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_11 = adj_count == 4'hb ? io_pad : link_data_pad_clk[11]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_10 = adj_count == 4'ha ? io_pad : link_data_pad_clk[10]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_13 = adj_count == 4'hd ? io_pad : link_data_pad_clk[13]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_12 = adj_count == 4'hc ? io_pad : link_data_pad_clk[12]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_15 = adj_count == 4'hf ? io_pad : link_data_pad_clk[15]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire  link_data_pad_clk_in_14 = adj_count == 4'he ? io_pad : link_data_pad_clk[14]; // @[GPIO.scala 132:29 GPIO.scala 133:32 GPIO.scala 135:32]
  wire [7:0] link_data_pad_clk_hi = {link_data_pad_clk_in_15,link_data_pad_clk_in_14,link_data_pad_clk_in_13,
    link_data_pad_clk_in_12,link_data_pad_clk_in_11,link_data_pad_clk_in_10,link_data_pad_clk_in_9,
    link_data_pad_clk_in_8}; // @[GPIO.scala 130:131]
  reg [15:0] link_data_reg; // @[GPIO.scala 140:100]
  // ==========================================================================
  // SoC Labs FIX-N (2026-06-10): RACE-FREE bit->word handoff.
  //
  // ROOT CAUSE (HW BER eyemaps 2026-06-10, reproduced in sim by
  // cocotb/phy_bist/tb_rx_word_capture_skew.sv): the old design sampled the
  // 16-bit assembly register link_data_pad_clk (bit-clock domain) directly
  // with link_data_reg on the POSEDGE of the derived word clock w_lnk_clk
  // (~count[3], BUFG'd on FPGA). That posedge and the LAST assembly write of
  // each sweep (the bit-position written at the count==15 edge) derive from
  // the SAME pad-clock edge, so the capture was a pure ns-scale race:
  //     latch arrival : count clk->Q + route-to-BUFG + BUFG insertion
  //     data  arrival : assembly clk->Q + handoff D-route
  // The handoff is UNTIMED on the FPGA (no create_generated_clock on the
  // BUFG'd ~count[3]; Vivado routed timing summary reports "no_clock" for the
  // whole recovered word-clock domain), so the outcome was a per-build, per-
  // lane ROUTING LOTTERY. When the route loses, the latched word is the
  // coherent window ending ONE BIT-CELL EARLY — a word-window shift that NO
  // (io_phase_offset, io_bit_slip) rotation can undo => through the self-sync
  // PRBS-15 checker the best phase dirties exactly 1/2 of all words (and the
  // other phases the 1-2^-k staircase, k=2..6) => the link_up wall. A
  // period-1 (constant-word) training stream is immune, which is why
  // lane_locked=0xff always held while PRBS never did.
  //
  // FIX (textbook, by construction — robust to ANY static skew between the
  // two clock nets):
  //   1. Assemble AND complete the word entirely in the bit-clock domain:
  //      link_data_word (below) registers the completed 16-bit word at the
  //      count 15->0 wrap — the same instant the old latch fired, so the
  //      window/framing (io_phase_offset semantics) are bit-identical. It
  //      changes ONCE per 16 bit-clocks, coincident with the w_lnk_clk
  //      RISING edge.
  //   2. The word-clock domain samples that STABLE register on the FALLING
  //      edge of w_lnk_clk — 8 bit-cells (half a word period, 1.28 us at
  //      6.25 MHz) away from link_data_word's update on BOTH sides. Any
  //      static skew up to +/- half a word period is absorbed by
  //      construction; no timing-constraint lottery remains.
  //   3. w_lnk_clk stays the FREE-RUNNING ~count[3] (glitch fix e853093
  //      preserved); io_phase_offset stays the data-framing knob and
  //      io_bit_slip the word rotation.
  // Zero-skew behaviour is bit-identical for every posedge-w_lnk_clk
  // consumer (deskew write, checkers): link_data_reg now loads window
  // [n-16,n) at the negedge AFTER wrap n, so at wrap n+16 a posedge consumer
  // samples exactly what it sampled before. (Combinational observers see
  // io_link_data transition at the negedge instead of just-after-posedge.)
  // Belt-and-braces FPGA constraints: fpga/targets/*/
  // pynq_z2_tidelink_word_handoff.xdc (generated clocks on the recovered
  // word-clock domain + max_delay on this handoff).
  // ==========================================================================
  reg [15:0] link_data_word; // FIX-N: bit-domain completed-word register
  // --------------------------------------------------------------------------
  // FIX-N skew-model hook (SIM-ONLY, default 0 = inert): models the FPGA
  // ROUTING delay on the bit->word handoff D-path (link_data_word ->
  // link_data_reg). +handoff_route_ps=R injects that route as a transport
  // delay so tb_rx_word_capture_skew can sweep the race window. Pre-FIX-N
  // this hook sat on the link_data_pad_clk -> link_data_reg bus and
  // reproduced the HW 1-2^-k eyemap signature for R >= (latch insertion);
  // post-FIX-N the half-word margin makes every swept R pass.
  // --------------------------------------------------------------------------
  // (VERILATOR excluded too: event-scheduled #delays need --timing, and the
  //  hook is a VCS-only experiment knob — verilator flows get the plain wire.)
`ifdef SYNTHESIS
  wire [15:0] link_data_handoff = link_data_word;
`elsif VERILATOR
  wire [15:0] link_data_handoff = link_data_word;
`else
  integer     sk_handoff_route_ps;
  reg  [15:0] link_data_handoff_dly;
  initial begin
    if (!$value$plusargs("handoff_route_ps=%d", sk_handoff_route_ps))
      sk_handoff_route_ps = 0;
    link_data_handoff_dly = 16'h0;
  end
  always @(link_data_word)
    link_data_handoff_dly <= #(sk_handoff_route_ps/1000.0) link_data_word;
  wire [15:0] link_data_handoff = (sk_handoff_route_ps == 0)
                                  ? link_data_word : link_data_handoff_dly;
`endif
  WavClockInv pad_clk_inv_winv ( // @[Stdcell.scala 276:22]
    .io_a(pad_clk_inv_winv_io_a),
    .io_z(pad_clk_inv_winv_io_z)
  );
  WavClockMux pad_clk_scan_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(pad_clk_scan_mux_io_i_sel),
    .io_i_a(pad_clk_scan_mux_io_i_a),
    .io_i_b(pad_clk_scan_mux_io_i_b),
    .io_o_z(pad_clk_scan_mux_io_o_z)
  );
  WavClockMux pad_clk_inv_scan_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(pad_clk_inv_scan_mux_io_i_sel),
    .io_i_a(pad_clk_inv_scan_mux_io_i_a),
    .io_i_b(pad_clk_inv_scan_mux_io_i_b),
    .io_o_z(pad_clk_inv_scan_mux_io_o_z)
  );
  WavClockMux pad_clk_inv_scan_mux_1 ( // @[Stdcell.scala 149:21]
    .io_i_sel(pad_clk_inv_scan_mux_1_io_i_sel),
    .io_i_a(pad_clk_inv_scan_mux_1_io_i_a),
    .io_i_b(pad_clk_inv_scan_mux_1_io_i_b),
    .io_o_z(pad_clk_inv_scan_mux_1_io_o_z)
  );
  WavResetSync por_reset_scan_wrs ( // @[Stdcell.scala 324:21]
    .io_clk(por_reset_scan_wrs_io_clk),
    .io_scan_ctrl(por_reset_scan_wrs_io_scan_ctrl),
    .io_reset_in(por_reset_scan_wrs_io_reset_in),
    .io_reset_out(por_reset_scan_wrs_io_reset_out)
  );
  WavClockMux io_link_clk_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(io_link_clk_mux_io_i_sel),
    .io_i_a(io_link_clk_mux_io_i_a),
    .io_i_b(io_link_clk_mux_io_i_b),
    .io_o_z(io_link_clk_mux_io_o_z)
  );
  assign io_scan_out = 1'h0; // @[GPIO.scala 110:21]
  // SoC Labs §9 clock fix (2026-05-19): clean per-lane recovered clocks.
  // Driven from the generate block further down (one of two branches based
  // on the USE_CLKBUF parameter). Declared explicitly here, before first
  // use, to avoid implicit-wire vs explicit-wire conflicts.
  wire w_cnt_clk;  // clocks `count` + por_reset_scan_wrs
  wire w_pad_clk;  // clocks the first-stage link_data_pad_clk capture
  wire w_lnk_clk;  // /16 word clock; drives link_data_reg + io_link_clk
  assign io_link_clk = w_lnk_clk; // §9 clock fix — BUFG'd when USE_CLKBUF=1
  // SoC Labs bit-slip patch: apply per-lane right-rotation by io_bit_slip on
  // the 16-bit deserialised word. Right-rotation matches the natural reading
  // order — when the FPGA captures data N bits "late", the recovered bits
  // appear shifted right; rotating right by N realigns to the original
  // 16-bit window. Default io_bit_slip=0 → bit-exact passthrough.
  // 5-bit index required to address bits [31:0] of _link_data_rep. io_bit_slip
  // is 3 bits, so we zero-extend to 5 (not 4) to silence Verilator WIDTH lint.
  wire [31:0] _link_data_rep = {link_data_reg, link_data_reg};
  assign io_link_data = _link_data_rep[{2'b00, io_bit_slip} +: 16];
  assign pad_clk_inv_winv_io_a = io_pad_clk; // @[Stdcell.scala 277:15]
  assign pad_clk_scan_mux_io_i_sel = io_scan_mode; // @[Stdcell.scala 150:21]
  assign pad_clk_scan_mux_io_i_a = io_pad_clk; // @[Stdcell.scala 151:21]
  assign pad_clk_scan_mux_io_i_b = io_scan_clk; // @[Stdcell.scala 152:21]
  assign pad_clk_inv_scan_mux_io_i_sel = io_pol; // @[Stdcell.scala 150:21]
  assign pad_clk_inv_scan_mux_io_i_a = io_pad_clk; // @[Stdcell.scala 151:21]
  assign pad_clk_inv_scan_mux_io_i_b = pad_clk_inv_winv_io_z; // @[Stdcell.scala 152:21]
  assign pad_clk_inv_scan_mux_1_io_i_sel = io_scan_mode; // @[Stdcell.scala 150:21]
  assign pad_clk_inv_scan_mux_1_io_i_a = pad_clk_inv_scan_mux_io_o_z; // @[Stdcell.scala 151:21]
  assign pad_clk_inv_scan_mux_1_io_i_b = io_scan_clk; // @[Stdcell.scala 152:21]
  assign por_reset_scan_wrs_io_clk = w_cnt_clk; // §9 clock fix — BUFG'd when USE_CLKBUF=1
  assign por_reset_scan_wrs_io_scan_ctrl = io_scan_asyncrst_ctrl; // @[Stdcell.scala 327:23]
  assign por_reset_scan_wrs_io_reset_in = io_por_reset; // @[Stdcell.scala 326:23]
  assign io_link_clk_mux_io_i_sel = io_scan_mode; // @[Stdcell.scala 150:21]
  // SoC Labs glitch fix (2026-06-09): derive io_link_clk from the FREE-RUNNING
  // count[3], NOT adj_count[3]. This makes the recovered word clock entirely
  // INDEPENDENT of io_phase_offset, so a LIVE phase change (the calibrator
  // sweeping candidates) can never produce a runt/glitch clock edge on the
  // word clock that runs the whole rx domain (deskew read, all 8 PRBS
  // checkers, lane_checker, calibrator FSM, CDC tails). Restores the
  // symmetric Wav architecture — WavD2DGpioTx.io_link_clk is ~count[3] too.
  //
  // Word coherence (the v2 2026-05-05 intent: a captured 16-bit word holds
  // all bits from one serializer round) is now achieved on the DATA side, NOT
  // the clock. The bit-position mux (link_data_pad_clk_in_*) still keys on
  // adj_count == X (= count + phase). With a constant phase P, bit X is
  // written when count == (X - P) mod 16, i.e. each of the 16 bits is written
  // EXACTLY ONCE during one count: 0->15 sweep. The latch fires at the count
  // 15->0 wrap (~count[3] rising edge), capturing a coherent word — every bit
  // written once since the previous wrap. The framing is just a fixed
  // rotation (by P) of the old adj_count framing.
  //
  // On a LIVE phase change P->P', the single count-cycle straddling the change
  // writes some bits under P and some under P' => that ONE latched word is a
  // transient mix (a one-word data glitch the calibrator's PRBS/checker clr
  // already tolerates); the CLOCK never moves. Every subsequent word is clean
  // under P'.
  assign io_link_clk_mux_io_i_a = ~count[3]; // @[GPIO.scala 124:23]
  assign io_link_clk_mux_io_i_b = io_scan_clk; // @[Stdcell.scala 152:21]
  // ==========================================================================
  // SoC Labs §9 clock fix (2026-05-19): clean per-lane recovered clocks.
  // FPGA (USE_CLKBUF=1): BUFG the two derived clocks the always-blocks below
  //   need, bypassing the io_pol / scan_mode muxes (both static 0 in FPGA
  //   bring-up — see header). Kills the 7× Place 30-568 LUT-driving-clock
  //   warnings the routed netlist showed on pynq-z2-pair-all.
  // sim/ASIC/UVM (USE_CLKBUF=0): the original WavClockMux outputs — bit-exact,
  //   no Xilinx primitive elaborated (generate-if prunes the BUFG branch).
  // ==========================================================================
  // w_cnt_clk / w_pad_clk / w_lnk_clk are declared explicitly at the top of
  // the assigns block above (before first use). The generate block below
  // drives each one from exactly one of two branches per axis. Target A
  // (2026-05-28) split the BUFG decision into two independent axes —
  // USE_CAP_CLKBUF (io_pad_clk capture-side) and USE_LNK_CLKBUF (derived
  // word-clock). Backwards-compat: when the deprecated combined
  // USE_CLKBUF is set, both new params default to its value, so:
  //   USE_CLKBUF=0 → CAP=0,LNK=0 → both passthrough (original sim/ASIC).
  //   USE_CLKBUF=1 → CAP=1,LNK=1 → both BUFG-backed (legacy FPGA).
  // The new Target A combo CAP=0,LNK=1 lets the BD do a single IBUFG→BUFG
  // on the pad_clk_rx pin (cuts ~40 pF off the pad load from 8×BUFG-input
  // fan-in) while still keeping the fabric-derived word-clock on a
  // dedicated BUFG net per lane.
  generate
    // ----- capture-clock axis: USE_EXT_CAP_CLK (HIGHEST PRIORITY) -------
    // SoC Labs PHASE-B (2026-07-14): the parent already computed this lane's
    // capture mux chain (lane-identical by construction) and already buffered
    // both outputs. Take them as-is. This preserves the io_pol inversion that
    // g_cap_bufg below wrongly discards, because the parent replicates the
    // FULL chain — inverter, io_pol mux and scan mux — before the buffer.
    if (USE_EXT_CAP_CLK) begin : g_cap_ext
      // Parent supplies the already-muxed, already-BUFG'd shared clocks.
      assign w_cnt_clk = io_cnt_clk_ext;
      assign w_pad_clk = io_cap_clk_ext;
    end
    // ----- capture-clock axis: USE_CAP_CLKBUF ---------------------------
    // =====================================================================
    // !! WARNING — DO NOT ENABLE USE_CAP_CLKBUF. THIS BRANCH IS UNSAFE. !!
    //
    // It BYPASSES the io_pol mux: it drives w_pad_clk (the capture clock for
    // link_data_pad_clk and the FIX-R-proper window matcher) directly from the
    // BUFG'd io_pad_clk, on the stated assumption "io_pol=0, scan=0 => same
    // edge".
    //
    // THAT ASSUMPTION IS FALSE. io_pol = out_prepend_swi_polarity, which
    // RESETS TO 1'h1 (WavD2DGpio_v2.v:1885, and the RANDOMIZE init at :1971).
    // With io_pol=1 the pad_clk_inv_scan_mux selects the INVERTED pad clock,
    // so the capture flops are MEANT to sample on the inverted edge — a
    // deliberate half-bit offset from the `count` assembly clock. Enabling
    // this branch would silently REMOVE that inversion on all 8 lanes,
    // collapsing the capture point onto the counter edge and killing the link.
    //
    // (The USE_CLKBUF header comment further up, which claims io_pol "reset 0,
    // never written", is likewise wrong. The RTL, not the comment, is
    // authoritative: reset value is 1.)
    //
    // Kept only for historical/backward compatibility with callers that still
    // pass USE_CAP_CLKBUF. WavD2DGpio_v2 hardcodes USE_CAP_CLKBUF=1'b0, so it
    // is dead in every current build. For a buffered capture clock use
    // USE_EXT_CAP_CLK (above), which keeps the io_pol mux.
    // =====================================================================
    else if (USE_CAP_CLKBUF) begin : g_cap_bufg
`ifndef TIDELINK_RXCLK_NO_PRIMITIVE
      BUFG u_cap_bufg (.I(io_pad_clk), .O(w_cnt_clk));
      assign w_pad_clk = w_cnt_clk;        // UNSAFE: io_pol mux bypassed (see WARNING)
`else
      // Belt-and-braces opt-out (mirrors tidelink_idelay_rx/tidelink_rxclk_buf):
      // a non-Vivado flow that forces USE_CAP_CLKBUF=1 without a unisim library
      // can define TIDELINK_RXCLK_NO_PRIMITIVE to fall back to passthrough.
      assign w_cnt_clk = pad_clk_scan_mux_io_o_z;
      assign w_pad_clk = pad_clk_inv_scan_mux_1_io_o_z;
`endif
    end else begin : g_cap_passthrough
      assign w_cnt_clk = pad_clk_scan_mux_io_o_z;
      assign w_pad_clk = pad_clk_inv_scan_mux_1_io_o_z;
    end
    // ----- derived word-clock axis: USE_LNK_CLKBUF ----------------------
    if (USE_LNK_CLKBUF) begin : g_lnk_bufg
`ifndef TIDELINK_RXCLK_NO_PRIMITIVE
      // SoC Labs glitch fix (2026-06-09): BUFG the FREE-RUNNING ~count[3],
      // NOT ~adj_count[3]. The derived word clock must be phase-independent
      // so a live io_phase_offset change can never glitch the BUFG'd net that
      // clocks every capture flop in the lane. Matches the sim mux input a
      // (io_link_clk_mux_io_i_a) above; word coherence is handled on the data
      // side via the adj_count bit-position mux. See that comment for proof.
      BUFG u_lnk_bufg (.I(~count[3]), .O(w_lnk_clk));
`else
      assign w_lnk_clk = io_link_clk_mux_io_o_z;
`endif
    end else begin : g_lnk_passthrough
      assign w_lnk_clk = io_link_clk_mux_io_o_z;
    end
  endgenerate
  // ==========================================================================
  // SoC Labs §9 T3a self-aligning RX (2026-05-19): comma-hunt realignment.
  // See the parameter-block header for the full rationale. Implementation:
  //   - capture the 8 most-recent io_pad bits in `realign_shifter` (LSB =
  //     newest bit so byte-bit-0 maps to bit[0] of the rotated reference);
  //   - after a settling window from io_por_reset, the FSM goes S_HUNT;
  //   - on each cycle, compare `realign_shifter` against the 8 cyclic
  //     rotations of TRAINING_BYTE and pick the first match (lowest rot
  //     index — priority ladder), then apply count := count - rot (mod 16)
  //     on the NEXT cycle, then go S_LOCKED;
  //   - on time-out (MAX_HUNT cycles) without a match, fall through to
  //     S_LOCKED and let count free-run from where it was (legacy
  //     behaviour). This keeps the lane operable if the peer isn't in
  //     training mode yet — phase_offset/bit_slip/IDELAYE2 will still try.
  // The whole shooting-match is gated by the constant USE_T3A parameter via
  // a generate block so the USE_T3A=0 path is bit-exact (no flops added).
  // ==========================================================================
  localparam S_SETTLE = 2'd0;
  localparam S_HUNT   = 2'd1;
  localparam S_LOCKED = 2'd2;
  // Settle window: let the recovered clock + IBUF chain stabilise before we
  // start looking for the comma. 64 pad_clks is plenty for the deserialiser
  // pipeline + the BUFG path to fully propagate the first bytes of the
  // training stream into the shifter.
  localparam [6:0] SETTLE_CYCLES = 7'd64;
  // Hunt time-out. The peer typically enters training_mode well before
  // role-lock, so the first valid training byte should appear inside the
  // first dozen pad_clks of S_HUNT. 1024 is a comfortable margin that
  // still bounds the FSM if the peer is silent.
  localparam [9:0] MAX_HUNT      = 10'd1023;
  // tdif-06 (2026-05-25): S_LOCKED dwell before continuous re-arm.
  // MUST be >= 16 (one word time) so the realign_shifter has fully
  // refreshed before re-arm sees it. 63 = 4 word times, ~1.6us @ 25 MHz.
  // Used only when T3A_CONTINUOUS=1; ignored otherwise.
  localparam [5:0] DWELL_MAX     = 6'd63;

  // realign_shifter[0] is the most-recently-sampled io_pad bit.
  // After 8 cycles of sampling, realign_shifter[7:0] holds the last 8 bits
  // in receive-time order (newest=LSB). We compare against rotations of
  // TRAINING_BYTE under the convention: rot=k means the byte was sent
  // starting `k` bit-positions ahead of where we currently align — i.e.
  // the lane is "k" bits ahead, so we slip count BACK by k to realign.
  generate
    if (USE_T3A) begin : g_t3a_realign
      reg [7:0]   realign_shifter;
      reg [1:0]   align_state;
      reg [6:0]   settle_cnt;
      reg [9:0]   hunt_cnt;
      reg [2:0]   slip_amt;
      reg         do_slip;
      // tdif-06 (2026-05-25): bounded re-arm dwell. When T3A_CONTINUOUS=1
      // the FSM stays in S_LOCKED for DWELL_MAX cycles BEFORE re-entering
      // S_HUNT. DWELL_MAX MUST be >= one word time (16 cycles) so the
      // realign_shifter has fully refreshed before the next hunt — this
      // prevents the tdif-04 drift bug where re-arm 1 cycle later saw the
      // same training-byte pattern and slipped repeatedly. 64 cycles is a
      // comfortable margin (4 word times) and keeps re-arm cheap.
      reg [5:0]   dwell_cnt;

      // Rotated reference values. Same convention as WavD2DGpioTx's
      // serialiser: each `pad_clk` puts ONE bit on the wire; over 8 cycles
      // a byte is delivered. We don't care which TX bit-order is used —
      // we only need that EXACTLY ONE of the 8 cyclic rotations of the
      // byte yields the shifter value the RX sees (which is precisely the
      // period-8 property the TRAINING_BYTE was picked for).
      // rot=k → cyclic right-rotation by k of TRAINING_BYTE.
      function [7:0] rotr8(input [7:0] b, input [2:0] k);
        rotr8 = (b >> k) | (b << (8 - k));
      endfunction

      // Combinational hunt: priority-encoded first-match across rot 0..7.
      // Defined here (outside the always block) so the `for-rot` loop is
      // pure combinational logic — no implicit latches.
      reg        match_any;
      reg [2:0]  match_rot;
      integer    rot_i;
      always @* begin
        match_any = 1'b0;
        match_rot = 3'd0;
        // Iterate highest-to-lowest so the LAST non-blocking write wins
        // ⇒ when multiple rotations match (impossible for the period-8
        // training bytes, but defensive), rot 0 wins.
        for (rot_i = 7; rot_i >= 0; rot_i = rot_i - 1) begin
          if (realign_shifter == rotr8(TRAINING_BYTE, rot_i[2:0])) begin
            match_any = 1'b1;
            match_rot = rot_i[2:0];
          end
        end
      end

      // Shifter + FSM. Async-reset on io_por_reset so re-init re-arms T3a.
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          realign_shifter <= 8'h00;
          align_state     <= S_SETTLE;
          settle_cnt      <= 7'd0;
          hunt_cnt        <= 10'd0;
          slip_amt        <= 3'd0;
          do_slip         <= 1'b0;
          dwell_cnt       <= 6'd0;
        end else begin
          // Newest bit at LSB; older bits march toward MSB. Equivalent to
          //   realign_shifter = {realign_shifter[6:0], io_pad}
          // with the convention "LSB = most-recent".
          realign_shifter <= {realign_shifter[6:0], io_pad};
          do_slip         <= 1'b0;  // default
          case (align_state)
            S_SETTLE: begin
              if (settle_cnt == SETTLE_CYCLES - 1) begin
                align_state <= S_HUNT;
              end else begin
                settle_cnt  <= settle_cnt + 7'd1;
              end
            end
            S_HUNT: begin
              if (match_any) begin
                slip_amt    <= match_rot;
                do_slip     <= 1'b1;
                align_state <= S_LOCKED;
              end else if (hunt_cnt == MAX_HUNT) begin
                // Time-out: leave count alone, fall through to LOCKED.
                slip_amt    <= 3'd0;
                do_slip     <= 1'b0;
                align_state <= S_LOCKED;
              end else begin
                hunt_cnt <= hunt_cnt + 10'd1;
              end
            end
            S_LOCKED: begin
              // SoC Labs tdif-06 (2026-05-25): BOUNDED continuous re-arm.
              // tdif-04 (T3A_CONTINUOUS=1, 1-cycle dwell) failed because re-
              // arm 1 cycle later saw the same training-byte pattern still
              // in the shifter and slipped repeatedly, drifting count.
              // tdif-06 dwells DWELL_MAX cycles (>= one word time) before
              // re-arming, so the shifter has refreshed and the next match
              // (if any) reflects the CURRENT count phase — slip will be 0
              // when alignment is still correct (steady training) and
              // non-zero only when a real re-train is in progress.
              //
              // During FC data with no training-byte match, S_HUNT's
              // existing MAX_HUNT timeout path falls back to S_LOCKED with
              // do_slip=0, preserving count. So FC traffic is not disturbed.
              if (T3A_CONTINUOUS) begin
                if (dwell_cnt == DWELL_MAX) begin
                  dwell_cnt   <= 6'd0;
                  hunt_cnt    <= 10'd0;
                  align_state <= S_HUNT;
                end else begin
                  dwell_cnt   <= dwell_cnt + 6'd1;
                end
              end else begin
                align_state <= S_LOCKED;
              end
            end
            default: align_state <= S_LOCKED;
          endcase
        end
      end

      // count: free-runs normally; on the single `do_slip` pulse, the next
      // value is (count + 1 - slip_amt) so the realign takes effect on the
      // very next cycle. Subtract-by-rotation is correct because the
      // shifter saw byte-bit-0 at position `rot` cycles into the past —
      // shifting count back by `rot` rewinds it to "0 at byte-bit-0".
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          count <= 4'hf;
        end else if (do_slip) begin
          // count + 1 - slip_amt, mod 16. {1'b0,slip_amt} → 4-bit operand.
          count <= count + 4'h1 - {1'b0, slip_amt};
        end else begin
          count <= count + 4'h1;
        end
      end
    end else begin : g_t3a_passthru
      // Bit-exact legacy: count free-runs from 4'hf, +1 every cycle. No
      // shifter, no FSM, no hunt counter — the generate-if prunes them.
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          count <= 4'hf;
        end else begin
          count <= count + 4'h1;
        end
      end
    end
  endgenerate
  always @(posedge w_pad_clk or posedge io_por_reset) begin
    if (io_por_reset) begin
      link_data_pad_clk <= 16'h0;
    end else begin
      link_data_pad_clk <= {link_data_pad_clk_hi,link_data_pad_clk_lo};
    end
  end
  // FIX-N step 1: register the COMPLETED word in the BIT-CLOCK domain.
  //
  // SoC Labs FIX-Q-RX (2026-06-10): REGISTERED in-flight bit (the FIX-P
  // follow-up hardening). The original FIX-N loaded {hi,lo} at the count==15
  // capture edge — the assembly's NEXT-state, whose slot (15+phase) taps
  // io_pad COMBINATIONALLY (IBUF/IDELAY + mux LUT). That in-flight bit's
  // setup is therefore the raw pad eye at the SAME edge through a DIFFERENT
  // route than the assembly flop's own capture: with a capture edge near the
  // data transition the two routes can resolve DIFFERENTLY (the "in-flight
  // pairing conflict" face of the FIX-P wall reproducer). RX_WORD_REG_PURE=1
  // (default) loads link_data_word ONE bit-cell LATER (count==0 falling
  // edge) from the assembly FLOP OUTPUTS only: at that edge the flops hold
  // exactly the completed window [count 0..15] (the slot being rewritten on
  // that very edge reads its OLD Q = the completed window's bit, a plain
  // same-clock-net flop->flop transfer, STA-timed). The VALUE SEQUENCE is
  // bit-identical to the FIX-N load — link_data_word holds the same word,
  // updated half a cell after the w_lnk_clk rising edge instead of half a
  // cell before — and the FIX-N step-2 negedge sample keeps 7.5/8.5
  // bit-cells of margin (was 8/8). No io_pad combinational tap remains in
  // the word register: the LAST capture-eye-class path inside the RX is the
  // assembly flop itself. RX_WORD_REG_PURE=0 = the FIX-N in-flight load
  // (A/B).
  // ==========================================================================
  // SoC Labs FIX-R seed (2026-06-10): the WORD-WINDOW PIN — the THIRD
  // alignment dimension (slip,phase are pure ROTATIONS; neither can move the
  // 16-capture WINDOW the completed word is cut from). The window is pinned
  // by THIS load decode against the free-running count, i.e. by the count-
  // framing-vs-stream relationship established when the (gated) forwarded
  // clock last restarted — a per-session lottery mod 16 on HW (count freezes
  // while the peer's gate is down and resumes at an arbitrary offset into
  // the peer's word). A non-zero pin puts ONE out-of-place bit per word in
  // checker-stream order at EVERY (slip,phase) => the un-sweepable
  // 1-2^-m dirty-word floors (m = pin offset bits), lane-identical (all
  // lanes' counts share one clock/reset), training-immune (period-1),
  // forwarded-clock-edge-insensitive (an 80 ns polarity flip moves the pin
  // by +/-1, never to a chosen value) — the die_b HW signature. Reproducer:
  // tb_oddr_capture_edge TX_IOB=1 oddr_invert=1 (clean captures, regular
  // clocks, NO clean phase at word_pin=0; clean at word_pin=15).
  // io_word_pin slides the load decode (window pin) by 0..15 capture cells.
  // Default 4'h0 = bit-exact legacy framing. Applies to the
  // RX_WORD_REG_PURE=1 branch (the deployed config); the legacy in-flight
  // A/B branch keeps its hardwired count==15 load.
  // ==========================================================================
  // ==========================================================================
  // SoC Labs FIX-R-proper (2026-06-10): training-derived AUTONOMOUS window
  // pin (see the WORD_PIN_AUTO parameter header for the full design notes).
  //
  // Timing derivation (why "cand = count at the match edge" is exact): the
  // shifter registers io_pad on the SAME posedge-w_pad_clk the assembly
  // flops use, oldest bit at MSB. When the REGISTERED shifter equals the
  // as-transmitted pattern, the pattern's LAST bit (w[15]) was captured at
  // the PREVIOUS edge — i.e. at the CURRENT edge the assembly flops hold
  // exactly the completed window w[0..15] (the slot being rewritten on this
  // very edge reads old Q), which is precisely the instant the
  // g_word_reg_pure load must fire. The load decode compares the same
  // `count` net at the same edge, so the required pin IS the `count` value
  // visible now — no polarity (io_pol) or phase/slip term enters. Aligned
  // legacy framing (w[15] at count==15) yields cand 0: bit-exact default.
  //
  // Confirm rule: a commit needs WPA_CONFIRM consecutive re-matches at
  // EXACTLY +16-edge spacing with the SAME count (gap counter saturates at
  // 15; a missed expected match or a different-count match restarts the
  // run). Training (constant period-16 word, unique under rotation — the
  // 0x12EB/0xED14 family) re-matches every word; PRBS/idle data cannot
  // sustain the periodicity (~2^-64 joint false rate), so the matcher is
  // self-gating with no training_mode plumbing.
  // ==========================================================================
  wire [3:0] word_pin_eff;
  generate
    if (WORD_PIN_AUTO) begin : g_word_pin_auto
      // As-RECEIVED pattern: first-sent bit (TRAINING_WORD16[0], serialised
      // at count==0) is the OLDEST in the shifter = MSB => bit-reverse.
      function [15:0] wpa_bitrev16(input [15:0] w);
        integer bi;
        begin
          for (bi = 0; bi < 16; bi = bi + 1) wpa_bitrev16[15-bi] = w[bi];
        end
      endfunction
      localparam [15:0] WPA_PATTERN_SH = wpa_bitrev16(TRAINING_WORD16);
      // Consecutive periodic re-matches required before commit (total
      // matches = WPA_CONFIRM+1 = 4 training words on the wire).
      localparam [1:0] WPA_CONFIRM = 2'd3;

      reg [15:0] wpa_shift_q;       // raw io_pad history, oldest at MSB
      reg [3:0]  wpa_cand_q;        // candidate pin (count at match edge)
      reg [1:0]  wpa_conf_q;        // consecutive periodic confirms
      reg [3:0]  wpa_gap_q;         // edges since last match (sat. 15)
      reg [3:0]  word_pin_auto_r;   // committed pin (reset 0 = legacy)

      // TRAINING_WORD16==0 (unconfigured lane) must never re-pin: an
      // idle/all-zero stream matches a zero pattern on EVERY edge. The
      // elaboration-constant qualifier folds the matcher inert.
      wire wpa_match = (TRAINING_WORD16 != 16'h0000)
                       && (wpa_shift_q == WPA_PATTERN_SH);

      always @(posedge w_pad_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          wpa_shift_q     <= 16'h0;
          wpa_cand_q      <= 4'h0;
          wpa_conf_q      <= 2'd0;
          wpa_gap_q       <= 4'hf;
          word_pin_auto_r <= 4'h0;
        end else begin
          wpa_shift_q <= {wpa_shift_q[14:0], io_pad};
          if (wpa_match) begin
            if (count == wpa_cand_q && wpa_gap_q == 4'hf) begin
              // Periodic re-match at the same count: confirm / commit.
              if (wpa_conf_q == WPA_CONFIRM) begin
                word_pin_auto_r <= wpa_cand_q;   // re-commit is a no-op
              end else begin
                wpa_conf_q <= wpa_conf_q + 2'd1;
              end
            end else begin
              // New (or aperiodic) candidate: restart the confirm run.
              wpa_cand_q <= count;
              wpa_conf_q <= 2'd0;
            end
            wpa_gap_q <= 4'd0;
          end else begin
            wpa_gap_q <= (wpa_gap_q == 4'hf) ? 4'hf : wpa_gap_q + 4'd1;
            // Expected periodic re-match missed: break the confirm run.
            if (wpa_gap_q == 4'hf) wpa_conf_q <= 2'd0;
          end
        end
      end

      // Runtime select: per-lane SW override (highest priority) vs auto pin vs
      // the io_word_pin input (manual override / legacy). Mid-stream pin moves
      // give one transient word (same class as a live phase change) and then
      // steady framing. With io_word_pin_ovr_en=0 this is BIT-IDENTICAL to the
      // legacy auto/io_word_pin select.
      assign word_pin_eff = io_word_pin_ovr_en ? io_word_pin_ovr
                          : io_word_pin_auto_en ? word_pin_auto_r
                                                : io_word_pin;
    end else begin : g_word_pin_manual
      // Compile chicken bit OFF: bit-exact pre-FIX-R-proper (the matcher
      // contributes no logic; io_word_pin_auto_en is intentionally unused).
      // The per-lane SW override still applies on top (default en=0 = legacy).
      wire wpa_unused_auto_en = io_word_pin_auto_en;
      assign word_pin_eff = io_word_pin_ovr_en ? io_word_pin_ovr : io_word_pin;
    end
  endgenerate
  generate
    if (RX_WORD_REG_PURE) begin : g_word_reg_pure
      always @(posedge w_pad_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          link_data_word <= 16'h0;
        end else if (count == word_pin_eff) begin
          link_data_word <= link_data_pad_clk;
        end
      end
    end else begin : g_word_reg_inflight
      // Legacy FIX-N load: {hi,lo} is the assembly's next-state INCLUDING
      // the bit being written on this very edge (the in-flight bit), at the
      // count 15->0 wrap, coincident with the w_lnk_clk posedge.
      always @(posedge w_pad_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          link_data_word <= 16'h0;
        end else if (count == 4'hf) begin
          link_data_word <= {link_data_pad_clk_hi,link_data_pad_clk_lo};
        end
      end
    end
  endgenerate
  // FIX-N step 2: sample the stable completed word on the FALLING edge of the
  // free-running word clock — 8 bit-cells away from link_data_word's update
  // on both sides, race-free by construction for ANY static skew up to half a
  // word period between the pad-clock net and the (BUFG'd) ~count[3] net.
  // Posedge-w_lnk_clk consumers (deskew write flops, checkers) see the exact
  // value sequence the old posedge latch gave them (one extra half-cycle of
  // settled data, zero behavioural change at every sampling edge).
  always @(negedge w_lnk_clk or posedge io_por_reset) begin
    if (io_por_reset) begin
      link_data_reg <= 16'h0;
    end else begin
      link_data_reg <= link_data_handoff;
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
  count = _RAND_0[3:0];
  _RAND_1 = {1{`RANDOM}};
  link_data_pad_clk = _RAND_1[15:0];
  _RAND_2 = {1{`RANDOM}};
  link_data_reg = _RAND_2[15:0];
`endif // RANDOMIZE_REG_INIT
  if (io_por_reset) begin
    count = 4'hf;
  end
  if (io_por_reset) begin
    link_data_pad_clk = 16'h0;
  end
  if (io_por_reset) begin
    link_data_word = 16'h0;  // FIX-N
  end
  if (io_por_reset) begin
    link_data_reg = 16'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
