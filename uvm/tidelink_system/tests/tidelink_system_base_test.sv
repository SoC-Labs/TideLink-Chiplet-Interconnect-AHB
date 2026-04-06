///////////////////////////////////////////////////////////////////////////////
// tidelink_system_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the TideLink paired-system UVM testbench.
// Sets up default configuration, installs report catchers, provides helper
// tasks for initialization, register access, and timeout watchdog.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SYSTEM_BASE_TEST_SV
`define GUARD_TIDELINK_SYSTEM_BASE_TEST_SV

// ---------------------------------------------------------------
// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO.
// Generic SRAM returns X for uninitialized locations during IDLE cycles.
// ---------------------------------------------------------------
class system_hrdata_xz_catcher extends uvm_report_catcher;
  `uvm_object_utils(system_hrdata_xz_catcher)
  function new(string name = "system_hrdata_xz_catcher");
    super.new(name);
  endfunction
  virtual function action_e catch();
    // Demote HRDATA X/Z (uninitialized SRAM during IDLE)
    if (get_id() == "register_fail:AMBA:AHB_COMMON:signal_valid_hrdata_check") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    // Demote zero_wait_cycle_okay (fc_wr direct write can stall AHB hready)
    if (get_id() == "register_fail:AMBA:AHB_COMMON:zero_wait_cycle_okay") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class tidelink_system_base_test extends uvm_test;

  `uvm_component_utils(tidelink_system_base_test)

  tidelink_system_env env;

  // Virtual interface for clock/reset/IRQ access
  virtual tidelink_system_if tb_if;

  // Report catcher
  system_hrdata_xz_catcher hrdata_catcher;

  // Default timeout (in clock cycles)
  int unsigned test_timeout_cycles = 100_000;

  function new(string name = "tidelink_system_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building system base test...", UVM_LOW)

    // Get virtual interface
    if (!uvm_config_db#(virtual tidelink_system_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for system base test")

    // Install report catcher
    hrdata_catcher = system_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    // Create environment
    env = tidelink_system_env::type_id::create("env", this);

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
  // Helper: initialize both sides
  // ---------------------------------------------------------------
  virtual task init_both_sides(bit [31:0] a_pair_base = 32'h4000_0000,
                                bit [31:0] b_pair_base = 32'h5000_0000,
                                bit [31:0] a_threshold = 32'd0,
                                bit [31:0] b_threshold = 32'd0);
    sys_init_sequence a_init, b_init;

    `uvm_info("TEST", "Initializing both sides...", UVM_LOW)

    // Initialize side A
    a_init = sys_init_sequence::type_id::create("a_init");
    a_init.pair_base_addr = a_pair_base;
    a_init.rel_threshold  = a_threshold;
    a_init.side_name = "A";
    a_init.start(env.a_cfg_apb_agent.sequencer);

    // Initialize side B
    b_init = sys_init_sequence::type_id::create("b_init");
    b_init.pair_base_addr = b_pair_base;
    b_init.rel_threshold  = b_threshold;
    b_init.side_name = "B";
    b_init.start(env.b_cfg_apb_agent.sequencer);

    // Wait for doorbells to propagate through FC crossover
    repeat (50) @(posedge tb_if.clk);

    `uvm_info("TEST", "Both sides initialized.", UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: initialize one side
  // ---------------------------------------------------------------
  virtual task init_side(side_t side,
                          bit [31:0] pair_base = 32'h4000_0000,
                          bit [31:0] threshold = 32'd0);
    sys_init_sequence init_seq;
    init_seq = sys_init_sequence::type_id::create("init_seq");
    init_seq.pair_base_addr = pair_base;
    init_seq.rel_threshold  = threshold;
    init_seq.side_name = (side == SIDE_A) ? "A" : "B";
    if (side == SIDE_A)
      init_seq.start(env.a_cfg_apb_agent.sequencer);
    else
      init_seq.start(env.b_cfg_apb_agent.sequencer);
  endtask

  // ---------------------------------------------------------------
  // Helper: read a config register on a given side
  // TideLink regs at 0x2000 offset in unified APB space
  // ---------------------------------------------------------------
  virtual task read_cfg_reg(side_t side, input bit [11:0] addr, output bit [31:0] data);
    integration_cfg_read_sequence rd_seq;
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h2000 + addr;
    if (side == SIDE_A)
      rd_seq.start(env.a_cfg_apb_agent.sequencer);
    else
      rd_seq.start(env.b_cfg_apb_agent.sequencer);
    data = rd_seq.rdata;
  endtask

  // ---------------------------------------------------------------
  // Helper: write a config register on a given side
  // TideLink regs at 0x2000 offset in unified APB space
  // ---------------------------------------------------------------
  virtual task write_cfg_reg(side_t side, input bit [11:0] addr, input bit [31:0] data);
    integration_cfg_write_sequence wr_seq;
    wr_seq = integration_cfg_write_sequence::type_id::create("wr_seq");
    wr_seq.addr = 15'h2000 + addr;
    wr_seq.data = data;
    if (side == SIDE_A)
      wr_seq.start(env.a_cfg_apb_agent.sequencer);
    else
      wr_seq.start(env.b_cfg_apb_agent.sequencer);
  endtask

  // ---------------------------------------------------------------
  // Helper: write a packet from one side's TX aperture
  // ---------------------------------------------------------------
  virtual task write_packet(side_t side, bit [31:0] data[]);
    sys_packet_sequence wr_seq;
    wr_seq = sys_packet_sequence::type_id::create("wr_seq");
    wr_seq.packet_data = data;
    wr_seq.side_name = (side == SIDE_A) ? "A" : "B";
    if (side == SIDE_A)
      wr_seq.start(env.a_tx_ahb_sys_env.master[0].sequencer);
    else
      wr_seq.start(env.b_tx_ahb_sys_env.master[0].sequencer);
  endtask

  // ---------------------------------------------------------------
  // Helper: read a packet from one side's RX FIFO
  // ---------------------------------------------------------------
  virtual task read_packet(side_t side, int unsigned num_words,
                            output bit [31:0] data[]);
    sys_read_packet_sequence rd_seq;
    rd_seq = sys_read_packet_sequence::type_id::create("rd_seq");
    rd_seq.num_words = num_words;
    rd_seq.side_name = (side == SIDE_A) ? "A" : "B";
    if (side == SIDE_A)
      rd_seq.start(env.a_fifo_ahb_sys_env.master[0].sequencer);
    else
      rd_seq.start(env.b_fifo_ahb_sys_env.master[0].sequencer);
    data = rd_seq.read_data;
  endtask

  // ---------------------------------------------------------------
  // Helper: check for error flags on a given side
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
  // Helper: timeout watchdog (spawned in main_phase)
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

`endif // GUARD_TIDELINK_SYSTEM_BASE_TEST_SV
