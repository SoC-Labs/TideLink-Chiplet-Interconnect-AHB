///////////////////////////////////////////////////////////////////////////////
// test_sideband_stress.sv
///////////////////////////////////////////////////////////////////////////////
// Rapid credit returns and doorbells mixed with data traffic. Stresses the
// TX arbitration between returner sideband and TX aperture, and the RX
// routing between FIFO_DATA and SIDEBAND packet types.
//
// Test approach:
//   - Send multiple small packets rapidly to generate frequent credit
//     returns (returner fires often)
//   - While returner sideband traffic is active, send new TX aperture
//     data to create contention on the FC TX port
//   - Write to doorbell register to inject additional sideband traffic
//
// Targets bugs in:
//   - TX arbitration priority (returner should win, data should not be lost)
//   - RX FSM handling of interleaved FIFO_DATA and SIDEBAND
//   - Config mux arbitration under rapid sideband writes
//   - Deadlock when both TX and RX are simultaneously busy
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_SIDEBAND_STRESS_SV
`define GUARD_TEST_SIDEBAND_STRESS_SV

class test_sideband_stress extends tidelink_system_base_test;

  `uvm_component_utils(test_sideband_stress)

  int unsigned num_iterations = 8;

  function new(string name = "test_sideband_stress", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 300_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Sideband Stress ===", UVM_LOW)

    // Initialize both sides with immediate release threshold
    init_both_sides(32'h4000_0000, 32'h5000_0000, 32'd0, 32'd0);

    // Rapid write-read cycles to generate maximum sideband traffic
    for (int iter = 0; iter < num_iterations; iter++) begin
      `uvm_info("TEST", $sformatf("--- Iteration %0d/%0d ---", iter + 1, num_iterations), UVM_LOW)

      // Write doorbell on A (generates sideband traffic A->B)
      write_cfg_reg(SIDE_A, REG_DOORBELL, 32'h1);

      // Immediately send a data packet A->B (contends with doorbell sideband)
      pkt_data = new[2];
      pkt_data[0] = {16'hDD00, 16'(iter)};
      pkt_data[1] = {16'hDD01, 16'(iter)};
      write_packet(SIDE_A, pkt_data);

      // Also send B->A to create bidirectional sideband+data contention
      pkt_data = new[2];
      pkt_data[0] = {16'hEE00, 16'(iter)};
      pkt_data[1] = {16'hEE01, 16'(iter)};
      write_packet(SIDE_B, pkt_data);

      // Wait for FC crossover
      repeat (30) @(posedge tb_if.clk);

      // Read both FIFOs
      read_packet(SIDE_B, 2, read_data);
      read_packet(SIDE_A, 2, read_data);

      // Wait for credit returns (sideband traffic back through crossover)
      repeat (50) @(posedge tb_if.clk);

      // Verify data integrity each iteration
      env.sb.compare_a2b_data();
      env.sb.compare_b2a_data();
    end

    // Final checks
    read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("A final CREDIT_COUNT = %0d", reg_data), UVM_LOW)
    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B final CREDIT_COUNT = %0d", reg_data), UVM_LOW)

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_SIDEBAND_STRESS_SV
