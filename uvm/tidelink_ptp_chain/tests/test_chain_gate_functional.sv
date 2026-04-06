///////////////////////////////////////////////////////////////////////////////
// test_chain_gate_functional.sv
///////////////////////////////////////////////////////////////////////////////
// Verification gap G34: PTP multi-hop chaining not verified.
//
// Exercises the lock gate mechanism end-to-end:
//   1. Enable HW sync on B2 (PHC_LOCK_GATE_EN=1)
//   2. Verify no SYNC packets appear on link 2 while b1_servo_locked=0
//   3. Force b1_servo_locked=1
//   4. Verify SYNC packets begin on link 2 within hw_sync_interval
//   5. Verify sequence numbers increment correctly
//   6. Test background FIFO traffic during PTP on both links
//
// References: SHORTCOMINGS.md #34
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_GATE_FUNCTIONAL_SV
`define GUARD_TEST_CHAIN_GATE_FUNCTIONAL_SV

class test_chain_gate_functional extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_gate_functional)

  function new(string name = "test_chain_gate_functional", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 10_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] status;
    int unsigned initial_seq_num;
    int unsigned later_seq_num;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Gate Functional (G34) ===", UVM_LOW)

    init_all_links();

    // Enable PTP on all sides
    enable_ptp(SIDE_A);
    enable_ptp(SIDE_B1);
    enable_ptp(SIDE_B2);
    enable_ptp(SIDE_C);

    // Configure servos: A=GM, B1=Sub, B2=GM, C=Sub
    configure_servo(SIDE_A,  2'b00, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_B1, 2'b01, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_B2, 2'b00, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_C,  2'b01, default_kp, default_ki, default_step_thresh);

    // ===============================================================
    // Phase 1: Enable HW sync on A and B2, verify B2 is gated
    // ===============================================================
    `uvm_info("TEST", "Phase 1: Enable HW sync, verify B2 gated", UVM_LOW)

    enable_hw_sync(SIDE_A, hw_sync_interval);
    enable_hw_sync(SIDE_B2, hw_sync_interval);

    // Record B2's sequence number (should be 0 since gate is blocking)
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    initial_seq_num = (status >> 2) & 16'hFFFF;
    `uvm_info("TEST", $sformatf("B2 initial seq_num = %0d, phc_locked = %0b",
      initial_seq_num, status[18]), UVM_LOW)

    // Verify B2 phc_locked is 0
    if (status[18])
      `uvm_error("TEST", "B2 phc_locked should be 0 before B1 locks")

    // Wait several sync intervals — B2 should NOT advance
    repeat (50000) @(posedge tb_if.clk);

    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    later_seq_num = (status >> 2) & 16'hFFFF;
    `uvm_info("TEST", $sformatf("B2 seq_num after wait = %0d (expected %0d)",
      later_seq_num, initial_seq_num), UVM_LOW)

    if (later_seq_num != initial_seq_num)
      `uvm_error("TEST", $sformatf(
        "B2 seq_num advanced while gated: %0d -> %0d",
        initial_seq_num, later_seq_num))
    else
      `uvm_info("TEST", "B2 correctly gated (no SYNC generated)", UVM_LOW)

    // ===============================================================
    // Phase 2: Unlock B1 → verify B2 starts generating SYNCs
    // ===============================================================
    `uvm_info("TEST", "Phase 2: Force B1 locked, verify B2 starts SYNCs", UVM_LOW)

    tb_if.force_b1_servo_locked_val = 1'b1; tb_if.force_b1_servo_locked = 1'b1;
    repeat (10) @(posedge tb_if.clk);

    // Verify phc_locked transitioned
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (!status[18])
      `uvm_error("TEST", "B2 phc_locked should be 1 after B1 lock force")
    else
      `uvm_info("TEST", "B2 phc_locked=1 confirmed", UVM_LOW)

    // Wait for a few sync intervals for B2 to fire SYNCs
    repeat (50000) @(posedge tb_if.clk);

    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    later_seq_num = (status >> 2) & 16'hFFFF;
    `uvm_info("TEST", $sformatf("B2 seq_num after unlock = %0d", later_seq_num), UVM_LOW)

    if (later_seq_num <= initial_seq_num)
      `uvm_error("TEST", $sformatf(
        "B2 seq_num did not advance after unlock: %0d",
        later_seq_num))
    else
      `uvm_info("TEST", $sformatf(
        "B2 generated %0d SYNCs after unlock", later_seq_num - initial_seq_num), UVM_LOW)

    // ===============================================================
    // Phase 3: Verify A is independently generating SYNCs
    // ===============================================================
    `uvm_info("TEST", "Phase 3: Verify A HW sync active independently", UVM_LOW)

    read_apb_reg(SIDE_A, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    `uvm_info("TEST", $sformatf("A HW_SYNC_STATUS = 0x%08h (seq=%0d, active=%0b)",
      status, (status >> 2) & 16'hFFFF, status[0]), UVM_LOW)

    if (!status[0])
      `uvm_error("TEST", "A HW sync should be active")
    if (((status >> 2) & 16'hFFFF) == 0)
      `uvm_warning("TEST", "A seq_num is still 0 — may need more time")

    // Phase 4 (FIFO traffic during PTP) is deferred — the PTP chain
    // environment does not have FIFO packet write/read helpers.
    // This would need to be tested in tidelink_top_system instead.

    // Clean up force
    tb_if.force_b1_servo_locked = 1'b0;

    `uvm_info("TEST", "G34 Chain Gate Functional test complete.", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_GATE_FUNCTIONAL_SV
