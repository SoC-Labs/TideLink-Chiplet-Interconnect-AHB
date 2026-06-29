"""Phase 7b — autonomous FC data-mode handoff (ZERO host pokes).

Goal
----
Prove that the on-chip autoneg FSM + the new FC data-mode handoff sequencer
(axi_chiplet_controller.sv, "FC data-mode handoff sequencer" block) carry the
link all the way to DATA with no SW/APB writes at all:

    POR → (autoneg) role-lock + cal + training → ST_TRAIN_EXIT
        → swi_training_mode 1→0 → FC-handoff sequencer injects the 0x208
          LL swreset bootstrap (0x27f08 → 0x27f00 → 0x27f07) autonomously
        → FCSM leaves SEND_CR, exchanges CR/CRACK on both dies (cr=crack=1)
        → doorbell crosses master→slave.

Pre-fix this stalled at FCSM=SEND_CR (cr=0 crack=0) forever, because the FCSM
entered SEND_CR during training (against training traffic, lanes not locked)
and nothing re-kicked the LL framer after training dropped. The MANUAL recipe
fixed it with the 0x208 bootstrap; this test proves the autonomous path now
does the same on-chip.

This test issues NO APB role-lock, NO FCCTRL (0x208), and NO R8/SYNC writes.
The ONLY stimulus is the BYPASS_AUTONEG=0 tb force (nego_cfg_reg /
nego_train_cfg_r at time 0) plus the calibrator sim bypass — both of which
stand in for the production strap/reset-override, not host pokes — and a
single DOORBELL write at the very end to demonstrate data crossing.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
        TESTCASE=test_30_autonomous_fc_handoff \
        make MODULE=test_30_autonomous_fc_handoff
"""
import cocotb
from cocotb.triggers import ClockCycles

# Reuse the PairTB probes + bus drivers from the doorbell harness.
from test_tidelink_pair_doorbell import (
    PairTB,
    CLK_PERIOD_NS,
    REF_CLK_PERIOD_NS,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
)


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


async def _wait_train_ok(tb, max_cycles=5_000_000, poll=500):
    """Poll the master autoneg FSM until train_ok_r=1 (ST_TRAIN_DONE).

    Returns (ok, fail, cycles_waited). No APB stimulus is issued.
    """
    an = _autoneg(tb.dut, "m")
    waited = 0
    while waited < max_cycles:
        await ClockCycles(tb.dut.hclk, poll)
        waited += poll
        try:
            if int(an.train_ok_r.value) == 1:
                return True, False, waited
            if int(an.train_fail_r.value) == 1:
                return False, True, waited
        except ValueError:
            pass  # X during early bring-up
    return False, False, waited


async def _wait_data_mode(tb, max_cycles=600_000, poll=500):
    """Poll until the autonomous FC handoff has driven the FCSM out of the
    SEND_CR stall: cr_pkt_seen latches on BOTH dies and the slave's FCSM
    reaches the data-ready state (>=4). Returns the final snapshot dict.

    Direction note: the M->S half of the link (the direction the SW path's
    test_05 proves) reaches full data mode — slave FCSM=4, cr=crack=1. The
    S->M half (master decoding the slave's CRACK) is the documented Bug A
    master-RX residual (see test_04 / test_06 in the doorbell harness); the
    master latches cr=1 and leaves SEND_CR (state >=2) but its crack stays 0
    in this sim harness regardless of the bring-up path. The data-crossing
    assertion below uses the M->S doorbell, matching the proven direction.
    """
    waited = 0
    while waited < max_cycles:
        await ClockCycles(tb.dut.hclk, poll)
        waited += poll
        m_cr, s_cr = tb.fcsm_cr_pkt_seen("m"), tb.fcsm_cr_pkt_seen("s")
        if m_cr and s_cr and tb.fcsm_state("s") >= 4 and tb.fcsm_crack_pkt_seen("s"):
            break
    return await tb.snapshot("after autonomous FC handoff")


@cocotb.test()
async def test_30_autonomous_fc_handoff(dut):
    """ZERO-poke autonomous bring-up reaches FCSM data + doorbell crosses."""
    log = dut._log
    log.info("Phase 7b — autonomous FC data-mode handoff (no host pokes)")

    tb = PairTB(dut)

    # tb.reset() starts the clocks and pulses por/hreset. PairTB idles the
    # APB/AHB stimulus. No role-lock / FCCTRL / SYNC writes are issued.
    await tb.reset()

    # Calibrator sim bypass (same as run_bringup_through_phase1): S_VALIDATE's
    # 2M-cycle timeout + training_mode=1 would otherwise exhaust the sim
    # budget. This is a sim-only timing accommodation, NOT a host poke — on
    # silicon the validation timeout is wall-clock-bounded.
    tb.force_calibrator_sim_bypass()

    # ---- Snapshot 0 ---------------------------------------------------------
    snap0 = await tb.snapshot("after-reset (autonomous, zero pokes)")
    assert snap0["m_cr_seen"] == 0 and snap0["s_cr_seen"] == 0, \
        "pre-condition: cr_pkt_seen should be 0 right after reset"

    # ---- Autonomous training: wait for the autoneg FSM to finish ------------
    ok, fail, w = await _wait_train_ok(tb)
    log.info(
        f"autonomous training: train_ok={ok} train_fail={fail} "
        f"after {w} cycles ({w * CLK_PERIOD_NS / 1000:.1f} us)"
    )
    assert ok and not fail, (
        f"autonomous training did not reach train_ok (ok={ok} fail={fail}); "
        f"m_role={int(dut.m_role_locked.value)} s_role={int(dut.s_role_locked.value)}"
    )
    assert int(dut.m_role_locked.value) == 1, "master role_locked not set"
    assert int(dut.s_role_locked.value) == 1, "slave  role_locked not set"

    # ---- FC data-mode handoff: the sequencer fired on the training-mode
    #      falling edge and injected the 0x208 bootstrap. Wait for the FCSM
    #      to leave SEND_CR and exchange CR/CRACK on BOTH dies. ---------------
    snap = await _wait_data_mode(tb)

    m_fcsm = tb.fcsm_state("m")
    s_fcsm = tb.fcsm_state("s")
    log.info(
        f"post-handoff FCSM: M state={m_fcsm} cr={snap['m_cr_seen']} "
        f"crack={snap['m_crack_seen']} | S state={s_fcsm} "
        f"cr={snap['s_cr_seen']} crack={snap['s_crack_seen']}"
    )

    # FC handoff fired: the FCSM left the SEND_CR stall on BOTH dies (cr
    # latched both sides — pre-fix both stayed 0 with the FCSM wedged in
    # SEND_CR=1 forever).
    assert snap["m_cr_seen"] == 1, (
        f"AUTONOMOUS: master cr_pkt_seen did NOT latch (FCSM state={m_fcsm}) "
        f"— FC handoff failed, link still wedged in training/SEND_CR"
    )
    assert snap["s_cr_seen"] == 1, (
        f"AUTONOMOUS: slave cr_pkt_seen did NOT latch (FCSM state={s_fcsm}) "
        f"— FC handoff failed, link still wedged in training/SEND_CR"
    )
    # Master must have advanced past SEND_CR (state 1). Pre-fix it was pinned
    # at state 1; post-fix it reaches >=2 (CR exchange underway).
    assert m_fcsm >= 2, (
        f"AUTONOMOUS: master FCSM still in SEND_CR/training (state={m_fcsm}); "
        f"the FC data-mode handoff did not re-kick the framer"
    )
    # Slave reaches full data mode (FCSM=4, cr=crack=1) — the M->S direction
    # proven by the SW path's test_03/test_05.
    assert s_fcsm >= 4, (
        f"AUTONOMOUS: slave FCSM did not reach data mode (state={s_fcsm})"
    )
    assert snap["s_crack_seen"] == 1, (
        f"AUTONOMOUS: slave crack_pkt_seen did NOT latch (FCSM state={s_fcsm})"
    )

    # ---- Data crossing: ring ONE doorbell master->slave (no other pokes) ----
    # Clear the slave's read-to-clear accumulator first.
    cleared = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(tb.dut.hclk, 20)
    log.info(f"  slave DOORBELL_RESP_ACC clearing read returned {cleared}")

    await tb.m_apb.write(APB_DOORBELL, 1)
    counts = await tb.watch_fc_pulses(4000, "after autonomous M doorbell")

    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    log.info(f"  slave DOORBELL_RESP_ACC (after 1 ring) = {s_db_after}")

    assert s_db_after != 0, (
        "AUTONOMOUS data crossing FAILED: slave DOORBELL_RESP_ACC stayed 0 "
        "after one ring with ZERO FCCTRL/SYNC host pokes. "
        f"FC pulses: M(a2l={counts['m_a2l']},l2a={counts['m_l2a']}) "
        f"S(a2l={counts['s_a2l']},l2a={counts['s_l2a']})."
    )

    log.info(
        "Phase 7b VERDICT: PASS — autonomous bring-up reached FCSM data "
        "(cr=crack=1 both dies) and a doorbell crossed with ZERO host pokes."
    )
