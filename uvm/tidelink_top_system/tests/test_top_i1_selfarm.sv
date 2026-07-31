///////////////////////////////////////////////////////////////////////////////
// test_top_i1_selfarm.sv
///////////////////////////////////////////////////////////////////////////////
// T1 — I1 SELF_ARM_TRAIN_EN FIX-LOGIC regression (test/i1-selfarm-regression).
//
// WHAT THIS GATES
// ---------------
// The I1 eth-chiplet bring-up fix (fix/i1-selfarm-rolelock @43b5845,
// docs/I1_SELFARM_FIX.md): a default-OFF `SELF_ARM_TRAIN_EN` parameter on
// axi_chiplet_controller (threaded through tidelink_top) that latches
// role_lock_reg=1 on the SW ROLE_CFG[1] write WITHOUT waiting for the peer
// mask-handshake gate (mask_hs_gate_open) or the nego_lost_w fallback. On the
// eth-chiplet neither of those ever fires (its peer-I2C control plane never
// completes: nego_en=0, no peer mask verdict), so pre-fix role_lock stayed 0.
// role_locked is a MUTUAL CLOCK ENABLE (wlink_por_reset = ~role_locked), so a
// stuck-0 held every FCSM + the forwarded PHY clock in reset and the calibrator
// could never run (cal_done=0, fcsm=0). Self-latching on the explicit SW intent
// honours the design principle "role-lock must NEVER wait on a protocol event"
// (project_role_lock_is_a_mutual_clock_enable).
//
// HONESTY / SCOPE — THIS IS A FIX-LOGIC UNIT REGRESSION, *NOT* A SILICON REPRO
// ---------------------------------------------------------------------------
// The silicon I1 failure is ABOVE the synthesisable RTL a zero-BER sim compiles
// (packaged-IP / OOC-synth / reset-sequencing) — established by the companion
// control-plane repro, docs/I1_CONTROLPLANE_SIM.md: with the calibrator
// un-bypassed and the real ROLE_CFG/training bring-up driven, the FCSM
// deps->override swap moves NO arm-chain signal, so a faithful RTL sim is
// BLIND to the silicon role_locked=0. This test therefore does NOT reproduce
// the silicon deadlock. It asserts the FIX LOGIC directly on the real
// axi_chiplet_controller (via tidelink_top): that under the exact eth-chiplet
// control-plane condition (mask_hs gate engaged, nego_en=0), SELF_ARM_TRAIN_EN
// changes role_lock from "never latches" to "latches on the SW write". The
// silicon failure itself is gated only on KR260 HW (kr260_eth_regress); this
// suite guards the fix's RTL logic against regression / accidental default flip.
//
// SINGLE-SIM DISCRIMINATION (self-checking, instrument-trust baked in)
// -------------------------------------------------------------------
// tb/top.sv parameterises the two dies asymmetrically at COMPILE time:
//   die A  SELF_ARM_TRAIN_EN = 1   (when compiled with +define+TL_SELF_ARM_A_ON)
//   die B  SELF_ARM_TRAIN_EN = 0   (shipping default — the NEGATIVE CONTROL)
// Both dies are driven with IDENTICAL stimulus under the eth-chiplet condition.
//   * die A (fix ON)  MUST latch role_lock on the ROLE_CFG[1] write   -> POSITIVE
//   * die B (fix OFF) MUST NOT latch role_lock under the same stimulus -> NEG CTL
// If die B ALSO latched, the pass would be spurious (the strap/stimulus, not the
// param, would be doing the work) and the test FAILS — this is the
// verify-the-instrument check the project keeps re-learning it needs.
//
// DISCRIMINATION PROOF (the "negative control you run once"): recompiling
// WITHOUT +define+TL_SELF_ARM_A_ON makes die A *also* OFF, so CHK_FIX_LATCH_A
// fails and the whole test FAILS — proving the suite is not vacuously green.
// (Recorded in docs/I1_SELFARM_REGRESSION.md.)
//
// WHAT IS AND ISN'T ASSERTED
// --------------------------
// Asserted (all real RTL nets, sampled via tb_if — no forcing, no X-masking):
//   role_lock_reg, swi_training_mode_r, nego_en, mask_hs_gate_open,
//   mask_hs_match  (u_chiplet_controller.* mirrored onto tb_if in top.sv).
// NOT asserted: the calibrator actually SWEEPING (cal_state leaving 0). In this
// asymmetric config die A's rx_link_clk is the PEER's (die B's) forwarded
// pad_clk_tx, which die B — role_lock=0 — holds gated, so die A's calibrator
// (clocked on rx_link_clk) cannot advance. That coupling is the mutual-clock-
// enable itself, and the calibrator sweep is downstream of / independent from
// the fix logic (AUTOCAL_ENABLE defaults 0; arm = role_locked & autocal_enable).
// So we assert the ARM PRECONDITION the fix restores — role_locked=1 AND
// swi_training_mode_r=1 on die A (the two SW-owned terms of the calibrator arm
// become simultaneously satisfiable), vs the arm never being satisfiable on die
// B (role_locked stays 0). Per docs/I1_CONTROLPLANE_SIM.md the physical sweep is
// peer-clock-coupled and the silicon symptom is above-RTL anyway.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_I1_SELFARM_SV
`define GUARD_TEST_TOP_I1_SELFARM_SV

class test_top_i1_selfarm extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_i1_selfarm)

  // Absolute APB offsets in the unified config space (match the control-plane
  // repro / kr260_eth_bringup.py recipe).
  localparam bit [14:0] APB_ROLE_CFG = 15'h2080; // [1]=role_lock W1S, [0]=role
  localparam bit [14:0] APB_R8_SLOT0  = 15'h2100; // [0]=SWI_TRAINING_MODE

  localparam bit [31:0] ROLE_CFG_MASTER_LOCK = 32'h0000_0002; // lock, role=0(master)
  localparam bit [31:0] ROLE_CFG_SLAVE_LOCK  = 32'h0000_0003; // lock, role=1(slave)
  localparam bit [31:0] R8_TRAIN_ON           = 32'h0000_0001; // SWI_TRAINING_MODE=1

  int unsigned obs_cyc = 6000;   // sticky-hold observation window

  // Accumulators — sampled every settle() over the whole run.
  bit a_rl_ever, b_rl_ever;      // role_lock ever seen high
  bit a_tr_ever, b_tr_ever;      // training ever seen high
  bit a_mmatch_ever;             // die A mask_hs_match ever high (must stay 0)

  int unsigned fails;

  function new(string name = "test_top_i1_selfarm", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'($value$plusargs("SELFARM_OBS_CYC=%d", obs_cyc));
    test_timeout_cycles = 2_000_000;
  endfunction

  task apb_wr(side_t side, bit [14:0] addr, bit [31:0] data);
    integration_cfg_write_sequence wr;
    wr = integration_cfg_write_sequence::type_id::create("wr");
    wr.addr = addr; wr.data = data;
    if (side == SIDE_A) wr.start(env.a_apb_agt.sequencer);
    else                wr.start(env.b_apb_agt.sequencer);
  endtask

  function void sample();
    if (tb_if.a_role_locked) a_rl_ever = 1;
    if (tb_if.b_role_locked) b_rl_ever = 1;
    if (tb_if.a_train_r)     a_tr_ever = 1;
    if (tb_if.b_train_r)     b_tr_ever = 1;
    if (tb_if.a_mask_match)  a_mmatch_ever = 1;
  endfunction

  task settle(int unsigned n);
    repeat (n) @(posedge tb_if.clk);
    sample();
  endtask

  function void dump(string tag);
    $display("[I1SA] %-14s A[rl=%0b tr=%0b nego=%0b mgate=%0b mmatch=%0b]  B[rl=%0b tr=%0b nego=%0b mgate=%0b mmatch=%0b]",
      tag,
      tb_if.a_role_locked, tb_if.a_train_r, tb_if.a_nego_en, tb_if.a_mask_gate, tb_if.a_mask_match,
      tb_if.b_role_locked, tb_if.b_train_r, tb_if.b_nego_en, tb_if.b_mask_gate, tb_if.b_mask_match);
  endfunction

  // One assertion. cond==1 => PASS; else record a failure + UVM_ERROR.
  function void chk(string id, bit cond, string detail);
    if (cond) begin
      $display("[I1SA_CHK] PASS  %-22s %s", id, detail);
    end else begin
      fails++;
      $display("[I1SA_CHK] FAIL  %-22s %s", id, detail);
      `uvm_error("I1SA", $sformatf("%s FAILED: %s", id, detail))
    end
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    $display("[I1_SELFARM_CFG] eth-chiplet control-plane condition: mask_hs gate ENGAGED (bypass=0), nego_en=0.");
    $display("[I1_SELFARM_CFG] die A = SELF_ARM_TRAIN_EN(compile: +TL_SELF_ARM_A_ON) ; die B = shipping-default OFF (negative control).");

    // --- Engage the eth-chiplet condition ------------------------------------
    // Drop the mask-handshake bypass strap on BOTH dies so mask_hs_gate_open can
    // only open on a genuine peer mask verdict (which never arrives with
    // nego_en=0). This is the condition under which pre-fix role_lock CANNOT
    // latch — the whole reason the fix exists.
    tb_if.a_mask_hs_bypass = 1'b0;
    tb_if.b_mask_hs_bypass = 1'b0;
    settle(50);
    dump("t0-pre");

    // --- Instrument-trust preconditions (fail early if the setup is wrong) ----
    chk("PRE_A_UNLOCKED",  tb_if.a_role_locked == 1'b0, "die A role_locked must be 0 before any write");
    chk("PRE_B_UNLOCKED",  tb_if.b_role_locked == 1'b0, "die B role_locked must be 0 before any write");
    chk("GATE_ENGAGED_A",  tb_if.a_mask_gate   == 1'b0, "die A mask_hs_gate_open must be 0 (bypass dropped, no peer verdict)");
    chk("GATE_ENGAGED_B",  tb_if.b_mask_gate   == 1'b0, "die B mask_hs_gate_open must be 0 (bypass dropped, no peer verdict)");
    chk("NEGO_OFF_A",      tb_if.a_nego_en     == 1'b0, "die A nego_en must be 0 (eth-chiplet control-plane condition)");
    chk("NEGO_OFF_B",      tb_if.b_nego_en     == 1'b0, "die B nego_en must be 0 (eth-chiplet control-plane condition)");

    // --- SW ROLE_CFG[1] write (the bring-up intent) --------------------------
    // Master lock on A, slave lock on B — both set ROLE_CFG[1]=1, arming
    // nego_lock_pending_reg. With the gate engaged + nego_en=0, ONLY the
    // SELF_ARM_TRAIN_EN term can carry that intent into role_lock_reg.
    apb_wr(SIDE_A, APB_ROLE_CFG, ROLE_CFG_MASTER_LOCK);
    apb_wr(SIDE_B, APB_ROLE_CFG, ROLE_CFG_SLAVE_LOCK);
    settle(200);
    dump("post-role-cfg");

    // THE FIX (die A, param ON): role_lock latches WITHOUT the handshake/nego.
    chk("FIX_LATCH_A", tb_if.a_role_locked == 1'b1,
        "die A role_lock must LATCH on SW ROLE_CFG[1] via SELF_ARM_TRAIN_EN (no mask gate, no nego)");
    // NEGATIVE CONTROL (die B, param OFF): same stimulus, must NOT latch.
    chk("NEGCTL_B_NOLATCH", tb_if.b_role_locked == 1'b0,
        "die B role_lock must STAY 0 (default-OFF: no self-arm) — instrument-trust check");
    // The self-arm must NOT forge the genuine-integrity witness (mask_hs_match
    // stays 0; role latched via the self-arm term, not a faked peer match).
    chk("MASKMATCH_A_ZERO", tb_if.a_mask_match == 1'b0,
        "die A mask_hs_match must stay 0 — self-arm does not forge the mask-verified witness");

    // --- SW SWI_TRAINING_MODE=1 (the arm's training term) --------------------
    apb_wr(SIDE_A, APB_R8_SLOT0, R8_TRAIN_ON);
    apb_wr(SIDE_B, APB_R8_SLOT0, R8_TRAIN_ON);
    settle(200);
    dump("post-train-on");

    chk("TRAIN_A", tb_if.a_train_r == 1'b1,
        "die A swi_training_mode_r must be 1 after SW SWI_TRAINING_MODE write");
    // The two SW-owned terms of the calibrator arm are simultaneously satisfied
    // on die A => the calibrator arm is now SATISFIABLE (was unreachable pre-fix
    // because role_locked could never be 1).
    chk("ARM_PRECOND_A", (tb_if.a_role_locked && tb_if.a_train_r) == 1'b1,
        "die A calibrator arm precondition (role_locked & swi_training_mode_r) must be satisfiable");

    // --- Sticky-hold observation window --------------------------------------
    // role_lock is POR-clear-only: once latched on A it must hold; on B it must
    // never appear for the entire window.
    begin
      int unsigned waited = 0;
      while (waited < obs_cyc) begin
        settle(500);
        waited += 500;
        chk($sformatf("HOLD_A@%0d", waited), tb_if.a_role_locked == 1'b1,
            "die A role_lock must HOLD (POR-clear-only)");
        chk($sformatf("NEGCTL_B@%0d", waited), tb_if.b_role_locked == 1'b0,
            "die B role_lock must never latch across the whole window");
      end
    end
    dump("final");

    // --- Aggregate cross-checks over the whole run ---------------------------
    chk("A_RL_EVER",       a_rl_ever    == 1'b1, "die A role_lock was observed high at least once");
    chk("B_RL_NEVER",      b_rl_ever    == 1'b0, "die B role_lock was NEVER observed high (negative control)");
    chk("A_MMATCH_NEVER",  a_mmatch_ever == 1'b0, "die A mask_hs_match was NEVER high (witness not forged)");

    // --- Verdict + machine-readable signature (gate greps these) -------------
    $display("[I1_SELFARM_SIG] A[rl_ever=%0b tr_ever=%0b mmatch_ever=%0b]  B[rl_ever=%0b tr_ever=%0b]  fails=%0d",
             a_rl_ever, a_tr_ever, a_mmatch_ever, b_rl_ever, b_tr_ever, fails);
    if (fails == 0) begin
      $display("[I1_SELFARM_VERDICT] PASS: SELF_ARM_TRAIN_EN latches role_lock on die A (fix ON) and NOT on die B (default OFF); training + arm precondition satisfiable on A.");
    end else begin
      $display("[I1_SELFARM_VERDICT] FAIL: %0d check(s) failed — SELF_ARM discrimination not proven (see [I1SA_CHK] FAIL lines above).", fails);
    end
    $display("[I1_SELFARM_DONE]");

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_I1_SELFARM_SV
