///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask.sv — Drop the highest physical lane (D2 in sim plan)
///////////////////////////////////////////////////////////////////////////////
// Symmetric mask=0x7F: the canonical "burnt highest ribbon pin" recovery
// scenario. Reduces 8-lane link to 7 lanes contiguous; popcount=7,
// active_lanes register reads 6 per direction.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_SV
`define GUARD_TEST_TOP_LANE_MASK_SV

class test_top_lane_mask extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask)

  function new(string name = "test_top_lane_mask", uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h007F;
    a_rx_mask = 16'h007F;
    b_tx_mask = 16'h007F;
    b_rx_mask = 16'h007F;
  endfunction

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_SV
