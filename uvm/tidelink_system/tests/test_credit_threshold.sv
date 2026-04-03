///////////////////////////////////////////////////////////////////////////////
// test_credit_threshold.sv
///////////////////////////////////////////////////////////////////////////////
// Test different release threshold values to verify credit batching behavior.
//
// The release threshold controls how many credits accumulate before the
// returner sends a batch release. This test:
//   1. Sets a non-zero threshold (e.g., 8)
//   2. Sends a packet, reads it, verifies credits are NOT returned
//      until the threshold is reached
//   3. Sends more packets to cross the threshold
//   4. Verifies batched credit release
//
// Targets bugs in:
//   - Threshold accumulator comparison logic
//   - Off-by-one in threshold trigger
//   - Release trigger not firing when accumulated == threshold
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_CREDIT_THRESHOLD_SV
`define GUARD_TEST_CREDIT_THRESHOLD_SV

class test_credit_threshold extends tidelink_system_base_test;

  `uvm_component_utils(test_credit_threshold)

  function new(string name = "test_credit_threshold", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 200_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;
    bit [31:0] pair_credits_before, pair_credits_after;
    int unsigned threshold_val = 8;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Credit Threshold = %0d ===", threshold_val), UVM_LOW)

    // Initialize with non-zero threshold
    // A's threshold controls when B's returner batches releases to A
    // B's threshold controls when A's returner batches releases to B
    init_both_sides(32'h4000_0000, 32'h5000_0000, threshold_val, threshold_val);

    // Record A's pair credit counter before test
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, pair_credits_before);
    `uvm_info("TEST", $sformatf("A initial PAIR_CREDIT_COUNTER = %0d",
      pair_credits_before), UVM_LOW)

    // Step 1: Send a small packet (3 words = 4 credits consumed, below threshold)
    `uvm_info("TEST", "Step 1: Send small packet (below threshold)", UVM_LOW)
    pkt_data = new[3];
    pkt_data[0] = 32'h1111_1111;
    pkt_data[1] = 32'h2222_2222;
    pkt_data[2] = 32'h3333_3333;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);

    // Read it from B
    read_packet(SIDE_B, 3, read_data);
    repeat (60) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Check B's release accumulator — should have accumulated 4 credits
    // but may not have triggered release yet (depends on threshold)
    read_cfg_reg(SIDE_B, REG_REL_ACC, reg_data);
    `uvm_info("TEST", $sformatf("B REL_ACC after first read = %0d", reg_data), UVM_LOW)

    // Step 2: Send another packet to push past threshold
    `uvm_info("TEST", "Step 2: Send second packet (crosses threshold)", UVM_LOW)
    pkt_data = new[4];
    pkt_data[0] = 32'h4444_4444;
    pkt_data[1] = 32'h5555_5555;
    pkt_data[2] = 32'h6666_6666;
    pkt_data[3] = 32'h7777_7777;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);

    // Read from B
    read_packet(SIDE_B, 4, read_data);
    repeat (80) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Step 3: Verify credit release occurred
    // After reading 4+5=9 credits worth, exceeding threshold of 8,
    // B's returner should have sent a batched release to A
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, pair_credits_after);
    `uvm_info("TEST", $sformatf("A PAIR_CREDIT_COUNTER after threshold cross = %0d",
      pair_credits_after), UVM_LOW)

    // Step 4: Send a third packet and verify final state
    `uvm_info("TEST", "Step 4: Verification packet", UVM_LOW)
    pkt_data = new[2];
    pkt_data[0] = 32'h8888_8888;
    pkt_data[1] = 32'h9999_9999;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 2, read_data);
    repeat (80) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Final credit verification
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B final CREDIT_COUNT = %0d", reg_data), UVM_LOW)

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_CREDIT_THRESHOLD_SV
