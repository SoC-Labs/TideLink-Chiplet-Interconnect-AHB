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
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Single Packet A->B ===", UVM_LOW)

    init_system();

    pkt_data = new[4];
    pkt_data[0] = 32'hDEAD_BEEF;
    pkt_data[1] = 32'hCAFE_BABE;
    pkt_data[2] = 32'h1234_5678;
    pkt_data[3] = 32'h9ABC_DEF0;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
