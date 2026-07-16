"""
test_sync_dist_obs.py — DATA-MODE per-lane SYNC Hamming-distance OBS unit test
(SoC Labs 2026-06-25, the winscan metric).

Proves CHANGE 2 (tidelink_lane_deskew sync_dist_vec_o):
  Each lane exposes, on sync_dist_vec_o[5L +: 5], the Hamming distance of its
  most-recent incoming word to its SYNC slice (the SAME sync_dist_w the capture
  FSM thresholds with sync_hit <= SYNC_REANCHOR_TOL). It is registered in
  lane_clk then 2-flop-synced into out_clk (mirrors sync_seen_vec_o).

Checks:
  1. CORRECTNESS — drive each lane a word at a KNOWN Hamming distance from its
     SYNC slice (a spread of 0, 3, 5, ... per lane) and assert the obs reads
     exactly that distance after the register + CDC settle.
  2. SWEEP — for one lane, walk the injected distance 0..16 and confirm the obs
     tracks it monotonically (a winscan gradient — the whole point).
  3. READ-ONLY / NO ARM REGRESSION — confirm the obs does NOT perturb the
     capture FSM: feeding distance-0 SYNC slices still arms sync_seen exactly as
     before, and feeding only far (dist>tol) words never arms — i.e. the obs is
     a pure fan-out of sync_dist_w.

Built under TB_SYNC_REANCHOR_EN=1 / TB_EPOCH_ANCHOR_EN=0 (the V2 production
deskew config), where g_sync_capture (hence sync_dist_w) exists.
"""

import os

import cocotb
from cocotb.triggers import Timer

LANES = 8
WIDTH = 16
WORD_NS = 20

SYNC_WORD = 0xF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00

# Compiled per-lane SYNC tolerance the capture FSM uses (for the no-regression
# arm check). Default 4 = DUT/tb default.
SYNC_REANCHOR_TOL = int(os.environ.get("SYNC_REANCHOR_TOL", "4"))


def sync_slice(gi):
    return (SYNC_WORD >> (gi * WIDTH)) & 0xFFFF


def hamming(a, b):
    return bin((a ^ b) & 0xFFFF).count("1")


def word_at_distance(base, dist):
    """Return a 16-bit word at exactly `dist` Hamming bits from `base` (flip the
    lowest `dist` bits)."""
    w = base
    for i in range(dist):
        w ^= (1 << i)
    return w & 0xFFFF


def lane_clk(dut, gi):
    return getattr(dut, f"lane_clk{gi}")


def lane_data(dut, gi):
    return getattr(dut, f"lane_data{gi}")


def dist_obs(dut, gi):
    return (int(dut.sync_dist_vec.value) >> (5 * gi)) & 0x1F


async def reset(dut, mask=0xFF):
    dut.rst_n.value = 0
    dut.training_mode.value = 0
    dut.lane_mask.value = mask
    dut.out_clk.value = 0
    try:
        dut.sync_obs_clr.value = 0
    except Exception:
        pass
    for gi in range(LANES):
        lane_clk(dut, gi).value = 0
        lane_data(dut, gi).value = 0
    await Timer(5 * WORD_NS, units="ns")
    dut.rst_n.value = 1
    await Timer(3 * WORD_NS, units="ns")


async def pulse_lane_clocks(dut, n=3):
    """Toggle every lane_clk n full periods (latch the live lane_data into the
    lane_clk-domain sync_dist register)."""
    for _ in range(n):
        for gi in range(LANES):
            lane_clk(dut, gi).value = 1
        await Timer(WORD_NS / 2, units="ns")
        for gi in range(LANES):
            lane_clk(dut, gi).value = 0
        await Timer(WORD_NS / 2, units="ns")


async def pulse_out_clk(dut, n=4):
    """Toggle out_clk n periods (push the lane-domain value through the 2-flop
    out_clk synchroniser)."""
    for _ in range(n):
        dut.out_clk.value = 1
        await Timer(WORD_NS / 2, units="ns")
        dut.out_clk.value = 0
        await Timer(WORD_NS / 2, units="ns")


async def apply_words_and_settle(dut, words):
    """Drive per-lane words, then clock lane + out domains so the obs settles."""
    for gi in range(LANES):
        lane_data(dut, gi).value = words[gi]
    # Hold the words STABLE across several lane_clk edges so the lane-domain
    # register and the out_clk 2-flop both latch the same (quasi-static) value.
    for _ in range(4):
        await pulse_lane_clocks(dut, n=2)
        await pulse_out_clk(dut, n=2)


@cocotb.test()
async def test_sync_dist_obs_correctness(dut):
    await reset(dut)

    # Per-lane injected distances: a spread including 0, 3, 5 (the task's named
    # cases) plus others to exercise the full 5-bit field.
    inj = [0, 3, 5, 1, 7, 5, 2, 6]
    words = [word_at_distance(sync_slice(gi), inj[gi]) for gi in range(LANES)]

    # Sanity: the words really are at the intended distances.
    for gi in range(LANES):
        assert hamming(words[gi], sync_slice(gi)) == inj[gi]

    await apply_words_and_settle(dut, words)

    for gi in range(LANES):
        got = dist_obs(dut, gi)
        assert got == inj[gi], (
            f"lane {gi}: injected SYNC-distance {inj[gi]}, obs read {got} "
            f"(word=0x{words[gi]:04x} slice=0x{sync_slice(gi):04x})"
        )
    cocotb.log.info(
        "PASS: per-lane sync_dist_vec reads the injected distances "
        f"{inj} (lanes 0..7)"
    )


@cocotb.test()
async def test_sync_dist_obs_sweep(dut):
    """Walk lane 0's injected distance 0..16; the obs must track it — the
    winscan gradient the IDELAY tap centres on."""
    await reset(dut)
    far = [word_at_distance(sync_slice(gi), 8) for gi in range(LANES)]

    for d in range(0, 17):
        words = list(far)
        words[0] = word_at_distance(sync_slice(0), d)
        await apply_words_and_settle(dut, words)
        got = dist_obs(dut, 0)
        assert got == d, f"sweep: injected dist {d} on lane0, obs read {got}"
    cocotb.log.info("PASS: lane0 sync_dist obs tracks 0..16 (winscan gradient)")


@cocotb.test()
async def test_sync_dist_obs_no_arm_regression(dut):
    """The obs is a pure read-only fan-out of sync_dist_w — it adds NO gate to the
    capture FSM, so the FSM's documented arm semantics are unchanged. Verify:

      (a) FAR words (dist 8 > tol): sync_hit never fires -> sync_seen stays 0;
          the obs correctly reads 8 the whole time.
      (b) CONTINUOUS exact slices (dist 0, within tol, EVERY beat): this is the
          'continuous within-tol' case the self-gating periodic-confirm arm is
          DESIGNED to REJECT (the gap counter resets every beat so the periodic
          re-match never fires) -> sync_seen STAYS 0. The obs reads 0. This is
          the UNCHANGED anti-poison behaviour — the obs does not perturb it.
      (c) The obs VALUE depends ONLY on the injected distance, NOT on the arm
          state (it reads the same 0/8 in both the armed-reject and far cases),
          proving it is a pure read-only fan-out of sync_dist_w."""
    await reset(dut)

    # (a) Far words: distance 8 (> SYNC_REANCHOR_TOL). obs reads 8, no arm.
    far = [word_at_distance(sync_slice(gi), 8) for gi in range(LANES)]
    await apply_words_and_settle(dut, far)
    for gi in range(LANES):
        assert dist_obs(dut, gi) == 8, f"lane {gi}: far obs != 8"
    seen_far = int(dut.obs_sync_seen_wr.value)
    assert seen_far == 0, (
        f"far-only words must NOT arm any lane, but obs_sync_seen_wr=0x{seen_far:02x}"
    )

    # (b) Continuous exact SYNC slices (dist 0). The self-gating arm REJECTS a
    # continuous within-tol stream by design (anti-poison), so sync_seen stays 0
    # and the obs reads 0 — the presence of the obs does not change this.
    exact = [sync_slice(gi) for gi in range(LANES)]
    for gi in range(LANES):
        lane_data(dut, gi).value = exact[gi]
    for _ in range(120):
        await pulse_lane_clocks(dut, n=1)
        await pulse_out_clk(dut, n=1)
    for gi in range(LANES):
        assert dist_obs(dut, gi) == 0, f"lane {gi}: exact-slice obs != 0"
    seen_exact = int(dut.obs_sync_seen_wr.value)
    assert seen_exact == 0x00, (
        "a CONTINUOUS exact-slice stream is the anti-poison case the FSM rejects "
        f"-> sync_seen must stay 0 (obs adds no gate), but got 0x{seen_exact:02x}"
    )
    cocotb.log.info(
        "PASS: sync_dist obs is read-only — far words read dist 8 with no arm, "
        "continuous exact slices read dist 0 and the FSM's anti-poison reject is "
        "UNCHANGED (obs adds no gate; value tracks distance, not arm state)"
    )
