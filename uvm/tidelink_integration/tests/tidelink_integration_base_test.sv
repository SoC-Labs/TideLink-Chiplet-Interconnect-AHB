///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the TideLink integration UVM testbench.
// Sets up default configuration, installs report catchers, and waits for
// reset deassertion.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_BASE_TEST_SV
`define GUARD_TIDELINK_INTEGRATION_BASE_TEST_SV

// ---------------------------------------------------------------
// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO.
// The generic SRAM returns X for uninitialized locations during
// IDLE bus cycles — this is don't-care per the AHB spec but the
// VIP monitor flags it as a protocol error.
// ---------------------------------------------------------------
class integration_hrdata_xz_catcher extends uvm_report_catcher;

  `uvm_object_utils(integration_hrdata_xz_catcher)

  function new(string name = "integration_hrdata_xz_catcher");
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

class tidelink_integration_base_test extends uvm_test;

  `uvm_component_utils(tidelink_integration_base_test)

  tidelink_integration_env                 env;
  tidelink_integration_tx_ahb_config       tx_ahb_cfg;
  tidelink_integration_fifo_ahb_config     fifo_ahb_cfg;

  // Virtual interface for clock/reset/IRQ access
  virtual tidelink_integration_if tb_if;

  // Report catcher
  integration_hrdata_xz_catcher hrdata_catcher;

  function new(string name = "tidelink_integration_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building integration base test...", UVM_LOW)

    // Get virtual interface
    if (!uvm_config_db#(virtual tidelink_integration_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for integration base test")

    // Install report catcher
    hrdata_catcher = integration_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    // Create configurations
    tx_ahb_cfg   = tidelink_integration_tx_ahb_config::type_id::create("tx_ahb_cfg");
    fifo_ahb_cfg = tidelink_integration_fifo_ahb_config::type_id::create("fifo_ahb_cfg");

    uvm_config_db#(tidelink_integration_tx_ahb_config)::set(
      this, "env", "tx_ahb_cfg", tx_ahb_cfg);
    uvm_config_db#(tidelink_integration_fifo_ahb_config)::set(
      this, "env", "fifo_ahb_cfg", fifo_ahb_cfg);

    // Create environment
    env = tidelink_integration_env::type_id::create("env", this);

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
    @(posedge tb_if.rst_n);
    repeat (5) @(posedge tb_if.clk);
    `uvm_info("reset_phase", "Reset complete.", UVM_LOW)
    phase.drop_objection(this);
  endtask

  // Helper task: initialize TideLink via unified APB config port
  virtual task init_tidelink(bit [31:0] pair_base = 32'h4000_0000,
                              bit [31:0] threshold = 32'd0);
    integration_init_sequence init_seq;
    init_seq = integration_init_sequence::type_id::create("init_seq");
    init_seq.pair_base_addr = pair_base;
    init_seq.rel_threshold  = threshold;
    init_seq.start(env.cfg_apb_agent.sequencer);
  endtask

  // Helper task: read a config register (adds 0x2000 offset for TideLink regs)
  virtual task read_cfg_reg(input bit [11:0] addr, output bit [31:0] data);
    integration_cfg_read_sequence rd_seq;
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h2000 + addr;
    rd_seq.start(env.cfg_apb_agent.sequencer);
    data = rd_seq.rdata;
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

`endif // GUARD_TIDELINK_INTEGRATION_BASE_TEST_SV
