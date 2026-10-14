"""Sideband (0xA1, WlinkGenericFCSM_6) CRC-replay BREADTH sweep.

One sim per case, parameterised by environment (see run_sweep.sh):
  SB_DIR   ab (tx=m,rx=s) | ba (tx=s,rx=m)
  SB_MODE  first : real APB 0x23C single shot (first 0xA1 packet after arm)  [as test_sideband_crc_replay]
           pos   : same real injector, but err_inj_smack gated to the SB_POS-th 0xA1 TX packet
                   of the measured window (tb_top.sv pi_* block); SB_POS is 0-based
           none  : no injection (control)
  SB_LEN   sideband message length field L (message = L+2 words)
  SB_NMSG  number of messages sent back to back inside the window (default 1)
  SB_GAP   idle hclk between AHB-TX words (default 4; 0 = back-to-back)
  SB_SEED  jitters pre-send alignment and tags (sim is otherwise deterministic)
  SB_BYTE/SB_BIT  corrupted byte (4..11 payload) and bit
  SB_FORCE none|l9b|l9c|both  DIAGNOSTIC Force(0) on the receiver's socl_l9b_reanchor_now / socl_l9c_backward
Emits one `RESULT {json}` log line.  The test fails only on instrument/precondition
errors; the verdict is data, not an assertion (SB_ASSERT_EXACT=1 asserts it).
"""
import os, json, random
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force

from test_sideband_crc_replay import (Mon, _bringup, _s, _crc, _arm_apb, _disarm_apb,
                                      APB_REL, APB_CREDIT, APB_RXST, APB_RXCTL, APB_PAIR_EN,
                                      SB_ID)

E = os.environ.get
DIR, MODE = E("SB_DIR", "ab"), E("SB_MODE", "first")
LEN, NMSG, GAP = int(E("SB_LEN", "2")), int(E("SB_NMSG", "1")), int(E("SB_GAP", "4"))
POS, SEED = int(E("SB_POS", "0")), int(E("SB_SEED", "0"))
BYTE, BIT, FORCE = int(E("SB_BYTE", "5")), int(E("SB_BIT", "0")), E("SB_FORCE", "none")
TX, RX = ("m", "s") if DIR == "ab" else ("s", "m")


def mkmsg(tag, length):
    w = [(length & 0xFFF) << 20, 0]
    for i in range(length):
        w.append(tag if i == 0 else ((~tag) & 0xFFFFFFFF) if i == 1 else (tag * (2 * i + 1) + i) & 0xFFFFFFFF)
    return w


async def setup(tb):
    await tb.apb(RX).write(APB_REL, 0)
    await tb.apb(TX).write(APB_PAIR_EN, 1)
    await tb.apb(RX).write(APB_RXCTL, 0x2)
    await ClockCycles(tb.dut.hclk, 50)


async def credit_wait(tb, need):
    t = 0
    while (await tb.apb(RX).read(APB_CREDIT)) < need:
        await ClockCycles(tb.dut.hclk, 20); t += 1
        assert t < 500, "no receiver credit"


async def drain(tb, wait=60000, settle=3000, maxpk=12):
    apb = tb.apb(RX); pk = []
    for _ in range(wait // 100):
        if (await apb.read(APB_RXST) >> 4) & 1: break
        await ClockCycles(tb.dut.hclk, 100)
    await ClockCycles(tb.dut.hclk, settle)
    while (await apb.read(APB_RXST) >> 4) & 1 and len(pk) < maxpk:
        hdr = await tb.ahb_fifo_read_word(RX, 0)
        total = min(((hdr >> 20) & 0xFFF) + 2, 64)
        pk.append([hdr] + [await tb.ahb_fifo_read_word(RX, i * 4) for i in range(1, total)])
    return pk


def classify(sent, got):
    key = lambda m: tuple(m)
    sk = [key(m) for m in sent]
    ok = [0] * len(sent); stray = []
    for g in got:
        k = key(g)
        if k in sk: ok[sk.index(k)] += 1
        else: stray.append(g)
    lost = sum(1 for c in ok if c == 0)
    dup = sum(c - 1 for c in ok if c > 1)
    return lost, dup, len(stray), stray


def piv(tb, name, v=None):
    h = getattr(tb.dut, name)
    if v is None: return int(h.value)
    h.value = v


@cocotb.test()
async def test_case(dut):
    rnd = random.Random(SEED * 7919 + 13)
    tb = await _bringup(dut)
    await setup(tb)
    cnt = f"pi_cnt_{TX}"
    # instrument precondition + packet census: one clean message, count 0xA1 TX packets it takes
    tag0 = 0x5C000001
    m0 = mkmsg(tag0, LEN)
    await credit_wait(tb, LEN + 2)
    n0 = piv(tb, cnt)
    await tb.ahb_tx_write_packet(TX, m0)
    pk0 = await drain(tb)
    n_pkts_msg = piv(tb, cnt) - n0
    assert len(pk0) == 1 and pk0[0] == m0, f"PRECONDITION clean message: {pk0} vs {m0}"
    async def crc():
        return (await tb.apb(RX).read(0x1700 + 0x20)) & 0xFFFF
    c0 = await crc()
    if FORCE in ("l9b", "both"):
        tb.fcsm(RX).socl_l9b_reanchor_now.value = Force(0)
    if FORCE in ("l9c", "both"):
        tb.fcsm(RX).socl_l9c_backward.value = Force(0)
    mon = Mon(tb); mon.start()
    # arm
    piv(tb, "pi_clr", 1); await ClockCycles(dut.hclk, 200); piv(tb, "pi_clr", 0)
    piv(tb, "pi_did", SB_ID)
    if E("SB_TRACE") == "1": piv(tb, "pi_trace", 1)
    if MODE == "first":
        await tb.apb(TX).write(0x023C, 0); await ClockCycles(dut.hclk, 400)
        val = (1 << 24) | ((BIT & 7) << 16) | ((BYTE & 0xFF) << 8) | SB_ID
        await tb.apb(TX).write(0x023C, val); await ClockCycles(dut.hclk, 400)
    elif MODE == "pos":
        # real injector fields (byte/bit/did) via APB but kept un-edged (enable bit set with edge consumed
        # BEFORE the window; smack is then owned by the position gate)
        piv(tb, "pi_tgt", POS)
        val = (1 << 24) | ((BIT & 7) << 16) | ((BYTE & 0xFF) << 8) | SB_ID
        await tb.apb(TX).write(0x023C, 0); await ClockCycles(dut.hclk, 400)
        piv(tb, "pi_en_" + TX, 1)          # force smack = (cnt==tgt): RTL edge-arm bypassed, cnt==tgt can't hold yet if POS>0
        await tb.apb(TX).write(0x023C, val); await ClockCycles(dut.hclk, 400)
        # NB: swi_err_inj enable/byte/bit/did registers now live; smack owned by gate
    await ClockCycles(dut.hclk, rnd.randrange(0, 40))     # seed: alignment jitter
    sent = []
    await credit_wait(tb, NMSG * (LEN + 2))
    for i in range(NMSG):
        tag = (0x5C000100 + 0x1111 * (i + 1) + rnd.randrange(0, 0x1000) * 0x10000) & 0xFFFFFFFF
        m = mkmsg(tag, LEN); sent.append(m)
        await tb.ahb_tx_write_packet(TX, m, gap=GAP)
    credit_before_drain = await tb.apb(RX).read(APB_CREDIT); rxst_before = await tb.apb(RX).read(APB_RXST)
    got = await drain(tb)
    fired = piv(tb, cnt)
    if MODE != "none":
        piv(tb, "pi_en_" + TX, 0)
        await _disarm_apb_side(tb)
    c1 = await crc()
    mon.stop(); await ClockCycles(dut.hclk, 2)
    lost, dup, nstray, stray = classify(sent, got)
    # link health: two fresh clean messages
    fresh = []
    for k in range(2):
        tg = 0x5C0FF000 + k * 0x101 + SEED
        mm = mkmsg(tg, LEN)
        await credit_wait(tb, LEN + 2)
        await tb.ahb_tx_write_packet(TX, mm)
        pkf = await drain(tb)
        fresh.append(len(pkf) == 1 and pkf[0] == mm)
    c2 = await crc()
    def rises(side, n): return mon.count(side, n)
    shot_fired = (MODE == "none") or (fired > POS if MODE == "pos" else fired >= 1)
    res = dict(dir=DIR, mode=MODE, len=LEN, nmsg=NMSG, gap=GAP, pos=POS, seed=SEED, byte=BYTE, bit=BIT,
               force=FORCE, pkts_per_msg=n_pkts_msg, tx_pkts_in_window=fired, shot_fired=shot_fired,
               crc_delta=(c1 - c0) & 0xFFFF, crc_delta_after_fresh=(c2 - c1) & 0xFFFF,
               sent_msgs=NMSG, delivered_msgs=len(got), lost=lost, dup=dup, stray=nstray,
               fresh_ok=all(fresh),
               l9b_rises=rises(RX, "socl_l9b_reanchor_now"), l9c_rises=rises(RX, "socl_l9c_backward"),
               nack_req=rises(RX, "send_nack_req"), state7=mon.state7[RX], wdog_max=mon.max_wdog[RX],
               tx_revert=rises(TX, "a2l_fc_replay_link_revert"),
               exact=(lost == 0 and dup == 0 and nstray == 0),
               credit_tx_view_before_drain=credit_before_drain, rxst_before_drain=rxst_before,
               got=[[hex(w) for w in g[:4]] for g in got[:6]], sent=[[hex(w) for w in m[:4]] for m in sent],
               stray_words=[[hex(w) for w in s[:6]] for s in stray[:3]])
    dut._log.info("RESULT " + json.dumps(res))
    if E("SB_ASSERT_EXACT") == "1":
        assert res["exact"] and res["crc_delta"] >= 1 and shot_fired, res


async def _disarm_apb_side(tb):
    await tb.apb(TX).write(0x023C, 0)
    await ClockCycles(tb.dut.hclk, 400)
