///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_single_lane.sv — Minimum-width operation (D4)
///////////////////////////////////////////////////////////////////////////////
// Symmetric mask=0x01: only lane 0 active. Exercises the popcount=1 path,
// active_lanes register = 0, bytesPerCycle = 2. The link operates at its
// minimum throughput; this is the worst-case GPIO PHY serialisation soak,
// which is why phy_transit_wait may need extension.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_SINGLE_LANE_SV
`define GUARD_TEST_TOP_LANE_MASK_SINGLE_LANE_SV

class test_top_lane_mask_single_lane extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_single_lane)

  function new(string name = "test_top_lane_mask_single_lane",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h0001;
    a_rx_mask = 16'h0001;
    b_tx_mask = 16'h0001;
    b_rx_mask = 16'h0001;
    // Single-lane mode is ~8x slower than full-width; extend the wait.
    phy_transit_wait = 40000;
  endfunction

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_SINGLE_LANE_SV
