///////////////////////////////////////////////////////////////////////////////
// test_top_peer_mask_mismatch_refused.sv — Peer-mask handshake fails closed
///////////////////////////////////////////////////////////////////////////////
// Negative test for the peer-mask gate. Sequence:
//   1. Engage the gate via mask_hs_bypass = 0 on both sides.
//   2. Bring up Wlink — role-cfg writes should land but role_lock stays 0.
//   3. Software writes 0x02 (peer_says_fail) to A's link_lane_mask_hs_result.
//   4. Confirm:
//        a) Both sides STILL have role_lock = 0 (gate stays closed).
//        b) The local nego_status[8] = nego_mask_mismatch flag is set on A
//           (sticky).
//        c) Attempting an A→B AHB packet does NOT round-trip — Wlink is in
//           POR on both sides.
//
// This validates the hardware-enforced safety property: a single failed
// handshake byte is enough to refuse link-up. Recovery requires a poreset
// (matches AUTONEG_PROTOCOL.md §12.2: one negotiation per POR).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_PEER_MASK_MISMATCH_REFUSED_SV
`define GUARD_TEST_TOP_PEER_MASK_MISMATCH_REFUSED_SV

class test_top_peer_mask_mismatch_refused extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_peer_mask_mismatch_refused)

  localparam bit [14:0] WLINK_LANE_MASK_HS_RESULT = 15'h021C;
  localparam bit [14:0] CTRL_NEGO_STATUS          = 15'h2094;
  localparam bit [14:0] CTRL_ROLE_CFG             = 15'h2080;

  function new(string name = "test_top_peer_mask_mismatch_refused",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h007F;
    a_rx_mask = 16'h007F;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
    // Mismatched masks → if traffic flowed it would corrupt; but the gate
    // should prevent any traffic at all.
    top_system_a2b_expected_catcher::expect_a2b_mismatch = 1'b1;
  endfunction

  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b0;
    tb_if.b_mask_hs_bypass = 1'b0;
    `uvm_info("TEST", "Peer-mask gate engaged (mask_hs_bypass = 0)", UVM_LOW)
  endtask

  virtual task main_phase(uvm_phase phase);
    bit [31:0] role_a, role_b, status_a, status_b;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== %s ===", get_type_name()), UVM_LOW)

    // Bring up the link with the gate engaged. role_lock is held off.
    init_wlink();

    // Software writes peer_says_fail (0x02) to both sides' result registers.
    `uvm_info("TEST", "Writing fail-token (0x02) to both sides' link_lane_mask_hs_result", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK_HS_RESULT, 32'h0000_0002);
    write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK_HS_RESULT, 32'h0000_0002);
    repeat (50) @(posedge tb_if.clk);

    // Expectation: role_lock STAYS at 0 — the gate only opens on match.
    read_cfg_reg_raw(SIDE_A, CTRL_ROLE_CFG, role_a);
    read_cfg_reg_raw(SIDE_B, CTRL_ROLE_CFG, role_b);
    `uvm_info("TEST", $sformatf(
      "Post-fail ROLE_CFG: A=0x%08h B=0x%08h (lock bit MUST stay 0)",
      role_a, role_b), UVM_LOW)
    if (role_a[1] != 1'b0)
      `uvm_error("TEST", $sformatf("[A] role_lock asserted despite mask-fail (ROLE_CFG=0x%08h) — GATE LEAKED", role_a))
    if (role_b[1] != 1'b0)
      `uvm_error("TEST", $sformatf("[B] role_lock asserted despite mask-fail (ROLE_CFG=0x%08h) — GATE LEAKED", role_b))

    // Expectation: nego_status[8] = nego_mask_mismatch is set on both sides.
    read_cfg_reg_raw(SIDE_A, CTRL_NEGO_STATUS, status_a);
    read_cfg_reg_raw(SIDE_B, CTRL_NEGO_STATUS, status_b);
    `uvm_info("TEST", $sformatf(
      "NEGO_STATUS: A=0x%08h B=0x%08h (bit[8] mask_mismatch should be 1)",
      status_a, status_b), UVM_LOW)
    if (status_a[8] != 1'b1)
      `uvm_error("TEST", $sformatf("[A] nego_mask_mismatch not latched (NEGO_STATUS=0x%08h)", status_a))
    if (status_b[8] != 1'b1)
      `uvm_error("TEST", $sformatf("[B] nego_mask_mismatch not latched (NEGO_STATUS=0x%08h)", status_b))

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_PEER_MASK_MISMATCH_REFUSED_SV
