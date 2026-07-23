"""F14-B follow-up (lane Z-D) — MINIMAL-RECOVERY LADDER per wedge cause.

Y-C established that any transient data-mode disturbance wedges the link and
that its 3-rung ladder could only clear it with a full POR of BOTH dies. But
that last rung also re-runs autocal, so it conflated two very different
answers:

    "the power/reset domain had to be cycled"   -> bench trip, NOT field-recoverable
    "the PHY merely had to retrain"             -> APB writes, FIELD-RECOVERABLE

This module re-runs each wedge cause against the fine ladder in
`recovery_common.py`, which inserts the rungs between "SW re-bringup" and
"POR": a bare calibrator re-arm, three strengths of transient SYNC beacon, a
both-die LL swreset, and a full PHY retrain with no POR at all.

Each test also captures a HEALTHY and a WEDGED liveness snapshot and diffs
them, so the run itself produces the evidence for which observable actually
detects the wedge (Y-C: fcsm reads a healthy 4 on both dies while no data
crosses, so fcsm is disqualified).

Wedge causes, one per test, matching Y-C's S1a / S1b / S3c:
  W1  framing slip from all-lane corruption   (FLIP mask 0xFF, s->m)
  W2  link-clock dropout                      (clk_kill, s->m)
  W3  single-lane X                           (lane 2 stuck-X, s->m)

A test FAILS only if the ladder cannot recover the link at all. Which rung was
needed is a FINDING, logged as VERDICT[...] / LADDER[...].
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
from errinj_common import (
    inject_data, clear_all, kill_clock, link_healthy,
    burst_during_fault, M_FLIP, M_STUCKX, M_STUCK1,
)
from recovery_common import (
    recovery_ladder, liveness_snapshot, fmt_liveness, diff_liveness,
    is_link_alive,
)


async def _bringup_and_prove_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: link never reached CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: link not healthy pre-injection ({detail})"
    tb.log.info(f"  [pre-inject] link HEALTHY ({detail})")
    return tb


async def _run_cause(dut, tag, payloads, fault_setup, fault_clear, src="s", dst="m"):
    """Prove healthy -> snapshot healthy -> inject mid-burst -> snapshot wedged
    -> diff the observables -> walk the fine ladder."""
    tb = await _bringup_and_prove_healthy(dut)

    healthy_snap = await liveness_snapshot(tb)
    tb.log.info(f"  [{tag}] HEALTHY obs: {fmt_liveness(healthy_snap)}")

    during = await burst_during_fault(tb, src, dst, payloads,
                                      fault_setup=fault_setup,
                                      fault_clear=fault_clear, ctx=tag)
    clear_all(dut)
    await ClockCycles(dut.hclk, 2000)

    wedged_snap = await liveness_snapshot(tb)
    tb.log.info(f"  [{tag}] POST-FAULT obs: {fmt_liveness(wedged_snap)}")

    delta = diff_liveness(healthy_snap, wedged_snap)
    tb.log.info(f"DETECT[{tag}]: observables that CHANGED healthy->post-fault: "
                f"{delta if delta else 'NONE — no observable discriminated!'}")

    alive, why = await is_link_alive(tb, src, dst)
    tb.log.info(f"DETECT[{tag}]: is_link_alive() -> {alive} ({why})")

    rung, fw_reachable, trace = await recovery_ladder(tb, src, dst)
    tb.log.info(f"VERDICT[{tag}]: during-burst byte-exact={during} | "
                f"MINIMAL RECOVERY = {rung} | "
                f"firmware-reachable-in-field={fw_reachable}")
    for label, ok, detail in trace:
        tb.log.info(f"LADDER[{tag}] {label}: healthy={ok} ({detail})")

    assert not rung.startswith("NONE"), (
        f"{tag}: HARD WEDGE — the link did not recover at ANY rung, including a "
        f"full POR of both dies. No software or operator action restores it.")
    return tb, rung, fw_reachable


@cocotb.test()
async def test_10_w1_framing_slip_all_lane_corruption(dut):
    """W1 — all-lane FLIP during an s->m burst (Y-C S1a)."""
    await _run_cause(
        dut, "W1_all_lane_flip",
        [[0xBEEF0001, 0xF00D0002], [0xBEEF0003, 0xF00D0004],
         [0xBEEF0005, 0xF00D0006]],
        fault_setup=lambda: inject_data(dut, "s2m", M_FLIP, 0xFF),
        fault_clear=lambda: clear_all(dut))


@cocotb.test()
async def test_11_w2_link_clock_dropout(dut):
    """W2 — recovered-link-clock dropout during an s->m burst (Y-C S1b)."""
    await _run_cause(
        dut, "W2_clk_dropout",
        [[0xC10C0001, 0xC10C0002], [0xC10C0003, 0xC10C0004]],
        fault_setup=lambda: kill_clock(dut, "s2m", on=True),
        fault_clear=lambda: kill_clock(dut, "s2m", on=False))


@cocotb.test()
async def test_12_w3_single_lane_x(dut):
    """W3 — lane 2 stuck-X during an s->m burst (Y-C S3c).

    CAVEAT, read before quoting this test: stuck-X is a SIMULATION fault model.
    Silicon has no X — a real broken lane is stuck at a level, or marginal.
    Because X propagates through the APB readback path, every observable in
    this test reads X (-1) rather than a value, so the wedge-DETECTION result
    here is about VCS X-pessimism, not about what firmware would see on a
    board. test_13 is the silicon-meaningful single-lane case; prefer it."""
    await _run_cause(
        dut, "W3_lane2_stuckX",
        [[0x0BAD0001, 0x0BAD0002], [0x0BAD0003, 0x0BAD0004]],
        fault_setup=lambda: inject_data(dut, "s2m", M_STUCKX, 1 << 2),
        fault_clear=lambda: clear_all(dut))


@cocotb.test()
async def test_13_w4_single_lane_stuck1(dut):
    """W4 — lane 2 stuck-1 during an s->m burst: the SILICON-MEANINGFUL
    single-lane fault (a shorted/pulled-up wire or a dead driver), and the one
    whose observables stay readable so the wedge-detection recipe can actually
    be evaluated on it."""
    await _run_cause(
        dut, "W4_lane2_stuck1",
        [[0x51C10001, 0x51C10002], [0x51C10003, 0x51C10004]],
        fault_setup=lambda: inject_data(dut, "s2m", M_STUCK1, 1 << 2),
        fault_clear=lambda: clear_all(dut))
