///////////////////////////////////////////////////////////////////////////////
// tidelink_system_vseq.sv
///////////////////////////////////////////////////////////////////////////////
// Virtual sequencer for coordinated multi-port sequences across both
// chiplet sides. Holds handles to all 6 AHB master sequencers.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SYSTEM_VSEQ_SV
`define GUARD_TIDELINK_SYSTEM_VSEQ_SV

class tidelink_system_vseq extends uvm_sequencer;

  `uvm_component_utils(tidelink_system_vseq)

  // Sequencer handles (set during connect_phase in env)
  svt_ahb_master_transaction_sequencer a_tx_sqr;
  svt_ahb_master_transaction_sequencer a_fifo_sqr;
  svt_ahb_master_transaction_sequencer a_cfg_sqr;
  svt_ahb_master_transaction_sequencer b_tx_sqr;
  svt_ahb_master_transaction_sequencer b_fifo_sqr;
  svt_ahb_master_transaction_sequencer b_cfg_sqr;

  function new(string name = "tidelink_system_vseq", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // GUARD_TIDELINK_SYSTEM_VSEQ_SV
