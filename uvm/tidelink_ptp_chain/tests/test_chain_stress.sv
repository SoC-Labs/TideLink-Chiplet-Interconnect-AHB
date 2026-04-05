///////////////////////////////////////////////////////////////////////////////
// test_chain_stress.sv
///////////////////////////////////////////////////////////////////////////////
// Run background FIFO data traffic on all links while PTP convergence
// is in progress. Verify that PTP still converges and that data packets
// are not corrupted by concurrent PTP FC exchanges.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CHAIN_STRESS_SV
`define GUARD_TEST_CHAIN_STRESS_SV

class test_chain_stress extends tidelink_ptp_chain_base_test;

  `uvm_component_utils(test_chain_stress)

  function new(string name = "test_chain_stress", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Chain Stress ===", UVM_LOW)

    init_all_links();

    // TODO: Configure and enable PTP/servo on all sides
    // TODO: Enable HW sync on A and B2
    // TODO: Fork background FIFO write/read traffic on A->B1 and B2->C links
    // TODO: Wait for full chain convergence despite load
    // TODO: Verify no STATUS errors (overrun, underrun, master_error) on any side
    // TODO: Verify received data packets match sent data
    // TODO: Report PTP convergence time under load

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CHAIN_STRESS_SV
