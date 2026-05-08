///////////////////////////////////////////////////////////////////////////////
// test_top_peer_mask_auto_mismatch.sv — HW-driven peer-mask handshake fail
///////////////////////////////////////////////////////////////////////////////
// Phase 2D negative test. Both sides assert mask_hs_auto_en (NEGO_CFG[6])
// with mismatched lane masks programmed pre-negotiation. The autoneg FSM:
//   1. wins the I2C claim (ST_NEGO_POLL TXN_CHECK ACK)
//   2. reads the peer's link_lane_mask via I2C (ST_NEGO_MASK_RD_ADDR /
//      ST_NEGO_MASK_RD_DATA)
//   3. runs the crossover-identity comparator (mask_match_w):
//          local.tx == peer.rx AND local.rx == peer.tx
//      With B's tx_mask = 0x7F and A's rx_mask = 0xFF, the second equality
//      fails, so the comparator outputs match=0 / fail=1.
//   4. writes peer_says_fail (0x02) to peer's link_lane_mask_hs_result over
//      I2C (ST_NEGO_MASK_RES_TX with the computed verdict byte).
//
// On RES_TX → DONE the master latches mask_hs_local_fail_r = 1 (and
// _match_r = 0). The wrapper-side mask_hs_fail OR-tree latches
// nego_mask_mismatch_reg on both sides (master from autoneg flag, slave
// from the I2C-written hs_result[1]). The mask gate stays closed →
// role_lock_reg does NOT assert on either side.
//
// Asserts:
//   - role_lock = 0 on both sides (gate refused)
//   - hs_result on B = 0x00000002 (peer_says_fail)
//   - NEGO_STATUS[NEGO_STATUS_MASK_MM] (bit 9) sticky on both sides
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_PEER_MASK_AUTO_MISMATCH_SV
`define GUARD_TEST_TOP_PEER_MASK_AUTO_MISMATCH_SV

class test_top_peer_mask_auto_mismatch extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_peer_mask_auto_mismatch)

  localparam bit [14:0] WLINK_LANE_MASK_HS_RESULT = 15'h021C;
  localparam bit [14:0] WLINK_LANE_MASK           = 15'h0214;
  localparam bit [14:0] CTRL_NEGO_STATUS          = 15'h2094;
  localparam bit [14:0] CTRL_ROLE_CFG             = 15'h2080;
  localparam bit [14:0] CTRL_NEGO_CFG             = 15'h2090;
  localparam bit [14:0] CTRL_NEGO_PRIORITY        = 15'h2098;
  localparam bit [14:0] CTRL_I2C_SLV_ADDR         = 15'h2088;
  localparam bit [14:0] CTRL_I2C_PRESCALE         = 15'h208C;

  function new(string name = "test_top_peer_mask_auto_mismatch",
               uvm_component parent = null);
    super.new(name, parent);
    // Crossover-identity-failing pair: A.rx (0xFF) != B.tx (0x7F). The
    // comparator runs on the master (A), which sees local.rx=0xFF vs
    // captured peer.tx=0x7F → fail.
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h007F;
    b_rx_mask = 16'h00FF;
    // No traffic phase in this test — Wlink stays in POR because the gate
    // refuses to open. The base scoreboard catcher is left default (no
    // expected mismatch — we just don't drive any TX/RX traffic).
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
    bit [31:0] role_a, role_b, hs_a, hs_b, status_a, status_b;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== %s ===", get_type_name()), UVM_LOW)

    // --------------------------------------------------------------------
    // Pre-negotiation setup. The Wlink lane_mask register is in the apb
    // domain (apb_reset only — released after hresetn), so writes land
    // even with role_lock=0 / wlink_por_reset asserted.
    // --------------------------------------------------------------------
    `uvm_info("TEST", $sformatf(
      "Programming lane masks: A.tx=0x%02h A.rx=0x%02h | B.tx=0x%02h B.rx=0x%02h (crossover MUST fail)",
      a_tx_mask[7:0], a_rx_mask[7:0], b_tx_mask[7:0], b_rx_mask[7:0]), UVM_LOW)
    write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK,
                      {16'h0000, a_rx_mask[7:0], a_tx_mask[7:0]});
    write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK,
                      {16'h0000, b_rx_mask[7:0], b_tx_mask[7:0]});

    // I2C slave address + slow prescale (matches test_top_peer_mask_auto)
    write_cfg_reg_raw(SIDE_A, CTRL_I2C_SLV_ADDR, 32'h0000_007E);
    write_cfg_reg_raw(SIDE_B, CTRL_I2C_SLV_ADDR, 32'h0000_007E);
    write_cfg_reg_raw(SIDE_A, CTRL_I2C_PRESCALE, 32'h0000_0010);
    write_cfg_reg_raw(SIDE_B, CTRL_I2C_PRESCALE, 32'h0000_0010);

    // Priority: A wins
    write_cfg_reg_raw(SIDE_A, CTRL_NEGO_PRIORITY, 32'h0000_0001);
    write_cfg_reg_raw(SIDE_B, CTRL_NEGO_PRIORITY, 32'h0000_FFFE);

    // NEGO_CFG: en|fl|auto_en (bit 6 = mask_hs_auto_en)
    `uvm_info("TEST", "Programming NEGO_CFG with mask_hs_auto_en=1", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, CTRL_NEGO_CFG, 32'h0000_0061);
    write_cfg_reg_raw(SIDE_B, CTRL_NEGO_CFG, 32'h0000_0061);

    // Wait for negotiation + handshake to complete (RES_TX → DONE on A,
    // result byte landed on B).
    repeat (40000) @(posedge tb_if.clk);

    // --------------------------------------------------------------------
    // Post-handshake checks
    // --------------------------------------------------------------------
    read_cfg_reg_raw(SIDE_A, CTRL_NEGO_STATUS, status_a);
    read_cfg_reg_raw(SIDE_B, CTRL_NEGO_STATUS, status_b);
    `uvm_info("TEST", $sformatf(
      "NEGO_STATUS: A=0x%08h B=0x%08h (state=A.%0d B.%0d done=A.%0b B.%0b err=A.%0b B.%0b won=A.%0b lost=B.%0b mm=A.%0b B.%0b)",
      status_a, status_b,
      status_a[3:0], status_b[3:0],
      status_a[NEGO_STATUS_DONE], status_b[NEGO_STATUS_DONE],
      status_a[NEGO_STATUS_ERROR], status_b[NEGO_STATUS_ERROR],
      status_a[NEGO_STATUS_WON], status_b[NEGO_STATUS_LOST],
      status_a[NEGO_STATUS_MASK_MM], status_b[NEGO_STATUS_MASK_MM]), UVM_LOW)

    // role_lock MUST stay 0 on both sides — the comparator-fail verdict
    // closes the mask gate even with force_lock=1.
    read_cfg_reg_raw(SIDE_A, CTRL_ROLE_CFG, role_a);
    read_cfg_reg_raw(SIDE_B, CTRL_ROLE_CFG, role_b);
    `uvm_info("TEST", $sformatf(
      "ROLE_CFG: A=0x%08h B=0x%08h (lock bit MUST stay 0 — gate refused)",
      role_a, role_b), UVM_LOW)
    if (role_a[1] != 1'b0)
      `uvm_error("TEST", $sformatf("[A] role_lock asserted despite mask-fail (ROLE_CFG=0x%08h) — GATE LEAKED", role_a))
    if (role_b[1] != 1'b0)
      `uvm_error("TEST", $sformatf("[B] role_lock asserted despite mask-fail (ROLE_CFG=0x%08h) — GATE LEAKED", role_b))

    // B is the slave; its hs_result was written by master's I2C transaction.
    // peer_says_fail (bit 1) = 1, peer_says_match (bit 0) = 0.
    read_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK_HS_RESULT, hs_a);
    read_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK_HS_RESULT, hs_b);
    `uvm_info("TEST", $sformatf(
      "hs_result: A=0x%08h B=0x%08h (B should have peer_says_fail=1, peer_says_match=0)",
      hs_a, hs_b), UVM_LOW)
    if (hs_b[0] != 1'b0)
      `uvm_error("TEST", $sformatf("[B] hs_result.peer_says_match unexpectedly set (hs_result=0x%08h)", hs_b))
    if (hs_b[1] != 1'b1)
      `uvm_error("TEST", $sformatf("[B] hs_result.peer_says_fail not set by FSM I2C write (hs_result=0x%08h)", hs_b))

    // nego_mask_mismatch sticky on both sides.
    if (status_a[NEGO_STATUS_MASK_MM] != 1'b1)
      `uvm_error("TEST", $sformatf("[A] nego_mask_mismatch not latched (NEGO_STATUS=0x%08h)", status_a))
    if (status_b[NEGO_STATUS_MASK_MM] != 1'b1)
      `uvm_error("TEST", $sformatf("[B] nego_mask_mismatch not latched (NEGO_STATUS=0x%08h)", status_b))

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_PEER_MASK_AUTO_MISMATCH_SV
