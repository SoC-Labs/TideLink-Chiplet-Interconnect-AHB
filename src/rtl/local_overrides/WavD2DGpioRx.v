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
  parameter USE_CLKBUF = 1'b0,
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
  // SoC Labs L11 (2026-05-26): re-arm T3A and reset `count` whenever the
  // training-mode signal is asserted (level-triggered). This solves the
  // post-bringup byte-align loss we see on HW: after the first recal cycle
  // (slot0=0x3 -> 0x0 + swreset), `count` and the T3A FSM both keep their
  // POR-set alignment, but the slave's effective byte boundary on the wire
  // has shifted (per the calibrator's bit_slip/phase_offset sweep result)
  // and/or the slave's framer is wedged on training filler. By re-armming
  // T3A on every fresh training window, the FSM gets a chance to re-find
  // the comma against the CURRENT bit alignment, with the calibrator's
  // current bit_slip/phase_offset taps in effect.
  //   T3A_REARM_ON_TRAIN=0 (default, sim/ASIC bit-exact) -> behaviour
  //     identical to the prior file: T3A is one-shot, only re-arms on POR.
  //   T3A_REARM_ON_TRAIN=1 (FPGA only, paired with USE_T3A=1) -> while
  //     `io_train_rearm` is HIGH, `count` is held at 4'hf and the T3A FSM
  //     is held in S_SETTLE. On the falling edge of io_train_rearm, the
  //     FSM proceeds through S_SETTLE -> S_HUNT -> S_LOCKED in the normal
  //     way, but on the CURRENT training byte stream (i.e. with whatever
  //     phase_offset/bit_slip the calibrator has settled by then).
  //
  // Note: T3A_REARM_ON_TRAIN=1 is a NO-OP for the FC data path: the rearm
  // only triggers while training_mode is asserted. Once SW drops
  // training_mode (slot0=0x0 + swreset), the FSM is in S_LOCKED with the
  // freshly-acquired slip; subsequent FC data is byte-aligned identically
  // to the bit-exact path.
  parameter T3A_REARM_ON_TRAIN = 1'b0
) (
  input         io_scan_mode,
  input         io_scan_asyncrst_ctrl,
  input         io_scan_clk,
  output        io_scan_out,
  input         io_por_reset,
  // SoC Labs L11 (2026-05-26): level-triggered "re-arm T3A" pulse. Tie 0
  // for legacy / sim / ASIC paths (T3A_REARM_ON_TRAIN=0 also gates the
  // entire rearm block so this input is unused — synth optimises out).
  // On FPGA bring-up, drive from effective_training_mode (the OR of
  // calibrator-driven and APB-driven training-mode signals), synced into
  // w_cnt_clk domain at the per-lane RX level. CDC is per-lane in this
  // module to keep the override self-contained.
  input         io_train_rearm,
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
  output        io_link_clk,
  output [15:0] io_link_data,
  input         io_pad_clk,
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
  reg [3:0] count; // @[GPIO.scala 121:97]
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
  // SoC Labs alignment patch (2026-05-05, v2): derive io_link_clk from
  // adj_count[3] instead of count[3]. This shifts the link_data_reg capture
  // moment by io_phase_offset cycles so the captured 16-bit word contains
  // all bits from the SAME serializer round (else half from current window,
  // half from previous, regardless of bit-position rotation).
  assign io_link_clk_mux_io_i_a = ~adj_count[3]; // @[GPIO.scala 124:23]
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
  // drives them from exactly one of the two branches (USE_CLKBUF=1: BUFG-
  // backed; USE_CLKBUF=0: aliased to the original WavClockMux outputs).
  generate
    if (USE_CLKBUF) begin : g_clkbuf
`ifndef TIDELINK_RXCLK_NO_PRIMITIVE
      BUFG u_cap_bufg (.I(io_pad_clk),    .O(w_cnt_clk));
      assign w_pad_clk = w_cnt_clk;        // io_pol=0, scan=0 ⇒ same edge
      BUFG u_lnk_bufg (.I(~adj_count[3]), .O(w_lnk_clk));
`else
      // Belt-and-braces opt-out (mirrors tidelink_idelay_rx/tidelink_rxclk_buf):
      // a non-Vivado flow that forces USE_CLKBUF=1 without a unisim library
      // can define TIDELINK_RXCLK_NO_PRIMITIVE to fall back to passthrough.
      assign w_cnt_clk = pad_clk_scan_mux_io_o_z;
      assign w_pad_clk = pad_clk_inv_scan_mux_1_io_o_z;
      assign w_lnk_clk = io_link_clk_mux_io_o_z;
`endif
    end else begin : g_passthru
      assign w_cnt_clk = pad_clk_scan_mux_io_o_z;
      assign w_pad_clk = pad_clk_inv_scan_mux_1_io_o_z;
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
  // ==========================================================================
  // SoC Labs L11 (2026-05-26): per-lane CDC sync of io_train_rearm into the
  // w_cnt_clk domain. io_train_rearm is sourced upstream from
  // effective_training_mode (apb_clk-ish domain at the chiplet-controller
  // level). The 2-flop synchroniser is gated by the T3A_REARM_ON_TRAIN
  // parameter so it costs ZERO flops when the feature is disabled
  // (sim/ASIC path). Default reset value is 0 so an unused tie-down at the
  // top-level driver is bit-exact passthrough.
  // ==========================================================================
  wire train_rearm_sync;
  generate
    if (T3A_REARM_ON_TRAIN) begin : g_rearm_sync
      reg train_rearm_sync_0;
      reg train_rearm_sync_1;
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          train_rearm_sync_0 <= 1'b0;
          train_rearm_sync_1 <= 1'b0;
        end else begin
          train_rearm_sync_0 <= io_train_rearm;
          train_rearm_sync_1 <= train_rearm_sync_0;
        end
      end
      assign train_rearm_sync = train_rearm_sync_1;
    end else begin : g_rearm_passthru
      // Bit-exact path: rearm always 0. The signal is unused so synth
      // prunes any downstream gating.
      assign train_rearm_sync = 1'b0;
    end
  endgenerate

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
      // SoC Labs L11 (2026-05-26): sync re-arm path. When train_rearm_sync
      // is HIGH, force the FSM back to S_SETTLE and clear all the slip /
      // hunt state. Held high for the duration of training_mode (level
      // signal), so on the falling edge of training_mode the FSM is in
      // S_SETTLE at hunt_cnt=0 — the first MAX_HUNT-window of post-rearm
      // bytes will be observed against TRAINING_BYTE. While
      // training_mode is high those bytes ARE the training pattern, so
      // hunt should succeed and lock before training drops.
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          realign_shifter <= 8'h00;
          align_state     <= S_SETTLE;
          settle_cnt      <= 7'd0;
          hunt_cnt        <= 10'd0;
          slip_amt        <= 3'd0;
          do_slip         <= 1'b0;
          dwell_cnt       <= 6'd0;
        end else if (train_rearm_sync) begin
          // L11 sync rearm: parallel to async-reset behaviour, but the
          // shifter keeps sampling so on the falling edge of
          // train_rearm_sync the shifter already holds the LAST 8 bits
          // of the training pattern — letting the FSM lock within a few
          // cycles of S_HUNT instead of needing SETTLE+8 cycles to fill.
          realign_shifter <= {realign_shifter[6:0], io_pad};
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
      // SoC Labs L11 (2026-05-26): sync rearm — hold count at 4'hf while
      // train_rearm_sync is asserted so the FSM and count are aligned at
      // the rearm release moment and the FSM's slip applies cleanly.
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          count <= 4'hf;
        end else if (train_rearm_sync) begin
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
      // SoC Labs L11 (2026-05-26): keep count async-reset only path in
      // the passthru branch. Without T3A enabled, training rearm has no
      // FSM to drive — the count signal can still be held at 4'hf while
      // rearm is asserted so the count phase becomes deterministic at
      // rearm release, which is harmless to USE_T3A=0 sim/ASIC because
      // T3A_REARM_ON_TRAIN defaults to 0 there. When both are 0, this
      // entire branch reduces to the original free-run.
      always @(posedge w_cnt_clk or posedge io_por_reset) begin
        if (io_por_reset) begin
          count <= 4'hf;
        end else if (train_rearm_sync) begin
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
  always @(posedge io_link_clk or posedge io_por_reset) begin
    if (io_por_reset) begin
      link_data_reg <= 16'h0;
    end else begin
      link_data_reg <= link_data_pad_clk;
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
    link_data_reg = 16'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
