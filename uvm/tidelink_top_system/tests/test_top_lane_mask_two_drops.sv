///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_two_drops.sv — Two non-adjacent dropped lanes (D5)
///////////////////////////////////////////////////////////////////////////////
// Symmetric mask=0x6E: lanes {1,2,3,5,6} active = 5 lanes, with two gaps
// (lane 0 and lane 4 disabled, plus lane 7). This is a torture case for
// the per-lane lanePos = popcount(mask[k-1:0]) computation, because the
// position-to-physical-lane mapping is non-monotonic relative to lane
// index in any obvious way:
//   physical lane 1 -> position 0
//   physical lane 2 -> position 1
//   physical lane 3 -> position 2
//   physical lane 5 -> position 3
//   physical lane 6 -> position 4
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_TWO_DROPS_SV
`define GUARD_TEST_TOP_LANE_MASK_TWO_DROPS_SV

class test_top_lane_mask_two_drops extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_two_drops)

  function new(string name = "test_top_lane_mask_two_drops",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h006E;
    a_rx_mask = 16'h006E;
    b_tx_mask = 16'h006E;
    b_rx_mask = 16'h006E;
  endfunction

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_TWO_DROPS_SV
