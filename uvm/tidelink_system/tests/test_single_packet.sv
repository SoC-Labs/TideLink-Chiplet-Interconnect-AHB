///////////////////////////////////////////////////////////////////////////////
// test_single_packet.sv
///////////////////////////////////////////////////////////////////////////////
// Single packet A->B: write a 4-word packet from A's TX aperture, verify
// it arrives in B's RX FIFO with correct data, and check that credits are
// consumed on B and released back to A after reading.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_SINGLE_PACKET_SV
`define GUARD_TEST_SINGLE_PACKET_SV

class test_single_packet extends tidelink_system_base_test;

  `uvm_component_utils(test_single_packet)

  function new(string name = "test_single_packet", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] reg_data;
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Single Packet A->B ===", UVM_LOW)

    // Step 1: Initialize both sides
    init_both_sides(32'h4000_0000, 32'h5000_0000, 32'd0, 32'd0);

    // Step 2: Check initial credit count on B (receiver side)
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B initial CREDIT_COUNT = %0d", reg_data), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", $sformatf("Expected B CREDIT_COUNT=%0d, got %0d",
        MAX_CREDITS, reg_data))

    // Step 3: Write 4-word packet from A's TX aperture
    pkt_data = new[4];
    pkt_data[0] = 32'hDEAD_BEEF;
    pkt_data[1] = 32'hCAFE_BABE;
    pkt_data[2] = 32'h1234_5678;
    pkt_data[3] = 32'h9ABC_DEF0;
    write_packet(SIDE_A, pkt_data);

    // Wait for FC crossover delivery
    repeat (30) @(posedge tb_if.clk);

    // Step 4: Check B's packet_committed status
    read_cfg_reg(SIDE_B, REG_STATUS, reg_data);
    `uvm_info("TEST", $sformatf("B STATUS = 0x%08h", reg_data), UVM_LOW)
    if (reg_data[STATUS_PACKET_COMMITTED] !== 1'b1)
      `uvm_error("TEST", "Expected packet_committed bit set in B's STATUS")

    // Step 5: Check B's credit count decreased (5 words: 1 length + 4 data)
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after write = %0d (expected %0d)",
      reg_data, MAX_CREDITS - 5), UVM_LOW)
    if (reg_data !== (MAX_CREDITS - 5))
      `uvm_error("TEST", "B CREDIT_COUNT mismatch after write")

    // Step 6: Read the packet from B's RX FIFO
    read_packet(SIDE_B, 4, read_data);

    // Wait for returner credit release via FC crossover
    repeat (50) @(posedge tb_if.clk);

    // Step 7: Verify data integrity via scoreboard
    env.sb.compare_a2b_data();

    // Step 8: Check B's credit count recovered
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after read = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "B CREDIT_COUNT did not recover after read")

    // Step 9: Check no errors on either side
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_SINGLE_PACKET_SV
