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

    // Phase 1: Normal operation
    init_system();

    pkt_data = new[4];
    pkt_data[0] = 32'hBEEF_0001;
    pkt_data[1] = 32'hBEEF_0002;
    pkt_data[2] = 32'hBEEF_0003;
    pkt_data[3] = 32'hBEEF_0004;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);
    env.sb.compare_a2b_data();

    `uvm_info("TEST", "Pre-reset operation verified.", UVM_LOW)

    // Phase 2: Flush and re-init
    `uvm_info("TEST", "Flushing both sides...", UVM_LOW)
    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0002);  // FLUSH
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0002);
    repeat (50) @(posedge tb_if.clk);

    write_cfg_reg(SIDE_A, REG_CTRL, 32'h0000_0000);
    write_cfg_reg(SIDE_B, REG_CTRL, 32'h0000_0000);
    repeat (100) @(posedge tb_if.clk);

    // Ring doorbells again
    write_cfg_reg(SIDE_A, REG_DOORBELL, 32'h1);
    write_cfg_reg(SIDE_B, REG_DOORBELL, 32'h1);
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // Phase 3: Post-reset packet
    `uvm_info("TEST", "Post-reset: sending new packet...", UVM_LOW)

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
