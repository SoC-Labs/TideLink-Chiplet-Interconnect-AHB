///////////////////////////////////////////////////////////////////////////////
// test_long_running.sv
///////////////////////////////////////////////////////////////////////////////
// Long-running soak test: 1000+ packets in both directions.
// Verifies there are no accumulated errors over sustained operation:
//   - Credit counter drift (accumulated rounding errors)
//   - FIFO pointer wrap-around bugs (only visible after many operations)
//   - Memory leak in scoreboard queues
//   - Slow resource exhaustion
//   - Intermittent timing races
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_LONG_RUNNING_SV
`define GUARD_TEST_LONG_RUNNING_SV

class test_long_running extends tidelink_system_base_test;

  `uvm_component_utils(test_long_running)

  int unsigned num_packets = 500;  // 500 per direction = 1000 total
  int unsigned max_words   = 8;

  function new(string name = "test_long_running", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 5_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;
    int unsigned a_words, b_words;
    int unsigned milestone_interval = 100;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Long Running: %0d packets each direction ===",
      num_packets), UVM_LOW)

    init_both_sides();

    for (int pkt = 0; pkt < num_packets; pkt++) begin
      // Progress reporting at milestones
      if ((pkt % milestone_interval) == 0)
        `uvm_info("TEST", $sformatf("Progress: packet %0d/%0d", pkt, num_packets), UVM_LOW)

      // Vary packet sizes (1-8 words) based on iteration
      a_words = (pkt % max_words) + 1;
      b_words = ((pkt + 3) % max_words) + 1;

      // A->B packet
      pkt_data = new[a_words];
      for (int w = 0; w < a_words; w++)
        pkt_data[w] = {16'(pkt), 16'(w)};
      write_packet(SIDE_A, pkt_data);

      // B->A packet (slightly delayed to create interesting timing)
      pkt_data = new[b_words];
      for (int w = 0; w < b_words; w++)
        pkt_data[w] = {16'(pkt | 16'h8000), 16'(w)};
      write_packet(SIDE_B, pkt_data);

      // Wait for FC crossover
      repeat (20) @(posedge tb_if.clk);

      // Read both FIFOs
      read_packet(SIDE_B, a_words, read_data);
      read_packet(SIDE_A, b_words, read_data);

      // Wait for credit returns
      repeat (40) @(posedge tb_if.clk);

      // Verify at every iteration (catches corruption immediately)
      env.sb.compare_a2b_data();
      env.sb.compare_b2a_data();

      // Periodic credit balance check
      if ((pkt % milestone_interval) == 0) begin
        read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, reg_data);
        if (reg_data !== MAX_CREDITS)
          `uvm_error("TEST", $sformatf("Pkt %0d: A credits=%0d, expected=%0d",
            pkt, reg_data, MAX_CREDITS))

        read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
        if (reg_data !== MAX_CREDITS)
          `uvm_error("TEST", $sformatf("Pkt %0d: B credits=%0d, expected=%0d",
            pkt, reg_data, MAX_CREDITS))

        // Check for accumulated errors
        check_no_errors(SIDE_A);
        check_no_errors(SIDE_B);
      end
    end

    // Final comprehensive check
    `uvm_info("TEST", "Final verification...", UVM_LOW)

    read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("A final CREDIT_COUNT = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "A credits drifted over long run")

    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B final CREDIT_COUNT = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "B credits drifted over long run")

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", $sformatf("Long-running test complete: %0d packets per direction",
      num_packets), UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_LONG_RUNNING_SV
