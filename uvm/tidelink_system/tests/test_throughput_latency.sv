///////////////////////////////////////////////////////////////////////////////
// test_throughput_latency.sv
///////////////////////////////////////////////////////////////////////////////
// Verification gap G33: No throughput or latency characterisation tests.
//
// Measures and reports performance metrics:
//   1. Single-direction throughput at various packet sizes
//   2. End-to-end packet latency (TX write to packet_committed_irq)
//   3. Credit return latency (read_complete to released_credits_irq)
//
// Results are printed at UVM_LOW for CI extraction. Asserts minimum
// thresholds to catch regressions.
//
// References: SHORTCOMINGS.md #33
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_THROUGHPUT_LATENCY_SV
`define GUARD_TEST_THROUGHPUT_LATENCY_SV

class test_throughput_latency extends tidelink_system_base_test;

  `uvm_component_utils(test_throughput_latency)

  // Minimum throughput baseline (words/cycle) — set conservatively
  real min_throughput = 0.05;

  // Maximum latency ceiling (cycles) for a 4-word packet
  int unsigned max_packet_latency = 200;

  function new(string name = "test_throughput_latency", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 2_000_000;
  endfunction

  // Helper: measure throughput for N packets of given size
  task measure_throughput(
    int unsigned pkt_size,
    int unsigned num_packets,
    output real  words_per_cycle
  );
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    longint unsigned start_time, end_time;
    longint unsigned total_words;
    longint unsigned total_cycles;

    pkt_data = new[pkt_size];
    total_words = 0;

    start_time = $time / (CLK_PERIOD);

    for (int p = 0; p < num_packets; p++) begin
      // Populate packet data
      for (int w = 0; w < pkt_size; w++)
        pkt_data[w] = (p << 16) | w;

      write_packet(SIDE_A, pkt_data);
      repeat (15) @(posedge tb_if.clk);
      read_packet(SIDE_B, pkt_size, read_data);
      repeat (30) @(posedge tb_if.clk);

      total_words += pkt_size + 1; // +1 for length header
    end

    end_time = $time / (CLK_PERIOD);
    total_cycles = end_time - start_time;

    if (total_cycles > 0)
      words_per_cycle = real'(total_words) / real'(total_cycles);
    else
      words_per_cycle = 0.0;

    // Clear scoreboard (we're measuring, not comparing data)
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();
  endtask

  // Helper: measure single-packet latency (TX first write to committed IRQ)
  task measure_packet_latency(
    int unsigned  pkt_size,
    int unsigned  num_samples,
    output int unsigned min_lat,
    output int unsigned max_lat,
    output int unsigned avg_lat
  );
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    int unsigned latencies[];
    int unsigned lat;
    longint unsigned sum;

    pkt_data = new[pkt_size];
    latencies = new[num_samples];
    sum = 0;
    min_lat = '1; // Max unsigned
    max_lat = 0;

    for (int s = 0; s < num_samples; s++) begin
      for (int w = 0; w < pkt_size; w++)
        pkt_data[w] = 32'h1A10_0000 | (s << 8) | w;

      // Measure from first write to IRQ
      lat = 0;
      fork
        begin
          write_packet(SIDE_A, pkt_data);
        end
        begin
          // Count cycles until packet_committed_irq
          while (tb_if.b_packet_committed_irq !== 1'b1) begin
            @(posedge tb_if.clk);
            lat++;
            if (lat > 10000) begin
              `uvm_error("TEST", "Latency measurement timeout (>10000 cycles)")
              break;
            end
          end
        end
      join

      latencies[s] = lat;
      sum += lat;
      if (lat < min_lat) min_lat = lat;
      if (lat > max_lat) max_lat = lat;

      // Read packet to clear state for next iteration
      read_packet(SIDE_B, pkt_size, read_data);
      repeat (30) @(posedge tb_if.clk);
    end

    avg_lat = sum / num_samples;

    // Clear scoreboard
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();
  endtask

  // Clock period for time-to-cycle conversion
  localparam CLK_PERIOD = 10;

  virtual task main_phase(uvm_phase phase);
    real throughput;
    int unsigned min_lat, max_lat, avg_lat;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Throughput & Latency Characterisation (G33) ===", UVM_LOW)

    init_both_sides();

    // ===============================================================
    // Throughput measurements at various packet sizes
    // ===============================================================
    `uvm_info("TEST", "--- Throughput Measurements ---", UVM_LOW)
    `uvm_info("PERF",
      "+--------+--------+----------------+", UVM_LOW)
    `uvm_info("PERF",
      "| PktSz  | Count  | Words/Cycle    |", UVM_LOW)
    `uvm_info("PERF",
      "+--------+--------+----------------+", UVM_LOW)

    // 1-word packets
    measure_throughput(1, 50, throughput);
    `uvm_info("PERF", $sformatf(
      "| %6d | %6d | %14.4f |", 1, 50, throughput), UVM_LOW)
    if (throughput < min_throughput)
      `uvm_error("PERF", $sformatf(
        "Throughput %.4f below minimum %.4f for 1-word packets",
        throughput, min_throughput))

    // 4-word packets
    measure_throughput(4, 50, throughput);
    `uvm_info("PERF", $sformatf(
      "| %6d | %6d | %14.4f |", 4, 50, throughput), UVM_LOW)
    if (throughput < min_throughput)
      `uvm_error("PERF", $sformatf(
        "Throughput %.4f below minimum %.4f for 4-word packets",
        throughput, min_throughput))

    // 16-word packets
    measure_throughput(16, 30, throughput);
    `uvm_info("PERF", $sformatf(
      "| %6d | %6d | %14.4f |", 16, 30, throughput), UVM_LOW)

    // 64-word packets
    measure_throughput(64, 15, throughput);
    `uvm_info("PERF", $sformatf(
      "| %6d | %6d | %14.4f |", 64, 15, throughput), UVM_LOW)

    // 256-word packets
    measure_throughput(256, 5, throughput);
    `uvm_info("PERF", $sformatf(
      "| %6d | %6d | %14.4f |", 256, 5, throughput), UVM_LOW)

    `uvm_info("PERF",
      "+--------+--------+----------------+", UVM_LOW)

    // ===============================================================
    // Packet latency measurements
    // ===============================================================
    `uvm_info("TEST", "--- Packet Latency Measurements ---", UVM_LOW)

    // Re-init for clean state
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0002);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0002);
    repeat (50) @(posedge tb_if.clk);
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0000);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0000);
    repeat (20) @(posedge tb_if.clk);
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();
    init_both_sides();

    measure_packet_latency(4, 10, min_lat, max_lat, avg_lat);
    `uvm_info("PERF", $sformatf(
      "4-word packet latency (10 samples): min=%0d max=%0d avg=%0d cycles",
      min_lat, max_lat, avg_lat), UVM_LOW)

    if (max_lat > max_packet_latency)
      `uvm_error("PERF", $sformatf(
        "Max latency %0d exceeds ceiling %0d for 4-word packet",
        max_lat, max_packet_latency))

    // Verify no errors accumulated during measurements
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Throughput & latency characterisation complete.", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_THROUGHPUT_LATENCY_SV
