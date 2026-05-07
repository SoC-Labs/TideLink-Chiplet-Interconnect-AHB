///////////////////////////////////////////////////////////////////////////////
// test_top_peer_mask_auto.sv — HW-driven peer-mask handshake (Phase 2)
///////////////////////////////////////////////////////////////////////////////
// Exercises the autoneg FSM's automatic mask-handshake path. With
// mask_hs_auto_en (NEGO_CFG[6]) asserted on both sides, the master
// FSM, after winning the I2C claim, runs through the new
// ST_NEGO_MASK_RES_TX state to push a 6-byte result-write transaction
// to the peer's link_lane_mask_hs_result @ 0x21C and asserts its own
// sticky local match flag. Both sides' role_lock then latches without
// any SW writes to the hs_result register.
//
// This test confirms:
//   - role_lock asserts on both sides without SW driving the gate
//   - link_lane_mask_hs_result on the slave reflects 0x01 (match) after
//     the FSM's I2C write lands
//   - traffic flows
//
// Phase 2 minimum-viable: the FSM unconditionally declares match
// (no peer-mask read or comparator). A future commit (2C/2D) layers
// in the actual comparison.
//
// **KNOWN BLOCKED**: this test currently hits a pre-existing autoneg I2C
// issue — the master peer's claim transaction NACKs (master ends in the
// "lost" path with state=DONE, lost=1, won=0), so the new
// ST_NEGO_MASK_RES_TX state is never entered. Same root cause as
// test_top_autoneg_basic's pre-existing failure. The Phase 2 RTL is
// structurally correct (the FSM state body and gate-open path are in
// place); end-to-end validation needs the autoneg I2C ACK path fixed
// first. See SHORTCOMINGS.md item 14a and the peer-mask plan for status.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_PEER_MASK_AUTO_SV
`define GUARD_TEST_TOP_PEER_MASK_AUTO_SV

class test_top_peer_mask_auto extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_peer_mask_auto)

  localparam bit [14:0] WLINK_LANE_MASK_HS_RESULT = 15'h021C;
  localparam bit [14:0] CTRL_NEGO_STATUS          = 15'h2094;
  localparam bit [14:0] CTRL_ROLE_CFG             = 15'h2080;
  localparam bit [14:0] CTRL_NEGO_CFG             = 15'h2090;
  localparam bit [14:0] CTRL_NEGO_PRIORITY        = 15'h2098;
  localparam bit [14:0] CTRL_I2C_SLV_ADDR         = 15'h2088;
  localparam bit [14:0] CTRL_I2C_PRESCALE         = 15'h208C;

  function new(string name = "test_top_peer_mask_auto",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
  endfunction

  // Engage the gate. apb_debug_unlock stays 1 so the slave can still
  // process the master's I2C write to its hs_result register.
  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b0;
    tb_if.b_mask_hs_bypass = 1'b0;
    `uvm_info("TEST", "Peer-mask gate engaged (mask_hs_bypass = 0)", UVM_LOW)
  endtask

  virtual task main_phase(uvm_phase phase);
    bit [31:0] role_a, role_b, hs_a, hs_b;
    bit [31:0] pkt_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== %s ===", get_type_name()), UVM_LOW)

    // Program I2C slave address (peer expects 0x7E claim writes) and prescale
    write_cfg_reg_raw(SIDE_A, CTRL_I2C_SLV_ADDR, 32'h0000_007E);
    write_cfg_reg_raw(SIDE_B, CTRL_I2C_SLV_ADDR, 32'h0000_007E);
    // Larger prescale → slower I2C SCL. With prescale=1 (default), SCL is
    // ~clk/8 which may be too fast for the slave to track. Use 0x10 for
    // ~clk/68 ≈ 1.4 MHz at 100 MHz.
    write_cfg_reg_raw(SIDE_A, CTRL_I2C_PRESCALE, 32'h0000_0010);
    write_cfg_reg_raw(SIDE_B, CTRL_I2C_PRESCALE, 32'h0000_0010);

    // Program priority — A wins (lower = sooner)
    write_cfg_reg_raw(SIDE_A, CTRL_NEGO_PRIORITY, 32'h0000_0001);
    write_cfg_reg_raw(SIDE_B, CTRL_NEGO_PRIORITY, 32'h0000_FFFE);

    // NEGO_CFG with mask_hs_auto_en=1 (bit 6), pri_sel=00 (register source),
    // force_lock=1, en=1.  Bit layout per axi_chiplet_controller.sv:
    //   [0]=en, [1]=start, [3:2]=pri_sel, [4]=fallback, [5]=force_lock,
    //   [6]=mask_hs_auto_en
    `uvm_info("TEST", "Programming NEGO_CFG with mask_hs_auto_en=1", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, CTRL_NEGO_CFG, 32'h0000_0061);  // en|fl|auto_en
    write_cfg_reg_raw(SIDE_B, CTRL_NEGO_CFG, 32'h0000_0061);

    // The FSM has already entered ST_BYPASS at POR (since nego_en was 0
    // pre-NEGO_CFG-write). With the BYPASS→NEGO_INIT re-arm path in
    // tidelink_autoneg.sv, it transitions to NEGO_INIT now that nego_en
    // is set. No reset pulse needed.

    // Wait for negotiation + handshake to complete.
    repeat (40000) @(posedge tb_if.clk);

    // Diag: read NEGO_STATUS on both sides
    begin
      bit [31:0] status_a, status_b;
      read_cfg_reg_raw(SIDE_A, CTRL_NEGO_STATUS, status_a);
      read_cfg_reg_raw(SIDE_B, CTRL_NEGO_STATUS, status_b);
      `uvm_info("TEST", $sformatf(
        "NEGO_STATUS: A=0x%08h B=0x%08h (state=A.%0d B.%0d done=A.%0b B.%0b err=A.%0b B.%0b won=A.%0b lost=B.%0b)",
        status_a, status_b,
        status_a[3:0], status_b[3:0],
        status_a[NEGO_STATUS_DONE], status_b[NEGO_STATUS_DONE],
        status_a[NEGO_STATUS_ERROR], status_b[NEGO_STATUS_ERROR],
        status_a[NEGO_STATUS_WON], status_b[NEGO_STATUS_LOST]), UVM_LOW)
    end

    // Verify role_lock asserted on both sides (gate opened automatically)
    read_cfg_reg_raw(SIDE_A, CTRL_ROLE_CFG, role_a);
    read_cfg_reg_raw(SIDE_B, CTRL_ROLE_CFG, role_b);
    `uvm_info("TEST", $sformatf(
      "ROLE_CFG: A=0x%08h B=0x%08h (lock should be 1 on both)",
      role_a, role_b), UVM_LOW)
    if (role_a[1] != 1'b1)
      `uvm_error("TEST", $sformatf("[A] role_lock not asserted (ROLE_CFG=0x%08h)", role_a))
    if (role_b[1] != 1'b1)
      `uvm_error("TEST", $sformatf("[B] role_lock not asserted (ROLE_CFG=0x%08h)", role_b))

    // Verify the slave's link_lane_mask_hs_result was written by the master
    // over I2C. Master is A (lower priority), so B is the slave whose
    // hs_result register received the FSM-driven write.
    read_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK_HS_RESULT, hs_a);
    read_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK_HS_RESULT, hs_b);
    `uvm_info("TEST", $sformatf(
      "hs_result: A=0x%08h B=0x%08h (B should have peer_says_match=1)",
      hs_a, hs_b), UVM_LOW)
    if (hs_b[0] != 1'b1)
      `uvm_error("TEST", $sformatf("[B] hs_result.peer_says_match not set by FSM I2C write (hs_result=0x%08h)", hs_b))

    // Run a small packet to confirm traffic flows
    init_both_sides();
    pkt_data = new[2];
    pkt_data[0] = 32'hABCD_1234;
    pkt_data[1] = 32'hCAFE_BABE;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    begin
      bit [31:0] read_data[];
      read_packet(SIDE_B, 2, read_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
      env.sb.compare_a2b_data();
    end

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_PEER_MASK_AUTO_SV
