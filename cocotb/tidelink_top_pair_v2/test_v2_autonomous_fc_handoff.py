"""Phase 7b (V2 base) — autonomous FC data-mode handoff over the V2 deskew
path, ZERO host pokes.

Goal
----
Prove on the PROVEN V2 base (full-range IDELAY + cross-lane deskew + calibrator
credit-fix) that the on-chip autoneg FSM + the FC data-mode handoff sequencer
(axi_chiplet_controller.sv, "FC data-mode handoff sequencer" block) carry the
link all the way to byte-exact A->B DATA with NO SW/APB writes at all:

    POR -> (autoneg) role-lock + cal + training -> ST_TRAIN_EXIT
        -> swi_training_mode 1->0 -> FC-handoff sequencer injects the 0x208
           LL swreset bootstrap (0x27f08 -> 0x27f00 -> 0x27f07) autonomously
        -> FCSM leaves SEND_CR, exchanges CR/CRACK on both dies (cr=crack=1)
        -> a real AHB packet crosses M->S and byte-compares in the slave's
           RX FIFO (exercises the V2 deskew RX).

The cal-preserve gate (cal_eye_converged_r) keeps the master's converged eye
through the handoff so the master RX stays locked and decodes the inbound
CRACK; the V2 calibrator's own calibrated_once_q credit-fix masks the same
re-arm downstream (belt-and-suspenders).

This test issues NO APB role-lock, NO FCCTRL (0x208), and NO R8/SYNC writes.
The ONLY stimulus is the BYPASS_AUTONEG=0 tb force (nego_cfg_reg /
nego_train_cfg_r at time 0) + the calibrator sim bypass — both stand-ins for
the production strap/reset-override, not host pokes — plus the AHB packet
itself (the payload being delivered).

Run
---
    cd cocotb/tidelink_top_pair_v2
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
        TESTCASE=test_v2_autonomous_fc_handoff \
        make MODULE=test_v2_autonomous_fc_handoff
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB,
    CLK_PERIOD_NS,
    send_and_check,
)


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


async def _wait_train_ok(tb, max_cycles=5_000_000, poll=500):
    """Poll the master autoneg FSM until train_ok_r=1 (ST_TRAIN_DONE).
    Returns (ok, fail, cycles). No APB stimulus is issued."""
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
            pass
    return False, False, waited


async def _wait_data_mode(tb, max_cycles=800_000, poll=500):
    """Poll until the autonomous FC handoff has driven the FCSM out of the
    SEND_CR stall: cr latches on BOTH dies and BOTH FCSMs reach the data-ready
    state (LINK_IDLE = 4) with crack latched. Returns the final snapshot."""
    waited = 0
    while waited < max_cycles:
        await ClockCycles(tb.dut.hclk, poll)
        waited += poll
        if (tb.fcsm_cr_seen("m") == 1 and tb.fcsm_cr_seen("s") == 1 and
                tb.fcsm_crack_seen("m") == 1 and tb.fcsm_crack_seen("s") == 1 and
                tb.fcsm_state("m") == 4 and tb.fcsm_state("s") == 4):
            break
    return await tb.snapshot("after autonomous FC handoff (V2)")


# 2026-07-11: the historical unconditional skip cited a "harness gap" that was actually a
# Makefile omission — the v2 Makefile never plumbed TB_TOP_BYPASS_AUTONEG (the v1 Makefile
# does). It is now plumbed + exported (BYPASS_AUTONEG, default 1). This test needs the
# autonomous force ENGAGED, i.e. run it with `make BYPASS_AUTONEG=0`; under the default
# (=1) the tb parks in ST_BYPASS, so we skip rather than spuriously fail. With
# BYPASS_AUTONEG=0 it RUNS GREEN (bilateral fcsm=4, byte-exact M->S, zero pokes).
@cocotb.test(skip=(os.environ.get("BYPASS_AUTONEG", "1") != "0"))
async def test_v2_autonomous_fc_handoff(dut):
    """ZERO-poke autonomous bring-up on the V2 deskew base reaches bilateral
    FCSM=4 and a byte-exact packet crosses M->S.

    HARNESS GAP (2026-06-29): currently SKIPPED. On the tidelink_top_pair_v2
    testbench the BYPASS_AUTONEG=0 `force` on nego_cfg_reg does NOT engage the
    autoneg FSM — the FSM samples nego_en=0 in ST_IDLE and parks in ST_BYPASS
    (state 6), so autonomous role-lock/training never runs. This is a tb-side
    issue specific to the v2 harness (its per-die por_gate + the `#5000;
    release` of the force, vs the tidelink_top_pair harness which holds the
    force for the whole sim) and is INDEPENDENT of the RTL fix under test.

    The same RTL fix IS proven autonomous on the V2 RTL via
    cocotb/tidelink_top_pair/test_30_autonomous_fc_handoff.py run with
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 (compiles flists/tidelink_fpga_v2.flist
    = the full V2 deskew stack): bilateral FCSM=4 cr=crack=1 + doorbell
    crosses, zero pokes. And the V2 deskew DATA path is proven by
    test_v2_pair_data test_02/03 (byte-exact M->S + S->M). This test is kept
    (skipped) as the eventual single-harness autonomous+deskew+skew proof once
    the v2-tb force is repaired."""
    log = dut._log
    log.info("Phase 7b (V2) — autonomous FC data-mode handoff, no host pokes")

    tb = PairV2TB(dut)
    # PairV2TB.__init__ starts clocks + idles AHB; APBMaster idles the APB.
    # reset() pulses por/hreset. No role-lock / FCCTRL / SYNC writes issued.
    await tb.reset()

    # Calibrator sim bypass (skip the S_HOLD dwell + 2M-cycle S_VALIDATE that
    # is infeasible in sim). Sim-timing accommodation, NOT a host poke.
    tb.force_calibrator_sim_bypass()

    # Pre-condition: link not yet up.
    assert tb.fcsm_cr_seen("m") in (0, -1) and tb.fcsm_cr_seen("s") in (0, -1), \
        "pre-condition: cr_pkt_seen should be 0 right after reset"

    # ---- Autonomous training (no APB) --------------------------------------
    ok, fail, w = await _wait_train_ok(tb)
    log.info(f"autonomous training: train_ok={ok} train_fail={fail} "
             f"after {w} cycles ({w * CLK_PERIOD_NS / 1000:.1f} us)")
    assert ok and not fail, (
        f"autonomous training did not reach train_ok (ok={ok} fail={fail}); "
        f"m_role={int(dut.m_role_locked.value)} s_role={int(dut.s_role_locked.value)}")
    assert int(dut.m_role_locked.value) == 1, "master role_locked not set"
    assert int(dut.s_role_locked.value) == 1, "slave  role_locked not set"

    # ---- FC data-mode handoff: bilateral CR/CRACK + FCSM=4 -----------------
    snap = await _wait_data_mode(tb)
    m_fcsm, s_fcsm = tb.fcsm_state("m"), tb.fcsm_state("s")
    log.info(f"post-handoff FCSM: M state={m_fcsm} cr={tb.fcsm_cr_seen('m')} "
             f"crack={tb.fcsm_crack_seen('m')} | S state={s_fcsm} "
             f"cr={tb.fcsm_cr_seen('s')} crack={tb.fcsm_crack_seen('s')}")

    assert tb.fcsm_cr_seen("m") == 1 and tb.fcsm_cr_seen("s") == 1, (
        "AUTONOMOUS: cr_pkt_seen did NOT latch bilaterally "
        f"(M={tb.fcsm_cr_seen('m')} S={tb.fcsm_cr_seen('s')}) — FC handoff "
        f"failed, link still wedged in training/SEND_CR")
    assert tb.fcsm_crack_seen("m") == 1 and tb.fcsm_crack_seen("s") == 1, (
        "AUTONOMOUS: crack_pkt_seen did NOT latch bilaterally "
        f"(M={tb.fcsm_crack_seen('m')} S={tb.fcsm_crack_seen('s')})")
    assert m_fcsm == 4 and s_fcsm == 4, (
        f"AUTONOMOUS: FCSM not bilateral LINK_IDLE/data (M={m_fcsm} S={s_fcsm})")
    _ = snap

    # ---- Byte-exact data crossing over the V2 deskew RX (M->S) -------------
    # Settle, then send one real 4-word AHB packet and byte-compare the
    # header + both payload words in the slave's RX FIFO. ZERO FCCTRL/SYNC
    # pokes were issued — only the autoneg + on-chip handoff brought the link
    # to data mode.
    await ClockCycles(dut.hclk, 500)
    ok_data, got = await send_and_check(
        tb, "m", "s", [0xDA7A0000, 0xCAFEBABE], ctx="autonomous-m2s")
    assert ok_data, (
        "AUTONOMOUS data crossing FAILED: M->S packet not byte-exact in the "
        f"slave RX FIFO with ZERO FCCTRL/SYNC host pokes. got="
        f"[{', '.join(f'0x{x:08x}' for x in got)}]")

    log.info("Phase 7b (V2) VERDICT: PASS — autonomous bring-up reached "
             "bilateral FCSM=4 (cr=crack=1) and a byte-exact packet crossed "
             "M->S over the V2 deskew path with ZERO host pokes.")
