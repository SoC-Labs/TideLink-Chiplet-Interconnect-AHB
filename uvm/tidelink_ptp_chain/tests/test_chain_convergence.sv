///////////////////////////////////////////////////////////////////////////////
// test_chain_convergence.sv
///////////////////////////////////////////////////////////////////////////////
// Verifies end-to-end PTP convergence across a 3-chiplet chain:
//   A (GM) -> B1 (Sub) / B2 (GM, gated by B1 lock) -> C (Sub)
//
// Steps:
//   1. Init all links
//   2. Enable PTP on all 4 sides
//   3. Configure A as GM, B1 as Sub; B2 as GM, C as Sub
//   4. Enable HW sync on A (starts sync immediately)
//   5. Enable HW sync on B2 (gated by phc_locked_i = b1_servo_locked)
//   6. Wait for B1 servo lock
//   7. Verify B2 HW_SYNC_STATUS[18] (phc_locked) is now 1
//   8. Wait for C servo lock
//   9. Observe steady state
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_CONVERGENCE_SV
`define GUARD_TEST_CHAIN_CONVERGENCE_SV

class test_chain_convergence extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_convergence)

  // Default servo gains
  bit [31:0] default_kp          = 32'h0800_0000;  // Kp ~ 0.03125
  bit [31:0] default_ki          = 32'h0080_0000;  // Ki ~ 0.00195
  bit [31:0] default_step_thresh = 32'd1_000_000;  // 1 ms step threshold

  // HW sync interval (nanoseconds)
  bit [31:0] hw_sync_interval    = 32'd100_000;    // 100 us

  // Steady-state observation cycles
  int unsigned steady_state_cycles = 50_000;

  function new(string name = "test_chain_convergence", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] hw_sync_status;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Convergence ===", UVM_LOW)

    // ---------------------------------------------------------------
    // 1. Initialize all links (Wlink + TideLink)
    // ---------------------------------------------------------------
    init_all_links();

    // ---------------------------------------------------------------
    // 2. Enable PTP on all 4 sides
    // ---------------------------------------------------------------
    enable_ptp(SIDE_A);
    enable_ptp(SIDE_B1);
    enable_ptp(SIDE_B2);
    enable_ptp(SIDE_C);

    // ---------------------------------------------------------------
    // 3. Configure servos
    //    A:  GM mode (mode=0)
    //    B1: Sub mode (mode=1) — disciplines PHC_B from A
    //    B2: GM mode (mode=0) — forwards PHC_B time to C
    //    C:  Sub mode (mode=1) — disciplines PHC_C from B2
    // ---------------------------------------------------------------
    configure_servo(SIDE_A,  2'b00, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_B1, 2'b01, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_B2, 2'b00, default_kp, default_ki, default_step_thresh);
    configure_servo(SIDE_C,  2'b01, default_kp, default_ki, default_step_thresh);

    // ---------------------------------------------------------------
    // 4. Enable HW sync on A (fires immediately — no lock gate)
    // ---------------------------------------------------------------
    enable_hw_sync(SIDE_A, hw_sync_interval);

    // ---------------------------------------------------------------
    // 5. Enable HW sync on B2 (gated by phc_locked_i = b1_servo_locked)
    //    Will not fire until B1 locks
    // ---------------------------------------------------------------
    enable_hw_sync(SIDE_B2, hw_sync_interval);

    // ---------------------------------------------------------------
    // 6. Wait for B1 servo lock (A -> B1 convergence)
    // ---------------------------------------------------------------
    wait_servo_lock(SIDE_B1);

    // ---------------------------------------------------------------
    // 7. Verify B2 HW_SYNC_STATUS[18] (phc_locked) is now asserted
    //    This confirms the lock gate has opened for B2 -> C
    // ---------------------------------------------------------------
    read_apb_reg(SIDE_B2,
      TIDELINK_APB_BASE + 15'(REG_HW_SYNC_STATUS), hw_sync_status);

    if (hw_sync_status[18])
      `uvm_info("TEST", $sformatf(
        "[B2] HW_SYNC_STATUS.phc_locked=1 as expected (status=0x%08h)",
        hw_sync_status), UVM_LOW)
    else
      `uvm_error("TEST", $sformatf(
        "[B2] HW_SYNC_STATUS.phc_locked=0 — lock gate not open (status=0x%08h)",
        hw_sync_status))

    // ---------------------------------------------------------------
    // 8. Wait for C servo lock (B2 -> C convergence)
    // ---------------------------------------------------------------
    wait_servo_lock(SIDE_C);

    // ---------------------------------------------------------------
    // 9. Cascade convergence achieved — observe steady state
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Cascade convergence achieved. Observing steady state...", UVM_LOW)

    repeat (steady_state_cycles) @(posedge tb_if.clk);

    `uvm_info("TEST", "Steady-state observation complete.", UVM_LOW)

    // ---------------------------------------------------------------
    // 10. Done
    // ---------------------------------------------------------------
    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_CONVERGENCE_SV
