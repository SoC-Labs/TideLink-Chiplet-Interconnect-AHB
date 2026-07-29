"""c3 — MANDATORY negative control for the hardware credit gate.

Built with +define+TXGEN_FORCE_CREDIT_GATE_DIS, which forces the generator's
CREDIT_GATE_DIS=1. This is the ARM that makes every other credit result mean
something: without it, a green "no overrun" test could simply mean the generator
never sent enough to overrun.

The claim proven here is the direct complement of test_c1_zero_credit_never_starts
(gate ON, zero credit => generator NEVER sends): with the gate compiled OUT and
zero peer credit, the generator DOES send. On silicon the peer RX FIFO has no
write-side backpressure (fc_wr_ready tied 1), so those zero-credit writes are
exactly the ones that would be silently dropped / overrun the peer. Proving the
generator emits them here proves the gate is the only thing standing between a
line-rate generator and silent data loss.

A full end-to-end variant (arm FOREVER, never drain, assert the PEER's overrun
sticky sets) needs ~MAX_CREDITS=4096 words to cross the link to overflow the
real RX FIFO — a very long sim at RAM_ADDR_W=14. That belongs in a reduced-FIFO
build; this unit-level control proves the load-bearing fact deterministically.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_txgen_unit import (
    reset, wr, rd, R_CTRL, R_PKT, R_GAP, R_STATUS, R_WORDS,
    CTRL_EN, CTRL_START, CTRL_FOREVER, ST_GATE_ACTIVE,
)


@cocotb.test()
async def test_c3_gate_disabled_sends_into_zero_credit(dut):
    """Gate compiled OUT + zero peer credit => the generator STILL sends.

    If this build somehow still had the gate, STATUS[6] would read 1 and the
    generator would stall — so assert the gate is genuinely out first, then that
    it sends anyway.
    """
    await reset(dut, credit=0)

    st = await rd(dut, R_STATUS)
    assert (st & ST_GATE_ACTIVE) == 0, (
        "CREDIT_GATE_ACTIVE is still set — this build did NOT compile with "
        "TXGEN_FORCE_CREDIT_GATE_DIS, so it is not a valid negative control"
    )

    await wr(dut, R_PKT, 4)
    await wr(dut, R_GAP, 0)
    await wr(dut, R_CTRL, CTRL_EN | CTRL_FOREVER)
    await wr(dut, R_CTRL, CTRL_EN | CTRL_FOREVER | CTRL_START)

    sent = False
    for _ in range(300):
        await RisingEdge(dut.hclk)
        if dut.gen_owns.value == 1:
            sent = True
            break

    assert sent, (
        "generator did NOT send with the gate disabled and zero credit — the "
        "negative control failed to reproduce the unsafe behaviour, so the "
        "positive credit-gate results prove nothing"
    )
    await ClockCycles(dut.hclk, 200)
    words = int(await rd(dut, R_WORDS))
    assert words > 0, "no words emitted with the gate disabled"
    dut._log.info(f"[c3] gate disabled: generator sent {words} words into zero "
                  f"credit — the gate is load-bearing")
