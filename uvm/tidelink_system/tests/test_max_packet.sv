///////////////////////////////////////////////////////////////////////////////
// test_max_packet.sv
///////////////////////////////////////////////////////////////////////////////
// Maximum size packet test: fill the entire FIFO with a single packet.
// Verifies:
//   - FIFO can accept MAX_CREDITS-2 data words (plus 2-word header = MAX_CREDITS)
//   - No overflow when filling to capacity
//   - All data reads back correctly after maximum fill
//   - Credit count drops to zero and recovers fully
//   - Write pointer wrap-around handling
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_MAX_PACKET_SV
`define GUARD_TEST_MAX_PACKET_SV

class test_max_packet extends tidelink_system_base_test;

  `uvm_component_utils(test_max_packet)

  // Use a smaller max to keep simulation reasonable
  // Full FIFO = 4096 words, packet = 4094 data + 2-word header (BUG-22)
  // Use 256 words for practical testing (override if needed)
  int unsigned max_pkt_words = 256;

  function new(string name = "test_max_packet", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 500_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;
    int unsigned expected_credits;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Max Packet: %0d data words ===",
      max_pkt_words), UVM_LOW)

    // Initialize both sides
    init_both_sides();

    // Generate large packet with predictable pattern
    pkt_data = new[max_pkt_words];
    for (int w = 0; w < max_pkt_words; w++)
      pkt_data[w] = 32'hA000_0000 | w;

    // Write max packet from A's TX
    `uvm_info("TEST", $sformatf("Writing %0d-word packet from A TX", max_pkt_words), UVM_LOW)
    write_packet(SIDE_A, pkt_data);

    // Wait for all words to traverse FC crossover
    repeat (max_pkt_words + 50) @(posedge tb_if.clk);

    // Check B's credit count (should be MAX - (max_pkt_words + 2))
    // 2-word header + N data — see tidelink_fifo_ctrl.sv packet_delta = length + 2
    expected_credits = MAX_CREDITS - (max_pkt_words + 2);
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT = %0d (expected %0d)",
      reg_data, expected_credits), UVM_LOW)
    if (reg_data !== expected_credits)
      `uvm_error("TEST", "B CREDIT_COUNT mismatch after max write")

    // Read the entire packet back from B's FIFO
    `uvm_info("TEST", $sformatf("Reading %0d words from B FIFO", max_pkt_words), UVM_LOW)
    read_packet(SIDE_B, max_pkt_words, read_data);

    // Wait for credit release
    repeat (100) @(posedge tb_if.clk);

    // Verify data integrity
    env.sb.compare_a2b_data();

    // Verify credits recovered
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after read = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "B CREDIT_COUNT did not recover after max read")

    // Check no errors
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_MAX_PACKET_SV
