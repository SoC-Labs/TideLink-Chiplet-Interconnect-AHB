"""R5 — die_a-first terminal stall (zombie-peer trap) auto-retry gate.

Silicon mechanism (root-caused, 3-agent read-only panel 2026-07-02)
-------------------------------------------------------------------
When die_a (master-strapped) arms FIRST, the un-armed slave die is a
"zombie": its I2C slave core is alive and ACKs everything at the POR
device_address 0x7E (axi_chiplet_controller.sv — role_in_nego mux + POR
i2c_slv_addr_reg=0x7E), but its Wlink link core and calibrator are held in
POR reset (wlink_por_reset = ~poresetn | ~role_locked). The early-armed
master therefore:

  * WINS the I2C claim (zombie ACKs) and role-locks as master;
  * walks the whole mask-handshake + training sequence against the zombie
    (the zombie's Wlink APB register file rides apb_reset, so reads/writes
    complete — with all-zero lane status);
  * cannot lock its OWN lanes (the zombie's TX is dead), so the N10
    local-only bypass can't fire either;
  * exhausts the poll budget (NEGO_TRAIN_CFG[7:4], default 16 attempts) and
    parks TERMINAL in ST_TRAIN_FAIL — which is EXCLUDED from the AXIL drive
    gate, so the master goes I2C-SILENT FOREVER. The slave, arming late, is
    never polled; the pair is dead until a SW W1P train_retrain_req.

The R5 fix (tidelink_autoneg.sv): in ST_TRAIN_FAIL, when train_auto_en and a
~0.3 s backoff (retry_backoff_r, TB-shrinkable via tb_retry_backoff_short_q)
expires, take the EXISTING train_retrain_req arc to ST_NEGO_DONE_PRE AND
reload timeout_ctr with nego_timeout_reg (else ~50 retries would drain the
global budget into terminal ST_ERROR). Retry-forever = the intended "wait
for the partner" semantics. Gated under USE_CAL_IN_HOLD (V2); the V1 netlist
constant-folds the branch away. The controller's sticky train_fail_irq_r is
kept for diagnosability (asserted below).

What this test does
-------------------
Unlike test_31 (BYPASS_AUTONEG=0 arms BOTH dies at t=0 via the tb force),
this test builds with BYPASS_AUTONEG=1 (NO tb force) and staggers the arming
itself over the REAL APB programming interface (the harness supports this:
tb_top ties apb_debug_unlock=1 and the PairTB ApbMaster drives the same
paddr map SW uses):

  1. POR; deposit the designed-in sim hooks on both dies
     (tb_retry_backoff_short_q / tb_winscan_dwell_short_q /
     tb_fch_dwell_short_q) + the flat-0 eye model (test_31's idiom);
  2. arm the MASTER ONLY: NEGO_PRIORITY(0x2098)=1,
     NEGO_TRAIN_CFG(0x210C)=0x0021 (train_auto_en=1, poll budget 2 — a pure
     timing shrink of the 16-attempt default so the FAIL arrives in-window),
     NEGO_CFG(0x2090)=0x61 (nego_en + force_lock + mask_hs_auto_en);
  3. WAIT for the master's autoneg to park in ST_TRAIN_FAIL against the
     zombie slave (assert the slave really is a zombie: role_locked=0,
     autoneg in ST_BYPASS) and assert the sticky train_fail_irq_r latched;
  4. arm the SLAVE the same way (priority=2) — its claim gets no ACK (the
     master's I2C slave core is in reset post-role-lock) -> MISS_ACK loser
     branch -> role-locks as slave -> its Wlink/cal leave POR reset;
  5. assert the master's backoff retry CONVERGES: master re-enters
     ST_TRAIN_ENTER (probed state history THROUGH ST_TRAIN_FAIL), reaches
     ST_TRAIN_DONE/train_ok, BOTH calibrators reach S_DONE, and BOTH FCSMs
     reach 4 (data mode) — reusing test_31's monitors.

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_l5 SIM=vcs \
      make MODULE=test_32_die_a_first_zombie_retry
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force

from test_tidelink_pair_doorbell import PairTB

# Reuse test_31's hierarchy accessors + reset/idle helpers and encodings
# (cocotb only collects tests from $MODULE, so the import is side-effect-free
# — same precedent as test_30 importing the doorbell harness).
from test_31_autonomous_training_exit import (
    _ctrl, _cal, _autoneg, _fcsm, _si,
    _idle_stimulus, _reset,
    CAL_S_DONE, CAL_NAMES,
    ST_TRAIN_EXIT, ST_TRAIN_DONE, ST_TRAIN_FAIL,
)

CLK_PERIOD_NS = 20.0

# Autoneg state encodings (tidelink_autoneg.sv) beyond test_31's exports.
ST_BYPASS       = 6
ST_ERROR        = 7
ST_TRAIN_ENTER  = 12

# TideLink APB paddr map (ctrl_reg_addr = {paddr[8:7], paddr[4:2]}):
#   Region 4 slot 4 -> NEGO_CFG        (SoC 0x4403_2090)
#   Region 4 slot 6 -> NEGO_PRIORITY   (SoC 0x4403_2098)
#   Region 8 slot 3 -> NEGO_TRAIN_CFG  (SoC 0x4403_210C)
APB_NEGO_CFG       = 0x2090
APB_NEGO_PRIORITY  = 0x2098
APB_NEGO_TRAIN_CFG = 0x210C

NEGO_CFG_ARM = 0x61      # [0] nego_en, [5] force_lock, [6] mask_hs_auto_en
# train_auto_en=1, poll budget [7:4]=2 (timing shrink of the default 16 so
# the zombie-poll FAIL lands in the sim window; 0 would select the default).
NEGO_TRAIN_CFG_ARM = 0x0021


async def _wait_autoneg_state(dut, side, targets, max_cycles, poll=50,
                              log_every=100_000, seen=None):
    """Poll `side`'s autoneg state_r until it lands in `targets`; optionally
    record every observed state in `seen` (state-history probe)."""
    log = dut._log
    if isinstance(targets, int):
        targets = {targets}
    an = _autoneg(dut, side)
    waited, last_log = 0, 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        st = _si(an.state_r)
        if seen is not None and st >= 0:
            seen.add(st)
        if st in targets:
            return st, waited
        if waited - last_log >= log_every:
            last_log = waited
            log.info(f"[{side}] an_state={st} waiting for {sorted(targets)} "
                     f"t={waited*CLK_PERIOD_NS/1000:.0f}us")
    return -1, waited


async def _apb_arm(tb, side, priority):
    """Arm one die's autoneg over the real APB programming interface."""
    apb = tb.m_apb if side == "m" else tb.s_apb
    await apb.write(APB_NEGO_PRIORITY, priority)
    await apb.write(APB_NEGO_TRAIN_CFG, NEGO_TRAIN_CFG_ARM)
    await apb.write(APB_NEGO_CFG, NEGO_CFG_ARM)


@cocotb.test()
async def test_32_die_a_first_zombie_retry(dut):
    log = dut._log
    log.info("R5 — die_a-first zombie-peer trap: auto-retry from ST_TRAIN_FAIL")

    tb = PairTB(dut)
    await _idle_stimulus(dut)
    await _reset(dut)

    # ---- Designed-in sim hooks (timing accommodations, not state bypasses) --
    #  * tb_retry_backoff_short_q: R5 backoff 0.3s -> 20k cycles;
    #  * tb_winscan_dwell_short_q + flat-0 eye model: test_31's (f) idiom so
    #    the post-retry winscan + fch bootstrap run in-window (the flat metric
    #    trips the R2c degenerate guard -> seeded taps, the safe sim outcome);
    #  * tb_fch_dwell_short_q: R4c 0.25s swreset dwell -> the proven 4095;
    #  * tb_ws_anchor_short_q: F4 WS_FINALIZE anchor gate timeout 0.3s -> 50k
    #    (REQUIRED here: the master's zombie-phase winscan episodes run with a
    #    beacon-less peer, so the anchor gate can only exit via the timeout);
    #  * tb_syncoff_settle_short_q: F2 SYNC-OFF settle 0.5s -> the proven 1024.
    for side in ("m", "s"):
        _autoneg(dut, side).tb_retry_backoff_short_q.value = 1
        _ctrl(dut, side).tb_winscan_dwell_short_q.value = 1
        _ctrl(dut, side).tb_fch_dwell_short_q.value = 1
        _ctrl(dut, side).tb_ws_anchor_short_q.value = 1
        _ctrl(dut, side).tb_syncoff_settle_short_q.value = 1
        _ctrl(dut, side).obs_sync_dist_vec_w.value = Force(0)

    # De-forced calibrators (test_31 contract): the sim bypass must be OFF.
    for side in ("m", "s"):
        assert _si(_cal(dut, side).tb_early_exit_force_q) == 0, \
            f"[{side}] calibrator sim bypass engaged — this test must be de-forced"

    # ---- Pre-condition: NOBODY armed; both autonegs parked in ST_BYPASS -----
    await ClockCycles(dut.hclk, 200)
    for side in ("m", "s"):
        st = _si(_autoneg(dut, side).state_r)
        assert st == ST_BYPASS, (
            f"[{side}] autoneg not parked in ST_BYPASS pre-arm (state={st}) — "
            f"BYPASS_AUTONEG=1 build expected (no tb force)")

    # ---- (2) Arm the MASTER ONLY --------------------------------------------
    m_states = set()
    await _apb_arm(tb, "m", priority=1)
    log.info("MASTER armed via APB (NEGO_CFG=0x61); slave left un-armed (zombie)")

    # ---- (3) Master must park in ST_TRAIN_FAIL against the zombie -----------
    st, w = await _wait_autoneg_state(dut, "m", ST_TRAIN_FAIL,
                                      max_cycles=3_000_000, seen=m_states)
    assert st == ST_TRAIN_FAIL, (
        f"MASTER never reached ST_TRAIN_FAIL against the zombie peer "
        f"(state={_si(_autoneg(dut,'m').state_r)} after {w} cycles, "
        f"seen={sorted(m_states)}) — the die_a-first trap did not reproduce")
    log.info(f"MASTER parked in ST_TRAIN_FAIL at t={w*CLK_PERIOD_NS/1000:.0f}us "
             f"(states seen: {sorted(m_states)})")

    # The zombie premise: the slave is STILL un-armed/un-locked with its
    # autoneg in ST_BYPASS and its Wlink/cal in POR reset.
    assert _si(_autoneg(dut, "s").state_r) == ST_BYPASS, \
        "slave autoneg left ST_BYPASS while un-armed — not a zombie scenario"
    assert _si(dut.s_role_locked) == 0, \
        "slave role_locked while un-armed — the zombie premise is broken"

    # Diagnosability kept (R5 requirement): the sticky train_fail_irq_r
    # latched on the FAIL entry even though the FSM will now auto-retry.
    assert _si(_ctrl(dut, "m").train_fail_irq_r) == 1, (
        "MASTER train_fail_irq_r did NOT latch sticky on ST_TRAIN_FAIL — "
        "R5 must keep the FAIL diagnosable across auto-retries")

    # The master must be RETRYING (not terminally silent): observe it leave
    # ST_TRAIN_FAIL for ST_NEGO_DONE_PRE/ST_TRAIN_ENTER at least once while
    # the peer is still a zombie (backoff = 20k cycles via the hook).
    st, w2 = await _wait_autoneg_state(dut, "m", ST_TRAIN_ENTER,
                                       max_cycles=1_500_000, seen=m_states)
    assert st == ST_TRAIN_ENTER, (
        f"MASTER never re-entered ST_TRAIN_ENTER after ST_TRAIN_FAIL "
        f"(seen={sorted(m_states)}) — the R5 auto-retry arc did not fire "
        f"(pre-fix behaviour: I2C-silent forever)")
    log.info(f"MASTER auto-retry observed (TRAIN_FAIL -> ... -> TRAIN_ENTER) "
             f"after +{w2*CLK_PERIOD_NS/1000:.0f}us")

    # ---- (4) NOW arm the slave (the late die arrives) ------------------------
    await _apb_arm(tb, "s", priority=2)
    log.info("SLAVE armed via APB — master's next retry should converge")

    # ---- (5) Convergence: master through FAIL to DONE; both cals S_DONE;
    #      both FCSMs reach 4 ---------------------------------------------------
    seen_done = {"m": False, "s": False}
    train_ok_seen = False
    MAX_CYCLES = 8_000_000
    POLL = 50
    waited = 0
    last_log = 0
    while waited < MAX_CYCLES:
        await ClockCycles(dut.hclk, POLL)
        waited += POLL
        m_st = _si(_autoneg(dut, "m").state_r)
        if m_st >= 0:
            m_states.add(m_st)
        if _si(_autoneg(dut, "m").train_ok_r) == 1:
            train_ok_seen = True
        for side in ("m", "s"):
            if _si(_cal(dut, side).cur_state) == CAL_S_DONE:
                seen_done[side] = True
        if waited - last_log >= 200_000:
            last_log = waited
            log.info(
                f"t={waited*CLK_PERIOD_NS/1000:.0f}us  "
                f"M an={m_st} ok={train_ok_seen} cal={CAL_NAMES.get(_si(_cal(dut,'m').cur_state))} "
                f"| S an={_si(_autoneg(dut,'s').state_r)} "
                f"cal={CAL_NAMES.get(_si(_cal(dut,'s').cur_state))} "
                f"rl={_si(dut.s_role_locked)}")
        if train_ok_seen and all(seen_done.values()):
            break

    # State-history probe: the master's path went THROUGH ST_TRAIN_FAIL and
    # back out (17 -> ... -> 12 -> ... -> 16), never into terminal ST_ERROR.
    log.info(f"MASTER autoneg state history: {sorted(m_states)}")
    assert ST_TRAIN_FAIL in m_states, "history lost ST_TRAIN_FAIL (probe bug?)"
    assert ST_ERROR not in m_states, (
        "MASTER autoneg hit terminal ST_ERROR — the R5 retry arc must RELOAD "
        "timeout_ctr with nego_timeout_reg (retries drained the global budget)")
    assert train_ok_seen, (
        f"MASTER never reached train_ok after the slave armed "
        f"(an={_si(_autoneg(dut,'m').state_r)}, history={sorted(m_states)}) — "
        f"the auto-retry did not converge")
    assert ST_TRAIN_DONE in m_states or train_ok_seen, \
        "train_ok without ST_TRAIN_DONE observed — probe inconsistency"

    # Both calibrators fully calibrated (the zombie came alive and trained).
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert seen_done[side], (
            f"{name} calibrator never reached S_DONE after the late arm "
            f"(cal={CAL_NAMES.get(_si(_cal(dut,side).cur_state))}) — "
            f"the retry-driven bilateral training did not complete")
    assert _si(dut.s_role_locked) == 1, "slave never role-locked after arming"

    # FCSM data mode on BOTH dies (post winscan + fch bootstrap, exactly the
    # test_31 (7)/(9) oracle).
    fc_ok = {"m": False, "s": False}
    for _ in range(6000):
        await ClockCycles(dut.hclk, 200)
        for side in ("m", "s"):
            if _si(_fcsm(dut, side).state) == 4:
                fc_ok[side] = True
        if all(fc_ok.values()):
            break
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert fc_ok[side], (
            f"{name} FCSM never reached 4 (data mode) after the retry "
            f"convergence (fcsm={_si(_fcsm(dut, side).state)})")

    log.info("VERDICT: PASS — die_a-first zombie trap reproduced (master parked "
             "ST_TRAIN_FAIL, sticky IRQ latched, slave verified zombie), the R5 "
             "backoff retry kept re-polling (FAIL->DONE_PRE->TRAIN_ENTER), and "
             "once the slave armed late the pair converged: master train_ok "
             "through ST_TRAIN_FAIL history, both cals S_DONE, both FCSM=4, "
             "no ST_ERROR (global budget reloaded per retry).")
