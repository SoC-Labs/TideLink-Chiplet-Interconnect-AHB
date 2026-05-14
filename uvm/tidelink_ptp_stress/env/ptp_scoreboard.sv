///////////////////////////////////////////////////////////////////////////////
// ptp_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// PTP delay statistics scoreboard. Receives (t1,t2,t3,t4) timestamp tuples
// from analysis ports and computes forward delay, reverse delay, round-trip,
// and asymmetry. Tracks running mean, variance, min/max and builds a
// histogram of delay values. Prints end-of-test report and asserts no
// packets were lost.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SCOREBOARD_SV
`define GUARD_PTP_SCOREBOARD_SV

// Timestamp tuple transaction
class ptp_timestamp_tuple extends uvm_sequence_item;

  `uvm_object_utils(ptp_timestamp_tuple)

  // Timestamps in nanoseconds (64-bit to hold seconds*1e9 + ns)
  bit [63:0] t1;  // TX timestamp on Side A (SYNC departure)
  bit [63:0] t2;  // RX timestamp on Side B (SYNC arrival)
  bit [63:0] t3;  // TX timestamp on Side B (DELAY_REQ departure)
  bit [63:0] t4;  // RX timestamp on Side A (DELAY_REQ arrival)

  function new(string name = "ptp_timestamp_tuple");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("t1=%0d t2=%0d t3=%0d t4=%0d", t1, t2, t3, t4);
  endfunction

endclass

`uvm_analysis_imp_decl(_ptp_timestamp)

class ptp_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(ptp_scoreboard)

  // Analysis export for timestamp tuples
  uvm_analysis_imp_ptp_timestamp #(ptp_timestamp_tuple, ptp_scoreboard) ts_export;

  // Expected vs received exchange count
  int unsigned expected_exchanges;
  int unsigned received_exchanges;

  // Forward delay (t2 - t1) statistics
  real fwd_sum, fwd_sum_sq;
  real fwd_min, fwd_max;

  // Reverse delay (t4 - t3) statistics
  real rev_sum, rev_sum_sq;
  real rev_min, rev_max;

  // Round-trip and asymmetry
  real rtt_sum, rtt_max;
  real asym_sum, asym_max;

  // Histogram: forward delay in clock-cycle bins (index = delay cycles)
  int unsigned fwd_histogram[int unsigned];
  int unsigned rev_histogram[int unsigned];

  function new(string name = "ptp_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ts_export = new("ts_export", this);
    fwd_min = 1e18;
    fwd_max = 0;
    rev_min = 1e18;
    rev_max = 0;
    rtt_max = 0;
    asym_max = 0;
  endfunction

  virtual function void write_ptp_timestamp(ptp_timestamp_tuple t);
    real fwd_delay, rev_delay, rtt, asym;

    received_exchanges++;

    // Forward delay: t2 - t1 (SYNC path A->B)
    fwd_delay = real'(t.t2) - real'(t.t1);
    // Reverse delay: t4 - t3 (DELAY_REQ path B->A)
    rev_delay = real'(t.t4) - real'(t.t3);
    // Round-trip time
    rtt = fwd_delay + rev_delay;
    // Asymmetry
    asym = fwd_delay - rev_delay;
    if (asym < 0) asym = -asym;

    // Forward stats
    fwd_sum    += fwd_delay;
    fwd_sum_sq += fwd_delay * fwd_delay;
    if (fwd_delay < fwd_min) fwd_min = fwd_delay;
    if (fwd_delay > fwd_max) fwd_max = fwd_delay;

    // Reverse stats
    rev_sum    += rev_delay;
    rev_sum_sq += rev_delay * rev_delay;
    if (rev_delay < rev_min) rev_min = rev_delay;
    if (rev_delay > rev_max) rev_max = rev_delay;

    // RTT / asymmetry
    rtt_sum += rtt;
    if (rtt > rtt_max) rtt_max = rtt;
    asym_sum += asym;
    if (asym > asym_max) asym_max = asym;

    // Histogram (integer bin = delay in nanoseconds)
    begin
      int unsigned fwd_bin = int'(fwd_delay);
      int unsigned rev_bin = int'(rev_delay);
      if (fwd_histogram.exists(fwd_bin))
        fwd_histogram[fwd_bin]++;
      else
        fwd_histogram[fwd_bin] = 1;
      if (rev_histogram.exists(rev_bin))
        rev_histogram[rev_bin]++;
      else
        rev_histogram[rev_bin] = 1;
    end

    `uvm_info("PTP_SB", $sformatf(
      "Exchange #%0d: fwd=%0.0f rev=%0.0f rtt=%0.0f asym=%0.0f",
      received_exchanges, fwd_delay, rev_delay, rtt, asym), UVM_HIGH)
  endfunction

  // -------------------------------------------------------------------
  // Report Phase
  // -------------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    real fwd_mean, fwd_var, rev_mean, rev_var;
    real rtt_mean, asym_mean;
    int unsigned bin_key;
    string hist_str;

    if (received_exchanges == 0) begin
      `uvm_warning("PTP_SB", "No PTP exchanges received.")
      return;
    end

    // Compute statistics
    fwd_mean = fwd_sum / real'(received_exchanges);
    fwd_var  = (fwd_sum_sq / real'(received_exchanges)) - (fwd_mean * fwd_mean);

    rev_mean = rev_sum / real'(received_exchanges);
    rev_var  = (rev_sum_sq / real'(received_exchanges)) - (rev_mean * rev_mean);

    rtt_mean  = rtt_sum / real'(received_exchanges);
    asym_mean = asym_sum / real'(received_exchanges);

    // Build histogram string (forward delay)
    hist_str = "\n  Forward Delay Histogram (ns -> count):\n";
    if (fwd_histogram.first(bin_key)) begin
      do begin
        hist_str = {hist_str, $sformatf("    %5d ns : %0d\n", bin_key, fwd_histogram[bin_key])};
      end while (fwd_histogram.next(bin_key));
    end

    `uvm_info("PTP_SB_REPORT", $sformatf(
      "\n============ PTP Stress Scoreboard Report ============\n" +
      "  Total exchanges:        %0d / %0d expected\n" +
      "\n  Forward Delay (A->B):\n" +
      "    Mean:     %0.2f ns\n" +
      "    Variance: %0.2f ns^2\n" +
      "    Min:      %0.0f ns\n" +
      "    Max:      %0.0f ns\n" +
      "\n  Reverse Delay (B->A):\n" +
      "    Mean:     %0.2f ns\n" +
      "    Variance: %0.2f ns^2\n" +
      "    Min:      %0.0f ns\n" +
      "    Max:      %0.0f ns\n" +
      "\n  Round-Trip Time:\n" +
      "    Mean:     %0.2f ns\n" +
      "    Max:      %0.0f ns\n" +
      "\n  Asymmetry (|fwd - rev|):\n" +
      "    Mean:     %0.2f ns\n" +
      "    Max:      %0.0f ns\n" +
      "%s" +
      "======================================================",
      received_exchanges, expected_exchanges,
      fwd_mean, fwd_var, fwd_min, fwd_max,
      rev_mean, rev_var, rev_min, rev_max,
      rtt_mean, rtt_max,
      asym_mean, asym_max,
      hist_str), UVM_LOW)

    // Check no exchanges lost
    if (received_exchanges != expected_exchanges)
      `uvm_error("PTP_SB", $sformatf(
        "Exchange count mismatch: expected %0d, received %0d",
        expected_exchanges, received_exchanges))

  endfunction

endclass

`endif // GUARD_PTP_SCOREBOARD_SV
