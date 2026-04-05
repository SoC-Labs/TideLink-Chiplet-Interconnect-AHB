///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_config.sv
///////////////////////////////////////////////////////////////////////////////
// Configuration object for PTP chain testbench parameters.
// Controls timing, convergence thresholds, and test limits.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_CONFIG_SV
`define GUARD_TIDELINK_PTP_CHAIN_CONFIG_SV

class tidelink_ptp_chain_config extends uvm_object;

  `uvm_object_utils_begin(tidelink_ptp_chain_config)
    `uvm_field_int(hw_sync_interval_ns,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(convergence_threshold_ns, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(max_settling_exchanges,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(steady_state_exchanges,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(test_timeout_cycles,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(wlink_linkup_wait,       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(phy_transit_wait,        UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  // HW sync interval in nanoseconds (default 1 Hz = 1e9 ns)
  int unsigned hw_sync_interval_ns = 1_000_000_000;

  // Convergence threshold in nanoseconds (1 us)
  int unsigned convergence_threshold_ns = 1000;

  // Maximum number of PTP exchanges before declaring failure to settle
  int unsigned max_settling_exchanges = 200;

  // Number of steady-state exchanges to collect after convergence
  int unsigned steady_state_exchanges = 100;

  // Test timeout in clock cycles
  int unsigned test_timeout_cycles = 5_000_000;

  // Wait cycles for Wlink link-up
  int unsigned wlink_linkup_wait = 10_000;

  // Wait cycles for PHY transit settling
  int unsigned phy_transit_wait = 5_000;

  function new(string name = "tidelink_ptp_chain_config");
    super.new(name);
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_CHAIN_CONFIG_SV
