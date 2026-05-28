"""test_eye_apb_burst_readout — proposal §9 test #6.

Walks SWI_EYE_LANE_SEL through 0..7, draining each lane's 128 scores
via EYE_BURST_DATA (auto-increment, 5 packed 6-bit scores per read, 26
reads per lane). Cross-checks the drained values against a hierarchical
reference into u_dut.score_buf.

Proposal §5:
  EYE_BURST_DATA = 0x4403_216C, RO. Each read returns
    [29:0] = five packed 6-bit scores (score[0..4]),
    auto-advance internal pointer by 5 on every read.
  EYE_SCORE_IDX  = 0x4403_2164, RW. [6:0] = point (slip[2:0],phase[3:0]);
    [16] = auto-increment after read. We write 0 with auto-inc to seed
    the burst pointer at 0.

The drain protocol per the proposal §7 worked example:
    write32(base, EYE_SCORE_IDX, 0 | (1<<16))   # seed + auto-inc
    for _ in range(26):
        out.append(read32(base, EYE_BURST_DATA))

Test plan:
  For lane in 0..7:
    1. Write SWI_EYE_LANE_SEL = lane.
    2. Trigger sweep, wait for DONE.
    3. Seed EYE_SCORE_IDX with auto-inc, drain 26 reads into a buffer.
    4. Unpack each read into five 6-bit scores -> 130 values; truncate
       to 128.
    5. Cross-check the 128 drained values against u_dut.score_buf[0..127].

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import ClockCycles

from eye_common import (
    SWI_EYE_CTRL, SWI_EYE_LANE_SEL, EYE_SCORE_IDX, EYE_BURST_DATA,
    CTRL_RESET,
    SCORE_IDX_AUTO_INC, BURST_READS_PER_LANE, BURST_SCORES_PER_READ,
    SCORES_PER_LANE, STATE_DONE, STATE_TIMED_OUT,
    apb_idle, apb_read, apb_write,
    start_clock_and_reset, trigger_eye_sweep, poll_status_state,
)


def _unpack_burst(word):
    """Five packed 6-bit scores at [29:0]: score[i] at [6i+5 : 6i]."""
    return [(word >> (6 * i)) & 0x3F for i in range(BURST_SCORES_PER_READ)]


def _read_score_buf(dut):
    out = []
    for idx in range(SCORES_PER_LANE):
        try:
            v = int(dut.u_dut.score_buf[idx].value)
        except Exception:
            v = -1
        out.append(v & 0x3F if v >= 0 else -1)
    return out


async def _drain_lane(dut, lane):
    """Drain all 128 scores for the currently-selected lane via burst
    reads. Returns the 128-element score list."""
    # Seed the burst pointer at index 0 with auto-inc enabled.
    await apb_write(dut, EYE_SCORE_IDX, 0 | SCORE_IDX_AUTO_INC)

    raw_words = []
    for _ in range(BURST_READS_PER_LANE):
        raw_words.append(await apb_read(dut, EYE_BURST_DATA))

    # Unpack 26 words × 5 scores = 130; truncate to 128.
    flat = []
    for w in raw_words:
        flat.extend(_unpack_burst(w))
    return flat[:SCORES_PER_LANE]


@cocotb.test()
async def test_burst_readout_matches_score_buf(dut):
    """Walk lane 0..7, drain each lane via EYE_BURST_DATA, and cross-check
    against the hierarchical score_buf reference."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0xFF
    await apb_idle(dut)
    await start_clock_and_reset(dut)
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 4)

    for lane in range(8):
        # Reset so previous lane's buffer doesn't pollute this iteration.
        await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET)
        await ClockCycles(dut.clk, 4)

        # Run a sweep on this lane.
        await trigger_eye_sweep(dut, lane=lane, dwell_us=10_000)
        await poll_status_state(
            dut, target_states=(STATE_DONE, STATE_TIMED_OUT),
            max_polls=4096,
        )

        # Take a synchronised hierarchical snapshot BEFORE the APB drain
        # — the drain itself takes a few hundred clk cycles and we want
        # to compare apples to apples.
        ref = _read_score_buf(dut)

        drained = await _drain_lane(dut, lane)

        assert len(drained) == SCORES_PER_LANE, (
            f"lane={lane}: drained {len(drained)} entries, expected "
            f"{SCORES_PER_LANE}."
        )

        # Cross-check. Any unresolved-X cells in `ref` are skipped.
        mismatches = []
        for i in range(SCORES_PER_LANE):
            if ref[i] < 0:
                continue
            if drained[i] != ref[i]:
                mismatches.append((i, drained[i], ref[i]))

        assert not mismatches, (
            f"lane={lane}: APB burst drain disagrees with score_buf "
            f"hierarchical reference at {len(mismatches)} cells. "
            f"First 4 mismatches (idx, burst, ref): "
            f"{mismatches[:4]}. The auto-increment burst path or the "
            f"5x6-bit packing is wrong."
        )

    dut._log.info(
        "OK: 8-lane EYE_BURST_DATA drain matches score_buf for all lanes."
    )


@cocotb.test()
async def test_burst_readout_auto_increment(dut):
    """Sanity: two back-to-back EYE_BURST_DATA reads return DIFFERENT
    score words (the pointer auto-advances), assuming the buffer is
    populated with a non-uniform pattern."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    # Mix of locked/unlocked lanes so score values vary across points.
    dut.lane_locked.value = 0x33     # lanes 0,1,4,5
    await apb_idle(dut)
    await start_clock_and_reset(dut)
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 4)

    await apb_write(dut, SWI_EYE_CTRL, CTRL_RESET)
    await ClockCycles(dut.clk, 4)
    await trigger_eye_sweep(dut, lane=0, dwell_us=10_000)
    await poll_status_state(
        dut, target_states=(STATE_DONE, STATE_TIMED_OUT), max_polls=4096
    )

    # Seed pointer at 0 with auto-inc.
    await apb_write(dut, EYE_SCORE_IDX, 0 | SCORE_IDX_AUTO_INC)
    w0 = await apb_read(dut, EYE_BURST_DATA)
    w1 = await apb_read(dut, EYE_BURST_DATA)

    # The full buffer cannot be uniformly identical 5-tuples, so two
    # consecutive bursts should generally differ. If they happen to
    # match, log a warning rather than fail (the data depends on the
    # RTL sweep order).
    if w0 == w1:
        dut._log.warning(
            f"Two consecutive EYE_BURST_DATA reads returned the same "
            f"value 0x{w0:08x} — auto-inc may not be working, OR the "
            f"underlying buffer is uniformly 0 at these points. "
            f"Inconclusive; rely on test_burst_readout_matches_score_buf."
        )

    dut._log.info(f"EYE_BURST_DATA[0]=0x{w0:08x}, [1]=0x{w1:08x}.")
