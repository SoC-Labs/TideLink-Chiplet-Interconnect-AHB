///////////////////////////////////////////////////////////////////////////////
// ahb_tx_agent.sv
///////////////////////////////////////////////////////////////////////////////
// UVM agent for AHB master writes to the DUT's TX aperture slave port.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_TX_AGENT_SV
`define GUARD_AHB_TX_AGENT_SV

class ahb_tx_agent extends uvm_agent;

  `uvm_component_utils(ahb_tx_agent)

  ahb_tx_driver    driver;
  ahb_tx_sequencer sequencer;

  function new(string name = "ahb_tx_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver    = ahb_tx_driver::type_id::create("driver", this);
      sequencer = ahb_tx_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass

`endif // GUARD_AHB_TX_AGENT_SV
