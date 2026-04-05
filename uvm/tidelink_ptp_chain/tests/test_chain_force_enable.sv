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
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Force Enable ===", UVM_LOW)

    init_all_links();

    // TODO: Configure and enable PTP/servo on all sides
    // TODO: Enable HW sync on B2 with force_en=1 (HW_SYNC_CTRL = 32'h0000_0005)
    // TODO: Verify B2 HW_SYNC_STATUS[0] (active) asserts even though phc_locked=0
    // TODO: Verify C receives sync messages and servo begins processing
    // TODO: Enable HW sync on A to start normal chain convergence
    // TODO: Wait for B1 lock, then verify C convergence improves
    // TODO: Report that force_en bypassed the lock gate successfully

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_FORCE_ENABLE_SV
