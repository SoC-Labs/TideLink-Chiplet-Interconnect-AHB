///////////////////////////////////////////////////////////////////////////////
// test_top_single_packet.sv — Single packet A->B through full Wlink path
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_SINGLE_PACKET_SV
`define GUARD_TEST_TOP_SINGLE_PACKET_SV

class test_top_single_packet extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_single_packet)

  function new(string name = "test_top_single_packet", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] reg_data;
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Single Packet A->B ===", UVM_LOW)

    // Full system init: Wlink + TideLink
    init_system();

    // Check initial credit count on B
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B initial CREDIT_COUNT = %0d", reg_data), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", $sformatf("Expected B CREDIT_COUNT=%0d, got %0d",
        MAX_CREDITS, reg_data))

    // Write 4-word packet from A TX aperture
    pkt_data = new[4];
    pkt_data[0] = 32'hDEAD_BEEF;
    pkt_data[1] = 32'hCAFE_BABE;
    pkt_data[2] = 32'h1234_5678;
    pkt_data[3] = 32'h9ABC_DEF0;
    write_packet(SIDE_A, pkt_data);

    // Wait for packet to traverse: TX -> FC adapter -> Wlink -> PHY -> Wlink -> FC -> FIFO
    repeat (200) @(posedge tb_if.clk);

    // Check B received the packet
    read_cfg_reg(SIDE_B, REG_STATUS, reg_data);
    `uvm_info("TEST", $sformatf("B STATUS = 0x%08h", reg_data), UVM_LOW)

    // Check B's credit count decreased
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after write = %0d", reg_data), UVM_LOW)

    // Read packet from B's FIFO
    read_packet(SIDE_B, 4, read_data);

    // Wait for credit release via Wlink sideband
    repeat (200) @(posedge tb_if.clk);

    // Verify data
    env.sb.compare_a2b_data();

    // Check credit recovery
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after read = %0d", reg_data), UVM_LOW)

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
