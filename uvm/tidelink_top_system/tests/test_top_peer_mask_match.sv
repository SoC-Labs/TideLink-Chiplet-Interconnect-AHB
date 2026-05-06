///////////////////////////////////////////////////////////////////////////////
// test_top_peer_mask_match.sv — Peer-mask handshake happy path
///////////////////////////////////////////////////////////////////////////////
// Drives the SW-side peer-mask handshake end-to-end:
//   1. Drop a_apb_debug_unlock so the peer-mask gate is *active*.
//   2. Both sides program the same 0x7F lane mask via APB.
//   3. Bring up the link via init_wlink + init_both_sides; the autoneg
//      pulses set_role_lock as usual but role_lock_reg latches as
//      nego_lock_pending only — actual role_lock is held back.
//   4. Confirm role_locked still reads 0 (gate held closed).
//   5. Software writes 0x01 (peer_says_match) to the local
//      link_lane_mask_hs_result @ 0x21C. The gate opens, role_lock_reg
//      latches, link enable propagates, traffic flows.
//   6. Run a 4-word A→B packet and verify integrity.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_PEER_MASK_MATCH_SV
`define GUARD_TEST_TOP_PEER_MASK_MATCH_SV

class test_top_peer_mask_match extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_peer_mask_match)

  localparam bit [14:0] WLINK_LANE_MASK_HS_RESULT = 15'h021C;
  localparam bit [14:0] CTRL_NEGO_STATUS          = 15'h2094;
  localparam bit [14:0] CTRL_ROLE_CFG             = 15'h2080;

  function new(string name = "test_top_peer_mask_match",
               uvm_component parent = null);
    super.new(name, parent);
    // Symmetric reduced mask — drops highest lane on both sides
    a_tx_mask = 16'h007F;
    a_rx_mask = 16'h007F;
    b_tx_mask = 16'h007F;
    b_rx_mask = 16'h007F;
  endfunction

  // Drive mask_hs_bypass = 0 so the peer-mask gate is the actual
  // lock-arbiter. apb_debug_unlock stays 1 so the slave's local SW can
  // still write its own hs_result register (the master peer would do
  // this over I2C in production; in this SW-driven test each side
  // writes its own copy).
  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b0;
    tb_if.b_mask_hs_bypass = 1'b0;
    `uvm_info("TEST", "Peer-mask gate engaged (a/b mask_hs_bypass = 0)", UVM_LOW)
  endtask

  // Override base flow: program masks BEFORE init_wlink so the
  // gate-open sequence completes mid-init rather than after the link
  // would have otherwise come up.
  virtual task init_system_with_lane_mask();
    bit [31:0] role_a, role_b;

    `uvm_info("TEST", $sformatf(
      "Lane mask plan: A=0x%04h B=0x%04h (symmetric, expect handshake match)",
      a_tx_mask, b_tx_mask), UVM_LOW)

    // Bring up the link with the gate engaged. The autoneg FSM (or this
    // test's role-cfg writes) will pulse set_role_lock; the gate holds
    // role_lock_reg = 0 until SW writes the mask-handshake result.
    init_wlink();

    // Confirm the gate is in fact holding role_locked at 0 even though
    // role_cfg has been programmed.
    read_cfg_reg_raw(SIDE_A, CTRL_ROLE_CFG, role_a);
    read_cfg_reg_raw(SIDE_B, CTRL_ROLE_CFG, role_b);
    `uvm_info("TEST", $sformatf(
      "Pre-handshake ROLE_CFG: A=0x%08h B=0x%08h (lock bit should be 0)",
      role_a, role_b), UVM_LOW)
    if (role_a[1] != 1'b0)
      `uvm_error("TEST", $sformatf("[A] role_lock asserted before peer-mask handshake (ROLE_CFG=0x%08h)", role_a))
    if (role_b[1] != 1'b0)
      `uvm_error("TEST", $sformatf("[B] role_lock asserted before peer-mask handshake (ROLE_CFG=0x%08h)", role_b))

    // Software-driven peer-mask handshake: each side writes match=0x01
    // to its OWN link_lane_mask_hs_result register. (The eventual HW
    // automation will have the master peer write the slave's register
    // over I2C; in SW-driven mode each side declares match locally.)
    `uvm_info("TEST", "Writing match-token to both sides' link_lane_mask_hs_result", UVM_LOW)
    write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK_HS_RESULT, 32'h0000_0001);
    write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK_HS_RESULT, 32'h0000_0001);

    // Give the gate a few cycles to release role_lock_reg.
    repeat (20) @(posedge tb_if.clk);

    read_cfg_reg_raw(SIDE_A, CTRL_ROLE_CFG, role_a);
    read_cfg_reg_raw(SIDE_B, CTRL_ROLE_CFG, role_b);
    `uvm_info("TEST", $sformatf(
      "Post-handshake ROLE_CFG: A=0x%08h B=0x%08h (lock bit should be 1)",
      role_a, role_b), UVM_LOW)
    if (role_a[1] != 1'b1)
      `uvm_error("TEST", $sformatf("[A] role_lock not asserted after match-token (ROLE_CFG=0x%08h)", role_a))
    if (role_b[1] != 1'b1)
      `uvm_error("TEST", $sformatf("[B] role_lock not asserted after match-token (ROLE_CFG=0x%08h)", role_b))

    // Wait for the link to train now that POR has released
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);

    init_both_sides();

    // Apply the test mask on both sides via the standard disable/write/enable
    // sequence (link is now up).
    apply_lane_mask();

    if (env.cov != null)
      env.cov.sample_lane_mask(a_tx_mask, a_rx_mask);
  endtask

endclass

`endif // GUARD_TEST_TOP_PEER_MASK_MATCH_SV
