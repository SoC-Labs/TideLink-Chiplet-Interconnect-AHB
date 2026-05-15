///////////////////////////////////////////////////////////////////////////////
// test_train_no_peer_response.sv — I²C times out on training-mode entry
///////////////////////////////////////////////////////////////////////////////
// After autoneg + mask-handshake complete, the slave's I²C slave core is
// disabled mid-flight. The master's ST_TRAIN_ENTER I²C write to peer's
// SWI_TRAINING_MODE then NACKs (no slave to ACK), the FSM detects
// I2C_STS_MISS_ACK, and transitions to ST_TRAIN_FAIL with
// train_peer_nack=1 and peer_lane_fault=0xFF (poison sentinel).
//
// Force-injection: hierarchical-force the slave's I²C slave-core reset
// high so it drops off the bus after autoneg completes. We do this after
// `nego_done=1` to avoid wedging autoneg's own mask-handshake.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TRAIN_NO_PEER_RESPONSE_SV
`define GUARD_TEST_TRAIN_NO_PEER_RESPONSE_SV

class test_train_no_peer_response extends test_top_train_base;

  `uvm_component_utils(test_train_no_peer_response)

  function new(string name = "test_train_no_peer_response",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b1;
    tb_if.b_mask_hs_bypass = 1'b1;
  endtask

  // Background process: wait for autoneg's nego_done to assert on master,
  // then force the slave's I²C slave reset HIGH so subsequent I²C
  // transactions from the master will NACK.
  task disable_slave_i2c_after_nego_done();
    // Poll the slave's NEGO_STATUS for done bit
    bit [31:0] sts;
    int polled;
    sts = 0;
    polled = 0;
    while (!sts[4] && polled < 200000) begin
      read_cfg_reg_raw(SIDE_B, 15'h2094, sts);  // NEGO_STATUS
      polled += 200;
      repeat (200) @(posedge tb_if.clk);
    end
    `uvm_info("TEST", "Slave nego_done observed — disabling slave I²C core",
              UVM_LOW)
    // Drive tb_if knob; the module-scope force in top.sv applies it.
    tb_if.b_i2c_slv_disable = 1'b1;
  endtask

  virtual task main_phase(uvm_phase phase);
    bit train_ok, train_fail;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_train_no_peer_response ===", UVM_LOW)

    program_train_cfg();

    // Run autoneg in parallel with the slave-I²C-disable injector.
    fork
      disable_slave_i2c_after_nego_done();
    join_none

    wait_train_complete(train_ok, train_fail);
    `uvm_info("TEST", $sformatf(
      "Final: ok=%0b fail=%0b peer_nack=%0b peer_fault=0x%02h",
      train_ok, train_fail, tb_if.a_train_peer_nack_obs,
      tb_if.a_train_peer_lane_fault_obs), UVM_LOW)

    if (train_ok)
      `uvm_error("TEST", "Expected train_ok=0 for peer-NACK scenario")
    if (!train_fail)
      `uvm_error("TEST", "Expected train_fail=1 for peer-NACK scenario")
    if (!tb_if.a_train_peer_nack_obs)
      `uvm_error("TEST", "Expected train_peer_nack=1 for peer-NACK scenario")
    if (tb_if.a_train_peer_lane_fault_obs !== 8'hFF)
      `uvm_error("TEST", $sformatf(
        "Expected peer_lane_fault=0xFF (poison sentinel), got 0x%02h",
        tb_if.a_train_peer_lane_fault_obs))

    tb_if.b_i2c_slv_disable = 1'b0;

    repeat (50) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TRAIN_NO_PEER_RESPONSE_SV
