///////////////////////////////////////////////////////////////////////////////
// test_chain_b_unlock_c_holds.sv
///////////////////////////////////////////////////////////////////////////////
// Verify that when A's HW sync is temporarily disabled (causing B1 to
// unlock), C's servo pauses gracefully because B2's lock gate closes.
// When A's HW sync is re-enabled and B1 re-locks, C should resume and
// eventually converge again.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_B_UNLOCK_C_HOLDS_SV
`define GUARD_TEST_CHAIN_B_UNLOCK_C_HOLDS_SV

class test_chain_b_unlock_c_holds extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_b_unlock_c_holds)

  function new(string name = "test_chain_b_unlock_c_holds", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain B Unlock C Holds ===", UVM_LOW)

    init_all_links();

    // TODO: Configure and enable PTP/servo on all sides
    // TODO: Wait for full chain convergence
    // TODO: Disable HW sync on A (write HW_SYNC_CTRL=0)
    // TODO: Wait for B1 servo to unlock
    // TODO: Verify B2 HW_SYNC_STATUS[18] (phc_locked) deasserts
    // TODO: Verify C servo stops receiving sync messages (pauses)
    // TODO: Re-enable HW sync on A
    // TODO: Wait for B1 re-lock, then C re-lock
    // TODO: Confirm full chain convergence restored

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_B_UNLOCK_C_HOLDS_SV
