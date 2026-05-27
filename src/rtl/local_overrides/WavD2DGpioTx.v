// =============================================================================
// SoC Labs LOCAL OVERRIDE: WavD2DGpioTx.v
//
// Source: deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v (~150 lines)
// Override reason: per-lane WORD-ALIGNED training-mux transition (tdif-03).
//
// Background
// ----------
// The base WavD2DGpioTx.v (Chisel-generated) serialises a 16-bit `io_link_data`
// bit-by-bit using an internal 4-bit `count` register that wraps mod-16 on
// io_clk. Lines 43-45 of the base contain a 2-input combinatorial mux:
//
//     wire [15:0] _link_data_eff = io_training_mode
//                                  ? {io_training_pattern, io_training_pattern}
//                                  : io_link_data;
//
// When SW drops io_training_mode mid-word (i.e. when `count` is not 4'hf), the
// mux switches in the middle of bit-serialising a 16-bit word — producing a
// hybrid word that is neither a valid training byte nor a valid LL header.
//
// The wrapper-level fix in src/rtl/local_overrides/WavD2DGpio.v (tdif-02) used
// a wrapper-side mirror counter to time the mux flip. On HW (Build #21), that
// improved slave RX but master RX stayed blind — suggesting per-lane `count`
// registers may not all share the same phase as the wrapper-level mirror
// counter (e.g. different reset arrival, slight skew on hsclk distribution).
//
// Fix (tdif-03)
// -------------
// Move the latching INSIDE WavD2DGpioTx so each lane uses ITS OWN `count`
// register. The mux flip is then guaranteed to land at the per-lane word
// boundary regardless of cross-lane phase.
//
//   * io_training_mode is sampled into io_training_mode_q on the cycle that
//     count==4'hf (i.e. the last bit of a 16-bit word is being driven). The
//     newly-latched value takes effect on the next cycle, which is count==0
//     — the first bit of the next word.
//   * The mux uses io_training_mode_q instead of io_training_mode.
//
// Parameter gating
// ----------------
// WORD_ALIGN_MUX = 1 (default) enables the latch.
// WORD_ALIGN_MUX = 0           bypasses (combinatorial pass-through, base
//                              behaviour, used for sim regression A/B).
//
// Bit-exactness
// -------------
// With WORD_ALIGN_MUX=0 the override is byte-identical to the base RTL: the
// mux is wired to io_training_mode directly and io_training_mode_q is left
// dangling (synth will optimise it away). Only the comment header and the
// generate block change.
//
// Coverage
// --------
//   * cocotb/wav_d2d_gpio_tx/test_wav_tx_training_mux  exercises the unit-
//     level mux (extend to assert word boundary in a follow-up).
//   * cocotb/wlink_pair/test_tx_gated_by_training      paired-Wlink sim.
//
// Author: SoC Labs (2026-05-25)
// Linked to: docs/V2_DEFERRALS.md, project_phc_phase1_session_2026_05_24.md
// =============================================================================
module WavD2DGpioTx #(
  // SoC Labs tdif-03: latch io_training_mode at the per-lane word boundary
  // (count==4'hf) so the per-lane combinatorial mux at line ~43 below only
  // switches between training-pattern and live io_link_data on a 16-bit
  // word boundary. Default 1 = enabled (FPGA bring-up target). Set to 0 to
  // get bit-exact base behaviour (sim regression A/B).
  parameter WORD_ALIGN_MUX = 1'b1
) (
  input         io_scan_mode,
  input         io_scan_asyncrst_ctrl,
  input         io_scan_clk,
  output        io_scan_out,
  input         io_clk,
  input         io_reset,
  input         io_clk_en,
  input  [15:0] io_link_data,
  // SoC Labs training-mode patch (2026-05-13, BRINGUP_REPORT §9): when
  // io_training_mode is high, the serialiser sources its 16-bit word from
  // {io_training_pattern, io_training_pattern} (i.e. the 8-bit byte repeated
  // twice). The receive side correlates the recovered byte against this
  // known pattern to calibrate per-lane bit_slip. Default io_training_mode=0
  // → bit-exact passthrough.
  input         io_training_mode,
  input  [7:0]  io_training_pattern,
  output        io_link_clk,
  output        io_pad,
  output        io_pad_clk
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
  reg [31:0] _RAND_2;
`endif // RANDOMIZE_REG_INIT
  wire  hs_reset_scan_wrs_io_clk; // @[Stdcell.scala 324:21]
  wire  hs_reset_scan_wrs_io_scan_ctrl; // @[Stdcell.scala 324:21]
  wire  hs_reset_scan_wrs_io_reset_in; // @[Stdcell.scala 324:21]
  wire  hs_reset_scan_wrs_io_reset_out; // @[Stdcell.scala 324:21]
  wire  hs_clk_gated_wcg_io_clk_in; // @[Stdcell.scala 469:21]
  wire  hs_clk_gated_wcg_io_enable; // @[Stdcell.scala 469:21]
  wire  hs_clk_gated_wcg_io_test_en; // @[Stdcell.scala 469:21]
  wire  hs_clk_gated_wcg_io_clk_out; // @[Stdcell.scala 469:21]
  wire  io_link_clk_mux_io_i_sel; // @[Stdcell.scala 149:21]
  wire  io_link_clk_mux_io_i_a; // @[Stdcell.scala 149:21]
  wire  io_link_clk_mux_io_i_b; // @[Stdcell.scala 149:21]
  wire  io_link_clk_mux_io_o_z; // @[Stdcell.scala 149:21]
  reg [3:0] count; // @[GPIO.scala 55:30]
  reg  clk_en_qual; // @[GPIO.scala 59:34]
  wire [3:0] count_in = count + 4'h1; // @[GPIO.scala 69:30]
  // ---------------------------------------------------------------------------
  // SoC Labs tdif-03 (2026-05-25): WORD-ALIGNED training-mux transition.
  //
  // io_training_mode_q is sampled from io_training_mode on the cycle when
  // count==4'hf (the LAST bit of a 16-bit word). io_training_mode_q is
  // therefore stable across each 16-bit word and only changes value on the
  // boundary count: f -> 0.
  //
  // Reset value: 1'b0 (matches the natural reset state — pattern not applied
  // until the controller drives io_training_mode high after reset deassert).
  //
  // Clock-domain note: io_training_mode arrives on io_clk (same domain as
  // `count`) — no synchroniser needed. The base RTL already used it
  // combinatorially on io_clk; we only delay its effect by up to 15 cycles.
  // ---------------------------------------------------------------------------
  reg  io_training_mode_q;
  always @(posedge io_clk or posedge hs_reset_scan_wrs_io_reset_out) begin
    if (hs_reset_scan_wrs_io_reset_out) begin
      io_training_mode_q <= 1'b0;
    end else if (count == 4'hf) begin
      io_training_mode_q <= io_training_mode;
    end
  end
  // Per-lane mux source select: when WORD_ALIGN_MUX=1, drive the mux from
  // the registered value (word-aligned). When 0, drive directly (base
  // behaviour, byte-identical to original RTL).
  wire io_training_mode_mux = WORD_ALIGN_MUX ? io_training_mode_q
                                             : io_training_mode;
  // SoC Labs §9.11e (2026-05-28): training-pattern ISI fix.
  // ----------------------------------------------------------
  // Original (§9.7-§9.11d) emitted {P, P} during training — same byte
  // repeated, period 8 on the wire. This locks the lane_checker at the
  // correct slip/phase but DOES NOT exercise the high-ISI byte-boundary
  // transitions that real packet data has. Independent 3-agent analysis
  // 2026-05-27 + HW SW-sweep (0/16 phases crossed doorbell despite
  // bilateral LINK_IDLE) confirmed: calibrator picks a (slip, phase) that
  // training passes but real data fails (OVERNIGHT_2026_05_27 Layer-2).
  //
  // §9.11e fix: emit {P, ~P} instead. The bitwise complement at the
  // byte boundary GUARANTEES an 8-bit transition every 16-bit word
  // (~P[7] → P[0] always flips), exercising the same ISI conditions
  // real data sees. The calibrator is forced to find a (slip, phase)
  // robust to byte-boundary transitions, not just a same-byte-repeat eye.
  //
  // Rotation uniqueness preserved: {P, ~P} has period exactly 16 (no
  // period-8 sub-period unless P == ~P, which requires P=0x00 or 0xFF
  // — neither of our 8 per-lane patterns is degenerate). Only one slip
  // value matches; lane_checker behaviour is unchanged at the protocol
  // level. Local-override tidelink_lane_checker.sv has the matching
  // {P, ~P} expected pattern.
  wire [15:0] _link_data_eff = io_training_mode_mux
                              ? {io_training_pattern, ~io_training_pattern}
                              : io_link_data;
  wire  tx_pad_array_0 = _link_data_eff[0]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_1 = _link_data_eff[1]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_2 = _link_data_eff[2]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_3 = _link_data_eff[3]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_4 = _link_data_eff[4]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_5 = _link_data_eff[5]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_6 = _link_data_eff[6]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_7 = _link_data_eff[7]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_8 = _link_data_eff[8]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_9 = _link_data_eff[9]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_10 = _link_data_eff[10]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_11 = _link_data_eff[11]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_12 = _link_data_eff[12]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_13 = _link_data_eff[13]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_14 = _link_data_eff[14]; // @[GPIO.scala 76:38]
  wire  tx_pad_array_15 = _link_data_eff[15]; // @[GPIO.scala 76:38]
  wire  _GEN_1 = 4'h1 == count ? tx_pad_array_1 : tx_pad_array_0; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_2 = 4'h2 == count ? tx_pad_array_2 : _GEN_1; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_3 = 4'h3 == count ? tx_pad_array_3 : _GEN_2; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_4 = 4'h4 == count ? tx_pad_array_4 : _GEN_3; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_5 = 4'h5 == count ? tx_pad_array_5 : _GEN_4; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_6 = 4'h6 == count ? tx_pad_array_6 : _GEN_5; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_7 = 4'h7 == count ? tx_pad_array_7 : _GEN_6; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_8 = 4'h8 == count ? tx_pad_array_8 : _GEN_7; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_9 = 4'h9 == count ? tx_pad_array_9 : _GEN_8; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_10 = 4'ha == count ? tx_pad_array_10 : _GEN_9; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_11 = 4'hb == count ? tx_pad_array_11 : _GEN_10; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_12 = 4'hc == count ? tx_pad_array_12 : _GEN_11; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_13 = 4'hd == count ? tx_pad_array_13 : _GEN_12; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  wire  _GEN_14 = 4'he == count ? tx_pad_array_14 : _GEN_13; // @[GPIO.scala 78:21 GPIO.scala 78:21]
  WavResetSync hs_reset_scan_wrs ( // @[Stdcell.scala 324:21]
    .io_clk(hs_reset_scan_wrs_io_clk),
    .io_scan_ctrl(hs_reset_scan_wrs_io_scan_ctrl),
    .io_reset_in(hs_reset_scan_wrs_io_reset_in),
    .io_reset_out(hs_reset_scan_wrs_io_reset_out)
  );
  WavClockGate hs_clk_gated_wcg ( // @[Stdcell.scala 469:21]
    .io_clk_in(hs_clk_gated_wcg_io_clk_in),
    .io_enable(hs_clk_gated_wcg_io_enable),
    .io_test_en(hs_clk_gated_wcg_io_test_en),
    .io_clk_out(hs_clk_gated_wcg_io_clk_out)
  );
  WavClockMux io_link_clk_mux ( // @[Stdcell.scala 149:21]
    .io_i_sel(io_link_clk_mux_io_i_sel),
    .io_i_a(io_link_clk_mux_io_i_a),
    .io_i_b(io_link_clk_mux_io_i_b),
    .io_o_z(io_link_clk_mux_io_o_z)
  );
  assign io_scan_out = 1'h0; // @[GPIO.scala 48:21]
  assign io_link_clk = io_link_clk_mux_io_o_z; // @[GPIO.scala 72:22]
  assign io_pad = 4'hf == count ? tx_pad_array_15 : _GEN_14; // @[GPIO.scala 81:21 GPIO.scala 81:21]
  assign io_pad_clk = hs_clk_gated_wcg_io_clk_out; // @[GPIO.scala 63:21]
  assign hs_reset_scan_wrs_io_clk = io_clk; // @[Stdcell.scala 325:23]
  assign hs_reset_scan_wrs_io_scan_ctrl = io_scan_asyncrst_ctrl; // @[Stdcell.scala 327:23]
  assign hs_reset_scan_wrs_io_reset_in = io_reset; // @[Stdcell.scala 326:23]
  assign hs_clk_gated_wcg_io_clk_in = io_clk; // @[Stdcell.scala 470:21]
  assign hs_clk_gated_wcg_io_enable = clk_en_qual; // @[Stdcell.scala 472:21]
  assign hs_clk_gated_wcg_io_test_en = io_scan_mode; // @[Stdcell.scala 473:21]
  assign io_link_clk_mux_io_i_sel = io_scan_mode; // @[Stdcell.scala 150:21]
  assign io_link_clk_mux_io_i_a = ~count[3]; // @[GPIO.scala 71:24]
  assign io_link_clk_mux_io_i_b = io_scan_clk; // @[Stdcell.scala 152:21]
  always @(posedge io_clk or posedge hs_reset_scan_wrs_io_reset_out) begin
    if (hs_reset_scan_wrs_io_reset_out) begin
      count <= 4'hf;
    end else begin
      count <= count + 4'h1;
    end
  end
  always @(posedge io_clk or posedge hs_reset_scan_wrs_io_reset_out) begin
    if (hs_reset_scan_wrs_io_reset_out) begin
      clk_en_qual <= 1'h0;
    end else if (&count_in) begin
      clk_en_qual <= io_clk_en;
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
  clk_en_qual = _RAND_1[0:0];
  _RAND_2 = {1{`RANDOM}};
  io_training_mode_q = _RAND_2[0:0];
`endif // RANDOMIZE_REG_INIT
  if (hs_reset_scan_wrs_io_reset_out) begin
    count = 4'hf;
  end
  if (hs_reset_scan_wrs_io_reset_out) begin
    clk_en_qual = 1'h0;
  end
  if (hs_reset_scan_wrs_io_reset_out) begin
    io_training_mode_q = 1'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
