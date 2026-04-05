///////////////////////////////////////////////////////////////////////////////
// test_chain_step_recovery.sv
///////////////////////////////////////////////////////////////////////////////
// Inject a phase step on PHC_A after chain convergence and verify that
// both B1 and C servos recover to locked state within expected bounds.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_STEP_RECOVERY_SV
`define GUARD_TEST_CHAIN_STEP_RECOVERY_SV

class test_chain_step_recovery extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_step_recovery)

  function new(string name = "test_chain_step_recovery", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Step Recovery ===", UVM_LOW)

    init_all_links();

    // TODO: Configure and enable PTP/servo on all sides
    // TODO: Wait for full chain convergence (B1 locked, C locked)
    // TODO: Inject a phase step on PHC_A (e.g. write SET_TIME with offset)
    // TODO: Monitor B1 servo unlock and subsequent re-lock
    // TODO: Monitor C servo unlock and subsequent re-lock
    // TODO: Report recovery time for both hops
    // TODO: Assert recovery times are within acceptable limits

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_STEP_RECOVERY_SV
