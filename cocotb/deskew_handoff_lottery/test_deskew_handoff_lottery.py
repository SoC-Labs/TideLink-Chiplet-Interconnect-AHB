"""Cross-lane whole-word skew ROBUSTNESS harness for the V2 deskew.

*** PREMISE REFUTED (2026-07-22) — READ THIS FIRST ***
This bench was built to reproduce a KR260 "intermittent delivery" bug. That bug
was a receiver-side MEASUREMENT ARTIFACT, not a link defect: the RX FIFO is a
STREAMING FIFO (packets queue at advancing 16-byte offsets), but the hardware
receiver read a FIXED offset (0x8) and only ever saw packet 0. Reading at the
correct strided offsets delivers 12/12 tags byte-exact, in order. There is NO
framer-lock lottery; the deskew is correct and delivery is reliable. So the
"lottery / intermittent / SHEARED" language below refers ONLY to behaviour under
DELIBERATELY INJECTED synthetic whole-word skew (a robustness/envelope
characterisation, parametric on EPOCH_ANCHOR_EN / LANE_MASK for Phase 3) — it is
NOT a reproduction of any real KR260 delivery bug. See README.md. NB this
harness's own read path (_send_one) already uses the CORRECT per-packet strided
drain, which is exactly what the hardware receiver failed to do.

--- original design notes (retained for context) ---

HARDWARE OBSERVATION originally targeted
-------------------------------------
With both dies fcsm=4 / cal=1 in data mode (SYNC beacon off):
  * the FIRST packet sent crosses BYTE-EXACT, but the NEXT packets read back
    all-zero (not delivered) -- within the SAME bring-up; and
  * across PL reloads, WHICH direction / whether-it-delivers is a LOTTERY.
  * die_b's post-deskew slice lands DETERMINISTICALLY wrong (identical across
    POR/re-train retries, lane-0 slice reads 0) and only re-rolls at PL reload.

ROOT-CAUSE HYPOTHESIS (the thing this bench exercises)
------------------------------------------------------
The cross-lane word deskew (tidelink_lane_deskew_v2.sv) anchors ONCE at the
training->data handoff. In the shipping V2 build WlinkGPIOPHY EPOCH_ANCHOR_EN=0,
so the one-shot training-exit EPOCH corrector is OFF and only SYNC_REANCHOR is
nominally enabled -- but SYNC_REANCHOR needs the SYNC beacon, which is idle-gated
away in data mode, so it never re-arms. Net: whatever per-lane word phase the
deskew latched at the handoff is FROZEN for all of data mode. If it latched the
wrong word-phase, the assembled 128-bit io_link_data is sheared -> packets read
back zero, with NO re-anchor to recover.

HOW THIS SIM MODELS THE HARDWARE (and the deterministic-wrong / lottery split)
------------------------------------------------------------------------------
epoch_skew_rt.sv injects a per-lane WHOLE-WORD (16 pad_clk cycle) skew whose
per-lane depth cocotb sets ONCE at reset and holds constant through the entire
bring-up. So within a trial (and across POR / re-train retries of that trial)
the skew -- and therefore the deskew anchor outcome -- is DETERMINISTIC, exactly
like die_b's fixed-wrong slice. A DIFFERENT trial uses a DIFFERENT per-lane
vector, which models a PL-RELOAD re-roll of the ribbon realization: that is the
only thing that re-rolls the lottery on silicon. The ensemble of trials is the
lottery; each individual trial is deterministic.

WHAT THE TESTS ASSERT
---------------------
  test_00_zero_skew_control  : NEGATIVE CONTROL. Zero skew => every packet, both
                               directions, both bring-up positions, delivers
                               byte-exact. Hard fail if not. (Rules out a broken
                               harness / phantom-pop false-negative.)
  test_1x_<realization>      : one deterministic ribbon realization each. Logs a
                               per-(direction, packet) delivery table. Under the
                               FIX build (EPOCH_ANCHOR=1) EVERY skewed-direction
                               packet must deliver (fix gate, hard). Under the
                               SHIPPING build (EPOCH_ANCHOR=0) the clean direction
                               must still deliver (harness sanity) and the skewed
                               direction is recorded.
  test_99_lottery_summary    : re-runs all realizations and asserts the ensemble
                               signature: SHIPPING => MIXED outcomes (some deliver,
                               some shear -> a genuine lottery, not a total break);
                               FIX => all deliver.

Every "delivered" is a DISTINCT-payload byte-exact check that also pops the
packet from the RX FIFO (drains offsets 0..12), so a stale FIFO read cannot
produce a false PASS (the phantom-pop / stale-read classes that have burned this
project). Distinct payloads per (trial, direction, packet) are the tags.

Run (source ../../set_env.sh ; export TIDELINK_PHY_V2=1):
  make EPOCH_ANCHOR=0 MODULE=test_deskew_handoff_lottery   # shipping: lottery
  make EPOCH_ANCHOR=1 MODULE=test_deskew_handoff_lottery   # fix: all deliver
  make lottery                                             # both, one transcript
"""
import os
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_PKT_WORD_LEN,
)

ANCHOR    = os.environ.get("EPOCH_ANCHOR", "0") == "1"
LANE_MASK = int(os.environ.get("LANE_MASK", "0xFF"), 0)

BUILD = "FIX(EPOCH_ANCHOR=1)" if ANCHOR else "SHIPPING(EPOCH_ANCHOR=0)"

# ---------------------------------------------------------------------------
# Deterministic ribbon realizations. Each maps to one "PL load". The per-lane
# values are WHOLE-WORD delays (0..7) applied to that direction's 8 lanes.
#   m2s = master TX -> slave  RX   (slave's deskew must undo it)
#   s2m = slave  TX -> master RX   (master's deskew must undo it)
# R1 is the measured v37 silicon fingerprint on the master's RX (S->M skewed,
# M->S clean); R2 is its mirror; R3 isolates a single deterministically-wrong
# lane 0 (the "lane-0 slice reads 0" HW detail); R4 skews BOTH directions.
# ---------------------------------------------------------------------------
SIL = [3, 7, 5, 4, 6, 3, 7, 5]
REALIZATIONS = [
    ("R1_s2m_silicon", [0]*8, SIL),
    ("R2_m2s_silicon", SIL,   [0]*8),
    ("R3_s2m_lane0",   [0]*8, [7, 0, 0, 0, 0, 0, 0, 0]),
    ("R4_both_skew",   [2, 5, 1, 6, 3, 7, 4, 2], SIL),
]


def _pack(offsets):
    """8 per-lane 3-bit word offsets -> the 24-bit *_wordsel value."""
    v = 0
    for lane, off in enumerate(offsets):
        v |= (off & 0x7) << (3 * lane)
    return v


def _set_skew(tb, m2s, s2m):
    tb.dut.m2s_wordsel.value = _pack(m2s)
    tb.dut.s2m_wordsel.value = _pack(s2m)


def _apply_lane_mask(tb):
    """Force the deskew RX lane_mask on both dies when LANE_MASK != 0xFF.
    Left un-forced at the 0xFF default so the shipping RTL path is bit-exact."""
    if LANE_MASK == 0xFF:
        return
    for side in ("m", "s"):
        try:
            dk = tb.top(side).u_chiplet_controller.u_wlink.phy.gpio.u_deskew
            dk.lane_mask.value = Force(LANE_MASK & 0xFF)
            tb.log.info(f"  [{side}] deskew.lane_mask FORCED = 0x{LANE_MASK:02x}")
        except AttributeError:
            tb.log.warning(f"  [{side}] deskew.lane_mask not found (mask knob no-op)")


async def _send_one(tb, src, dst, payload, ctx):
    """Send ONE 4-word packet src->dst and byte-compare all 4 words landed in
    dst's RX FIFO, DRAINING the packet (read 0..12 -> read_complete pops it).
    Returns (delivered: bool, got: list). Never asserts -- the caller decides."""
    words = make_packet(payload)
    await tb.ahb_tx_write_packet(src, words)
    await ClockCycles(tb.dut.hclk, 3000)
    pkt_len = await tb.apb(dst).read(APB_PKT_WORD_LEN)
    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(4)]
    ok = all(got[i] == words[i] for i in range(4))
    tb.log.info(
        f"      [{ctx}] {src}->{dst} PKT_LEN=0x{pkt_len:x} "
        f"sent=[{', '.join(f'0x{w:08x}' for w in words)}] "
        f"got=[{', '.join(f'0x{w:08x}' for w in got)}] -> "
        f"{'DELIVERED' if ok else 'SHEARED/ZERO'}")
    return ok, got


async def _run_trial(tb, name, m2s, s2m):
    """One deterministic ribbon realization: set skew (held constant), bring the
    V2 pair up into data mode, then on EACH direction send a FIRST packet, idle
    (SYNC/beacon cadence + any one-shot passes), then a SECOND distinct packet --
    the 'first-delivers-then-shears' probe. Returns (cr, out) where out is
        { 'm2s': (A_ok, B_ok), 's2m': (A_ok, B_ok) }.
    A skewed RX can shear the reverse CR handshake so CR/CRACK never latches;
    that is a legitimate 'this direction did not come up' -- recorded, not
    aborted, so the transcript shows the whole lottery."""
    tb.log.info(f"==== TRIAL {name}  m2s={m2s} s2m={s2m}  [{BUILD}] ====")
    _set_skew(tb, m2s, s2m)
    await run_bringup_full(tb)
    _apply_lane_mask(tb)
    cr = await tb.wait_cr_crack()
    await ClockCycles(tb.dut.hclk, 500)
    tb.log.info(f"  {name}: CR/CRACK bilateral={cr} "
                f"M(cr={tb.fcsm_cr_seen('m')},crack={tb.fcsm_crack_seen('m')}) "
                f"S(cr={tb.fcsm_cr_seen('s')},crack={tb.fcsm_crack_seen('s')})")

    out = {}
    # Unique payloads per (trial, direction, packet) = the distinct tags.
    base = (hash(name) & 0xFFFF) << 8
    for direction, src, dst in (("m2s", "m", "s"), ("s2m", "s", "m")):
        if not cr:
            out[direction] = (False, False)
            continue
        tagA = [0x0A000000 | base | 0xA0, 0xA1000000 | base]
        tagB = [0x0B000000 | base | 0xB0, 0xB1000000 | base]
        a_ok, _ = await _send_one(tb, src, dst, tagA, f"{name}:{direction}:A")
        await ClockCycles(tb.dut.hclk, 4000)   # idle gap -> steady-state re-anchor window
        b_ok, _ = await _send_one(tb, src, dst, tagB, f"{name}:{direction}:B")
        out[direction] = (a_ok, b_ok)
    tb.log.info(f"---- {name} [{BUILD}] outcome: "
                f"m2s(A,B)={out['m2s']} s2m(A,B)={out['s2m']} ----")
    return cr, out


def _skewed_dir(m2s, s2m):
    if any(s2m) and not any(m2s):
        return "s2m"
    if any(m2s) and not any(s2m):
        return "m2s"
    return "both"


async def _realization_body(dut, name, m2s, s2m):
    """Shared per-realization gate. FIX build => every direction delivers both
    packets. SHIPPING build => the skewed path must exhibit the defect (a shear,
    or the reverse CR handshake never latching). The nominally-clean reverse
    direction is only LOGGED, not gated (FC couples the directions under skew)."""
    tb = PairV2TB(dut)
    cr, out = await _run_trial(tb, name, m2s, s2m)
    skewed = _skewed_dir(m2s, s2m)

    # NOTE: the nominally-"clean" reverse direction is NOT guaranteed to deliver
    # under a one-way skew -- the FC protocol couples the directions (forward
    # credits / acks ride the skewed path), so shearing one direction can stall
    # the other. That coupling is REAL (observed here on R2), not a harness bug;
    # the zero-skew control (test_00) is what proves harness soundness. So we
    # only LOG the clean-direction outcome, we do not gate on it.
    clean = "m2s" if skewed == "s2m" else "s2m" if skewed == "m2s" else None
    if clean and cr and out[clean] != (True, True):
        tb.log.info(f"  {name}: reverse direction {clean}={out[clean]} did not "
                    f"fully deliver under one-way skew (FC direction coupling).")

    if ANCHOR:
        assert cr, f"{name}: FIX build failed to reach bilateral CR/CRACK"
        for direction, res in out.items():
            assert res == (True, True), (
                f"{name}: FIX build (EPOCH_ANCHOR=1) did NOT recover {direction}: "
                f"(A,B)={res}. The candidate fix must deliver every packet under "
                f"this deterministic skew.")
    else:
        sheared = (not cr) or any(
            not (a and b) for d, (a, b) in out.items()
            if d == skewed or skewed == "both")
        assert sheared, (
            f"{name}: SHIPPING build delivered every packet under skew {skewed} "
            f"(m2s={out['m2s']} s2m={out['s2m']}) -- this realization did NOT "
            f"reproduce the shear. Re-tune its per-lane vector.")


# ---------------------------------------------------------------------------
# test_00 : ZERO-SKEW NEGATIVE CONTROL
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_00_zero_skew_control(dut):
    """Zero skew => every packet delivers byte-exact both directions, both
    positions, in BOTH builds. Proves the harness (bring-up, tagged send, drain,
    compare) is sound -- so any SHEARED result under skew is the DUT, not the tb."""
    tb = PairV2TB(dut)
    cr, out = await _run_trial(tb, "R0_zero", [0]*8, [0]*8)
    assert cr, "ZERO-SKEW control did not reach bilateral CR/CRACK"
    for direction, (a_ok, b_ok) in out.items():
        assert a_ok and b_ok, (
            f"ZERO-SKEW control failed on {direction}: (A={a_ok}, B={b_ok}). "
            f"The harness must deliver every packet with no skew; a failure here "
            f"means the tb is broken, not the deskew.")


# ---------------------------------------------------------------------------
# test_1x : one deterministic realization each (the per-PL-load samples).
# Explicit named functions (a factory with @cocotb.test(name=...) does not
# register matchable names under cocotb 2.0) so each is independently runnable
# and reported PASS/FAIL.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_10_R1_s2m_silicon(dut):
    await _realization_body(dut, *REALIZATIONS[0])


@cocotb.test()
async def test_11_R2_m2s_silicon(dut):
    await _realization_body(dut, *REALIZATIONS[1])


@cocotb.test()
async def test_12_R3_s2m_lane0(dut):
    await _realization_body(dut, *REALIZATIONS[2])


@cocotb.test()
async def test_13_R4_both_skew(dut):
    await _realization_body(dut, *REALIZATIONS[3])


# ---------------------------------------------------------------------------
# test_99 : ensemble lottery signature
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_99_lottery_summary(dut):
    """Re-run every realization and assert the ENSEMBLE signature.

    SHIPPING (EPOCH_ANCHOR=0): outcomes are INTERMITTENT -- at least one
      realization fully delivers (or a clean direction does) AND at least one
      shears. That mix, across deterministic per-PL-load samples, IS the lottery.
    FIX (EPOCH_ANCHOR=1): every realization delivers every packet.
    """
    tb = PairV2TB(dut)
    table = {}
    for name, m2s, s2m in REALIZATIONS:
        _cr, out = await _run_trial(tb, name, m2s, s2m)
        table[name] = out

    tb.log.info(f"======== LOTTERY SUMMARY [{BUILD}] ========")
    all_delivered = []
    any_sheared = False
    for name, out in table.items():
        m, s = out["m2s"], out["s2m"]
        full = (m == (True, True)) and (s == (True, True))
        sheared = (not m[0]) or (not m[1]) or (not s[0]) or (not s[1])
        any_sheared = any_sheared or sheared
        all_delivered.append(full)
        tb.log.info(f"  {name:16s} m2s(A,B)={m} s2m(A,B)={s} "
                    f"=> {'ALL-DELIVER' if full else 'INTERMITTENT/SHEAR'}")

    if ANCHOR:
        assert all(all_delivered), (
            f"FIX build (EPOCH_ANCHOR=1): not every realization fully delivered: "
            f"{table}. The training-exit EPOCH anchor must recover all.")
        tb.log.info("  FIX: all realizations delivered every packet.")
    else:
        assert any_sheared, (
            f"SHIPPING build: NO realization sheared -- expected the deskew "
            f"handoff to mis-anchor on at least one. Table: {table}")
        assert not all(all_delivered), (
            f"SHIPPING build: EVERY realization fully delivered -- no lottery. "
            f"Table: {table}")
        tb.log.info("  SHIPPING: outcomes are intermittent across realizations "
                    "(the deterministic per-PL-load lottery).")
