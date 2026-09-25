"""M4DUP: a peer write pre-latched during our own stalled data phase must not
become two AXI writes.

ext_is_nonseq has no HREADY term (the 2026-07-05 comb-loop fix), so a NONSEQ
the master presents while its PREVIOUS data phase to this port is still
stalled is pre-latched into the pipe. Before the fix that pre-latch armed
wr_hold_r, which masked ahb_sub_hreadyout at the moment XHB500 took the
pre-latched phase (when the previous write's B returned): XHB500 issued it with
the previous beat's HWDATA while the master stayed stalled, then the pipe
latched the same pending phase again. A Cortex-M4 STR loop does exactly this
(the ALU and branch put the next peer NONSEQ a few cycles into the stall):
compute measured 2N-1 AXI writes for N stores, the extra one stale, final
memory exact (handoff-crcpair-20260924/M4DUP.md).

The master here is AHB-Lite compliant: after an address is accepted it drives
IDLE, and LATE cycles into the data phase -- after that write's W beat has
landed, while its B is still outstanding -- it raises NONSEQ for the next write
and holds it until HREADY. (A master may change IDLE to NONSEQ during a waited
transfer; once NONSEQ it must hold.) HREADY toward the port follows the chiplet
rule: this port's HREADYOUT while the data phase is ours, 1 otherwise.

Checks, counted at the master die's s_axi: one AW per store, the W beats carry
exactly the stored values in order (no stale beat), and the far memory ends
exact. The control presents each NONSEQ in the first data-phase cycle
(back-to-back), which was never affected.
Pre-fix (b8879b3): late_nonseq_loop FAILS (15 AW for 8 stores); fixed: both PASS.
"""
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

import test_v2_burst_encodings as be

NONSEQ, IDLE = 0b10, 0b00
N_STORES = 8
LATE = 20                   # cycles into the stalled data phase; W lands in ~2
BASE_OFF = 0xA00            # inside the 4 KB tb BRAM
TIMEOUT = 400_000
_TAG = {"n": 0}


class LateNonseqMaster:
    """Single non-bufferable writes; the next NONSEQ appears `late` cycles into
    the previous data phase (late=0: in its first cycle, i.e. back-to-back)."""

    def __init__(self, dut, late):
        self.d = dut
        self.late = late

    def _idle(self):
        d = self.d
        d.m_ahb_sub_hsel.value = 0
        d.m_ahb_sub_htrans.value = IDLE
        d.m_ahb_sub_hwrite.value = 0
        d.m_ahb_sub_hburst.value = 0
        d.m_ahb_sub_hprot.value = 0
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hready.value = 1

    def _addr(self, addr):
        d = self.d
        d.m_ahb_sub_hsel.value = 1
        d.m_ahb_sub_haddr.value = addr & 0xFFFF_FFFF
        d.m_ahb_sub_htrans.value = NONSEQ
        d.m_ahb_sub_hsize.value = 2
        d.m_ahb_sub_hburst.value = be.BUR_SINGLE
        d.m_ahb_sub_hprot.value = 0x1          # data, non-bufferable (both chiplets tie [3:2]=00)
        d.m_ahb_sub_hwrite.value = 1
        d.m_ahb_sub_hready.value = 1

    async def run(self, writes):
        """writes: list of (addr, data). Returns stats incl. whether each NONSEQ
        after the first was really presented while the previous one stalled."""
        d = self.d
        self._idle()
        await RisingEdge(d.hclk)
        idx, dphase, dcyc, presented = 0, None, 0, False
        stalled_presents = 0
        self._addr(writes[0][0])
        presented = True
        for cyc in range(TIMEOUT):
            await ReadOnly()
            try:
                ro = int(d.m_ahb_sub_hreadyout.value)
            except ValueError:
                ro = 0
            hready = ro if dphase is not None else 1
            await RisingEdge(d.hclk)
            if dphase is not None:
                dcyc += 1
            if hready:
                if dphase is not None:
                    dphase = None
                if presented:                  # the presented address was accepted
                    dphase = writes[idx]
                    d.m_ahb_sub_hwdata.value = dphase[1] & 0xFFFF_FFFF
                    idx += 1
                    dcyc = 0
                    presented = False
                    self.d.m_ahb_sub_htrans.value = IDLE
                    self.d.m_ahb_sub_hsel.value = 0
                if dphase is None and idx >= len(writes):
                    self._idle()
                    return {"completed": True, "cycles": cyc, "stalled_presents": stalled_presents}
            # present the next NONSEQ once `late` cycles of the current data phase have passed
            if not presented and idx < len(writes) and (dphase is None or dcyc >= self.late):
                if dphase is not None and not hready:
                    stalled_presents += 1
                self._addr(writes[idx][0])
                presented = True
        self._idle()
        return {"completed": False, "cycles": TIMEOUT, "stalled_presents": stalled_presents}


async def scenario(dut, late, label):
    tb, _ = await be._bringup(dut)
    _TAG["n"] += 1
    tag = _TAG["n"] & 0xFF
    for i in range(N_STORES):          # the BRAM persists across tests: clear, then tag
        dut.u_s_mng_bram.mem[(BASE_OFF >> 2) + i].value = 0
    await ClockCycles(dut.hclk, 2)
    writes = [(be.APERTURE_BASE + BASE_OFF + 4 * i, 0xC4000000 | (tag << 16) | (i << 8) | (0x5A ^ i))
              for i in range(N_STORES)]
    census = be.BurstCensus(dut, tb.log)
    mon = cocotb.start_soon(census.run(TIMEOUT + 5000))
    res = await LateNonseqMaster(dut, late).run(writes)
    await ClockCycles(dut.hclk, 3000)
    mon.kill()
    landed = [be._bram_peek(dut, BASE_OFF + 4 * i) for i in range(N_STORES)]
    wdata = [w for w, _ in census.w_beats]
    tb.log.info(f"[{label}] late={late} completed={res['completed']} cycles={res['cycles']} "
                f"stalled_presents={res['stalled_presents']} AW={len(census.aw_beats)} "
                f"W={len(wdata)}")
    tb.log.info(f"[{label}] W data  = {[hex(x) for x in wdata]}")
    tb.log.info(f"[{label}] wanted  = {[hex(v) for _, v in writes]}")
    tb.log.info(f"[{label}] landed  = {[hex(x) if x is not None else None for x in landed]}")
    assert res["completed"], f"master did not finish: {res}"
    if late:
        # instrument check: the shape under test really happened
        assert res["stalled_presents"] >= N_STORES - 1, \
            f"only {res['stalled_presents']} NONSEQs were presented during a stall; the bench did not produce the M4 shape"
    assert landed == [v for _, v in writes], f"final memory wrong: {landed}"
    assert len(census.aw_beats) == N_STORES, \
        f"{len(census.aw_beats)} AXI writes for {N_STORES} stores (M4DUP duplicates)"
    assert wdata == [v for _, v in writes], "W beats are not exactly the stored values in order"


@cocotb.test()
async def back_to_back_control(dut):
    await scenario(dut, 0, "b2b")


@cocotb.test()
async def late_nonseq_loop(dut):
    await scenario(dut, LATE, "late")
