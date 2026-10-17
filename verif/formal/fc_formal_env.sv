// Formal-only environment assumptions for WlinkGenericFCSM_6 RX cone. Compiled only with
// +define+TL_FC_FORMAL (never in simulation or synthesis flists).
// Each assumption is deliberately weak and listed in docs/FORMAL.md; the sim matrix
// covers what they leave out (assume-guarantee).
`ifdef TL_FC_FORMAL
module fc_formal_env #(parameter int CRC_MODE = 1) (
  input logic       clk, rst,
  input logic       disable_crc,
  input logic       pkt_is_data_pkt,
  input logic [7:0] ll_rx_pktnum,
  input logic [7:0] credit_max_eff
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (rst);
  // ring modulus constrained to the legal credit window [4:31] (5-bit ring)
  m_credit_range: assume property (credit_max_eff >= 8'd4 && credit_max_eff <= 8'd31);
  // a TX that follows the credit ring never sends a packet number beyond it
  m_pktnum_in_ring: assume property (pkt_is_data_pkt |-> ll_rx_pktnum <= credit_max_eff);
  // CRC mode of the receiver (quasi-static APB config, SM_CONTROL bit16)
  if (CRC_MODE == 1) begin : g_on
    m_crc_on: assume property (!disable_crc);
  end else if (CRC_MODE == 2) begin : g_off
    m_crc_off: assume property (disable_crc);
  end
endmodule

bind WlinkGenericFCSM_6 fc_formal_env #(.CRC_MODE(`TL_FC_SVA_CRC_MODE)) u_fc_formal_env (
  .clk(io_rx_clk), .rst(io_rx_reset), .disable_crc(out_prepend_swi_disable_crc),
  .pkt_is_data_pkt(pkt_is_data_pkt), .ll_rx_pktnum(ll_rx_pktnum), .credit_max_eff(fe_tx_credit_max_eff));
`endif
