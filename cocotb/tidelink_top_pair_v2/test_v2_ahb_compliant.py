"""AHB write paths on ahb_sub under a PROTOCOL-CORRECT bus model (R-03).

Why this exists. test_v2_burst_encodings.py showed every AHB transfer reaching
the XHB500 as TWO address phases (xhb NONSEQ=2 for one port NONSEQ) and leaving
as TWO AXI writes, the first carrying stale/zero data. Its master, however,
reads tidelink's own ahb_sub_hreadyout as the BUS ready during the ADDRESS
phase and holds NONSEQ while it is low. A real AHB bus does not: an address
phase completes on the global HREADY, which is the HREADYOUT of whichever
slave is in its DATA phase (1 when none is). tidelink deliberately drives
ahb_sub_hreadyout low in its own address phase (tidelink_top.sv, the
`ext_is_nonseq && !pipe_valid_r` arm) to register the address; a real bus
ignores that. So the doubled isolated write may be a bench artefact.

The case a real bus CAN produce is back-to-back peer transfers: while the peer
is stalling A's data phase the master holds B's address phase, and the
ethernet chiplet feeds the peer ahb_sub_hready = 1 during its own data phase
(nanosoc_eth_chiplet.sv:301, `dph_peer ? 1'b1 : ...`, to break a combinational
loop). tidelink must then ignore B until A completes.

Bus model here (single master, tidelink ahb_sub the only non-default slave):
  global HREADY = ahb_sub_hreadyout while a peer DATA phase is active, else 1.
  peer's HREADY input (m_ahb_sub_hready) = 1 always -- the chiplet rule gives
  1 in the peer data phase, and with no other slave the global HREADY is 1
  otherwise.
  At a rising edge with global HREADY=1: the pending data phase completes, the
  presented address phase (if not IDLE) is accepted and becomes the data phase,
  and the master then drives the next address phase and the accepted write's
  HWDATA (held until that data phase completes).

RESULTS (2026-09-23, ad09040): isolated SINGLE -> 1 AXI write; four
back-to-back SINGLEs -> 4, no bad intermediate state; INCR4 on the singles path
-> 4. So the doubled writes of test_v2_burst_encodings.py were its master, not
the RTL. The genuine defect is the burst arm (HPROT[3]=1) for WRITES: one AW,
eight W beats, beat 0's data at all four addresses (TL-050). Burst-arm READS
are correct and ~3.7x faster. TL-050 clears HPROT[3] toward the bridge for
writes only; incr4_hprot8 is the red/green arm (pre-fix FAIL, post-fix PASS).

Per case the census reports AHB address phases at the port and at the XHB500,
AXI AW/W beats, far-die BRAM contents after settle, and every intermediate
BRAM state seen (a transient wrong/zero value is a real hazard for a FIFO or
register target even if the final value is right).
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

import test_v2_burst_encodings as be

NONSEQ, SEQ, IDLE = 0b10, 0b11, 0b00


class CompliantAHBMaster:
    def __init__(self, dut):
        self.d = dut

    def _idle(self):
        d = self.d
        d.m_ahb_sub_hsel.value = 0
        d.m_ahb_sub_htrans.value = IDLE
        d.m_ahb_sub_hwrite.value = 0
        d.m_ahb_sub_hburst.value = 0
        d.m_ahb_sub_hprot.value = 0
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hready.value = 1

    def _drive_addr(self, t):
        d = self.d
        d.m_ahb_sub_hsel.value = 1
        d.m_ahb_sub_haddr.value = t["addr"] & 0xFFFF_FFFF
        d.m_ahb_sub_htrans.value = t["htrans"]
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hburst.value = t["hburst"]
        d.m_ahb_sub_hprot.value = t["hprot"]
        d.m_ahb_sub_hwrite.value = 0 if t.get("read") else 1
        d.m_ahb_sub_hready.value = 1

    async def run(self, transfers, timeout=be.BEAT_TIMEOUT * 20):
        """transfers: list of dicts {addr, data, htrans, hburst, hprot}."""
        d = self.d
        await RisingEdge(d.hclk)
        idx, dphase, done = 0, None, 0
        if transfers:
            self._drive_addr(transfers[0])
        else:
            self._idle()
        for cyc in range(timeout):
            await ReadOnly()
            try:
                ro = int(d.m_ahb_sub_hreadyout.value)
            except ValueError:
                ro = 0
            global_hready = ro if dphase is not None else 1
            if global_hready and dphase is not None and dphase.get("read"):
                try:
                    dphase["rdata"] = int(d.m_ahb_sub_hrdata.value)
                except ValueError:
                    dphase["rdata"] = None
            await RisingEdge(d.hclk)
            if not global_hready:
                continue
            if dphase is not None:
                done += 1
                dphase = None
            if idx < len(transfers):           # presented address phase accepted
                dphase = transfers[idx]
                idx += 1
                if not dphase.get("read"):
                    d.m_ahb_sub_hwdata.value = dphase["data"] & 0xFFFF_FFFF
            if idx < len(transfers):
                self._drive_addr(transfers[idx])
            else:
                d.m_ahb_sub_hsel.value = 0
                d.m_ahb_sub_htrans.value = IDLE
            if dphase is None and idx >= len(transfers):
                self._idle()
                return {"completed": True, "done": done, "cycles": cyc}
        self._idle()
        return {"completed": False, "done": done, "cycles": timeout}


def singles(base_off, datas, hprot=0):
    return [dict(addr=be.APERTURE_BASE + base_off + 4 * i, data=v, htrans=NONSEQ,
                 hburst=be.BUR_SINGLE, hprot=hprot) for i, v in enumerate(datas)]


def burst(base_off, datas, hburst, hprot):
    return [dict(addr=be.APERTURE_BASE + base_off + 4 * i, data=v,
                 htrans=NONSEQ if i == 0 else SEQ, hburst=hburst, hprot=hprot)
            for i, v in enumerate(datas)]


async def measure(dut, tb, label, transfers, base_off, n_words, seed=None):
    """Drive `transfers`; census; watch every intermediate BRAM state."""
    if seed is not None:
        for i, v in enumerate(seed):
            await be.BurstAHBSubMaster(dut).burst_write(
                be.APERTURE_BASE + base_off + 4 * i, [v], be.BUR_SINGLE, 0)
        await ClockCycles(dut.hclk, be.WRITE_SETTLE)
    census = be.BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(be.BEAT_TIMEOUT * 40 + be.WRITE_SETTLE))
    states, stop = [], {"v": False}

    async def sampler():
        last = None
        while not stop["v"]:
            await RisingEdge(dut.hclk)
            cur = tuple(be._bram_peek(dut, base_off + 4 * i) for i in range(n_words))
            if cur != last:
                states.append(cur)
                last = cur
    samp = cocotb.start_soon(sampler())
    res = await CompliantAHBMaster(dut).run(transfers)
    await ClockCycles(dut.hclk, be.WRITE_SETTLE)
    stop["v"] = True
    await RisingEdge(dut.hclk)
    mon.kill()
    final = [be._bram_peek(dut, base_off + 4 * i) for i in range(n_words)]
    want = [t["data"] for t in transfers]
    tb.log.info("=" * 78)
    tb.log.info(f"[compliant] {label}: {res}")
    tb.log.info(f"[compliant] {label}: {census.summary()}")
    tb.log.info(f"[compliant] {label}: W payloads="
                + str([(f"0x{x:08x}" if x is not None and x >= 0 else str(x), l)
                       for x, l in census.w_beats]))
    tb.log.info(f"[compliant] {label}: BRAM states traversed ({len(states)}):")
    for s in states:
        tb.log.info("    " + " ".join("None" if x is None else f"0x{x:08x}" for x in s))
    tb.log.info(f"[compliant] {label}: final={['0x%08x' % x if x is not None else None for x in final]} "
                f"want={['0x%08x' % x for x in want]}")
    tb.log.info("=" * 78)
    return dict(res=res, census=census, final=final, want=want, states=states)


def _aw(c):
    return list(c.aw_beats)


@cocotb.test()
async def isolated_single_hprot0(dut):
    """Isolated SINGLE write, shipping HPROT: expect ONE AXI write."""
    tb, m = await be._bringup(dut)
    r = await measure(dut, tb, "isolated SINGLE h0", singles(0x800, [0xA1A10001]), 0x800, 1)
    assert r["res"]["completed"], r["res"]
    assert r["final"] == r["want"], (r["final"], r["want"])
    assert len(_aw(r["census"])) == 1, f"isolated SINGLE produced AW={_aw(r['census'])}"


@cocotb.test()
async def back_to_back_singles_hprot0(dut):
    """Four back-to-back SINGLE writes (a memcpy), shipping HPROT: the case the
    chiplet's hready_to_peer=1 rule exposes. Expect exactly four AXI writes and
    no intermediate wrong value at any address."""
    tb, m = await be._bringup(dut)
    seed = [0x5EED0000 + i for i in range(4)]
    datas = [0xB2B20000 + i for i in range(4)]
    r = await measure(dut, tb, "b2b 4xSINGLE h0", singles(0x900, datas), 0x900, 4, seed=seed)
    assert r["res"]["completed"], r["res"]
    assert r["final"] == r["want"], (r["final"], r["want"])
    aw = _aw(r["census"])
    bad = [s for s in r["states"]
           if any(x is not None and x not in (seed[i], datas[i]) for i, x in enumerate(s))]
    assert len(aw) == 4, f"4 back-to-back SINGLEs produced AW={aw}"
    assert not bad, f"intermediate states outside {{seed, data}}: {bad}"


@cocotb.test()
async def incr4_hprot0(dut):
    """INCR4 on the shipping singles path: expect four single-beat AXI writes."""
    tb, m = await be._bringup(dut)
    datas = [0xC3C30000 + i for i in range(4)]
    r = await measure(dut, tb, "INCR4 h0", burst(0xA00, datas, be.BUR_INCR4, 0x0), 0xA00, 4)
    assert r["res"]["completed"], r["res"]
    assert r["final"] == r["want"], (r["final"], r["want"])
    assert len(_aw(r["census"])) == 4, f"INCR4 h0 produced AW={_aw(r['census'])}"


@cocotb.test()
async def incr4_hprot8(dut):
    """Cacheable INCR4 WRITE. Pre-TL-050 it took the XHB500 burst arm and landed
    beat 0's data at all four addresses. Post-fix the write must take the
    singles path (HPROT[3] cleared toward the bridge for writes): four
    single-beat AWs, correct data, no intermediate value outside {seed, data}."""
    tb, m = await be._bringup(dut)
    seed = [0x5EED1000 + i for i in range(4)]
    datas = [0xD4D40000 + i for i in range(4)]
    r = await measure(dut, tb, "INCR4 h8", burst(0xB00, datas, be.BUR_INCR4, 0x8), 0xB00, 4, seed=seed)
    assert r["res"]["completed"], r["res"]
    assert r["final"] == r["want"], (r["final"], r["want"])
    aw = _aw(r["census"])
    bad = [s for s in r["states"]
           if any(x is not None and x not in (seed[i], datas[i]) for i, x in enumerate(s))]
    assert not bad, f"intermediate states outside {{seed, data}}: {bad}"
    assert aw == [(0, 1)] * 4, (f"cacheable INCR4 WRITE produced AW={aw}; with TL-050 "
                                f"it must take the singles path (4 x awlen=0)")


def read_burst(base_off, n, hburst, hprot):
    return [dict(addr=be.APERTURE_BASE + base_off + 4 * i, data=0, read=True,
                 htrans=NONSEQ if i == 0 else SEQ, hburst=hburst, hprot=hprot)
            for i in range(n)]


async def _read_case(dut, label, base_off, hburst, hprot):
    tb, m = await be._bringup(dut)
    seed = [0x7E0D0000 + (hprot << 12) + i for i in range(4)]
    for i, v in enumerate(seed):
        await be.BurstAHBSubMaster(dut).burst_write(
            be.APERTURE_BASE + base_off + 4 * i, [v], be.BUR_SINGLE, 0)
    await ClockCycles(dut.hclk, be.WRITE_SETTLE)
    assert [be._bram_peek(dut, base_off + 4 * i) for i in range(4)] == seed, "seed failed"
    census = be.BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(be.BEAT_TIMEOUT * 40))
    tr = read_burst(base_off, 4, hburst, hprot)
    res = await CompliantAHBMaster(dut).run(tr)
    await ClockCycles(dut.hclk, 200)
    mon.kill()
    got = [t.get("rdata") for t in tr]
    tb.log.info("=" * 78)
    tb.log.info(f"[compliant] {label}: {res}")
    tb.log.info(f"[compliant] {label}: {census.summary()}")
    tb.log.info(f"[compliant] {label}: read={['0x%08x' % x if x is not None else None for x in got]} "
                f"want={['0x%08x' % x for x in seed]}")
    tb.log.info("=" * 78)
    return res, got, seed


@cocotb.test()
async def incr4_read_hprot0(dut):
    """INCR4 READ on the shipping singles path (control): expect the seeded words."""
    res, got, seed = await _read_case(dut, "INCR4 READ h0", 0xC00, be.BUR_INCR4, 0x0)
    assert res["completed"], res
    assert got == seed, (got, seed)


# Opt-in (R03_BURST_READ=1): exercising the burst arm in the aggregate gate would
# make coverage_check's instrument test fail -- it proves the coverage tool can
# report UNCOVERED by requiring exactly this arm to be unexercised. Gate it once
# that check has a different known-unexercised marker.
@cocotb.test(skip=os.environ.get("R03_BURST_READ") != "1")
async def incr4_read_hprot8(dut):
    """Cacheable INCR4 READ -- the burst arm, reachable on the compute chiplet,
    whose peer guard rejects bufferable/burst WRITES only."""
    res, got, seed = await _read_case(dut, "INCR4 READ h8", 0xD00, be.BUR_INCR4, 0x8)
    assert res["completed"], res
    assert got == seed, (got, seed)
