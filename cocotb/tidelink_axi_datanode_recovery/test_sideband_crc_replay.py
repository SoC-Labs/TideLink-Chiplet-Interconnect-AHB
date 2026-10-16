"""TL-059: a CRC-detected sideband packet (DataID 0xA1, WlinkGenericFCSM_6) must be REPLAYED.

KR260 finding (a652c73e, 2026-10-14): die_a arms LINK_ERROR_INJECTION (APB 0x23C) for DataID
0xA1 and sends sideband packets through the onchip ahb_tx path.  die_b's sideband CRC counter
(node 0x1700 +0x20) counts the error but the packet is never delivered; a fresh clean packet
afterwards is.  The AXI data nodes (0x80-0x84) detect AND replay the same shot.  Cause: the
SoC Labs L9b forward re-anchor / L9c backward re-ACK in FCSM_6 (written for the July CRC-off
regime) forgive the gap left by the CRC drop and then swallow the NACK replay.  Fix (design
E): L9b/L9c are only legal while link CRC is DISABLED (SM_CONTROL bit16).

INVARIANT (every case): every packet the injector corrupted must be counted by the receiver's
CRC counter, and every message sent must be delivered EXACTLY ONCE, byte-exact, in order, with a
clean message afterwards.  A shot that fired but was not CRC-counted is an ERROR (the harness
could not prove detection), never a PASS -- except in the explicit header-field case, where the
CRC counter is documented not to count (see test_sideband_hit_header_field).

Tests (each needs its own bring-up/sim -- run with TESTCASE=, see the Makefile `sbcrc` target):
  test_sideband_clean_control        no injection: both messages exactly once, CRC +0
  test_sideband_crc_replay           the finding: real APB-armed injector, byte 5, one message
  test_sideband_crc_position_ab/_ba  corrupt first / middle / second-to-last / last (and the last
                                     packet of message A) of a 2-message stream, with followers
  test_sideband_hit_header_field     hit on the DataID / word_count header bytes
  test_sideband_two_hits_in_flight   two corrupted packets inside one NACK window
  test_sideband_hit_on_replay        the REPLAY of a corrupted packet is itself corrupted
  test_sideband_hit_first_after_bringup  the very first sideband packet after bring-up is hit
  test_sideband_injector_controls    the injector's own must-fail controls (injector_controls.py, shared with the
                                     KR260 tool): alias refused, 0x23C holds, wrong-DataID inert, 0x003C alias dead
  test_axi_w_crc_replay_control      positive control: W (0x81) byte 5 via a peer write

Negative controls (Makefile `sbcrc_neg_*`, must FAIL; wrapped as a gate suite):
  +define+SOCL_L9_ALWAYS   pre-fix RTL (L9b/L9c active with CRC on)
  SB_CRC_OFF=1             disable_crc=1 on the receiver (SM_CONTROL 0x1714 bit16): the link layer
                           no longer checks CRC, so the shot is NOT detected (CRC +0) and the
                           corrupted word is delivered silently -- the documented CRC-off contract.
"""
import os
import json
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
# Shared injector must-fail controls (ONE implementation, also run by the KR260 board tool): injector offset ==
# RDL 0x23C, arm readback holds, wrong-DataID arm inert, a fired shot must move the counter, shots == counts.
from injector_ctl_cocotb import (AsyncInjector, ControlError, ShotLedger, arm_for_gate,
                                 run_wrong_id_control, shot_errors)
from test_axi_datanode_gaps import (AHBSubMaster, _force_axi_crc, _slave_bram_peek,
                                    _release_all,
                                    APER_BASE, OFF_INJECT, OFF_SANITY, D_INJECT, D_SANITY)

SB_ID = 0xA1
N6 = 0x1700                       # FCSM_6 (sideband) APB node base
CRCCNT = 0x20
SM_CONTROL = N6 + 0x14            # bit16 = disable_crc (out_prepend_swi_disable_crc)
APB_ERRINJ = 0x023C
APB_REL, APB_CREDIT, APB_RXST, APB_RXCTL, APB_PAIR_EN = 0x2004, 0x200C, 0x2010, 0x201C, 0x2030
BYTE = int(os.environ.get("SB_BYTE", "5"))
BIT = int(os.environ.get("SB_BIT", "0"))
CRC_OFF = os.environ.get("SB_CRC_OFF", "0") == "1"      # negative control: receiver CRC check off
POSLIST = tuple(int(x) for x in os.environ.get("SB_POS", "").split(",") if x)   # debug override
MSG_LEN = 6                       # payload words of the multi-packet messages (L+2 = 8 words)


def _s(h, n):
    try:    return int(getattr(h, n).value)
    except Exception: return None


class Mon:
    """Per-hclk edge counter of a few FCSM_6 wires (diagnostics + the 'L9 stays quiet' check)."""
    SIGS = ("send_nack_req", "crc_corrupt", "socl_l9b_reanchor_now", "socl_l9c_backward",
            "a2l_fc_replay_link_revert", "state")

    def __init__(self, tb, rx, tx):
        self.tb, self.rx, self.tx = tb, rx, tx
        self.n = {}
        self.run = False

    async def _loop(self):
        last = {}
        while self.run:
            await RisingEdge(self.tb.dut.hclk)
            for side in (self.rx, self.tx):
                fc = self.tb.fcsm(side)
                for sig in self.SIGS:
                    v = _s(fc, sig)
                    if v is None: continue
                    if last.get((side, sig)) != v:
                        last[(side, sig)] = v
                        if v == 1 or (sig == "state" and v == 7):
                            self.n[(side, sig)] = self.n.get((side, sig), 0) + 1

    def start(self):
        self.run = True
        self.task = cocotb.start_soon(self._loop())

    def stop(self):
        self.run = False

    def c(self, side, sig):
        return self.n.get((side, sig), 0)


class Ctx:
    """One bring-up, one direction.  tx/rx are 'm'/'s'."""
    def __init__(self, tb, direction):
        self.tb, self.dir = tb, direction
        self.tx, self.rx = ("m", "s") if direction == "ab" else ("s", "m")
        self.seq = 0               # tag generator, so no two messages in a bring-up share a payload
        self.inj = AsyncInjector(tb.apb(self.tx), tb.dut.hclk)     # raises ControlError on a non-RDL offset
        self.ledger = ShotLedger()  # C-COUNT-EXPECT: every shot's counter movement
        self.crc_base = None        # receiver CRC counter before the first shot (set where it is first read: no extra APB traffic)

    def tag(self):
        self.seq += 1
        return 0x5C000000 + (self.seq << 12) + (0x3A5 * self.seq & 0xFFF)


async def bringup(dut, direction="ab", setup=True):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ctx = Ctx(tb, direction)
    if setup:                      # rev2hw.Path.setup
        await tb.apb(ctx.rx).write(APB_REL, 0)
        await tb.apb(ctx.tx).write(APB_PAIR_EN, 1)
        await tb.apb(ctx.rx).write(APB_RXCTL, 0x2)
        await ClockCycles(dut.hclk, 50)
    if CRC_OFF:
        await set_rx_crc_disable(ctx, True)
    if os.environ.get("SB_TRACE") == "1":      # debug only: PITRACE line per TX 0xA1 packet
        pi(ctx, "pi_trace", 1)
    return ctx


async def set_rx_crc_disable(ctx, off):
    """Receiver FCSM_6 SM_CONTROL bit16 (disable_crc), read-modify-write."""
    apb = ctx.tb.apb(ctx.rx)
    v = await apb.read(SM_CONTROL)
    v = (v | (1 << 16)) if off else (v & ~(1 << 16))
    await apb.write(SM_CONTROL, v)
    await ClockCycles(ctx.tb.dut.hclk, 50)
    rb = await apb.read(SM_CONTROL)
    assert ((rb >> 16) & 1) == (1 if off else 0), f"SM_CONTROL readback 0x{rb:08x}: disable_crc did not take"


def mkmsg(tag, length):
    """[len<<20, 0, p0 .. p(len-1)]: L+2 words; payload words are all distinct."""
    w = [(length & 0xFFF) << 20, 0]
    for i in range(length):
        w.append(tag if i == 0 else ((~tag) & 0xFFFFFFFF) if i == 1
                 else (tag * (2 * i + 1) + i) & 0xFFFFFFFF)
    return w


async def credit_wait(ctx, need):
    t = 0
    while (await ctx.tb.apb(ctx.rx).read(APB_CREDIT)) < need:
        await ClockCycles(ctx.tb.dut.hclk, 20); t += 1
        assert t < 500, "no receiver credit"


async def send(ctx, msgs, gap=4):
    """Send `msgs` back to back; remembers the receiver's free-credit count beforehand."""
    ctx.credit0 = await ctx.tb.apb(ctx.rx).read(APB_CREDIT)
    for m in msgs:
        await credit_wait(ctx, len(m))
        await ctx.tb.ahb_tx_write_packet(ctx.tx, m, gap=gap)


async def collect(ctx, msgs, quiet=6000, lost_wait=80000):
    """Wait for the whole stream to LAND in the receiver FIFO, then read it.

    Reading while words are still arriving (a NACK/replay storm can last >300 us) races the FIFO
    write port (the read returns a word being written for the next message) -- that is a harness
    hazard, not the DUT.  So: poll the free-credit count until `landed` (credit0 - credit) reaches
    the words sent and then stays put for `quiet` hclk (a replay duplicate would show as extra
    landed words); give up after `lost_wait` idle hclk (lost words).  Then read messages out of the
    FIFO by their headers until `landed` words are consumed.  STATUS[4] PACKET_COMMITTED is a single
    flag cleared by the address-0 read, so it cannot count queued messages and is not used."""
    apb, want = ctx.tb.apb(ctx.rx), sum(len(m) for m in msgs)
    last, idle, stable = None, 0, 0
    while True:
        landed = ctx.credit0 - await apb.read(APB_CREDIT)
        if landed == last:
            idle += 100; stable += 100
        else:
            idle = stable = 0
        last = landed
        if (landed >= want and stable >= quiet) or idle >= lost_wait:
            break
        await ClockCycles(ctx.tb.dut.hclk, 100)
    pk, remaining = [], landed
    while remaining >= 2 and len(pk) < 3 * len(msgs):
        hdr = await ctx.tb.ahb_fifo_read_word(ctx.rx, 0)
        total = min(((hdr >> 20) & 0xFFF) + 2, 64, remaining)
        pk.append([hdr] + [await ctx.tb.ahb_fifo_read_word(ctx.rx, i * 4) for i in range(1, total)])
        remaining -= total
    ctx.landed, ctx.want = landed, want
    return pk


def classify(sent, got):
    """-> dict(lost, dup, stray, order_ok, exact).  exact == got is sent, once each, in order."""
    sk = [tuple(m) for m in sent]
    cnt = [0] * len(sent); stray = 0
    for g in got:
        k = tuple(g)
        if k in sk: cnt[sk.index(k)] += 1
        else: stray += 1
    lost = sum(1 for c in cnt if c == 0)
    dup = sum(c - 1 for c in cnt if c > 1)
    return dict(lost=lost, dup=dup, stray=stray, exact=[tuple(g) for g in got] == sk)


async def crc(ctx):
    return (await ctx.tb.apb(ctx.rx).read(N6 + CRCCNT)) & 0xFFFF


async def arm_apb(ctx, did, byte, bit):
    """rev2hw.arm: write 0, then the armed value (0->1 edge in the TX link clock); 0x23C must read 0 before
    and read back the armed value after (injector_controls C-REG-ADDR / C-REG-HOLD)."""
    await ctx.inj.arm(did, byte, bit)


async def disarm_apb(ctx):
    await ctx.inj.disarm()


async def wrong_id_control(ctx, drive):
    """C-INJ-INERT: arm a DataID nobody uses while `drive()` (-> number of messages NOT delivered exactly)
    runs; the receiver's CRC counter must not move and the data must be exact."""
    errs = await run_wrong_id_control(ctx.inj, drive, lambda: crc(ctx))
    assert not errs, "PRECONDITION: wrong-DataID injector control: " + "; ".join(errs)


async def finish(ctx, results):
    """_verdict() plus C-COUNT-EXPECT: the CRC counter moved exactly as much as the shots account for."""
    total = ((await crc(ctx)) - ctx.crc_base) & 0xFFFF
    errs = ctx.ledger.errors(total_delta=total)
    if errs:
        results = list(results) + [dict(name="count_expect", errors=errs)]
    _verdict(results)


def pi(ctx, name, v=None):
    """tb_top.sv pi_* position-injector controls (harness only)."""
    h = getattr(ctx.tb.dut, name)
    if v is None: return int(h.value)
    h.value = v


async def pi_open(ctx, tgt, tgt2=-1, rep=False, byte=BYTE, bit=BIT):
    """Window: clear the TX packet counter, point the position gate at packet `tgt`
    (optionally also `tgt2`, and/or the replay of `tgt`), program byte/bit/DataID through the real
    APB register and let the gate own err_inj_smack."""
    pi(ctx, "pi_clr", 1); await ClockCycles(ctx.tb.dut.hclk, 50); pi(ctx, "pi_clr", 0)
    pi(ctx, "pi_did", SB_ID); pi(ctx, "pi_tgt", tgt); pi(ctx, "pi_tgt2", tgt2)
    pi(ctx, "pi_rep_en", 1 if rep else 0)
    await ctx.inj.clear()                       # write 0; 0x23C must read 0
    pi(ctx, "pi_en_" + ctx.tx, 1)
    await arm_for_gate(ctx.inj, SB_ID, byte, bit)   # armed value written and read back


async def pi_close(ctx):
    pi(ctx, "pi_en_" + ctx.tx, 0)
    pi(ctx, "pi_tgt2", -1); pi(ctx, "pi_rep_en", 0)
    await disarm_apb(ctx)


async def census(ctx, msgs):
    """Clean (un-armed) run of `msgs`: returns the number of 0xA1 TX wlink packets they take and
    proves the instrument: all delivered exactly once, CRC +0."""
    warm = [mkmsg(ctx.tag(), 2)]      # first traffic after bring-up carries extra stream-start packets
    await send(ctx, warm)
    assert classify(warm, await collect(ctx, warm))["exact"], "PRECONDITION: warm-up message"
    pi(ctx, "pi_clr", 1); await ClockCycles(ctx.tb.dut.hclk, 50); pi(ctx, "pi_clr", 0)
    c0 = await crc(ctx)
    await send(ctx, msgs)
    got = await collect(ctx, msgs)
    n = pi(ctx, "pi_cnt_" + ctx.tx)
    assert classify(msgs, got)["exact"], f"PRECONDITION: clean traffic not exact: {got}"
    assert ((await crc(ctx)) - c0) & 0xFFFF == 0, "PRECONDITION: CRC counted on clean traffic"
    return n


async def shot(ctx, name, msgs, tgt, tgt2=-1, rep=False, byte=BYTE, bit=BIT,
               expect_crc=None, gap=4):
    """One armed shot over the message stream `msgs`.  expect_crc = number of CRC counts required
    (default: one per corrupted packet); 0 documents a field the CRC counter does not count.
    Returns a result dict; res['errors'] lists every violated invariant (empty == PASS)."""
    tb = ctx.tb
    mon = Mon(tb, ctx.rx, ctx.tx); mon.start()
    c0 = await crc(ctx)
    if ctx.crc_base is None:
        ctx.crc_base = c0
    await pi_open(ctx, tgt, tgt2, rep, byte, bit)
    await send(ctx, msgs, gap)
    got = await collect(ctx, msgs)
    landed, want_words = ctx.landed, ctx.want
    fired = pi(ctx, "pi_fired_" + ctx.tx)
    npk = pi(ctx, "pi_cnt_" + ctx.tx)
    await pi_close(ctx)
    c1 = await crc(ctx)
    mon.stop(); await ClockCycles(tb.dut.hclk, 2)
    cl = classify(msgs, got)
    # link health: a fresh clean message must still be delivered exactly once
    fm = [mkmsg(ctx.tag(), 2)]
    await send(ctx, fm)
    fresh = classify(fm, await collect(ctx, fm))["exact"]
    det = (c1 - c0) & 0xFFFF
    want_hits = 1 + (1 if tgt2 >= 0 else 0) + (1 if rep else 0)
    errs = shot_errors(fired, det, want_hits, expect_crc, npk)       # C-INJ-LIVE (injector_controls)
    ctx.ledger.add(fired, det, name)                                   # C-COUNT-EXPECT
    if not cl["exact"]:
        for i, g in enumerate(got):
            hit = [j for j, m in enumerate(msgs) if list(m) == list(g)]
            tb.log.info(f"[sbcrc]   delivered[{i}] len={len(g)} " + (f"== sent[{hit[0]}]" if hit else
                        "STRAY words=" + ",".join(f"{w:08x}" for w in g)))
        for j, m in enumerate(msgs):
            tb.log.info(f"[sbcrc]   sent[{j}] words=" + ",".join(f"{w:08x}" for w in m))
    if not cl["exact"]:
        errs.append(f"NOT EXACTLY-ONCE: lost={cl['lost']} dup={cl['dup']} stray={cl['stray']} "
                    f"delivered={len(got)}/{len(msgs)}")
    if not fresh:
        errs.append("LINK UNHEALTHY: fresh clean message not delivered exactly once afterwards")
    if (not CRC_OFF) and (mon.c(ctx.rx, "socl_l9b_reanchor_now") or mon.c(ctx.rx, "socl_l9c_backward")):
        errs.append(f"L9b/L9c fired with CRC ON (l9b={mon.c(ctx.rx, 'socl_l9b_reanchor_now')} "
                    f"l9c={mon.c(ctx.rx, 'socl_l9c_backward')})")
    res = dict(name=name, dir=ctx.dir, tgt=tgt, tgt2=tgt2, rep=rep, byte=byte, bit=bit, tx_pkts=npk,
               landed=landed, want_words=want_words, fired=fired, crc_delta=det, delivered=len(got), sent=len(msgs), lost=cl["lost"],
               dup=cl["dup"], stray=cl["stray"], fresh=fresh,
               nack_req=mon.c(ctx.rx, "send_nack_req"), revert=mon.c(ctx.tx, "a2l_fc_replay_link_revert"),
               l9b=mon.c(ctx.rx, "socl_l9b_reanchor_now"), l9c=mon.c(ctx.rx, "socl_l9c_backward"),
               errors=errs)
    tb.log.info("[sbcrc] " + json.dumps(res))
    return res


def _verdict(results):
    bad = [r for r in results if r["errors"]]
    for r in bad:
        cocotb.log.error(f"[sbcrc] FAIL {r['name']}: " + " | ".join(r["errors"]))
    assert results, "no shots ran"
    assert not bad, (f"{len(bad)}/{len(results)} shots violated the invariant: "
                     + "; ".join(f"{r['name']}: {r['errors'][0]}" for r in bad))


def stream_msgs(ctx):
    return [mkmsg(ctx.tag(), MSG_LEN), mkmsg(ctx.tag(), MSG_LEN)]


# --------------------------------------------------------------------------------------------
@cocotb.test()
async def test_sideband_clean_control(dut):
    """No injection: instrument proof.  Both messages exactly once, CRC +0, no L9b/L9c."""
    ctx = await bringup(dut)
    msgs = stream_msgs(ctx)
    c0 = await crc(ctx)
    mon = Mon(ctx.tb, ctx.rx, ctx.tx); mon.start()
    await send(ctx, msgs)
    got = await collect(ctx, msgs)
    mon.stop(); await ClockCycles(dut.hclk, 2)
    cl = classify(msgs, got)
    d = ((await crc(ctx)) - c0) & 0xFFFF
    dut._log.info(f"[sbcrc] clean crc+{d} {cl} nack_req={mon.c(ctx.rx, 'send_nack_req')}")
    assert d == 0 and cl["exact"], (d, cl)


@cocotb.test()
async def test_sideband_crc_replay(dut):
    """The finding, driven exactly as rev2hw: real APB-armed injector (0->1 edge), byte 5, bit 0,
    first 0xA1 packet after arming, one 4-word message, then a follower message."""
    ctx = await bringup(dut)
    pre = [mkmsg(ctx.tag(), 2)]
    await send(ctx, pre)
    assert classify(pre, await collect(ctx, pre))["exact"], "PRECONDITION: clean packet"
    msgs = [[(2 << 20), 0, 0x5C000105, (~0x5C000105) & 0xFFFFFFFF], mkmsg(ctx.tag(), 2)]
    mon = Mon(ctx.tb, ctx.rx, ctx.tx); mon.start()
    c0 = await crc(ctx)
    await arm_apb(ctx, SB_ID, BYTE, BIT)
    await send(ctx, msgs)
    got = await collect(ctx, msgs)
    await disarm_apb(ctx)
    d = ((await crc(ctx)) - c0) & 0xFFFF
    mon.stop(); await ClockCycles(dut.hclk, 2)
    cl = classify(msgs, got)
    fm = [mkmsg(ctx.tag(), 2)]
    await send(ctx, fm)
    fresh = classify(fm, await collect(ctx, fm))["exact"]
    dut._log.info(f"[sbcrc] replay crc+{d} {cl} fresh={fresh} nack_req={mon.c(ctx.rx, 'send_nack_req')} "
                  f"l9b={mon.c(ctx.rx, 'socl_l9b_reanchor_now')} l9c={mon.c(ctx.rx, 'socl_l9c_backward')}")
    ctx.ledger.add(None, d, "replay")                                  # C-COUNT-EXPECT (shot count unobservable here)
    assert d == 1, f"shot not detected (CRC counter +{d}): vacuous"
    assert cl["exact"], f"detected sideband CRC error was NOT replayed exactly once: {cl}"
    assert fresh, "link unhealthy after the shot"


async def _positions(dut, direction):
    ctx = await bringup(dut, direction)
    n = 2 * await census(ctx, [mkmsg(ctx.tag(), MSG_LEN)])       # 1 wlink packet per message word
    dut._log.info(f"[sbcrc] {direction}: stream of 2 messages = {n} wlink packets")
    assert n >= 8, f"unexpected packet census n={n}"
    pos = [("first", 0), ("middle", n // 4), ("lastA_with_follower", n // 2 - 1),
           ("second_to_last", n - 2), ("last", n - 1)]
    if POSLIST:
        pos = [(f"dbg", p) for p in POSLIST]
    res = []
    for nm, p in pos:
        res.append(await shot(ctx, f"{direction}:{nm}@{p}", stream_msgs(ctx), p))
    await finish(ctx, res)


@cocotb.test()
async def test_sideband_crc_position_ab(dut):
    await _positions(dut, "ab")


@cocotb.test()
async def test_sideband_crc_position_ba(dut):
    await _positions(dut, "ba")


@cocotb.test()
async def test_sideband_hit_header_field(dut):
    """Hit on the packet header: byte 0 (DataID, bit 3 -> 0xA9: no node owns it) and byte 1
    (word_count).  The FCSM CRC counter only counts packets whose DataID still matches
    (crc_corrupt requires it), so a DataID hit is a SILENT drop -- CRC +0 by design, the hole in a
    'pend-flop set by CRC error' fix (a word_count hit with ECC bypassed IS CRC-counted).  The invariant still holds: the gap must be NACKed and the
    packet replayed, exactly once.
      SB_HDR_ECC=on  (default, FPGA/ASIC-with-ECC flist): header ECC corrects the single-bit hit, so
                     nothing is dropped (no NACK) -- asserted, so the case cannot pass vacuously.
      SB_HDR_ECC=off (ASIC_MIRROR=2: WlinkEccSyndrome bypassed): the hit DROPS the packet; asserted
                     that it was NACKed (>=1 NACK, CRC +0) and replayed exactly once."""
    ecc_on = os.environ.get("SB_HDR_ECC", "on") != "off"
    ctx = await bringup(dut)
    n = 2 * await census(ctx, [mkmsg(ctx.tag(), MSG_LEN)])
    res = []
    for byte, bit, pos in ((0, 3, 1), (0, 3, n // 2), (0, 3, n - 2), (1, 0, 1)):
        r = await shot(ctx, f"hdr byte{byte}bit{bit}@{pos} ecc={'on' if ecc_on else 'off'}",
                       stream_msgs(ctx), pos, byte=byte, bit=bit,
                       expect_crc=1 if (byte == 1 and not ecc_on) else 0)   # word_count is under the CRC
        if ecc_on and r["nack_req"]:
            r["errors"].append(f"header ECC on but the hit still caused {r['nack_req']} NACKs")
        if (not ecc_on) and byte == 0 and not r["nack_req"]:
            r["errors"].append("ERROR drop: DataID hit with ECC bypassed caused no NACK (hit had no effect); vacuous")
        res.append(r)
    await finish(ctx, res)


@cocotb.test()
async def test_sideband_two_hits_in_flight(dut):
    """Two corrupted packets inside one NACK window (adjacent, and one packet apart)."""
    ctx = await bringup(dut)
    n = 2 * await census(ctx, [mkmsg(ctx.tag(), MSG_LEN)])
    res = []
    for t1, t2 in ((1, 2), (1, 3), (n // 2, n // 2 + 1)):
        res.append(await shot(ctx, f"two_hits@{t1},{t2}", stream_msgs(ctx), t1, tgt2=t2))
    await finish(ctx, res)


@cocotb.test()
async def test_sideband_hit_on_replay(dut):
    """The NACK-driven replay of a corrupted packet is itself corrupted (replay-of-replay)."""
    ctx = await bringup(dut)
    n = 2 * await census(ctx, [mkmsg(ctx.tag(), MSG_LEN)])
    res = []
    for p in POSLIST or (1, n // 2, n - 2):
        res.append(await shot(ctx, f"hit_on_replay@{p}", stream_msgs(ctx), p, rep=True))
    await finish(ctx, res)


@cocotb.test()
async def test_sideband_hit_first_after_bringup(dut):
    """The very first sideband data packet after bring-up is corrupted (before L9's
    first_data_seen one-shots have fired; no clean traffic precedes it), with followers."""
    ctx = await bringup(dut)
    msgs = stream_msgs(ctx)
    res = [await shot(ctx, "first_after_bringup@0", msgs, 0)]
    await finish(ctx, res)


@cocotb.test()
async def test_sideband_injector_controls(dut):
    """The injector's own must-fail controls (injector_controls.py, the SAME code the KR260 tool runs), in their
    own bring-up so the nine invariant tests keep their exact traffic timing:
      C-REG-ADDR   an injector driver pointed at the 0x003C alias is refused before any write
      C-REG-HOLD   0x23C reads 0, holds the armed value (readback), reads 0 after the disarm
      C-INJ-INERT  armed for a DataID nobody uses: a message is delivered exactly once, CRC +0, disarm clean
      ALIAS-DEAD   writing the alias 0x003C (the historical host bug) does NOT arm anything: the same shot then
                   leaves the CRC counter at +0 -- which is exactly why a shot with no counter movement is an ERROR"""
    ctx = await bringup(dut)
    # C-REG-ADDR
    try:
        AsyncInjector(ctx.tb.apb(ctx.tx), dut.hclk, offset=0x003C)
        raise AssertionError("an injector pointed at the 0x003C alias was accepted")
    except ControlError:
        pass
    # C-REG-HOLD (arm asserts zero-before and readback-equals-written; disarm must read 0)
    r = await ctx.inj.arm(SB_ID, BYTE, BIT)
    assert r.ok and r.value == ((1 << 24) | ((BIT & 7) << 16) | ((BYTE & 0xFF) << 8) | SB_ID)
    await ctx.inj.disarm()
    assert await ctx.inj.reads_zero(), "0x23C does not read 0 after the disarm"
    # C-INJ-INERT
    warm = [mkmsg(ctx.tag(), 2)]

    async def _drive():
        await send(ctx, warm)
        return 0 if classify(warm, await collect(ctx, warm))["exact"] else 1
    await wrong_id_control(ctx, _drive)
    # ALIAS-DEAD: write the arm value to the alias, send, and require the counter to stay put
    c0 = ctx.crc_base = await crc(ctx)
    apb = ctx.tb.apb(ctx.tx)
    await apb.write(0x003C, (1 << 24) | ((BIT & 7) << 16) | ((BYTE & 0xFF) << 8) | SB_ID)
    await ClockCycles(dut.hclk, 400)
    msgs = [mkmsg(ctx.tag(), 2)]
    await send(ctx, msgs)
    got = await collect(ctx, msgs)
    d = ((await crc(ctx)) - c0) & 0xFFFF
    dut._log.info(f"[sbcrc] alias-arm: crc+{d} exact={classify(msgs, got)['exact']} 0x23C reads 0x{await apb.read(APB_ERRINJ):08x}")
    assert d == 0 and classify(msgs, got)["exact"], f"the 0x003C alias armed something (CRC +{d}): the sim map changed"
    assert await ctx.inj.reads_zero(), "an alias write reached 0x23C"
    ctx.ledger.add(0, d, "alias")
    errs = ctx.ledger.errors(total_delta=((await crc(ctx)) - ctx.crc_base) & 0xFFFF)     # C-COUNT-EXPECT
    assert not errs, "; ".join(errs)


@cocotb.test()
async def test_axi_w_crc_replay_control(dut):
    """Positive control: same APB-armed single-bit shot on W (0x81, byte 5) of a peer write."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ctx = Ctx(tb, "ab")
    master = AHBSubMaster(dut)
    _force_axi_crc(tb, True)
    fcw = tb.top("s").u_chiplet_controller.u_wlink.axi2wl.wlink_axiwFC
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"
    c0 = _s(fcw, "crc_errors") or 0
    await arm_apb(ctx, 0x81, BYTE, BIT)
    await master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=80000)
    await ClockCycles(dut.hclk, 3000)
    await disarm_apb(ctx)
    c1 = _s(fcw, "crc_errors") or 0
    got = _slave_bram_peek(dut, OFF_INJECT)
    dut._log.info(f"[w] crc_errors {c0}->{c1} mem=0x{got:08x} (sent 0x{D_INJECT:08x})")
    _release_all(tb)
    assert c1 > c0, "W shot not detected: vacuous"
    assert got == D_INJECT, "W shot detected but data not exact after replay"
