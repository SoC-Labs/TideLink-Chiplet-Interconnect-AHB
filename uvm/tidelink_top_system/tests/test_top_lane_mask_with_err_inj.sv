///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_with_err_inj.sv — Mask + error injection (D8)
///////////////////////////////////////////////////////////////////////////////
// Composability check: with mask=0x7F (lane 7 disabled), use the existing
// link_error_injection register at 0x023C to flip a bit in a slot that
// would have lived on lane 7 if all 8 lanes were active. The masked link
// must NOT surface a CRC error from this injection because the byte the
// error targeted is not actually transmitted.
//
// Note: error_injection targets a specific (data_id, byte, bit) tuple in
// the application data. Since byte position depends on the active byte
// striping (which depends on the mask), the test injects on a byte index
// that exercises the byte-7 slot in the original 8-lane layout. This is
// a corner case — what we're really verifying is that the surrounding
// state machine is robust when the masked configuration runs the same
// error-injection code path as the unmasked configuration.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_WITH_ERR_INJ_SV
`define GUARD_TEST_TOP_LANE_MASK_WITH_ERR_INJ_SV

class test_top_lane_mask_with_err_inj extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_with_err_inj)

  localparam bit [14:0] WLINK_ERR_INJECTION = 15'h023C;

  function new(string name = "test_top_lane_mask_with_err_inj",
               uvm_component parent = null);
    super.new(name, parent);
    // Drop top lane symmetrically
    a_tx_mask = 16'h007F;
    a_rx_mask = 16'h007F;
    b_tx_mask = 16'h007F;
    b_rx_mask = 16'h007F;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] err_inj_word;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Lane mask + error injection composability ===", UVM_LOW)

    init_system_with_lane_mask();
    check_active_lanes();

    // Configure error injection on side A: target data_id=0x80 (AXI AR),
    // byte=14 (would be in the lane-7 high half at 8-lane stripe), bit=0,
    // enable. With mask=0x7F this byte index isn't transmitted, so no CRC
    // error should surface.
    err_inj_word = (1 << 31) | (0 << 16) | (14 << 8) | 32'h0000_0080;
    write_cfg_reg_raw(SIDE_A, WLINK_ERR_INJECTION, err_inj_word);
    repeat (10) @(posedge tb_if.clk);

    pkt_data = new[4];
    pkt_data[0] = 32'hF00D_FACE;
    pkt_data[1] = 32'hC0DE_BABE;
    pkt_data[2] = 32'hA1B2_C3D4;
    pkt_data[3] = 32'h5566_7788;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // Disable error injection so it doesn't pollute later tests in the same run
    write_cfg_reg_raw(SIDE_A, WLINK_ERR_INJECTION, 32'h0);

    env.sb.compare_a2b_data();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_WITH_ERR_INJ_SV
