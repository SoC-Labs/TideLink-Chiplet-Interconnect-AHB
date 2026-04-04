///////////////////////////////////////////////////////////////////////////////
// ptp_sync_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// Scoreboard for PTP synchronisation verification.
//
// Tracks per-exchange metrics (offset, delay, NS_INCR_FRAC, drift rate)
// and derives convergence statistics: settling time, overshoot,
// steady-state error, and stability (standard deviation of residual).
//
// End-of-test assertions check that the servo converged within budget
// and that residual error is bounded.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SYNC_SCOREBOARD_SV
`define GUARD_PTP_SYNC_SCOREBOARD_SV

class ptp_sync_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(ptp_sync_scoreboard)

  // Configuration handle
  ptp_sync_config cfg;

  // ---------------------------------------------------------------
  // Per-exchange records
  // ---------------------------------------------------------------
  typedef struct {
    int unsigned exchange_id;
    real         offset_ns;
    real         delay_ns;
    bit [31:0]   ns_incr_frac_b;
    real         drift_rate;   // ppm estimate
  } exchange_record_t;

  exchange_record_t records[$];

  // ---------------------------------------------------------------
  // Convergence tracking
  // ---------------------------------------------------------------
  int  settling_exchange;     // first exchange where |offset| < threshold
  bit  converged;
  real max_overshoot_ns;      // largest |offset| after first crossing zero
  real steady_state_sum;
  real steady_state_sum_sq;
  int unsigned steady_state_count;

  // Step-change recovery tracking
  bit  step_injected;
  int  step_exchange_id;
  int  recovery_exchange;     // first exchange after step where |offset| < threshold
  bit  recovered;

  function new(string name = "ptp_sync_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    settling_exchange    = -1;
    converged            = 0;
    max_overshoot_ns     = 0.0;
    steady_state_sum     = 0.0;
    steady_state_sum_sq  = 0.0;
    steady_state_count   = 0;
    step_injected        = 0;
    step_exchange_id     = -1;
    recovery_exchange    = -1;
    recovered            = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ptp_sync_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "ptp_sync_config not found in config_db")
  endfunction

  // ---------------------------------------------------------------
  // Record a PTP exchange result
  // ---------------------------------------------------------------
  function void record_exchange(int unsigned id,
                                 real offset_ns,
                                 real delay_ns,
                                 bit [31:0] ns_incr_frac_b);
    exchange_record_t rec;
    real abs_offset;
    real drift_ppm;

    rec.exchange_id     = id;
    rec.offset_ns       = offset_ns;
    rec.delay_ns        = delay_ns;
    rec.ns_incr_frac_b  = ns_incr_frac_b;

    // Estimate drift rate in ppm from NS_INCR_FRAC deviation
    // Nominal NS_INCR_FRAC = 0 means exactly 4ns per tick.
    // Each LSB of NS_INCR_FRAC = 4 / 2^32 ns ~ 9.31e-10 ns per tick.
    // At 100 MHz (10ns period), 1 LSB = 9.31e-10 / 10 * 1e6 ppm ~ 9.31e-5 ppm
    drift_ppm = $itor($signed(ns_incr_frac_b)) * 9.31e-5;
    rec.drift_rate = drift_ppm;

    records.push_back(rec);

    abs_offset = (offset_ns < 0.0) ? -offset_ns : offset_ns;

    // Check convergence
    if (!converged && abs_offset < $itor(cfg.convergence_threshold_ns)) begin
      settling_exchange = id;
      converged = 1;
      `uvm_info("SB_PTP", $sformatf("Converged at exchange %0d (offset=%.3f ns)",
        id, offset_ns), UVM_LOW)
    end

    // Track steady-state after convergence
    if (converged) begin
      steady_state_sum    += offset_ns;
      steady_state_sum_sq += offset_ns * offset_ns;
      steady_state_count++;

      if (abs_offset > max_overshoot_ns)
        max_overshoot_ns = abs_offset;
    end

    // Step recovery tracking
    if (step_injected && !recovered && id > step_exchange_id) begin
      if (abs_offset < $itor(cfg.convergence_threshold_ns)) begin
        recovery_exchange = id;
        recovered = 1;
        `uvm_info("SB_PTP", $sformatf("Recovered from step at exchange %0d (offset=%.3f ns)",
          id, offset_ns), UVM_LOW)
      end
    end

    `uvm_info("SB_PTP", $sformatf(
      "Exchange %0d: offset=%.3f ns, delay=%.3f ns, frac_b=0x%08h, drift=%.4f ppm",
      id, offset_ns, delay_ns, ns_incr_frac_b, drift_ppm), UVM_HIGH)
  endfunction

  // ---------------------------------------------------------------
  // Mark that a step change was injected at a given exchange
  // ---------------------------------------------------------------
  function void mark_step_injection(int unsigned exchange_id);
    step_injected    = 1;
    step_exchange_id = exchange_id;
    recovered        = 0;
    recovery_exchange = -1;
    // Reset steady-state tracking since we expect transient
    max_overshoot_ns    = 0.0;
    steady_state_sum    = 0.0;
    steady_state_sum_sq = 0.0;
    steady_state_count  = 0;
    `uvm_info("SB_PTP", $sformatf("Step change injected at exchange %0d", exchange_id), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------
  // Compute steady-state statistics
  // ---------------------------------------------------------------
  function real get_mean_offset();
    if (steady_state_count == 0) return 0.0;
    return steady_state_sum / $itor(steady_state_count);
  endfunction

  function real get_stddev_offset();
    real mean, variance;
    if (steady_state_count < 2) return 0.0;
    mean = get_mean_offset();
    variance = (steady_state_sum_sq / $itor(steady_state_count)) - (mean * mean);
    if (variance < 0.0) variance = 0.0;
    return $sqrt(variance);
  endfunction

  // ---------------------------------------------------------------
  // Report and end-of-test assertions
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    real mean_offset, stddev;
    int unsigned total_exchanges;

    total_exchanges = records.size();
    mean_offset = get_mean_offset();
    stddev = get_stddev_offset();

    `uvm_info("SB_REPORT", $sformatf({
      "\n",
      "---------- PTP Sync Scoreboard Report ----------\n",
      "  Total exchanges:         %0d\n",
      "  Converged:               %s\n",
      "  Settling exchange:       %0d\n",
      "  Max overshoot (after convergence): %.3f ns\n",
      "  Steady-state mean offset: %.3f ns\n",
      "  Steady-state stddev:      %.3f ns\n",
      "  Steady-state samples:     %0d\n",
      "  Step injected:            %s\n",
      "  Step recovery exchange:   %0d\n",
      "-------------------------------------------------"},
      total_exchanges,
      converged ? "YES" : "NO",
      settling_exchange,
      max_overshoot_ns,
      mean_offset,
      stddev,
      steady_state_count,
      step_injected ? "YES" : "NO",
      recovery_exchange), UVM_LOW)

    // ---------------------------------------------------------------
    // End-of-test assertions
    // ---------------------------------------------------------------
    if (!converged)
      `uvm_error("SB_PTP", $sformatf(
        "Servo did NOT converge within %0d exchanges", total_exchanges))

    if (converged && settling_exchange > cfg.max_settling_exchanges)
      `uvm_error("SB_PTP", $sformatf(
        "Settling time (%0d exchanges) exceeds budget (%0d)",
        settling_exchange, cfg.max_settling_exchanges))

    if (converged && steady_state_count > 0) begin
      real abs_mean = (mean_offset < 0.0) ? -mean_offset : mean_offset;
      if (abs_mean > $itor(cfg.convergence_threshold_ns))
        `uvm_error("SB_PTP", $sformatf(
          "Steady-state mean offset (%.3f ns) exceeds threshold (%0d ns)",
          mean_offset, cfg.convergence_threshold_ns))
    end

    if (step_injected && !recovered)
      `uvm_error("SB_PTP", "Servo did NOT recover from step change")

  endfunction

endclass

`endif // GUARD_PTP_SYNC_SCOREBOARD_SV
