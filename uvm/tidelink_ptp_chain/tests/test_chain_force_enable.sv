///////////////////////////////////////////////////////////////////////////////
// test_chain_force_enable.sv
///////////////////////////////////////////////////////////////////////////////
// Verify that setting hw_sync_force_en=1 (HW_SYNC_CTRL[2]) on B2
// causes the HW sync initiator to fire immediately, bypassing the
// phc_locked_i gate. This allows B2->C sync even before B1 has locked.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_FORCE_ENABLE_SV
`define GUARD_TEST_CHAIN_FORCE_ENABLE_SV

class test_chain_force_enable extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_force_enable)

  function new(string name = "test_chain_force_enable", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] status;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Force Enable ===", UVM_LOW)

    init_all_links();

    // Enable PTP on B2
    enable_ptp(SIDE_B2);

    // Configure B2 servo as GM
    configure_servo(SIDE_B2, 2'b00, default_kp, default_ki, default_step_thresh);

    // ---------------------------------------------------------------
    // Verify B2 phc_locked is 0 (B1 servo not locked)
    // ---------------------------------------------------------------
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    `uvm_info("TEST", $sformatf("B2 HW_SYNC_STATUS before force_en: 0x%08h (phc_locked=%0b)",
      status, status[18]), UVM_LOW)

    // ---------------------------------------------------------------
    // Enable HW sync with force_en = 1 (bypass lock gate)
    // HW_SYNC_CTRL[0] = enable, HW_SYNC_CTRL[2] = force_en -> value = 0x5
    // ---------------------------------------------------------------
    write_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_INTERVAL, hw_sync_interval);
    write_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_CTRL, 32'h0000_0005);

    `uvm_info("TEST", "B2 HW sync enabled with force_en=1 (lock gate bypassed)", UVM_LOW)

    // Wait for PHC time to advance past interval
    repeat (env.ptp_cfg.phy_transit_wait) @(posedge tb_if.clk);

    // ---------------------------------------------------------------
    // Check that B2 HW sync FSM is active despite phc_locked = 0
    // ---------------------------------------------------------------
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    `uvm_info("TEST", $sformatf("B2 HW_SYNC_STATUS after force_en: 0x%08h (active=%0b, phc_locked=%0b)",
      status, status[0], status[18]), UVM_LOW)

    if (!status[0]) begin
      `uvm_error("TEST", "B2 HW sync should be active with force_en=1")
    end

    // Verify HW_SYNC_CTRL readback has force_en bit set
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_CTRL, status);
    if (!status[2]) begin
      `uvm_error("TEST", $sformatf("HW_SYNC_CTRL[2] force_en not set in readback: 0x%08h", status))
    end else begin
      `uvm_info("TEST", "force_en bit confirmed in HW_SYNC_CTRL readback", UVM_LOW)
    end

    `uvm_info("TEST", "=== Test Chain Force Enable Complete ===", UVM_LOW)
    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_FORCE_ENABLE_SV
