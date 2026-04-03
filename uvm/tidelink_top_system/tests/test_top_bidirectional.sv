///////////////////////////////////////////////////////////////////////////////
// test_top_bidirectional.sv — Simultaneous A->B and B->A through Wlink
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_BIDIRECTIONAL_SV
`define GUARD_TEST_TOP_BIDIRECTIONAL_SV

class test_top_bidirectional extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_bidirectional)

  function new(string name = "test_top_bidirectional", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] a_pkt[], b_pkt[];
    bit [31:0] a_read[], b_read[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Bidirectional ===", UVM_LOW)

    init_system();

    a_pkt = new[4];
    a_pkt[0] = 32'hAAAA_1111;
    a_pkt[1] = 32'hAAAA_2222;
    a_pkt[2] = 32'hAAAA_3333;
    a_pkt[3] = 32'hAAAA_4444;

    b_pkt = new[4];
    b_pkt[0] = 32'hBBBB_1111;
    b_pkt[1] = 32'hBBBB_2222;
    b_pkt[2] = 32'hBBBB_3333;
    b_pkt[3] = 32'hBBBB_4444;

    fork
      write_packet(SIDE_A, a_pkt);
      write_packet(SIDE_B, b_pkt);
    join

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    fork
      read_packet(SIDE_B, 4, b_read);
      read_packet(SIDE_A, 4, a_read);
    join

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
