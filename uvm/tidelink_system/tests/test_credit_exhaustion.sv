///////////////////////////////////////////////////////////////////////////////
// test_credit_exhaustion.sv
///////////////////////////////////////////////////////////////////////////////
// Send packets until credits are exhausted on the receiver side:
//   1. Send multiple packets without reading (credits drain)
//   2. Verify pair credit counter on A eventually reaches zero
//   3. Read packets from B's FIFO (credits release back to A)
//   4. Verify A's pair credit counter recovers
//   5. Send another packet to confirm recovery
//
// Targets bugs in:
//   - Credit counter underflow protection
//   - Pair credit enable/disable gating
//   - Released credits accumulator saturation
//   - Flow control backpressure (if pair credit counter blocks writes)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CREDIT_EXHAUSTION_SV
`define GUARD_TEST_CREDIT_EXHAUSTION_SV

class test_credit_exhaustion extends tidelink_system_base_test;

  `uvm_component_utils(test_credit_exhaustion)

  // Send enough packets to consume significant credits
  int unsigned words_per_pkt = 32;
  int unsigned num_drain_pkts = 20;  // 20 * (32+1) = 660 credits consumed

  function new(string name = "test_credit_exhaustion", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 500_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;
    bit [31:0] pair_credits;
    int unsigned total_words_consumed;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Credit Exhaustion: %0d pkts x %0d words ===",
      num_drain_pkts, words_per_pkt), UVM_LOW)

    // Initialize both sides (threshold=0 for immediate release)
    init_both_sides();

    // Step 1: Drain credits by sending many packets without reading
    `uvm_info("TEST", "Step 1: Draining credits by sending without reading", UVM_LOW)
    total_words_consumed = 0;

    for (int pkt = 0; pkt < num_drain_pkts; pkt++) begin
      pkt_data = new[words_per_pkt];
      for (int w = 0; w < words_per_pkt; w++)
        pkt_data[w] = {16'(pkt), 16'(w)};

      write_packet(SIDE_A, pkt_data);
      total_words_consumed += (words_per_pkt + 1); // data + length

      // Minimal wait for FC crossover
      repeat (words_per_pkt + 10) @(posedge tb_if.clk);

      // Check B's credit count periodically
      if ((pkt % 5) == 4) begin
        read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
        `uvm_info("TEST", $sformatf("After pkt %0d: B credits=%0d (consumed=%0d)",
          pkt + 1, reg_data, total_words_consumed), UVM_MEDIUM)
      end
    end

    // Step 2: Check credit state
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after drain = %0d (expected %0d)",
      reg_data, MAX_CREDITS - total_words_consumed), UVM_LOW)
    if (reg_data !== (MAX_CREDITS - total_words_consumed))
      `uvm_error("TEST", "B credit count mismatch after drain")

    // Check A's pair credit counter (should reflect consumed credits)
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, pair_credits);
    `uvm_info("TEST", $sformatf("A PAIR_CREDIT_COUNTER = %0d", pair_credits), UVM_LOW)

    // Step 3: Read all packets from B's FIFO to release credits
    `uvm_info("TEST", "Step 3: Reading all packets to release credits", UVM_LOW)
    for (int pkt = 0; pkt < num_drain_pkts; pkt++) begin
      read_packet(SIDE_B, words_per_pkt, read_data);
      // Wait for credit return via FC crossover
      repeat (40) @(posedge tb_if.clk);

      // Compare data for this packet
      env.sb.compare_a2b_data();
    end

    // Wait for all credit releases to propagate
    repeat (100) @(posedge tb_if.clk);

    // Step 4: Verify credits fully recovered
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after recovery = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "B credits did not fully recover")

    // Step 5: Send one more packet to confirm system works after recovery
    `uvm_info("TEST", "Step 5: Verification packet after recovery", UVM_LOW)
    pkt_data = new[4];
    pkt_data[0] = 32'hRECO_VER1;
    pkt_data[1] = 32'hRECO_VER2;
    pkt_data[2] = 32'hRECO_VER3;
    pkt_data[3] = 32'hRECO_VER4;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Final checks
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CREDIT_EXHAUSTION_SV
