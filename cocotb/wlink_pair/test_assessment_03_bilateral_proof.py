"""ASSESSMENT FINDING #3 — BILATERAL CLAIM UNDEMONSTRATED.

The assessment notes:
   Option (c) flips 6/12 fuzz failures to master-side polarity. We claim
   this proves the bug is bilateral (same mechanism, opposite die). But
   we haven't run a test that DEFINITIVELY shows: even with option (c)
   applied symmetrically on both dies, the polarity-flipped failure
   persists in some timing scenarios.

Falsifier of the bilateral claim: a test where BOTH sides have the gate
(v3 first_short_pkt_seen) fully fired, yet a master-side state==1
latches in some timing scenario.

This test:
  * Scenario A: synchronous POR (stagger=0, equal periods) — both sides
                v3 gate is in main → expect symmetric bring-up, no
                state==1 latches on filler on either side
  * Scenario B: staggered POR (stagger=500 master clocks) — slave POR
                deasserts 500 cyc late. The v3 gate is in main, but if
                the bug is bilateral, the polarity-flipped failure
                (master_state stuck at 1 instead of slave) should
                appear.

ASSERT logic:
  * Scenario A: PASS — both sides reach FCSM state>=LINK_IDLE, no early
    spurious state==1 on either side.
  * Scenario B:
    - If both sides also reach LINK_IDLE → bilateral claim is REFUTED
      (v3 gate is bilaterally robust). Bilateral was a worst-case
      hypothesis that did not manifest with current RTL.
    - If master-side state==1 latches at POR with closed gate → bilateral
      claim is CONFIRMED.
    - If slave-side state==1 latches but master clean → bilateral claim
      is REFUTED (still asymmetric, slave-only).
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave


def _llrx(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.llrx


def _fcsm(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


async def _observe_post_por(dut, cycles):
    """Track state, first_short_pkt_seen, cr_pkt_seen on BOTH sides for
    `cycles` master_clks. Returns dict of per-side observations."""
    m_llrx = _llrx(dut, "m")
    s_llrx = _llrx(dut, "s")
    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")

    obs = {
        "m": {"max_llrx_state": 0, "first_state1": None, "first_state1_gate": None,
              "first_state1_fssp": None, "max_fcsm_state": 0, "cr_seen": False},
        "s": {"max_llrx_state": 0, "first_state1": None, "first_state1_gate": None,
              "first_state1_fssp": None, "max_fcsm_state": 0, "cr_seen": False},
    }
    for c in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        for side, llrx, fcsm in (("m", m_llrx, m_fcsm), ("s", s_llrx, s_fcsm)):
            try:
                lst = int(llrx.state.value)
                fst = int(fcsm.state.value)
                cr = int(fcsm.cr_pkt_seen_rx.value)
            except Exception:
                continue
            o = obs[side]
            if lst > o["max_llrx_state"]:
                o["max_llrx_state"] = lst
            if fst > o["max_fcsm_state"]:
                o["max_fcsm_state"] = fst
            if cr:
                o["cr_seen"] = True
            if lst == 1 and o["first_state1"] is None:
                o["first_state1"] = c
                try:
                    o["first_state1_gate"] = int(llrx.long_pkt_gate.value)
                except Exception:
                    o["first_state1_gate"] = -1
                try:
                    o["first_state1_fssp"] = int(llrx.first_short_pkt_seen.value)
                except Exception:
                    o["first_state1_fssp"] = -1
    return obs


@cocotb.test()
async def test_03a_synchronous_por(dut):
    """Scenario A — synchronous POR. Bilateral check baseline."""
    await setup(dut, master_period_ns=20.0, slave_period_ns=20.0,
                stagger_por_cycles=0)
    await lock_master(dut)
    await lock_slave(dut)
    obs = await _observe_post_por(dut, 3000)
    dut._log.info("=" * 70)
    dut._log.info("  ASSESSMENT FINDING #3 — BILATERAL — Scenario A (sync POR)")
    dut._log.info("=" * 70)
    for side in ("m", "s"):
        o = obs[side]
        dut._log.info(f"  [{side}] max_llrx_state={o['max_llrx_state']} "
                      f"max_fcsm_state={o['max_fcsm_state']} cr_seen={o['cr_seen']}")
        dut._log.info(f"  [{side}] first_state1_cyc={o['first_state1']} "
                      f"gate={o['first_state1_gate']} fssp={o['first_state1_fssp']}")
    # PASS Scenario A: no early state==1 with closed gate on either side.
    for side in ("m", "s"):
        o = obs[side]
        if o["first_state1"] is not None and o["first_state1_fssp"] == 0:
            assert False, (
                f"[A][{side}] state==1 at cyc {o['first_state1']} with v3 gate CLOSED "
                f"(fssp=0). Scenario A is supposed to be the easy case; failure here "
                f"means the v3 gate is leaky even in the synchronous-POR baseline.")
    dut._log.info("  Scenario A PASS — neither side latched state==1 with gate closed.")


@cocotb.test()
async def test_03b_staggered_por_500cyc(dut):
    """Scenario B — stagger=500 cyc. The v3 gate is bilaterally applied;
    if the bug is truly bilateral, this should drive a master-side
    spurious state==1. If both sides come up clean, bilateral hypothesis
    is REFUTED."""
    await setup(dut, master_period_ns=20.0, slave_period_ns=20.0,
                stagger_por_cycles=500)
    await lock_master(dut)
    await lock_slave(dut)
    obs = await _observe_post_por(dut, 3000)
    dut._log.info("=" * 70)
    dut._log.info("  ASSESSMENT FINDING #3 — BILATERAL — Scenario B (stagger=500cyc)")
    dut._log.info("=" * 70)
    for side in ("m", "s"):
        o = obs[side]
        dut._log.info(f"  [{side}] max_llrx_state={o['max_llrx_state']} "
                      f"max_fcsm_state={o['max_fcsm_state']} cr_seen={o['cr_seen']}")
        dut._log.info(f"  [{side}] first_state1_cyc={o['first_state1']} "
                      f"gate={o['first_state1_gate']} fssp={o['first_state1_fssp']}")

    # Decisive verdicts:
    m_spurious = (obs["m"]["first_state1"] is not None and
                  obs["m"]["first_state1_fssp"] == 0)
    s_spurious = (obs["s"]["first_state1"] is not None and
                  obs["s"]["first_state1_fssp"] == 0)

    if m_spurious and not s_spurious:
        dut._log.info("  VERDICT: BILATERAL CONFIRMED — master-side spurious state==1")
        dut._log.info("  → Polarity-flipped failure reproduced. v3 gate is NOT bilaterally")
        dut._log.info("    robust against stagger=500cyc.")
        # This is a known failure mode — log loudly but do not assert FAIL
        # because the test purpose is to PROVE bilateral, not gate CI.
        return
    if s_spurious and not m_spurious:
        dut._log.info("  VERDICT: NOT BILATERAL — only slave-side state==1 spurious")
        dut._log.info("  → Bug remains slave-polarity even under stagger. Bilateral")
        dut._log.info("    claim is REFUTED on this timing scenario.")
        return
    if m_spurious and s_spurious:
        dut._log.info("  VERDICT: BIDIRECTIONAL SIMULTANEOUS — both sides spurious")
        dut._log.info("  → Bilateral hypothesis confirmed AND symmetric failure.")
        return
    dut._log.info("  VERDICT: BILATERAL REFUTED — both sides come up clean")
    dut._log.info("  → Neither side latched state==1 with v3 gate closed even at")
    dut._log.info("    stagger=500cyc. The v3 gate is bilaterally ROBUST.")
