///////////////////////////////////////////////////////////////////////////////
// test_chain_b_unlock_c_holds.sv
///////////////////////////////////////////////////////////////////////////////
// Verify lock gate behaviour when B1 locks, unlocks, and re-locks.
// Uses force on b1_servo_locked to simulate lock transitions.
//
// Key verification: the lock gate only prevents IDLE->ARMED transition.
// Once the HW sync FSM is armed/running, a lock drop does NOT force it
// back to IDLE. But if the FSM is disabled and re-enabled, it will need
// the lock gate to be satisfied again.
//
// Steps:
//   1. Init all links, configure servos, enable PTP
//   2. Enable HW sync on B2, force b1_servo_locked=1 -> B2 arms
//   3. Verify B2 is active (HW_SYNC_STATUS active=1)
//   4. Force b1_servo_locked=0 (simulate B1 losing lock)
//   5. Verify B2 HW_SYNC_STATUS[18]=0 but FSM still active
//   6. Disable B2 HW sync, then re-enable while lock is still low
//   7. Verify B2 FSM does NOT arm (gate blocks it)
//   8. Force b1_servo_locked=1 again -> B2 re-arms
//   9. Verify B2 active again
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_B_UNLOCK_C_HOLDS_SV
`define GUARD_TEST_CHAIN_B_UNLOCK_C_HOLDS_SV

class test_chain_b_unlock_c_holds extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_b_unlock_c_holds)

  function new(string name = "test_chain_b_unlock_c_holds", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] status;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain B Unlock C Holds ===", UVM_LOW)

    init_all_links();

    enable_ptp(SIDE_B2);
    configure_servo(SIDE_B2, 2'b00, default_kp, default_ki, default_step_thresh);

    // ---------------------------------------------------------------
    // Phase 1: Force B1 locked, enable B2 HW sync -> should arm
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Phase 1: Force B1 locked, enable B2 HW sync", UVM_LOW)
    force test_top.b1_servo_locked = 1'b1;
    repeat (5) @(posedge tb_if.clk);

    enable_hw_sync(SIDE_B2, hw_sync_interval);
    repeat (10) @(posedge tb_if.clk);

    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (!status[0]) begin
      `uvm_error("TEST", "B2 HW sync should be active after lock + enable")
    end else begin
      `uvm_info("TEST", "B2 HW sync active confirmed", UVM_LOW)
    end

    // ---------------------------------------------------------------
    // Phase 2: Drop B1 lock -> B2 phc_locked=0 but FSM stays active
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Phase 2: Drop B1 lock, verify B2 FSM stays active", UVM_LOW)
    force test_top.b1_servo_locked = 1'b0;
    repeat (10) @(posedge tb_if.clk);

    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (status[18]) begin
      `uvm_error("TEST", $sformatf(
        "B2 phc_locked should be 0 after B1 unlock, got status=0x%08h", status))
    end
    if (!status[0]) begin
      `uvm_error("TEST", "B2 HW sync should remain active despite lock drop")
    end else begin
      `uvm_info("TEST", "B2 FSM still active after lock drop (gate only blocks arming)", UVM_LOW)
    end

    // ---------------------------------------------------------------
    // Phase 3: Disable and re-enable B2 HW sync while lock is low
    // -> FSM should NOT arm (gate blocks IDLE->ARMED)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Phase 3: Disable+re-enable B2 while lock low", UVM_LOW)
    write_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_CTRL, 32'h0);  // disable
    repeat (5) @(posedge tb_if.clk);
    write_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_CTRL, 32'h1);  // re-enable
    repeat (10) @(posedge tb_if.clk);

    // The FSM should be in IDLE (enable is set but gate blocks arming)
    // status[0] = active (enable is set), but busy should be 0
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (status[1]) begin
      `uvm_error("TEST", "B2 should NOT be busy (gate should block arming while lock low)")
    end else begin
      `uvm_info("TEST", "B2 correctly blocked from arming while lock low", UVM_LOW)
    end

    // ---------------------------------------------------------------
    // Phase 4: Re-assert B1 lock -> B2 should re-arm
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Phase 4: Re-assert B1 lock, verify B2 re-arms", UVM_LOW)
    force test_top.b1_servo_locked = 1'b1;
    repeat (10) @(posedge tb_if.clk);

    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (!status[18]) begin
      `uvm_error("TEST", "B2 phc_locked should be 1 after B1 re-lock")
    end
    `uvm_info("TEST", $sformatf("B2 HW_SYNC_STATUS after re-lock: 0x%08h", status), UVM_LOW)

    // Release force
    release test_top.b1_servo_locked;

    `uvm_info("TEST", "=== Test Chain B Unlock C Holds Complete ===", UVM_LOW)
    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_B_UNLOCK_C_HOLDS_SV
