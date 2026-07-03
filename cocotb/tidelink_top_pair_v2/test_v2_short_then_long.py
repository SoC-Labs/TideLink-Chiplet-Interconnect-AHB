# =============================================================================
# SHORT-then-LONG boundary repro attempt (SoC Labs 2026-07-03 late).
#
# SILICON DISCRIMINATOR RESULT (v2disc3, RXCAP instrumented, SYNC OFF):
# an isolated A->B data long (wc=7 -> 2 link words at the 4-lane mask) dies
# INSIDE die_b's RX framer between long-header decode and body entry:
# long_ever 0->1, max_byte_count 0->8 (exactly ONE link word consumed),
# long_start_cnt stays 0, no err, no eop, exp frozen. die_a emits cleanly.
#
# On silicon an isolated data long is ALWAYS preceded by a SHORT (the bFC
# ACK/CR keepalives stream constantly); in sim there is NO bFC traffic, so
# sim's isolated longs are preceded by idle — and they deliver. Both RTL
# audits flagged the framer's short->long boundary handling
# (is_short_pkt_prev, WlinkRxLinkLayer.v ~:261/:453 vs :771) as divergent.
#
# THIS TEST: emit a ch7 SHORT (doorbell) immediately before the isolated
# data long, sweeping the spacing, to reproduce the silicon loss in sim.
# A FAIL here = the silicon bug captured in a waveform-debuggable sim.
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (PairV2TB, run_bringup_full, APB_TIDELINK_BASE,
                            OFF_DOORBELL)

APB_FCSMCAP  = 0x21A8
APB_DOORBELL = APB_TIDELINK_BASE + OFF_DOORBELL


async def _fcsm_exp(tb, side):
    v = await tb.apb(side).read(APB_FCSMCAP)
    return v & 0xFF, (v >> 21) & 1


@cocotb.test()
async def test_short_then_isolated_long(dut):
    """Doorbell SHORT then one data LONG at several spacings: every long must
    deliver (exp +1 each). Loss at any spacing = silicon framer bug repro."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    exp0, _ = await _fcsm_exp(tb, "s")
    lost = []
    sent = 0
    # spacing sweep in hclk between the short and the long (at default ratio
    # one link word = 6.4 hclk; at TIDELINK_SIM_REF_PERIOD_NS=40 it is 32)
    for gap in (0, 2, 4, 8, 16, 32, 64):
        await tb.apb("m").write(APB_DOORBELL, 0x1)   # ch7 short onto the wire
        if gap:
            await ClockCycles(dut.hclk, gap)
        await tb.ahb_tx_write_word("m", (sent % 8) * 4, 0x51A70000 + sent)
        sent += 1
        await ClockCycles(dut.hclk, 4000)            # long idle after
        exp1, mism = await _fcsm_exp(tb, "s")
        got = (exp1 - exp0) & 0xFF
        # NOTE (2026-07-03): the tidelink doorbell is NOT a ch7 short — it
        # rides the SAME tl FC data channel and advances the same exp counter
        # (measured: exp_delta = 2x sent, both packets deliver). So this test
        # actually exercises the zero-gap LONG->LONG boundary, which must be
        # lossless. Expected delivery = 2 per iteration (doorbell + data).
        tb.log.info(f"[s->l gap={gap:3d}] sent={sent} exp_delta={got} mism={mism}")
        if got != 2 * sent:
            lost.append((gap, sent, got))
    expf, mismf = await _fcsm_exp(tb, "s")
    tb.log.info(f"[s->l] final: sent={sent} delivered={(expf-exp0)&0xFF} "
                f"mism={mismf} lost={lost}")
    assert not lost, (
        f"doorbell+data pair loss at gaps {lost} "
        f"(zero-gap long->long boundary must be lossless)")
