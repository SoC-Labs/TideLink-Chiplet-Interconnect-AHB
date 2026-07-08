"""Silicon x5 a2l TX OVER-ADVANCE reproduction in the integrated V2 pair sim.

BUG (silicon-confirmed): die_a's TX over-advances the packet number — sending N
app words A->B pushes ~5*N FC words into the a2l replay FIFO, walking the a2l
write pointer / pktnum 5x, exhausting the fe credit ceiling (0x1f) after ~6
words and saturating the peer's expected pktnum at 0x20. B->A is unaffected.

WHY SIM NEVER REPRODUCED IT: the pair harness drives die_a's AHB-TX aperture
with the SPEC-COMPLIANT single-cycle NONSEQ writer (ahb_tx_write_word) — HTRANS
drops to IDLE after one beat, so exactly one FC word is emitted per store. The
silicon axi_ahblite_bridge instead HOLDS HTRANS=NONSEQ with HADDR/HWDATA stable
for the whole AXI transaction (~10 hclk) while HREADYOUT loops back as HREADY;
the fc_adapter's LEVEL address-phase detect then re-latches a fresh FC word
every completed data phase during the hold. That is a pure hclk-domain
(fc_adapter) phenomenon — the app<->link clock RATIO only changes how fast a2l
back-pressure clamps the multi-emit, it is NOT the cause. See
ahb_tx_write_word_held in pair_v2_common.py.

This module drives the SAME N-word A->B stream two ways and counts, at the die_a
(master) fc_adapter output, how many FC words are actually emitted (a2l
handshakes) + the a2l wptr / credit walk:

  test_spec_writer_1to1   spec single-cycle NONSEQ  -> expect M == N (1:1)
  test_held_writer_repro  silicon held-NONSEQ       -> the reproduction (M vs N)

Run:
  # in-tree (FIXED, tx_xfer_lock) RTL — clamps to 1:1 (fix validated in sim):
  make EPOCH_PROFILE=zero MODULE=test_v2_multipkt_pktnum
  # PRE-FIX RTL (963d19d^, no tx_xfer_lock) — REPRODUCES the over-advance:
  make EPOCH_PROFILE=zero MODULE=test_v2_multipkt_pktnum PREFIX_FC=1
  # + silicon 40-ns ref ratio surfaces the a2l_full / app_ready=0 TX stall:
  make EPOCH_PROFILE=zero MODULE=test_v2_multipkt_pktnum PREFIX_FC=1 \
       TIDELINK_SIM_REF_PERIOD_NS=40
Sweep knobs: TL_N_WORDS, TL_HOLD_CY, TL_GAP_CY.

MEASURED (EPOCH_PROFILE=zero, held-NONSEQ writer, hold=11):
  RTL      ref   N   M(emits)  ratio   a2l_full/app_ready
  fixed    8ns   8      8      1.00x    0 / 1     <- tx_xfer_lock clamps
  fixed    40ns  8      8      1.00x    0 / 1     <- clamps at silicon ratio too
  PRE-FIX  8ns   1     11     11.00x    0 / 1     <- ONE held store => 11 FC words
  PRE-FIX  8ns   3     17      5.67x    0 / 1     <- ~silicon 5x/word
  PRE-FIX  8ns   8     17      2.12x    0 / 1     <- saturates 16-deep a2l FIFO
  PRE-FIX  40ns  8     15      1.88x    1 / 0     <- FIFO stays FULL, TX STALLS
  (spec single-cycle writer = 1:1 in every case — this is what hid the bug.)
FINDING: the over-advance is an hclk-domain fc_adapter re-latch driven by the
HELD-NONSEQ AHB bus, NOT the clock ratio; per-store multiplier == hold length;
a burst fills the 16-deep a2l replay/credit FIFO -> app_ready=0 (the A->B cap).
The 40-ns ref only makes the credit-exhaustion downstream harm persist.
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, REF_CLK_PERIOD_NS


# Env-overridable so the held-NONSEQ hold length (== the silicon bridge's AXI
# transaction dwell) can be swept without recompiling:
#   TL_N_WORDS   app words written A->B                        (default 8)
#   TL_HOLD_CY   held-NONSEQ hold length in hclk (silicon ~10) (default 11)
#   TL_GAP_CY    inter-store IDLE gap (bridge idles between txns)(default 8)
N_WORDS   = int(os.environ.get("TL_N_WORDS", "8"))
HOLD_CY   = int(os.environ.get("TL_HOLD_CY", "11"))
GAP_CY    = int(os.environ.get("TL_GAP_CY",  "8"))


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


async def _emit_counter(tb, side, stop):
    """Count die_a fc_adapter FC-word emits (tl_fc_a2l_valid & ready) and the
    max a2l occupancy while the driver runs."""
    dut = tb.dut
    n_emit = 0
    while not stop["done"]:
        await RisingEdge(dut.hclk)
        if tb.fc_a2l_hs(side) == 1:
            n_emit += 1
    stop["n_emit"] = n_emit


async def _drive_and_measure(tb, side, held):
    """Write N_WORDS to die_a's AHB-TX aperture (walking addresses) either via
    the spec single-cycle writer or the silicon held-NONSEQ writer, counting
    FC-word emits + the a2l wptr / credit walk. Returns a metrics dict."""
    dut = tb.dut
    payload = [0xA5A50000 + i for i in range(N_WORDS)]

    wptr0 = tb.a2l_wptr(side)
    ack0  = tb.a2l_synced_ack(side)
    stop  = {"done": False, "n_emit": 0}
    ctask = cocotb.start_soon(_emit_counter(tb, side, stop))

    if held:
        await tb.ahb_tx_write_packet_held(side, payload,
                                          hold_cycles=HOLD_CY, gap=GAP_CY)
    else:
        # spec single-cycle NONSEQ, matching the proven ahb_tx_write_packet
        for i, w in enumerate(payload):
            await tb.ahb_tx_write_word(side, i * 4, w)
            await ClockCycles(dut.hclk, GAP_CY)

    # let the last emits + credit returns settle
    await ClockCycles(dut.hclk, 400)
    stop["done"] = True
    await RisingEdge(dut.hclk)

    wptr1 = tb.a2l_wptr(side)
    ack1  = tb.a2l_synced_ack(side)
    m = {
        "n_words":   N_WORDS,
        "n_emit":    stop["n_emit"],                 # FC words actually emitted
        "d_wptr":    (wptr1 - wptr0) & 0x1F,         # 5-bit wptr walk
        "wptr0":     wptr0, "wptr1": wptr1,
        "ack0":      ack0,  "ack1": ack1,
        "d_ack":     (ack1 - ack0) & 0x1F,
        "a2l_full":  tb.a2l_full(side),
        "app_ready": tb.a2l_app_ready(side),
    }
    return m


def _report(tb, tag, m):
    ratio = (m["n_emit"] / m["n_words"]) if m["n_words"] else 0.0
    tb.log.info("=" * 74)
    tb.log.info(f"  [{tag}] ref_clk={REF_CLK_PERIOD_NS}ns  A->B (die_a TX)")
    tb.log.info(f"  [{tag}] N app words written      = {m['n_words']}")
    tb.log.info(f"  [{tag}] M FC words emitted (a2l) = {m['n_emit']}   "
                f"==> EMIT/WORD = {ratio:.2f}x")
    tb.log.info(f"  [{tag}] a2l wptr walk Δ          = {m['d_wptr']} "
                f"(wptr {m['wptr0']}->{m['wptr1']})")
    tb.log.info(f"  [{tag}] a2l synced_ack walk Δ    = {m['d_ack']} "
                f"(ack {m['ack0']}->{m['ack1']})")
    tb.log.info(f"  [{tag}] a2l_full={m['a2l_full']}  app_ready={m['app_ready']}")
    verdict = "OVER-ADVANCE" if m["n_emit"] > m["n_words"] else "1:1 (clean)"
    tb.log.info(f"  [{tag}] >>> VERDICT: {verdict}")
    tb.log.info("=" * 74)


@cocotb.test()
async def test_spec_writer_1to1(dut):
    """Baseline: spec single-cycle NONSEQ writer. Must emit 1 FC word / store."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    m = await _drive_and_measure(tb, "m", held=False)
    _report(tb, "SPEC", m)
    assert m["n_emit"] == m["n_words"], \
        f"spec writer emitted {m['n_emit']} FC words for {m['n_words']} stores"


@cocotb.test()
async def test_held_writer_repro(dut):
    """Silicon held-NONSEQ writer. Reports the emit/word multiplier — this is
    the reproduction (or a clean 1:1 if the in-tree tx_xfer_lock fix suppresses
    it, which is itself the finding)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    m = await _drive_and_measure(tb, "m", held=True)
    _report(tb, "HELD", m)
    # Report-only: do NOT fail the run — the number is the deliverable.
    tb.log.info(f"HELD-NONSEQ emit/word = {m['n_emit'] / m['n_words']:.2f}x "
                f"(silicon signature ~5x)")
