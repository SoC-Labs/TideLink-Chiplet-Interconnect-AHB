"""FIX-2 fail-first — TOLERANT ANCHOR-VERIFY (tol-3, wrong-slot-safe).

Silicon failure class (iter-1 die_a — root-caused, evidence-backed)
-------------------------------------------------------------------
The anchor COMMIT is tol-5 (per-lane sync_dist <= SYNC_REANCHOR_TOL=5 in the
deskew) but the anchor VERIFY was tol-0 EXACT (dbg_lane_any_match_w, ==). On
die_a's marginal eye a CORRECTLY-aligned lane lands at Hamming 1-5 from its SYNC
slice: it COMMITS (tol-5) but can NEVER exact-VERIFY -> ws_verify_q stuck at 0
(the die_a verify_stuck). die_b's cleaner eye verifies exact (92%), so it is
die_a-eye-specific.

FIX-2 (WavD2DGpio_v2.v) verifies with a Hamming tolerance of 3:
  anchor_vfy_lane_w[L] = sync_live_popcount16(slice_L ^ SYNC_L) <= VERIFY_TOL(3)
WHY 3 (not 5): the 8 SYNC slices of TIDELINK_SYNC_WORD form a code whose MINIMUM
pairwise inter-slice Hamming distance is 4, so tol-3 (< 4) PROVABLY rejects any
wrong slot (a mis-aligned lane reads a whole different slice at dist >= 4 > 3)
while accepting a correctly-aligned marginal-eye lane at dist <= 3. The
cross-lane simultaneity requirement is KEPT (anchor_vfy_word_w = & over active
lanes on ONE valid beat), so a temporally mis-aligned lane still fails.

How this test models it deterministically
-----------------------------------------
The FIX-2 outputs anchor_vfy_lane_w / anchor_vfy_word_w are COMBINATIONAL in
deskew_aligned_data — so this forces a synthetic post-deskew word (all 8 lanes
the exact SYNC slice, ONE lane perturbed to a controlled Hamming distance) plus
the valid strobe + an all-lanes-active mask, and reads the verify verdict
directly (no clock needed). Cases on lane 0 (SYNC slice 0x1F00):

  * dist 0 (exact)      -> verify=1  (baseline; both tol-0 and tol-3)
  * dist 2 / dist 3     -> verify=1 at tol-3  (RED at tol-0: never verifies)
  * dist 4              -> verify=0  (wrong-slot-safe: tol-3 < min inter-slice 4)
  * real WRONG SLOT     -> verify=0  (lane0 carries slice 1's content, dist 6)
    (dist 3 is the FIX-2 discriminator: GREEN at tol-3, RED at tol-0 exact.)

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_l5 SIM=vcs \
      make MODULE=test_tolerant_verify
"""
import cocotb
from cocotb.triggers import Timer
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB
from test_31_autonomous_training_exit import _ctrl, _si, _idle_stimulus, _reset

# TIDELINK_SYNC_WORD (deps/tidelink-phy/rtl/tidelink_sync_word.svh)
SYNC = 0xF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00

# Model on the slave (arbitrary — the verify block is per-die identical).
SIDE = "s"
INJ_LANE = 0                       # SYNC slice 0 = 0x1F00


def _slice(word, L):
    return (word >> (16 * L)) & 0xFFFF


def _set_slice(word, L, val):
    return (word & ~(0xFFFF << (16 * L))) | ((val & 0xFFFF) << (16 * L))


def _gpio(dut, side):
    """The WavD2DGpio_v2 instance: controller.u_wlink -> Wlink.phy ->
    WlinkGPIOPHY.gpio (the same hierarchy test_33's _vfy_lane_net walks)."""
    return _ctrl(dut, side).u_wlink.phy.gpio


async def _verify_word(dut, side, aligned_word):
    """Force the post-deskew aligned word + valid strobe + all-lanes-active mask,
    settle the combinational verify, and return (anchor_vfy_word_w,
    anchor_vfy_lane_w). Pure combinational read — no link clock needed."""
    g = _gpio(dut, side)
    g.io_link_rx_rx_lane_mask.value = Force(0xFF)     # all 8 lanes REQUIRED
    g.deskew_out_valid_w.value      = Force(1)        # valid post-deskew beat
    g.deskew_aligned_data.value     = Force(aligned_word)
    await Timer(2, units="ns")                        # settle combinational
    return _si(g.anchor_vfy_word_w), _si(g.anchor_vfy_lane_w)


@cocotb.test()
async def test_tolerant_verify(dut):
    """A correctly-aligned marginal-eye lane (Hamming 2-3 from SYNC, within the
    tol-5 commit but outside the exact compare) must VERIFY at tol-3, while a
    wrong slot (dist >= 4) must NOT. On ca19da3 (tol-0 exact) the dist-3 lane
    never verifies (verify_stuck) — the fail-first assertion."""
    log = dut._log
    log.info("FIX-2 tolerant-verify repro — marginal lane vs wrong slot")
    tb = PairTB(dut)                 # starts the clocks + idles the buses
    await _idle_stimulus(dut)
    await _reset(dut)

    g = _gpio(dut, SIDE)
    base = _slice(SYNC, INJ_LANE)    # 0x1F00

    # dist 0 (exact): every lane the exact SYNC slice.
    w0,  l0  = await _verify_word(dut, SIDE, SYNC)
    # dist 2 marginal: flip 2 low bits of lane 0 (0x1F00 -> 0x1F03).
    w2,  l2  = await _verify_word(dut, SIDE, _set_slice(SYNC, INJ_LANE, base ^ 0x0003))
    # dist 3 marginal: flip 3 low bits (0x1F00 -> 0x1F07) — the discriminator.
    w3,  l3  = await _verify_word(dut, SIDE, _set_slice(SYNC, INJ_LANE, base ^ 0x0007))
    # dist 4: flip 4 low bits (0x1F00 -> 0x1F0F) — the wrong-slot distance floor.
    w4,  l4  = await _verify_word(dut, SIDE, _set_slice(SYNC, INJ_LANE, base ^ 0x000F))
    # real WRONG SLOT: lane 0 carries slice 1's content (0x3D2E, dist 6 from 0x1F00).
    wrong    = _set_slice(SYNC, INJ_LANE, _slice(SYNC, 1))
    wws, lws = await _verify_word(dut, SIDE, wrong)

    for name in ("io_link_rx_rx_lane_mask", "deskew_out_valid_w", "deskew_aligned_data"):
        getattr(g, name).value = Release()

    b0 = lambda v: (v >> INJ_LANE) & 1
    log.info("================ FIX-2 TOLERANT-VERIFY EVIDENCE ================")
    log.info(f"anchor_vfy_word_w : d0={w0} d2={w2} d3={w3} d4={w4} wrongslot={wws}")
    log.info(f"anchor_vfy_lane[0]: d0={b0(l0)} d2={b0(l2)} d3={b0(l3)} "
             f"d4={b0(l4)} wrongslot={b0(lws)}")
    log.info("===============================================================")

    # ---- Baseline: the exact SYNC word verifies (both tol-0 and tol-3) --------
    assert w0 == 1 and b0(l0) == 1, (
        "exact SYNC word did not verify — harness/force broken (not a FIX-2 "
        "verdict)")

    # ---- THE FIX-2 DISCRIMINATOR (RED on ca19da3 tol-0, GREEN after tol-3) ----
    assert w3 == 1 and b0(l3) == 1, (
        "dist-3 marginal lane did NOT verify — the tol-0 EXACT compare "
        "(pre-FIX-2): a correctly-aligned marginal-eye lane commits (tol-5) but "
        "never verifies (die_a verify_stuck). FIX-2 (VERIFY_TOL=3) must accept "
        "dist <= 3.")
    assert w2 == 1 and b0(l2) == 1, (
        "dist-2 marginal lane did not verify at tol-3 (Hamming-2 within tol-3)")

    # ---- WRONG-SLOT SAFETY (rejects at tol-3; also rejects at tol-0) ----------
    assert w4 == 0 and b0(l4) == 0, (
        "dist-4 lane VERIFIED at tol-3 — VERIFY_TOL is too loose (must be < the "
        "minimum inter-slice Hamming distance = 4, so it can never accept the "
        "closest possible wrong slot)")
    assert wws == 0 and b0(lws) == 0, (
        "a REAL wrong slot (lane 0 = slice 1's content, dist 6) VERIFIED — the "
        "tolerant compare accepted a whole wrong slice (wrong-slot-unsafe)")

    log.info("VERDICT: PASS — VERIFY_TOL=3 accepts dist<=3 (marginal eye), "
             "rejects dist>=4 (min inter-slice Hamming=4 => wrong-slot-safe); "
             "cross-lane simultaneity requirement unchanged.")
