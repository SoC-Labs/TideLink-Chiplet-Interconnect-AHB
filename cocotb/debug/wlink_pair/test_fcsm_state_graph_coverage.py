"""FCSM state-graph traversal coverage.

Catches regressions where the FCSM stops traversing the full state
graph during link bring-up:
    IDLE -> SEND_CREDITS1 -> SEND_CREDITS2 -> LINK_EN_WAIT
         -> LINK_IDLE -> LINK_DATA

Walks one full link-bringup cycle per side, recording every state
transition (the cycle ⟨old_state, new_state, sim_time⟩). At the end
the test asserts that:

  1. The state set visited is a SUPERSET of {0,1,2,3,4,5}
     (i.e. IDLE..LINK_DATA all observed).
  2. The transition list contains the expected EDGES:
     0->1, 1->2, 2->3, 3->4, 4->5.
  3. No invalid state is observed (only 0..5,7 are legal per FC.scala).
  4. Both sides traverse the full set (so a one-side-only stuck FCSM
     is also caught).

NB: For the wlink_pair testbench without further calibrator-force
intervention, the FCSM normally traverses all states cleanly. With the
tdif-06 fix stack PLUS the actual HW recal cycle, some side gets stuck
at SEND_CREDITS1 — which this test will detect.

This file uses the BASELINE setup (no recal_cycle / no training pulse)
so we can confirm the "all-states-visited" contract on the proven-good
path FIRST. A second test then runs the HW bringup sequence and asserts
the full graph is STILL traversed (catching the tdif-06 regression).
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll, STATE_NAME,
)


def _fcsm(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


LEGAL_STATES = {0, 1, 2, 3, 4, 5, 7}
# Required states up to LINK_IDLE. LINK_DATA (5) is only reached when a
# packet is in flight; the wlink_pair TB drives no AHB/data traffic so
# we don't require state 5 in the visited set. LINK_DATA reachability
# is the contract of test_paired_recal_to_link_data; here we cover the
# bring-up graph.
REQUIRED_BRINGUP_STATES = {0, 1, 2, 3, 4}
REQUIRED_BRINGUP_EDGES = [(0, 1), (1, 2), (2, 3), (3, 4)]


async def _walk_and_record(dut, cycles):
    """Walk N master_clks, return per-side (states_visited, transitions)."""
    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    m_visited = set(); s_visited = set()
    m_trans = []; s_trans = []
    last_m = -1; last_s = -1
    for cyc in range(cycles):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.state.value); ss = int(s.state.value)
        m_visited.add(ms); s_visited.add(ss)
        if ms != last_m and last_m != -1:
            m_trans.append((last_m, ms, cyc))
        if ss != last_s and last_s != -1:
            s_trans.append((last_s, ss, cyc))
        last_m = ms; last_s = ss
    return m_visited, m_trans, s_visited, s_trans


def _name_set(s):
    return "{" + ",".join(f"{i}={STATE_NAME.get(i,'?')}" for i in sorted(s)) + "}"


# -----------------------------------------------------------------------
# TEST 1: baseline bringup must traverse the FULL state graph on both sides.
# This is the contract test — the proven-good wlink_pair path.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_baseline_full_state_graph_traversal(dut):
    """Baseline (no recal cycle, no training pulse): both sides MUST
    traverse {IDLE, SEND_CREDITS1, SEND_CREDITS2, LINK_EN_WAIT,
    LINK_IDLE, LINK_DATA} during the bring-up window."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    m_vis, m_tr, s_vis, s_tr = await _walk_and_record(dut, 5000)

    dut._log.info(f"  master visited states: {_name_set(m_vis)}")
    dut._log.info(f"  slave  visited states: {_name_set(s_vis)}")
    dut._log.info(f"  master transitions ({len(m_tr)}): {m_tr[:30]}")
    dut._log.info(f"  slave  transitions ({len(s_tr)}): {s_tr[:30]}")

    # No illegal state.
    illegal_m = m_vis - LEGAL_STATES
    illegal_s = s_vis - LEGAL_STATES
    assert not illegal_m, f"master visited illegal states {illegal_m}"
    assert not illegal_s, f"slave  visited illegal states {illegal_s}"

    # Required bring-up state set is a subset of what was visited.
    missing_m = REQUIRED_BRINGUP_STATES - m_vis
    missing_s = REQUIRED_BRINGUP_STATES - s_vis
    assert not missing_m, (
        f"master FCSM did not traverse all required bring-up states: "
        f"missing {missing_m} ({_name_set(missing_m)})")
    assert not missing_s, (
        f"slave  FCSM did not traverse all required bring-up states: "
        f"missing {missing_s} ({_name_set(missing_s)})")

    # Required edges observed.
    m_edges = {(a, b) for (a, b, _) in m_tr}
    s_edges = {(a, b) for (a, b, _) in s_tr}
    miss_m_e = [e for e in REQUIRED_BRINGUP_EDGES if e not in m_edges]
    miss_s_e = [e for e in REQUIRED_BRINGUP_EDGES if e not in s_edges]
    assert not miss_m_e, (
        f"master missing bring-up edges: {miss_m_e}; observed={sorted(m_edges)}")
    assert not miss_s_e, (
        f"slave  missing bring-up edges: {miss_s_e}; observed={sorted(s_edges)}")
    dut._log.info("  PASS: both sides traverse {IDLE..LINK_DATA} with all bring-up edges")


# -----------------------------------------------------------------------
# TEST 2: HW recal sequence must ALSO produce the full state graph.
# This is the tdif-06 regression catcher: with the L1/L2/L3 fix stack
# the recal cycle leaves the slave's FCSM stuck at SEND_CREDITS1 (state 1),
# so its visited-state set does NOT include LINK_DATA -> this test FAILS.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_hw_recal_sequence_full_state_graph_traversal(dut):
    """HW bring-up sequence (recal_cycle -> drop training -> LL swreset):
    both sides must STILL traverse the full bring-up state graph. The
    tdif-06 regression manifests here as missing LINK_DATA on the slave."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Replay the HW bring-up sequence.
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)

    # Now observe the full post-swreset window for state evolution.
    m_vis, m_tr, s_vis, s_tr = await _walk_and_record(dut, 5000)

    dut._log.info(f"  master visited (post-recal): {_name_set(m_vis)}")
    dut._log.info(f"  slave  visited (post-recal): {_name_set(s_vis)}")
    dut._log.info(f"  master transitions ({len(m_tr)}): {m_tr[:30]}")
    dut._log.info(f"  slave  transitions ({len(s_tr)}): {s_tr[:30]}")

    illegal_m = m_vis - LEGAL_STATES
    illegal_s = s_vis - LEGAL_STATES
    assert not illegal_m, f"master visited illegal states {illegal_m}"
    assert not illegal_s, f"slave  visited illegal states {illegal_s}"

    missing_m = REQUIRED_BRINGUP_STATES - m_vis
    missing_s = REQUIRED_BRINGUP_STATES - s_vis

    if missing_m or missing_s:
        dut._log.error(
            f"  STATE-GRAPH REGRESSION (HW bringup): "
            f"master missing={missing_m} ({_name_set(missing_m)}); "
            f"slave  missing={missing_s} ({_name_set(missing_s)})")

    assert not missing_m, (
        f"master FCSM did not traverse all bring-up states under HW recal "
        f"sequence: missing {missing_m} ({_name_set(missing_m)}) — "
        f"visited={_name_set(m_vis)}")
    assert not missing_s, (
        f"slave  FCSM did not traverse all bring-up states under HW recal "
        f"sequence: missing {missing_s} ({_name_set(missing_s)}) — "
        f"visited={_name_set(s_vis)}. This is the tdif-06 HW signature.")


# -----------------------------------------------------------------------
# TEST 3: diagnostic — log the full transition list (no assertions).
# Used for triage when the asserting tests fail.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_diagnostic_full_transition_log(dut):
    """Diagnostic. Replays the HW bringup sequence and logs EVERY state
    transition on both sides for the first 5000 cycles. Helpful when
    test_02 fails to identify exactly where the FCSM stalls."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
    await drop_training_and_swreset_ll(dut)
    m_vis, m_tr, s_vis, s_tr = await _walk_and_record(dut, 5000)
    dut._log.info(f"  master transitions ({len(m_tr)}):")
    for (a, b, t) in m_tr:
        dut._log.info(
            f"    +{t:5d}  {a}->{b}  ({STATE_NAME.get(a,'?')}"
            f"->{STATE_NAME.get(b,'?')})")
    dut._log.info(f"  slave  transitions ({len(s_tr)}):")
    for (a, b, t) in s_tr:
        dut._log.info(
            f"    +{t:5d}  {a}->{b}  ({STATE_NAME.get(a,'?')}"
            f"->{STATE_NAME.get(b,'?')})")
