///////////////////////////////////////////////////////////////////////////////
// test_top_reset_recovery.sv — Flush and re-init, verify clean operation
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_RESET_RECOVERY_SV
`define GUARD_TEST_TOP_RESET_RECOVERY_SV

class test_top_reset_recovery extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_reset_recovery)

  function new(string name = "test_top_reset_recovery", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 5_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Reset Recovery ===", UVM_LOW)

    // Phase 1: Normal operation — send and receive a packet
    init_system();

    pkt_data = new[4];
    pkt_data[0] = 32'hBEEF_0001;
    pkt_data[1] = 32'hBEEF_0002;
    pkt_data[2] = 32'hBEEF_0003;
    pkt_data[3] = 32'hBEEF_0004;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);

    // Wait for all credit sideband to complete before flush
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // Clear scoreboard queues from Phase 1
    env.sb.compare_a2b_data();

    `uvm_info("TEST", "Pre-reset operation verified.", UVM_LOW)

    // Phase 2: Flush both sides
    // Wait extra to ensure all FC adapter pipeline stages have drained
    // (the FC RX path may have in-flight sideband writes)
    `uvm_info("TEST", "Flushing both sides...", UVM_LOW)

    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0002);  // FLUSH
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0002);

    // Hold flush for a few cycles to ensure all pipeline stages are cleared
    repeat (100) @(posedge tb_if.clk);

    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0000);  // Clear flush
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0000);

    // Wait for any in-flight FC sideband to settle
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // Ring doorbells again to exchange credits
    write_cfg_reg(SIDE_A, REG_DOORBELL, 32'h1);
    write_cfg_reg(SIDE_B, REG_DOORBELL, 32'h1);
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    `uvm_info("TEST", "Flush complete, re-initialized.", UVM_LOW)

    // Phase 3: Post-flush packet — verify clean operation
    // Clear any scoreboard state accumulated during flush/re-init
    env.sb.a_tx_write_data.delete();
    env.sb.a_tx_write_addr.delete();
    env.sb.b_fifo_read_data.delete();
    env.sb.b_fifo_read_addr.delete();

    `uvm_info("TEST", "Post-reset: sending new packet...", UVM_LOW)

    pkt_data = new[4];
    pkt_data[0] = 32'hFACE_0001;
    pkt_data[1] = 32'hFACE_0002;
    pkt_data[2] = 32'hFACE_0003;
    pkt_data[3] = 32'hFACE_0004;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    `uvm_info("TEST", "Post-reset operation verified.", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif
