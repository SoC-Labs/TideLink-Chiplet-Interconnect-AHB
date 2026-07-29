"""Pair-level proof that the v1 TX generator delivers through the FULL stack.

Unit tests (cocotb/tidelink_txgen) prove the generator drives the fc_adapter
correctly in isolation. This suite proves the OTHER half: that a generator armed
via APB Region E in a brought-up V2 pair actually lands byte-exact packets in the
PEER's RX FIFO — i.e. the Region-E decode reaches through the real APB mux, the
mux into the fc_adapter is live, and the emitted header is one the peer stores.

Covers docs/TXGEN_V1_DESIGN.md §4:
  b2/b3  saturated, byte-exact delivery (the headline)
  c2     never overruns the peer under a bounded credit budget

The mandatory negative control c3 (peer DOES overrun with the gate compiled
OUT) needs a TXGEN_CREDIT_GATE_DIS=1 build and lives in its own suite.

Region E (paddr[8:5]=1110): SoC 0x21C0..0x21DC.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_TIDELINK_BASE, APB_PKT_WORD_LEN,
)

TXGEN_CTRL   = 0x21C0
TXGEN_PKT    = 0x21C4
TXGEN_GAP    = 0x21C8
TXGEN_BUDGET = 0x21CC
TXGEN_STATUS = 0x21D0
TXGEN_WORDS  = 0x21D4
TXGEN_STALL  = 0x21D8
TXGEN_ID     = 0x21DC

CTRL_EN      = 1 << 0
CTRL_START   = 1 << 1
CTRL_STOP    = 1 << 2
CTRL_FOREVER = 1 << 3

ST_RUNNING      = 1 << 0
ST_STALL_CREDIT = 1 << 2
ST_ERR_AHB      = 1 << 4
ST_GATE_ACTIVE  = 1 << 6

TXGEN_ID_VAL = 0x5447_0100

# Released-Credits accumulator: a write here bumps PAIR_CREDIT_COUNTER (0x2028),
# the master's view of the peer's free credit — the same seed the char flow does.
APB_RELEASED_ACC = APB_TIDELINK_BASE + 0x020

# STATUS[1] overrun on the RX FIFO side (Region 0 slot 4, 0x2010).
APB_STATUS   = APB_TIDELINK_BASE + 0x010
ST_OVERRUN   = 1 << 1


def expected_payload(seq, beat):
    """The generator emits {seq[15:0], beat[15:0]} for payload beats."""
    return ((seq & 0xFFFF) << 16) | (beat & 0xFFFF)


@cocotb.test()
async def test_txgen_reachable(dut):
    """Region E decodes through the full pair APB path.

    The riskiest integration point: a shim decoded in tidelink_top, folded into
    the prdata mux. If the ID does not read back, nothing else in this file can.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    m = tb.apb("m")
    idv = await m.read(TXGEN_ID)
    assert idv == TXGEN_ID_VAL, \
        f"TXGEN_ID = 0x{idv:08x} via the full pair APB path, expected 0x{TXGEN_ID_VAL:08x}"
    st = await m.read(TXGEN_STATUS)
    assert st & ST_GATE_ACTIVE, "credit gate not compiled in on the pair build"
    assert (st & ST_RUNNING) == 0, "generator RUNNING at POR — not fail-closed"


@cocotb.test()
async def test_txgen_delivers_byte_exact(dut):
    """b2/b3: armed generator lands byte-exact packets in the peer RX FIFO."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")
    n = 4                       # 4 payload + 2 header = 6 words/packet
    per_packet = n + 2

    # Seed pair credit so the master's gate lets it run (peer RX is empty).
    # A write to the released-credits acc bumps PAIR_CREDIT_COUNTER — the same
    # seed the char flow does before any credit-gated send.
    await m.write(APB_RELEASED_ACC, per_packet * 8)

    await m.write(TXGEN_PKT, n)          # DEST_OFF = 0
    await m.write(TXGEN_GAP, 0)
    await m.write(TXGEN_BUDGET, per_packet)   # exactly ONE packet
    await m.write(TXGEN_CTRL, CTRL_EN)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_START)

    # Let one packet cross.
    await ClockCycles(dut.hclk, 4000)

    words_sent = await m.read(TXGEN_WORDS)
    assert words_sent == per_packet, \
        f"generator emitted {words_sent} words, expected exactly {per_packet}"

    # Drain the slave and byte-check. Packet seq 0 => payload beats 2..5 carry
    # {0, beat}.
    got = [await tb.ahb_fifo_read_word("s", i * 4) for i in range(per_packet)]
    exp_hdr = (n << 20) | (0x1 << 18)     # WR_REQ, length n
    assert got[0] == exp_hdr, \
        f"header mismatch: got 0x{got[0]:08x}, expected 0x{exp_hdr:08x}"
    for b in range(2, per_packet):
        want = expected_payload(0, b)
        assert got[b] == want, (
            f"payload beat {b}: got 0x{got[b]:08x}, expected 0x{want:08x} "
            f"({{seq,beat}} pattern) — generator data corrupted in transit"
        )
    tb.log.info(f"[txgen] delivered byte-exact: {[hex(w) for w in got]}")


@cocotb.test()
async def test_txgen_never_overruns(dut):
    """c2: FOREVER run against a bounded, undrained peer never overruns.

    The peer RX write side has no backpressure, so the only thing preventing
    silent data loss is the generator's hardware credit gate. Arm FOREVER with
    a small seeded budget, never drain the slave, and assert the peer's overrun
    sticky stays clear while the generator parks in STALL_CREDIT.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")
    s = tb.apb("s")
    n = 4
    per_packet = n + 2
    budget_packets = 3
    await m.write(APB_RELEASED_ACC, per_packet * budget_packets)

    await m.write(TXGEN_PKT, n)
    await m.write(TXGEN_GAP, 0)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_FOREVER)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_FOREVER | CTRL_START)

    # Run well past the point the seeded credit is exhausted; never drain.
    await ClockCycles(dut.hclk, 8000)

    st_slave = await s.read(APB_STATUS)
    assert (st_slave & ST_OVERRUN) == 0, (
        f"peer RX FIFO OVERRAN (STATUS=0x{st_slave:08x}) — the credit gate did "
        f"not hold the generator back; data was silently dropped"
    )
    gen_st = await m.read(TXGEN_STATUS)
    assert gen_st & ST_STALL_CREDIT, (
        f"generator not in STALL_CREDIT (STATUS=0x{gen_st:08x}) after exhausting "
        f"a {budget_packets}-packet budget — it is not gating on credit"
    )
    words = await m.read(TXGEN_WORDS)
    assert words <= per_packet * budget_packets, (
        f"generator sent {words} words but only {per_packet * budget_packets} "
        f"credits were seeded"
    )
    tb.log.info(f"[txgen] gated cleanly: sent {words} words, peer no overrun")
