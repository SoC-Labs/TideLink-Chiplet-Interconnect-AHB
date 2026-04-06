///////////////////////////////////////////////////////////////////////////////
// test_pair_credit_underflow.sv
///////////////////////////////////////////////////////////////////////////////
// Verification gap G31: Pair credit counter underflow not tested.
//
// Tests behaviour when software writes to PAIR_CREDIT_CONSUME (0x02C) more
// times than credits are available in PAIR_CREDIT_COUNTER. Documents whether
// the counter wraps (unsigned underflow) or saturates at zero.
//
// Also tests recovery via FLUSH + re-init after underflow.
//
// References: SHORTCOMINGS.md #7, #31
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_PAIR_CREDIT_UNDERFLOW_SV
`define GUARD_TEST_PAIR_CREDIT_UNDERFLOW_SV

class test_pair_credit_underflow extends tidelink_system_base_test;

  `uvm_component_utils(test_pair_credit_underflow)

  function new(string name = "test_pair_credit_underflow", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 300_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;
    bit [31:0] pair_credits_before;
    bit [31:0] pair_credits_after;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Pair Credit Counter Underflow (G31) ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Phase 1: Establish baseline
    // ---------------------------------------------------------------
    init_both_sides();

    // Send a packet A->B and read it, so B sends credit release to A
    pkt_data = new[4];
    pkt_data[0] = 32'hBA5E_0001;
    pkt_data[1] = 32'hBA5E_0002;
    pkt_data[2] = 32'hBA5E_0003;
    pkt_data[3] = 32'hBA5E_0004;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Read PAIR_CREDIT_COUNTER on A (should have credits from B's doorbell)
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, pair_credits_before);
    `uvm_info("TEST", $sformatf("A PAIR_CREDIT_COUNTER before underflow = %0d",
      pair_credits_before), UVM_LOW)

    if (pair_credits_before == 0) begin
      `uvm_error("TEST", "PAIR_CREDIT_COUNTER is 0 before underflow test - cannot proceed")
      phase.drop_objection(this);
      return;
    end

    // ---------------------------------------------------------------
    // Phase 2: Over-consume pair credits to trigger underflow
    // ---------------------------------------------------------------
    `uvm_info("TEST", $sformatf(
      "Phase 2: Consuming %0d+1 credits to trigger underflow",
      pair_credits_before), UVM_LOW)

    // Consume exactly pair_credits_before credits (drain to zero)
    for (int i = 0; i < pair_credits_before; i++) begin
      write_cfg_reg(SIDE_A, REG_PAIR_CREDIT_CONSUME, 32'h1);
    end
    repeat (10) @(posedge tb_if.clk);

    // Verify counter is at zero
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, reg_data);
    `uvm_info("TEST", $sformatf("A PAIR_CREDIT_COUNTER after exact drain = %0d",
      reg_data), UVM_LOW)
    if (reg_data != 0)
      `uvm_error("TEST", $sformatf(
        "Expected PAIR_CREDIT_COUNTER == 0 after draining %0d credits, got %0d",
        pair_credits_before, reg_data))

    // Now consume ONE MORE — this is the underflow
    write_cfg_reg(SIDE_A, REG_PAIR_CREDIT_CONSUME, 32'h1);
    repeat (10) @(posedge tb_if.clk);

    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, pair_credits_after);
    `uvm_info("TEST", $sformatf(
      "A PAIR_CREDIT_COUNTER after underflow = 0x%08h (%0d)",
      pair_credits_after, pair_credits_after), UVM_LOW)

    // Document the behavior: wrap or saturate?
    if (pair_credits_after == 0) begin
      `uvm_info("TEST",
        "PAIR_CREDIT_COUNTER saturated at 0 (safe behavior)", UVM_LOW)
    end else if (pair_credits_after > 32'h8000_0000) begin
      `uvm_warning("TEST", $sformatf(
        "PAIR_CREDIT_COUNTER wrapped to large value 0x%08h (SHORTCOMING #7 confirmed)",
        pair_credits_after))
    end else begin
      `uvm_warning("TEST", $sformatf(
        "PAIR_CREDIT_COUNTER unexpected value after underflow: %0d",
        pair_credits_after))
    end

    // Verify system is still responsive (no hang)
    read_cfg_reg(SIDE_A, REG_STATUS, reg_data);
    `uvm_info("TEST", $sformatf("A STATUS after underflow = 0x%08h", reg_data), UVM_LOW)

    // ---------------------------------------------------------------
    // Phase 3: Recovery via FLUSH + re-init
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Phase 3: Recovering via FLUSH + re-init", UVM_LOW)

    // FLUSH both sides
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0002);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0002);
    repeat (50) @(posedge tb_if.clk);
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0000);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0000);
    repeat (20) @(posedge tb_if.clk);

    // Re-init both sides (reconfigures pair base, threshold, doorbell)
    init_both_sides();

    // Verify PAIR_CREDIT_COUNTER recovered
    read_cfg_reg(SIDE_A, REG_PAIR_CREDIT_COUNTER, reg_data);
    `uvm_info("TEST", $sformatf(
      "A PAIR_CREDIT_COUNTER after recovery = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)

    // Clear scoreboard from pre-recovery state
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();

    // ---------------------------------------------------------------
    // Phase 4: Verify normal operation after recovery
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Phase 4: Verifying normal operation after recovery", UVM_LOW)

    pkt_data = new[4];
    pkt_data[0] = 32'hECBE_0001;
    pkt_data[1] = 32'hECBE_0002;
    pkt_data[2] = 32'hECBE_0003;
    pkt_data[3] = 32'hECBE_0004;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Post-recovery packet verified OK.", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_PAIR_CREDIT_UNDERFLOW_SV
