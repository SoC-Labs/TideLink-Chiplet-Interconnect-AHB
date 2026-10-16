"""Multi-message sideband delivery (VERIFICATION.md open item (a)): queue N back-to-back messages
from TX, do not drain, count words at the RX FIFO write port (DUT-internal) AND at the APB/AHB
drain.  Per-message accounting; harness variants:

  DRAIN=old    the pre-TL-059 harness drain: loop `while STATUS[4] PACKET_COMMITTED` (a SINGLE flag,
               cleared by the address-0 read, so it can only ever read ONE message)
  DRAIN=new    read by header until the FIFO write-port word count is consumed

Env: MM_DIR ab|ba  MM_N  MM_LEN  MM_GAP  MM_WHEN after|while  MM_REL (APB 0x2004)  MM_PAIR  MM_RXCTL
     MM_CTL_FLUSH=1  must-fail control: a REAL drop (receiver FIFO flushed after message 0 landed);
                     the checker MUST report exact=False (proves the harness can see a real drop).
Emits `MMRESULT {json}`.  Asserts exactness (DUT) unless MM_NOASSERT=1.
"""
import os, json
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from test_sideband_crc_replay import (bringup, mkmsg, credit_wait, APB_REL, APB_CREDIT, APB_RXST,
                                      APB_RXCTL, APB_PAIR_EN, N6, CRCCNT)

E = os.environ.get
DIR, N, LEN, GAP = E("MM_DIR", "ab"), int(E("MM_N", "3")), int(E("MM_LEN", "2")), int(E("MM_GAP", "0"))
WHEN, DRAIN = E("MM_WHEN", "after"), E("MM_DRAIN", "both")
REL, PAIR, RXCTL = int(E("MM_REL", "0"), 0), int(E("MM_PAIR", "1")), int(E("MM_RXCTL", "2"), 0)
DSETTLE = int(E("MM_DRAIN_SETTLE", "200"))
BREAK_FLUSH = E("MM_CTL_FLUSH") == "1"


LEGACY_WRITE = E("MM_LEGACY_WRITE") == "1"   # PairV2TB.ahb_tx_write_word: gives up after 50 cyc of HREADY=0
LEGACY_READ = E("MM_LEGACY_READ") == "1"     # PairV2TB.ahb_fifo_read_word: one-clock address phase


class TxStat:
    errs = 0; max_low = 0


async def tx_write_packet(tb, side, words, gap=0):
    if LEGACY_WRITE:
        return await tb.ahb_tx_write_packet(side, words, gap=gap)
    e, low = await tb.ahb_tx_write_packet_legal(side, words, gap=gap)
    TxStat.errs += e; TxStat.max_low = max(TxStat.max_low, low)


async def fifo_read_word(tb, side, byte_addr):
    if LEGACY_READ:
        return await tb.ahb_fifo_read_word(side, byte_addr)
    return await tb.ahb_fifo_read_word_legal(side, byte_addr)


def fifo_ctrl(tb, side):
    return tb.top(side).u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


class WrMon:
    """Counts words accepted at the RX FIFO write port (fc_wr_valid & fc_wr_write, per hclk)."""
    def __init__(self, tb, side):
        self.h = fifo_ctrl(tb, side); self.clk = tb.dut.hclk; self.words = []; self.run = False
        self.overrun = 0

    async def _loop(self):
        while self.run:
            await RisingEdge(self.clk)
            try:
                if int(self.h.fc_wr_valid.value) and int(self.h.fc_wr_write.value):
                    self.words.append(int(self.h.fc_wr_wdata.value))
                self.overrun = int(self.h.overrun.value)
            except ValueError:
                pass

    def start(self): self.run = True; cocotb.start_soon(self._loop())
    def stop(self): self.run = False


async def read_n(tb, rx, n):
    return [await fifo_read_word(tb, rx, i * 4) for i in range(n)]


async def drain_old(tb, rx):
    """pre-TL-059 harness: poll STATUS[4] (single flag) between packets."""
    apb = tb.apb(rx); pk = []
    while (await apb.read(APB_RXST) >> 4) & 1 and len(pk) < 12:
        hdr = await fifo_read_word(tb, rx, 0)
        total = min(((hdr >> 20) & 0xFFF) + 2, 64)
        pk.append([hdr] + [await fifo_read_word(tb, rx, i * 4) for i in range(1, total)])
    return pk


async def drain_new(tb, rx, landed):
    pk, rem = [], landed
    while rem >= 2 and len(pk) < 3 * N:
        hdr = await fifo_read_word(tb, rx, 0)
        total = min(((hdr >> 20) & 0xFFF) + 2, 64, rem)
        pk.append([hdr] + [await fifo_read_word(tb, rx, i * 4) for i in range(1, total)])
        rem -= total
    return pk


@cocotb.test()
async def test_multimsg(dut):
    ctx = await bringup(dut, DIR, setup=False)
    tb, tx, rx = ctx.tb, ctx.tx, ctx.rx
    await tb.apb(rx).write(APB_REL, REL)
    await tb.apb(tx).write(APB_PAIR_EN, PAIR)
    await tb.apb(rx).write(APB_RXCTL, RXCTL)
    await ClockCycles(dut.hclk, 50)
    mon = WrMon(tb, rx); mon.start()
    msgs = [mkmsg(ctx.tag(), LEN) for _ in range(N)]
    credit0 = await tb.apb(rx).read(APB_CREDIT)
    got_while = []
    stop_drain = [False]
    async def drainer():      # concurrent receiver: pop a message only once all its words have landed
        while not stop_drain[0]:
            consumed = sum(len(g) for g in got_while)
            if len(mon.words) - consumed >= LEN + 2:
                await ClockCycles(dut.hclk, DSETTLE)       # let the last word's write_complete settle
                got_while.extend(await drain_new(tb, rx, LEN + 2))
            else:
                await ClockCycles(dut.hclk, 50)
    if WHEN == "concur":
        cocotb.start_soon(drainer())
    if BREAK_FLUSH:   # must-fail control: a REAL drop -- flush the receiver FIFO after message 0 lands
        await credit_wait(ctx, len(msgs[0])); await tx_write_packet(tb, tx, msgs[0], gap=GAP)
        await ClockCycles(dut.hclk, 3000); await tb.apb(rx).write(APB_RXCTL, 0x2)
        await ClockCycles(dut.hclk, 100)
        msgs_to_send = msgs[1:]
    else:
        msgs_to_send = msgs
    for m in msgs_to_send:
        await credit_wait(ctx, len(m))
        await tx_write_packet(tb, tx, m, gap=GAP)
        if WHEN == "while":  # (serial: send one, wait, drain it)
            await ClockCycles(dut.hclk, 3000)
            c = credit0 - await tb.apb(rx).read(APB_CREDIT)
            got_while += await drain_new(tb, rx, len(m) if c >= len(m) else c)
            credit0 = await tb.apb(rx).read(APB_CREDIT)
    async def settle(quiet=6000, cap=60000):
        last, stable = -1, 0
        while stable < cap:
            if len(mon.words) == last: stable += 100
            else: stable = 0
            last = len(mon.words)
            if stable >= quiet and len(mon.words) >= want_total: return
            await ClockCycles(dut.hclk, 100)
    want_total = sum(len(m) for m in msgs)
    await settle()
    stop_drain[0] = True; await ClockCycles(dut.hclk, 400)
    wr_undrained = len(mon.words)
    credit_undrained = credit0 - await tb.apb(rx).read(APB_CREDIT)
    flag_before = (await tb.apb(rx).read(APB_RXST) >> 4) & 1
    tx_credit_view = await tb.apb(tx).read(APB_CREDIT)
    got = list(got_while); consumed = sum(len(g) for g in got)
    rounds = 0
    while consumed < want_total and rounds < 12:
        landed = len(mon.words) - consumed
        if landed < 2:
            await settle(quiet=6000, cap=20000)
            landed = len(mon.words) - consumed
            if landed < 2: break
        pk = await drain_new(tb, rx, landed)
        got += pk; consumed += sum(len(g) for g in pk); rounds += 1
        await settle(quiet=3000, cap=20000)
    mon.stop()
    wr_words = list(mon.words)
    res = dict(dir=DIR, n=N, len=LEN, gap=GAP, when=WHEN, rel=REL, pair=PAIR, rxctl=RXCTL,
               want_words=want_total, wr_port_words=len(wr_words), wr_undrained=wr_undrained,
               credit_landed_undrained=credit_undrained, tx_credit_view=tx_credit_view,
               flag_before_drain=flag_before, overrun=mon.overrun, tx_hresp_errors=TxStat.errs, tx_hready_low_max=TxStat.max_low, legacy_write=LEGACY_WRITE, drain_rounds=rounds,
               delivered=[msgs.index(g) if g in msgs else -1 for g in got],
               exact=got == msgs,
               bad=[dict(i=i, got=[hex(w) for w in g], exp=[hex(w) for w in (msgs[i] if i < len(msgs) else [])])
                    for i, g in enumerate(got) if i < len(msgs) and g != msgs[i]][:3], first_wr=[hex(w) for w in wr_words[:20]] if len(wr_words) != want_total else None)
    dut._log.info("MMRESULT " + json.dumps(res))
    if E("MM_NOASSERT") != "1":
        assert res["exact"], res
        assert res["wr_port_words"] == res["want_words"], res


@cocotb.test()
async def test_multimsg_old_drain(dut):
    """Reproduces the 2026-10-14 symptom with the OLD drain on the same stimulus (only when MM_OLD=1)."""
    if E("MM_OLD") != "1":
        return
    ctx = await bringup(dut, DIR, setup=False)
    tb, tx, rx = ctx.tb, ctx.tx, ctx.rx
    await tb.apb(rx).write(APB_REL, REL); await tb.apb(tx).write(APB_PAIR_EN, PAIR)
    await tb.apb(rx).write(APB_RXCTL, RXCTL); await ClockCycles(dut.hclk, 50)
    mon = WrMon(tb, rx); mon.start()
    msgs = [mkmsg(ctx.tag(), LEN) for _ in range(N)]
    for m in msgs:
        await credit_wait(ctx, len(m)); await tx_write_packet(tb, tx, m, gap=GAP)
    await ClockCycles(dut.hclk, 8000)
    got = await drain_old(tb, rx); mon.stop()
    dut._log.info("MMOLD " + json.dumps(dict(n=N, wr_port_words=len(mon.words), want=sum(map(len, msgs)),
                  old_drain_msgs=[msgs.index(g) if g in msgs else -1 for g in got])))
