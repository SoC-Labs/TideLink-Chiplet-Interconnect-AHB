///////////////////////////////////////////////////////////////////////////////
// test_top_mixed_traffic.sv — Mix TideLink FIFO + AHB passthrough traffic
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_MIXED_TRAFFIC_SV
`define GUARD_TEST_TOP_MIXED_TRAFFIC_SV

class test_top_mixed_traffic extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_mixed_traffic)

  function new(string name = "test_top_mixed_traffic", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 5_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Mixed Traffic ===", UVM_LOW)

    init_system();

    // Simultaneously drive TideLink FIFO + AHB passthrough
    fork
      // TideLink FIFO: A->B
      begin
        for (int p = 0; p < 3; p++) begin
          pkt_data = new[4];
          for (int w = 0; w < 4; w++)
            pkt_data[w] = 32'hF1F0_0000 | (p << 8) | w;
          write_packet(SIDE_A, pkt_data);
        end
      end

      // TideLink FIFO: B->A
      begin
        for (int p = 0; p < 3; p++) begin
          pkt_data = new[4];
          for (int w = 0; w < 4; w++)
            pkt_data[w] = 32'hF2F0_0000 | (p << 8) | w;
          write_packet(SIDE_B, pkt_data);
        end
      end

      // AHB passthrough: A SUB writes
      begin
        top_sys_ahb_sub_write_sequence wr_seq;
        for (int i = 0; i < 3; i++) begin
          wr_seq = top_sys_ahb_sub_write_sequence::type_id::create("wr_seq");
          wr_seq.addr = 32'h0000_1000 + (i * 4);
          wr_seq.data = 32'hABCD_0000 | i;
          wr_seq.start(env.a_sub_ahb_sys_env.master[0].sequencer);
        end
      end
    join

    repeat (phy_transit_wait * 3) @(posedge tb_if.clk);

    for (int p = 0; p < 3; p++) begin
      read_packet(SIDE_B, 4, read_data);
      read_packet(SIDE_A, 4, read_data);
    end

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    `uvm_info("TEST", "Mixed traffic test complete.", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif
