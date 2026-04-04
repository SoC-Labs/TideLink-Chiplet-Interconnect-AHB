///////////////////////////////////////////////////////////////////////////////
// ptp_sync_vseq.sv
///////////////////////////////////////////////////////////////////////////////
// Virtual sequencer for PTP synchronisation testbench.
// Holds handles to all 8 AHB master sequencers (4 per chiplet side)
// plus PTP-side sequencers.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SYNC_VSEQ_SV
`define GUARD_PTP_SYNC_VSEQ_SV

class ptp_sync_vseq extends uvm_sequencer;

  `uvm_component_utils(ptp_sync_vseq)

  // Chiplet A sequencer handles
  svt_ahb_master_transaction_sequencer a_phc_sqr;     // PHC AHB registers (12-bit addr)
  svt_ahb_master_transaction_sequencer a_ptp_sqr;     // PTP AHB slave (4-bit addr)
  svt_ahb_master_transaction_sequencer a_cfg_sqr;     // TideLink config registers

  // Chiplet B sequencer handles
  svt_ahb_master_transaction_sequencer b_phc_sqr;     // PHC AHB registers (12-bit addr)
  svt_ahb_master_transaction_sequencer b_ptp_sqr;     // PTP AHB slave (4-bit addr)
  svt_ahb_master_transaction_sequencer b_cfg_sqr;     // TideLink config registers

  function new(string name = "ptp_sync_vseq", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // GUARD_PTP_SYNC_VSEQ_SV
