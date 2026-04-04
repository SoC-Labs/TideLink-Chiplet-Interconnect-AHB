///////////////////////////////////////////////////////////////////////////////
// ptp_sync_config.sv
///////////////////////////////////////////////////////////////////////////////
// Configuration object for PTP synchronisation testbench.
//
// Contains servo PI gains, convergence criteria, and exchange parameters
// used by sequences and the scoreboard to control and evaluate
// PTP clock synchronisation behaviour.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SYNC_CONFIG_SV
`define GUARD_PTP_SYNC_CONFIG_SV

class ptp_sync_config extends uvm_object;

  `uvm_object_utils(ptp_sync_config)

  // ---------------------------------------------------------------
  // Servo PI gains
  // ---------------------------------------------------------------
  real Kp = 0.5;     // Proportional gain
  real Ki = 0.01;    // Integral gain

  // Maximum absolute adjustment value (in NS_INCR_FRAC units)
  real max_adjustment = 1000000.0;

  // ---------------------------------------------------------------
  // Convergence criteria
  // ---------------------------------------------------------------
  // Threshold (in nanoseconds) below which the offset is considered converged
  int unsigned convergence_threshold_ns = 10;

  // Maximum number of exchanges allowed before convergence must be achieved
  int unsigned max_settling_exchanges = 200;

  // ---------------------------------------------------------------
  // Exchange parameters
  // ---------------------------------------------------------------
  // Total number of PTP exchanges to run
  int unsigned num_exchanges = 1000;

  // Number of clock cycles between consecutive exchanges
  int unsigned exchange_interval_cycles = 10000;

  function new(string name = "ptp_sync_config");
    super.new(name);
  endfunction

endclass

`endif // GUARD_PTP_SYNC_CONFIG_SV
