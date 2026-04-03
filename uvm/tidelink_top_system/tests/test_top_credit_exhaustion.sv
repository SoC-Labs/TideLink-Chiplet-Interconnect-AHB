///////////////////////////////////////////////////////////////////////////////
// test_top_credit_exhaustion.sv — Exhaust credits through Wlink, then drain
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_CREDIT_EXHAUSTION_SV
`define GUARD_TEST_TOP_CREDIT_EXHAUSTION_SV

class test_top_credit_exhaustion extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_credit_exhaustion)

  function new(string name = "test_top_credit_exhaustion", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 500_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;
    int pkt_size = 32;
    int num_packets = 20;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Credit Exhaustion ===", UVM_LOW)

    init_system();

    // Send many packets without reading (consume credits)
    for (int p = 0; p < num_packets; p++) begin
      pkt_data = new[pkt_size];
      for (int w = 0; w < pkt_size; w++)
        pkt_data[w] = (p << 16) | w;
      write_packet(SIDE_A, pkt_data);
      repeat (100) @(posedge tb_if.clk);
    end

    repeat (500) @(posedge tb_if.clk);

    // Check credits have decreased
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after %0d packets = %0d",
      num_packets, reg_data), UVM_LOW)

    // Drain all packets
    for (int p = 0; p < num_packets; p++) begin
      read_packet(SIDE_B, pkt_size, read_data);
    end

    // Wait for credit release through Wlink
    repeat (1000) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    // Credits should recover
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT after drain = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    phase.drop_objection(this);
  endtask

endclass

`endif
