///////////////////////////////////////////////////////////////////////////////
// test_frequency_drift.sv
///////////////////////////////////////////////////////////////////////////////
// PTP synchronisation test: frequency drift compensation.
//
// PHC_B runs at +100 ppm relative to PHC_A (both start at time 0).
// The servo adjusts NS_INCR_FRAC on PHC_B to compensate for the
// frequency offset, keeping the clock offset bounded.
//
// Pass criteria:
//   - Servo converges within max_settling_exchanges
//   - Steady-state residual bounded by convergence_threshold_ns
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_FREQUENCY_DRIFT_SV
`define GUARD_TEST_FREQUENCY_DRIFT_SV

class test_frequency_drift extends ptp_sync_base_test;

  `uvm_component_utils(test_frequency_drift)

  // Drift in ppm for PHC_B
  real drift_ppm = 100.0;

  function new(string name = "test_frequency_drift", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Override defaults for this test
    cfg.num_exchanges            = 1000;
    cfg.max_settling_exchanges   = 200;
    cfg.convergence_threshold_ns = 10;
    cfg.exchange_interval_cycles = 10000;

    // Reconfigure servo
    servo.configure(cfg);
  endfunction

  virtual task main_phase(uvm_phase phase);
    phc_drift_inject_sequence  drift_seq;
    ptp_servo_sequence         servo_seq;
    real frac_real;
    bit [31:0] initial_frac_b;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf(
      "=== test_frequency_drift: PHC_B at +%.0f ppm ===", drift_ppm), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialise PHC_A at nominal, PHC_B with drift
    // ---------------------------------------------------------------
    // Compute NS_INCR_FRAC for the desired ppm drift
    frac_real = 4.0 * drift_ppm * 1.0e-6 * 4294967296.0;
    initial_frac_b = $rtoi(frac_real);

    init_phcs(
      .ns_incr_a(32'd4), .ns_incr_frac_a(32'd0),
      .ns_incr_b(32'd4), .ns_incr_frac_b(initial_frac_b)
    );
    enable_ptp();

    // Sample frequency error for coverage
    env.cov.sample_freq_error(drift_ppm);

    // Set initial frac on servo sequence
    `uvm_info("TEST", $sformatf("PHC_B initial NS_INCR_FRAC=0x%08h (%.0f ppm)",
      initial_frac_b, drift_ppm), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 2: Run servo loop
    // ---------------------------------------------------------------
    servo_seq = create_servo_seq("drift_servo");
    servo_seq.current_ns_incr_frac_b = initial_frac_b;
    servo_seq.start(null);

    // ---------------------------------------------------------------
    // Step 3: Sample convergence metrics
    // ---------------------------------------------------------------
    if (env.sb.converged) begin
      env.cov.sample_settling(env.sb.settling_exchange);
      env.cov.sample_residual(env.sb.get_mean_offset());
    end

    `uvm_info("TEST", "=== test_frequency_drift complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_FREQUENCY_DRIFT_SV
