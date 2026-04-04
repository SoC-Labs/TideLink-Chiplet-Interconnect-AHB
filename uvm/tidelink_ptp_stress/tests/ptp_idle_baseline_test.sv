///////////////////////////////////////////////////////////////////////////////
// ptp_idle_baseline_test.sv
///////////////////////////////////////////////////////////////////////////////
// Baseline PTP delay measurement with 0% background traffic.
// Runs 1000 SYNC + DELAY_REQ exchanges to establish the minimum-delay
// characterisation for the interconnect.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_IDLE_BASELINE_TEST_SV
`define GUARD_PTP_IDLE_BASELINE_TEST_SV

class ptp_idle_baseline_test extends ptp_stress_base_test;

  `uvm_component_utils(ptp_idle_baseline_test)

  function new(string name = "ptp_idle_baseline_test", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 50_000_000;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // 0% traffic on all channels
    cfg.axi_traffic_rate  = 0;
    cfg.fifo_traffic_rate = 0;
    cfg.gb_traffic_rate   = 0;
    cfg.num_ptp_exchanges = 1000;

    `uvm_info("TEST", $sformatf("PTP Idle Baseline: %s", cfg.convert2string()), UVM_LOW)
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== PTP Idle Baseline Test (0% traffic, 1000 exchanges) ===", UVM_LOW)

    init_system();
    run_ptp_stress();

    repeat (100) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_PTP_IDLE_BASELINE_TEST_SV
