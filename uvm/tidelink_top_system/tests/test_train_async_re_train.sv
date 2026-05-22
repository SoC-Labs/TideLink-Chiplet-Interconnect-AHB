///////////////////////////////////////////////////////////////////////////////
// test_train_async_re_train.sv — SW-triggered re-train after initial bring-up
///////////////////////////////////////////////////////////////////////////////
// Phase A: identical to test_train_i2c_handshake. Wait for train_ok=1.
// Phase B: SW writes NEGO_TRAIN_CFG.train_retrain (W1P bit[2]). The
//   master FSM transitions ST_TRAIN_DONE → ST_NEGO_DONE_PRE → ST_TRAIN_ENTER
//   and walks the sequence again. train_ok / train_fail clear on entry.
// Phase C: confirm a second train_ok=1 with peer_lane_locked=0xFF.
//
// The retrain pulse is self-clearing: the chiplet_controller's NEGO_TRAIN_CFG
// write logic asserts `nego_train_retrain_pulse=1` for one cycle on a W1P
// of bit[2], then drops it back to 0 — preventing the FSM from re-entering
// the training loop on subsequent reads.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TRAIN_ASYNC_RE_TRAIN_SV
`define GUARD_TEST_TRAIN_ASYNC_RE_TRAIN_SV

class test_train_async_re_train extends test_top_train_base;

  `uvm_component_utils(test_train_async_re_train)

  function new(string name = "test_train_async_re_train",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b1;
    tb_if.b_mask_hs_bypass = 1'b1;
  endtask

  virtual task main_phase(uvm_phase phase);
    bit train_ok, train_fail;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_train_async_re_train — Phase A (initial) ===",
              UVM_LOW)
    force_local_status(SIDE_A, 8'hFF, 8'h00, 1'b1);
    force_local_status(SIDE_B, 8'hFF, 8'h00, 1'b1);
    program_train_cfg();
    wait_train_complete(train_ok, train_fail);
    if (!train_ok)
      `uvm_error("TEST", "Phase A: train_ok not asserted")
    `uvm_info("TEST", "Phase A complete — train_ok=1", UVM_LOW)

    // ---- Phase B — fire retrain ----
    `uvm_info("TEST", "=== Phase B — writing NEGO_TRAIN_CFG.train_retrain ===",
              UVM_LOW)
    write_cfg_reg_raw(SIDE_A, R8_NEGO_TRAIN_CFG, 32'h0000_0005);
    repeat (500) @(posedge tb_if.clk);

    // ---- Phase C — wait for second train_ok ----
    wait_train_complete(train_ok, train_fail);
    `uvm_info("TEST", $sformatf(
      "Phase C: ok=%0b fail=%0b state=%0d", train_ok, train_fail,
      tb_if.a_train_state_obs), UVM_LOW)
    if (!train_ok)
      `uvm_error("TEST", "Phase C: train_ok not re-asserted after retrain")
    if (train_fail)
      `uvm_error("TEST", "Phase C: train_fail set after retrain")

    release_local_status(SIDE_A);
    release_local_status(SIDE_B);

    repeat (50) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TRAIN_ASYNC_RE_TRAIN_SV
