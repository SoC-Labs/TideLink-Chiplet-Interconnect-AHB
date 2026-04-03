///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_vseq.sv
///////////////////////////////////////////////////////////////////////////////
// Virtual sequencer for coordinated multi-port sequences across both
// chiplet sides. Holds handles to all sequencers (AHB + APB per side).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_VSEQ_SV
`define GUARD_TIDELINK_TOP_SYSTEM_VSEQ_SV

class tidelink_top_system_vseq extends uvm_sequencer;

  `uvm_component_utils(tidelink_top_system_vseq)

  // Chiplet A sequencer handles
  svt_ahb_master_transaction_sequencer a_sub_sqr;
  svt_ahb_master_transaction_sequencer a_tx_sqr;
  svt_ahb_master_transaction_sequencer a_fifo_sqr;
  svt_ahb_master_transaction_sequencer a_cfg_sqr;
  svt_ahb_master_transaction_sequencer a_adr_sqr;
  apb_master_sequencer                 a_apb_sqr;

  // Chiplet B sequencer handles
  svt_ahb_master_transaction_sequencer b_sub_sqr;
  svt_ahb_master_transaction_sequencer b_tx_sqr;
  svt_ahb_master_transaction_sequencer b_fifo_sqr;
  svt_ahb_master_transaction_sequencer b_cfg_sqr;
  svt_ahb_master_transaction_sequencer b_adr_sqr;
  apb_master_sequencer                 b_apb_sqr;

  function new(string name = "tidelink_top_system_vseq", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // GUARD_TIDELINK_TOP_SYSTEM_VSEQ_SV
