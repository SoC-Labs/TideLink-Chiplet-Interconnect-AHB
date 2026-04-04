///////////////////////////////////////////////////////////////////////////////
// ptp_all_saturated_test.sv
///////////////////////////////////////////////////////////////////////////////
// Maximum-stress PTP delay measurement with 100% background traffic on
// all channels (AXI, FIFO, general bus). Runs 1000 SYNC + DELAY_REQ
// exchanges to characterise worst-case delay variance.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_ALL_SATURATED_TEST_SV
`define GUARD_PTP_ALL_SATURATED_TEST_SV

class ptp_all_saturated_test extends ptp_stress_base_test;

  `uvm_component_utils(ptp_all_saturated_test)

  function new(string name = "ptp_all_saturated_test", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 100_000_000;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // 100% traffic on all channels
    cfg.axi_traffic_rate  = 100;
    cfg.fifo_traffic_rate = 100;
    cfg.gb_traffic_rate   = 100;
    cfg.num_ptp_exchanges = 1000;

    `uvm_info("TEST", $sformatf("PTP All Saturated: %s", cfg.convert2string()), UVM_LOW)
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== PTP All Saturated Test (100% traffic, 1000 exchanges) ===", UVM_LOW)

    init_system();
    run_ptp_stress();

    repeat (100) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_PTP_ALL_SATURATED_TEST_SV
