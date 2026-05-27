"""Phase 0 — empirical eye-shape capture for the PHY calibrator.

Captures the per-lane lock_score at every (sweep_slip, sweep_phase) point
across the full 128-point calibrator sweep, for both master and slave
calibrators, on the cocotb tidelink_top_pair PHY.

The eye-centre policy proposed in
docs/agent_o_structural_fix_proposal.md selects the centre of the widest
contiguous run of passing dwells per lane. The MIN_LOCK_DWELLS default
matters: too small picks an edge; too large rejects valid eyes. Phase 0
records the empirical eye shape on the cocotb sim so the default can be
chosen from data, not guessed.

Output: docs/eyemap_dump_<branch>_<date>.csv with columns
  side,slip,phase,lane0_score,lane1_score,...,lane7_score,passed_mask
where passed_mask is an 8-bit value with bit i set iff lane i's score
reached LOCK_THRESH at that (slip, phase) point.

Run: TIDELINK_HOME=$(pwd) make -C cocotb/tidelink_top_pair MODULE=test_eyemap_dump
"""
import os
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import PairTB, run_bringup_full


_HERE = Path(__file__).resolve().parent
TIDELINK_HOME = Path(os.environ.get("TIDELINK_HOME", _HERE.parent.parent))
DOCS_DIR = TIDELINK_HOME / "docs"
DUMP_PATH = DOCS_DIR / "eyemap_dump.csv"
SUMMARY_PATH = DOCS_DIR / "eyemap_dump_summary.md"


def _cc(dut, side):
    return (dut.u_master if side == "m" else dut.u_slave).u_chiplet_controller


def _cal(dut, side):
    return _cc(dut, side).u_calibrator


def _safe_int(handle):
    try:
        return int(handle.value)
    except (AttributeError, ValueError, TypeError):
        return None


def _lane_scores(dut, side):
    """Read all 8 lane_score[i] values from the calibrator at the current
    sim time. Returns list of 8 ints (or None for unreachable lanes).
    """
    cal = _cal(dut, side)
    out = []
    for i in range(8):
        try:
            out.append(int(cal.lane_score[i].value))
        except (AttributeError, ValueError, IndexError):
            out.append(None)
    return out


async def _await_state(dut, side, target_state, timeout_cy=2_000_000):
    """Wait until the calibrator on `side` reaches state == target_state."""
    clk = dut.u_master.u_chiplet_controller.u_calibrator.clk
    for _ in range(timeout_cy):
        await RisingEdge(clk)
        cur = _safe_int(_cal(dut, side).cur_state)
        if cur == target_state:
            return True
    return False


@cocotb.test()
async def test_eyemap_dump(dut):
    """Walk the full sweep and capture per-(slip,phase) lane_score on M+S."""

    tb = PairTB(dut)
    # PairTB.__init__ starts the clocks via cocotb.start_soon, so no
    # separate start_clocks() call is needed.
    await tb.reset()
    await tb.do_role_lock()

    # State encoding (mirrors tidelink_phy_align_calibrator.sv):
    #   S_IDLE=0, S_ARM=1, S_SWEEP=2, S_FINISH=3, S_DONE=4,
    #   S_CANCEL=5, S_HOLD=6, S_PROBE=7
    S_SWEEP = 2

    # We sample lane_score at the last cycle of every dwell (dwell_ctr ==
    # DWELL_MAX). This is the score JUST before the per-dwell reset fires.
    # DWELL_CYCLES default is 64 → dwell_ctr maxes at 63.
    samples_m = []
    samples_s = []
    seen_m = set()
    seen_s = set()
    clk = dut.u_master.u_chiplet_controller.u_calibrator.clk

    dut._log.info("eyemap: waiting for first M or S to enter S_SWEEP")
    # Settle the bringup
    await ClockCycles(clk, 2)

    # 128 points × DWELL_CYCLES (64) × 2 = 16k cycles per side worst case
    timeout_cy = 200_000
    for _ in range(timeout_cy):
        await RisingEdge(clk)

        # Sample whenever a side is in S_SWEEP at the last dwell cycle.
        for side, samples, seen in (
            ("m", samples_m, seen_m),
            ("s", samples_s, seen_s),
        ):
            cal = _cal(dut, side)
            cur = _safe_int(cal.cur_state)
            if cur != S_SWEEP:
                continue
            try:
                dwell_ctr = int(cal.dwell_ctr.value)
            except (AttributeError, ValueError):
                continue
            # We want the LAST cycle of the dwell. DWELL_MAX = DWELL_CYCLES - 1.
            # For the default DWELL_CYCLES=64 this is 63.
            try:
                dwell_cycles = int(cal.DWELL_CYCLES.value)
            except (AttributeError, ValueError):
                dwell_cycles = 64
            if dwell_ctr != (dwell_cycles - 1):
                continue
            slip = _safe_int(cal.sweep_slip)
            phase = _safe_int(cal.sweep_phase)
            if slip is None or phase is None:
                continue
            key = (slip, phase)
            if key in seen:
                continue
            seen.add(key)
            scores = _lane_scores(dut, side)
            samples.append((slip, phase, scores))

        # Stop once BOTH sides have left S_SWEEP (entered S_FINISH/HOLD/DONE).
        m_cur = _safe_int(_cal(dut, "m").cur_state)
        s_cur = _safe_int(_cal(dut, "s").cur_state)
        if m_cur != S_SWEEP and s_cur != S_SWEEP and len(samples_m) >= 8 and len(samples_s) >= 8:
            # Both sides have entered post-sweep states (PROBE→SWEEP→FINISH
            # is the path; we wait until BOTH have moved past S_SWEEP and
            # we have at least some samples).
            break

    dut._log.info(
        f"eyemap: captured M={len(samples_m)} S={len(samples_s)} dwell points "
        f"(expected up to 128 each)"
    )

    # Read LOCK_THRESH for the passed-mask computation
    try:
        lock_thresh = int(_cal(dut, "m").LOCK_THRESH.value)
    except (AttributeError, ValueError):
        lock_thresh = 16

    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    with open(DUMP_PATH, "w") as f:
        f.write("side,slip,phase," + ",".join(f"lane{i}_score" for i in range(8)) + ",passed_mask\n")
        for side, samples in (("m", samples_m), ("s", samples_s)):
            for slip, phase, scores in sorted(samples):
                passed_mask = 0
                for i, sc in enumerate(scores):
                    if sc is not None and sc >= lock_thresh:
                        passed_mask |= (1 << i)
                row = [side, str(slip), str(phase)]
                row += [str(s) if s is not None else "" for s in scores]
                row.append(f"0x{passed_mask:02x}")
                f.write(",".join(row) + "\n")

    dut._log.info(f"eyemap: wrote {DUMP_PATH}")

    # Per-lane summary: longest contiguous passing-run along phase-inner
    # (i.e. for each (lane, slip), scan phase 0..15 and find the widest run
    # of phase points where the lane passed LOCK_THRESH).
    def _eye_summary(samples, side):
        # samples : [(slip, phase, [scores...])]
        # Index by (slip, lane) -> list-of-16-bools indexed by phase
        eye = {(slip, lane): [False] * 16 for slip in range(8) for lane in range(8)}
        for slip, phase, scores in samples:
            for lane, sc in enumerate(scores):
                if sc is not None and sc >= lock_thresh:
                    eye[(slip, lane)][phase] = True
        # Compute widest contiguous run per (slip, lane)
        lines = [f"### Side {side.upper()} eye summary (LOCK_THRESH={lock_thresh})\n",
                 "| slip | lane | widest_run | run_start_phase | passing_phases |",
                 "|------|------|------------|-----------------|----------------|"]
        for slip in range(8):
            for lane in range(8):
                bools = eye[(slip, lane)]
                best_len, best_start = 0, -1
                cur_len, cur_start = 0, -1
                for p, ok in enumerate(bools):
                    if ok:
                        if cur_len == 0:
                            cur_start = p
                        cur_len += 1
                        if cur_len > best_len:
                            best_len = cur_len
                            best_start = cur_start
                    else:
                        cur_len = 0
                passing_str = "".join("X" if b else "." for b in bools)
                lines.append(f"| {slip} | {lane} | {best_len} | {best_start} | `{passing_str}` |")
        return "\n".join(lines) + "\n"

    with open(SUMMARY_PATH, "w") as f:
        f.write("# Phase 0 eyemap dump summary\n\n")
        f.write(f"- Samples M: {len(samples_m)} / 128\n")
        f.write(f"- Samples S: {len(samples_s)} / 128\n")
        f.write(f"- LOCK_THRESH (training-pattern lock criterion): {lock_thresh}\n\n")
        f.write("Phase-inner eye scan (X = passed LOCK_THRESH, . = did not):\n\n")
        f.write(_eye_summary(samples_m, "m"))
        f.write("\n")
        f.write(_eye_summary(samples_s, "s"))

    dut._log.info(f"eyemap: wrote {SUMMARY_PATH}")

    assert len(samples_m) > 0, "no M eyemap samples captured — bringup/sweep timing issue"
    assert len(samples_s) > 0, "no S eyemap samples captured — bringup/sweep timing issue"
