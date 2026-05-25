// =============================================================================
// SoC Labs L6 producer-side fix (2026-05-26): minimum CR-emit hold in state==1
// -----------------------------------------------------------------------------
// Bug class observed in cocotb wlink_pair fuzz (6/12 scenarios fail):
//   * Master starts bring-up 2 cycles before slave (lock_master then lock_slave)
//   * Slave's RX framer (WlinkRxLinkLayer / LL_RX) byte-aligns FIRST and decodes
//     master's CR(0x44) packets — cr_pkt_seen_rx latches on slave side.
//   * That tx-synchronizes to cr_pkt_seen_tx_demet_io_out=1 → _GEN_34 fires →
//     slave's FCSM transitions state 1 → state 2 within ~500 master clks of
//     entering state 1.  Slave then stops emitting CR(0x44) (state 2 only
//     emits CRACK(0x45)).
//   * Master's RX framer is still hunting for byte-align at that point.  By
//     the time master's framer locks, slave is no longer producing CR, so
//     master.cr_pkt_seen_rx never latches.  Master's FCSM stalls at LINK_IDLE
//     because credits never properly cross.
//
// Root cause: state 1 → state 2 transition (FC.scala _GEN_34) fires as soon as
// EITHER cr_seen OR crack_seen latches on the tx-domain synchronizer.  This
// is correct in the SYMMETRIC case (both RX framers lock within the same CR
// burst) but fails ASYMMETRICALLY when one side's framer locks much earlier
// than the other.  Master's RX framer needs time to byte-align; slave's
// state 1 exit is too aggressive and "shuts the door" on master's framer.
//
// Producer-side fix (this file): introduce socl_l6_cr_emit_count counter
// that increments on each (auto_tx_out_advance & sop & state==1) cycle, and
// gate _GEN_34 on that count reaching at least SOCL_L6_MIN_CR_EMITS.  This
// guarantees the FCSM emits a minimum number of CR packets before allowing
// state 1 exit — giving the peer's RX framer time to lock onto a CR packet.
//
// This does NOT change behavior in the symmetric case: in steady state both
// sides will emit at least MIN CR before any cr_seen/crack_seen latches; with
// the synchronizer+framer latency the gate is already met by the time the
// peer reaches state 2.  In the asymmetric case the gate keeps slave emitting
// CR for the full MIN window, ensuring master's RX framer (now byte-aligning)
// can latch onto a CR.
//
// MIN value (32) chosen: well below the ~500-cycle state 1 window in the
// failing scenarios (slave naturally stayed in state 1 for cyc 67..563 = 496
// cycles in the failing fuzz scenario, so 32 is comfortably within that
// window and adds <5% to the bring-up critical path).  Synthesizable as a
// localparam.
// =============================================================================
module WlinkGenericFCSM_6 #(
  parameter [7:0] SOCL_L6_MIN_CR_EMITS = 8'd32
) (
  input         clock,
  input         reset,
  input         auto_in_psel,
  input         auto_in_penable,
  input         auto_in_pwrite,
  input  [12:0] auto_in_paddr,
  input  [31:0] auto_in_pwdata,
  input  [3:0]  auto_in_pstrb,
  output        auto_in_pready,
  output [31:0] auto_in_prdata,
  input         auto_rx_in_sop,
  input  [7:0]  auto_rx_in_data_id,
  input  [15:0] auto_rx_in_word_count,
  input  [55:0] auto_rx_in_data,
  input         auto_rx_in_valid,
  input  [15:0] auto_rx_in_crc,
  output        auto_tx_out_sop,
  output [7:0]  auto_tx_out_data_id,
  output [15:0] auto_tx_out_word_count,
  output [55:0] auto_tx_out_data,
  output [15:0] auto_tx_out_crc,
  input         auto_tx_out_advance,
  input         io_app_clk,
  input         io_app_reset,
  input         io_app_enable,
  input         io_app_a2l_valid,
  input  [47:0] io_app_a2l_data,
  output        io_app_a2l_ready,
  output        io_app_l2a_valid,
  output [47:0] io_app_l2a_data,
  input         io_app_l2a_accept,
  input         io_tx_clk,
  input         io_tx_reset,
  input         io_rx_clk,
  input         io_rx_reset,
  output        io_rx_crc_err,
  // SoC Labs credit-path observability (read-only APB exposure of the FC
  // state machine — replaces the ILA debug core). These mirror existing
  // internal nets; promoting them to outputs is structurally free.
  //   io_obs_state          : FC state machine `state` (io_tx_clk domain;
  //                           wedges at 1 in the bring-up failure).
  //   io_obs_cr_pkt_seen_rx : sticky cr-pkt-seen (io_rx_clk domain; the
  //                           0e126b0 sticky-reset fix is read as-is).
  //   io_obs_crack_pkt_seen_rx : sticky crack-pkt-seen (io_rx_clk).
  //   io_obs_pkt_is_cr_pkt / io_obs_pkt_is_crack_pkt : combinational
  //                           decode off auto_rx_in_* (io_rx_clk domain).
  // 2-flop-synced into apb_clk by axi_chiplet_controller.sv.
  output [2:0]  io_obs_state,
  output        io_obs_cr_pkt_seen_rx,
  output        io_obs_crack_pkt_seen_rx,
  output        io_obs_pkt_is_cr_pkt,
  output        io_obs_pkt_is_crack_pkt
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
  reg [63:0] _RAND_17;
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
  reg [31:0] _RAND_28;
  reg [31:0] _RAND_29;
  reg [31:0] _RAND_30;
  reg [31:0] _RAND_31;
`endif // RANDOMIZE_REG_INIT
  wire [55:0] rx_crc_computed_crcgen_io_in; // @[LinkLayer.scala 1274:24]
  wire [15:0] rx_crc_computed_crcgen_io_out; // @[LinkLayer.scala 1274:24]
  wire  en_ff2_rx_demet_clock; // @[Stdcell.scala 58:23]
  wire  en_ff2_rx_demet_reset; // @[Stdcell.scala 58:23]
  wire  en_ff2_rx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  en_ff2_rx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  l2a_fc_replay_app_clk; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_reset; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_enable; // @[FC.scala 219:43]
  wire [47:0] l2a_fc_replay_app_data; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_valid; // @[FC.scala 219:43]
  wire  l2a_fc_replay_app_ready; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_clk; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_reset; // @[FC.scala 219:43]
  wire [4:0] l2a_fc_replay_link_ack_addr; // @[FC.scala 219:43]
  wire [4:0] l2a_fc_replay_link_cur_addr; // @[FC.scala 219:43]
  wire [47:0] l2a_fc_replay_link_data; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_valid; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_advance; // @[FC.scala 219:43]
  wire  l2a_fc_replay_link_empty; // @[FC.scala 219:43]
  wire  l2a_fifo_addr_to_tx_w_clk; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_w_reset; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_w_inc; // @[FC.scala 241:43]
  wire [4:0] l2a_fifo_addr_to_tx_w_addr; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_r_clk; // @[FC.scala 241:43]
  wire  l2a_fifo_addr_to_tx_r_reset; // @[FC.scala 241:43]
  wire [4:0] l2a_fifo_addr_to_tx_r_addr; // @[FC.scala 241:43]
  wire  ack_nack_fifo_io_wclk; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_wreset; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_winc; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rclk; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rreset; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rinc; // @[FC.scala 260:41]
  wire [18:0] ack_nack_fifo_io_wdata; // @[FC.scala 260:41]
  wire [18:0] ack_nack_fifo_io_rdata; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_wfull; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_rempty; // @[FC.scala 260:41]
  wire [2:0] ack_nack_fifo_io_swi_almost_empty; // @[FC.scala 260:41]
  wire [2:0] ack_nack_fifo_io_swi_almost_full; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_half_full; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_almost_empty; // @[FC.scala 260:41]
  wire  ack_nack_fifo_io_almost_full; // @[FC.scala 260:41]
  wire  a2l_fc_replay_app_clk; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_reset; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_enable; // @[FC.scala 297:43]
  wire [47:0] a2l_fc_replay_app_data; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_valid; // @[FC.scala 297:43]
  wire  a2l_fc_replay_app_ready; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_clk; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_reset; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_ack_update; // @[FC.scala 297:43]
  wire [4:0] a2l_fc_replay_link_ack_addr; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_revert; // @[FC.scala 297:43]
  wire [4:0] a2l_fc_replay_link_revert_addr; // @[FC.scala 297:43]
  wire [4:0] a2l_fc_replay_link_cur_addr; // @[FC.scala 297:43]
  wire [47:0] a2l_fc_replay_link_data; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_valid; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_advance; // @[FC.scala 297:43]
  wire  a2l_fc_replay_link_empty; // @[FC.scala 297:43]
  wire  en_ff2_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  cr_pkt_seen_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  crack_pkt_seen_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire [55:0] bundleOut_0_crc_crcgen_io_in; // @[LinkLayer.scala 1274:24]
  wire [15:0] bundleOut_0_crc_crcgen_io_out; // @[LinkLayer.scala 1274:24]
  wire [7:0] ll_rx_pktnum = auto_rx_in_data[7:0]; // @[FC.scala 123:33]
  reg [2:0] state; // @[FC.scala 143:91]
  wire  _crc_corrupt_T = auto_rx_in_sop & auto_rx_in_valid; // @[FC.scala 157:52]
  reg [7:0] swi_data_id_1; // @[SW.scala 83:22]
  wire  _crc_corrupt_T_2 = auto_rx_in_sop & auto_rx_in_valid & auto_rx_in_data_id == swi_data_id_1; // @[FC.scala 157:67]
  reg  out_prepend_swi_disable_crc; // @[SW.scala 83:22]
  wire  crc_corrupt = auto_rx_in_sop & auto_rx_in_valid & auto_rx_in_data_id == swi_data_id_1 & ~
    out_prepend_swi_disable_crc & rx_crc_computed_crcgen_io_out != auto_rx_in_crc; // @[FC.scala 157:40]
  reg [15:0] crc_errors; // @[FC.scala 160:107]
  wire  pkt_is_data_pkt = _crc_corrupt_T_2 & ~crc_corrupt; // @[FC.scala 166:85]
  wire  valid_rx_pkt_crc_err = _crc_corrupt_T_2 & crc_corrupt; // @[FC.scala 167:85]
  reg [7:0] swi_cr_id; // @[SW.scala 83:22]
  wire  pkt_is_cr_pkt = _crc_corrupt_T & auto_rx_in_data_id == swi_cr_id; // @[FC.scala 169:50]
  reg [7:0] out_prepend_swi_crack_id; // @[SW.scala 83:22]
  wire  pkt_is_crack_pkt = _crc_corrupt_T & auto_rx_in_data_id == out_prepend_swi_crack_id; // @[FC.scala 170:50]
  reg [7:0] out_prepend_swi_ack_id; // @[SW.scala 83:22]
  wire  pkt_is_ack_pkt = _crc_corrupt_T & auto_rx_in_data_id == out_prepend_swi_ack_id; // @[FC.scala 171:50]
  reg [7:0] out_prepend_swi_nack_id; // @[SW.scala 83:22]
  wire  pkt_is_nack_pkt = _crc_corrupt_T & auto_rx_in_data_id == out_prepend_swi_nack_id; // @[FC.scala 172:50]
  reg [7:0] last_good_pkt; // @[FC.scala 179:107]
  reg [7:0] fe_rx_credit_max; // @[FC.scala 183:107]
  reg  cr_pkt_seen_rx; // @[FC.scala 186:107]
  reg  crack_pkt_seen_rx; // @[FC.scala 188:107]
  reg [7:0] exp_pkt_num; // @[FC.scala 193:44]
  wire [15:0] _crc_errors_in_T_2 = crc_errors + 16'h1; // @[FC.scala 196:123]
  wire [15:0] _crc_errors_in_T_3 = crc_errors == 16'hffff ? crc_errors : _crc_errors_in_T_2; // @[FC.scala 196:73]
  wire [15:0] _crc_errors_in_T_4 = crc_corrupt ? _crc_errors_in_T_3 : crc_errors; // @[FC.scala 196:56]
  wire [15:0] crc_errors_in = en_ff2_rx_demet_io_out ? _crc_errors_in_T_4 : 16'h0; // @[FC.scala 196:41]
  reg [7:0] fe_tx_credit_max; // @[FC.scala 200:44]
  wire  _fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out; // @[FC.scala 201:42]
  wire  _fe_tx_credit_max_in_T_1 = pkt_is_cr_pkt | pkt_is_crack_pkt; // @[FC.scala 201:77]
  wire  exp_pkt_seen = pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num; // @[FC.scala 210:54]
  wire  exp_pkt_not_seen = pkt_is_data_pkt & ll_rx_pktnum != exp_pkt_num; // @[FC.scala 211:54]
  wire [7:0] _exp_pkt_num_in_T_3 = exp_pkt_num + 8'h1; // @[FC.scala 212:132]
  wire [7:0] _last_good_pkt_in_T_1 = exp_pkt_seen ? exp_pkt_num : last_good_pkt; // @[FC.scala 213:62]
  wire [7:0] last_good_pkt_in = _fe_tx_credit_max_in_T ? 8'h0 : _last_good_pkt_in_T_1; // @[FC.scala 213:41]
  wire  ack_nack_fifo_valid = ~ack_nack_fifo_io_rempty; // @[FC.scala 261:35]
  wire  _ack_nack_fifo_io_winc_T = pkt_is_ack_pkt | pkt_is_nack_pkt; // @[FC.scala 264:51]
  wire [2:0] _pkttypenotifier_T_1 = valid_rx_pkt_crc_err ? 3'h4 : {{2'd0}, exp_pkt_not_seen}; // @[FC.scala 276:42]
  wire [2:0] _pkttypenotifier_T_2 = pkt_is_nack_pkt ? 3'h3 : _pkttypenotifier_T_1; // @[FC.scala 275:40]
  wire [2:0] pkttypenotifier = pkt_is_ack_pkt ? 3'h2 : _pkttypenotifier_T_2; // @[FC.scala 274:39]
  wire [18:0] _ack_nack_fifo_io_wdata_T_1 = {pkttypenotifier,auto_rx_in_word_count}; // @[Cat.scala 30:58]
  wire [18:0] _ack_nack_fifo_io_wdata_T_2 = {pkttypenotifier,8'h0,last_good_pkt_in}; // @[Cat.scala 30:58]
  wire  isExpPacket = ack_nack_fifo_io_rdata[18:16] == 3'h0 & ack_nack_fifo_valid; // @[FC.scala 287:73]
  wire  isNotExpPacket = ack_nack_fifo_io_rdata[18:16] == 3'h1 & ack_nack_fifo_valid; // @[FC.scala 288:73]
  wire  isAckPacket = ack_nack_fifo_io_rdata[18:16] == 3'h2 & ack_nack_fifo_valid; // @[FC.scala 289:73]
  wire  isNackPacket = ack_nack_fifo_io_rdata[18:16] == 3'h3 & ack_nack_fifo_valid; // @[FC.scala 290:73]
  wire  crcCorruptSeen = ack_nack_fifo_io_rdata[18:16] == 3'h4 & ack_nack_fifo_valid; // @[FC.scala 291:73]
  reg  sop; // @[FC.scala 318:48]
  reg [7:0] data_id; // @[FC.scala 320:48]
  reg [15:0] word_count; // @[FC.scala 322:48]
  reg [55:0] link_data; // @[FC.scala 324:48]
  reg [7:0] count; // @[FC.scala 331:48]
  wire [4:0] link_ack_addr = ack_nack_fifo_io_rdata[4:0]; // @[FC.scala 334:64]
  reg  ack_seen_before; // @[FC.scala 340:48]
  wire  _ack_seen_before_T = state == 3'h0; // @[FC.scala 341:53]
  wire [7:0] _GEN_315 = {{3'd0}, link_ack_addr}; // @[FC.scala 348:89]
  wire [4:0] _link_revert_addr_T_5 = link_ack_addr + 5'h1; // @[FC.scala 348:158]
  wire [4:0] _link_revert_addr_T_6 = _GEN_315 == 8'h1f ? 5'h0 : _link_revert_addr_T_5; // @[FC.scala 348:47]
  reg [7:0] fe_rx_ptr; // @[FC.scala 362:48]
  wire  _fe_rx_ptr_in_T = ~en_ff2_tx_demet_io_out; // @[FC.scala 363:46]
  reg [7:0] ne_rx_ptr; // @[FC.scala 366:48]
  wire [7:0] _ne_rx_ptr_next_T_2 = ne_rx_ptr + 8'h1; // @[FC.scala 368:95]
  wire [7:0] ne_rx_ptr_next = ne_rx_ptr == fe_rx_credit_max ? 8'h0 : _ne_rx_ptr_next_T_2; // @[FC.scala 368:45]
  wire [1:0] _GEN_2 = fe_rx_credit_max[2] ? 2'h2 : {{1'd0}, fe_rx_credit_max[1]}; // @[FC.scala 376:34 FC.scala 377:39]
  wire [1:0] _GEN_3 = fe_rx_credit_max[3] ? 2'h3 : _GEN_2; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] _GEN_4 = fe_rx_credit_max[4] ? 3'h4 : {{1'd0}, _GEN_3}; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] _GEN_5 = fe_rx_credit_max[5] ? 3'h5 : _GEN_4; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] _GEN_6 = fe_rx_credit_max[6] ? 3'h6 : _GEN_5; // @[FC.scala 376:34 FC.scala 377:39]
  wire [2:0] fe_rx_ptr_msb = fe_rx_credit_max[7] ? 3'h7 : _GEN_6; // @[FC.scala 376:34 FC.scala 377:39]
  wire  _GEN_8 = ne_rx_ptr_next[0] != fe_rx_ptr[0] ? 1'h0 : 1'h1; // @[FC.scala 387:51 FC.scala 388:41 FC.scala 384:39]
  wire  _GEN_9 = 3'h0 < fe_rx_ptr_msb ? _GEN_8 : 1'h1; // @[FC.scala 386:39 FC.scala 384:39]
  wire  _GEN_10 = ne_rx_ptr_next[1] != fe_rx_ptr[1] ? 1'h0 : _GEN_9; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_11 = 3'h1 < fe_rx_ptr_msb ? _GEN_10 : _GEN_9; // @[FC.scala 386:39]
  wire  _GEN_12 = ne_rx_ptr_next[2] != fe_rx_ptr[2] ? 1'h0 : _GEN_11; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_13 = 3'h2 < fe_rx_ptr_msb ? _GEN_12 : _GEN_11; // @[FC.scala 386:39]
  wire  _GEN_14 = ne_rx_ptr_next[3] != fe_rx_ptr[3] ? 1'h0 : _GEN_13; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_15 = 3'h3 < fe_rx_ptr_msb ? _GEN_14 : _GEN_13; // @[FC.scala 386:39]
  wire  _GEN_16 = ne_rx_ptr_next[4] != fe_rx_ptr[4] ? 1'h0 : _GEN_15; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_17 = 3'h4 < fe_rx_ptr_msb ? _GEN_16 : _GEN_15; // @[FC.scala 386:39]
  wire  _GEN_18 = ne_rx_ptr_next[5] != fe_rx_ptr[5] ? 1'h0 : _GEN_17; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_19 = 3'h5 < fe_rx_ptr_msb ? _GEN_18 : _GEN_17; // @[FC.scala 386:39]
  wire  _GEN_20 = ne_rx_ptr_next[6] != fe_rx_ptr[6] ? 1'h0 : _GEN_19; // @[FC.scala 387:51 FC.scala 388:41]
  wire  _GEN_21 = 3'h6 < fe_rx_ptr_msb ? _GEN_20 : _GEN_19; // @[FC.scala 386:39]
  wire [7:0] _T_44 = ne_rx_ptr_next >> fe_rx_ptr_msb; // @[FC.scala 393:26]
  wire [7:0] _T_46 = fe_rx_ptr >> fe_rx_ptr_msb; // @[FC.scala 393:55]
  wire  fe_rx_is_full = _T_44[0] == _T_46[0] ? 1'h0 : _GEN_21; // @[FC.scala 393:71 FC.scala 394:39]
  reg [4:0] l2a_fifo_raddr_txclk_prev; // @[FC.scala 400:48]
  wire [4:0] l2a_fifo_raddr_txclk = l2a_fifo_addr_to_tx_r_addr; // @[FC.scala 240:41 FC.scala 249:35]
  wire  l2a_fifo_raddr_txclk_update = l2a_fifo_raddr_txclk_prev != l2a_fifo_raddr_txclk; // @[FC.scala 401:67]
  reg  send_ack_req; // @[FC.scala 407:48]
  reg  send_nack_req; // @[FC.scala 409:48]
  reg [7:0] last_good_pkt_from_rx; // @[FC.scala 414:48]
  wire [7:0] _last_good_pkt_from_rx_in_T_2 = isExpPacket ? ack_nack_fifo_io_rdata[7:0] : last_good_pkt_from_rx; // @[FC.scala 415:66]
  wire [7:0] last_good_pkt_from_rx_in = _fe_rx_ptr_in_T ? 8'h0 : _last_good_pkt_from_rx_in_T_2; // @[FC.scala 415:45]
  reg [7:0] last_ack_pkt_sent; // @[FC.scala 418:48]
  wire  _GEN_25 = en_ff2_tx_demet_io_out | sop; // @[FC.scala 449:24 FC.scala 450:39 FC.scala 427:39]
  // SoC Labs L6 producer-side fix: count CR emissions in state==1, gate exit.
  reg  [7:0] socl_l6_cr_emit_count; // counts (advance & sop) cycles while state==1
  wire socl_l6_cr_emit_gate_ok = (socl_l6_cr_emit_count >= SOCL_L6_MIN_CR_EMITS);
  // Original Chisel-emitted _GEN_34 (kept as comment for review):
  //   wire [2:0] _GEN_34 = crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out ? 3'h2 : state;
  // Patched: only allow state 1 -> state 2 once minimum CR-emit count reached.
  wire [2:0] _GEN_34 = (crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out) & socl_l6_cr_emit_gate_ok
                       ? 3'h2 : state; // SoC Labs L6 gate
  wire  _GEN_35 = auto_tx_out_advance | sop; // @[FC.scala 459:28 FC.scala 427:39]
  wire [55:0] _GEN_38 = auto_tx_out_advance ? 56'h0 : link_data; // @[FC.scala 459:28 FC.scala 430:39]
  wire  _GEN_40 = crack_pkt_seen_tx_demet_io_out ? 1'h0 : 1'h1; // @[FC.scala 476:34 FC.scala 477:39 FC.scala 484:39]
  wire [7:0] _GEN_41 = crack_pkt_seen_tx_demet_io_out ? 8'h0 : out_prepend_swi_crack_id; // @[FC.scala 476:34 FC.scala 478:39 FC.scala 485:39]
  wire [15:0] _GEN_42 = crack_pkt_seen_tx_demet_io_out ? 16'h0 : 16'h1f1f; // @[FC.scala 476:34 FC.scala 479:39 FC.scala 486:39]
  reg [7:0] swi_link_en_wait; // @[SW.scala 83:22]
  wire [7:0] _GEN_44 = crack_pkt_seen_tx_demet_io_out ? swi_link_en_wait : count; // @[FC.scala 476:34 FC.scala 481:39 FC.scala 425:39]
  wire [2:0] _GEN_45 = crack_pkt_seen_tx_demet_io_out ? 3'h3 : state; // @[FC.scala 476:34 FC.scala 482:39 FC.scala 424:39]
  wire [2:0] _GEN_51 = auto_tx_out_advance ? _GEN_45 : state; // @[FC.scala 475:28 FC.scala 424:39]
  wire  _T_54 = count == 8'h0; // @[FC.scala 495:20]
  wire [7:0] _count_in_T_1 = count - 8'h1; // @[FC.scala 498:48]
  wire [2:0] _GEN_52 = count == 8'h0 ? 3'h4 : state; // @[FC.scala 495:28 FC.scala 496:39 FC.scala 424:39]
  wire [7:0] _GEN_53 = count == 8'h0 ? count : _count_in_T_1; // @[FC.scala 495:28 FC.scala 425:39 FC.scala 498:39]
  wire [7:0] _count_in_T_5 = _T_54 ? 8'h0 : _count_in_T_1; // @[FC.scala 504:45]
  wire  _T_57 = send_ack_req & _T_54; // @[FC.scala 514:33]
  wire [7:0] _GEN_61 = send_ack_req & _T_54 ? last_good_pkt_from_rx_in : last_ack_pkt_sent; // @[FC.scala 514:50 FC.scala 515:39 FC.scala 436:39]
  wire [7:0] _GEN_70 = send_nack_req ? last_good_pkt_from_rx_in : _GEN_61; // @[FC.scala 505:28 FC.scala 506:39]
  wire [7:0] _GEN_104 = auto_tx_out_advance ? _GEN_70 : last_ack_pkt_sent; // @[FC.scala 537:28 FC.scala 436:39]
  wire [7:0] _GEN_122 = send_nack_req ? last_good_pkt_from_rx_in : last_ack_pkt_sent; // @[FC.scala 586:30 FC.scala 587:39 FC.scala 436:39]
  wire [7:0] _GEN_131 = auto_tx_out_advance ? _GEN_122 : last_ack_pkt_sent; // @[FC.scala 582:28 FC.scala 436:39]
  wire [7:0] _GEN_140 = state == 3'h6 ? _GEN_131 : last_ack_pkt_sent; // @[FC.scala 578:57 FC.scala 436:39]
  wire [7:0] _GEN_152 = state == 3'h7 ? last_ack_pkt_sent : _GEN_140; // @[FC.scala 571:58 FC.scala 436:39]
  wire [7:0] _GEN_160 = state == 3'h5 ? _GEN_104 : _GEN_152; // @[FC.scala 534:58]
  wire [7:0] _GEN_171 = state == 3'h4 ? _GEN_70 : _GEN_160; // @[FC.scala 501:58]
  wire [7:0] _GEN_183 = state == 3'h3 ? last_ack_pkt_sent : _GEN_171; // @[FC.scala 491:61 FC.scala 436:39]
  wire [7:0] _GEN_198 = state == 3'h2 ? last_ack_pkt_sent : _GEN_183; // @[FC.scala 473:62 FC.scala 436:39]
  wire [7:0] _GEN_209 = state == 3'h1 ? last_ack_pkt_sent : _GEN_198; // @[FC.scala 457:62 FC.scala 436:39]
  wire [7:0] word_count_in_lo = _ack_seen_before_T ? 8'h0 : _GEN_209; // @[FC.scala 444:47 FC.scala 446:39]
  wire [12:0] _word_count_in_T_4 = {l2a_fifo_raddr_txclk,word_count_in_lo}; // @[Cat.scala 30:58]
  wire  _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full; // @[FC.scala 523:45]
  wire [7:0] link_data_in_lo = {{3'd0}, a2l_fc_replay_link_cur_addr}; // @[FC.scala 350:45 FC.scala 351:39]
  wire [55:0] _link_data_in_T = {a2l_fc_replay_link_data,link_data_in_lo}; // @[Cat.scala 30:58]
  wire  _GEN_55 = a2l_fc_replay_link_valid & ~fe_rx_is_full | sop; // @[FC.scala 523:63 FC.scala 525:39 FC.scala 427:39]
  wire [7:0] _GEN_56 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? swi_data_id_1 : data_id; // @[FC.scala 523:63 FC.scala 526:39 FC.scala 428:39]
  wire [15:0] _GEN_57 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 16'h7 : word_count; // @[FC.scala 523:63 FC.scala 527:39 FC.scala 429:39]
  wire [55:0] _GEN_58 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? _link_data_in_T : link_data; // @[FC.scala 523:63 FC.scala 528:39 FC.scala 430:39]
  wire [7:0] _GEN_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? ne_rx_ptr_next : ne_rx_ptr; // @[FC.scala 523:63 FC.scala 530:39 FC.scala 434:39]
  wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state; // @[FC.scala 523:63 FC.scala 531:39 FC.scala 424:39]
  wire  _GEN_62 = send_ack_req & _T_54 ? 1'h0 : send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update); // @[FC.scala 514:50 FC.scala 516:39 FC.scala 438:39]
  wire  _GEN_63 = send_ack_req & _T_54 | _GEN_55; // @[FC.scala 514:50 FC.scala 517:39]
  wire [7:0] _GEN_64 = send_ack_req & _T_54 ? out_prepend_swi_ack_id : _GEN_56; // @[FC.scala 514:50 FC.scala 518:39]
  wire [15:0] _GEN_65 = send_ack_req & _T_54 ? {{3'd0}, _word_count_in_T_4} : _GEN_57; // @[FC.scala 514:50 FC.scala 519:39]
  wire [55:0] _GEN_66 = send_ack_req & _T_54 ? 56'h0 : _GEN_58; // @[FC.scala 514:50 FC.scala 520:39]
  wire [2:0] _GEN_67 = send_ack_req & _T_54 ? 3'h6 : _GEN_60; // @[FC.scala 514:50 FC.scala 521:39]
  wire  _GEN_68 = send_ack_req & _T_54 ? 1'h0 : _T_59; // @[FC.scala 514:50 FC.scala 441:39]
  wire [7:0] _GEN_69 = send_ack_req & _T_54 ? ne_rx_ptr : _GEN_59; // @[FC.scala 514:50 FC.scala 434:39]
  wire  _GEN_71 = send_nack_req ? 1'h0 : send_nack_req | (crcCorruptSeen | isNotExpPacket); // @[FC.scala 505:28 FC.scala 507:39 FC.scala 439:39]
  wire  _GEN_72 = send_nack_req | _GEN_63; // @[FC.scala 505:28 FC.scala 508:39]
  wire [7:0] _GEN_73 = send_nack_req ? out_prepend_swi_nack_id : _GEN_64; // @[FC.scala 505:28 FC.scala 509:39]
  wire [15:0] _GEN_74 = send_nack_req ? {{3'd0}, _word_count_in_T_4} : _GEN_65; // @[FC.scala 505:28 FC.scala 510:39]
  wire [55:0] _GEN_75 = send_nack_req ? 56'h0 : _GEN_66; // @[FC.scala 505:28 FC.scala 511:39]
  wire [2:0] _GEN_76 = send_nack_req ? 3'h7 : _GEN_67; // @[FC.scala 505:28 FC.scala 512:39]
  wire  _GEN_77 = send_nack_req ? send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update) : _GEN_62; // @[FC.scala 505:28 FC.scala 438:39]
  wire  _GEN_78 = send_nack_req ? 1'h0 : _GEN_68; // @[FC.scala 505:28 FC.scala 441:39]
  wire [7:0] _GEN_79 = send_nack_req ? ne_rx_ptr : _GEN_69; // @[FC.scala 505:28 FC.scala 434:39]
  wire [2:0] _GEN_85 = _T_59 ? 3'h5 : 3'h4; // @[FC.scala 555:65 FC.scala 563:39 FC.scala 566:39]
  wire  _GEN_88 = _T_57 | _T_59; // @[FC.scala 546:52 FC.scala 549:39]
  wire [2:0] _GEN_92 = _T_57 ? 3'h6 : _GEN_85; // @[FC.scala 546:52 FC.scala 553:39]
  wire  _GEN_96 = send_nack_req | _GEN_88; // @[FC.scala 538:30 FC.scala 541:39]
  wire [2:0] _GEN_100 = send_nack_req ? 3'h7 : _GEN_92; // @[FC.scala 538:30 FC.scala 545:39]
  wire  _GEN_105 = auto_tx_out_advance ? _GEN_71 : send_nack_req | (crcCorruptSeen | isNotExpPacket); // @[FC.scala 537:28 FC.scala 439:39]
  wire  _GEN_106 = auto_tx_out_advance ? _GEN_96 : sop; // @[FC.scala 537:28 FC.scala 427:39]
  wire [7:0] _GEN_107 = auto_tx_out_advance ? _GEN_73 : data_id; // @[FC.scala 537:28 FC.scala 428:39]
  wire [15:0] _GEN_108 = auto_tx_out_advance ? _GEN_74 : word_count; // @[FC.scala 537:28 FC.scala 429:39]
  wire [55:0] _GEN_109 = auto_tx_out_advance ? _GEN_75 : link_data; // @[FC.scala 537:28 FC.scala 430:39]
  wire [2:0] _GEN_110 = auto_tx_out_advance ? _GEN_100 : state; // @[FC.scala 537:28 FC.scala 424:39]
  wire  _GEN_111 = auto_tx_out_advance ? _GEN_77 : send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update); // @[FC.scala 537:28 FC.scala 438:39]
  wire  _GEN_112 = auto_tx_out_advance & _GEN_78; // @[FC.scala 537:28 FC.scala 441:39]
  wire [7:0] _GEN_113 = auto_tx_out_advance ? _GEN_79 : ne_rx_ptr; // @[FC.scala 537:28 FC.scala 434:39]
  wire  _GEN_114 = auto_tx_out_advance ? 1'h0 : sop; // @[FC.scala 573:28 FC.scala 574:39 FC.scala 427:39]
  wire [2:0] _GEN_115 = auto_tx_out_advance ? 3'h4 : state; // @[FC.scala 573:28 FC.scala 575:39 FC.scala 424:39]
  wire  _GEN_123 = send_nack_req | _T_59; // @[FC.scala 586:30 FC.scala 589:39]
  wire [7:0] _GEN_124 = send_nack_req ? out_prepend_swi_nack_id : _GEN_56; // @[FC.scala 586:30 FC.scala 590:39]
  wire [15:0] _GEN_125 = send_nack_req ? {{3'd0}, _word_count_in_T_4} : _GEN_57; // @[FC.scala 586:30 FC.scala 591:39]
  wire [55:0] _GEN_126 = send_nack_req ? 56'h0 : _GEN_58; // @[FC.scala 586:30 FC.scala 592:39]
  wire [2:0] _GEN_127 = send_nack_req ? 3'h7 : _GEN_85; // @[FC.scala 586:30 FC.scala 593:39]
  wire  _GEN_128 = send_nack_req ? 1'h0 : _T_59; // @[FC.scala 586:30 FC.scala 441:39]
  wire [7:0] _GEN_129 = send_nack_req ? ne_rx_ptr : _GEN_59; // @[FC.scala 586:30 FC.scala 434:39]
  reg [7:0] out_prepend_swi_ack_dly_count; // @[SW.scala 83:22]
  wire [7:0] _GEN_130 = auto_tx_out_advance ? out_prepend_swi_ack_dly_count : count; // @[FC.scala 582:28 FC.scala 584:39 FC.scala 425:39]
  wire  _GEN_132 = auto_tx_out_advance ? _GEN_123 : sop; // @[FC.scala 582:28 FC.scala 427:39]
  wire [7:0] _GEN_133 = auto_tx_out_advance ? _GEN_124 : data_id; // @[FC.scala 582:28 FC.scala 428:39]
  wire [15:0] _GEN_134 = auto_tx_out_advance ? _GEN_125 : word_count; // @[FC.scala 582:28 FC.scala 429:39]
  wire [55:0] _GEN_135 = auto_tx_out_advance ? _GEN_126 : link_data; // @[FC.scala 582:28 FC.scala 430:39]
  wire [2:0] _GEN_136 = auto_tx_out_advance ? _GEN_127 : state; // @[FC.scala 582:28 FC.scala 424:39]
  wire  _GEN_137 = auto_tx_out_advance & _GEN_128; // @[FC.scala 582:28 FC.scala 441:39]
  wire [7:0] _GEN_138 = auto_tx_out_advance ? _GEN_129 : ne_rx_ptr; // @[FC.scala 582:28 FC.scala 434:39]
  wire [7:0] _GEN_139 = state == 3'h6 ? _GEN_130 : count; // @[FC.scala 578:57 FC.scala 425:39]
  wire  _GEN_141 = state == 3'h6 ? _GEN_105 : send_nack_req | (crcCorruptSeen | isNotExpPacket); // @[FC.scala 578:57 FC.scala 439:39]
  wire  _GEN_142 = state == 3'h6 ? _GEN_132 : sop; // @[FC.scala 578:57 FC.scala 427:39]
  wire [7:0] _GEN_143 = state == 3'h6 ? _GEN_133 : data_id; // @[FC.scala 578:57 FC.scala 428:39]
  wire [15:0] _GEN_144 = state == 3'h6 ? _GEN_134 : word_count; // @[FC.scala 578:57 FC.scala 429:39]
  wire [55:0] _GEN_145 = state == 3'h6 ? _GEN_135 : link_data; // @[FC.scala 578:57 FC.scala 430:39]
  wire [2:0] _GEN_146 = state == 3'h6 ? _GEN_136 : 3'h0; // @[FC.scala 578:57 FC.scala 612:37]
  wire  _GEN_147 = state == 3'h6 & _GEN_137; // @[FC.scala 578:57 FC.scala 441:39]
  wire [7:0] _GEN_148 = state == 3'h6 ? _GEN_138 : ne_rx_ptr; // @[FC.scala 578:57 FC.scala 434:39]
  wire  _GEN_149 = state == 3'h7 ? _GEN_114 : _GEN_142; // @[FC.scala 571:58]
  wire [2:0] _GEN_150 = state == 3'h7 ? _GEN_115 : _GEN_146; // @[FC.scala 571:58]
  wire [7:0] _GEN_151 = state == 3'h7 ? count : _GEN_139; // @[FC.scala 571:58 FC.scala 425:39]
  wire  _GEN_153 = state == 3'h7 ? send_nack_req | (crcCorruptSeen | isNotExpPacket) : _GEN_141; // @[FC.scala 571:58 FC.scala 439:39]
  wire [7:0] _GEN_154 = state == 3'h7 ? data_id : _GEN_143; // @[FC.scala 571:58 FC.scala 428:39]
  wire [15:0] _GEN_155 = state == 3'h7 ? word_count : _GEN_144; // @[FC.scala 571:58 FC.scala 429:39]
  wire [55:0] _GEN_156 = state == 3'h7 ? link_data : _GEN_145; // @[FC.scala 571:58 FC.scala 430:39]
  wire  _GEN_157 = state == 3'h7 ? 1'h0 : _GEN_147; // @[FC.scala 571:58 FC.scala 441:39]
  wire [7:0] _GEN_158 = state == 3'h7 ? ne_rx_ptr : _GEN_148; // @[FC.scala 571:58 FC.scala 434:39]
  wire [7:0] _GEN_159 = state == 3'h5 ? _count_in_T_5 : _GEN_151; // @[FC.scala 534:58 FC.scala 536:39]
  wire  _GEN_161 = state == 3'h5 ? _GEN_105 : _GEN_153; // @[FC.scala 534:58]
  wire  _GEN_162 = state == 3'h5 ? _GEN_106 : _GEN_149; // @[FC.scala 534:58]
  wire [7:0] _GEN_163 = state == 3'h5 ? _GEN_107 : _GEN_154; // @[FC.scala 534:58]
  wire [15:0] _GEN_164 = state == 3'h5 ? _GEN_108 : _GEN_155; // @[FC.scala 534:58]
  wire [55:0] _GEN_165 = state == 3'h5 ? _GEN_109 : _GEN_156; // @[FC.scala 534:58]
  wire [2:0] _GEN_166 = state == 3'h5 ? _GEN_110 : _GEN_150; // @[FC.scala 534:58]
  wire  _GEN_167 = state == 3'h5 ? _GEN_111 : send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update); // @[FC.scala 534:58 FC.scala 438:39]
  wire  _GEN_168 = state == 3'h5 ? _GEN_112 : _GEN_157; // @[FC.scala 534:58]
  wire [7:0] _GEN_169 = state == 3'h5 ? _GEN_113 : _GEN_158; // @[FC.scala 534:58]
  wire [7:0] _GEN_170 = state == 3'h4 ? _count_in_T_5 : _GEN_159; // @[FC.scala 501:58 FC.scala 504:39]
  wire  _GEN_172 = state == 3'h4 ? _GEN_71 : _GEN_161; // @[FC.scala 501:58]
  wire  _GEN_173 = state == 3'h4 ? _GEN_72 : _GEN_162; // @[FC.scala 501:58]
  wire [7:0] _GEN_174 = state == 3'h4 ? _GEN_73 : _GEN_163; // @[FC.scala 501:58]
  wire [15:0] _GEN_175 = state == 3'h4 ? _GEN_74 : _GEN_164; // @[FC.scala 501:58]
  wire [55:0] _GEN_176 = state == 3'h4 ? _GEN_75 : _GEN_165; // @[FC.scala 501:58]
  wire [2:0] _GEN_177 = state == 3'h4 ? _GEN_76 : _GEN_166; // @[FC.scala 501:58]
  wire  _GEN_178 = state == 3'h4 ? _GEN_77 : _GEN_167; // @[FC.scala 501:58]
  wire  _GEN_179 = state == 3'h4 ? _GEN_78 : _GEN_168; // @[FC.scala 501:58]
  wire [7:0] _GEN_180 = state == 3'h4 ? _GEN_79 : _GEN_169; // @[FC.scala 501:58]
  wire [2:0] _GEN_181 = state == 3'h3 ? _GEN_52 : _GEN_177; // @[FC.scala 491:61]
  wire  _GEN_190 = state == 3'h3 ? 1'h0 : _GEN_179; // @[FC.scala 491:61 FC.scala 441:39]
  wire [7:0] _GEN_191 = state == 3'h3 ? ne_rx_ptr : _GEN_180; // @[FC.scala 491:61 FC.scala 434:39]
  wire  _GEN_201 = state == 3'h2 ? 1'h0 : _GEN_190; // @[FC.scala 473:62 FC.scala 441:39]
  wire  _GEN_212 = state == 3'h1 ? 1'h0 : _GEN_201; // @[FC.scala 457:62 FC.scala 441:39]
  reg [2:0] out_prepend_swi_almost_full; // @[SW.scala 83:22]
  reg [2:0] out_prepend_swi_almost_empty; // @[SW.scala 83:22]
  wire [5:0] in_bits_index = auto_in_paddr[7:2]; // @[RegisterNodes.scala 228:18 RegisterNodes.scala 237:19]
  wire [5:0] out_findex = in_bits_index & 6'h30; // @[RegisterNodes.scala 229:24]
  wire  _out_T = out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
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
  wire  out_oindex_hi_hi = in_bits_index[3]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_hi_lo = in_bits_index[2]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_lo_hi = in_bits_index[1]; // @[RegisterNodes.scala 229:24]
  wire  out_oindex_lo_lo = in_bits_index[0]; // @[RegisterNodes.scala 229:24]
  wire [3:0] out_oindex = {out_oindex_hi_hi,out_oindex_hi_lo,out_oindex_lo_hi,out_oindex_lo_lo}; // @[Cat.scala 30:58]
  wire [15:0] _out_frontSel_T = 16'h1 << out_oindex; // @[OneHot.scala 58:35]
  wire  out_frontSel_0 = _out_frontSel_T[0]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_0 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_0 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid = out_wivalid_0 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_1 = &out_frontMask[15:8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_1 = out_wivalid_0 & out_wimask_1; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_2 = &out_frontMask[23:16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_2 = out_wivalid_0 & out_wimask_2; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_3 = &out_frontMask[31:24]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_3 = out_wivalid_0 & out_wimask_3; // @[RegisterNodes.scala 229:24]
  wire [31:0] out_prepend_2 = {out_prepend_swi_nack_id,out_prepend_swi_ack_id,out_prepend_swi_crack_id,swi_cr_id}; // @[Cat.scala 30:58]
  wire  out_frontSel_5 = _out_frontSel_T[5]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_4 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_5 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_4 = out_wivalid_4 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_5 = out_wivalid_4 & out_wimask_1; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_6 = &out_frontMask[16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_6 = out_wivalid_4 & out_wimask_6; // @[RegisterNodes.scala 229:24]
  wire [16:0] out_prepend_4 = {out_prepend_swi_disable_crc,out_prepend_swi_ack_dly_count,swi_link_en_wait}; // @[Cat.scala 30:58]
  wire  out_frontSel_1 = _out_frontSel_T[1]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_7 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_1 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_7 = out_wivalid_7 & out_wimask; // @[RegisterNodes.scala 229:24]
  wire  readval = a2l_fc_replay_link_empty; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_frontSel_4 = _out_frontSel_T[4]; // @[RegisterNodes.scala 229:24]
  wire  out_wivalid_10 = in_valid & auto_in_penable & ~in_bits_read & out_frontSel_4 & out_findex == 6'h0; // @[RegisterNodes.scala 229:24]
  wire  readval_1 = ack_nack_fifo_io_rempty; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi = ack_nack_fifo_io_wfull; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi_1 = ack_nack_fifo_io_half_full; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi_2 = ack_nack_fifo_io_almost_empty; // @[SW.scala 199:25 SW.scala 200:15]
  wire  out_prepend_hi_3 = ack_nack_fifo_io_almost_full; // @[SW.scala 199:25 SW.scala 200:15]
  wire [5:0] out_prepend_9 = {1'h0,out_prepend_hi_3,out_prepend_hi_2,out_prepend_hi_1,out_prepend_hi,readval_1}; // @[Cat.scala 30:58]
  wire [7:0] out_prepend_lo_10 = {{2'd0}, out_prepend_9}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_16 = &out_frontMask[10:8]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_16 = out_wivalid_10 & out_wimask_16; // @[RegisterNodes.scala 229:24]
  wire [11:0] out_prepend_11 = {1'h0,out_prepend_swi_almost_full,out_prepend_lo_10}; // @[Cat.scala 30:58]
  wire [15:0] out_prepend_lo_12 = {{4'd0}, out_prepend_11}; // @[RegisterNodes.scala 229:24]
  wire  out_wimask_18 = &out_frontMask[18:16]; // @[RegisterNodes.scala 229:24]
  wire  out_f_wivalid_18 = out_wivalid_10 & out_wimask_18; // @[RegisterNodes.scala 229:24]
  wire [18:0] out_prepend_12 = {out_prepend_swi_almost_empty,out_prepend_lo_12}; // @[Cat.scala 30:58]
  wire  _out_out_bits_data_T = 4'h0 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_1 = 4'h1 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_2 = 4'h2 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_3 = 4'h4 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_4 = 4'h5 == out_oindex; // @[Conditional.scala 37:30]
  wire  _out_out_bits_data_T_5 = 4'h8 == out_oindex; // @[Conditional.scala 37:30]
  wire  _GEN_301 = _out_out_bits_data_T_5 ? _out_T : 1'h1; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_302 = _out_out_bits_data_T_4 ? _out_T : _GEN_301; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_303 = _out_out_bits_data_T_3 ? _out_T : _GEN_302; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_304 = _out_out_bits_data_T_2 ? _out_T : _GEN_303; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  _GEN_305 = _out_out_bits_data_T_1 ? _out_T : _GEN_304; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire  out_out_bits_data_out = _out_out_bits_data_T ? _out_T : _GEN_305; // @[Conditional.scala 40:58 MuxLiteral.scala 53:32]
  wire [15:0] _GEN_307 = _out_out_bits_data_T_5 ? crc_errors_in : 16'h0; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [16:0] _GEN_308 = _out_out_bits_data_T_4 ? out_prepend_4 : {{1'd0}, _GEN_307}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [18:0] _GEN_309 = _out_out_bits_data_T_3 ? out_prepend_12 : {{2'd0}, _GEN_308}; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [18:0] _GEN_310 = _out_out_bits_data_T_2 ? {{18'd0}, readval} : _GEN_309; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [18:0] _GEN_311 = _out_out_bits_data_T_1 ? {{11'd0}, swi_data_id_1} : _GEN_310; // @[Conditional.scala 39:67 MuxLiteral.scala 53:32]
  wire [31:0] out_out_bits_data_out_1 = _out_out_bits_data_T ? out_prepend_2 : {{13'd0}, _GEN_311}; // @[Conditional.scala 40:58 MuxLiteral.scala 53:32]
  wire  _T_70 = auto_in_penable & in_valid; // @[Decoupled.scala 40:37]
  wire  _GEN_313 = _T_70 | taken; // @[RegisterNodes.scala 233:23 RegisterNodes.scala 233:31 RegisterNodes.scala 232:24]
  WlinkCrcGen_8 rx_crc_computed_crcgen ( // @[LinkLayer.scala 1274:24]
    .io_in(rx_crc_computed_crcgen_io_in),
    .io_out(rx_crc_computed_crcgen_io_out)
  );
  WavDemetReset en_ff2_rx_demet ( // @[Stdcell.scala 58:23]
    .clock(en_ff2_rx_demet_clock),
    .reset(en_ff2_rx_demet_reset),
    .io_in(en_ff2_rx_demet_io_in),
    .io_out(en_ff2_rx_demet_io_out)
  );
  WlinkGenericFCReplayV2_12 l2a_fc_replay ( // @[FC.scala 219:43]
    .app_clk(l2a_fc_replay_app_clk),
    .app_reset(l2a_fc_replay_app_reset),
    .app_enable(l2a_fc_replay_app_enable),
    .app_data(l2a_fc_replay_app_data),
    .app_valid(l2a_fc_replay_app_valid),
    .app_ready(l2a_fc_replay_app_ready),
    .link_clk(l2a_fc_replay_link_clk),
    .link_reset(l2a_fc_replay_link_reset),
    .link_ack_addr(l2a_fc_replay_link_ack_addr),
    .link_cur_addr(l2a_fc_replay_link_cur_addr),
    .link_data(l2a_fc_replay_link_data),
    .link_valid(l2a_fc_replay_link_valid),
    .link_advance(l2a_fc_replay_link_advance),
    .link_empty(l2a_fc_replay_link_empty)
  );
  WlinkGenericFCReplayAddrSync_18 l2a_fifo_addr_to_tx ( // @[FC.scala 241:43]
    .w_clk(l2a_fifo_addr_to_tx_w_clk),
    .w_reset(l2a_fifo_addr_to_tx_w_reset),
    .w_inc(l2a_fifo_addr_to_tx_w_inc),
    .w_addr(l2a_fifo_addr_to_tx_w_addr),
    .r_clk(l2a_fifo_addr_to_tx_r_clk),
    .r_reset(l2a_fifo_addr_to_tx_r_reset),
    .r_addr(l2a_fifo_addr_to_tx_r_addr)
  );
  WavFIFO_1 ack_nack_fifo ( // @[FC.scala 260:41]
    .io_wclk(ack_nack_fifo_io_wclk),
    .io_wreset(ack_nack_fifo_io_wreset),
    .io_winc(ack_nack_fifo_io_winc),
    .io_rclk(ack_nack_fifo_io_rclk),
    .io_rreset(ack_nack_fifo_io_rreset),
    .io_rinc(ack_nack_fifo_io_rinc),
    .io_wdata(ack_nack_fifo_io_wdata),
    .io_rdata(ack_nack_fifo_io_rdata),
    .io_wfull(ack_nack_fifo_io_wfull),
    .io_rempty(ack_nack_fifo_io_rempty),
    .io_swi_almost_empty(ack_nack_fifo_io_swi_almost_empty),
    .io_swi_almost_full(ack_nack_fifo_io_swi_almost_full),
    .io_half_full(ack_nack_fifo_io_half_full),
    .io_almost_empty(ack_nack_fifo_io_almost_empty),
    .io_almost_full(ack_nack_fifo_io_almost_full)
  );
  WlinkGenericFCReplayV2_13 a2l_fc_replay ( // @[FC.scala 297:43]
    .app_clk(a2l_fc_replay_app_clk),
    .app_reset(a2l_fc_replay_app_reset),
    .app_enable(a2l_fc_replay_app_enable),
    .app_data(a2l_fc_replay_app_data),
    .app_valid(a2l_fc_replay_app_valid),
    .app_ready(a2l_fc_replay_app_ready),
    .link_clk(a2l_fc_replay_link_clk),
    .link_reset(a2l_fc_replay_link_reset),
    .link_ack_update(a2l_fc_replay_link_ack_update),
    .link_ack_addr(a2l_fc_replay_link_ack_addr),
    .link_revert(a2l_fc_replay_link_revert),
    .link_revert_addr(a2l_fc_replay_link_revert_addr),
    .link_cur_addr(a2l_fc_replay_link_cur_addr),
    .link_data(a2l_fc_replay_link_data),
    .link_valid(a2l_fc_replay_link_valid),
    .link_advance(a2l_fc_replay_link_advance),
    .link_empty(a2l_fc_replay_link_empty)
  );
  WavDemetReset en_ff2_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(en_ff2_tx_demet_clock),
    .reset(en_ff2_tx_demet_reset),
    .io_in(en_ff2_tx_demet_io_in),
    .io_out(en_ff2_tx_demet_io_out)
  );
  WavDemetReset cr_pkt_seen_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(cr_pkt_seen_tx_demet_clock),
    .reset(cr_pkt_seen_tx_demet_reset),
    .io_in(cr_pkt_seen_tx_demet_io_in),
    .io_out(cr_pkt_seen_tx_demet_io_out)
  );
  WavDemetReset crack_pkt_seen_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(crack_pkt_seen_tx_demet_clock),
    .reset(crack_pkt_seen_tx_demet_reset),
    .io_in(crack_pkt_seen_tx_demet_io_in),
    .io_out(crack_pkt_seen_tx_demet_io_out)
  );
  WlinkCrcGen_8 bundleOut_0_crc_crcgen ( // @[LinkLayer.scala 1274:24]
    .io_in(bundleOut_0_crc_crcgen_io_in),
    .io_out(bundleOut_0_crc_crcgen_io_out)
  );
  assign auto_in_pready = auto_in_psel & ~taken; // @[RegisterNodes.scala 241:26]
  assign auto_in_prdata = out_out_bits_data_out ? out_out_bits_data_out_1 : 32'h0; // @[RegisterNodes.scala 229:24]
  assign auto_tx_out_sop = sop; // @[Nodes.scala 1207:84 FC.scala 624:25]
  assign auto_tx_out_data_id = data_id; // @[Nodes.scala 1207:84 FC.scala 625:25]
  assign auto_tx_out_word_count = word_count; // @[Nodes.scala 1207:84 FC.scala 626:25]
  assign auto_tx_out_data = link_data; // @[Nodes.scala 1207:84 FC.scala 627:25]
  assign auto_tx_out_crc = bundleOut_0_crc_crcgen_io_out; // @[Nodes.scala 1207:84 FC.scala 630:25]
  assign io_app_a2l_ready = a2l_fc_replay_app_ready; // @[FC.scala 303:35]
  assign io_app_l2a_valid = l2a_fc_replay_link_valid; // @[FC.scala 230:35]
  assign io_app_l2a_data = l2a_fc_replay_link_data; // @[FC.scala 231:35]
  assign io_rx_crc_err = |crc_errors; // @[FC.scala 161:49]
  // SoC Labs credit-path observability taps (FC state machine internals).
  assign io_obs_state             = state;
  assign io_obs_cr_pkt_seen_rx    = cr_pkt_seen_rx;
  assign io_obs_crack_pkt_seen_rx = crack_pkt_seen_rx;
  assign io_obs_pkt_is_cr_pkt     = pkt_is_cr_pkt;
  assign io_obs_pkt_is_crack_pkt  = pkt_is_crack_pkt;
  assign rx_crc_computed_crcgen_io_in = auto_rx_in_data; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign en_ff2_rx_demet_clock = io_rx_clk; // @[FC.scala 191:33]
  assign en_ff2_rx_demet_reset = io_rx_reset; // @[FC.scala 191:54]
  assign en_ff2_rx_demet_io_in = io_app_enable; // @[Stdcell.scala 59:17]
  assign l2a_fc_replay_app_clk = io_rx_clk; // @[FC.scala 220:35]
  assign l2a_fc_replay_app_reset = io_rx_reset; // @[FC.scala 221:35]
  assign l2a_fc_replay_app_enable = io_app_enable; // @[FC.scala 222:35]
  assign l2a_fc_replay_app_data = auto_rx_in_data[55:8]; // @[FC.scala 122:33]
  assign l2a_fc_replay_app_valid = pkt_is_data_pkt & ll_rx_pktnum == exp_pkt_num; // @[FC.scala 210:54]
  assign l2a_fc_replay_link_clk = io_app_clk; // @[FC.scala 227:35]
  assign l2a_fc_replay_link_reset = io_app_reset; // @[FC.scala 228:35]
  assign l2a_fc_replay_link_ack_addr = l2a_fc_replay_link_cur_addr; // @[FC.scala 237:35]
  assign l2a_fc_replay_link_advance = io_app_l2a_accept; // @[FC.scala 232:35]
  assign l2a_fifo_addr_to_tx_w_clk = io_app_clk; // @[FC.scala 242:49]
  assign l2a_fifo_addr_to_tx_w_reset = io_app_reset; // @[FC.scala 243:35]
  assign l2a_fifo_addr_to_tx_w_inc = 1'h1; // @[FC.scala 244:35]
  assign l2a_fifo_addr_to_tx_w_addr = l2a_fc_replay_link_cur_addr; // @[FC.scala 245:35]
  assign l2a_fifo_addr_to_tx_r_clk = io_tx_clk; // @[FC.scala 247:48]
  assign l2a_fifo_addr_to_tx_r_reset = io_tx_reset; // @[FC.scala 248:35]
  assign ack_nack_fifo_io_wclk = io_rx_clk; // @[FC.scala 262:33]
  assign ack_nack_fifo_io_wreset = io_rx_reset; // @[FC.scala 263:33]
  assign ack_nack_fifo_io_winc = pkt_is_ack_pkt | pkt_is_nack_pkt | exp_pkt_seen | exp_pkt_not_seen |
    valid_rx_pkt_crc_err; // @[FC.scala 264:106]
  assign ack_nack_fifo_io_rclk = io_tx_clk; // @[FC.scala 282:33]
  assign ack_nack_fifo_io_rreset = io_tx_reset; // @[FC.scala 283:33]
  assign ack_nack_fifo_io_rinc = ack_nack_fifo_valid & state != 3'h0; // @[FC.scala 284:56]
  assign ack_nack_fifo_io_wdata = _ack_nack_fifo_io_winc_T ? _ack_nack_fifo_io_wdata_T_1 : _ack_nack_fifo_io_wdata_T_2; // @[FC.scala 278:39]
  assign ack_nack_fifo_io_swi_almost_empty = out_prepend_swi_almost_empty; // @[SW.scala 117:16]
  assign ack_nack_fifo_io_swi_almost_full = out_prepend_swi_almost_full; // @[SW.scala 117:16]
  assign a2l_fc_replay_app_clk = io_app_clk; // @[FC.scala 298:35]
  assign a2l_fc_replay_app_reset = io_app_reset; // @[FC.scala 299:35]
  assign a2l_fc_replay_app_enable = io_app_enable; // @[FC.scala 300:35]
  assign a2l_fc_replay_app_data = io_app_a2l_data; // @[FC.scala 301:35]
  assign a2l_fc_replay_app_valid = io_app_a2l_valid; // @[FC.scala 302:35]
  assign a2l_fc_replay_link_clk = io_tx_clk; // @[FC.scala 304:35]
  assign a2l_fc_replay_link_reset = io_tx_reset; // @[FC.scala 305:35]
  assign a2l_fc_replay_link_ack_update = ack_nack_fifo_io_rdata[18:16] == 3'h2 & ack_nack_fifo_valid; // @[FC.scala 289:73]
  assign a2l_fc_replay_link_ack_addr = ack_nack_fifo_io_rdata[4:0]; // @[FC.scala 334:64]
  assign a2l_fc_replay_link_revert = ack_nack_fifo_io_rdata[18:16] == 3'h3 & ack_nack_fifo_valid; // @[FC.scala 290:73]
  assign a2l_fc_replay_link_revert_addr = ~ack_seen_before ? 5'h0 : _link_revert_addr_T_6; // @[FC.scala 347:45]
  assign a2l_fc_replay_link_advance = _ack_seen_before_T ? 1'h0 : _GEN_212; // @[FC.scala 444:47 FC.scala 441:39]
  assign en_ff2_tx_demet_clock = io_tx_clk; // @[FC.scala 314:33]
  assign en_ff2_tx_demet_reset = io_tx_reset; // @[FC.scala 314:54]
  assign en_ff2_tx_demet_io_in = io_app_enable; // @[Stdcell.scala 59:17]
  assign cr_pkt_seen_tx_demet_clock = io_tx_clk; // @[FC.scala 314:33]
  assign cr_pkt_seen_tx_demet_reset = io_tx_reset; // @[FC.scala 314:54]
  assign cr_pkt_seen_tx_demet_io_in = cr_pkt_seen_rx; // @[Stdcell.scala 59:17]
  assign crack_pkt_seen_tx_demet_clock = io_tx_clk; // @[FC.scala 314:33]
  assign crack_pkt_seen_tx_demet_reset = io_tx_reset; // @[FC.scala 314:54]
  assign crack_pkt_seen_tx_demet_io_in = crack_pkt_seen_rx; // @[Stdcell.scala 59:17]
  assign bundleOut_0_crc_crcgen_io_in = link_data; // @[Nodes.scala 1207:84 FC.scala 627:25]
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      state <= 3'h0;
    end else if (_fe_rx_ptr_in_T) begin
      state <= 3'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        state <= 3'h1;
      end
    end else if (state == 3'h1) begin
      if (auto_tx_out_advance) begin
        state <= _GEN_34;
      end
    end else if (state == 3'h2) begin
      state <= _GEN_51;
    end else begin
      state <= _GEN_181;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_data_id_1 <= 8'ha1;
    end else if (out_f_wivalid_7) begin
      swi_data_id_1 <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_disable_crc <= 1'h0;
    end else if (out_f_wivalid_6) begin
      out_prepend_swi_disable_crc <= auto_in_pwdata[16];
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      crc_errors <= 16'h0;
    end else if (en_ff2_rx_demet_io_out) begin
      if (crc_corrupt) begin
        if (!(crc_errors == 16'hffff)) begin
          crc_errors <= _crc_errors_in_T_2;
        end
      end
    end else begin
      crc_errors <= 16'h0;
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_cr_id <= 8'h44;
    end else if (out_f_wivalid) begin
      swi_cr_id <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_crack_id <= 8'h45;
    end else if (out_f_wivalid_1) begin
      out_prepend_swi_crack_id <= auto_in_pwdata[15:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_ack_id <= 8'h46;
    end else if (out_f_wivalid_2) begin
      out_prepend_swi_ack_id <= auto_in_pwdata[23:16];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_nack_id <= 8'h47;
    end else if (out_f_wivalid_3) begin
      out_prepend_swi_nack_id <= auto_in_pwdata[31:24];
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      last_good_pkt <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      last_good_pkt <= 8'h0;
    end else if (exp_pkt_seen) begin
      last_good_pkt <= exp_pkt_num;
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      fe_rx_credit_max <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      fe_rx_credit_max <= 8'h0;
    end else if (_fe_tx_credit_max_in_T_1) begin
      fe_rx_credit_max <= auto_rx_in_word_count[15:8];
    end
  end
  // SoC Labs (FPGA bring-up fix, 2026-05-08): make cr_pkt_seen_rx and
  // crack_pkt_seen_rx fully sticky once set. On FPGA the proc_sys_reset
  // re-pulses io_rx_reset until clk_wiz locks; the original code would
  // clear the latched bit, leaving the master never seeing the slave's
  // crack and the FCSM wedging at state=1. The synchronous clear via
  // `_fe_tx_credit_max_in_T = ~en_ff2_rx_demet_io_out` is also dropped
  // because the swi_enable-rx synchronizer can dip low transiently during
  // the same reset window. These latches are pure "have I ever seen a
  // cr/crack pkt?" markers used only to advance state 1 -> 2; channel
  // disable/re-enable is normally handled by full POR (`reset` here),
  // which still asynchronously re-zeroes them. Normal sim bring-up is
  // unaffected because in steady state these signals don't toggle.
  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      cr_pkt_seen_rx <= 1'h0;
    end else begin
      cr_pkt_seen_rx <= pkt_is_cr_pkt | cr_pkt_seen_rx;
    end
  end
  always @(posedge io_rx_clk or posedge reset) begin
    if (reset) begin
      crack_pkt_seen_rx <= 1'h0;
    end else begin
      crack_pkt_seen_rx <= pkt_is_crack_pkt | crack_pkt_seen_rx;
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      exp_pkt_num <= 8'h0;
    end else if (_fe_tx_credit_max_in_T) begin
      exp_pkt_num <= 8'h0;
    end else if (exp_pkt_seen) begin
      if (exp_pkt_num == fe_tx_credit_max) begin
        exp_pkt_num <= 8'h0;
      end else begin
        exp_pkt_num <= _exp_pkt_num_in_T_3;
      end
    end
  end
  always @(posedge io_rx_clk or posedge io_rx_reset) begin
    if (io_rx_reset) begin
      fe_tx_credit_max <= 8'h0;
    end else if (~en_ff2_rx_demet_io_out) begin
      fe_tx_credit_max <= 8'h0;
    end else if (pkt_is_cr_pkt | pkt_is_crack_pkt) begin
      fe_tx_credit_max <= auto_rx_in_word_count[7:0];
    end
  end
  // SoC Labs L6 producer-side fix: CR-emit counter.  Increments on every
  // (auto_tx_out_advance & sop) cycle while state==1, saturates at 0xFF.
  // Reset to 0 on tx_reset OR whenever FCSM is not in state 1 (so a return to
  // state 0 / a fresh enable pulse re-arms the gate).
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      socl_l6_cr_emit_count <= 8'h0;
    end else if (state != 3'h1) begin
      socl_l6_cr_emit_count <= 8'h0;
    end else if (auto_tx_out_advance & sop) begin
      if (socl_l6_cr_emit_count != 8'hff)
        socl_l6_cr_emit_count <= socl_l6_cr_emit_count + 8'h1;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      sop <= 1'h0;
    end else if (_ack_seen_before_T) begin
      sop <= _GEN_25;
    end else if (state == 3'h1) begin
      sop <= _GEN_35;
    end else if (state == 3'h2) begin
      if (auto_tx_out_advance) begin
        sop <= _GEN_40;
      end
    end else if (!(state == 3'h3)) begin
      sop <= _GEN_173;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      data_id <= 8'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        data_id <= swi_cr_id;
      end
    end else if (state == 3'h1) begin
      if (auto_tx_out_advance) begin
        // SoC Labs L6: keep emitting CR while the L6 min-emit gate is
        // un-met, even if cr_seen/crack_seen have already latched on the
        // synchronizer.  Once the gate is met the original Chisel mux
        // applies (transition to CRACK on cr/crack seen, else CR).
        if ((crack_pkt_seen_tx_demet_io_out | cr_pkt_seen_tx_demet_io_out)
            & socl_l6_cr_emit_gate_ok) begin
          data_id <= out_prepend_swi_crack_id;
        end else begin
          data_id <= swi_cr_id;
        end
      end
    end else if (state == 3'h2) begin
      if (auto_tx_out_advance) begin
        data_id <= _GEN_41;
      end
    end else if (!(state == 3'h3)) begin
      data_id <= _GEN_174;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      word_count <= 16'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        word_count <= 16'h1f1f;
      end
    end else if (state == 3'h1) begin
      if (auto_tx_out_advance) begin
        word_count <= 16'h1f1f;
      end
    end else if (state == 3'h2) begin
      if (auto_tx_out_advance) begin
        word_count <= _GEN_42;
      end
    end else if (!(state == 3'h3)) begin
      word_count <= _GEN_175;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      link_data <= 56'h0;
    end else if (_ack_seen_before_T) begin
      if (en_ff2_tx_demet_io_out) begin
        link_data <= 56'h0;
      end
    end else if (state == 3'h1) begin
      link_data <= _GEN_38;
    end else if (state == 3'h2) begin
      link_data <= _GEN_38;
    end else if (!(state == 3'h3)) begin
      link_data <= _GEN_176;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      count <= 8'h0;
    end else if (!(_ack_seen_before_T)) begin
      if (!(state == 3'h1)) begin
        if (state == 3'h2) begin
          if (auto_tx_out_advance) begin
            count <= _GEN_44;
          end
        end else if (state == 3'h3) begin
          count <= _GEN_53;
        end else begin
          count <= _GEN_170;
        end
      end
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      ack_seen_before <= 1'h0;
    end else if (state == 3'h0) begin
      ack_seen_before <= 1'h0;
    end else begin
      ack_seen_before <= isAckPacket | ack_seen_before;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      fe_rx_ptr <= 8'h0;
    end else if (~en_ff2_tx_demet_io_out) begin
      fe_rx_ptr <= 8'h0;
    end else if (isAckPacket | isNackPacket) begin
      fe_rx_ptr <= ack_nack_fifo_io_rdata[15:8];
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      ne_rx_ptr <= 8'h0;
    end else if (isNackPacket) begin
      ne_rx_ptr <= ack_nack_fifo_io_rdata[15:8];
    end else if (_ack_seen_before_T) begin
      ne_rx_ptr <= 8'h0;
    end else if (!(state == 3'h1)) begin
      if (!(state == 3'h2)) begin
        ne_rx_ptr <= _GEN_191;
      end
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      l2a_fifo_raddr_txclk_prev <= 5'h0;
    end else begin
      l2a_fifo_raddr_txclk_prev <= l2a_fifo_addr_to_tx_r_addr;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      send_ack_req <= 1'h0;
    end else if (_ack_seen_before_T) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else if (state == 3'h1) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else if (state == 3'h2) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else if (state == 3'h3) begin
      send_ack_req <= send_ack_req | (isExpPacket | l2a_fifo_raddr_txclk_update);
    end else begin
      send_ack_req <= _GEN_178;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      send_nack_req <= 1'h0;
    end else if (_ack_seen_before_T) begin
      send_nack_req <= send_nack_req | (crcCorruptSeen | isNotExpPacket);
    end else if (state == 3'h1) begin
      send_nack_req <= send_nack_req | (crcCorruptSeen | isNotExpPacket);
    end else if (state == 3'h2) begin
      send_nack_req <= send_nack_req | (crcCorruptSeen | isNotExpPacket);
    end else if (state == 3'h3) begin
      send_nack_req <= send_nack_req | (crcCorruptSeen | isNotExpPacket);
    end else begin
      send_nack_req <= _GEN_172;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      last_good_pkt_from_rx <= 8'h0;
    end else if (_fe_rx_ptr_in_T) begin
      last_good_pkt_from_rx <= 8'h0;
    end else if (isExpPacket) begin
      last_good_pkt_from_rx <= ack_nack_fifo_io_rdata[7:0];
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      last_ack_pkt_sent <= 8'h0;
    end else if (_ack_seen_before_T) begin
      last_ack_pkt_sent <= 8'h0;
    end else if (!(state == 3'h1)) begin
      if (!(state == 3'h2)) begin
        if (!(state == 3'h3)) begin
          last_ack_pkt_sent <= _GEN_171;
        end
      end
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      swi_link_en_wait <= 8'h8;
    end else if (out_f_wivalid_4) begin
      swi_link_en_wait <= auto_in_pwdata[7:0];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_ack_dly_count <= 8'h7;
    end else if (out_f_wivalid_5) begin
      out_prepend_swi_ack_dly_count <= auto_in_pwdata[15:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_almost_full <= 3'h6;
    end else if (out_f_wivalid_16) begin
      out_prepend_swi_almost_full <= auto_in_pwdata[10:8];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      out_prepend_swi_almost_empty <= 3'h2;
    end else if (out_f_wivalid_18) begin
      out_prepend_swi_almost_empty <= auto_in_pwdata[18:16];
    end
  end
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      taken <= 1'h0;
    end else if (_T_70) begin
      taken <= 1'h0;
    end else begin
      taken <= _GEN_313;
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
  state = _RAND_0[2:0];
  _RAND_1 = {1{`RANDOM}};
  swi_data_id_1 = _RAND_1[7:0];
  _RAND_2 = {1{`RANDOM}};
  out_prepend_swi_disable_crc = _RAND_2[0:0];
  _RAND_3 = {1{`RANDOM}};
  crc_errors = _RAND_3[15:0];
  _RAND_4 = {1{`RANDOM}};
  swi_cr_id = _RAND_4[7:0];
  _RAND_5 = {1{`RANDOM}};
  out_prepend_swi_crack_id = _RAND_5[7:0];
  _RAND_6 = {1{`RANDOM}};
  out_prepend_swi_ack_id = _RAND_6[7:0];
  _RAND_7 = {1{`RANDOM}};
  out_prepend_swi_nack_id = _RAND_7[7:0];
  _RAND_8 = {1{`RANDOM}};
  last_good_pkt = _RAND_8[7:0];
  _RAND_9 = {1{`RANDOM}};
  fe_rx_credit_max = _RAND_9[7:0];
  _RAND_10 = {1{`RANDOM}};
  cr_pkt_seen_rx = _RAND_10[0:0];
  _RAND_11 = {1{`RANDOM}};
  crack_pkt_seen_rx = _RAND_11[0:0];
  _RAND_12 = {1{`RANDOM}};
  exp_pkt_num = _RAND_12[7:0];
  _RAND_13 = {1{`RANDOM}};
  fe_tx_credit_max = _RAND_13[7:0];
  _RAND_14 = {1{`RANDOM}};
  sop = _RAND_14[0:0];
  _RAND_15 = {1{`RANDOM}};
  data_id = _RAND_15[7:0];
  _RAND_16 = {1{`RANDOM}};
  word_count = _RAND_16[15:0];
  _RAND_17 = {2{`RANDOM}};
  link_data = _RAND_17[55:0];
  _RAND_18 = {1{`RANDOM}};
  count = _RAND_18[7:0];
  _RAND_19 = {1{`RANDOM}};
  ack_seen_before = _RAND_19[0:0];
  _RAND_20 = {1{`RANDOM}};
  fe_rx_ptr = _RAND_20[7:0];
  _RAND_21 = {1{`RANDOM}};
  ne_rx_ptr = _RAND_21[7:0];
  _RAND_22 = {1{`RANDOM}};
  l2a_fifo_raddr_txclk_prev = _RAND_22[4:0];
  _RAND_23 = {1{`RANDOM}};
  send_ack_req = _RAND_23[0:0];
  _RAND_24 = {1{`RANDOM}};
  send_nack_req = _RAND_24[0:0];
  _RAND_25 = {1{`RANDOM}};
  last_good_pkt_from_rx = _RAND_25[7:0];
  _RAND_26 = {1{`RANDOM}};
  last_ack_pkt_sent = _RAND_26[7:0];
  _RAND_27 = {1{`RANDOM}};
  swi_link_en_wait = _RAND_27[7:0];
  _RAND_28 = {1{`RANDOM}};
  out_prepend_swi_ack_dly_count = _RAND_28[7:0];
  _RAND_29 = {1{`RANDOM}};
  out_prepend_swi_almost_full = _RAND_29[2:0];
  _RAND_30 = {1{`RANDOM}};
  out_prepend_swi_almost_empty = _RAND_30[2:0];
  _RAND_31 = {1{`RANDOM}};
  taken = _RAND_31[0:0];
`endif // RANDOMIZE_REG_INIT
  if (io_tx_reset) begin
    state = 3'h0;
  end
  if (reset) begin
    swi_data_id_1 = 8'ha1;
  end
  if (reset) begin
    out_prepend_swi_disable_crc = 1'h0;
  end
  if (io_rx_reset) begin
    crc_errors = 16'h0;
  end
  if (reset) begin
    swi_cr_id = 8'h44;
  end
  if (reset) begin
    out_prepend_swi_crack_id = 8'h45;
  end
  if (reset) begin
    out_prepend_swi_ack_id = 8'h46;
  end
  if (reset) begin
    out_prepend_swi_nack_id = 8'h47;
  end
  if (io_rx_reset) begin
    last_good_pkt = 8'h0;
  end
  if (io_rx_reset) begin
    fe_rx_credit_max = 8'h0;
  end
  if (io_rx_reset) begin
    cr_pkt_seen_rx = 1'h0;
  end
  if (io_rx_reset) begin
    crack_pkt_seen_rx = 1'h0;
  end
  if (io_rx_reset) begin
    exp_pkt_num = 8'h0;
  end
  if (io_rx_reset) begin
    fe_tx_credit_max = 8'h0;
  end
  if (io_tx_reset) begin
    sop = 1'h0;
  end
  if (io_tx_reset) begin
    data_id = 8'h0;
  end
  if (io_tx_reset) begin
    word_count = 16'h0;
  end
  if (io_tx_reset) begin
    link_data = 56'h0;
  end
  if (io_tx_reset) begin
    count = 8'h0;
  end
  if (io_tx_reset) begin
    ack_seen_before = 1'h0;
  end
  if (io_tx_reset) begin
    fe_rx_ptr = 8'h0;
  end
  if (io_tx_reset) begin
    ne_rx_ptr = 8'h0;
  end
  if (io_tx_reset) begin
    l2a_fifo_raddr_txclk_prev = 5'h0;
  end
  if (io_tx_reset) begin
    send_ack_req = 1'h0;
  end
  if (io_tx_reset) begin
    send_nack_req = 1'h0;
  end
  if (io_tx_reset) begin
    last_good_pkt_from_rx = 8'h0;
  end
  if (io_tx_reset) begin
    last_ack_pkt_sent = 8'h0;
  end
  if (reset) begin
    swi_link_en_wait = 8'h8;
  end
  if (reset) begin
    out_prepend_swi_ack_dly_count = 8'h7;
  end
  if (reset) begin
    out_prepend_swi_almost_full = 3'h6;
  end
  if (reset) begin
    out_prepend_swi_almost_empty = 3'h2;
  end
  if (reset) begin
    taken = 1'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
