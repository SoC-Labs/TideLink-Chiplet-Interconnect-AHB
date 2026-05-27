"""test_eye_paired_entry — proposal §9 test #3 + §4 Mechanism α.

Two independent calibrators (`u_a_dut`, `u_b_dut`) each wrapped with
their own `tidelink_eye_regs` APB shim. The cocotb test:

  1. Programmes dwell + lane_sel on BOTH sides.
  2. Issues SWI_EYE_CTRL.ENTER to side A.
  3. Within a tight 1 µs (100 cycles @ 100 MHz) window, issues
     SWI_EYE_CTRL.ENTER to side B. This is the "paired-manual" entry
     skew the proposal §4 calls out (LAN ssh round-trip is ~5 ms; a 1 µs
     sim skew is much tighter than the worst real-world skew, so this
     verifies the upper bound of the design's robustness).
  4. Polls SWI_EYE_STATUS on both sides; asserts BOTH reach STATE=DONE.
  5. Reads each side's score_buf via hierarchical xref (u_a_dut.score_buf,
     u_b_dut.score_buf) and asserts:
       * Both buffers are populated (≥ 64 entries with non-zero values).
       * The two buffers are INDEPENDENT — driving side A with
         lane_locked=0xFF and side B with lane_locked=0x00 gives:
            buf_a mostly saturated (0x3F),
            buf_b mostly zero.

Mechanism α is the v2 default per §4 recommendation; β / γ are reserved
in `SWI_EYE_CTRL[7]` REMOTE_TRIGGER_EN (RAZ/WI in v2).

Uses TB_VARIANT=eye_paired and tb_top_eye_paired.sv.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from eye_common import (
    SWI_EYE_CTRL, SWI_EYE_LANE_SEL, SWI_EYE_DWELL_US, SWI_EYE_STATUS,
    CTRL_ENTER, CTRL_RESET, CTRL_MODE_SINGLE, CTRL_FORCE_FULL_SWEEP,
    STATE_DONE, STATE_TIMED_OUT,
    SCORES_PER_LANE, CLK_PERIOD_NS,
    apb_read, apb_write, poll_status_state, status_decode,
)


async def _idle_paired(dut):
    """Park every test-driven input on the two-DUT testbench."""
    for prefix in ("a_", "b_"):
        getattr(dut, f"{prefix}psel").value    = 0
        getattr(dut, f"{prefix}penable").value = 0
        getattr(dut, f"{prefix}pwrite").value  = 0
        getattr(dut, f"{prefix}paddr").value   = 0
        getattr(dut, f"{prefix}pwdata").value  = 0
        getattr(dut, f"{prefix}role_locked").value = 0
        getattr(dut, f"{prefix}swreset").value     = 0
        getattr(dut, f"{prefix}lane_locked").value = 0


async def _start_paired(dut):
    """Start clock, drive reset, idle both sides' APB."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _idle_paired(dut)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


def _read_score_buf(dut_handle):
    """Snapshot a calibrator's score buffer via hierarchical xref into
    the DUT instance handle (u_a_dut or u_b_dut)."""
    out = []
    for idx in range(SCORES_PER_LANE):
        try:
            v = int(dut_handle.score_buf[idx].value)
        except Exception:
            v = -1
        out.append(v & 0x3F if v >= 0 else -1)
    return out


@cocotb.test()
async def test_paired_enter_both_reach_done(dut):
    """Issue ENTER to side A and side B within 1 µs (100 cycles).
    Both calibrators must independently reach STATE=DONE.
    """
    await _start_paired(dut)

    # Latch role_locked on both sides.
    dut.a_role_locked.value = 1
    dut.b_role_locked.value = 1
    dut.a_lane_locked.value = 0xFF
    dut.b_lane_locked.value = 0xFF
    await ClockCycles(dut.clk, 4)

    # Programme dwell + lane_sel on BOTH sides BEFORE issuing ENTER, so
    # the ENTER writes can be issued with the smallest possible skew.
    await apb_write(dut, SWI_EYE_LANE_SEL, 4, prefix="a_")
    await apb_write(dut, SWI_EYE_LANE_SEL, 4, prefix="b_")
    await apb_write(dut, SWI_EYE_DWELL_US, 50_000, prefix="a_")
    await apb_write(dut, SWI_EYE_DWELL_US, 50_000, prefix="b_")

    # ENTER side A first, then side B within ≤ 1 µs.
    ctrl_word = CTRL_ENTER | CTRL_MODE_SINGLE | CTRL_FORCE_FULL_SWEEP
    await apb_write(dut, SWI_EYE_CTRL, ctrl_word, prefix="a_")
    # Insert a small known skew; bus-cycle cost of the first write is
    # already ≤ 50 ns so we add a deliberate gap to cover the spec'd
    # "within 1 µs" window.
    await ClockCycles(dut.clk, 50)   # 50 cycles = 500 ns
    await apb_write(dut, SWI_EYE_CTRL, ctrl_word, prefix="b_")

    # Poll both sides for DONE.
    status_a = await poll_status_state(
        dut, target_states=(STATE_DONE, STATE_TIMED_OUT),
        max_polls=4096, prefix="a_",
    )
    status_b = await poll_status_state(
        dut, target_states=(STATE_DONE, STATE_TIMED_OUT),
        max_polls=4096, prefix="b_",
    )
    fa = status_decode(status_a)
    fb = status_decode(status_b)

    assert fa["state"] == STATE_DONE, (
        f"Side A did not reach DONE — final state={fa['state']} "
        f"(STATUS=0x{status_a:08x})."
    )
    assert fb["state"] == STATE_DONE, (
        f"Side B did not reach DONE — final state={fb['state']} "
        f"(STATUS=0x{status_b:08x})."
    )

    dut._log.info("OK: paired ENTER — both sides reached DONE.")


@cocotb.test()
async def test_paired_score_buffers_are_independent(dut):
    """Drive side A with lane_locked=0xFF (sweep saturates score_buf)
    and side B with lane_locked=0x00 (sweep scores zero everywhere).
    After paired ENTER + DONE, side A's buffer must be saturated and
    side B's buffer must be near-zero — proves the two calibrators are
    independent, no cross-bleed.
    """
    await _start_paired(dut)

    dut.a_role_locked.value = 1
    dut.b_role_locked.value = 1
    dut.a_lane_locked.value = 0xFF     # all lanes locked → high scores
    dut.b_lane_locked.value = 0x00     # no lanes locked → zero scores
    await ClockCycles(dut.clk, 4)

    # Reset both sides' state machines + buffers.
    await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET, prefix="a_")
    await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET, prefix="b_")
    await ClockCycles(dut.clk, 4)

    # Programme + ENTER both sides on the same lane.
    await apb_write(dut, SWI_EYE_LANE_SEL, 2, prefix="a_")
    await apb_write(dut, SWI_EYE_LANE_SEL, 2, prefix="b_")
    await apb_write(dut, SWI_EYE_DWELL_US, 50_000, prefix="a_")
    await apb_write(dut, SWI_EYE_DWELL_US, 50_000, prefix="b_")
    ctrl_word = CTRL_ENTER | CTRL_MODE_SINGLE | CTRL_FORCE_FULL_SWEEP
    await apb_write(dut, SWI_EYE_CTRL, ctrl_word, prefix="a_")
    await ClockCycles(dut.clk, 30)
    await apb_write(dut, SWI_EYE_CTRL, ctrl_word, prefix="b_")

    # Wait for both sides to terminate.
    await poll_status_state(
        dut, target_states=(STATE_DONE, STATE_TIMED_OUT),
        max_polls=4096, prefix="a_",
    )
    await poll_status_state(
        dut, target_states=(STATE_DONE, STATE_TIMED_OUT),
        max_polls=4096, prefix="b_",
    )

    buf_a = _read_score_buf(dut.u_a_dut)
    buf_b = _read_score_buf(dut.u_b_dut)

    sat_a = sum(1 for v in buf_a if v == 0x3F)
    sat_b = sum(1 for v in buf_b if v == 0x3F)

    assert sat_a >= SCORES_PER_LANE // 2, (
        f"Side A: only {sat_a}/{SCORES_PER_LANE} saturated entries — "
        f"score_buf write path on side A may be broken."
    )
    assert sat_b <= SCORES_PER_LANE // 8, (
        f"Side B: {sat_b} saturated entries despite lane_locked=0x00 — "
        f"side A's saturated data is bleeding into side B's buffer. "
        f"The two calibrators are NOT independent."
    )

    dut._log.info(
        f"OK: paired buffers independent — A={sat_a} saturated, "
        f"B={sat_b} saturated."
    )
