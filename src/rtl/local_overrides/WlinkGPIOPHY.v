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
  input  [31:0]  swi_phase_offset_in
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
    .io_swi_phase_offset_in(swi_phase_offset_in)
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
  assign gpio_io_link_tx_tx_idle = link_tx_tx_idle; // SoC Labs 2026-06-06
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
