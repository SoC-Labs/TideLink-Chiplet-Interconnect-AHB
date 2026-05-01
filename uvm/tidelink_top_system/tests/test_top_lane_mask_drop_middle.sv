///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_drop_middle.sv — Drop a middle lane (D3 in sim plan)
///////////////////////////////////////////////////////////////////////////////
// Symmetric mask=0xFB: physical lane 2 disabled. 7 active lanes,
// non-contiguous. Exercises the lanePos formula's handling of
// gaps in the active-lane sequence — the byte stripe must skip
// lane 2's slot and place the remaining lanes at positions 0,1,2,3,4,5,6.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_DROP_MIDDLE_SV
`define GUARD_TEST_TOP_LANE_MASK_DROP_MIDDLE_SV

class test_top_lane_mask_drop_middle extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_drop_middle)

  function new(string name = "test_top_lane_mask_drop_middle",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h00FB;
    a_rx_mask = 16'h00FB;
    b_tx_mask = 16'h00FB;
    b_rx_mask = 16'h00FB;
  endfunction

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_DROP_MIDDLE_SV
