///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_vseq.sv
///////////////////////////////////////////////////////////////////////////////
// Virtual sequencer for coordinated multi-port sequences across all four
// PTP chain sides (a, b1, b2, c). Holds handles to all sequencers
// (AHB + APB per side).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_VSEQ_SV
`define GUARD_TIDELINK_PTP_CHAIN_VSEQ_SV

class tidelink_ptp_chain_vseq extends uvm_sequencer;

  `uvm_component_utils(tidelink_ptp_chain_vseq)

  // Side A sequencer handles
  svt_ahb_master_transaction_sequencer a_sub_sqr;
  svt_ahb_master_transaction_sequencer a_tx_sqr;
  svt_ahb_master_transaction_sequencer a_fifo_sqr;
  svt_ahb_master_transaction_sequencer a_adr_sqr;
  apb_master_sequencer                 a_apb_sqr;

  // Side B1 sequencer handles
  svt_ahb_master_transaction_sequencer b1_sub_sqr;
  svt_ahb_master_transaction_sequencer b1_tx_sqr;
  svt_ahb_master_transaction_sequencer b1_fifo_sqr;
  svt_ahb_master_transaction_sequencer b1_adr_sqr;
  apb_master_sequencer                 b1_apb_sqr;

  // Side B2 sequencer handles
  svt_ahb_master_transaction_sequencer b2_sub_sqr;
  svt_ahb_master_transaction_sequencer b2_tx_sqr;
  svt_ahb_master_transaction_sequencer b2_fifo_sqr;
  svt_ahb_master_transaction_sequencer b2_adr_sqr;
  apb_master_sequencer                 b2_apb_sqr;

  // Side C sequencer handles
  svt_ahb_master_transaction_sequencer c_sub_sqr;
  svt_ahb_master_transaction_sequencer c_tx_sqr;
  svt_ahb_master_transaction_sequencer c_fifo_sqr;
  svt_ahb_master_transaction_sequencer c_adr_sqr;
  apb_master_sequencer                 c_apb_sqr;

  function new(string name = "tidelink_ptp_chain_vseq", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_CHAIN_VSEQ_SV
