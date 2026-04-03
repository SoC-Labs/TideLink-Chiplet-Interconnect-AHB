///////////////////////////////////////////////////////////////////////////////
// fc_agent.sv
///////////////////////////////////////////////////////////////////////////////
// UVM agent for the FC node interface.
// Active mode: FC RX driver (drives l2a) + FC TX monitor (observes a2l)
// Passive mode: FC TX monitor only
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_FC_AGENT_SV
`define GUARD_FC_AGENT_SV

class fc_agent extends uvm_agent;

  `uvm_component_utils(fc_agent)

  fc_driver     driver;
  fc_monitor    monitor;
  fc_sequencer  sequencer;

  uvm_analysis_port #(fc_seq_item) ap;

  function new(string name = "fc_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    monitor = fc_monitor::type_id::create("monitor", this);
    ap = new("ap", this);

    if (get_is_active() == UVM_ACTIVE) begin
      driver    = fc_driver::type_id::create("driver", this);
      sequencer = fc_sequencer::type_id::create("sequencer", this);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    monitor.ap.connect(ap);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass

`endif // GUARD_FC_AGENT_SV
