///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_asymmetric.sv — One direction degraded (D6)
///////////////////////////////////////////////////////////////////////////////
// Asymmetric ribbon fault: A->B direction is reduced (mask=0x7F), B->A is
// full-width (mask=0xFF). On each side the cross-direction pair must agree:
//   A.tx_mask  ==  B.rx_mask  (both 0x7F)  governs A->B byte striping
//   B.tx_mask  ==  A.rx_mask  (both 0xFF)  governs B->A byte striping
//
// This test verifies that a unidirectional fault recovery works: only the
// A->B path is degraded, the B->A path runs at full width. Sends a packet
// in each direction and confirms both arrive.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_ASYMMETRIC_SV
`define GUARD_TEST_TOP_LANE_MASK_ASYMMETRIC_SV

class test_top_lane_mask_asymmetric extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_asymmetric)

  function new(string name = "test_top_lane_mask_asymmetric",
               uvm_component parent = null);
    super.new(name, parent);
    // A->B direction degraded (drop top): A.tx == B.rx == 0x7F
    a_tx_mask = 16'h007F;
    b_rx_mask = 16'h007F;
    // B->A direction full width: B.tx == A.rx == 0xFF
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
  endfunction

  // Override to send packets in both directions and confirm both round-trip.
  virtual task run_traffic();
    bit [31:0] a2b_data[];
    bit [31:0] b2a_data[];
    bit [31:0] rx_b[];
    bit [31:0] rx_a[];

    a2b_data = new[4];
    a2b_data[0] = 32'hAAAA_0001;
    a2b_data[1] = 32'hAAAA_0002;
    a2b_data[2] = 32'hAAAA_0003;
    a2b_data[3] = 32'hAAAA_0004;

    b2a_data = new[4];
    b2a_data[0] = 32'hBBBB_0001;
    b2a_data[1] = 32'hBBBB_0002;
    b2a_data[2] = 32'hBBBB_0003;
    b2a_data[3] = 32'hBBBB_0004;

    write_packet(SIDE_A, a2b_data);
    write_packet(SIDE_B, b2a_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, rx_b);
    read_packet(SIDE_A, 4, rx_a);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_ASYMMETRIC_SV
