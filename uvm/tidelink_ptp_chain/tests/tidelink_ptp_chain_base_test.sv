///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the TideLink PTP chain UVM testbench.
// Handles Wlink + TideLink initialization across all 4 sides (A, B1, B2, C),
// provides helper tasks for APB register access, PTP/servo configuration,
// and timeout watchdog. All concrete chain tests extend this class.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_BASE_TEST_SV
`define GUARD_TIDELINK_PTP_CHAIN_BASE_TEST_SV

// ---------------------------------------------------------------
// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO
// ---------------------------------------------------------------
class ptp_chain_hrdata_xz_catcher extends uvm_report_catcher;
  `uvm_object_utils(ptp_chain_hrdata_xz_catcher)
  function new(string name = "ptp_chain_hrdata_xz_catcher");
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
    if (get_id() == "register_fail:AMBA:AHB_COMMON:hready_out_from_slave_not_X_or_Z_when_data_phase_not_pending") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class tidelink_ptp_chain_base_test extends uvm_test;

  `uvm_component_utils(tidelink_ptp_chain_base_test)

  tidelink_ptp_chain_env env;

  virtual tidelink_ptp_chain_if tb_if;

  ptp_chain_hrdata_xz_catcher hrdata_catcher;

  // APB base offset for TideLink registers (paddr[13]=1)
  localparam [14:0] TIDELINK_APB_BASE = 15'h2000;

  int unsigned test_timeout_cycles = 5_000_000;

  // Wlink link-up wait (PLL lock + SerDes precount + link training)
  int unsigned wlink_link_up_wait = 10000;

  // GPIO PHY serialization wait
  int unsigned phy_transit_wait = 5000;

  function new(string name = "tidelink_ptp_chain_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(virtual tidelink_ptp_chain_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for PTP chain base test")

    hrdata_catcher = ptp_chain_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    env = tidelink_ptp_chain_env::type_id::create("env", this);
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
  // Helper: get APB sequencer for a given side
  // ---------------------------------------------------------------
  virtual function apb_master_sequencer get_apb_sqr(side_t side);
    case (side)
      SIDE_A:  return env.vseqr.a_apb_sqr;
      SIDE_B1: return env.vseqr.b1_apb_sqr;
      SIDE_B2: return env.vseqr.b2_apb_sqr;
      SIDE_C:  return env.vseqr.c_apb_sqr;
    endcase
  endfunction

  // ---------------------------------------------------------------
  // Helper: write an APB register on a given side
  // ---------------------------------------------------------------
  virtual task write_apb_reg(side_t side, bit [14:0] addr, bit [31:0] data);
    integration_cfg_write_sequence wr_seq;
    wr_seq = integration_cfg_write_sequence::type_id::create("wr_seq");
    wr_seq.addr = addr;
    wr_seq.data = data;
    wr_seq.start(get_apb_sqr(side));
  endtask

  // ---------------------------------------------------------------
  // Helper: read an APB register on a given side
  // ---------------------------------------------------------------
  virtual task read_apb_reg(side_t side, bit [14:0] addr, output bit [31:0] data);
    integration_cfg_read_sequence rd_seq;
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = addr;
    rd_seq.start(get_apb_sqr(side));
    data = rd_seq.rdata;
  endtask

  // ---------------------------------------------------------------
  // Helper: initialize Wlink on one side
  // ---------------------------------------------------------------
  virtual task init_wlink(side_t side);
    top_sys_wlink_init_sequence wlink_init;
    string side_str;

    case (side)
      SIDE_A:  side_str = "A";
      SIDE_B1: side_str = "B1";
      SIDE_B2: side_str = "B2";
      SIDE_C:  side_str = "C";
    endcase

    wlink_init = top_sys_wlink_init_sequence::type_id::create($sformatf("%s_wlink_init", side_str));
    wlink_init.side_name = side_str;
    wlink_init.start(get_apb_sqr(side));
  endtask

  // ---------------------------------------------------------------
  // Helper: initialize TideLink on one side via APB
  // ---------------------------------------------------------------
  virtual task init_tidelink(side_t side, bit [31:0] pair_base);
    string side_str;

    case (side)
      SIDE_A:  side_str = "A";
      SIDE_B1: side_str = "B1";
      SIDE_B2: side_str = "B2";
      SIDE_C:  side_str = "C";
    endcase

    `uvm_info("TEST", $sformatf("[%s] Initializing TideLink (pair_base=0x%08h)...",
      side_str, pair_base), UVM_LOW)

    // Write pair base address
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_PAIR_BASE), pair_base);

    // Write release threshold (0 = immediate)
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_REL_THRESHOLD), 32'd0);

    // Enable pair credit counter
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_PAIR_CREDIT_ENABLE), 32'h0000_0001);

    // Ring doorbell to send initial credits
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_DOORBELL), 32'h0000_0001);

    `uvm_info("TEST", $sformatf("[%s] TideLink initialization complete.", side_str), UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: full system init (Wlink on all 4 sides, then TideLink)
  // ---------------------------------------------------------------
  virtual task init_all_links();
    `uvm_info("TEST", "Initializing Wlink on all 4 sides...", UVM_LOW)

    init_wlink(SIDE_A);
    init_wlink(SIDE_B1);
    init_wlink(SIDE_B2);
    init_wlink(SIDE_C);

    // Wait for link training on both PHY crossovers
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "Wlink link-up complete on all sides.", UVM_LOW)

    `uvm_info("TEST", "Initializing TideLink on all 4 sides...", UVM_LOW)

    init_tidelink(SIDE_A,  32'h4000_0000);
    init_tidelink(SIDE_B1, 32'h5000_0000);
    init_tidelink(SIDE_B2, 32'h6000_0000);
    init_tidelink(SIDE_C,  32'h7000_0000);

    // Wait for doorbells to propagate through both Wlink FC paths
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "All 4 sides initialized.", UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: configure servo on a given side
  //   mode: 0=GM, 1=Sub
  // ---------------------------------------------------------------
  virtual task configure_servo(side_t side, bit [1:0] mode,
                                bit [31:0] kp, bit [31:0] ki,
                                bit [31:0] step_thresh);
    string side_str;
    case (side)
      SIDE_A:  side_str = "A";
      SIDE_B1: side_str = "B1";
      SIDE_B2: side_str = "B2";
      SIDE_C:  side_str = "C";
    endcase

    `uvm_info("TEST", $sformatf(
      "[%s] Configuring servo: mode=%0d, kp=0x%08h, ki=0x%08h, step_thresh=%0d",
      side_str, mode, kp, ki, step_thresh), UVM_LOW)

    // SERVO_CTRL: [0]=enable, [1]=mode
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_SERVO_CTRL),
                  {30'h0, mode[0], 1'b1});

    // SERVO_KP
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_SERVO_KP), kp);

    // SERVO_KI
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_SERVO_KI), ki);

    // SERVO_STEP_THRESH
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_SERVO_STEP_THRESH), step_thresh);
  endtask

  // ---------------------------------------------------------------
  // Helper: enable HW sync initiator on a given side
  // ---------------------------------------------------------------
  virtual task enable_hw_sync(side_t side, bit [31:0] interval_ns);
    string side_str;
    case (side)
      SIDE_A:  side_str = "A";
      SIDE_B1: side_str = "B1";
      SIDE_B2: side_str = "B2";
      SIDE_C:  side_str = "C";
    endcase

    `uvm_info("TEST", $sformatf("[%s] Enabling HW sync (interval=%0d ns)...",
      side_str, interval_ns), UVM_LOW)

    // Write HW_SYNC_INTERVAL
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_HW_SYNC_INTERVAL), interval_ns);

    // Write HW_SYNC_CTRL: enable=1
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_HW_SYNC_CTRL), 32'h0000_0001);
  endtask

  // ---------------------------------------------------------------
  // Helper: enable PTP on a given side
  // ---------------------------------------------------------------
  virtual task enable_ptp(side_t side);
    string side_str;
    case (side)
      SIDE_A:  side_str = "A";
      SIDE_B1: side_str = "B1";
      SIDE_B2: side_str = "B2";
      SIDE_C:  side_str = "C";
    endcase

    `uvm_info("TEST", $sformatf("[%s] Enabling PTP...", side_str), UVM_LOW)

    // PTP_CTRL: enable=1, clear=1 (clear any stale RX state)
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_PTP_CTRL), 32'h0000_0003);

    // PTP_CTRL: enable=1, clear=0 (release clear bit)
    write_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_PTP_CTRL), 32'h0000_0001);
  endtask

  // ---------------------------------------------------------------
  // Helper: read SERVO_STATUS register
  // ---------------------------------------------------------------
  virtual task read_servo_status(side_t side, output bit [31:0] status);
    read_apb_reg(side, TIDELINK_APB_BASE + 15'(REG_SERVO_STATUS), status);
  endtask

  // ---------------------------------------------------------------
  // Helper: poll SERVO_STATUS[0] until locked or timeout
  // ---------------------------------------------------------------
  virtual task wait_servo_lock(side_t side, int timeout_cycles = 1_000_000);
    bit [31:0] status;
    int cycles = 0;
    string side_str;

    case (side)
      SIDE_A:  side_str = "A";
      SIDE_B1: side_str = "B1";
      SIDE_B2: side_str = "B2";
      SIDE_C:  side_str = "C";
    endcase

    `uvm_info("TEST", $sformatf("[%s] Waiting for servo lock (timeout=%0d cycles)...",
      side_str, timeout_cycles), UVM_LOW)

    forever begin
      read_servo_status(side, status);
      if (status[0]) begin
        `uvm_info("TEST", $sformatf("[%s] Servo LOCKED (status=0x%08h, cycles=%0d)",
          side_str, status, cycles), UVM_LOW)
        return;
      end
      repeat (100) @(posedge tb_if.clk);
      cycles += 100;
      if (cycles >= timeout_cycles) begin
        `uvm_error("TEST", $sformatf(
          "[%s] Servo lock timeout after %0d cycles (status=0x%08h)",
          side_str, cycles, status))
        return;
      end
    end
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

`endif // GUARD_TIDELINK_PTP_CHAIN_BASE_TEST_SV
