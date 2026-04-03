///////////////////////////////////////////////////////////////////////////////
// fc_sequencer.sv
///////////////////////////////////////////////////////////////////////////////
// UVM sequencer for FC sequence items.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_FC_SEQUENCER_SV
`define GUARD_FC_SEQUENCER_SV

class fc_sequencer extends uvm_sequencer #(fc_seq_item);

  `uvm_component_utils(fc_sequencer)

  function new(string name = "fc_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

`endif // GUARD_FC_SEQUENCER_SV
