"""Q-A: is the sustained multi-packet wedge the A->B-ONLY no-ACK replay
accumulation, or an FC logic defect?

Hypothesis (coordinator): on silicon we test A->B only; die_b never returns
B->A ACKs (credmax=0 risk), so die_a's a2l replay buffer is never acked, never
drains, and re-sends the accumulated buffer -> die_b's exp ratchets through the
buffered pktnums to credit_max(0x1f) -> wedge.

Two runs on the CLEAN zero-skew link (same 16-word back-to-back burst as
test_v2_multipkt_pktnum):
  (1) ACK ENABLED  (true bilateral): expect replay DRAINS, 16 delivered
                   exactly-once, exp advances once per app word, NO ratchet.
  (2) ACK BLOCKED  (model A->B only): FORCE the receiver's send_ack_req=0 so it
                   never emits an ACK packet -> the sender's replay buffer is
                   never acked. Observe whether the sender's replay read-pointer
                   re-walks / the receiver's exp ratchets toward credit_max.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_ackdrain_qa TESTCASE=test_qa_ack_enabled
  make EPOCH_PROFILE=zero MODULE=test_v2_ackdrain_qa TESTCASE=test_qa_ack_blocked
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

N_WORDS = 16


def fcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _i(s):
    try:
        return int(s.value)
    except Exception:
        return -1


async def _hold_ack_low(tb, dst):
    """Force the receiver (dst) FCSM send_ack_req=0 for the whole run, modelling
    a die that never returns ACKs to the sender."""
    rx = fcsm(tb, dst)
    sig = getattr(rx, "send_ack_req", None)
    if sig is None:
        tb.log.warning("send_ack_req not found; cannot block ACKs")
        return
    while True:
        sig.value = Force(0)
        await RisingEdge(tb.dut.hclk)


async def _watch(tb, src, dst, cycles):
    """Watch the sender's replay read-pointer (a2l_fc_replay_link_cur_addr) and
    revert pulses, plus the receiver's exp_pkt_num, for `cycles` rxclk cycles."""
    txr = fcsm(tb, src)
    rxr = fcsm(tb, dst)
    cur  = getattr(txr, "a2l_fc_replay_link_cur_addr", None)
    rev  = getattr(txr, "a2l_fc_replay_link_revert", None)
    exp  = getattr(rxr, "exp_pkt_num", None)
    maxexp = 0
    revcnt = 0
    cur_max = 0
    for _ in range(cycles):
        await RisingEdge(tb.dut.hclk)
        if rev is not None and _i(rev) == 1:
            revcnt += 1
        e = _i(exp)
        if e > maxexp:
            maxexp = e
        c = _i(cur)
        if c > cur_max:
            cur_max = c
    return maxexp, revcnt, cur_max


async def _run(tb, src, dst, block_ack):
    dut = tb.dut
    rxr = fcsm(tb, dst)
    fetxmax = _i(getattr(rxr, "fe_tx_credit_max", None))

    if block_ack:
        cocotb.start_soon(_hold_ack_low(tb, dst))
        await ClockCycles(dut.hclk, 10)

    payloads = [0xA5A50000 + (i << 8) + i for i in range(N_WORDS)]
    watch = cocotb.start_soon(_watch(tb, src, dst, cycles=8000))
    await tb.ahb_tx_write_packet_b2b(src, payloads)
    await ClockCycles(dut.hclk, 8000)
    maxexp, revcnt, cur_max = await watch

    got = [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(N_WORDS)]
    delivered = sum(1 for i in range(N_WORDS) if got[i] == payloads[i])
    tb.log.info(f"  [Q-A block_ack={block_ack}] fe_tx_credit_max=0x{fetxmax:02x} "
                f"delivered={delivered}/{N_WORDS} max_exp_pkt_num=0x{maxexp:02x} "
                f"tx_revert_cycles={revcnt} tx_replay_rdptr_max=0x{cur_max:02x}")
    tb.log.info(f"  [Q-A block_ack={block_ack}] RX readback: "
                f"[{', '.join(f'0x{w:08x}' for w in got)}]")
    return delivered, maxexp, revcnt


@cocotb.test()
async def test_qa_ack_enabled(dut):
    """Bilateral ACKs: replay drains, all 16 delivered exactly-once, no ratchet."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    delivered, maxexp, revcnt = await _run(tb, "s", "m", block_ack=False)
    assert delivered == N_WORDS, (
        f"ACK-enabled: expected all {N_WORDS} delivered, got {delivered}")
    assert revcnt == 0, f"ACK-enabled: unexpected {revcnt} TX reverts"


@cocotb.test()
async def test_qa_ack_blocked(dut):
    """ACK path blocked (A->B only model): observe replay accumulation / exp
    ratchet. NON-asserting beyond a sanity floor — this DOCUMENTS the no-ack
    failure mode (the hypothesised silicon wedge cause)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    delivered, maxexp, revcnt = await _run(tb, "s", "m", block_ack=True)
    tb.log.info(f"  [Q-A] ACK-blocked outcome: delivered={delivered} "
                f"max_exp=0x{maxexp:02x} reverts={revcnt} — compare vs ACK-enabled")
