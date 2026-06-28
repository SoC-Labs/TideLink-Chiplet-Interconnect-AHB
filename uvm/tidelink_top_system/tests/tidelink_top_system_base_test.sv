///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_base_test.sv
///////////////////////////////////////////////////////////////////////////////
// Base test for the full tidelink_top paired-system UVM testbench.
// Handles Wlink + TideLink initialization, provides helper tasks.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_BASE_TEST_SV
`define GUARD_TIDELINK_TOP_SYSTEM_BASE_TEST_SV

// Report catcher: demote scoreboard A2B mismatches to UVM_INFO. Used by
// tests that *expect* mismatches (damaged-lane unmasked positive control,
// the mismatch sweep diagnostic). Disabled by default — tests opt in by
// setting expect_a2b_mismatch=1 before main_phase.
class top_system_a2b_expected_catcher extends uvm_report_catcher;
  `uvm_object_utils(top_system_a2b_expected_catcher)
  static bit expect_a2b_mismatch = 1'b0;
  function new(string name = "top_system_a2b_expected_catcher");
    super.new(name);
  endfunction
  virtual function action_e catch();
    if (expect_a2b_mismatch &&
        (get_id() == "SB_A2B" || get_id() == "SB_REPORT")) begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

// Report catcher: demote SVT VIP HRDATA X/Z errors to INFO
class top_system_hrdata_xz_catcher extends uvm_report_catcher;
  `uvm_object_utils(top_system_hrdata_xz_catcher)
  function new(string name = "top_system_hrdata_xz_catcher");
    super.new(name);
  endfunction
  virtual function action_e catch();
    // Demote HRDATA X/Z (uninitialized SRAM during IDLE)
    if (get_id() == "register_fail:AMBA:AHB_COMMON:signal_valid_hrdata_check") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    // Demote zero_wait_cycle_okay (cfg mux stalls VIP when FC adapter has priority)
    if (get_id() == "register_fail:AMBA:AHB_COMMON:zero_wait_cycle_okay") begin
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    // Demote HREADY X/Z checks. AHB slaves (FC adapters) have HREADY
    // undriven during pre-link-up reset and the SVT VIP flags every cycle.
    // With ~5 monitors firing every cycle the unfiltered stream produces
    // multi-GB logs and slows simulation by ~100x — without telling us
    // anything about functional correctness.
    if (get_id() == "register_fail:AMBA:AHB_COMMON:signal_valid_hready_check") begin
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

class tidelink_top_system_base_test extends uvm_test;

  `uvm_component_utils(tidelink_top_system_base_test)

  tidelink_top_system_env env;

  virtual tidelink_top_system_if tb_if;

  top_system_hrdata_xz_catcher hrdata_catcher;
  top_system_a2b_expected_catcher a2b_catcher;

  int unsigned test_timeout_cycles = 2_000_000;

  // Wlink link-up wait (PLL lock ~400 ref_clk cycles + SerDes precount + link training)
  int unsigned wlink_link_up_wait = 10000;

  // GPIO PHY serialization wait: 8-lane GPIO is ~8x faster than 1-lane
  // ~2500 cycles per 5-word packet (vs 20K for 1-lane)
  int unsigned phy_transit_wait = 5000;

  function new(string name = "tidelink_top_system_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(virtual tidelink_top_system_if)::get(this, "", "tb_if", tb_if))
      `uvm_fatal("NOVIF", "Virtual interface not set for top system base test")

    hrdata_catcher = top_system_hrdata_xz_catcher::type_id::create("hrdata_catcher");
    uvm_report_cb::add(null, hrdata_catcher);

    a2b_catcher = top_system_a2b_expected_catcher::type_id::create("a2b_catcher");
    uvm_report_cb::add(null, a2b_catcher);

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
  // Unified-APB raw write/read helpers (absolute 15-bit paddr).
  // Used by the V2 bring-up below for the Wlink (0x0xxx) and Region-8
  // (0x21xx) registers that sit outside the TideLink 0x2000 block.
  // ---------------------------------------------------------------
  virtual task apb_raw_write(side_t side, bit [14:0] addr, bit [31:0] data);
    integration_cfg_write_sequence wr_seq;
    wr_seq = integration_cfg_write_sequence::type_id::create("apb_raw_wr");
    wr_seq.addr = addr;
    wr_seq.data = data;
    if (side == SIDE_A) wr_seq.start(env.a_apb_agt.sequencer);
    else                wr_seq.start(env.b_apb_agt.sequencer);
  endtask

  virtual task apb_raw_read(side_t side, bit [14:0] addr, output bit [31:0] data);
    integration_cfg_read_sequence rd_seq;
    rd_seq = integration_cfg_read_sequence::type_id::create("apb_raw_rd");
    rd_seq.addr = addr;
    if (side == SIDE_A) rd_seq.start(env.a_apb_agt.sequencer);
    else                rd_seq.start(env.b_apb_agt.sequencer);
    data = rd_seq.rdata;
  endtask

  // ---------------------------------------------------------------
  // Helper: initialize Wlink on both sides — V2 phy-integration bring-up.
  //
  // The V2 RTL (autocal calibrator + T3A self-aligning RX + local_overrides
  // Wlink) does NOT reach a data-carrying link from role_lock alone: the
  // recovered-RX framer needs the coordinated training -> calibrate -> data
  // handoff. Mirrors the PROVEN cocotb tidelink_top_pair doorbell bring-up
  // (cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py: do_role_lock /
  // wait_cal_done / do_hold_training / do_to_data_mode) which is the sequence
  // sw_coord_autocal_region8.sh runs on silicon. Without this the FCSM parks
  // at state==1 (cr_seen_rx=0) and the A->B datapath delivers all-zeros — the
  // pre-existing reason every data test in this suite regressed on the V2
  // branch and the AHB passthrough never crossed.
  //
  //   Phase 0  POR + role_lock both sides (ROLE_CFG 0x2080)
  //   Phase 1  passive autocal -> wait cal_done (SWI_LANE_STATUS 0x2108[16])
  //   Phase 1b hold-training refresh: R8 SLOT0 0x2100 = 0x3 -> 0x1
  //   Phase 2  to data mode: R8 SLOT0 = 0x0, then LL bootstrap 0x0208
  //            (0x27f08 swreset-on -> 0x27f00 swreset-off -> 0x27f07 enable)
  // ---------------------------------------------------------------
  localparam bit [14:0] APB_ROLE_CFG       = 15'h2080;
  localparam bit [14:0] APB_R8_SLOT0       = 15'h2100; // SWI_TRAINING_MODE / RECAL
  localparam bit [14:0] APB_R8_LANE_STATUS = 15'h2108; // [16]=cal_done, [7:0]=lane_locked
  localparam bit [14:0] APB_WL_LL_ENABLE   = 15'h0208; // Wlink LL enable/reset

  localparam bit [31:0] ROLE_CFG_MASTER_LOCK = 32'h0000_0002; // role=master, lock
  localparam bit [31:0] ROLE_CFG_SLAVE_LOCK  = 32'h0000_0003; // role=slave,  lock
  localparam bit [31:0] R8_TRAIN_RECAL       = 32'h0000_0003; // training + recal
  localparam bit [31:0] R8_TRAIN_ONLY        = 32'h0000_0001; // training, recal off
  localparam bit [31:0] R8_OFF               = 32'h0000_0000;
  localparam bit [31:0] LL_SWRESET_ON        = 32'h0002_7f08;
  localparam bit [31:0] LL_SWRESET_OFF       = 32'h0002_7f00;
  localparam bit [31:0] LL_ENABLE            = 32'h0002_7f07;

  virtual task init_wlink();
    bit [31:0] a_st, b_st;
    int unsigned polls;
    bit cal_ok;

    `uvm_info("TEST", "Initializing Wlink (V2 bring-up) on both sides...", UVM_LOW)

    // --- Phase 0: role_lock (releases Wlink POR). A=master, B=slave to
    //     match the straps in tb top.sv. ---
    apb_raw_write(SIDE_A, APB_ROLE_CFG, ROLE_CFG_MASTER_LOCK);
    apb_raw_write(SIDE_B, APB_ROLE_CFG, ROLE_CFG_SLAVE_LOCK);
    repeat (200) @(posedge tb_if.clk);

    // --- Phase 1: wait for passive autocal to converge (cal_done on both).
    //     The calibrator HOLD_CYCLES/VALIDATION_TIMEOUT are large, so this
    //     can take well over 100k cycles. Poll SWI_LANE_STATUS[16]. ---
    cal_ok = 1'b0;
    for (polls = 0; polls < 1500; polls++) begin
      repeat (500) @(posedge tb_if.clk);
      apb_raw_read(SIDE_A, APB_R8_LANE_STATUS, a_st);
      apb_raw_read(SIDE_B, APB_R8_LANE_STATUS, b_st);
      if (a_st[16] && b_st[16]) begin
        cal_ok = 1'b1;
        `uvm_info("TEST", $sformatf(
          "Autocal cal_done both sides after ~%0d poll-windows: A=0x%08h B=0x%08h (lane_locked A=0x%02h B=0x%02h)",
          polls, a_st, b_st, a_st[7:0], b_st[7:0]), UVM_LOW)
        break;
      end
    end
    if (!cal_ok)
      `uvm_warning("TEST", $sformatf(
        "Autocal did not report cal_done on both sides (A=0x%08h B=0x%08h); proceeding to data-mode handoff anyway",
        a_st, b_st))

    // --- Phase 1b: hold-training refresh (recal falling edge re-sweeps
    //     against the live peer training pattern). ---
    apb_raw_write(SIDE_A, APB_R8_SLOT0, R8_TRAIN_RECAL);
    apb_raw_write(SIDE_B, APB_R8_SLOT0, R8_TRAIN_RECAL);
    repeat (200) @(posedge tb_if.clk);
    apb_raw_write(SIDE_A, APB_R8_SLOT0, R8_TRAIN_ONLY);
    apb_raw_write(SIDE_B, APB_R8_SLOT0, R8_TRAIN_ONLY);
    repeat (200) @(posedge tb_if.clk);

    // --- Phase 2: to data mode — drop training, run LL swreset bootstrap. ---
    apb_raw_write(SIDE_A, APB_R8_SLOT0, R8_OFF);
    apb_raw_write(SIDE_B, APB_R8_SLOT0, R8_OFF);
    repeat (20) @(posedge tb_if.clk);
    apb_raw_write(SIDE_A, APB_WL_LL_ENABLE, LL_SWRESET_ON);
    apb_raw_write(SIDE_B, APB_WL_LL_ENABLE, LL_SWRESET_ON);
    repeat (20) @(posedge tb_if.clk);
    apb_raw_write(SIDE_A, APB_WL_LL_ENABLE, LL_SWRESET_OFF);
    apb_raw_write(SIDE_B, APB_WL_LL_ENABLE, LL_SWRESET_OFF);
    repeat (20) @(posedge tb_if.clk);
    apb_raw_write(SIDE_A, APB_WL_LL_ENABLE, LL_ENABLE);
    apb_raw_write(SIDE_B, APB_WL_LL_ENABLE, LL_ENABLE);

    // Let the FC credit handshake (CR/CRACK) complete across the now-live link.
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "Wlink link-up complete (V2 bring-up).", UVM_LOW)
  endtask

  // Diagnostic: read Wlink link_status (0x0234) and link_capabilities (0x0200)
  // on both sides and report tx_ready / rx_data_valid / in_error_state.
  // Used to diagnose stalls where the link might not have actually trained.
  virtual task probe_wlink_state();
    bit [31:0] a_status, b_status;
    bit [31:0] a_caps, b_caps;
    bit [31:0] a_phy_gen, b_phy_gen, a_phy_pll, b_phy_pll;
    bit [31:0] a_enr, b_enr, a_pst, b_pst;
    integration_cfg_read_sequence rd_seq;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0200;
    rd_seq.start(env.a_apb_agt.sequencer);
    a_caps = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0234;
    rd_seq.start(env.a_apb_agt.sequencer);
    a_status = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0000;
    rd_seq.start(env.a_apb_agt.sequencer);
    a_phy_gen = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h000C;
    rd_seq.start(env.a_apb_agt.sequencer);
    a_phy_pll = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0208;
    rd_seq.start(env.a_apb_agt.sequencer);
    a_enr = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0044;
    rd_seq.start(env.a_apb_agt.sequencer);
    a_pst = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0200;
    rd_seq.start(env.b_apb_agt.sequencer);
    b_caps = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0234;
    rd_seq.start(env.b_apb_agt.sequencer);
    b_status = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0000;
    rd_seq.start(env.b_apb_agt.sequencer);
    b_phy_gen = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h000C;
    rd_seq.start(env.b_apb_agt.sequencer);
    b_phy_pll = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0208;
    rd_seq.start(env.b_apb_agt.sequencer);
    b_enr = rd_seq.rdata;

    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 15'h0044;
    rd_seq.start(env.b_apb_agt.sequencer);
    b_pst = rd_seq.rdata;

    `uvm_info("PROBE", $sformatf(
      "[A] caps=0x%08h status=0x%08h tx_rdy=%0d rx_dv=%0d in_err=%0d  phy_gen=0x%08h phy_pll=0x%08h  enable_reset=0x%08h  tx_pstate=0x%08h",
      a_caps, a_status, (a_status>>3)&1, (a_status>>4)&1, (a_status>>2)&1,
      a_phy_gen, a_phy_pll, a_enr, a_pst), UVM_LOW)
    `uvm_info("PROBE", $sformatf(
      "[B] caps=0x%08h status=0x%08h tx_rdy=%0d rx_dv=%0d in_err=%0d  phy_gen=0x%08h phy_pll=0x%08h  enable_reset=0x%08h  tx_pstate=0x%08h",
      b_caps, b_status, (b_status>>3)&1, (b_status>>4)&1, (b_status>>2)&1,
      b_phy_gen, b_phy_pll, b_enr, b_pst), UVM_LOW)
  endtask

  // ---------------------------------------------------------------
  // Helper: initialize TideLink on both sides
  // ---------------------------------------------------------------
  virtual task init_both_sides(bit [31:0] a_pair_base = 32'h4000_0000,
                                bit [31:0] b_pair_base = 32'h5000_0000,
                                bit [31:0] a_threshold = 32'd0,
                                bit [31:0] b_threshold = 32'd0);

    `uvm_info("TEST", "Initializing TideLink on both sides...", UVM_LOW)

    // Initialize side A via APB writes (TideLink regs at 0x2000 offset)
    write_cfg_reg(SIDE_A, REG_PAIR_BASE,          a_pair_base);
    write_cfg_reg(SIDE_A, REG_REL_THRESHOLD,       a_threshold);
    write_cfg_reg(SIDE_A, REG_PAIR_CREDIT_ENABLE,  32'h1);

    // Initialize side B via APB writes
    write_cfg_reg(SIDE_B, REG_PAIR_BASE,          b_pair_base);
    write_cfg_reg(SIDE_B, REG_REL_THRESHOLD,       b_threshold);
    write_cfg_reg(SIDE_B, REG_PAIR_CREDIT_ENABLE,  32'h1);

    // Ring doorbell on both sides to start the credit handshake. Without
    // this, the Wlink TideLink FC TX node never gets initial credits from
    // the peer and stalls when traffic starts (skid_can_accept=0 → AHB
    // master back-pressured indefinitely).
    write_cfg_reg(SIDE_A, REG_DOORBELL,            32'h1);
    write_cfg_reg(SIDE_B, REG_DOORBELL,            32'h1);

    // Wait for doorbells to propagate through Wlink FC path (GPIO PHY is slow)
    repeat (phy_transit_wait) @(posedge tb_if.clk);

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
    rd_seq.addr = 15'h2000 + addr;  // TideLink regs at 0x2000 offset in unified APB
    if (side == SIDE_A)
      rd_seq.start(env.a_apb_agt.sequencer);
    else
      rd_seq.start(env.b_apb_agt.sequencer);
    data = rd_seq.rdata;
  endtask

  // ---------------------------------------------------------------
  // Helper: write a config register
  // ---------------------------------------------------------------
  virtual task write_cfg_reg(side_t side, input bit [11:0] addr, input bit [31:0] data);
    integration_cfg_write_sequence wr_seq;
    wr_seq = integration_cfg_write_sequence::type_id::create("wr_seq");
    wr_seq.addr = 15'h2000 + addr;  // TideLink regs at 0x2000 offset in unified APB
    wr_seq.data = data;
    if (side == SIDE_A)
      wr_seq.start(env.a_apb_agt.sequencer);
    else
      wr_seq.start(env.b_apb_agt.sequencer);
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
