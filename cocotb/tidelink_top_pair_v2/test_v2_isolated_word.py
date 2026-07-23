# =============================================================================
# ISOLATED-WORD delivery test (SoC Labs 2026-07-03).
#
# SILICON FINDING under test: with the tl39 store-path bug fixed (one genuine
# u32 store per word), an ISOLATED A->B data packet on an otherwise-idle link
# NEVER decodes at die_b (exp_pkt_num frozen, no mismatch, no NACK, RX RAM
# empty) — on BOTH the e45e0da0/a54641b0 and a6443cd7/cd424624 builds, under
# every 0x2100 config (0x1C / 0x14 / 0x10), link healthy (fcsm=4 bilateral).
# Everything that ever delivered was embedded in link-rate back-to-back
# traffic (bootstrap CR/CRACK window, HW NACK-replay storms, b2b sim writes).
# PS-rate writes are ~146 idle link-words apart, so every clean silicon
# packet is idle-followed.
#
# THEORY: at the reduced 4-lane mask a short packet spans >1 link transfer
# unit; the RX framer only closes packet assembly when ANOTHER LL word butts
# up behind it — idle-fill aborts the partial. (V1's proven single-word
# deliveries were 8-lane: packet fits one unit.)
#
# THIS TEST: same rig as test_v2_multipkt_pktnum but ONE word, then a LONG
# idle (>> 2 link words), then the oracle. If it FAILS, the silicon bug is
# reproduced in sim and can be waveform-debugged; if it PASSES, the loss is
# silicon-only (deskew/analog-adjacent) despite identical RTL.
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full

APB_FCSMCAP = 0x21A8


async def _fcsm_exp(tb, side):
    v = await tb.apb(side).read(APB_FCSMCAP)
    return v & 0xFF, (v >> 21) & 1  # (last_exp, mismatch_ever)


@cocotb.test()
async def test_a2b_isolated_word(dut):
    """ONE m->s word on an idle link must deliver: exp +1, no mismatch."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    exp0, mism0 = await _fcsm_exp(tb, "s")
    tb.log.info(f"[isolated] pre : exp=0x{exp0:02x} mism={mism0}")

    # ONE word, then nothing — the link goes idle behind it.
    await tb.ahb_tx_write_word("m", 0x0, 0xCAFE0001)

    # Long idle: >> the 2-link-word assembly window. One link word = 16 ref
    # cycles; at the default sim ratio that is 6.4 hclk. 4000 hclk ~ 600 link
    # words of idle — far beyond any pipeline flush.
    await ClockCycles(dut.hclk, 4000)

    exp1, mism1 = await _fcsm_exp(tb, "s")
    tb.log.info(f"[isolated] post: exp=0x{exp1:02x} mism={mism1} "
                f"(want exp +1, mism 0)")

    assert mism1 == 0, "isolated word produced a pktnum mismatch"
    assert exp1 == ((exp0 + 1) & 0xFF), (
        f"ISOLATED WORD LOST: exp 0x{exp0:02x} -> 0x{exp1:02x} "
        f"(silicon isolated-packet delivery gap REPRODUCED in sim)")


@cocotb.test()
async def test_a2b_two_isolated_words(dut):
    """Two words with a long idle gap between them (PS-rate shape)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    exp0, _ = await _fcsm_exp(tb, "s")
    await tb.ahb_tx_write_word("m", 0x0, 0xCAFE00A1)
    await ClockCycles(dut.hclk, 4000)
    expa, misma = await _fcsm_exp(tb, "s")
    await tb.ahb_tx_write_word("m", 0x4, 0xCAFE00A2)
    await ClockCycles(dut.hclk, 4000)
    expb, mismb = await _fcsm_exp(tb, "s")
    tb.log.info(f"[2xisolated] exp 0x{exp0:02x} -> 0x{expa:02x} -> 0x{expb:02x} "
                f"mism={misma},{mismb}")
    assert mismb == 0 and expb == ((exp0 + 2) & 0xFF), (
        f"isolated-gap words lost: exp 0x{exp0:02x}->0x{expb:02x}, mism={mismb}")
