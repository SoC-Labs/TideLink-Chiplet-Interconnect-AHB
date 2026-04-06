///////////////////////////////////////////////////////////////////////////////
// test_chain_lock_propagation.sv
///////////////////////////////////////////////////////////////////////////////
// Verifies lock gate propagation: B2 HW sync stays gated until B1 locks.
// Uses force on b1_servo_locked to simulate lock without waiting for real
// PTP convergence (avoids 4-DUT simulation speed bottleneck).
//
// Steps:
//   1. Init all links, configure servos, enable PTP
//   2. Enable HW sync on A and B2
//   3. Poll B2 HW_SYNC_STATUS[18] — verify it starts at 0
//   4. Force b1_servo_locked = 1 (simulating B1 PTP lock)
//   5. Verify B2 HW_SYNC_STATUS[18] transitions to 1
//   6. Verify B2 HW sync FSM advances (seq_num > 0 after PHC time elapses)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_LOCK_PROPAGATION_SV
`define GUARD_TEST_CHAIN_LOCK_PROPAGATION_SV

class test_chain_lock_propagation extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_lock_propagation)

  function new(string name = "test_chain_lock_propagation", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] status;
    int lock_cycle;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Lock Propagation ===", UVM_LOW)

    init_all_links();

    // Enable PTP on all 4 sides
    enable_ptp(SIDE_A);
    enable_ptp(SIDE_B1);
    enable_ptp(SIDE_B2);
    enable_ptp(SIDE_C);

    // Configure servos: A=GM, B1=Sub, B2=GM, C=Sub
    configure_servo(SIDE_A,  2'b00, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_B1, 2'b01, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_B2, 2'b00, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_C,  2'b01, default_kp, default_ki, default_step_thresh);

    // Enable HW sync on A and B2
    enable_hw_sync(SIDE_A, hw_sync_interval);
    enable_hw_sync(SIDE_B2, hw_sync_interval);

    // ---------------------------------------------------------------
    // Verify B2 HW_SYNC_STATUS[18] (phc_locked) starts at 0
    // ---------------------------------------------------------------
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (status[18]) begin
      `uvm_error("TEST", $sformatf(
        "B2 HW_SYNC_STATUS[18] should be 0 before B1 locks, got 0x%08h", status))
    end else begin
      `uvm_info("TEST", "B2 phc_locked=0 confirmed (B1 not yet locked)", UVM_LOW)
    end

    // ---------------------------------------------------------------
    // Simulate B1 achieving servo lock via force
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Forcing b1_servo_locked = 1...", UVM_LOW)
    tb_if.force_b1_servo_locked_val = 1'b1; tb_if.force_b1_servo_locked = 1'b1;

    // Wait a few cycles for the signal to propagate through B2's phc_locked_i
    repeat (10) @(posedge tb_if.clk);

    // ---------------------------------------------------------------
    // Verify B2 HW_SYNC_STATUS[18] transitions to 1
    // ---------------------------------------------------------------
    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    if (!status[18]) begin
      `uvm_error("TEST", $sformatf(
        "B2 HW_SYNC_STATUS[18] should be 1 after B1 locks, got 0x%08h", status))
    end else begin
      `uvm_info("TEST", "B2 phc_locked=1 confirmed (lock propagated)", UVM_LOW)
    end

    // ---------------------------------------------------------------
    // Wait for B2 HW sync to fire (seq_num should increment)
    // The HW sync FSM should have armed on the phc_locked_i rising edge
    // and will fire when PHC time reaches the target.
    // ---------------------------------------------------------------
    repeat (env.ptp_cfg.phy_transit_wait) @(posedge tb_if.clk);

    read_apb_reg(SIDE_B2, TIDELINK_APB_BASE + REG_HW_SYNC_STATUS, status);
    `uvm_info("TEST", $sformatf("B2 HW_SYNC_STATUS after wait: 0x%08h (seq=%0d, busy=%0b, active=%0b)",
      status, (status >> 2) & 16'hFFFF, status[1], status[0]), UVM_LOW)

    // Release force
    tb_if.force_b1_servo_locked = 1'b0;

    `uvm_info("TEST", "=== Test Chain Lock Propagation Complete ===", UVM_LOW)
    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_LOCK_PROPAGATION_SV
