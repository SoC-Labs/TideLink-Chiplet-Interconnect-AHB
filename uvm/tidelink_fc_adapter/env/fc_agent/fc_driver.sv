///////////////////////////////////////////////////////////////////////////////
// fc_driver.sv
///////////////////////////////////////////////////////////////////////////////
// UVM driver for the FC RX (l2a) interface.
// Drives tl_fc_l2a_valid and tl_fc_l2a_data, waits for tl_fc_l2a_accept.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_FC_DRIVER_SV
`define GUARD_FC_DRIVER_SV

class fc_driver extends uvm_driver #(fc_seq_item);

  `uvm_component_utils(fc_driver)

  virtual tidelink_fc_adapter_if vif;

  function new(string name = "fc_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for fc_driver")
  endfunction

  virtual task run_phase(uvm_phase phase);
    // Initialize FC RX bus to idle
    vif.fc_rx_cb.tl_fc_l2a_valid <= 1'b0;
    vif.fc_rx_cb.tl_fc_l2a_data  <= 48'h0;

    // Wait for reset deassertion
    @(posedge vif.rst_n);
    @(posedge vif.clk);

    forever begin
      fc_seq_item item;
      seq_item_port.get_next_item(item);
      drive_fc_rx(item);
      seq_item_port.item_done();
    end
  endtask

  virtual task drive_fc_rx(fc_seq_item item);
    bit [47:0] fc_word;

    // Optional inter-transfer delay
    repeat (item.delay) @(posedge vif.clk);

    fc_word = item.pack_fc_word();

    // Drive valid + data
    @(posedge vif.clk);
    vif.fc_rx_cb.tl_fc_l2a_valid <= 1'b1;
    vif.fc_rx_cb.tl_fc_l2a_data  <= fc_word;

    // Wait for accept
    @(posedge vif.clk);
    while (!vif.fc_rx_cb.tl_fc_l2a_accept) begin
      @(posedge vif.clk);
    end

    // Deassert valid
    vif.fc_rx_cb.tl_fc_l2a_valid <= 1'b0;
    vif.fc_rx_cb.tl_fc_l2a_data  <= 48'h0;

    `uvm_info("FC_DRV", $sformatf("Drove FC RX: pkt_type=%s addr=0x%04h data=0x%08h",
      item.pkt_type.name(), item.addr_offset, item.payload), UVM_HIGH)
  endtask

endclass

`endif // GUARD_FC_DRIVER_SV
