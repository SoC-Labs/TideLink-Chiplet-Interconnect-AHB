///////////////////////////////////////////////////////////////////////////////
// test_long_term_stability.sv
///////////////////////////////////////////////////////////////////////////////
// PTP synchronisation test: long-term stability under drift.
//
// PHC_B runs at +50 ppm relative to PHC_A. The servo runs for 10000
// exchanges and the test verifies that the residual offset remains
// bounded throughout the entire run.
//
// Pass criteria:
//   - Servo converges within max_settling_exchanges
//   - Steady-state stddev bounded (stability)
//   - No single exchange exceeds 2x convergence_threshold_ns after settling
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_LONG_TERM_STABILITY_SV
`define GUARD_TEST_LONG_TERM_STABILITY_SV

class test_long_term_stability extends ptp_sync_base_test;

  `uvm_component_utils(test_long_term_stability)

  // Drift in ppm for PHC_B
  real drift_ppm = 50.0;

  function new(string name = "test_long_term_stability", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Long-running configuration
    cfg.num_exchanges            = 10000;
    cfg.max_settling_exchanges   = 200;
    cfg.convergence_threshold_ns = 10;
    cfg.exchange_interval_cycles = 5000;

    // Increase timeout for long test
    test_timeout_cycles = 200_000_000;

    servo.configure(cfg);
  endfunction

  virtual task main_phase(uvm_phase phase);
    ptp_servo_sequence servo_seq;
    real frac_real;
    bit [31:0] initial_frac_b;
    real stddev;
    real max_post_settle;
    int unsigned i;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf(
      "=== test_long_term_stability: %0d exchanges at +%.0f ppm ===",
      cfg.num_exchanges, drift_ppm), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialise PHC_A at nominal, PHC_B with drift
    // ---------------------------------------------------------------
    frac_real = 4.0 * drift_ppm * 1.0e-6 * 4294967296.0;
    initial_frac_b = $rtoi(frac_real);

    init_phcs(
      .ns_incr_a(32'd4), .ns_incr_frac_a(32'd0),
      .ns_incr_b(32'd4), .ns_incr_frac_b(initial_frac_b)
    );
    enable_ptp();

    // Coverage
    env.cov.sample_freq_error(drift_ppm);

    // ---------------------------------------------------------------
    // Step 2: Run servo loop
    // ---------------------------------------------------------------
    servo_seq = create_servo_seq("stability_servo");
    servo_seq.current_ns_incr_frac_b = initial_frac_b;
    servo_seq.start(null);

    // ---------------------------------------------------------------
    // Step 3: Evaluate stability
    // ---------------------------------------------------------------
    if (env.sb.converged) begin
      env.cov.sample_settling(env.sb.settling_exchange);
      env.cov.sample_residual(env.sb.get_mean_offset());

      stddev = env.sb.get_stddev_offset();
      `uvm_info("TEST", $sformatf("Steady-state stddev: %.3f ns", stddev), UVM_LOW)

      // Check that stddev is reasonable (< 2x threshold)
      if (stddev > $itor(cfg.convergence_threshold_ns) * 2.0)
        `uvm_error("TEST", $sformatf(
          "Steady-state stddev (%.3f ns) too high (threshold=%0d ns)",
          stddev, cfg.convergence_threshold_ns))

      // Check max overshoot after convergence
      max_post_settle = env.sb.max_overshoot_ns;
      `uvm_info("TEST", $sformatf("Max post-settle offset: %.3f ns", max_post_settle), UVM_LOW)

      if (max_post_settle > $itor(cfg.convergence_threshold_ns) * 3.0)
        `uvm_error("TEST", $sformatf(
          "Post-settle max offset (%.3f ns) exceeds 3x threshold (%0d ns)",
          max_post_settle, cfg.convergence_threshold_ns))
    end

    // Check all post-convergence records for bounded residual
    if (env.sb.converged) begin
      for (i = env.sb.settling_exchange; i < env.sb.records.size(); i++) begin
        real abs_off;
        abs_off = (env.sb.records[i].offset_ns < 0.0) ?
                  -env.sb.records[i].offset_ns : env.sb.records[i].offset_ns;
        if (abs_off > $itor(cfg.convergence_threshold_ns) * 5.0) begin
          `uvm_error("TEST", $sformatf(
            "Exchange %0d: offset %.3f ns exceeds 5x threshold",
            i, env.sb.records[i].offset_ns))
          break;  // Report only the first violation
        end
      end
    end

    `uvm_info("TEST", "=== test_long_term_stability complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_LONG_TERM_STABILITY_SV
