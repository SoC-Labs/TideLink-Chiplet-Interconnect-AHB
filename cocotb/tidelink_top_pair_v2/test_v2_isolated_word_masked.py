# =============================================================================
# ISOLATED-WORD delivery test under the SILICON 4-LANE MASK (0xe4e4).
#
# test_v2_isolated_word PASSES at the sim default (8 lanes, default ratio),
# so the silicon isolated-packet loss is NOT reproduced there. But silicon
# runs lane mask 0xe4e4 (4 active lanes: 2,5,6,7) — and at 4 lanes a short
# packet spans MORE link transfer units than at 8, which is exactly the
# regime of the assembly-abort theory. run_bringup_full never sets a mask
# (sim = all 8 lanes), so this file mirrors the silicon recipe's mask writes
# (0x0214=0xe4e4 pre-role-lock + re-write after cal, SYNCTOL 0x2128=0x5e4).
#
# Matrix: run this at the default clock ratio AND with
# TIDELINK_SIM_REF_PERIOD_NS=40.0 (silicon ratio) for the full silicon match.
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB

APB_FCSMCAP  = 0x21A8
APB_LANEMASK = 0x0214
APB_SYNCTOL  = 0x2128


async def _fcsm_exp(tb, side):
    v = await tb.apb(side).read(APB_FCSMCAP)
    return v & 0xFF, (v >> 21) & 1


async def _bringup_masked(tb):
    """run_bringup_full with the silicon 0xe4e4 lane-mask recipe folded in."""
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    for side in ("m", "s"):
        await tb.apb(side).write(APB_LANEMASK, 0x0000E4E4)
        await tb.apb(side).write(APB_SYNCTOL, 0x000005E4)
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert"
    await tb.wait_cal_done()
    for side in ("m", "s"):
        await tb.apb(side).write(APB_LANEMASK, 0x0000E4E4)
    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 5000)


@cocotb.test()
async def test_a2b_isolated_word_masked(dut):
    """ONE m->s word on an idle 4-lane (0xe4e4) link must deliver."""
    tb = PairV2TB(dut)
    await _bringup_masked(tb)
    assert await tb.wait_cr_crack(), "masked link did not reach CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    exp0, mism0 = await _fcsm_exp(tb, "s")
    tb.log.info(f"[iso-masked] pre : exp=0x{exp0:02x} mism={mism0}")

    await tb.ahb_tx_write_word("m", 0x0, 0xCAFE0001)
    await ClockCycles(dut.hclk, 4000)

    exp1, mism1 = await _fcsm_exp(tb, "s")
    tb.log.info(f"[iso-masked] post: exp=0x{exp1:02x} mism={mism1}")
    assert mism1 == 0, "isolated word produced a pktnum mismatch (masked)"
    assert exp1 == ((exp0 + 1) & 0xFF), (
        f"ISOLATED WORD LOST at 4-lane mask: exp 0x{exp0:02x} -> 0x{exp1:02x} "
        f"(silicon delivery gap REPRODUCED in sim)")


@cocotb.test()
async def test_a2b_b2b_words_masked(dut):
    """Control: 4 back-to-back words on the masked link (the shape that
    delivers on silicon via storms) — must also deliver in sim."""
    tb = PairV2TB(dut)
    await _bringup_masked(tb)
    assert await tb.wait_cr_crack(), "masked link did not reach CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    exp0, _ = await _fcsm_exp(tb, "s")
    await tb.ahb_tx_write_packet_b2b("m", [0xB2B00001, 0xB2B00002,
                                           0xB2B00003, 0xB2B00004])
    await ClockCycles(dut.hclk, 6000)
    exp1, mism1 = await _fcsm_exp(tb, "s")
    tb.log.info(f"[b2b-masked] exp 0x{exp0:02x} -> 0x{exp1:02x} mism={mism1}")
    assert mism1 == 0 and exp1 == ((exp0 + 4) & 0xFF), (
        f"b2b words lost on masked link: exp 0x{exp0:02x}->0x{exp1:02x}")
