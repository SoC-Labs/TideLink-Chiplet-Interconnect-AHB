///////////////////////////////////////////////////////////////////////////////
// test_train_lane_fault.sv — slave lane 3 never locks
///////////////////////////////////////////////////////////////////////////////
// Forces the slave's `swi_lane_locked_in[3]` to 0 throughout the test. The
// master's polling sub-flow sees peer_lane_locked = 0xF7 every poll, never
// reaches all-locked, and after the configurable poll-timeout transitions
// to ST_TRAIN_FAIL. NEGO_TRAIN_STATUS reflects the diagnostic readout:
//   - peer_lane_locked = 0xF7
//   - peer_lane_fault  = 0x08 (lane 3 fault sticky)
//   - local_lane_fault = 0x00 (master's lanes healthy)
//   - train_fail = 1, train_ok = 0
//
// The slave's autocal FSM "exhausts retries" on lane 3 — this is modelled
// by forcing the lane_locked/lane_fault inputs directly (no actual cal-FSM
// running in this testbench).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TRAIN_LANE_FAULT_SV
`define GUARD_TEST_TRAIN_LANE_FAULT_SV

class test_train_lane_fault extends test_top_train_base;

  `uvm_component_utils(test_train_lane_fault)

  function new(string name = "test_train_lane_fault",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b1;
    tb_if.b_mask_hs_bypass = 1'b1;
    // Inject fault BEFORE training begins. Slave's lane 3 reports unlocked,
    // with sticky lane_fault[3]=1 and cal_done=1 (cal FSM has finished and
    // given up on that lane).
    force_local_status(SIDE_B, 8'hF7, 8'h08, 1'b1);
    // Master remains healthy
    force_local_status(SIDE_A, 8'hFF, 8'h00, 1'b1);
  endtask

  virtual task main_phase(uvm_phase phase);
    bit train_ok, train_fail;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_train_lane_fault ===", UVM_LOW)

    // Use a small poll_timeout so the test exits quickly. poll_timeout=2 →
    // 2 polls before fail.
    program_train_cfg(.poll_timeout(4'd2));

    wait_train_complete(train_ok, train_fail);
    `uvm_info("TEST", $sformatf(
      "Final: ok=%0b fail=%0b state=%0d peer_locked=0x%02h peer_fault=0x%02h",
      train_ok, train_fail, tb_if.a_train_state_obs,
      tb_if.a_train_peer_lane_locked_obs, tb_if.a_train_peer_lane_fault_obs),
      UVM_LOW)

    if (train_ok)
      `uvm_error("TEST", "Expected train_ok=0 for lane-fault scenario")
    if (!train_fail)
      `uvm_error("TEST", "Expected train_fail=1 for lane-fault scenario")
    if (tb_if.a_train_peer_nack_obs)
      `uvm_error("TEST", "peer_nack=1 unexpected (peer was responsive over I²C)")
    if (tb_if.a_train_peer_lane_locked_obs !== 8'hF7)
      `uvm_error("TEST", $sformatf(
        "Expected peer_lane_locked=0xF7, got 0x%02h",
        tb_if.a_train_peer_lane_locked_obs))

    release_local_status(SIDE_A);
    release_local_status(SIDE_B);

    repeat (50) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TRAIN_LANE_FAULT_SV
