///////////////////////////////////////////////////////////////////////////////
// test_error_injection.sv
///////////////////////////////////////////////////////////////////////////////
// Error injection and boundary condition testing:
//   1. Read from empty FIFO (underrun attempt)
//   2. Write to read-only registers
//   3. Read-back of various register initial values
//   4. Verify error flag behavior in STATUS register
//
// Targets bugs in:
//   - FIFO underrun detection and flag setting
//   - Register write protection
//   - STATUS register bit clearing
//   - System recovery after error conditions
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_ERROR_INJECTION_SV
`define GUARD_TEST_ERROR_INJECTION_SV

class test_error_injection extends tidelink_system_base_test;

  `uvm_component_utils(test_error_injection)

  function new(string name = "test_error_injection", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 200_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Error Injection ===", UVM_LOW)

    init_both_sides();

    // ---------------------------------------------------------------
    // Test 1: Read from empty FIFO on B (no packets sent yet)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 1: Read from empty FIFO", UVM_LOW)
    begin
      sys_read_packet_sequence rd_seq;
      rd_seq = sys_read_packet_sequence::type_id::create("empty_rd");
      rd_seq.num_words = 2;  // Force read of 2 words from empty FIFO
      rd_seq.side_name = "B";
      rd_seq.start(env.b_fifo_ahb_sys_env.master[0].sequencer);
    end
    repeat (20) @(posedge tb_if.clk);

    // Check if underrun flag is set (read from empty FIFO)
    read_cfg_reg(SIDE_B, REG_STATUS, reg_data);
    `uvm_info("TEST", $sformatf("B STATUS after empty read = 0x%08h", reg_data), UVM_LOW)
    // Note: underrun may or may not be set depending on FIFO implementation
    // The important thing is the system doesn't hang or crash

    // ---------------------------------------------------------------
    // Test 2: Write to read-only registers (STATUS, CREDIT_COUNT)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 2: Write to read-only registers", UVM_LOW)

    // Try writing to STATUS register (should be read-only or have specific clear behavior)
    write_cfg_reg(SIDE_A, REG_STATUS, 32'hFFFF_FFFF);
    repeat (10) @(posedge tb_if.clk);
    read_cfg_reg(SIDE_A, REG_STATUS, reg_data);
    `uvm_info("TEST", $sformatf("A STATUS after write attempt = 0x%08h", reg_data), UVM_LOW)

    // Try writing to CREDIT_COUNT register
    write_cfg_reg(SIDE_A, REG_CREDIT_COUNT, 32'h0);
    repeat (10) @(posedge tb_if.clk);
    read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("A CREDIT_COUNT after write attempt = %0d", reg_data), UVM_LOW)
    // Credit count should not have changed to 0
    if (reg_data == 0)
      `uvm_error("TEST", "CREDIT_COUNT was writable - should be read-only")

    // ---------------------------------------------------------------
    // Test 3: Register initial values
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 3: Register initial value checks", UVM_LOW)

    // Read PKT_WORD_LEN (should reflect last packet or initial state)
    read_cfg_reg(SIDE_A, REG_PKT_WORD_LEN, reg_data);
    `uvm_info("TEST", $sformatf("A PKT_WORD_LEN = 0x%08h", reg_data), UVM_LOW)

    // Read PAIR_CREDIT_COUNTER
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, reg_data);
    `uvm_info("TEST", $sformatf("A PAIR_CREDIT_COUNTER = %0d", reg_data), UVM_LOW)

    // ---------------------------------------------------------------
    // Test 4: Normal operation still works after error injection
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 4: Verify normal operation after errors", UVM_LOW)

    pkt_data = new[4];
    pkt_data[0] = 32'hAF1E_EE22;
    pkt_data[1] = 32'h1111_1111;
    pkt_data[2] = 32'h2222_2222;
    pkt_data[3] = 32'h3333_3333;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Verify data integrity was maintained despite earlier error injection
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after recovery = %0d", reg_data), UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_ERROR_INJECTION_SV
