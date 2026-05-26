"""POR-stagger threshold sweep — identify the cycle-count boundary at which
the paired bring-up transitions from success to bilateral failure.

Strategic value
---------------
The existing test_asymmetric_failure_fuzz uses a small set of fixed stagger
values (0, 500, 1000 cycles). The Phase-0 §11 root-cause analysis
(2026-05-24) showed that bringup_pair_converge.sh ACTIVELY BREAKS a
POR-aligned link via the slot0=0x3 recal at a mid-word mux flip. We don't
yet have a sim-quantified picture of WHERE the stagger threshold lives —
i.e. at what POR offset does the bilateral failure mode first appear, and
does it have a periodicity (T3A 1-of-8 boundary, recal hold duration, etc).

This test sweeps stagger across a logarithmic-ish range and records the
outcome of each scenario, then asserts BOTH:
  (a) zero scenarios show asymmetric cr_pkt_seen_rx, AND
  (b) the success/fail pattern is monotonic (no oscillation in the middle
      of the range) — if it is non-monotonic we have a NEW bug class to
      investigate (e.g. there's a magic stagger value that triggers a
      latched edge corruption).

PASS criterion
--------------
All 8 stagger values reach LINK_IDLE-or-better on BOTH sides, with
symmetric cr_pkt_seen_rx (both 1).

A non-monotonic pattern (PASS-FAIL-PASS-FAIL across stagger values) is
flagged as a NEW BUG CLASS in the log — the test still asserts on the
overall failure count.

Invocation
----------
  rm -rf sim_build ../phy_align/sim_build
  make MODULE=test_stagger_range_sweep
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll, _observe_state_window,
    _log_obs, FCSM_LINK_DATA, STATE_NAME,
)


# Logarithmic-ish sweep, biased to small values because that's where the
# POR-mid-word-mux-flip race window actually lives.
STAGGER_SWEEP = [0, 25, 50, 100, 200, 500, 1000, 2000]


async def _scenario(dut, stagger_por):
    """Run one HW-style paired bring-up at a given POR stagger."""
    await setup(dut, stagger_por_cycles=stagger_por)
    await lock_master(dut)
    await lock_slave(dut)
    # Same recal sequence the HW bringup uses (slot0=0x3 -> wait -> 0x1 -> wait).
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    return await _observe_state_window(dut, 3000, f"stagger={stagger_por}")


@cocotb.test()
async def test_01_stagger_threshold_sweep(dut):
    """Sweep POR stagger across 8 values, record per-scenario outcome, then
    look for the failure threshold AND any non-monotonic pattern."""
    results = []
    for stagger in STAGGER_SWEEP:
        obs = await _scenario(dut, stagger)
        ok = (obs["cr_m"] and obs["cr_s"]
              and obs["max_m"] >= FCSM_LINK_DATA - 1   # >=4 = LINK_IDLE
              and obs["max_s"] >= FCSM_LINK_DATA - 1)
        asym = obs["cr_m"] != obs["cr_s"]
        results.append((stagger, ok, asym, obs))
        dut._log.info(
            f"  stagger={stagger:5d}  ok={ok}  asym={asym}  "
            f"m.cr={int(obs['cr_m'])} s.cr={int(obs['cr_s'])}  "
            f"m.max={obs['max_m']}({STATE_NAME.get(obs['max_m'],'?')}) "
            f"s.max={obs['max_s']}({STATE_NAME.get(obs['max_s'],'?')})")

    # ---------- diagnostic: find threshold + non-monotonic regions -----------
    failing = [s for (s, ok, *_rest) in results if not ok]
    asym_count = sum(1 for (_s, _ok, asym, _o) in results if asym)
    dut._log.info("=" * 70)
    dut._log.info(
        f"  SWEEP TALLY: total={len(results)} failing={len(failing)} "
        f"asymmetric={asym_count}")
    dut._log.info(
        f"  failing stagger values: {failing}")

    # Detect non-monotonic pattern. If success goes T,T,F,T,F we have something
    # strange. We just look for any  ..F..T.. block (failure followed by
    # success in a higher stagger).
    success_pattern = [ok for (_s, ok, *_r) in results]
    non_monotonic = False
    seen_fail = False
    for ok in success_pattern:
        if not ok:
            seen_fail = True
        elif seen_fail:
            non_monotonic = True
            break
    if non_monotonic:
        dut._log.error("*" * 70)
        dut._log.error(
            f"  NON-MONOTONIC sweep pattern (success={success_pattern}): "
            f"a failure value sits between two successes. That implies a "
            f"magic stagger triggers a latched edge corruption — NEW BUG "
            f"CLASS, investigate.")
        dut._log.error("*" * 70)
    dut._log.info("=" * 70)

    # ---------- hard assertions ---------------------------------------------
    assert asym_count == 0, (
        f"{asym_count}/{len(results)} stagger values show asymmetric "
        f"cr_pkt_seen_rx — tdif-06/L4 fix stack is NOT complete across the "
        f"stagger range: {[(s, int(o['cr_m']), int(o['cr_s'])) for (s,_,asym,o) in results if asym]}")
    assert not failing, (
        f"{len(failing)}/{len(results)} stagger scenarios failed to reach "
        f"LINK_IDLE on both sides. Failing stagger values: {failing}")

    # If non-monotonic, also assert — this would be a new bug class.
    assert not non_monotonic, (
        f"non-monotonic stagger pattern detected (pattern={success_pattern}); "
        f"investigate a magic-stagger race")


@cocotb.test()
async def test_02_zero_stagger_baseline_reaches_link_idle(dut):
    """Sanity baseline of the sweep: stagger=0 must produce both sides at
    LINK_IDLE-or-better with symmetric cr_pkt_seen_rx. If THIS fails the
    whole sweep test is invalid (the dut is broken even at the optimistic
    case)."""
    obs = await _scenario(dut, 0)
    _log_obs(dut, obs, "zero-stagger baseline")
    assert obs["cr_m"] and obs["cr_s"], (
        f"baseline (stagger=0) failed symmetric cr_pkt_seen_rx: "
        f"m.cr={int(obs['cr_m'])} s.cr={int(obs['cr_s'])}")
    assert obs["max_m"] >= 4 and obs["max_s"] >= 4, (
        f"baseline (stagger=0) did not reach LINK_IDLE: "
        f"m.max={obs['max_m']} s.max={obs['max_s']}")
