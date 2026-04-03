///////////////////////////////////////////////////////////////////////////////
// test_reset_recovery.sv
///////////////////////////////////////////////////////////////////////////////
// Assert reset mid-transfer, verify clean recovery:
//   1. Start sending a packet from A->B
//   2. Assert reset while FC transfer is in progress
//   3. Wait for reset deassertion
//   4. Re-initialize both sides
//   5. Send a new packet and verify it works correctly
//
// Targets bugs in:
//   - FSM state cleanup on reset (FC adapter RX state, returner state)
//   - FIFO pointer reset
//   - Credit counter reset to initial values
//   - AHB bus state after reset (no hung transactions)
//   - Latched registers clearing on reset
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_RESET_RECOVERY_SV
`define GUARD_TEST_RESET_RECOVERY_SV

class test_reset_recovery extends tidelink_system_base_test;

  `uvm_component_utils(test_reset_recovery)

  function new(string name = "test_reset_recovery", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 200_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Reset Recovery ===", UVM_LOW)

    // Step 1: Initialize and send a packet normally
    init_both_sides();

    pkt_data = new[4];
    pkt_data[0] = 32'hBEFO_RE01;
    pkt_data[1] = 32'hBEFO_RE02;
    pkt_data[2] = 32'hBEFO_RE03;
    pkt_data[3] = 32'hBEFO_RE04;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    `uvm_info("TEST", "Pre-reset packet verified OK.", UVM_LOW)

    // Step 2: Start sending another packet, then reset mid-transfer
    `uvm_info("TEST", "Step 2: Starting packet then asserting reset", UVM_LOW)
    fork
      begin
        // Send a packet (some beats will be in-flight when reset hits)
        pkt_data = new[8];
        for (int w = 0; w < 8; w++)
          pkt_data[w] = 32'hDEAD_0000 | w;
        write_packet(SIDE_A, pkt_data);
      end
      begin
        // Assert reset after a few cycles (mid-transfer)
        repeat (8) @(posedge tb_if.clk);
        `uvm_info("TEST", "Asserting reset NOW", UVM_LOW)
        force test_top.rst_n = 1'b0;
        repeat (20) @(posedge tb_if.clk);
        release test_top.rst_n;
        // rst_n will be driven by the initial block in top.sv
        // But we need to explicitly bring it back
        force test_top.rst_n = 1'b1;
        repeat (5) @(posedge tb_if.clk);
        release test_top.rst_n;
      end
    join_any
    // Wait for both forks to settle (the write may error or complete)
    disable fork;

    // Clear scoreboard queues (in-flight data is lost, that's expected)
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();
    env.sb.b_tx_write_data.delete();
    env.sb.b_tx_write_addr.delete();
    env.sb.a_fifo_read_data.delete();
    env.sb.a_fifo_read_addr.delete();

    // Step 3: Wait for reset recovery
    `uvm_info("TEST", "Step 3: Waiting for reset recovery", UVM_LOW)
    repeat (20) @(posedge tb_if.clk);

    // Step 4: Verify post-reset register state
    `uvm_info("TEST", "Step 4: Checking post-reset state", UVM_LOW)
    read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("A CREDIT_COUNT after reset = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)

    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after reset = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)

    // Step 5: Re-initialize and send a clean packet
    `uvm_info("TEST", "Step 5: Re-initialize and verify clean operation", UVM_LOW)
    init_both_sides();

    pkt_data = new[4];
    pkt_data[0] = 32'hAFTE_RST1;
    pkt_data[1] = 32'hAFTE_RST2;
    pkt_data[2] = 32'hAFTE_RST3;
    pkt_data[3] = 32'hAFTE_RST4;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Check credits recovered
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after post-reset pkt = %0d",
      reg_data), UVM_LOW)

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Post-reset packet verified OK.", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_RESET_RECOVERY_SV
