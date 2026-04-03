///////////////////////////////////////////////////////////////////////////////
// ahb_tx_sequencer.sv
///////////////////////////////////////////////////////////////////////////////
// UVM sequencer for AHB TX write transactions.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_TX_SEQUENCER_SV
`define GUARD_AHB_TX_SEQUENCER_SV

class ahb_tx_sequencer extends uvm_sequencer #(ahb_tx_seq_item);

  `uvm_component_utils(ahb_tx_sequencer)

  function new(string name = "ahb_tx_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // GUARD_AHB_TX_SEQUENCER_SV
