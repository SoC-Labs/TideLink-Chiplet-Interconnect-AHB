///////////////////////////////////////////////////////////////////////////////
// test_chain_lock_propagation.sv
///////////////////////////////////////////////////////////////////////////////
// Measure the delay between B1 servo lock and C servo lock to characterise
// lock propagation latency through the chain.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_LOCK_PROPAGATION_SV
`define GUARD_TEST_CHAIN_LOCK_PROPAGATION_SV

class test_chain_lock_propagation extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_lock_propagation)

  function new(string name = "test_chain_lock_propagation", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Lock Propagation ===", UVM_LOW)

    init_all_links();

    // TODO: Enable PTP and configure servos on all sides
    // TODO: Enable HW sync on A and B2
    // TODO: Record timestamp when B1 servo locks (tb_if.b1_servo_locked posedge)
    // TODO: Record timestamp when C servo locks (tb_if.c_servo_locked posedge)
    // TODO: Compute and report lock propagation delay in clock cycles
    // TODO: Assert delay is within expected bounds

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_LOCK_PROPAGATION_SV
