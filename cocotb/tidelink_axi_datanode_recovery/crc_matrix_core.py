"""CRC-injection matrix core: ONE invariant/classifier + node adapters + shot engine.

INVARIANT (VERIFICATION.md 2.1, checked by one scoreboard for every node):
  for every packet the injector corrupted and the receiver's CRC counter detected:
    the whole submitted stream (+ one clean message sent afterwards, so a wedged link shows up as
    LOST) is delivered EXACTLY ONCE, IN ORDER, payload-exact.
  A shot that FIRED without the CRC counter moving is ERROR (the harness cannot prove detection),
  never a pass.

CLASSES (classify()):
  EXACT  delivered == sent, once each, in order
  LOST   >=1 sent item never delivered (incl. a clean follower or the post-shot health message)
  STRAY  >=1 delivered item that was never sent (corrupted/zeroed payload), or an order violation
  DUP    >=1 item delivered more than once (replay delivered twice)
  INERT  nothing fired, nothing counted, stream exact (the wrong-DataID control's required answer)
  ERROR  instrument/precondition failure: fired != expected, or fired with crc_delta != expected
Precedence: ERROR > LOST > STRAY > DUP > (EXACT | INERT).

Node adapters ("sb" sideband 0xA1; "AW","W","B","AR","R" = AXI 0x80-0x84) expose the same five
operations so the shot engine (run_shot) is node-agnostic.

Truth sources (never the pi_* gate alone):
  fired      tb_top.sv ri_hit_{m,s}: packets the RTL injector (err_inj term) actually corrupted
  crc_delta  receiver FCSM CRC counter over APB (node base + 0x20), the HW-visible counter
  delivery   sb: receiver RX FIFO read-out; AXI write nodes: slave-side AHB BRAM write bus monitor;
             AXI read nodes: values returned to the AHB master + BRAM read-bus monitor (DUP)
"""
import json
import os

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import PairV2TB, run_bringup_full
import test_sideband_crc_replay as sbm      # helpers only; its @cocotb.test objects are never re-exported
from test_axi_datanode_gaps import (AHBSubMaster, APER_BASE, _axi_node, _slave_bram_peek,
                                    AXI_FC_NODES, _wlink)
from cocotb.handle import Force, Release

APB_ERRINJ = 0x023C
CRC_CNT_OFF = 0x20
SM_CTRL_OFF = 0x14

# node -> (data_id, APB node base, transmitting die for an a2b / master-initiated access, kind)
NODE = {
    "sb": dict(did=0xA1, base=0x1700, kind="sb"),
    "AW": dict(did=0x80, base=0x1000, kind="axi", op="write", tx="m", inst="wlink_axiawFC"),
    "W":  dict(did=0x81, base=0x1100, kind="axi", op="write", tx="m", inst="wlink_axiwFC"),
    "B":  dict(did=0x82, base=0x1200, kind="axi", op="write", tx="s", inst="wlink_axibFC"),
    "AR": dict(did=0x83, base=0x1300, kind="axi", op="read",  tx="m", inst="wlink_axiarFC"),
    "R":  dict(did=0x84, base=0x1400, kind="axi", op="read",  tx="s", inst="wlink_axirFC"),
}
AXI_BASES = [NODE[n]["base"] for n in ("AW", "W", "B", "AR", "R")]
E = os.environ.get


# ---------------------------------------------------------------------------------------------
# The classifier (single implementation)
# ---------------------------------------------------------------------------------------------
def classify(sent, got, *, fired, expect_fired, crc_delta, expect_crc):
    """-> (cls, detail).  sent/got are lists of hashable items (tuples).  expect_fired/expect_crc:
    required shot / CRC-count totals (0/0 = the INERT contract)."""
    sk = list(sent)
    cnt = [0] * len(sk)
    stray = []
    for g in got:
        if g in sk:
            cnt[sk.index(g)] += 1
        else:
            stray.append(g)
    lost = sum(1 for c in cnt if c == 0)
    dup = sum(c - 1 for c in cnt if c > 1)
    in_order = list(got) == sk
    d = dict(lost=lost, dup=dup, stray=len(stray), in_order=in_order, fired=fired,
             crc_delta=crc_delta, expect_fired=expect_fired, expect_crc=expect_crc,
             delivered=len(got), sent=len(sk))
    err = []
    if fired != expect_fired:
        err.append(f"fired {fired} != expected {expect_fired}")
    if crc_delta != expect_crc:
        err.append(f"crc_delta {crc_delta} != expected {expect_crc}"
                   + (" (SHOT FIRED WITHOUT COUNTER MOVE)" if fired and not crc_delta else ""))
    if err:
        d["why"] = "; ".join(err)
        return "ERROR", d
    if lost:
        return "LOST", d
    if stray or (not in_order and not dup):
        return "STRAY", d
    if dup:
        return "DUP", d
    return ("INERT" if expect_fired == 0 and expect_crc == 0 else "EXACT"), d


# ---------------------------------------------------------------------------------------------
# tb_top helpers
# ---------------------------------------------------------------------------------------------
def tbv(dut, name, v=None):
    h = getattr(dut, name)
    if v is None:
        return int(h.value)
    h.value = v


async def clr_counters(dut):
    tbv(dut, "pi_clr", 1)
    await ClockCycles(dut.hclk, 50)
    tbv(dut, "pi_clr", 0)


def errinj_word(did, byte, bit):
    return (1 << 24) | ((bit & 7) << 16) | ((byte & 0xFF) << 8) | (did & 0xFF)


async def arm_edge(tb, tx, did, byte, bit):
    """rev2hw.arm: write 0 (settle), then the armed word (0->1 edge in the TX link clock)."""
    apb = tb.apb(tx)
    await apb.write(APB_ERRINJ, 0)
    await ClockCycles(tb.dut.hclk, 400)
    assert await apb.read(APB_ERRINJ) == 0, "0x23C does not read 0"
    w = errinj_word(did, byte, bit)
    await apb.write(APB_ERRINJ, w)
    await ClockCycles(tb.dut.hclk, 400)
    rb = await apb.read(APB_ERRINJ)
    assert rb == w, f"0x23C readback 0x{rb:08x} != 0x{w:08x}"


async def disarm(tb, tx):
    await tb.apb(tx).write(APB_ERRINJ, 0)
    await ClockCycles(tb.dut.hclk, 400)


async def pi_window(tb, tx, did, tgt, byte, bit):
    """Position window: clear counters, point the pi gate at packet `tgt` of DataID `did`,
    program byte/bit/DataID through the REAL APB register, let the gate own err_inj_smack."""
    dut = tb.dut
    await clr_counters(dut)
    tbv(dut, "pi_did", did)
    tbv(dut, "pi_tgt", tgt)
    tbv(dut, "pi_tgt2", -1)
    tbv(dut, "pi_rep_en", 0)
    await tb.apb(tx).write(APB_ERRINJ, 0)
    await ClockCycles(dut.hclk, 400)
    tbv(dut, "pi_en_" + tx, 1)
    await tb.apb(tx).write(APB_ERRINJ, errinj_word(did, byte, bit))
    await ClockCycles(dut.hclk, 400)


async def pi_close(tb, tx):
    tbv(tb.dut, "pi_en_" + tx, 0)
    tbv(tb.dut, "pi_tgt2", -1)
    await disarm(tb, tx)


async def apb_rmw_crc_disable(tb, side, base, off):
    """SM_CONTROL (base+0x14) bit16 = disable_crc, read-modify-write, readback-checked."""
    apb = tb.apb(side)
    v = await apb.read(base + SM_CTRL_OFF)
    v = (v | (1 << 16)) if off else (v & ~(1 << 16))
    await apb.write(base + SM_CTRL_OFF, v)
    await ClockCycles(tb.dut.hclk, 50)
    rb = await apb.read(base + SM_CTRL_OFF)
    assert ((rb >> 16) & 1) == (1 if off else 0), \
        f"{side} node 0x{base:04x} SM_CONTROL readback 0x{rb:08x}: disable_crc did not take"


async def read_crc_defaults(tb):
    """-> {(side, base): bit16} straight after bring-up, before any CRC write."""
    out = {}
    for side in ("m", "s"):
        for base in [NODE["sb"]["base"]] + AXI_BASES:
            out[(side, base)] = ((await tb.apb(side).read(base + SM_CTRL_OFF)) >> 16) & 1
    return out


# ---------------------------------------------------------------------------------------------
# Node adapters
# ---------------------------------------------------------------------------------------------
class SbAdapter:
    """Sideband 0xA1 through the onchip ahb_tx path.  direction ab: tx=m, rx=s."""
    name = "sb"
    did = 0xA1
    kind = "sb"

    def __init__(self, dut, direction):
        self.dut, self.direction = dut, direction
        self.tx, self.rx = ("m", "s") if direction == "ab" else ("s", "m")

    async def setup(self, crc_on=True):
        self.ctx = await sbm.bringup(self.dut, self.direction)
        self.tb = self.ctx.tb
        self.defaults = await read_crc_defaults(self.tb)
        if not crc_on:
            await sbm.set_rx_crc_disable(self.ctx, True)

    def make_items(self, size):
        # size S: 1 message of 4 words; L: 2 messages of 8 words; X: 4 messages of 8 words
        if size == "S":
            return [sbm.mkmsg(self.ctx.tag(), 2)]
        n = 2 if size == "L" else 4
        return [sbm.mkmsg(self.ctx.tag(), sbm.MSG_LEN) for _ in range(n)]

    def fresh_items(self):
        return [sbm.mkmsg(self.ctx.tag(), 2)]

    def keyed(self, items):
        return [tuple(m) for m in items]

    async def issue(self, items, gap):
        await sbm.send(self.ctx, items, gap)

    async def collect(self, items):
        return [tuple(m) for m in await sbm.collect(self.ctx, items)]

    async def crc(self):
        return await sbm.crc(self.ctx)

    def packets_per_item(self, items):
        return None      # sideband: 1 wlink packet per message word (verified by census)


class AxiAdapter:
    """AXI data node via master-initiated peer accesses (m ahb_sub -> XHB500 -> link -> s mng BRAM).
    AW/W/AR transmit on m, B/R on s (the slave die's ahb_sub is tied off in this bench, so there
    is no b2a-initiated direction).  Writes are POSTED (bufferable) so followers launch inside the
    NACK->replay window; reads are blocking single-outstanding (no followers possible)."""
    kind = "axi"
    direction = "ab"

    def __init__(self, dut, node):
        self.dut, self.name = dut, node
        n = NODE[node]
        self.did, self.base, self.op = n["did"], n["base"], n["op"]
        self.tx = n["tx"]
        self.rx = "s" if self.tx == "m" else "m"
        self.events = []        # BRAM bus events: ("W", addr, data) / ("R", addr)
        self.rd_returned = []
        self.issue_failed = False

    async def setup(self, crc_on=True):
        self.tb = PairV2TB(self.dut)
        self.master = AHBSubMaster(self.dut)
        await run_bringup_full(self.tb)
        assert await self.tb.wait_cr_crack(), "no CR/CRACK"
        await ClockCycles(self.dut.hclk, 500)
        self.defaults = await read_crc_defaults(self.tb)
        # TL-018: the shipping reset value on FCSM 0-4 is CRC ON (bit16=0) in FPGA and ASIC alike, so crc_on needs NO
        # APB write (the matrix runs the shipping default; ctl_ship_default asserts the reset value).  The CRC-OFF
        # control (ctl_detect_sense) writes bit16=1 explicitly, readback-checked.  CM_AXI_CRC_APB_ON=1 restores the old
        # behaviour (write bit16=0) for a build with +define+TIDELINK_FCSM_CRC_OFF_AT_RESET.
        if not crc_on:
            for side in ("m", "s"):
                for base in AXI_BASES:
                    await apb_rmw_crc_disable(self.tb, side, base, True)
        elif E("CM_AXI_CRC_APB_ON") == "1":
            for side in ("m", "s"):
                for base in AXI_BASES:
                    await apb_rmw_crc_disable(self.tb, side, base, False)
        self._mon = cocotb.start_soon(self._bram_monitor())
        # clean sanity write proves the path before anything is armed
        await self.master.write(APER_BASE + 0x100, 0xC0FFEE01)
        await ClockCycles(self.dut.hclk, 2000)
        assert _slave_bram_peek(self.dut, 0x100) == 0xC0FFEE01, "clean sanity write failed"
        self._seq = 0

    def apply_mutant(self):
        """CM_MUTANT=fixg_off: pre-Fix-G RTL (socl_l7_reached_link_data forced 0 => bring-up forgive armed
        forever, a detected error never NACKs).  Applied AFTER the clean precondition/census so the
        instrument is proven on unmutated RTL and only the shot window runs mutated."""
        if E("CM_MUTANT") == "fixg_off":
            for side in ("m", "s"):
                for inst in AXI_FC_NODES:
                    _axi_node(self.tb, side, inst).socl_l7_reached_link_data.value = Force(0)

    async def _bram_monitor(self):
        """Slave-die AHB BRAM bus: record every write (addr, data) and read (addr)."""
        b = self.dut.u_s_mng_bram
        prev = None
        while True:
            await RisingEdge(self.dut.hclk)
            try:
                if prev is not None:                       # data phase of last cycle's write
                    self.events.append(("W", prev, int(b.HWDATA.value)))
                    prev = None
                if int(b.HTRANS.value) & 2:
                    a = int(b.HADDR.value) & 0xFFF
                    if int(b.HWRITE.value):
                        prev = a
                    else:
                        self.events.append(("R", a))
            except ValueError:
                pass

    def _tag(self):
        self._seq += 1
        return 0xA5000000 | (self._seq << 12) | ((0x9D1 * self._seq) & 0xFFF)

    def make_items(self, size):
        n = {"S": 4, "L": 8, "X": 16}[size]
        base = 0x200 + 0x40 * (self._seq % 8)
        out = []
        for i in range(n):
            out.append(("W" if self.op == "write" else "R", base + 4 * i, self._tag() ^ (i * 0x01010101)))
        self._base_used = base
        return out

    def fresh_items(self):
        return [("W" if self.op == "write" else "R", 0x7C0, self._tag())]

    def keyed(self, items):
        return [(k, a, d) for (k, a, d) in items]

    async def issue(self, items, gap):
        self._mark = len(self.events)
        self.rd_returned = []
        if self.op == "read":
            for (_, a, d) in items:                        # preload the far-side terminus
                self.dut.u_s_mng_bram.mem[a >> 2].value = d
            await ClockCycles(self.dut.hclk, 4)
            self._mark = len(self.events)
        for (_, a, d) in items:
            if self.op == "write":
                try:
                    await self.master.write_bufferable(APER_BASE + a, d, self.dut.u_master, timeout=40000)
                except (TimeoutError, RuntimeError) as e:
                    # the posted-write path wedged / errored: that is a LOST outcome (the rest of the
                    # stream is never issued), not a harness exception.
                    self.dut._log.info(f"[cm] write 0x{a:x}: {e}")
                    self.issue_failed = True
                    break
            else:
                try:
                    r = await self.master.read(APER_BASE + a, timeout=40000)
                except (TimeoutError, RuntimeError) as e:
                    r = None
                    self.dut._log.info(f"[cm] read 0x{a:x}: {e}")
                self.rd_returned.append(("R", a, r))
            if gap:
                await ClockCycles(self.dut.hclk, gap)

    async def collect(self, items, quiet=3000, lost_wait=40000):
        """Writes: wait until the bram has seen every sent write then stays quiet (or idle
        `lost_wait`).  Reads: the returned values are final; wait `quiet` for a late duplicate."""
        want = len(items)
        idle = stable = 0
        last = None
        while True:
            if self.op == "write":
                n = sum(1 for e in self.events[self._mark:] if e[0] == "W")
            else:
                n = sum(1 for e in self.events[self._mark:] if e[0] == "R")
            if n == last:
                idle += 100; stable += 100
            else:
                idle = stable = 0
            last = n
            if (n >= want and stable >= quiet) or idle >= lost_wait:
                break
            await ClockCycles(self.dut.hclk, 100)
        ev = self.events[self._mark:]
        if self.op == "write":
            return [("W", a, d) for (k, a, d) in ev if k == "W"]
        got = list(self.rd_returned)
        seen = {}
        for (_, a) in [e for e in ev if e[0] == "R"]:           # extra bram reads == replayed AR (DUP)
            seen[a] = seen.get(a, 0) + 1
            if seen[a] > 1:
                got.append(("R", a, self.dut.u_s_mng_bram.mem[a >> 2].value.to_unsigned()))
        return got

    async def crc(self):
        return (await self.tb.apb(self.rx).read(self.base + CRC_CNT_OFF)) & 0xFFFF

    def packets_per_item(self, items):
        return 1


def make_adapter(dut, node, direction="ab"):
    return SbAdapter(dut, direction) if node == "sb" else AxiAdapter(dut, node)


# ---------------------------------------------------------------------------------------------
# Shot engine
# ---------------------------------------------------------------------------------------------
def position_index(pos, n):
    """packet index of the corrupted packet inside an n-packet stream."""
    return {"first": 0, "second": 1, "mid": max(2, n // 4) if n > 4 else 1,
            "second_to_last": n - 2, "last": n - 1}[pos]


async def census(ad, size):
    """Warm-up + one clean pass: proves the instrument (clean stream exact, CRC +0, no real
    injections) and returns (items, packets of this DataID the stream takes)."""
    tbv(ad.dut, "pi_did", ad.did)
    warm = ad.fresh_items()
    await ad.issue(warm, 4)
    g = await ad.collect(warm)
    assert g == ad.keyed(warm), f"PRECONDITION: warm-up not exact: {g}"
    items = ad.make_items(size)
    await clr_counters(ad.dut)
    c0 = await ad.crc()
    await ad.issue(items, 4)
    got = await ad.collect(items)
    n = tbv(ad.dut, "pi_cnt_" + ad.tx)
    assert got == ad.keyed(items), f"PRECONDITION: clean stream not exact: {got}"
    assert ((await ad.crc()) - c0) & 0xFFFF == 0, "PRECONDITION: CRC counted on clean traffic"
    assert tbv(ad.dut, "ri_hit_" + ad.tx) == 0, "PRECONDITION: injector fired on clean traffic"
    return n


async def run_shot(ad, *, size, pos, gap, byte=5, bit=0, real_injector=False, did=None,
                   expect_fired=1, expect_crc=None, tgt=None, census_n=None):
    """One armed shot over a fresh stream.  Returns (cls, detail, items)."""
    dut = ad.dut
    did = ad.did if did is None else did
    n = census_n if census_n is not None else await census(ad, size)
    items = ad.make_items(size)
    if tgt is None:
        if ad.kind == "axi":          # n packets / len(items) ops = packets per op (verified == 1 in census)
            tgt = position_index(pos, len(items)) * max(1, n // len(items))
        else:
            tgt = position_index(pos, n)
    fresh = ad.fresh_items()
    c0 = await ad.crc()
    if hasattr(ad, "apply_mutant"):
        ad.apply_mutant()
    if real_injector:
        await clr_counters(dut)
        await arm_edge(ad.tb, ad.tx, did, byte, bit)
    else:
        await pi_window(ad.tb, ad.tx, did, tgt, byte, bit)
    await ad.issue(items, gap)
    got = await ad.collect(items)
    fired = tbv(dut, "ri_hit_" + ad.tx)
    npk = tbv(dut, "pi_cnt_" + ad.tx)
    if real_injector:
        await disarm(ad.tb, ad.tx)
    else:
        await pi_close(ad.tb, ad.tx)
    c1 = await ad.crc()
    # health: a fresh clean item after the shot must still be delivered exactly once
    await ad.issue(fresh, 4)
    got_f = await ad.collect(fresh)
    det = (c1 - c0) & 0xFFFF
    # a replay may land after the health item was sent: take the post-collect counter too
    ec = expect_fired if expect_crc is None else expect_crc
    cls, d = classify(ad.keyed(items) + ad.keyed(fresh), list(got) + list(got_f),
                      fired=fired, expect_fired=expect_fired, crc_delta=det, expect_crc=ec)
    d.update(node=ad.name, dir=ad.direction, pos=pos, size=size, gap=gap, tgt=tgt, stream_pkts=npk,
             census_pkts=n, followers=(n - 1 - tgt) if not real_injector else None, byte=byte, bit=bit)
    return cls, d, items


def emit(dut, name, cls, detail, ok, expect):
    rec = dict(case=name, cls=cls, expect=expect, ok=ok, profile=E("CM_PROFILE", "zero"),
               mutant=E("CM_MUTANT", ""), **detail)
    dut._log.info("[cm] RESULT " + json.dumps(rec, default=str))
    return rec


def judge(cls, expect):
    """expect: EXACT | INERT | NOT_EXACT (mutant arms: a LOST/STRAY/DUP is required) | ANY."""
    if expect == "NOT_EXACT":
        return cls in ("LOST", "STRAY", "DUP")
    if expect == "ANY":
        return True
    return cls == expect
