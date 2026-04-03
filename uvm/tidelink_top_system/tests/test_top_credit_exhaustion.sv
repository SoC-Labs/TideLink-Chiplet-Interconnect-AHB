///////////////////////////////////////////////////////////////////////////////
// test_top_credit_exhaustion.sv — Exhaust credits through Wlink, then drain
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_CREDIT_EXHAUSTION_SV
`define GUARD_TEST_TOP_CREDIT_EXHAUSTION_SV

class test_top_credit_exhaustion extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_credit_exhaustion)

  function new(string name = "test_top_credit_exhaustion", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 10_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    int pkt_size = 4;
    int num_packets = 5;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Credit Exhaustion ===", UVM_LOW)

    init_system();

    // Send packets without reading
    for (int p = 0; p < num_packets; p++) begin
      pkt_data = new[pkt_size];
      for (int w = 0; w < pkt_size; w++)
        pkt_data[w] = (p << 16) | w;
      write_packet(SIDE_A, pkt_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
    end

    // Drain all packets
    for (int p = 0; p < num_packets; p++) begin
      read_packet(SIDE_B, pkt_size, read_data);
    end

    repeat (phy_transit_wait * 2) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    phase.drop_objection(this);
  endtask

endclass

`endif
