///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the TideLink FC Adapter UVM testbench.
// Sets up environment and waits for reset deassertion.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_BASE_TEST_SV
`define GUARD_TIDELINK_FC_ADAPTER_BASE_TEST_SV

class tidelink_fc_adapter_base_test extends uvm_test;

  `uvm_component_utils(tidelink_fc_adapter_base_test)

  tidelink_fc_adapter_env env;

  // Virtual interface for clock/reset access
  virtual tidelink_fc_adapter_if vif;

  function new(string name = "tidelink_fc_adapter_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building FC adapter base test...", UVM_LOW)

    // Get virtual interface
    if (!uvm_config_db#(virtual tidelink_fc_adapter_if)::get(this, "", "dut_vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not set for base test")

    // Create environment
    env = tidelink_fc_adapter_env::type_id::create("env", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    uvm_root root = uvm_root::get();
    `uvm_info("end_of_elaboration_phase", "Printing topology...", UVM_LOW)
    root.print_topology();
  endfunction

  // Wait for reset deassertion before starting main phase
  virtual task reset_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("reset_phase", "Waiting for reset deassertion...", UVM_LOW)
    @(posedge vif.rst_n);
    repeat (5) @(posedge vif.clk);
    `uvm_info("reset_phase", "Reset complete.", UVM_LOW)
    phase.drop_objection(this);
  endtask

  function void final_phase(uvm_phase phase);
    uvm_report_server svr;
    super.final_phase(phase);

    svr = uvm_report_server::get_server();

    if (svr.get_severity_count(UVM_FATAL) +
        svr.get_severity_count(UVM_ERROR) > 0)
      `uvm_info("final_phase", "\n========== TEST FAILED ==========\n", UVM_NONE)
    else
      `uvm_info("final_phase", "\n========== TEST PASSED ==========\n", UVM_NONE)
  endfunction

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_BASE_TEST_SV
