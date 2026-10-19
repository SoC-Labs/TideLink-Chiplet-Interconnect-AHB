// Binds fc_crc_contract_sva into every WlinkGenericFCSM* node. Compiled only with
// +define+TL_FC_SVA (see cocotb/tidelink_axi_datanode_recovery/Makefile, TL_FC_SVA=1).
// +define+TL_FC_SVA_STRICT_FIRST disables waiver W1 (first-data-packet CRC error).
// Override the CRC mode of the whole bind set with +define+TL_FC_SVA_CRC_MODE=<0|1|2>.
// Bind is by module name, so it applies to both the deps/ and local_overrides/ copies.
`ifdef TL_FC_SVA
`ifndef TL_FC_SVA_CRC_MODE
 `define TL_FC_SVA_CRC_MODE 0
`endif
`ifdef TL_FC_SVA_STRICT_FIRST
 `define TL_FC_SVA_WAIVE_FIRST 1'b0
`else
 `define TL_FC_SVA_WAIVE_FIRST 1'b1
`endif
`ifndef TL_FC_SVA_NACK_MAX
 `define TL_FC_SVA_NACK_MAX 64
`endif

// SoC Labs sideband node (0xA1): the only one with L9b/L9c.
bind WlinkGenericFCSM_6 fc_crc_contract_sva #(.HAS_L9(1'b1), .WAIVE_FIRST_DATA(`TL_FC_SVA_WAIVE_FIRST), .CRC_MODE(`TL_FC_SVA_CRC_MODE), .NACK_MAX(`TL_FC_SVA_NACK_MAX)) u_fc_crc_sva (
  .clk(io_rx_clk), .rst(io_rx_reset), .app_enable_n(_fe_tx_credit_max_in_T), .first_data_seen(socl_l9_first_data_seen_rx),
  .disable_crc(out_prepend_swi_disable_crc),
  .valid_rx_pkt_crc_err(valid_rx_pkt_crc_err), .pkt_is_data_pkt(pkt_is_data_pkt),
  .ll_rx_pktnum(ll_rx_pktnum), .exp_pkt_num(exp_pkt_num), .exp_pkt_not_seen(exp_pkt_not_seen),
  .send_nack_req(send_nack_req), .commit(l2a_fc_replay_app_valid), .nack_enq(ack_nack_fifo_io_winc),
  .socl_l9b_reanchor_now(socl_l9b_reanchor_now), .socl_l9c_backward(socl_l9c_backward));

`ifndef TL_FC_SVA_FCSM6_ONLY   // formal runs elaborate FCSM_6 alone
`define TL_FC_SVA_BIND_AXI(MOD) \
bind MOD fc_crc_contract_sva #(.HAS_L9(1'b0), .WAIVE_FIRST_DATA(`TL_FC_SVA_WAIVE_FIRST), .CRC_MODE(`TL_FC_SVA_CRC_MODE), .NACK_MAX(`TL_FC_SVA_NACK_MAX)) u_fc_crc_sva ( \
  .clk(io_rx_clk), .rst(io_rx_reset), .app_enable_n(_fe_tx_credit_max_in_T), .first_data_seen(1'b1), \
  .disable_crc(out_prepend_swi_disable_crc), \
  .valid_rx_pkt_crc_err(valid_rx_pkt_crc_err), .pkt_is_data_pkt(pkt_is_data_pkt), \
  .ll_rx_pktnum(ll_rx_pktnum), .exp_pkt_num(exp_pkt_num), .exp_pkt_not_seen(exp_pkt_not_seen), \
  .send_nack_req(send_nack_req), .commit(l2a_fc_replay_app_valid), .nack_enq(ack_nack_fifo_io_winc), \
  .socl_l9b_reanchor_now(1'b0), .socl_l9c_backward(1'b0));

`TL_FC_SVA_BIND_AXI(WlinkGenericFCSM)     // 0x80 AW
`TL_FC_SVA_BIND_AXI(WlinkGenericFCSM_1)   // 0x81 W
`TL_FC_SVA_BIND_AXI(WlinkGenericFCSM_2)   // 0x82 B
`TL_FC_SVA_BIND_AXI(WlinkGenericFCSM_3)   // 0x83 AR
`TL_FC_SVA_BIND_AXI(WlinkGenericFCSM_4)   // 0x84 R
`endif
`endif
