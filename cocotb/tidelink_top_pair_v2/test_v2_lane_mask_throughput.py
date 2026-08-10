"""LANE-MASK SUSTAINED-THROUGHPUT A/B — shipped 4-lane default vs all 8 lanes.

BACKGROUND
----------
The shipped FPGA build POR-defaults the Wlink lane mask to 0xE4 (K=4 active
lanes, `LANE_MASK_RESET` at src/rtl/local_overrides/Wlink.v:2511-2515) — a
leftover from a "4 dead lanes" belief that has since been fully refuted (all
8 lanes conduct fine on silicon; the original defect was a bring-up-recipe
bug, not electrical). `bytesPerCycle = popcount(lane_mask) * 2`, so this is a
flat 2x difference in raw per-cycle link bandwidth (8 vs 16 bytes) if all 8
lanes are used instead of 4.

Bring-up (link-up) at 8 lanes is already proven (test_v2_lane_mask_sweep.py
covers K up to 8 and every popcount in between). What has NEVER been
measured, in sim or on hardware, is whether SUSTAINED DATA THROUGHPUT
actually scales ~2x with the lane count, or whether some OTHER bottleneck
(AHB per-word overhead, or the Wlink FC a2l replay-window / ACK-return RTT
documented in project_txgen_sim_throughput_measured_2026_07_31) dominates and
swamps the wire-bandwidth difference. This suite answers that empirically —
it does NOT assume the answer is 2x.

METHOD
------
Reuses, unmodified, the two pieces of already-proven harness in this
directory rather than inventing new mechanism:
  * `bringup_reduced` / `force_lane_mask` / `read_mask_state` from
    test_v2_reduced_lane.py — the continuous-Force lane-mask technique
    (Force, not deposit, on `u_wlink.swi_tx_lane_mask` /
    `out_prepend_swi_rx_lane_mask` on BOTH dies, re-asserted after the async
    reset re-init to 8'hFF, plus a best-effort mirroring APB write to 0x0214)
    already used and validated by test_v2_lane_mask_sweep.py /
    test_v2_lane_mask_negctl.py for every popcount 1..8, not just 4 and 8.
  * The on-chip PERF_CTRL / SAMPLE_COUNT / TX_WORD_COUNT counters
    (region 5/6/7 inside the tidelink APB block), proven end-to-end through
    the real V2-pair APB path by test_v2_perf_ctrl.py. `TX_WORD_COUNT`
    increments on `fc_tx_handshake && fc_tx_is_data`
    (`tidelink_top.sv:2159-2161`, `tl_fc_a2l_valid & tl_fc_a2l_ready` —
    the FC-adapter -> a2l handoff, i.e. words actually admitted onto the
    LINK side, not merely accepted on the AHB bus). `SAMPLE_COUNT` free-runs
    every hclk while perf is enabled. Bracketing both immediately before the
    first AHB word write and immediately after `TX_WORD_COUNT` reaches the
    expected total gives sustained hclk-cycles/word for exactly the
    admission span, without diluting the number with pre/post-burst idle
    cycles.

Deliberately does NOT use TXGEN (see test_v2_txgen.py / the TXGEN throughput
sibling suite elsewhere in this project) — this suite measures the RAW link
path (plain AHB-TX aperture writes, gap=0, back-to-back, the same mechanism
already proven byte-exact for multi-packet bursts by
test_v2_pair_sustained.py's test_12/13/14) so the lane-mask A/B is isolated
from TXGEN's own separate software credit-gate bookkeeping.

PKT_LEN=124 (126 words/packet) x NPKT=8 (1008 words total) is sized well
past the ~17-word skid+FIFO admission elasticity and the 16-word a2l replay
window (see project_fc_adapter_pipelining_analysis_2026_07_30 /
project_txgen_sim_throughput_measured_2026_07_31) so the measured rate
reflects the STEADY-STATE sustained rate, not burst-absorption into an
elastic buffer, while staying comfortably under the peer's 4096-word RX
capacity (no drain needed mid-run).

THE REF-CLOCK TRAP (same one test_v2_txgen_throughput.py documents — read
before trusting a number out of this file): pair_v2_common's default
TIDELINK_SIM_REF_PERIOD_NS=8.0 is deliberately FASTER than any real silicon
ratio, chosen so unrelated suites in this directory stay fast/stable. Under
that default the raw wire-bandwidth ceiling (well under 1 hclk/word even at
K=4) is far below the fixed per-word AHB/protocol overhead, so the link is
NOT the bottleneck and this suite's ratio legitimately reads ~1x — that is a
correct negative-control result, not a bug. To let the lane-count difference
actually show up, run with a realistic silicon ratio (1 UI == 2 hclk periods
matches the PYNQ-Z2 target, `fpga/targets/pynq-z2-pair-all/tidelink_design.
tcl:236-266`; the KR260-pair-onchip target's real ratio is 8:1, i.e. 160.0):

    TIDELINK_SIM_REF_PERIOD_NS=40.0 make EPOCH_PROFILE=zero \\
        MODULE=test_v2_lane_mask_throughput SIM_BUILD=sim_build_lanethru

Every result line logs the REF_CLK_PERIOD_NS it actually ran under so a
number is self-documenting even without the override.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, make_packet, read_packet_drain, diff_words,
    CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
)
from test_v2_reduced_lane import bringup_reduced, read_mask_state

# ---------------------------------------------------------------------------
# Perf register map (mirrors test_v2_perf_ctrl.py / the TXGEN throughput
# sibling — each cocotb dir/file is its own PYTHONPATH root by repo
# convention, constants are deliberately re-declared rather than shared).
# ---------------------------------------------------------------------------
PERF_CTRL     = 0x20A0   # region 5 word 0
PERF_TX_WORDS = 0x20D0   # region 6 word 4  (tx_word_count_r)
PERF_SAMPLES  = 0x20E8   # region 7 word 2  (sample_count_r, free-running)
PERF_EN       = 0x1

MASK_4LANE = 0xE4   # shipped default (Wlink.v LANE_MASK_RESET); lanes
                     # {2,5,6,7} active, K=4, bytesPerCycle=8
MASK_8LANE = 0xFF   # all 8 lanes active, K=8, bytesPerCycle=16

PKT_LEN    = 124                 # payload words/packet -> 126 words/packet
NPKT       = 8                   # 8 * 126 = 1008 words total per config
PER_PACKET = PKT_LEN + 2

# Hard bounds, not silent papering (see AHB_BP_MAX_CYCLES in pair_v2_common
# for the same discipline: a stall here is a REAL result, never absorbed).
DRAIN_POLL_MAX_CYCLES = 2_000_000
DRAIN_SETTLE_CYCLES   = 5000


def payload_for(n, seed):
    """Distinct, position-encoding payload so a shift/corruption cannot
    alias onto a neighbouring word (matches test_v2_pair_sustained.py)."""
    return [(seed << 16) | i for i in range(n)]


async def _measure_one_mask(tb, mask, label):
    """Force `mask` on both dies, bring the link up on it, send NPKT
    back-to-back PKT_LEN-word packets over the plain AHB-TX aperture, and
    bracket PERF_CTRL SAMPLE_COUNT/TX_WORD_COUNT around exactly that
    admission span. Byte-checks every word landed before trusting the
    number. Returns a result dict."""
    K = bin(mask).count("1")
    tb.log.info("=" * 70)
    tb.log.info(f"  [{label}] mask=0x{mask:02X} K={K} bytesPerCycle={2 * K}")
    tb.log.info("=" * 70)

    await bringup_reduced(tb, mask=mask)
    assert await tb.wait_cr_crack(), \
        f"{label}: link did not reach bilateral CR/CRACK at mask 0x{mask:02X}"
    await ClockCycles(tb.dut.hclk, 500)

    # Instrument check: the mask must have actually reached the datapath +
    # deskew before a throughput number measured under it means anything
    # (same discipline as test_v2_reduced_lane.py test_01).
    for side, name in (("m", "M"), ("s", "S")):
        tx, rx, cal, dsk = read_mask_state(tb, side)
        tb.log.info(f"  [{label}] {name}: swi_tx=0x{tx:02x} swi_rx=0x{rx:02x} "
                    f"calibrator=0x{cal:02x} deskew=0x{dsk:02x}")
        assert tx == mask and rx == mask and dsk == mask, (
            f"{label} {name}: lane mask did not hold through bring-up "
            f"(swi_tx=0x{tx:02x} swi_rx=0x{rx:02x} deskew=0x{dsk:02x}, want "
            f"0x{mask:02x}) — INSTRUMENT FAULT, the throughput number below "
            f"would not be measuring what it claims to")

    m = tb.apb("m")
    await m.write(PERF_CTRL, PERF_EN)
    await ClockCycles(tb.dut.hclk, 5)

    sent_packets = [make_packet(payload_for(PKT_LEN, 0xA000 + p))
                    for p in range(NPKT)]
    expected_total = PER_PACKET * NPKT

    samp0 = await m.read(PERF_SAMPLES)
    txw0  = await m.read(PERF_TX_WORDS)

    for words in sent_packets:
        await tb.ahb_tx_write_packet("m", words, gap=0)

    for _ in range(DRAIN_POLL_MAX_CYCLES // 50):
        await ClockCycles(tb.dut.hclk, 50)
        txw_now = await m.read(PERF_TX_WORDS)
        if txw_now - txw0 >= expected_total:
            break
    else:
        raise TimeoutError(
            f"{label}: TX_WORD_COUNT never reached {expected_total} admitted "
            f"words within {DRAIN_POLL_MAX_CYCLES} hclk — the link is not "
            f"draining at mask 0x{mask:02X}; this is a real stall, not a "
            f"harness limit")

    samp1 = await m.read(PERF_SAMPLES)
    txw1  = await m.read(PERF_TX_WORDS)
    elapsed = samp1 - samp0
    words   = txw1 - txw0
    cpw = elapsed / words if words else float("inf")

    tb.log.info(f"  [{label}] elapsed={elapsed} hclk over {words} admitted "
                f"words -> {cpw:.3f} hclk/word "
                f"(REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} "
                f"CLK_PERIOD_NS={CLK_PERIOD_NS})")

    # Settle the propagation tail (the a2l pipeline can still be draining a
    # few words after TX_WORD_COUNT/admission completes — this happens
    # AFTER the elapsed-cycle measurement above, so it cannot skew cy/word),
    # then byte-check every packet landed correctly. A throughput number
    # from a run that silently corrupted data is worthless.
    await ClockCycles(tb.dut.hclk, DRAIN_SETTLE_CYCLES)
    mism_total = 0
    for p, words_sent in enumerate(sent_packets):
        got = await read_packet_drain(tb, "s", len(words_sent))
        mism = diff_words(words_sent, got)
        if mism:
            mism_total += len(mism)
            tb.log.error(f"  [{label}] packet {p}: {len(mism)} mismatches, "
                        f"first {mism[0]}")
    assert mism_total == 0, (
        f"{label}: {mism_total} word mismatches across {NPKT} packets at "
        f"mask 0x{mask:02X} — NOT byte-exact at the sustained rate; the "
        f"cycles/word number above is not trustworthy")

    return {"label": label, "mask": mask, "K": K,
            "elapsed": elapsed, "words": words, "cpw": cpw}


@cocotb.test()
async def test_01_sustained_throughput_4lane_vs_8lane(dut):
    """Headline A/B: identical packet size/count, lane mask forced to the
    shipped 4-lane default (0xE4) vs all 8 lanes (0xFF), cycles/word
    measured via the on-chip PERF_CTRL counters. Reports the ACTUAL ratio —
    see module docstring for why it is not assumed to be 2x, and why the
    ref-clock ratio the suite is invoked under matters."""
    tb = PairV2TB(dut)

    r4 = await _measure_one_mask(tb, MASK_4LANE, "4-lane(0xE4)")
    r8 = await _measure_one_mask(tb, MASK_8LANE, "8-lane(0xFF)")

    ratio = r4["cpw"] / r8["cpw"] if r8["cpw"] else float("inf")
    tb.log.info("=" * 70)
    tb.log.info("  SUSTAINED THROUGHPUT A/B RESULT")
    tb.log.info(f"    4-lane (0xE4, K=4): {r4['cpw']:.3f} hclk/word  "
                f"({r4['words']} words / {r4['elapsed']} hclk)")
    tb.log.info(f"    8-lane (0xFF, K=8): {r8['cpw']:.3f} hclk/word  "
                f"({r8['words']} words / {r8['elapsed']} hclk)")
    tb.log.info(f"    ratio (4-lane cpw / 8-lane cpw) = {ratio:.3f}x  "
                f"(naive lane-count-doubling hypothesis predicts 2.0x; "
                f"REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} — see module "
                f"docstring, this must be a realistic silicon ratio, e.g. "
                f"40.0, for the link to actually be the bottleneck)")
    tb.log.info("=" * 70)

    assert r8["cpw"] <= r4["cpw"], (
        f"8 lanes measured SLOWER than 4 lanes ({r8['cpw']:.3f} vs "
        f"{r4['cpw']:.3f} hclk/word) at otherwise-identical stimulus — more "
        f"wire bandwidth made throughput worse, which is not physically "
        f"sensible and most likely means the mask did not actually reach "
        f"the datapath for one of the two runs (INSTRUMENT FAULT, not a "
        f"real regression)")
