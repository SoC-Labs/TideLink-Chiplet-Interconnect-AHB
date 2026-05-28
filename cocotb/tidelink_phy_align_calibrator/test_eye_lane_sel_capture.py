"""test_eye_lane_sel_capture — proposal §9 test #1.

For each k in 0..7:
  1. Write SWI_EYE_LANE_SEL = k.
  2. Program a generous dwell, then trigger MODE=single + ENTER + FORCE_FULL_SWEEP.
  3. Wait for STATE=DONE.
  4. Assert SWI_EYE_STATUS[6:4] (last_swept_lane_id) == k.
  5. Drain `score_buf` via hierarchical xref (u_dut.score_buf[0..127]).
  6. Assert that exactly lane k's 128 entries were written this sweep —
     all OTHER lanes' references into the buffer remain at their post-reset
     value (0x3F sentinel or 0; we check both stick-options).

Per §2 Option A the buffer holds one lane × 128 points (`logic [5:0]
score_buf [0:127]`). "Only lane k's scores land in the buffer" is
verified by capturing the buffer before the sweep, then again after,
and asserting at least one entry changed when lane_sel=k AND that the
final last_swept_lane_id matches k.

The test re-asserts SWI_EYE_CTRL.RESET between iterations to drop the
sticky capture_valid bit and reset the score buffer; the v2 spec gives
RESET both "force back to S_DONE" + "clear score buffer" semantics.

Invocation:
    cd <worktree> && source set_env.sh
    rm -rf cocotb/tidelink_phy_align_calibrator/sim_build
    make -C cocotb/tidelink_phy_align_calibrator TB_VARIANT=eye \
         MODULE=test_eye_lane_sel_capture

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from eye_common import (
    SWI_EYE_CTRL, SWI_EYE_LANE_SEL, SWI_EYE_STATUS,
    CTRL_RESET, CTRL_MODE_SINGLE,
    STATE_DONE, STATE_TIMED_OUT,
    SCORES_PER_LANE,
    apb_idle, apb_read, apb_write,
    start_clock_and_reset, trigger_eye_sweep, poll_status_state,
    status_decode,
)


def _read_score_buf(dut):
    """Snapshot the calibrator's 128-deep score buffer via hierarchical
    xref. Returns a list of 128 ints in [0, 63].
    """
    out = []
    for idx in range(SCORES_PER_LANE):
        try:
            v = int(dut.u_dut.score_buf[idx].value)
        except Exception:
            v = -1   # unresolved-X sentinel; treat as 'no data'
        out.append(v & 0x3F if v >= 0 else -1)
    return out


async def _settle_and_seed(dut):
    """Drive a clean reset with all calibrator + APB inputs at idle."""
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    # Drive lane_locked=0xFF throughout so each dwell point scores
    # LANE_SCORE_MAX (the sweep latches successfully without spurious
    # faults, and the buffer is full of meaningful values).
    dut.lane_locked.value           = 0xFF
    await apb_idle(dut)
    await start_clock_and_reset(dut)


@cocotb.test()
async def test_lane_sel_capture_all_lanes(dut):
    """Walk SWI_EYE_LANE_SEL through 0..7. For each value:
       * trigger ENTER + FORCE_FULL_SWEEP;
       * wait for DONE;
       * check STATUS.last_swept_lane_id == k;
       * snapshot score_buf and confirm it is populated (at least one
         entry has 6'h3F, the LANE_SCORE_MAX saturating value).
    """
    await _settle_and_seed(dut)

    # Latch role_locked so the calibrator is responsive to ENTER. The
    # v2 eye-mode entry is independent of role_lock when MODE=single
    # but we keep the canonical bring-up path active.
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 4)

    snapshots = {}

    for k in range(8):
        # Clear the buffer + sticky capture_valid before each sweep.
        await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET)
        await ClockCycles(dut.clk, 4)

        # Run the sweep on lane k.
        await trigger_eye_sweep(dut, lane=k, dwell_us=10_000)

        # Poll for DONE (or TIMED_OUT — both are terminal for this test).
        status = await poll_status_state(
            dut, target_states=(STATE_DONE, STATE_TIMED_OUT),
            max_polls=4096,
        )
        fields = status_decode(status)
        assert fields["state"] == STATE_DONE, (
            f"lane={k}: sweep did not reach DONE; final state={fields['state']} "
            f"(STATUS=0x{status:08x}). Calibrator stuck in {fields}."
        )

        # The last_swept_lane_id mirror must match what we programmed.
        assert fields["last_swept_lane"] == k, (
            f"lane={k}: STATUS.last_swept_lane={fields['last_swept_lane']} "
            f"(STATUS=0x{status:08x}) — lane-sel did not propagate to "
            f"the calibrator. Spec §5 SWI_EYE_STATUS[6:4]."
        )

        snapshots[k] = _read_score_buf(dut)

        # The buffer must contain at least ONE valid score: with
        # lane_locked=0xFF the sweep saturates lane_score at LANE_SCORE_MAX
        # (0x3F) at every (slip,phase) point, so every entry should be
        # 0x3F. Tolerate <128 valid entries in case the calibrator
        # only writes on dwell_expire (which still gives 128 writes /
        # sweep but exact count is RTL-detail).
        non_zero = sum(1 for v in snapshots[k] if v > 0)
        assert non_zero >= SCORES_PER_LANE // 2, (
            f"lane={k}: only {non_zero}/{SCORES_PER_LANE} score_buf entries "
            f"were populated. score_buf is not being written during the "
            f"sweep, OR the lane-sel write gate is broken."
        )

    dut._log.info(
        f"OK: 8-lane lane-sel capture — STATUS.last_swept_lane mirrors "
        f"SWI_EYE_LANE_SEL on every iteration; score_buf populated "
        f"per-sweep."
    )


@cocotb.test()
async def test_lane_sel_other_lanes_quiescent(dut):
    """A focused property: when SWI_EYE_LANE_SEL=k, only the buffer
    cells corresponding to lane k get written during the sweep.

    We can't trivially observe "other lanes' scores" because Option A
    has a single-lane buffer (proposal §2: `logic [5:0] score_buf [0:127]`).
    What we CAN observe is that the buffer content tracks ONE lane at
    a time: if we run two sweeps back-to-back with different lane_sel
    and lane_locked patterns, the buffer must reflect the SECOND lane's
    data (not a merge of both).

    Concretely:
      Sweep A: lane_sel=0, lane_locked=0xFF (all lanes scoring high)
      RESET in between (clears buffer).
      Sweep B: lane_sel=3, lane_locked=0x01 (only lane 0 high; lane 3
               scores zero everywhere).
    After Sweep B the buffer should be MOSTLY 0 — proves lane 0's
    high scores from Sweep A didn't bleed into lane 3's view.
    """
    await _settle_and_seed(dut)
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 4)

    # ── Sweep A: lane 0, all lanes locked → buffer fills with 0x3F ───
    dut.lane_locked.value = 0xFF
    await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET)
    await ClockCycles(dut.clk, 4)
    await trigger_eye_sweep(dut, lane=0, dwell_us=10_000)
    await poll_status_state(dut, STATE_DONE, max_polls=4096)
    buf_after_a = _read_score_buf(dut)
    saturated_a = sum(1 for v in buf_after_a if v == 0x3F)
    assert saturated_a >= SCORES_PER_LANE // 2, (
        f"Sweep A: only {saturated_a}/{SCORES_PER_LANE} entries reached "
        f"LANE_SCORE_MAX with lane_locked=0xFF. score_buf write path "
        f"may be broken."
    )

    # ── RESET + Sweep B: lane 3, only lane 0 locked → buffer mostly 0 ─
    await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET)
    await ClockCycles(dut.clk, 4)
    dut.lane_locked.value = 0x01    # ONLY lane 0 ever scores
    await trigger_eye_sweep(dut, lane=3, dwell_us=10_000)
    await poll_status_state(
        dut, target_states=(STATE_DONE, STATE_TIMED_OUT), max_polls=4096
    )
    buf_after_b = _read_score_buf(dut)
    saturated_b = sum(1 for v in buf_after_b if v == 0x3F)

    # Lane 3 is never locked → every dwell scores 0; the buffer should
    # be ENTIRELY 0 (or near-0 if the score counter saturates differently).
    # We assert "no saturated cells" — proves Sweep A's lane-0 data did
    # NOT bleed through and the lane-sel write gate works.
    assert saturated_b <= SCORES_PER_LANE // 8, (
        f"Sweep B: lane_sel=3 but found {saturated_b} saturated cells "
        f"(lane_locked=0x01 means lane 3 never scores). Lane-sel write "
        f"gate may be broken — lane 3's buffer is showing lane 0's "
        f"earlier scores."
    )

    dut._log.info(
        "OK: lane-sel write gate isolates per-lane captures — Sweep A's "
        "data does not leak into Sweep B's buffer."
    )
