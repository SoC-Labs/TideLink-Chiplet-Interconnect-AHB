///////////////////////////////////////////////////////////////////////////////
// fc_monitor.sv
///////////////////////////////////////////////////////////////////////////////
// UVM monitor for the FC TX (a2l) interface.
// Observes tl_fc_a2l_valid/data/ready and captures completed transfers.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_FC_MONITOR_SV
`define GUARD_FC_MONITOR_SV

class fc_monitor extends uvm_monitor;

  `uvm_component_utils(fc_monitor)

  virtual tidelink_fc_adapter_if vif;

  uvm_analysis_port #(fc_seq_item) ap;

  function new(string name = "fc_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for fc_monitor")
  endfunction

  virtual task run_phase(uvm_phase phase);
    // Wait for reset deassertion
    @(posedge vif.rst_n);

    forever begin
      fc_seq_item item;
      collect_fc_tx(item);
      ap.write(item);
    end
  endtask

  virtual task collect_fc_tx(output fc_seq_item item);
    // Wait for a valid+ready handshake on FC TX (a2l)
    @(posedge vif.clk);
    while (!(vif.tl_fc_a2l_valid && vif.tl_fc_a2l_ready)) begin
      @(posedge vif.clk);
    end

    item = fc_seq_item::type_id::create("fc_tx_item");
    item.unpack_fc_word(vif.tl_fc_a2l_data);

    `uvm_info("FC_MON", $sformatf("Captured FC TX: pkt_type=%s addr=0x%04h data=0x%08h",
      item.pkt_type.name(), item.addr_offset, item.payload), UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_FC_MONITOR_SV
