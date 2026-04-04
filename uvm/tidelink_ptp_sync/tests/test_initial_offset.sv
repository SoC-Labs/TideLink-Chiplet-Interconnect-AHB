///////////////////////////////////////////////////////////////////////////////
// test_initial_offset.sv
///////////////////////////////////////////////////////////////////////////////
// PTP synchronisation test: initial time offset convergence.
//
// PHC_A starts at time 0. PHC_B starts with +1 us (1000 ns) offset.
// Both clocks run at the same frequency (no drift). The servo loop
// adjusts PHC_B's NS_INCR_FRAC to converge the offset to zero.
//
// Pass criteria:
//   - Servo converges within max_settling_exchanges
//   - Residual offset bounded by convergence_threshold_ns
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_INITIAL_OFFSET_SV
`define GUARD_TEST_INITIAL_OFFSET_SV

class test_initial_offset extends ptp_sync_base_test;

  `uvm_component_utils(test_initial_offset)

  function new(string name = "test_initial_offset", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Override defaults for this test
    cfg.num_exchanges            = 500;
    cfg.max_settling_exchanges   = 100;
    cfg.convergence_threshold_ns = 10;
    cfg.exchange_interval_cycles = 5000;

    // Reconfigure servo with updated config
    servo.configure(cfg);
  endfunction

  virtual task main_phase(uvm_phase phase);
    phc_offset_inject_sequence offset_seq;
    ptp_servo_sequence         servo_seq;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_initial_offset: PHC_B starts +1 us ahead ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialise both PHCs with same frequency
    // ---------------------------------------------------------------
    init_phcs();
    enable_ptp();

    // ---------------------------------------------------------------
    // Step 2: Inject +1 us offset on PHC_B
    // ---------------------------------------------------------------
    offset_seq = phc_offset_inject_sequence::type_id::create("inject_offset");
    offset_seq.seconds_lo  = 32'd0;
    offset_seq.nanoseconds = 32'd1000;  // +1 us = 1000 ns
    offset_seq.side_name   = "B";
    offset_seq.start(env.b_phc_ahb_sys_env.master[0].sequencer);

    // Sample initial offset for coverage
    env.cov.sample_initial_offset(1000.0);

    // Allow offset to take effect
    repeat (100) @(posedge tb_if.clk);

    // ---------------------------------------------------------------
    // Step 3: Run servo loop
    // ---------------------------------------------------------------
    servo_seq = create_servo_seq("initial_offset_servo");
    servo_seq.start(null);

    // ---------------------------------------------------------------
    // Step 4: Sample convergence metrics for coverage
    // ---------------------------------------------------------------
    if (env.sb.converged) begin
      env.cov.sample_settling(env.sb.settling_exchange);
      env.cov.sample_residual(env.sb.get_mean_offset());
    end

    `uvm_info("TEST", "=== test_initial_offset complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_INITIAL_OFFSET_SV
