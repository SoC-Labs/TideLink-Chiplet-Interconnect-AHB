///////////////////////////////////////////////////////////////////////////////
// test_top_i1_controlplane.sv
///////////////////////////////////////////////////////////////////////////////
// I1 CONTROL-PLANE repro (sim/i1-controlplane-repro, 2026-07-30).
//
// Prior I1 sim attempts (test_top_i1_fcsm_bringup, the cocotb bringup-race env)
// FORCED cal_done (tb_early_exit_force_q) and used the sideband-FCSM CR state as
// oracle — they BYPASSED exactly the calibrator-ARM logic the silicon ILA found
// stuck. On silicon, with the AXI FCSM 0-4 pointed at src/rtl/local_overrides
// (the shipping I1 override), the bring-up leaves
//     role_locked = 0   and   swi_training_mode_r = 0
// so the arm   nego_en & role_locked & swi_training_mode_r   never fires and the
// calibrator never sweeps (cal_state = 0, ever_swept = 0). This is a CONTROL-
// PLANE (register/FSM) failure, NOT the analog capture the old sims couldn't
// model — role_lock / training / nego / calibrator-arm are ALL RTL logic a
// faithful sim CAN observe.
//
// This test drives the REAL PS-side bring-up recipe and observes the arm chain
// directly, WITHOUT the calibrator bypass (run with +NO_CAL_BYPASS). It is
// intended to be built once per FCSM_SRC (deps vs local) and diffed:
//   - deps  should be GREEN: role_locked->1, train->1, cal_state leaves 0 (armed)
//   - local should be RED   IFF the override has an RTL path to the arm chain.
//   If deps and local produce IDENTICAL arm-chain traces, the FCSM swap has NO
//   RTL control-plane path and the silicon role_locked=0 is above RTL (build /
//   packaged-IP / timing) — an honest NO-SPLIT result, reported as such.
//
// Modes (+CP_MODE):
//   manual (default) : nego_en=0. SW writes ROLE_CFG (mask_hs_bypass strapped
//                      open by tidelink_top) then R8 SWI_TRAINING_MODE=1. The
//                      calibrator arms on the role_locked rising edge. Clean
//                      positive control: proves the TB can SEE a calibrator arm.
//   auto             : nego_en=1 (silicon-faithful). Program NEGO_CFG=0x61, POR-
//                      re-arm, let the I2C autoneg FSM drive role_lock+training.
//
// Verdict GREEN iff, on BOTH dies: role_locked==1 && cal_state ever left 0.
// The [CPSIG] line is the full arm-chain vector for the external deps-vs-local
// diff. Always emits regardless of verdict.
//
// Plusargs:
//   +CP_MODE=manual|auto   bring-up path (default manual)
//   +CP_OBS_CYC=<N>        observation cycles after bring-up (default 40000)
//   +NO_CAL_BYPASS         (consumed in top.sv) MUST be set — disables the
//                          calibrator sim-bypass so the arm is a faithful oracle.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_I1_CONTROLPLANE_SV
`define GUARD_TEST_TOP_I1_CONTROLPLANE_SV

class test_top_i1_controlplane extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_i1_controlplane)

  // Absolute APB offsets in the unified config space.
  localparam bit [14:0] APB_ROLE_CFG   = 15'h2080; // [1]=role_lock W1S, [0]=role
  localparam bit [14:0] APB_NEGO_CFG    = 15'h2090; // Region4 slot4: [0]=nego_en
  localparam bit [14:0] APB_R8_SLOT0    = 15'h2100; // [0]=SWI_TRAINING_MODE

  localparam bit [31:0] ROLE_CFG_MASTER_LOCK = 32'h0000_0002; // lock, role=0(master)
  localparam bit [31:0] ROLE_CFG_SLAVE_LOCK  = 32'h0000_0003; // lock, role=1(slave)
  localparam bit [31:0] NEGO_CFG_AUTON        = 32'h0000_0061; // nego_en=1 + mask_hs_auto
  localparam bit [31:0] R8_TRAIN_ON           = 32'h0000_0001; // SWI_TRAINING_MODE=1

  string       cp_mode   = "manual";
  int unsigned cp_obs_cyc = 40000;

  // arm-chain accumulators
  bit          a_rl_ever, b_rl_ever;
  bit          a_tr_ever, b_tr_ever;
  int unsigned a_cal_max, b_cal_max;
  bit          a_cal_armed, b_cal_armed;   // cal_state ever left 0

  function new(string name = "test_top_i1_controlplane", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'($value$plusargs("CP_MODE=%s", cp_mode));
    void'($value$plusargs("CP_OBS_CYC=%d", cp_obs_cyc));
    test_timeout_cycles = 8_000_000;
  endfunction

  task apb_wr(side_t side, bit [14:0] addr, bit [31:0] data);
    integration_cfg_write_sequence wr;
    wr = integration_cfg_write_sequence::type_id::create("wr");
    wr.addr = addr; wr.data = data;
    if (side == SIDE_A) wr.start(env.a_apb_agt.sequencer);
    else                wr.start(env.b_apb_agt.sequencer);
  endtask

  // Snapshot + machine-readable signature line (external deps-vs-local diff).
  function void dump_cp(string tag);
    $display("[CP] %s  A[rl=%0b tr=%0b nego=%0b mgate=%0b mmatch=%0b calRL=%0b cal=%0d nst=%0d]  B[rl=%0b tr=%0b nego=%0b mgate=%0b mmatch=%0b calRL=%0b cal=%0d nst=%0d]",
      tag,
      tb_if.a_role_locked, tb_if.a_train_r, tb_if.a_nego_en, tb_if.a_mask_gate,
      tb_if.a_mask_match, tb_if.a_cal_role_locked, tb_if.a_cal_state, tb_if.a_nego_st,
      tb_if.b_role_locked, tb_if.b_train_r, tb_if.b_nego_en, tb_if.b_mask_gate,
      tb_if.b_mask_match, tb_if.b_cal_role_locked, tb_if.b_cal_state, tb_if.b_nego_st);
  endfunction

  function void sample();
    if (tb_if.a_role_locked) a_rl_ever = 1;
    if (tb_if.b_role_locked) b_rl_ever = 1;
    if (tb_if.a_train_r)     a_tr_ever = 1;
    if (tb_if.b_train_r)     b_tr_ever = 1;
    if (tb_if.a_cal_state > a_cal_max) a_cal_max = tb_if.a_cal_state;
    if (tb_if.b_cal_state > b_cal_max) b_cal_max = tb_if.b_cal_state;
    if (tb_if.a_cal_state != 0) a_cal_armed = 1;
    if (tb_if.b_cal_state != 0) b_cal_armed = 1;
  endfunction

  task settle(int unsigned n);
    repeat (n) @(posedge tb_if.clk);
    sample();
  endtask

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    if (!$test$plusargs("NO_CAL_BYPASS"))
      `uvm_warning("CP", "calibrator sim-bypass is ACTIVE (no +NO_CAL_BYPASS) — the cal_state arm observation is CONTAMINATED. Re-run with +NO_CAL_BYPASS for a faithful arm oracle.")

    $display("[CP_CFG] MODE=%s OBS_CYC=%0d NO_CAL_BYPASS=%0b", cp_mode, cp_obs_cyc,
             $test$plusargs("NO_CAL_BYPASS"));

    settle(50);
    dump_cp("t0-pre");

    if (cp_mode == "auto") begin
      // ---- AUTONOMOUS path (silicon-faithful): nego_en=1 + POR re-arm --------
      apb_wr(SIDE_A, APB_NEGO_CFG, NEGO_CFG_AUTON);
      apb_wr(SIDE_B, APB_NEGO_CFG, NEGO_CFG_AUTON);
      settle(50);
      dump_cp("post-nego-cfg");
      // POR re-arm so nego_en is re-evaluated out of reset (BYPASS is terminal).
      tb_if.force_poreset = 1'b1;
      repeat (40) @(posedge tb_if.clk);
      tb_if.force_poreset = 1'b0;
      settle(2000);
      dump_cp("post-por-rearm");
      // Faithful silicon recipe (kr260_eth_bringup.py): with nego_en=1 the HOST
      // STILL writes ROLE_CFG=0x02/0x03 explicitly. With mask_hs_bypass strapped
      // open (mgate=1, the TB default) this latches role_lock via the SW path;
      // the autoneg runs concurrently. If the autoneg reaches ST_NEGO_DONE it
      // also drives role_lock/training. Either way this is the real bring-up.
      apb_wr(SIDE_A, APB_ROLE_CFG, ROLE_CFG_MASTER_LOCK);
      apb_wr(SIDE_B, APB_ROLE_CFG, ROLE_CFG_SLAVE_LOCK);
      settle(1000);
      dump_cp("post-role-cfg");
    end else begin
      // ---- MANUAL path (clean positive control): SW ROLE_CFG then R8 train ----
      apb_wr(SIDE_A, APB_ROLE_CFG, ROLE_CFG_MASTER_LOCK);
      apb_wr(SIDE_B, APB_ROLE_CFG, ROLE_CFG_SLAVE_LOCK);
      settle(500);
      dump_cp("post-role-lock");
      // Assert SWI_TRAINING_MODE=1 on both dies (the arm's training term).
      apb_wr(SIDE_A, APB_R8_SLOT0, R8_TRAIN_ON);
      apb_wr(SIDE_B, APB_R8_SLOT0, R8_TRAIN_ON);
      settle(500);
      dump_cp("post-train-on");
    end

    // ---- Observation window: let the (real, un-bypassed) calibrator run ------
    begin
      int unsigned waited = 0;
      while (waited < cp_obs_cyc) begin
        settle(500);
        waited += 500;
        if ((waited % 10000) == 0)
          dump_cp($sformatf("obs@%0d", waited));
      end
    end
    dump_cp("final");

    // ---- Verdict + full signature -------------------------------------------
    $display("[CPSIG] MODE=%s  A[rl=%0b tr=%0b calArmed=%0b calMax=%0d]  B[rl=%0b tr=%0b calArmed=%0b calMax=%0d]",
             cp_mode, a_rl_ever, a_tr_ever, a_cal_armed, a_cal_max,
             b_rl_ever, b_tr_ever, b_cal_armed, b_cal_max);

    if (a_rl_ever && b_rl_ever && a_cal_armed && b_cal_armed) begin
      $display("[CP_VERDICT] GREEN: role_locked latched AND calibrator armed (left state 0) on BOTH dies (calMax A=%0d B=%0d)",
               a_cal_max, b_cal_max);
      `uvm_info("CP", "VERDICT=GREEN (control-plane arm chain completed on both dies)", UVM_LOW)
    end else begin
      $display("[CP_VERDICT] RED: arm chain stuck -- A[rl=%0b cal_armed=%0b] B[rl=%0b cal_armed=%0b] -- I1 control-plane signature",
               a_rl_ever, a_cal_armed, b_rl_ever, b_cal_armed);
      `uvm_error("CP", $sformatf(
        "VERDICT=RED: control-plane arm did not complete A[rl=%0b cal_armed=%0b] B[rl=%0b cal_armed=%0b] (calMax A=%0d B=%0d)",
        a_rl_ever, a_cal_armed, b_rl_ever, b_cal_armed, a_cal_max, b_cal_max))
    end

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_I1_CONTROLPLANE_SV
