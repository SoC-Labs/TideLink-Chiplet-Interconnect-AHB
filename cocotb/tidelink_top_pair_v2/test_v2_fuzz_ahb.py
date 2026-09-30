"""Constrained-random peer traffic through the master die's ahb_sub port.

A single AHB-Lite master (one transfer in flight, as every chiplet CPU and DMA
is) issues a random mix of word WRITES and READS to a small window of the
slave die's memory, so addresses are reused and read-after-write hazards are
common. The TIMING of each next address phase is also random, covering the
shapes that have produced defects:
  - back-to-back (next NONSEQ in the first data-phase cycle),
  - early in a stalled data phase (1-3 cycles in),
  - late in a stalled data phase, after the W beat landed and before B
    (the Cortex-M4 STR-loop shape behind TL-053 / M4DUP),
  - after completion, with 0-40 idle cycles.
HPROT is non-bufferable (both chiplets tie [3:2]=00). HREADY toward the port
follows the chiplet rule: this port's HREADYOUT while the data phase is ours,
1 otherwise.

Scoreboard, all exact:
  - every read returns the model's value for that address (in-order master, so
    each completed write is visible to every later read),
  - AW handshakes at the master die's s_axi == writes issued, AR == reads
    issued (a duplicated or lost transfer fails even if memory ends right),
  - the W beats carry exactly the written values, in order,
  - no HRESP=ERROR, and the far memory equals the model at the end.
Optional (FUZZ_DIP=1): at random points write 0x27F00 then 0x27F07 to 0x208 on
a random die while traffic runs (the B19 trigger; harmless with TL-052), and
check the five data-channel credit maxima are unchanged.

Knobs (environment): FUZZ_SEED (default 1), FUZZ_N transfers (default 400),
FUZZ_DIP (default 0). Word accesses only: the bench's far-side BRAM model
writes whole words and ignores HSIZE.
"""
import os
import random

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

import test_v2_burst_encodings as be

NONSEQ, IDLE = 0b10, 0b00
WIN_OFF = 0x800                 # window inside the 4 KB tb BRAM
WIN_WORDS = 64                  # small window => frequent address reuse
TIMEOUT_PER_XFER = 20_000
CHANNELS = (("AW", "wlink_axiawFC"), ("W", "wlink_axiwFC"), ("B", "wlink_axibFC"),
            ("AR", "wlink_axiarFC"), ("R", "wlink_axirFC"))


def credmax(tb, side):
    out = {}
    for ch, inst in CHANNELS:
        n = getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)
        out[ch] = (int(n.fe_tx_credit_max.value), int(n.fe_rx_credit_max.value))
    return out


def plan(rng, n):
    """List of transfers; `next_at` says when the FOLLOWING address is presented:
    ('dphase', k) = k cycles into this transfer's data phase (k=0: back-to-back),
    ('after', g)  = g idle cycles after this transfer completes."""
    xs = []
    for _ in range(n):
        write = rng.random() < 0.6
        word = rng.randrange(WIN_WORDS)
        r = rng.random()
        if r < 0.25:
            nxt = ("dphase", 0)
        elif r < 0.40:
            nxt = ("dphase", rng.randint(1, 3))
        elif r < 0.65:
            nxt = ("dphase", rng.randint(8, 60))
        else:
            nxt = ("after", rng.choice([0, 0, 1, 2, 5, 17, 40]))
        xs.append(dict(write=write, off=WIN_OFF + 4 * word,
                       data=rng.getrandbits(32), hprot=rng.choice([0x1, 0x3]),
                       next_at=nxt))
    return xs


class FuzzMaster:
    def __init__(self, dut, log):
        self.d = dut
        self.log = log

    def _idle(self):
        d = self.d
        d.m_ahb_sub_hsel.value = 0
        d.m_ahb_sub_htrans.value = IDLE
        d.m_ahb_sub_hwrite.value = 0
        d.m_ahb_sub_hburst.value = 0
        d.m_ahb_sub_hprot.value = 0
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hready.value = 1

    def _addr(self, t):
        d = self.d
        d.m_ahb_sub_hsel.value = 1
        d.m_ahb_sub_haddr.value = (be.APERTURE_BASE + t["off"]) & 0xFFFF_FFFF
        d.m_ahb_sub_htrans.value = NONSEQ
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hburst.value = be.BUR_SINGLE
        d.m_ahb_sub_hprot.value = t["hprot"]
        d.m_ahb_sub_hwrite.value = 1 if t["write"] else 0
        d.m_ahb_sub_hready.value = 1

    async def run(self, xs, model, dips=None):
        """Drive xs in order; update `model` on write completion and check reads
        against it. `dips` is an optional coroutine hook called with the index of
        each completed transfer."""
        d = self.d
        self._idle()
        await RisingEdge(d.hclk)
        idx = 0                      # next transfer to present
        cur = None                   # transfer in data phase
        dcyc = 0                     # cycles spent in cur's data phase
        idle_left = None             # idle cycles still to insert after a completion
        presented = False
        errors, mism, done = [], [], 0
        self._addr(xs[0]); presented = True
        budget = TIMEOUT_PER_XFER * (len(xs) + 2)
        for cyc in range(budget):
            await ReadOnly()
            try:
                ro = int(d.m_ahb_sub_hreadyout.value)
            except ValueError:
                ro = 0
            hready = ro if cur is not None else 1
            if cur is not None and hready:
                try:
                    if int(d.m_ahb_sub_hresp.value):
                        errors.append((done, cur["off"]))
                except ValueError:
                    pass
                if not cur["write"]:
                    try:
                        rd = int(d.m_ahb_sub_hrdata.value)
                    except ValueError:
                        rd = None
                    want = model.get(cur["off"], 0)
                    if rd != want:
                        mism.append((done, hex(cur["off"]), rd, want))
            await RisingEdge(d.hclk)
            if cur is not None:
                dcyc += 1
            if hready:
                if cur is not None:              # cur completed
                    if cur["write"]:
                        model[cur["off"]] = cur["data"]
                    done += 1
                    kind, val = cur["next_at"]
                    idle_left = val if kind == "after" and not presented else None
                    cur = None
                    # Only when nothing is presented: an address accepted on this
                    # edge must get its HWDATA next cycle, so never stall here.
                    if dips is not None and not presented:
                        await dips(done)
                if presented:                    # presented address accepted
                    cur = xs[idx]; idx += 1
                    dcyc = 0; presented = False
                    if cur["write"]:
                        d.m_ahb_sub_hwdata.value = cur["data"]
                    d.m_ahb_sub_htrans.value = IDLE
                    d.m_ahb_sub_hsel.value = 0
                if cur is None and idx >= len(xs):
                    self._idle()
                    return dict(completed=True, cycles=cyc, done=done, errors=errors, mism=mism)
            if presented or idx >= len(xs):
                continue
            if cur is not None:
                kind, val = cur["next_at"]
                if kind == "dphase" and dcyc >= val:
                    self._addr(xs[idx]); presented = True
            else:
                if idle_left:
                    idle_left -= 1
                else:
                    self._addr(xs[idx]); presented = True
        self._idle()
        return dict(completed=False, cycles=budget, done=done, errors=errors, mism=mism)


@cocotb.test()
async def fuzz_peer_traffic(dut):
    seed = int(os.environ.get("FUZZ_SEED", "1"))
    n = int(os.environ.get("FUZZ_N", "400"))
    dip_on = os.environ.get("FUZZ_DIP", "0") == "1"
    rng = random.Random(seed)
    tb, _ = await be._bringup(dut)
    for i in range(WIN_WORDS):
        dut.u_s_mng_bram.mem[(WIN_OFF >> 2) + i].value = 0
    await ClockCycles(dut.hclk, 2)
    model = {}
    xs = plan(rng, n)
    nw = sum(1 for x in xs if x["write"])
    nr = n - nw

    census = be.BurstCensus(dut, tb.log)
    ar = {"n": 0}

    async def count_ar():
        while True:
            await RisingEdge(dut.hclk)
            await ReadOnly()
            try:
                if int(dut.u_master.s_axi_arvalid.value) and int(dut.u_master.s_axi_arready.value):
                    ar["n"] += 1
            except ValueError:
                pass
    mon = cocotb.start_soon(census.run(TIMEOUT_PER_XFER * (n + 4)))
    armon = cocotb.start_soon(count_ar())

    before = {s: credmax(tb, s) for s in ("m", "s")}
    dip_points = set(rng.sample(range(10, max(11, n - 10)), k=min(6, max(0, n - 20)))) if dip_on else set()
    dips_done = []

    async def dips(k):
        if k in dip_points:
            side = rng.choice(["m", "s"])
            apb = tb.apb(side)
            await apb.write(0x0208, 0x00027F00)
            await apb.write(0x0208, 0x00027F07)
            dips_done.append((k, side))

    res = await FuzzMaster(dut, tb.log).run(xs, model, dips if dip_on else None)
    await ClockCycles(dut.hclk, 3000)
    mon.kill(); armon.kill()

    wdata = [w for w, _ in census.w_beats]
    want_w = [x["data"] for x in xs if x["write"]]
    far = {off: be._bram_peek(dut, off) for off in model}
    far_bad = [(hex(o), far[o], v) for o, v in model.items() if far[o] != v]
    shapes = {}
    for x in xs:
        k = x["next_at"][0] if x["next_at"][0] == "after" else (
            "b2b" if x["next_at"][1] == 0 else ("early" if x["next_at"][1] <= 3 else "late"))
        shapes[k] = shapes.get(k, 0) + 1
    after = {s: credmax(tb, s) for s in ("m", "s")}

    tb.log.info(f"[fuzz] seed={seed} n={n} writes={nw} reads={nr} shapes={shapes} dip={dip_on} dips={dips_done}")
    tb.log.info(f"[fuzz] completed={res['completed']} cycles={res['cycles']} done={res['done']} "
                f"AW={len(census.aw_beats)} AR={ar['n']} W={len(wdata)} errors={len(res['errors'])} "
                f"read_mism={len(res['mism'])} far_bad={len(far_bad)}")
    if res["mism"]:
        tb.log.info(f"[fuzz] first read mismatches: {res['mism'][:5]}")
    if far_bad:
        tb.log.info(f"[fuzz] first far-memory mismatches: {far_bad[:5]}")
    if wdata != want_w:
        first = next((i for i, (a, b) in enumerate(zip(wdata, want_w)) if a != b), min(len(wdata), len(want_w)))
        tb.log.info(f"[fuzz] W stream diverges at beat {first}: got {[hex(v) for v in wdata[first:first + 4]]} "
                    f"want {[hex(v) for v in want_w[first:first + 4]]}")

    assert res["completed"], f"master did not finish ({res['done']}/{n} done)"
    assert not res["errors"], f"HRESP=ERROR on {res['errors'][:5]}"
    assert not res["mism"], f"{len(res['mism'])} read mismatches, first {res['mism'][:3]}"
    assert len(census.aw_beats) == nw, f"{len(census.aw_beats)} AW for {nw} writes"
    assert ar["n"] == nr, f"{ar['n']} AR for {nr} reads"
    assert wdata == want_w, "W beats differ from the written values"
    assert not far_bad, f"far memory differs from the model at {len(far_bad)} words"
    if dip_on:
        assert after == before, f"credit maxima changed across dips: {before} -> {after}"


@cocotb.test()
async def read_then_write_timing(dut):
    """Directed: READ(A) whose data phase stalls, then a WRITE(B) presented k
    cycles into that read's data phase, for a range of k. The read must return
    A's value and the write must be one AW with its own data."""
    tb, _ = await be._bringup(dut)
    for i in range(WIN_WORDS):
        dut.u_s_mng_bram.mem[(WIN_OFF >> 2) + i].value = 0
    await ClockCycles(dut.hclk, 2)
    census = be.BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(TIMEOUT_PER_XFER * 64))
    model = {}
    bad = []
    ks = [0, 1, 2, 3, 5, 10, 40]
    for n, k in enumerate(ks):
        a = WIN_OFF + 8 * n
        b = a + 4
        seed_val = 0x5EED0000 | n
        pre = [dict(write=True, off=a, data=seed_val, hprot=0x1, next_at=("after", 5))]
        res0 = await FuzzMaster(dut, tb.log).run(pre, model)
        aw0 = len(census.aw_beats)
        xs = [dict(write=False, off=a, data=0, hprot=0x1, next_at=("dphase", k)),
              dict(write=True, off=b, data=0xB0000000 | n, hprot=0x1, next_at=("after", 5))]
        res = await FuzzMaster(dut, tb.log).run(xs, model)
        await ClockCycles(dut.hclk, 1000)
        aw = len(census.aw_beats) - aw0
        ok = res["completed"] and not res["mism"] and aw == 1 and be._bram_peek(dut, b) == (0xB0000000 | n)
        tb.log.info(f"[rtw] k={k:<3} read_ok={not res['mism']} mism={res['mism']} AW_for_write={aw} "
                    f"far_b={be._bram_peek(dut, b):#010x} {'OK' if ok else 'BAD'}")
        if not ok:
            bad.append(k)
    mon.kill()
    assert not bad, f"read-then-write broken for k={bad}"
