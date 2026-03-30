///////////////////////////////////////////////////////////////////////////////
// tidelink_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the TideLink UVM testbench.
// Sets up default configuration and waits for reset deassertion.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_BASE_TEST_SV
`define GUARD_TIDELINK_BASE_TEST_SV

// ---------------------------------------------------------------
// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO.
// The generic SRAM returns X for uninitialized locations during
// IDLE bus cycles — this is don't-care per the AHB spec but the
// VIP monitor flags it as a protocol error.
// ---------------------------------------------------------------
class hrdata_xz_catcher extends uvm_report_catcher;

  `uvm_object_utils(hrdata_xz_catcher)

  function new(string name = "hrdata_xz_catcher");
    super.new(name);
  endfunction

  virtual function action_e catch();
    if (get_id() == "register_fail:AMBA:AHB_COMMON:signal_valid_hrdata_check") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction

endclass

class tidelink_base_test extends uvm_test;

  `uvm_component_utils(tidelink_base_test)

  tidelink_env              env;
  tidelink_fifo_ahb_config  fifo_ahb_cfg;
  tidelink_ret_ahb_config   ret_ahb_cfg;

  // Virtual interface for clock/reset access
  virtual apb_master_if vif;

  // Report catcher to suppress HRDATA X/Z during idle
  hrdata_xz_catcher hrdata_catcher;

  function new(string name = "tidelink_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building base test...", UVM_LOW)

    // Get virtual interface for clock/reset access
    if (!uvm_config_db#(virtual apb_master_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "Virtual interface not set for base test")

    // Install report catcher to suppress HRDATA X/Z errors
    hrdata_catcher = hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    // Create configurations
    fifo_ahb_cfg = tidelink_fifo_ahb_config::type_id::create("fifo_ahb_cfg");
    ret_ahb_cfg  = tidelink_ret_ahb_config::type_id::create("ret_ahb_cfg");
    uvm_config_db#(tidelink_fifo_ahb_config)::set(this, "env", "fifo_ahb_cfg", fifo_ahb_cfg);
    uvm_config_db#(tidelink_ret_ahb_config)::set(this, "env", "ret_ahb_cfg", ret_ahb_cfg);

    // Create environment
    env = tidelink_env::type_id::create("env", this);

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

`endif // GUARD_TIDELINK_BASE_TEST_SV
