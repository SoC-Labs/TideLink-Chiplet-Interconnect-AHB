///////////////////////////////////////////////////////////////////////////////
// test_top_mixed_traffic.sv — Mix TideLink FIFO + AHB passthrough traffic
///////////////////////////////////////////////////////////////////////////////
// Exercises both data paths simultaneously:
//   - TideLink FIFO: A TX aperture -> FC -> Wlink -> B RX FIFO
//   - AHB passthrough: A SUB -> XHB500 -> Wlink -> B MNG
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_MIXED_TRAFFIC_SV
`define GUARD_TEST_TOP_MIXED_TRAFFIC_SV

class test_top_mixed_traffic extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_mixed_traffic)

  function new(string name = "test_top_mixed_traffic", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 500_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Mixed Traffic ===", UVM_LOW)

    init_system();

    // Simultaneously drive TideLink FIFO + AHB passthrough
    fork
      // TideLink FIFO path: A->B
      begin
        for (int p = 0; p < 5; p++) begin
          pkt_data = new[4];
          for (int w = 0; w < 4; w++)
            pkt_data[w] = 32'hF1F0_0000 | (p << 8) | w;
          write_packet(SIDE_A, pkt_data);
        end
      end

      // TideLink FIFO path: B->A
      begin
        for (int p = 0; p < 5; p++) begin
          pkt_data = new[4];
          for (int w = 0; w < 4; w++)
            pkt_data[w] = 32'hF2F0_0000 | (p << 8) | w;
          write_packet(SIDE_B, pkt_data);
        end
      end

      // AHB passthrough: A SUB writes
      begin
        env.a_sub_ahb_sys_env.master[0].sequencer.get_cfg(get_cfg);
        for (int i = 0; i < 3; i++) begin
          `uvm_create_on(txn, env.a_sub_ahb_sys_env.master[0].sequencer)
          txn.cfg = get_cfg;
          assert(txn.randomize() with {
            xact_type  == svt_ahb_transaction::WRITE;
            addr       == 32'h0000_1000 + (i * 4);
            burst_type == svt_ahb_transaction::SINGLE;
            burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
            data.size() == 1;
            data[0]    == 32'hABCD_0000 | i;
          });
          `uvm_send(txn)
        end
      end
    join

    // Wait for all traffic to complete
    repeat (1000) @(posedge tb_if.clk);

    // Read TideLink FIFOs
    for (int p = 0; p < 5; p++) begin
      read_packet(SIDE_B, 4, read_data);
      read_packet(SIDE_A, 4, read_data);
    end

    repeat (500) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "Mixed traffic test complete.", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif
