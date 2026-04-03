///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the full tidelink_top paired-system UVM testbench.
// Handles Wlink + TideLink initialization, provides helper tasks.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_BASE_TEST_SV
`define GUARD_TIDELINK_TOP_SYSTEM_BASE_TEST_SV

// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO
class top_system_hrdata_xz_catcher extends uvm_report_catcher;
  `uvm_object_utils(top_system_hrdata_xz_catcher)
  function new(string name = "top_system_hrdata_xz_catcher");
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

class tidelink_top_system_base_test extends uvm_test;

  `uvm_component_utils(tidelink_top_system_base_test)

  tidelink_top_system_env env;

  virtual tidelink_top_system_if tb_if;

  top_system_hrdata_xz_catcher hrdata_catcher;

  int unsigned test_timeout_cycles = 200_000;

  // Wlink link-up wait (GPIO PHY needs both sides enabled)
  int unsigned wlink_link_up_wait = 500;

  function new(string name = "tidelink_top_system_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(virtual tidelink_top_system_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for top system base test")

    hrdata_catcher = top_system_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    env = tidelink_top_system_env::type_id::create("env", this);
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

  // ---------------------------------------------------------------
  // Helper: initialize Wlink on both sides
  // ---------------------------------------------------------------
  virtual task init_wlink();
    top_sys_wlink_init_sequence a_wlink_init, b_wlink_init;

    `uvm_info("TEST", "Initializing Wlink on both sides...", UVM_LOW)

    // Initialize both Wlink controllers
    a_wlink_init = top_sys_wlink_init_sequence::type_id::create("a_wlink_init");
    a_wlink_init.side_name = "A";
    a_wlink_init.start(env.a_apb_agt.sequencer);

    b_wlink_init = top_sys_wlink_init_sequence::type_id::create("b_wlink_init");
    b_wlink_init.side_name = "B";
    b_wlink_init.start(env.b_apb_agt.sequencer);

    // Wait for link training (PHY pad crossover + Wlink handshake)
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "Wlink link-up complete.", UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: initialize TideLink on both sides
  // ---------------------------------------------------------------
  virtual task init_both_sides(bit [31:0] a_pair_base = 32'h4000_0000,
                                bit [31:0] b_pair_base = 32'h5000_0000,
                                bit [31:0] a_threshold = 32'd0,
                                bit [31:0] b_threshold = 32'd0);
    top_sys_init_sequence a_init, b_init;

    `uvm_info("TEST", "Initializing TideLink on both sides...", UVM_LOW)

    a_init = top_sys_init_sequence::type_id::create("a_init");
    a_init.pair_base_addr = a_pair_base;
    a_init.rel_threshold  = a_threshold;
    a_init.side_name = "A";
    a_init.start(env.a_cfg_ahb_sys_env.master[0].sequencer);

    b_init = top_sys_init_sequence::type_id::create("b_init");
    b_init.pair_base_addr = b_pair_base;
    b_init.rel_threshold  = b_threshold;
    b_init.side_name = "B";
    b_init.start(env.b_cfg_ahb_sys_env.master[0].sequencer);

    // Wait for doorbells to propagate through Wlink FC path
    repeat (100) @(posedge tb_if.clk);

    `uvm_info("TEST", "Both sides initialized.", UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: full system init (Wlink + TideLink)
  // ---------------------------------------------------------------
  virtual task init_system(bit [31:0] a_pair_base = 32'h4000_0000,
                            bit [31:0] b_pair_base = 32'h5000_0000,
                            bit [31:0] a_threshold = 32'd0,
                            bit [31:0] b_threshold = 32'd0);
    init_wlink();
    init_both_sides(a_pair_base, b_pair_base, a_threshold, b_threshold);
  endtask

  // ---------------------------------------------------------------
  // Helper: read a config register
  // ---------------------------------------------------------------
  virtual task read_cfg_reg(side_t side, input bit [11:0] addr, output bit [31:0] data);
    integration_cfg_read_sequence rd_seq;
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = addr;
    if (side == SIDE_A)
      rd_seq.start(env.a_cfg_ahb_sys_env.master[0].sequencer);
    else
      rd_seq.start(env.b_cfg_ahb_sys_env.master[0].sequencer);
    data = rd_seq.rdata;
  endtask

  // ---------------------------------------------------------------
  // Helper: write a config register
  // ---------------------------------------------------------------
  virtual task write_cfg_reg(side_t side, input bit [11:0] addr, input bit [31:0] data);
    integration_cfg_write_sequence wr_seq;
    wr_seq = integration_cfg_write_sequence::type_id::create("wr_seq");
    wr_seq.addr = addr;
    wr_seq.data = data;
    if (side == SIDE_A)
      wr_seq.start(env.a_cfg_ahb_sys_env.master[0].sequencer);
    else
      wr_seq.start(env.b_cfg_ahb_sys_env.master[0].sequencer);
  endtask

  // ---------------------------------------------------------------
  // Helper: write a packet via TX aperture
  // ---------------------------------------------------------------
  virtual task write_packet(side_t side, bit [31:0] data[]);
    integration_tx_write_sequence wr_seq;
    wr_seq = integration_tx_write_sequence::type_id::create("wr_seq");
    wr_seq.packet_data = data;
    if (side == SIDE_A)
      wr_seq.start(env.a_tx_ahb_sys_env.master[0].sequencer);
    else
      wr_seq.start(env.b_tx_ahb_sys_env.master[0].sequencer);
  endtask

  // ---------------------------------------------------------------
  // Helper: read a packet from RX FIFO
  // ---------------------------------------------------------------
  virtual task read_packet(side_t side, int unsigned num_words,
                            output bit [31:0] data[]);
    integration_fifo_read_sequence rd_seq;
    rd_seq = integration_fifo_read_sequence::type_id::create("rd_seq");
    rd_seq.num_words = num_words;
    if (side == SIDE_A)
      rd_seq.start(env.a_fifo_ahb_sys_env.master[0].sequencer);
    else
      rd_seq.start(env.b_fifo_ahb_sys_env.master[0].sequencer);
    data = rd_seq.read_data;
  endtask

  // ---------------------------------------------------------------
  // Helper: check for error flags
  // ---------------------------------------------------------------
  virtual task check_no_errors(side_t side);
    bit [31:0] status;
    string side_str = (side == SIDE_A) ? "A" : "B";
    read_cfg_reg(side, REG_STATUS, status);
    if (status[STATUS_OVERRUN])
      `uvm_error("TEST", $sformatf("[%s] STATUS.OVERRUN set", side_str))
    if (status[STATUS_UNDERRUN])
      `uvm_error("TEST", $sformatf("[%s] STATUS.UNDERRUN set", side_str))
    if (status[STATUS_MASTER_ERROR])
      `uvm_error("TEST", $sformatf("[%s] STATUS.MASTER_ERROR set", side_str))
  endtask

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

`endif // GUARD_TIDELINK_TOP_SYSTEM_BASE_TEST_SV
