///////////////////////////////////////////////////////////////////////////////
// test_step_change.sv
///////////////////////////////////////////////////////////////////////////////
// PTP synchronisation test: step-change recovery.
//
// Both PHCs start synchronised. At exchange 200, PHC_B is jumped forward
// by +10 us. The servo must detect the step and recover synchronisation.
//
// Pass criteria:
//   - Initially converged (within first 50 exchanges)
//   - Recovers from step within max_settling_exchanges of the injection
//   - Post-recovery residual bounded by convergence_threshold_ns
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_STEP_CHANGE_SV
`define GUARD_TEST_STEP_CHANGE_SV

class test_step_change extends ptp_sync_base_test;

  `uvm_component_utils(test_step_change)

  // Exchange at which to inject the step
  int unsigned step_exchange = 200;

  // Step magnitude in nanoseconds
  bit [31:0] step_ns = 32'd10000;  // +10 us

  function new(string name = "test_step_change", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // Override defaults: need enough exchanges for convergence + step + recovery
    cfg.num_exchanges            = 600;
    cfg.max_settling_exchanges   = 200;
    cfg.convergence_threshold_ns = 10;
    cfg.exchange_interval_cycles = 5000;

    servo.configure(cfg);
  endfunction

  virtual task main_phase(uvm_phase phase);
    ptp_exchange_sequence      exch_seq;
    ahb_reg_write_sequence     wr_seq;
    phc_offset_inject_sequence offset_seq;
    int adjustment;
    int unsigned i;
    bit [31:0] current_frac_b;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf(
      "=== test_step_change: +%0d ns step at exchange %0d ===",
      step_ns, step_exchange), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialise both PHCs identically
    // ---------------------------------------------------------------
    init_phcs();
    enable_ptp();

    // ---------------------------------------------------------------
    // Step 2: Manual servo loop with step injection mid-way
    // ---------------------------------------------------------------
    servo.reset();
    current_frac_b = 32'd0;

    for (i = 0; i < cfg.num_exchanges; i++) begin

      // Inject step at the designated exchange
      if (i == step_exchange) begin
        `uvm_info("TEST", $sformatf("Injecting +%0d ns step on PHC_B at exchange %0d",
          step_ns, i), UVM_LOW)

        offset_seq = phc_offset_inject_sequence::type_id::create("step_inject");
        offset_seq.seconds_lo  = 32'd0;
        offset_seq.nanoseconds = step_ns;
        offset_seq.side_name   = "B";
        offset_seq.start(env.b_phc_ahb_sys_env.master[0].sequencer);

        // Mark step in scoreboard (resets convergence tracking)
        env.sb.mark_step_injection(i);

        // Reset servo integral to avoid windup from pre-step history
        servo.reset();

        repeat (50) @(posedge tb_if.clk);
      end

      // Perform PTP exchange
      exch_seq = ptp_exchange_sequence::type_id::create($sformatf("exch_%0d", i));
      exch_seq.a_phc_sqr = env.a_phc_ahb_sys_env.master[0].sequencer;
      exch_seq.a_ptp_sqr = env.a_ptp_ahb_sys_env.master[0].sequencer;
      exch_seq.b_phc_sqr = env.b_phc_ahb_sys_env.master[0].sequencer;
      exch_seq.b_ptp_sqr = env.b_ptp_ahb_sys_env.master[0].sequencer;
      exch_seq.start(null);

      // Compute and apply adjustment
      adjustment = servo.compute_adjustment(exch_seq.offset_ns);
      current_frac_b = current_frac_b + adjustment;

      wr_seq = ahb_reg_write_sequence::type_id::create("wr_frac_b");
      wr_seq.addr = PHC_REG_NS_INCR_FRAC;
      wr_seq.data = current_frac_b;
      wr_seq.start(env.b_phc_ahb_sys_env.master[0].sequencer);

      // Report to scoreboard
      env.sb.record_exchange(i, exch_seq.offset_ns, exch_seq.delay_ns, current_frac_b);

      // Coverage
      env.cov.sample_adjustment(adjustment);
      env.cov.sample_residual(exch_seq.offset_ns);

      // Wait for next exchange
      repeat (cfg.exchange_interval_cycles) @(posedge tb_if.clk);
    end

    // ---------------------------------------------------------------
    // Step 3: Sample step recovery metrics
    // ---------------------------------------------------------------
    if (env.sb.recovered) begin
      int unsigned recovery_time = env.sb.recovery_exchange - step_exchange;
      env.cov.sample_recovery(recovery_time);
      `uvm_info("TEST", $sformatf("Step recovery took %0d exchanges", recovery_time), UVM_LOW)
    end

    `uvm_info("TEST", "=== test_step_change complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_STEP_CHANGE_SV
