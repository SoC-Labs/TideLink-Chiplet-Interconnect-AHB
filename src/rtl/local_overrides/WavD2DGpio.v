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
  parameter USE_CAP_CLKBUF = USE_CLKBUF,
  parameter USE_LNK_CLKBUF = USE_CLKBUF,
  // SoC Labs §9 T3a (2026-05-19): self-aligning RX comma hunt. Per-lane
  // WavD2DGpioRx hunts for the per-lane training byte in the io_pad bit
  // stream and slips `count` to align to the byte boundary. The per-lane
  // training bytes are passed via per-instance TRAINING_BYTE parameter
  // overrides on the gpiorx_<N> instances below (matching the constants
  // wired to gpiotx_<N>.io_training_pattern — lane 0 = 0xA3, ..., lane 7 =
  // 0x2D). Default 0 (sim/ASIC bit-exact); FPGA wrapper sets 1.
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
  input  [31:0]  io_swi_phase_offset_in
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
  wire  tx_lane_en = io_link_tx_tx_lane_mask[0]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data = io_link_tx_tx_link_data[15:0]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_1 = io_link_tx_tx_lane_mask[1]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_1 = io_link_tx_tx_link_data[31:16]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_2 = io_link_tx_tx_lane_mask[2]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_2 = io_link_tx_tx_link_data[47:32]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_3 = io_link_tx_tx_lane_mask[3]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_3 = io_link_tx_tx_link_data[63:48]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_4 = io_link_tx_tx_lane_mask[4]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_4 = io_link_tx_tx_link_data[79:64]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_5 = io_link_tx_tx_lane_mask[5]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_5 = io_link_tx_tx_link_data[95:80]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_6 = io_link_tx_tx_lane_mask[6]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_6 = io_link_tx_tx_link_data[111:96]; // @[GPIO.scala 212:56]
  wire  tx_lane_en_7 = io_link_tx_tx_lane_mask[7]; // @[GPIO.scala 211:56]
  wire [15:0] tx_lane_data_7 = io_link_tx_tx_link_data[127:112]; // @[GPIO.scala 212:56]
  reg [7:0] precount; // @[GPIO.scala 223:114]
  wire  _precount_in_T = precount == 8'h0; // @[GPIO.scala 224:64]
  wire [7:0] _precount_in_T_2 = precount - 8'h1; // @[GPIO.scala 224:92]
  reg [7:0] swi_pream_count_1; // @[SW.scala 83:22]
  reg [7:0] postcount; // @[GPIO.scala 226:114]
  wire  _postcount_in_T = ~io_link_tx_tx_en; // @[GPIO.scala 227:33]
  wire [7:0] _postcount_in_T_3 = postcount - 8'h1; // @[GPIO.scala 227:96]
  reg [7:0] out_prepend_swi_post_count; // @[SW.scala 83:22]
  wire  rx_lane_en = io_link_rx_rx_lane_mask[0]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_0 = rx_lane_en ? gpiorx_0_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_1 = io_link_rx_rx_lane_mask[1]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_1 = rx_lane_en_1 ? gpiorx_1_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_2 = io_link_rx_rx_lane_mask[2]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_2 = rx_lane_en_2 ? gpiorx_2_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_3 = io_link_rx_rx_lane_mask[3]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_3 = rx_lane_en_3 ? gpiorx_3_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_4 = io_link_rx_rx_lane_mask[4]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_4 = rx_lane_en_4 ? gpiorx_4_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_5 = io_link_rx_rx_lane_mask[5]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_5 = rx_lane_en_5 ? gpiorx_5_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_6 = io_link_rx_rx_lane_mask[6]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_6 = rx_lane_en_6 ? gpiorx_6_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire  rx_lane_en_7 = io_link_rx_rx_lane_mask[7]; // @[GPIO.scala 242:56]
  wire [15:0] rx_link_data_7 = rx_lane_en_7 ? gpiorx_7_io_link_data : 16'h0; // @[GPIO.scala 243:37]
  wire [63:0] io_link_rx_rx_link_data_lo = {rx_link_data_3,rx_link_data_2,rx_link_data_1,rx_link_data_0}; // @[GPIO.scala 246:47]
  wire [63:0] io_link_rx_rx_link_data_hi = {rx_link_data_7,rx_link_data_6,rx_link_data_5,rx_link_data_4}; // @[GPIO.scala 246:47]
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
  wire        effective_training_mode_tx_raw = input_training_mode_w;
  wire        effective_training_mode_rx =
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
  WavD2DGpioTx gpiotx_0 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_0_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_0_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_0_io_scan_clk),
    .io_scan_out(gpiotx_0_io_scan_out),
    .io_clk(gpiotx_0_io_clk),
    .io_reset(gpiotx_0_io_reset),
    .io_clk_en(gpiotx_0_io_clk_en),
    .io_link_data(gpiotx_0_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hA3),
    .io_link_clk(gpiotx_0_io_link_clk),
    .io_pad(gpiotx_0_io_pad),
    .io_pad_clk(gpiotx_0_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_1 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_1_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_1_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_1_io_scan_clk),
    .io_scan_out(gpiotx_1_io_scan_out),
    .io_clk(gpiotx_1_io_clk),
    .io_reset(gpiotx_1_io_reset),
    .io_clk_en(gpiotx_1_io_clk_en),
    .io_link_data(gpiotx_1_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hB5),
    .io_link_clk(gpiotx_1_io_link_clk),
    .io_pad(gpiotx_1_io_pad),
    .io_pad_clk(gpiotx_1_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_2 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_2_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_2_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_2_io_scan_clk),
    .io_scan_out(gpiotx_2_io_scan_out),
    .io_clk(gpiotx_2_io_clk),
    .io_reset(gpiotx_2_io_reset),
    .io_clk_en(gpiotx_2_io_clk_en),
    .io_link_data(gpiotx_2_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hC9),
    .io_link_clk(gpiotx_2_io_link_clk),
    .io_pad(gpiotx_2_io_pad),
    .io_pad_clk(gpiotx_2_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_3 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_3_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_3_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_3_io_scan_clk),
    .io_scan_out(gpiotx_3_io_scan_out),
    .io_clk(gpiotx_3_io_clk),
    .io_reset(gpiotx_3_io_reset),
    .io_clk_en(gpiotx_3_io_clk_en),
    .io_link_data(gpiotx_3_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'hD3),
    .io_link_clk(gpiotx_3_io_link_clk),
    .io_pad(gpiotx_3_io_pad),
    .io_pad_clk(gpiotx_3_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_4 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_4_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_4_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_4_io_scan_clk),
    .io_scan_out(gpiotx_4_io_scan_out),
    .io_clk(gpiotx_4_io_clk),
    .io_reset(gpiotx_4_io_reset),
    .io_clk_en(gpiotx_4_io_clk_en),
    .io_link_data(gpiotx_4_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h65),
    .io_link_clk(gpiotx_4_io_link_clk),
    .io_pad(gpiotx_4_io_pad),
    .io_pad_clk(gpiotx_4_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_5 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_5_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_5_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_5_io_scan_clk),
    .io_scan_out(gpiotx_5_io_scan_out),
    .io_clk(gpiotx_5_io_clk),
    .io_reset(gpiotx_5_io_reset),
    .io_clk_en(gpiotx_5_io_clk_en),
    .io_link_data(gpiotx_5_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h4B),
    .io_link_clk(gpiotx_5_io_link_clk),
    .io_pad(gpiotx_5_io_pad),
    .io_pad_clk(gpiotx_5_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_6 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_6_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_6_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_6_io_scan_clk),
    .io_scan_out(gpiotx_6_io_scan_out),
    .io_clk(gpiotx_6_io_clk),
    .io_reset(gpiotx_6_io_reset),
    .io_clk_en(gpiotx_6_io_clk_en),
    .io_link_data(gpiotx_6_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h59),
    .io_link_clk(gpiotx_6_io_link_clk),
    .io_pad(gpiotx_6_io_pad),
    .io_pad_clk(gpiotx_6_io_pad_clk)
  );
  WavD2DGpioTx gpiotx_7 ( // @[GPIO.scala 190:61]
    .io_scan_mode(gpiotx_7_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiotx_7_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiotx_7_io_scan_clk),
    .io_scan_out(gpiotx_7_io_scan_out),
    .io_clk(gpiotx_7_io_clk),
    .io_reset(gpiotx_7_io_reset),
    .io_clk_en(gpiotx_7_io_clk_en),
    .io_link_data(gpiotx_7_io_link_data),
    .io_training_mode(effective_training_mode_tx),  // V2: immediate drop
    .io_training_pattern(8'h2D),
    .io_link_clk(gpiotx_7_io_link_clk),
    .io_pad(gpiotx_7_io_pad),
    .io_pad_clk(gpiotx_7_io_pad_clk)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'hA3)) gpiorx_0 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_0_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_0_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_0_io_scan_clk),
    .io_scan_out(gpiorx_0_io_scan_out),
    .io_por_reset(gpiorx_0_io_por_reset),
    .io_pol(gpiorx_0_io_pol),
    .io_phase_offset(effective_phase_offset[3:0]),
    .io_bit_slip(effective_bit_slip[2:0]),
    .io_link_clk(gpiorx_0_io_link_clk),
    .io_link_data(gpiorx_0_io_link_data),
    .io_pad_clk(gpiorx_0_io_pad_clk),
    .io_pad(gpiorx_0_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'hB5)) gpiorx_1 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_1_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_1_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_1_io_scan_clk),
    .io_scan_out(gpiorx_1_io_scan_out),
    .io_por_reset(gpiorx_1_io_por_reset),
    .io_pol(gpiorx_1_io_pol),
    .io_phase_offset(effective_phase_offset[7:4]),
    .io_bit_slip(effective_bit_slip[5:3]),
    .io_link_clk(gpiorx_1_io_link_clk),
    .io_link_data(gpiorx_1_io_link_data),
    .io_pad_clk(gpiorx_1_io_pad_clk),
    .io_pad(gpiorx_1_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'hC9)) gpiorx_2 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_2_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_2_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_2_io_scan_clk),
    .io_scan_out(gpiorx_2_io_scan_out),
    .io_por_reset(gpiorx_2_io_por_reset),
    .io_pol(gpiorx_2_io_pol),
    .io_phase_offset(effective_phase_offset[11:8]),
    .io_bit_slip(effective_bit_slip[8:6]),
    .io_link_clk(gpiorx_2_io_link_clk),
    .io_link_data(gpiorx_2_io_link_data),
    .io_pad_clk(gpiorx_2_io_pad_clk),
    .io_pad(gpiorx_2_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'hD3)) gpiorx_3 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_3_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_3_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_3_io_scan_clk),
    .io_scan_out(gpiorx_3_io_scan_out),
    .io_por_reset(gpiorx_3_io_por_reset),
    .io_pol(gpiorx_3_io_pol),
    .io_phase_offset(effective_phase_offset[15:12]),
    .io_bit_slip(effective_bit_slip[11:9]),
    .io_link_clk(gpiorx_3_io_link_clk),
    .io_link_data(gpiorx_3_io_link_data),
    .io_pad_clk(gpiorx_3_io_pad_clk),
    .io_pad(gpiorx_3_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'h65)) gpiorx_4 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_4_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_4_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_4_io_scan_clk),
    .io_scan_out(gpiorx_4_io_scan_out),
    .io_por_reset(gpiorx_4_io_por_reset),
    .io_pol(gpiorx_4_io_pol),
    .io_phase_offset(effective_phase_offset[19:16]),
    .io_bit_slip(effective_bit_slip[14:12]),
    .io_link_clk(gpiorx_4_io_link_clk),
    .io_link_data(gpiorx_4_io_link_data),
    .io_pad_clk(gpiorx_4_io_pad_clk),
    .io_pad(gpiorx_4_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'h4B)) gpiorx_5 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_5_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_5_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_5_io_scan_clk),
    .io_scan_out(gpiorx_5_io_scan_out),
    .io_por_reset(gpiorx_5_io_por_reset),
    .io_pol(gpiorx_5_io_pol),
    .io_phase_offset(effective_phase_offset[23:20]),
    .io_bit_slip(effective_bit_slip[17:15]),
    .io_link_clk(gpiorx_5_io_link_clk),
    .io_link_data(gpiorx_5_io_link_data),
    .io_pad_clk(gpiorx_5_io_pad_clk),
    .io_pad(gpiorx_5_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'h59)) gpiorx_6 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_6_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_6_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_6_io_scan_clk),
    .io_scan_out(gpiorx_6_io_scan_out),
    .io_por_reset(gpiorx_6_io_por_reset),
    .io_pol(gpiorx_6_io_pol),
    .io_phase_offset(effective_phase_offset[27:24]),
    .io_bit_slip(effective_bit_slip[20:18]),
    .io_link_clk(gpiorx_6_io_link_clk),
    .io_link_data(gpiorx_6_io_link_data),
    .io_pad_clk(gpiorx_6_io_pad_clk),
    .io_pad(gpiorx_6_io_pad)
  );
  WavD2DGpioRx #(.USE_CLKBUF(USE_CLKBUF), .USE_CAP_CLKBUF(USE_CAP_CLKBUF), .USE_LNK_CLKBUF(USE_LNK_CLKBUF), .USE_T3A(USE_T3A), .TRAINING_BYTE(8'h2D)) gpiorx_7 ( // @[GPIO.scala 191:61]
    .io_scan_mode(gpiorx_7_io_scan_mode),
    .io_scan_asyncrst_ctrl(gpiorx_7_io_scan_asyncrst_ctrl),
    .io_scan_clk(gpiorx_7_io_scan_clk),
    .io_scan_out(gpiorx_7_io_scan_out),
    .io_por_reset(gpiorx_7_io_por_reset),
    .io_pol(gpiorx_7_io_pol),
    .io_phase_offset(effective_phase_offset[31:28]),
    .io_bit_slip(effective_bit_slip[23:21]),
    .io_link_clk(gpiorx_7_io_link_clk),
    .io_link_data(gpiorx_7_io_link_data),
    .io_pad_clk(gpiorx_7_io_pad_clk),
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
  assign io_link_tx_tx_link_clk = gpiotx_0_io_link_clk; // @[GPIO.scala 218:31]
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
  assign gpiotx_0_io_link_data = tx_lane_en ? tx_lane_data : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_1_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_1_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_1_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_1_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_1_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_1_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_1_io_link_data = tx_lane_en_1 ? tx_lane_data_1 : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_2_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_2_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_2_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_2_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_2_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_2_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_2_io_link_data = tx_lane_en_2 ? tx_lane_data_2 : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_3_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_3_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_3_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_3_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_3_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_3_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_3_io_link_data = tx_lane_en_3 ? tx_lane_data_3 : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_4_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_4_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_4_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_4_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_4_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_4_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_4_io_link_data = tx_lane_en_4 ? tx_lane_data_4 : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_5_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_5_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_5_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_5_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_5_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_5_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_5_io_link_data = tx_lane_en_5 ? tx_lane_data_5 : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_6_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_6_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_6_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_6_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_6_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_6_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_6_io_link_data = tx_lane_en_6 ? tx_lane_data_6 : 16'h0; // @[GPIO.scala 213:37]
  assign gpiotx_7_io_scan_mode = io_scan_mode; // @[Bundles.scala 19:19]
  assign gpiotx_7_io_scan_asyncrst_ctrl = io_scan_asyncrst_ctrl; // @[Bundles.scala 20:19]
  assign gpiotx_7_io_scan_clk = io_scan_clk; // @[Bundles.scala 21:19]
  assign gpiotx_7_io_clk = hsclk_scan_mux_io_o_z; // @[GPIO.scala 204:31]
  assign gpiotx_7_io_reset = io_por_reset; // @[GPIO.scala 205:31]
  assign gpiotx_7_io_clk_en = io_link_tx_tx_en | postcount != 8'h0 & _postcount_in_T | effective_training_mode; // SoC Labs §9: keep serialiser clocked during training
  assign gpiotx_7_io_link_data = tx_lane_en_7 ? tx_lane_data_7 : 16'h0; // @[GPIO.scala 213:37]
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
