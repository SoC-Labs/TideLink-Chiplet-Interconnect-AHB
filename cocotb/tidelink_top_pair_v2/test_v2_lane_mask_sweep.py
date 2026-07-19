"""ODD / PARTIAL LANE-COUNT sweep — bidirectional byte-exact data gate.

WHY THIS EXISTS
---------------
Silicon (2026-07-16, cd2db38) measured a lane census of 5 ALIVE lanes
(0,2,5,6,7) and 3 dead (1,3,4). The shipped mask 0xE4 = {2,5,6,7} (popcount 4)
is byte-exact. Adding the proven-good lane 0 -> 0xE5 = {0,2,5,6,7} (popcount 5)
TRAINS (bilateral fcsm=4, reanchored=1, per-lane SYNC healthy) but delivers
ALL ZEROS to the GP1 RX aperture.

Pre-existing sim coverage only ever exercised popcount 8 (0xFF POR default) and
popcount 4 (test_v2_reduced_lane.py, 0xE4, M->S only). BOTH are powers of two.
No odd / non-power-of-2 lane count has ever been simulated, in either
direction. This suite closes that hole permanently.

The link layer packs bytes as: logical lane k (the k-th ENABLED lane, compacted
by the PHY via a prefix-popcount `rxLanePos`) carries byte k and byte k+K, where
K = popcount(mask), and bytesPerCycle = 2K. K=5 => 10 bytes/link-word, an ODD
byte-per-lane geometry that no power-of-2 mask ever produces.

USAGE
-----
    make EPOCH_PROFILE=zero MODULE=test_v2_lane_mask_sweep LANE_MASK=0xE5

`LANE_MASK` (env, default 0xE5) selects the mask under test. The suite is
mask-agnostic: it asserts byte-exact delivery in BOTH directions under whatever
mask it is given, so the same code is the control (0xFF / 0xE4) and the
experiment (0xE5 / 0x1F / 0xE7 / ...).

INSTRUMENT DISCIPLINE
---------------------
This project has been burned repeatedly by tests that could not go red (see
feedback_verify_instrument_before_dut). Therefore:
  * test_00 is a SELF-TEST of the oracle: it corrupts the expected payload and
    asserts the comparison FAILS. A green test_00 proves the oracle can detect
    wrong data.
  * The oracle here is STRICTER than pair_v2_common.send_and_check, which skips
    got[1] (the dest_addr word). We compare ALL FOUR words, so an all-zeros RX
    can never masquerade as a pass.
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, make_packet, ST_CAL_DONE
from test_v2_reduced_lane import force_lane_mask, read_mask_state

LANE_MASK = int(os.environ.get("LANE_MASK", "0xE5"), 0)
POPCOUNT = bin(LANE_MASK).count("1")
ACTIVE_LANES = [i for i in range(8) if (LANE_MASK >> i) & 1]

# Distinct, non-zero, byte-varied payloads. Every byte lane differs so a
# partial/rotated gather shows up as a mismatch rather than an accidental pass.
PAYLOAD_M2S = [0xCAFE0001, 0xCAFE0002]
PAYLOAD_S2M = [0xBEEF0003, 0xBEEF0004]


def _banner(tb):
    tb.log.info("=" * 70)
    tb.log.info(f"  LANE_MASK = 0x{LANE_MASK:02X}  popcount(K) = {POPCOUNT}  "
                f"active lanes = {ACTIVE_LANES}")
    tb.log.info(f"  bytesPerCycle = 2K = {2 * POPCOUNT}  "
                f"({'POWER-OF-2 lane count' if POPCOUNT in (1, 2, 4, 8) else 'ODD/NON-POWER-OF-2 lane count'})")
    tb.log.info("=" * 70)


async def _bringup(tb):
    """POR, latch LANE_MASK on both dies (continuous Force so the async reset
    re-init to 0xFF cannot clobber it), then the standard bring-up."""
    _banner(tb)
    await tb.reset()
    force_lane_mask(tb, LANE_MASK)
    await ClockCycles(tb.dut.hclk, 50)
    force_lane_mask(tb, LANE_MASK)
    for side, name in (("m", "M"), ("s", "S")):
        tx, rx, cal, dsk = read_mask_state(tb, side)
        tb.log.info(f"  [mask] {name}: swi_tx=0x{tx:02x} swi_rx=0x{rx:02x} "
                    f"calibrator=0x{cal:02x} deskew=0x{dsk:02x} "
                    f"(want 0x{LANE_MASK:02x})")
        assert tx == LANE_MASK and rx == LANE_MASK, (
            f"{name}: lane mask did not hold (swi_tx=0x{tx:02x} "
            f"swi_rx=0x{rx:02x}, want 0x{LANE_MASK:02x}) — INSTRUMENT FAULT, "
            f"the mask never reached the DUT")
    snap = await run_bringup_full(tb)
    return snap


async def _send_strict(tb, src, dst, payload, ctx):
    """Send a 4-word packet src->dst and compare ALL FOUR words byte-exactly.

    Stricter than pair_v2_common.send_and_check (which skips got[1]).
    Returns (ok, got, words)."""
    words = make_packet(payload)
    await tb.ahb_tx_write_packet(src, words)
    await ClockCycles(tb.dut.hclk, 3000)
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(4)]
    ok = all(got[i] == words[i] for i in range(4))
    tb.log.info(f"  [{ctx}] mask=0x{LANE_MASK:02X} K={POPCOUNT} {src}->{dst}: "
                f"sent=[{', '.join(f'0x{w:08x}' for w in words)}] "
                f"rx=[{', '.join(f'0x{w:08x}' for w in got)}] -> "
                f"{'BYTE-EXACT' if ok else 'MISMATCH'}")
    if not ok and all(g == 0 for g in got):
        tb.log.error(f"  [{ctx}] RX IS ALL ZEROS — the silicon 0xE5 signature "
                     f"(link trains, payload never lands)")
    return ok, got, words


# ---------------------------------------------------------------------------
# test_00 — INSTRUMENT SELF-TEST. Must be first. Proves the oracle goes RED.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_00_oracle_selftest(dut):
    """Prove the byte-exact oracle can FAIL. Sends a real packet, then compares
    against a deliberately WRONG expectation; the comparison must not match.

    Without this, a suite that passes at 0xFF/0xE4 but is structurally
    incapable of going red would be worthless."""
    tb = PairV2TB(dut)
    await _bringup(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    ok, got, words = await _send_strict(tb, "m", "s", PAYLOAD_M2S,
                                        ctx="oracle-selftest")
    # The real comparison should pass on a healthy mask; but the SELF-TEST is
    # that a corrupted expectation MUST mismatch.
    corrupted = [w ^ 0xFFFFFFFF for w in words]
    false_ok = all(got[i] == corrupted[i] for i in range(4))
    assert not false_ok, (
        "ORACLE FAULT: RX matched a bit-inverted expectation — the comparison "
        "is not actually comparing anything")
    # And an all-zeros RX must never satisfy the real oracle.
    zeros_ok = all(0 == words[i] for i in range(4))
    assert not zeros_ok, (
        "ORACLE FAULT: the expected packet is itself all-zeros, so an all-zeros "
        "RX would false-pass")
    tb.log.info("  [oracle-selftest] oracle is live: it rejects both a "
                "bit-inverted and an all-zeros RX")


@cocotb.test()
async def test_01_linkup(dut):
    """The link must TRAIN under the mask: cal_done both dies, bilateral
    CR/CRACK, FCSM=4. On silicon 0xE5 this PASSES — training is not the bug."""
    tb = PairV2TB(dut)
    snap = await _bringup(tb)
    for name, st in (("M", snap["m_p1"]), ("S", snap["s_p1"])):
        assert ST_CAL_DONE(st) == 1, f"{name}: cal_done not set (0x{st:08x})"
    assert await tb.wait_cr_crack(), (
        f"mask 0x{LANE_MASK:02X}: CR/CRACK did not complete — "
        f"M(cr={tb.fcsm_cr_seen('m')},crack={tb.fcsm_crack_seen('m')}) "
        f"S(cr={tb.fcsm_cr_seen('s')},crack={tb.fcsm_crack_seen('s')})")
    for side, name in (("m", "M"), ("s", "S")):
        assert tb.fcsm_state(side) == 4, (
            f"{name}: FCSM state {tb.fcsm_state(side)} != 4 (LINK_IDLE) "
            f"under mask 0x{LANE_MASK:02X}")
    tb.log.info(f"  mask 0x{LANE_MASK:02X}: TRAINED (bilateral fcsm=4)")


@cocotb.test()
async def test_02_data_m2s(dut):
    """M->S 4-word packet must be byte-exact under the mask."""
    tb = PairV2TB(dut)
    await _bringup(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, got, words = await _send_strict(tb, "m", "s", PAYLOAD_M2S, ctx="m2s")
    assert ok, (
        f"mask 0x{LANE_MASK:02X} (K={POPCOUNT}) M->S NOT byte-exact: "
        f"sent [{', '.join(f'0x{w:08x}' for w in words)}] "
        f"got [{', '.join(f'0x{w:08x}' for w in got)}]")


@cocotb.test()
async def test_03_data_s2m(dut):
    """S->M 4-word packet must be byte-exact under the mask.

    NOTE: no reduced-lane S->M data test existed before this one — the 0xE4
    suite is M->S only."""
    tb = PairV2TB(dut)
    await _bringup(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, got, words = await _send_strict(tb, "s", "m", PAYLOAD_S2M, ctx="s2m")
    assert ok, (
        f"mask 0x{LANE_MASK:02X} (K={POPCOUNT}) S->M NOT byte-exact: "
        f"sent [{', '.join(f'0x{w:08x}' for w in words)}] "
        f"got [{', '.join(f'0x{w:08x}' for w in got)}]")
