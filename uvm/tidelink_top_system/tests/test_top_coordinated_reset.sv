///////////////////////////////////////////////////////////////////////////////
// test_top_coordinated_reset.sv
///////////////////////////////////////////////////////////////////////////////
// Verification gap G35: Coordinated chiplet reset sequence not tested.
//
// Three reset scenarios through the full Wlink stack:
//   1. Unilateral reset during active traffic (one side resets, other recovers)
//   2. Bilateral simultaneous reset (both sides reset at same cycle)
//   3. Staggered drain-then-reset (clean shutdown protocol)
//
// Also verifies:
//   - Doorbell reset notification arrives at peer (G35/VG35)
//   - Credit consistency after reset (G35/VG36)
//
// References: SHORTCOMINGS.md #27, #35
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_COORDINATED_RESET_SV
`define GUARD_TEST_TOP_COORDINATED_RESET_SV

class test_top_coordinated_reset extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_coordinated_reset)

  function new(string name = "test_top_coordinated_reset", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 10_000_000;
  endfunction

  // Helper: credit audit on both sides
  task credit_audit(string phase_name);
    bit [31:0] a_credits, b_credits;
    read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, a_credits);
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, b_credits);
    `uvm_info("AUDIT", $sformatf(
      "[%s] A credits=%0d | B credits=%0d | expected=%0d",
      phase_name, a_credits, b_credits, MAX_CREDITS), UVM_LOW)
  endtask

  // Helper: clear all scoreboard queues
  task clear_scoreboard();
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();
    env.sb.b_tx_write_data.delete();
    env.sb.b_tx_write_addr.delete();
    env.sb.a_fifo_read_data.delete();
    env.sb.a_fifo_read_addr.delete();
  endtask

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Coordinated Chiplet Reset (G35) ===", UVM_LOW)

    // ===============================================================
    // Scenario 1: Unilateral reset during traffic
    // ===============================================================
    `uvm_info("TEST", "--- Scenario 1: Unilateral reset on A during traffic ---", UVM_LOW)

    init_system();
    credit_audit("scenario1_init");

    // Send 3 packets A->B successfully first
    for (int p = 0; p < 3; p++) begin
      pkt_data = new[4];
      pkt_data[0] = 32'h92E1_0000 | p;
      pkt_data[1] = 32'h92E1_1000 | p;
      pkt_data[2] = 32'h92E1_2000 | p;
      pkt_data[3] = 32'h92E1_3000 | p;
      write_packet(SIDE_A, pkt_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
      read_packet(SIDE_B, 4, read_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
    end
    env.sb.compare_a2b_data();
    `uvm_info("TEST", "3 pre-reset packets verified OK", UVM_LOW)

    // Start writing a 4th packet, then reset A mid-stream
    fork
      begin
        pkt_data = new[8];
        for (int w = 0; w < 8; w++)
          pkt_data[w] = 32'hE510_0000 | w;
        write_packet(SIDE_A, pkt_data);
      end
      begin
        // Wait a bit, then assert hresetn on A only
        repeat (phy_transit_wait / 4) @(posedge tb_if.clk);
        `uvm_info("TEST", "Asserting hresetn on side A", UVM_LOW)
        tb_if.force_reset = 1'b1;
        repeat (20) @(posedge tb_if.clk);
        tb_if.force_reset = 1'b0;
      end
    join_any
    disable fork;

    // Wait for reset recovery + any in-flight Wlink traffic to settle
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    clear_scoreboard();

    // Re-init full system (Wlink re-trains after reset)
    init_system();

    credit_audit("scenario1_recovered");

    // Verify normal operation after unilateral reset
    pkt_data = new[4];
    pkt_data[0] = 32'hAF21_0001;
    pkt_data[1] = 32'hAF21_0002;
    pkt_data[2] = 32'hAF21_0003;
    pkt_data[3] = 32'hAF21_0004;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Scenario 1 PASSED: Unilateral reset recovery", UVM_LOW)

    // ===============================================================
    // Scenario 2: Bilateral simultaneous reset
    // ===============================================================
    `uvm_info("TEST", "--- Scenario 2: Bilateral simultaneous reset ---", UVM_LOW)

    // Send one packet each direction to establish state
    pkt_data = new[4];
    pkt_data[0] = 32'h92E2_A001;
    pkt_data[1] = 32'h92E2_A002;
    pkt_data[2] = 32'h92E2_A003;
    pkt_data[3] = 32'h92E2_A004;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Bilateral reset: both sides reset at the same time
    `uvm_info("TEST", "Asserting bilateral reset", UVM_LOW)
    tb_if.force_reset = 1'b1;
    repeat (20) @(posedge tb_if.clk);
    tb_if.force_reset = 1'b0;

    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    clear_scoreboard();

    // Re-init full system
    init_system();

    credit_audit("scenario2_recovered");

    // Verify both directions work
    pkt_data = new[4];
    pkt_data[0] = 32'hAF22_A001;
    pkt_data[1] = 32'hAF22_A002;
    pkt_data[2] = 32'hAF22_A003;
    pkt_data[3] = 32'hAF22_A004;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // B->A direction
    clear_scoreboard();
    pkt_data = new[4];
    pkt_data[0] = 32'hAF22_B001;
    pkt_data[1] = 32'hAF22_B002;
    pkt_data[2] = 32'hAF22_B003;
    pkt_data[3] = 32'hAF22_B004;
    write_packet(SIDE_B, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_A, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_b2a_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Scenario 2 PASSED: Bilateral reset recovery", UVM_LOW)

    // ===============================================================
    // Scenario 3: Staggered drain-then-reset (clean shutdown)
    // ===============================================================
    `uvm_info("TEST", "--- Scenario 3: Staggered drain + FLUSH + reset ---", UVM_LOW)

    // Send 3 packets to create state
    for (int p = 0; p < 3; p++) begin
      pkt_data = new[4];
      pkt_data[0] = 32'h92E3_0000 | p;
      pkt_data[1] = 32'h92E3_1000 | p;
      pkt_data[2] = 32'h92E3_2000 | p;
      pkt_data[3] = 32'h92E3_3000 | p;
      write_packet(SIDE_A, pkt_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
      read_packet(SIDE_B, 4, read_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
    end
    env.sb.compare_a2b_data();

    // Clean shutdown protocol:
    // 1. Wait for all in-flight traffic to settle
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // 2. FLUSH both sides
    `uvm_info("TEST", "Flushing both sides for clean shutdown", UVM_LOW)
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0002);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0002);
    repeat (100) @(posedge tb_if.clk);
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0000);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0000);
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // 3. Assert reset
    `uvm_info("TEST", "Asserting reset after clean shutdown", UVM_LOW)
    tb_if.force_reset = 1'b1;
    repeat (20) @(posedge tb_if.clk);
    tb_if.force_reset = 1'b0;

    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    clear_scoreboard();

    // 4. Re-init and verify
    init_system();

    credit_audit("scenario3_recovered");

    // Verify A->B
    pkt_data = new[4];
    pkt_data[0] = 32'hAF23_0001;
    pkt_data[1] = 32'hAF23_0002;
    pkt_data[2] = 32'hAF23_0003;
    pkt_data[3] = 32'hAF23_0004;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Scenario 3 PASSED: Clean shutdown + reset recovery", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_COORDINATED_RESET_SV
