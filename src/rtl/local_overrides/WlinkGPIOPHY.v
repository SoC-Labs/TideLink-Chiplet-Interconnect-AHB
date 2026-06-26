module WlinkGPIOPHY #(
  // SoC Labs §9 clock fix: pass-through to WavD2DGpio.USE_CLKBUF.
  parameter USE_CLKBUF = 1'b0,
  // SoC Labs §9 T3a: pass-through to WavD2DGpio.USE_T3A (per-lane comma-hunt
  // self-aligning RX). Default 0 = sim/ASIC bit-exact; FPGA wrapper sets 1.
  parameter USE_T3A   = 1'b0
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
  input          link_tx_tx_idle,   // SoC Labs 2026-06-06: LL idle -> gate SYNC insertion (passthrough to gpio)
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
  // SoC Labs FIX-R (word-window pin, 2026-06-23): per-lane 4-bit word-window
  // pin (8x4b) + per-lane enable. Pass-through to WavD2DGpio, mirroring
  // swi_phase_offset_in. Tie 0 -> legacy framing (bit-exact default).
  input  [31:0]  swi_word_pin_perlane_in,
  input  [7:0]   swi_word_pin_perlane_en_in,
  // SoC Labs eyescan integration (WI-1, 2026-06-25): cal-window PRBS-15 TX
  // instrument. escan_tx_en is the controller's cal_window & eyescan_arm gate
  // (hclk/apb-domain quasi-static level). When HIGH, the 128-bit PRBS-15 word
  // (one per accepted TX beat) is muxed onto the link TX in place of the live
  // LL_TX word — a SEPARATE path from the per-lane PRBS-7 *training* mux inside
  // WavD2DGpioTx. With escan_tx_en=0 (POR default, eyescan_arm=0) the mux is a
  // pure passthrough so the TX datapath is bit-identical to 8ab846ba.
  input          escan_tx_en
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
  // SoC Labs eyescan FIX #1b (2026-06-26): forward-declare the TX-link-clk-synced
  // armed cal-window level so it can be connected to the WavD2DGpio instance
  // (io_escan_active) BELOW its always-block definition. VCS infers an implicit
  // net at first port use otherwise, clashing with the reg declaration.
  reg   escan_gate_tx1;
  wire  gpio_io_link_tx_tx_idle; // SoC Labs 2026-06-06
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
  WavD2DGpio #(.USE_CLKBUF(USE_CLKBUF), .USE_T3A(USE_T3A)) gpio ( // @[PHY.scala 376:27]
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
    .io_link_tx_tx_idle(gpio_io_link_tx_tx_idle),
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
    // SoC Labs FIX-R (word-window pin, 2026-06-23): per-lane word-pin + enable.
    .io_swi_word_pin_perlane_in(swi_word_pin_perlane_in),
    .io_swi_word_pin_perlane_en_in(swi_word_pin_perlane_en_in),
    // SoC Labs eyescan FIX #1b (2026-06-26): suppress the SYNC beacon while the
    // eyescan PRBS owns the wire. escan_gate_tx1 is the TX-link-clk-synced armed
    // cal-window level (declared below). arm=0 -> 0 -> bit-identical.
    .io_escan_active(escan_gate_tx1)
  );
  // ==========================================================================
  // SoC Labs eyescan PRBS-15 TX instrument (WI-1, 2026-06-25).
  //
  // Drives a PRBS-15 word onto the link TX during the calibration window so the
  // partner die's per-lane self-sync checkers (in axi_chiplet_controller) can
  // measure a REAL per-lane BER and the calibrator can pin each lane on its eye
  // centre. Reused VERBATIM from tidelink_phy_bist_core.sv:855-919 — same
  // generator module, same CDC, same tx_beat/gen_en cadence.
  //
  // ⚠ CRITICAL CLOCK DOMAIN (the one real hazard): the PHY's link_tx interface
  // (tx_ready, the per-word cadence) lives in the TX LINK-CLOCK domain
  // (gpio_io_link_tx_tx_link_clk = io_hsclk/16), NOT hclk. The generator MUST
  // advance EXACTLY once per accepted word, so it is clocked by that link clock.
  // Clocking it on hclk would let one link-clk-wide tx_ready pulse span several
  // hclk cycles -> a DECIMATED PRBS (garbage to the self-sync checker) while a
  // constant training word survives untouched — the historical "training locks,
  // payload never syncs" trap. escan_tx_en originates in hclk (controller
  // cal_window & eyescan_arm); 2-flop SYNC it into the TX link-clock domain
  // (mirrors the BIST gate_tx0/gate_tx1 pattern). A reload pulse on the rising
  // edge re-seeds the LFSR once per arm so both dies start from a known state.
  //
  // With escan_tx_en=0 (POR; eyescan_arm=0) gate_tx1=0 -> gen_en=0 (LFSR holds)
  // and the mux selects link_tx_tx_link_data -> bit-identical to 8ab846ba.
  // ==========================================================================
  localparam ESCAN_WORD_W = 128;

  wire escan_tx_clk = gpio_io_link_tx_tx_link_clk;   // TX link clock (io_hsclk/16)
  wire escan_tx_rst = por_reset;                     // async, active-high

  // 2-flop sync of escan_tx_en (hclk-domain level) into the TX link-clk domain,
  // plus a 3-stage edge-detect for a one-shot reload pulse on the arm rising
  // edge (so a re-arm restarts the PRBS sequence under a freshly-seeded LFSR).
  reg escan_gate_tx0;   // escan_gate_tx1 forward-declared above (FIX #1b)
  reg escan_arm_tx0, escan_arm_tx1, escan_arm_tx2;
  always @(posedge escan_tx_clk or posedge escan_tx_rst) begin
    if (escan_tx_rst) begin
      escan_gate_tx0 <= 1'b0; escan_gate_tx1 <= 1'b0;
      escan_arm_tx0  <= 1'b0; escan_arm_tx1  <= 1'b0; escan_arm_tx2 <= 1'b0;
    end else begin
      escan_gate_tx0 <= escan_tx_en;  escan_gate_tx1 <= escan_gate_tx0;
      escan_arm_tx0  <= escan_tx_en;  escan_arm_tx1  <= escan_arm_tx0;
      escan_arm_tx2  <= escan_arm_tx1;
    end
  end
  wire escan_tx_load = escan_arm_tx1 & ~escan_arm_tx2;     // 1 link-clk reload pulse

  // SoC Labs eyescan FIX #1 (PRIMARY, 2026-06-26): keep the PHY TX clocking
  // alive across the armed cal window. The ROOT-CAUSE bug WI-1 missed: during
  // S_VALIDATE the live LL is idle so link_tx_tx_en (=txpstate_io_tx_en) is
  // LOW. WavD2DGpio gates io_clk_en OFF (serializer stops -> the peer's
  // rx_link_clk dies) and forces io_link_tx_tx_ready=0 whenever io_link_tx_tx_en
  // is low (WavD2DGpio.v:998,1016). So with the old gpio_io_link_tx_tx_en =
  // link_tx_tx_en, no PRBS ever reaches the wire -> lane_synced stays 0 ->
  // the eyescan can never converge. Mirror the BIST ctrl_run contract: OR the
  // synced cal-window keep-alive (escan_gate_tx1) into the PHY TX enable so the
  // serializer runs and tx_ready keeps pulsing once/word for the whole armed
  // window. escan_gate_tx1=0 at POR / arm=0 -> bit-identical to 8ab846ba.
  // (Silicon-necessary: cures the serializer clock-gating that kills the peer's
  // recovered rx_link_clk. The shared-clock pair sim shares the RX clock so it
  // cannot reproduce that mode — this fix is validated on silicon, not in sim.)
  wire gpio_io_link_tx_tx_en_w = link_tx_tx_en | escan_gate_tx1;

  // tx_beat = a word was accepted this link-clk. Derived from the GATED TX
  // enable (gpio_io_link_tx_tx_en_w) so the LFSR advances exactly once per
  // accepted word during the cal window (when link_tx_tx_en alone is low but
  // the keep-alive holds the serializer running). gen_en advances the LFSR by
  // one 128-bit word only while gated AND accepted.
  wire escan_tx_beat = gpio_io_link_tx_tx_en_w & gpio_io_link_tx_tx_ready;
  wire escan_gen_en  = escan_tx_beat & escan_gate_tx1;

  wire [ESCAN_WORD_W-1:0] escan_prbs_word;
  tidelink_phy_bist_prbs_gen #(
    .WORD_W (ESCAN_WORD_W)
  ) u_escan_prbs_gen (
    .clk    (escan_tx_clk),
    .rst    (escan_tx_rst),
    .en     (escan_gen_en),
    .seed   (15'h0),                // 0 -> module's internal DEFAULT_SEED
    .load   (escan_tx_load),
    .word_o (escan_prbs_word)
  );

  // SEPARATE path from the PRBS-7 *training* mux (that lives downstream in
  // WavD2DGpioTx). Here we replace the LL_TX word with PRBS-15 ONLY during the
  // cal window; training_mode (asserted by the calibrator) still wins inside
  // WavD2DGpioTx, but by construction the cal window runs in S_VALIDATE where
  // training_mode is LOW, so the PRBS reaches the wire.
  wire [127:0] escan_tx_link_data = escan_gate_tx1 ? escan_prbs_word
                                                   : link_tx_tx_link_data;

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
  // SoC Labs eyescan FIX #1 (PRIMARY): keep TX clocking alive over the armed
  // cal window (see escan_tx_beat above). gpio_io_link_tx_tx_en_w =
  // link_tx_tx_en | escan_gate_tx1. arm=0 / POR -> escan_gate_tx1=0 -> identical
  // to the prior pure passthrough.
  assign gpio_io_link_tx_tx_en = gpio_io_link_tx_tx_en_w; // @[PHY.scala 408:32]
  assign gpio_io_link_tx_tx_idle = link_tx_tx_idle; // SoC Labs 2026-06-06
  // SoC Labs eyescan (WI-1): muxed link data (PRBS-15 in the cal window, else
  // the live LL_TX word). escan_gate_tx1=0 at POR -> == link_tx_tx_link_data.
  assign gpio_io_link_tx_tx_link_data = escan_tx_link_data; // @[PHY.scala 408:32]
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
