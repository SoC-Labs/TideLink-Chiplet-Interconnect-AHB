///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// PTP chain scoreboard for tracking per-hop convergence and chain-level
// lock propagation. Monitors hop A<->B and hop B<->C independently and
// reports settling time, steady-state accuracy, and cascade metrics.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_SCOREBOARD_SV
`define GUARD_TIDELINK_PTP_CHAIN_SCOREBOARD_SV

class tidelink_ptp_chain_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(tidelink_ptp_chain_scoreboard)

  // ---------------------------------------------------------------
  // Per-exchange record
  // ---------------------------------------------------------------
  typedef struct {
    int unsigned exchange_id;
    real         offset_ns;
    real         delay_ns;
  } exchange_record_t;

  // ---------------------------------------------------------------
  // Per-hop exchange queues
  // ---------------------------------------------------------------
  exchange_record_t hop_ab_records[$];
  exchange_record_t hop_bc_records[$];

  // ---------------------------------------------------------------
  // Per-hop metrics
  // ---------------------------------------------------------------
  int unsigned hop_ab_settling_exchange;
  real         hop_ab_ss_mean;
  real         hop_ab_ss_stddev;

  int unsigned hop_bc_settling_exchange;
  real         hop_bc_ss_mean;
  real         hop_bc_ss_stddev;

  // ---------------------------------------------------------------
  // Chain-level metrics
  // ---------------------------------------------------------------
  int unsigned cascade_settling_exchange;
  int unsigned b_lock_exchange;
  int unsigned c_lock_exchange;
  int unsigned lock_propagation_delay;

  // Lock flags
  bit b_locked;
  bit c_locked;

  // Configuration handle
  tidelink_ptp_chain_config cfg;

  function new(string name = "tidelink_ptp_chain_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(tidelink_ptp_chain_config)::get(this, "", "ptp_chain_cfg", cfg))
      cfg = tidelink_ptp_chain_config::type_id::create("cfg");
  endfunction

  // ---------------------------------------------------------------
  // Record a hop A<->B exchange
  // ---------------------------------------------------------------
  function void record_hop_ab_exchange(int unsigned id, real offset, real delay);
    exchange_record_t rec;
    rec.exchange_id = id;
    rec.offset_ns   = offset;
    rec.delay_ns    = delay;
    hop_ab_records.push_back(rec);
    `uvm_info("SB_HOP_AB", $sformatf("Exchange %0d: offset=%.3f ns, delay=%.3f ns",
      id, offset, delay), UVM_HIGH)
  endfunction

  // ---------------------------------------------------------------
  // Record a hop B<->C exchange
  // ---------------------------------------------------------------
  function void record_hop_bc_exchange(int unsigned id, real offset, real delay);
    exchange_record_t rec;
    rec.exchange_id = id;
    rec.offset_ns   = offset;
    rec.delay_ns    = delay;
    hop_bc_records.push_back(rec);
    `uvm_info("SB_HOP_BC", $sformatf("Exchange %0d: offset=%.3f ns, delay=%.3f ns",
      id, offset, delay), UVM_HIGH)
  endfunction

  // ---------------------------------------------------------------
  // Mark lock events (called from test sequences)
  // ---------------------------------------------------------------
  function void mark_b_locked(int unsigned exchange_id);
    if (!b_locked) begin
      b_locked = 1;
      b_lock_exchange = exchange_id;
      `uvm_info("SB_LOCK", $sformatf("Side B locked at exchange %0d", exchange_id), UVM_MEDIUM)
    end
  endfunction

  function void mark_c_locked(int unsigned exchange_id);
    if (!c_locked) begin
      c_locked = 1;
      c_lock_exchange = exchange_id;
      `uvm_info("SB_LOCK", $sformatf("Side C locked at exchange %0d", exchange_id), UVM_MEDIUM)
      if (b_locked) begin
        lock_propagation_delay = c_lock_exchange - b_lock_exchange;
        cascade_settling_exchange = c_lock_exchange;
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // Compute steady-state statistics for a hop
  // ---------------------------------------------------------------
  function void compute_hop_stats(
    input  exchange_record_t records[$],
    input  real              threshold,
    output int unsigned      settling_exchange,
    output real              ss_mean,
    output real              ss_stddev
  );
    int unsigned n;
    real sum, sum_sq, val;
    int  converged_idx;

    settling_exchange = 0;
    ss_mean   = 0.0;
    ss_stddev = 0.0;

    if (records.size() == 0) return;

    // Find first exchange where |offset| < threshold and stays below
    converged_idx = -1;
    for (int i = records.size() - 1; i >= 0; i--) begin
      if (records[i].offset_ns > threshold || records[i].offset_ns < -threshold) begin
        converged_idx = i + 1;
        break;
      end
    end
    if (converged_idx == -1) converged_idx = 0;
    settling_exchange = (converged_idx < records.size()) ?
                        records[converged_idx].exchange_id : 0;

    // Compute mean and stddev of converged region
    n = 0; sum = 0.0; sum_sq = 0.0;
    for (int i = converged_idx; i < records.size(); i++) begin
      val = records[i].offset_ns;
      sum += val;
      sum_sq += val * val;
      n++;
    end
    if (n > 0) begin
      ss_mean = sum / n;
      if (n > 1)
        ss_stddev = $sqrt((sum_sq - (sum * sum) / n) / (n - 1));
    end
  endfunction

  // ---------------------------------------------------------------
  // Report phase
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    real threshold;
    threshold = real'(cfg.convergence_threshold_ns);

    // Compute per-hop statistics
    compute_hop_stats(hop_ab_records, threshold,
                      hop_ab_settling_exchange, hop_ab_ss_mean, hop_ab_ss_stddev);
    compute_hop_stats(hop_bc_records, threshold,
                      hop_bc_settling_exchange, hop_bc_ss_mean, hop_bc_ss_stddev);

    `uvm_info("SB_REPORT", $sformatf(
      "\n---------- PTP Chain Scoreboard Summary ----------\n" +
      "  Hop A<->B:\n" +
      "    Total exchanges:     %0d\n" +
      "    Settling exchange:   %0d\n" +
      "    SS mean offset:      %.3f ns\n" +
      "    SS stddev:           %.3f ns\n" +
      "  Hop B<->C:\n" +
      "    Total exchanges:     %0d\n" +
      "    Settling exchange:   %0d\n" +
      "    SS mean offset:      %.3f ns\n" +
      "    SS stddev:           %.3f ns\n" +
      "  Chain Metrics:\n" +
      "    B lock exchange:     %0d\n" +
      "    C lock exchange:     %0d\n" +
      "    Lock propagation:    %0d exchanges\n" +
      "    Cascade settling:    %0d\n" +
      "---------------------------------------------------",
      hop_ab_records.size(), hop_ab_settling_exchange,
      hop_ab_ss_mean, hop_ab_ss_stddev,
      hop_bc_records.size(), hop_bc_settling_exchange,
      hop_bc_ss_mean, hop_bc_ss_stddev,
      b_lock_exchange, c_lock_exchange,
      lock_propagation_delay, cascade_settling_exchange), UVM_LOW)

    // Assert convergence
    if (hop_ab_records.size() > 0 && hop_ab_settling_exchange == 0 &&
        hop_ab_records[$].offset_ns > threshold)
      `uvm_error("SB_REPORT", "Hop A<->B did not converge within threshold")

    if (hop_bc_records.size() > 0 && hop_bc_settling_exchange == 0 &&
        hop_bc_records[$].offset_ns > threshold)
      `uvm_error("SB_REPORT", "Hop B<->C did not converge within threshold")

    if (hop_ab_records.size() > 0 && hop_bc_records.size() > 0 && !c_locked)
      `uvm_error("SB_REPORT", "Chain did not achieve full cascade lock")
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_CHAIN_SCOREBOARD_SV
