///////////////////////////////////////////////////////////////////////////////
// ptp_stress_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for PTP stress characterisation. Handles Wlink + TideLink + PTP
// initialization, provides helper tasks, timeout watchdog, and final verdict.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_STRESS_BASE_TEST_SV
`define GUARD_PTP_STRESS_BASE_TEST_SV

// Report catcher: demote SVT VIP HRDATA X/Z and zero_wait errors to INFO
class ptp_stress_hrdata_xz_catcher extends uvm_report_catcher;
  `uvm_object_utils(ptp_stress_hrdata_xz_catcher)
  function new(string name = "ptp_stress_hrdata_xz_catcher");
    super.new(name);
  endfunction
  virtual function action_e catch();
    if (get_id() == "register_fail:AMBA:AHB_COMMON:signal_valid_hrdata_check") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    if (get_id() == "register_fail:AMBA:AHB_COMMON:zero_wait_cycle_okay") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class ptp_stress_base_test extends uvm_test;

  `uvm_component_utils(ptp_stress_base_test)

  tidelink_ptp_stress_env env;
  ptp_config              cfg;

  virtual tidelink_ptp_stress_if tb_if;

  ptp_stress_hrdata_xz_catcher hrdata_catcher;

  // Analysis port for timestamp tuples (bridges sequences to scoreboard)
  uvm_analysis_port #(ptp_timestamp_tuple) ts_ap;

  int unsigned test_timeout_cycles = 10_000_000;
  int unsigned wlink_link_up_wait  = 10000;
  int unsigned phy_transit_wait    = 5000;

  function new(string name = "ptp_stress_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(virtual tidelink_ptp_stress_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for PTP stress base test")

    hrdata_catcher = ptp_stress_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    // Create or retrieve ptp_config
    cfg = ptp_config::type_id::create("cfg");
    uvm_config_db#(ptp_config)::set(this, "env", "ptp_cfg", cfg);

    env = tidelink_ptp_stress_env::type_id::create("env", this);

    // Analysis port
    ts_ap = new("ts_ap", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // Connect analysis port to scoreboard and coverage
    ts_ap.connect(env.sb.ts_export);
    ts_ap.connect(env.cov.ts_export);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    uvm_root root = uvm_root::get();
    root.print_topology();
  endfunction

  virtual task reset_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("reset_phase", "Waiting for reset deassertion...", UVM_LOW)
    @(posedge tb_if.rst_n);
    repeat (5) @(posedge tb_if.clk);
    `uvm_info("reset_phase", "Reset complete.", UVM_LOW)
    phase.drop_objection(this);
  endtask

  // -------------------------------------------------------------------
  // Helper: initialize Wlink on both sides
  // -------------------------------------------------------------------
  virtual task init_wlink();
    top_sys_wlink_init_sequence a_wlink_init, b_wlink_init;

    `uvm_info("TEST", "Initializing Wlink on both sides...", UVM_LOW)

    a_wlink_init = top_sys_wlink_init_sequence::type_id::create("a_wlink_init");
    a_wlink_init.side_name = "A";
    a_wlink_init.start(env.a_apb_agt.sequencer);

    b_wlink_init = top_sys_wlink_init_sequence::type_id::create("b_wlink_init");
    b_wlink_init.side_name = "B";
    b_wlink_init.start(env.b_apb_agt.sequencer);

    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "Wlink link-up complete.", UVM_LOW)
  endtask

  // -------------------------------------------------------------------
  // Helper: initialize TideLink on both sides
  // -------------------------------------------------------------------
  virtual task init_tidelink(bit [31:0] a_pair_base = 32'h4000_0000,
                              bit [31:0] b_pair_base = 32'h5000_0000);
    top_sys_init_sequence a_init, b_init;

    `uvm_info("TEST", "Initializing TideLink on both sides...", UVM_LOW)

    a_init = top_sys_init_sequence::type_id::create("a_init");
    a_init.pair_base_addr = a_pair_base;
    a_init.rel_threshold  = 32'd0;
    a_init.side_name = "A";
    a_init.start(env.a_cfg_ahb_sys_env.master[0].sequencer);

    b_init = top_sys_init_sequence::type_id::create("b_init");
    b_init.pair_base_addr = b_pair_base;
    b_init.rel_threshold  = 32'd0;
    b_init.side_name = "B";
    b_init.start(env.b_cfg_ahb_sys_env.master[0].sequencer);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "Both sides TideLink initialized.", UVM_LOW)
  endtask

  // -------------------------------------------------------------------
  // Helper: initialize PTP + PHC on both sides
  // -------------------------------------------------------------------
  virtual task init_ptp();
    ptp_init_sequence a_ptp_init, b_ptp_init;

    `uvm_info("TEST", "Initializing PTP + PHC on both sides...", UVM_LOW)

    a_ptp_init = ptp_init_sequence::type_id::create("a_ptp_init");
    a_ptp_init.side_name   = "A";
    a_ptp_init.phc_ns_incr = cfg.phc_ns_incr;
    a_ptp_init.start(env.a_cfg_ahb_sys_env.master[0].sequencer);

    b_ptp_init = ptp_init_sequence::type_id::create("b_ptp_init");
    b_ptp_init.side_name   = "B";
    b_ptp_init.phc_ns_incr = cfg.phc_ns_incr;
    b_ptp_init.start(env.b_cfg_ahb_sys_env.master[0].sequencer);

    repeat (100) @(posedge tb_if.clk);

    `uvm_info("TEST", "PTP + PHC initialization complete.", UVM_LOW)
  endtask

  // -------------------------------------------------------------------
  // Helper: full system init (Wlink + TideLink + PTP)
  // -------------------------------------------------------------------
  virtual task init_system();
    init_wlink();
    init_tidelink();
    init_ptp();
  endtask

  // -------------------------------------------------------------------
  // Helper: run mixed-load PTP exchanges
  // -------------------------------------------------------------------
  virtual task run_ptp_stress();
    mixed_load_virtual_sequence vseq;

    // Set expected exchange count in scoreboard
    env.sb.expected_exchanges = cfg.num_ptp_exchanges;

    vseq = mixed_load_virtual_sequence::type_id::create("vseq");
    vseq.cfg   = cfg;
    vseq.vseqr = env.vseqr;
    vseq.tb_if = tb_if;
    vseq.ts_ap = ts_ap;
    vseq.cov   = env.cov;
    vseq.start(null);
  endtask

  // -------------------------------------------------------------------
  // Timeout watchdog
  // -------------------------------------------------------------------
  virtual task timeout_watchdog(uvm_phase phase);
    fork
      begin
        repeat (test_timeout_cycles) @(posedge tb_if.clk);
        `uvm_fatal("TIMEOUT", $sformatf(
          "Test timeout after %0d clock cycles", test_timeout_cycles))
      end
    join_none
  endtask

  // -------------------------------------------------------------------
  // Final verdict
  // -------------------------------------------------------------------
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

`endif // GUARD_PTP_STRESS_BASE_TEST_SV
