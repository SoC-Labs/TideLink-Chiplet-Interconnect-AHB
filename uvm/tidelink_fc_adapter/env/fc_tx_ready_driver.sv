///////////////////////////////////////////////////////////////////////////////
// fc_tx_ready_driver.sv
///////////////////////////////////////////////////////////////////////////////
// Drives tl_fc_a2l_ready to control backpressure on the FC TX path.
// Can be configured for always-ready or random backpressure modes.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_FC_TX_READY_DRIVER_SV
`define GUARD_FC_TX_READY_DRIVER_SV

class fc_tx_ready_driver extends uvm_component;

  `uvm_component_utils(fc_tx_ready_driver)

  virtual tidelink_fc_adapter_if vif;

  // Configuration: 0 = always ready, 1 = random backpressure
  bit enable_backpressure = 0;

  function new(string name = "fc_tx_ready_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not found for fc_tx_ready_driver")
    void'(uvm_config_db#(bit)::get(this, "", "enable_backpressure", enable_backpressure));
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.tl_fc_a2l_ready <= 1'b1;

    @(posedge vif.rst_n);

    if (enable_backpressure) begin
      forever begin
        @(posedge vif.clk);
        if ($urandom_range(0, 3) == 0)
          vif.tl_fc_a2l_ready <= 1'b0;
        else
          vif.tl_fc_a2l_ready <= 1'b1;
      end
    end else begin
      // Always ready — nothing more to do
      vif.tl_fc_a2l_ready <= 1'b1;
    end
  endtask

endclass

`endif // GUARD_FC_TX_READY_DRIVER_SV
