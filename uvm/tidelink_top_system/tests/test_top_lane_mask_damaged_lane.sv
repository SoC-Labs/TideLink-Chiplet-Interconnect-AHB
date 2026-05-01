///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_damaged_lane.sv — Damaged-lane recovery (E3)
///////////////////////////////////////////////////////////////////////////////
// Simulates a broken ribbon pin: with mask=0x7F (lane 7 disabled) and the
// pad-perturb hook stuck-at-1 on lane 7 in both directions, packets must
// still round-trip cleanly because the GPIO PHY's RX gating squashes the
// noise before it reaches the LinkLayer.
//
// This is the headline "burnt lane recovery" scenario from the user guide.
// If the test passes, we have end-to-end confidence that:
//   - LinkLayer striping skips lane 7 (won't try to read its bytes)
//   - GPIO PHY TX-side drives 0 onto lane 7 pad regardless of garbage
//   - GPIO PHY RX-side squashes the perturbed input back to 0
//
// The control test test_top_lane_mask_damaged_lane_unmasked confirms
// that without the mask, the same perturbation does corrupt traffic.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_DAMAGED_LANE_SV
`define GUARD_TEST_TOP_LANE_MASK_DAMAGED_LANE_SV

class test_top_lane_mask_damaged_lane extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_damaged_lane)

  function new(string name = "test_top_lane_mask_damaged_lane",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h007F;
    a_rx_mask = 16'h007F;
    b_tx_mask = 16'h007F;
    b_rx_mask = 16'h007F;
  endfunction

  // Apply the perturb on lane 7 in both directions before the link comes up.
  // The mask must already be programmed (handled by init_system_with_lane_mask
  // in the base class) so that the link-up handshake doesn't see lane 7.
  virtual task pre_link_perturb();
    `uvm_info("TEST", "Forcing lane 7 stuck-at-1 in both directions", UVM_LOW)
    tb_if.a2b_lane_perturb_en[7]  = 1'b1;
    tb_if.a2b_lane_perturb_val[7] = 1'b1;
    tb_if.b2a_lane_perturb_en[7]  = 1'b1;
    tb_if.b2a_lane_perturb_val[7] = 1'b1;
  endtask

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Damaged-lane recovery (mask + stuck pad) ===", UVM_LOW)

    // Apply perturb before link comes up to mimic a pre-existing fault.
    pre_link_perturb();

    init_system_with_lane_mask();
    check_active_lanes();

    // Run a moderate burst — 5 packets — to ensure no single-packet luck.
    repeat (5) begin
      pkt_data = new[4];
      pkt_data[0] = 32'h1100_0000 | $urandom();
      pkt_data[1] = 32'h2200_0000 | $urandom();
      pkt_data[2] = 32'h3300_0000 | $urandom();
      pkt_data[3] = 32'h4400_0000 | $urandom();
      write_packet(SIDE_A, pkt_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
      read_packet(SIDE_B, 4, read_data);
      repeat (phy_transit_wait / 4) @(posedge tb_if.clk);
    end

    env.sb.compare_a2b_data();

    repeat (20) @(posedge tb_if.clk);

    // Release the perturb so other tests in the same run see clean lanes.
    tb_if.a2b_lane_perturb_en[7] = 1'b0;
    tb_if.b2a_lane_perturb_en[7] = 1'b0;

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_DAMAGED_LANE_SV
