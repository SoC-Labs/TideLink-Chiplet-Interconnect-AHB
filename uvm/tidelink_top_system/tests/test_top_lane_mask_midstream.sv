///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_midstream.sv — Mid-stream mask change (D7)
///////////////////////////////////////////////////////////////////////////////
// Sequence:
//   1. Bring up at default mask (0xFF), send a packet, verify
//   2. Disable Wlink LL on both sides via link_enable_reset
//   3. Reprogram mask to 0xFB (drop lane 2) on both sides
//   4. Re-enable Wlink LL on both sides
//   5. Send another packet at the new mask, verify it round-trips
//
// Validates the recommended bring-up sequence in the user guide: change
// the mask only with the link disabled. If the LL disable/re-enable
// doesn't quiesce in-flight bytes the second packet will corrupt.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_MIDSTREAM_SV
`define GUARD_TEST_TOP_LANE_MASK_MIDSTREAM_SV

class test_top_lane_mask_midstream extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_midstream)

  // Wlink register offsets within unified APB (Wlink space is 0x0000-0x1FFF)
  localparam bit [14:0] WLINK_LINK_ENABLE_RESET = 15'h0208;
  localparam bit [14:0] WLINK_LANE_MASK         = 15'h0214;

  // Default LL enable register value (swi_enable=1, lltx_enable=1, llrx_enable=1,
  // short_packet_max=0x7F, preq_data_id=0x02). See SW.scala:WavSWReg(0x8, ...).
  localparam bit [31:0] LL_ENABLE_DEFAULT = 32'h0002_7F07;
  localparam bit [31:0] LL_ENABLE_DISABLED = LL_ENABLE_DEFAULT & ~32'h0000_0006;

  function new(string name = "test_top_lane_mask_midstream",
               uvm_component parent = null);
    super.new(name, parent);
    // Start at default mask
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Mid-stream lane mask change ===", UVM_LOW)

    // Phase 1: bring up at full width
    init_system_with_lane_mask();
    check_active_lanes();

    pkt_data = new[4];
    pkt_data[0] = 32'h1111_AAAA;
    pkt_data[1] = 32'h2222_BBBB;
    pkt_data[2] = 32'h3333_CCCC;
    pkt_data[3] = 32'h4444_DDDD;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    // Phase 2: disable LL, change mask, re-enable
    `uvm_info("TEST", "Disabling LL on both sides", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DISABLED);
    write_cfg_reg_raw(SIDE_B, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DISABLED);
    repeat (200) @(posedge tb_if.clk);

    `uvm_info("TEST", "Reprogramming mask to 0x00FB on both sides", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK, {16'h00FB, 16'h00FB});
    write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK, {16'h00FB, 16'h00FB});
    repeat (50) @(posedge tb_if.clk);

    // Update tracked masks for the active_lanes check
    a_tx_mask = 16'h00FB;
    a_rx_mask = 16'h00FB;
    b_tx_mask = 16'h00FB;
    b_rx_mask = 16'h00FB;

    `uvm_info("TEST", "Re-enabling LL on both sides", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DEFAULT);
    write_cfg_reg_raw(SIDE_B, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DEFAULT);
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    check_active_lanes();

    // Phase 3: send a packet at the new mask
    pkt_data = new[4];
    pkt_data[0] = 32'h5555_EEEE;
    pkt_data[1] = 32'h6666_FFFF;
    pkt_data[2] = 32'h7777_0000;
    pkt_data[3] = 32'h8888_1111;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    env.sb.compare_a2b_data();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_MIDSTREAM_SV
