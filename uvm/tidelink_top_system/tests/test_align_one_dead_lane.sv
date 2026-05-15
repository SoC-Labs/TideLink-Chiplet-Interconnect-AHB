///////////////////////////////////////////////////////////////////////////////
// test_align_one_dead_lane.sv — §9 broken-lane diagnostic
///////////////////////////////////////////////////////////////////////////////
// Forces lane 4 of the A->B path to stuck-at-0 via the perturb hook (set
// before link-up). All other lanes carry their normal skid. The training
// pattern for lane 4 is 8'h65 (non-trivial), so the deserialised word at
// the receiver will never match {0x65, 0x65} regardless of slip — the
// per-lane checker for lane 4 should remain unlocked while every other
// lane locks.
//
// The 7 healthy lanes should all calibrate successfully and report
// lane_locked == 1; lane 4 should report 0. Together this validates:
//   - calibration is per-lane (one dead lane doesn't block the others),
//   - the unlocked status is observable via the existing UVM hooks.
//
// To match the task description, we deliberately do NOT lane-mask out
// lane 4 — that would prevent the §9 RTL from even sampling it. The point
// here is the diagnostic visibility of an un-trainable lane.
//
// Note: with a dead lane the FCSM cannot reach state>=4 (one of the
// striped bytes is corrupted, so the cr_pkt never decodes), so we do NOT
// call init_system() after calibration — we stop at the lane_locked check.
// The follow-up step (auto-mask the dead lane and re-train) belongs to a
// future autoneg phase, not the §9 mechanism this test covers.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_ALIGN_ONE_DEAD_LANE_SV
`define GUARD_TEST_ALIGN_ONE_DEAD_LANE_SV

class test_align_one_dead_lane extends test_top_align_base;

  `uvm_component_utils(test_align_one_dead_lane)

  function new(string name = "test_align_one_dead_lane",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [2:0]     skids[8] = '{3,3,3,3,3,3,3,3};
    int unsigned  a_locked_count, b_locked_count;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_align_one_dead_lane (lane 4 of A->B stuck-at-0) ===", UVM_LOW)

    // Force lane 4 of the a2b path to stuck-at-0 before anything else,
    // so the very first cycles the slave RX sees on lane 4 are dead.
    tb_if.a2b_lane_perturb_en[4]  = 1'b1;
    tb_if.a2b_lane_perturb_val[4] = 1'b0;

    // Apply uniform skid on healthy lanes; the dead-lane perturb wins
    // because the perturb mux sits upstream of the skid module in top.sv.
    apply_skid_a2b(skids);
    apply_skid_b2a(skids);

    set_training_mode(SIDE_A, 1'b1);
    set_training_mode(SIDE_B, 1'b1);
    set_all_slip     (SIDE_A, 3'd0);
    set_all_slip     (SIDE_B, 3'd0);

    init_wlink();
    repeat (500) @(posedge tb_if.clk);

    calibrate_both(a_locked_count, b_locked_count);

    `uvm_info("TEST", $sformatf(
      "Final A.lane_locked=0x%02h (%0d locked)  B.lane_locked=0x%02h (%0d locked)",
      tb_if.a_lane_locked, a_locked_count,
      tb_if.b_lane_locked, b_locked_count), UVM_LOW)

    // A's RX (b2a path, no perturb) must achieve full lock.
    if (tb_if.a_lane_locked !== 8'hFF)
      `uvm_error("TEST", $sformatf(
        "A.lane_locked=0x%02h, expected 0xFF (b2a is healthy)",
        tb_if.a_lane_locked))

    // B's RX (a2b path with lane 4 dead) must have lane 4 unlocked but
    // every other lane locked → expected mask 0xEF.
    if (tb_if.b_lane_locked[4] !== 1'b0)
      `uvm_error("TEST", $sformatf(
        "B.lane_locked[4]=%0d, expected 0 (dead lane should never lock)",
        tb_if.b_lane_locked[4]))
    if (tb_if.b_lane_locked !== 8'hEF)
      `uvm_error("TEST", $sformatf(
        "B.lane_locked=0x%02h, expected 0xEF (lane 4 dead, others locked)",
        tb_if.b_lane_locked))

    `uvm_info("TEST", "Dead-lane diagnostic confirmed via b_lane_locked[4]=0", UVM_LOW)

    // Release the perturb so subsequent test runs see clean lanes.
    tb_if.a2b_lane_perturb_en[4] = 1'b0;

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_ALIGN_ONE_DEAD_LANE_SV
