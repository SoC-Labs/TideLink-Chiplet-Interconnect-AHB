///////////////////////////////////////////////////////////////////////////////
// ptp_sync_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the PTP synchronisation UVM testbench.
//
// Sets up the environment, installs report catchers, provides helper tasks
// for PHC initialisation, register access, and timeout watchdog. All
// concrete PTP sync tests extend this class.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SYNC_BASE_TEST_SV
`define GUARD_PTP_SYNC_BASE_TEST_SV

// ---------------------------------------------------------------
// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO
// ---------------------------------------------------------------
class ptp_hrdata_xz_catcher extends uvm_report_catcher;
  `uvm_object_utils(ptp_hrdata_xz_catcher)
  function new(string name = "ptp_hrdata_xz_catcher");
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

class ptp_sync_base_test extends uvm_test;

  `uvm_component_utils(ptp_sync_base_test)

  tidelink_ptp_sync_env  env;
  ptp_sync_config        cfg;

  // Virtual interface for clock/reset access
  virtual tidelink_ptp_sync_if tb_if;

  // Report catcher
  ptp_hrdata_xz_catcher hrdata_catcher;

  // Servo model (shared across test phases)
  ptp_servo_model servo;

  // Default timeout (in clock cycles)
  // 1M cycles = 10 ms simulated; bounds wall-time for the placeholder tb
  // (the env was designed around a different DUT topology, tests can't
  // converge against the constant-zero stubs). Override per-test if a
  // real DUT lands.
  int unsigned test_timeout_cycles = 1_000_000;

  function new(string name = "ptp_sync_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building PTP sync base test...", UVM_LOW)

    // Get virtual interface
    if (!uvm_config_db#(virtual tidelink_ptp_sync_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for PTP sync base test")

    // Install report catcher
    hrdata_catcher = ptp_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    // Create configuration
    cfg = ptp_sync_config::type_id::create("cfg");

    // Pass config to environment (scoreboard needs it)
    uvm_config_db#(ptp_sync_config)::set(this, "env.sb", "cfg", cfg);

    // Create environment
    env = tidelink_ptp_sync_env::type_id::create("env", this);

    // Create servo model
    servo = ptp_servo_model::type_id::create("servo");
    servo.configure(cfg);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    uvm_root root = uvm_root::get();
    `uvm_info("end_of_elaboration_phase", "Printing topology...", UVM_LOW)
    root.print_topology();
  endfunction

  // Wait for reset deassertion
  virtual task reset_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("reset_phase", "Waiting for reset deassertion...", UVM_LOW)
    @(posedge tb_if.rst_n);
    repeat (5) @(posedge tb_if.clk);
    `uvm_info("reset_phase", "Reset complete.", UVM_LOW)
    phase.drop_objection(this);
  endtask

  // ---------------------------------------------------------------
  // Helper: initialise both PHCs
  // ---------------------------------------------------------------
  virtual task init_phcs(bit [31:0] ns_incr_a = 32'd4,
                          bit [31:0] ns_incr_frac_a = 32'd0,
                          bit [31:0] ns_incr_b = 32'd4,
                          bit [31:0] ns_incr_frac_b = 32'd0);
    phc_init_sequence a_init, b_init;

    `uvm_info("TEST", "Initialising both PHCs...", UVM_LOW)

    a_init = phc_init_sequence::type_id::create("a_phc_init");
    a_init.ns_incr      = ns_incr_a;
    a_init.ns_incr_frac = ns_incr_frac_a;
    a_init.side_name    = "A";
    a_init.start(env.a_phc_ahb_sys_env.master[0].sequencer);

    b_init = phc_init_sequence::type_id::create("b_phc_init");
    b_init.ns_incr      = ns_incr_b;
    b_init.ns_incr_frac = ns_incr_frac_b;
    b_init.side_name    = "B";
    b_init.start(env.b_phc_ahb_sys_env.master[0].sequencer);

    // Allow clocks to settle
    repeat (20) @(posedge tb_if.clk);

    `uvm_info("TEST", "Both PHCs initialised.", UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: enable PTP on both sides
  // ---------------------------------------------------------------
  virtual task enable_ptp();
    ahb_reg_write_sequence wr_seq;

    `uvm_info("TEST", "Enabling PTP on both sides...", UVM_LOW)

    // Enable PTP on side A
    wr_seq = ahb_reg_write_sequence::type_id::create("en_ptp_a");
    wr_seq.addr = PTP_REG_CTRL;
    wr_seq.data = (32'h1 << PTP_CTRL_ENABLE);
    wr_seq.start(env.a_cfg_ahb_sys_env.master[0].sequencer);

    // Enable PTP on side B
    wr_seq = ahb_reg_write_sequence::type_id::create("en_ptp_b");
    wr_seq.addr = PTP_REG_CTRL;
    wr_seq.data = (32'h1 << PTP_CTRL_ENABLE);
    wr_seq.start(env.b_cfg_ahb_sys_env.master[0].sequencer);

    repeat (10) @(posedge tb_if.clk);

    `uvm_info("TEST", "PTP enabled on both sides.", UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: write a PHC register on a given side
  // ---------------------------------------------------------------
  virtual task write_phc_reg(side_t side, input bit [11:0] addr, input bit [31:0] data);
    ahb_reg_write_sequence wr_seq;
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_phc");
    wr_seq.addr = addr;
    wr_seq.data = data;
    if (side == SIDE_A)
      wr_seq.start(env.a_phc_ahb_sys_env.master[0].sequencer);
    else
      wr_seq.start(env.b_phc_ahb_sys_env.master[0].sequencer);
  endtask

  // ---------------------------------------------------------------
  // Helper: read a PHC register on a given side
  // ---------------------------------------------------------------
  virtual task read_phc_reg(side_t side, input bit [11:0] addr, output bit [31:0] data);
    ahb_reg_read_sequence rd_seq;
    rd_seq = ahb_reg_read_sequence::type_id::create("rd_phc");
    rd_seq.addr = addr;
    if (side == SIDE_A)
      rd_seq.start(env.a_phc_ahb_sys_env.master[0].sequencer);
    else
      rd_seq.start(env.b_phc_ahb_sys_env.master[0].sequencer);
    data = rd_seq.rdata;
  endtask

  // ---------------------------------------------------------------
  // Helper: create and configure a servo sequence
  // ---------------------------------------------------------------
  virtual function ptp_servo_sequence create_servo_seq(string name = "servo_seq");
    ptp_servo_sequence seq;
    seq = ptp_servo_sequence::type_id::create(name);
    seq.cfg       = cfg;
    seq.servo     = servo;
    seq.sb        = env.sb;
    seq.cov       = env.cov;
    seq.a_phc_sqr = env.a_phc_ahb_sys_env.master[0].sequencer;
    seq.a_ptp_sqr = env.a_ptp_ahb_sys_env.master[0].sequencer;
    seq.b_phc_sqr = env.b_phc_ahb_sys_env.master[0].sequencer;
    seq.b_ptp_sqr = env.b_ptp_ahb_sys_env.master[0].sequencer;
    seq.tb_if     = tb_if;
    return seq;
  endfunction

  // ---------------------------------------------------------------
  // Helper: timeout watchdog
  // ---------------------------------------------------------------
  virtual task timeout_watchdog(uvm_phase phase);
    fork
      begin
        repeat (test_timeout_cycles) @(posedge tb_if.clk);
        `uvm_fatal("TIMEOUT", $sformatf(
          "Test timeout after %0d clock cycles", test_timeout_cycles))
      end
    join_none
  endtask

  // ---------------------------------------------------------------
  // Final verdict
  // ---------------------------------------------------------------
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

`endif // GUARD_PTP_SYNC_BASE_TEST_SV
