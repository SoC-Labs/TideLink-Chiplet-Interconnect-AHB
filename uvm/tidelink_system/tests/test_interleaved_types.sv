///////////////////////////////////////////////////////////////////////////////
// test_interleaved_types.sv
///////////////////////////////////////////////////////////////////////////////
// Mix different descriptor types (simulated via different data patterns):
//   - RD_REQ (read request descriptor in header word)
//   - WR_REQ (write request descriptor)
//   - RD_RSP (read response descriptor)
//   - WR_RSP (write response descriptor)
//
// The TideLink FIFO does not interpret descriptor contents — it just stores
// and forwards. This test verifies that different descriptor payloads
// (including various sizes) are preserved correctly through the FC path,
// and that interleaving different "types" doesn't cause data corruption
// or ordering issues.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_INTERLEAVED_TYPES_SV
`define GUARD_TEST_INTERLEAVED_TYPES_SV

class test_interleaved_types extends tidelink_system_base_test;

  `uvm_component_utils(test_interleaved_types)

  function new(string name = "test_interleaved_types", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 300_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;

    // Descriptor type encoding (in header word)
    bit [1:0] RD_REQ = 2'b00;
    bit [1:0] WR_REQ = 2'b01;
    bit [1:0] RD_RSP = 2'b10;
    bit [1:0] WR_RSP = 2'b11;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Interleaved Descriptor Types ===", UVM_LOW)

    init_both_sides();

    // Packet 1: RD_REQ (1-word payload)
    `uvm_info("TEST", "Sending RD_REQ descriptor (1 word)", UVM_LOW)
    pkt_data = new[2];
    pkt_data[0] = {RD_REQ, 30'h0000_0001};  // header: type + address
    pkt_data[1] = 32'h0000_0010;             // length field
    write_packet(SIDE_A, pkt_data);
    repeat (25) @(posedge tb_if.clk);
    read_packet(SIDE_B, 2, read_data);
    repeat (40) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Packet 2: WR_REQ (4-word payload)
    `uvm_info("TEST", "Sending WR_REQ descriptor (4 words)", UVM_LOW)
    pkt_data = new[5];
    pkt_data[0] = {WR_REQ, 30'h0000_0002};
    pkt_data[1] = 32'h0000_0004;
    pkt_data[2] = 32'hDADA_0001;
    pkt_data[3] = 32'hDADA_0002;
    pkt_data[4] = 32'hDADA_0003;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);
    read_packet(SIDE_B, 5, read_data);
    repeat (50) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Packet 3: RD_RSP (8-word payload, B->A direction)
    `uvm_info("TEST", "Sending RD_RSP descriptor B->A (8 words)", UVM_LOW)
    pkt_data = new[9];
    pkt_data[0] = {RD_RSP, 30'h0000_0003};
    pkt_data[1] = 32'h0000_0008;
    for (int i = 0; i < 7; i++)
      pkt_data[2+i] = 32'hBEEF_0000 | i;
    write_packet(SIDE_B, pkt_data);
    repeat (40) @(posedge tb_if.clk);
    read_packet(SIDE_A, 9, read_data);
    repeat (60) @(posedge tb_if.clk);
    env.sb.compare_b2a_data();

    // Packet 4: WR_RSP (minimal, 1 word)
    `uvm_info("TEST", "Sending WR_RSP descriptor (1 word)", UVM_LOW)
    pkt_data = new[1];
    pkt_data[0] = {WR_RSP, 30'h0000_0004};
    write_packet(SIDE_A, pkt_data);
    repeat (20) @(posedge tb_if.clk);
    read_packet(SIDE_B, 1, read_data);
    repeat (40) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Packet 5: Mixed direction rapid fire
    `uvm_info("TEST", "Rapid interleaved: A->B then B->A then A->B", UVM_LOW)

    // A->B: RD_REQ
    pkt_data = new[3];
    pkt_data[0] = {RD_REQ, 30'h1000_0001};
    pkt_data[1] = 32'hF1F1_F1F1;
    pkt_data[2] = 32'hF2F2_F2F2;
    write_packet(SIDE_A, pkt_data);
    repeat (15) @(posedge tb_if.clk);

    // B->A: WR_REQ
    pkt_data = new[3];
    pkt_data[0] = {WR_REQ, 30'h2000_0001};
    pkt_data[1] = 32'hE1E1_E1E1;
    pkt_data[2] = 32'hE2E2_E2E2;
    write_packet(SIDE_B, pkt_data);
    repeat (15) @(posedge tb_if.clk);

    // A->B: WR_RSP
    pkt_data = new[2];
    pkt_data[0] = {WR_RSP, 30'h3000_0001};
    pkt_data[1] = 32'hD1D1_D1D1;
    write_packet(SIDE_A, pkt_data);
    repeat (30) @(posedge tb_if.clk);

    // Read all
    read_packet(SIDE_B, 3, read_data);
    read_packet(SIDE_A, 3, read_data);
    read_packet(SIDE_B, 2, read_data);
    repeat (80) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    // Final checks
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_INTERLEAVED_TYPES_SV
