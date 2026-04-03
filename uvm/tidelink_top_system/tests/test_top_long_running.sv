///////////////////////////////////////////////////////////////////////////////
// test_top_long_running.sv — Multiple packets in both directions
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LONG_RUNNING_SV
`define GUARD_TEST_TOP_LONG_RUNNING_SV

class test_top_long_running extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_long_running)

  function new(string name = "test_top_long_running", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 50_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    int num_packets = 10;
    int pkt_size = 4;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Top Long Running (%0d packets per direction) ===",
      num_packets), UVM_LOW)

    init_system();

    for (int p = 0; p < num_packets; p++) begin
      // Write A->B
      pkt_data = new[pkt_size];
      for (int w = 0; w < pkt_size; w++)
        pkt_data[w] = 32'hA000_0000 | (p << 8) | w;
      write_packet(SIDE_A, pkt_data);

      // Write B->A
      for (int w = 0; w < pkt_size; w++)
        pkt_data[w] = 32'hB000_0000 | (p << 8) | w;
      write_packet(SIDE_B, pkt_data);

      repeat (phy_transit_wait) @(posedge tb_if.clk);

      read_packet(SIDE_B, pkt_size, read_data);
      read_packet(SIDE_A, pkt_size, read_data);

      repeat (phy_transit_wait) @(posedge tb_if.clk);

      if ((p + 1) % 5 == 0) begin
        env.sb.compare_a2b_data();
        env.sb.compare_b2a_data();
        `uvm_info("TEST", $sformatf("Completed %0d/%0d packets", p + 1, num_packets), UVM_LOW)
      end
    end

    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    phase.drop_objection(this);
  endtask

endclass

`endif
