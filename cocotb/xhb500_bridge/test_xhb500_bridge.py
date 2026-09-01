"""XHB500 bridge-pair unit tests -- the inbound AXI->AHB path and both error paths.

WHY (2026-08-26)
    The first coverage database over this repository's whole simulation corpus
    reported `xhb500_axi_to_ahb_bridge_chiplet_mst_core_xin` -- the INBOUND
    cross-die bridge, the direction a far die uses to reach our memory -- at
    FSM 0.00%.  Re-measured per-database (the merged report silently drops
    designs whose shape differs from the base design), it is 0.00% in ALL 42
    databases that contain it.  Its companion response mux `..._core_h_xout`
    likewise.  On the outbound side `..._slv_core_resp` reached 20% -- two of
    ten transitions -- with RESP_FSM_ERROR and RESP_FSM_LOCK_ERROR never
    entered.

    That is the machinery the N1 / TL-042 / TL-044 backstops sit on top of:
    every one of those recovery mechanisms is specified in terms of an AHB
    ERROR response, and nothing had ever produced one through these bridges.

WHAT IS AND IS NOT REACHABLE IN SILICON
    Two of the paths covered here are provably dead as INTEGRATED, and the
    tests say so rather than pretending otherwise:
      * src/rtl/tidelink_top.sv:3319 ties u_xhb_mng.hexokay to 1'b0, so
        AXI_RESP_EXOKAY can never be produced by the inbound bridge in this
        SoC -- an AXI exclusive read across the die boundary always returns
        OKAY.  test_mst_shipping_tie_makes_exclusive_read_non_exclusive
        asserts exactly that, and test_mst_hexokay_becomes_rresp_exokay
        proves the mux underneath it is not itself broken.
      * src/rtl/tidelink_top.sv:3169 ties u_xhb_sub.hmastlock to 1'b0, so
        RESP_FSM_LOCK_ERROR is unreachable as integrated.  Same treatment.

RED PROOF -- every test here has been demonstrated FAILING
    A test that cannot fail is worse than no test.  Eleven single-line
    mutations were applied to the DUT sources (deps/xhb500/generated/**, which
    is gitignored and locally staged, so nothing was committed), the suite was
    re-run, and the sources were restored and verified byte-identical by
    digest (find|md5sum|md5sum = 391c23fd3cc0af55f3828bce50ae1924, unchanged
    before and after).  Reproduce with the mutations listed below.

      M1  core_xin      nxt_addr_11_0_q <= ar.axaddr[11:0]   (no burst advance)
                        -> burst_read
      M2  core_xin      if(ar_unaligned & ar_nonmodif) -> if(1'b0)
                        -> unaligned_nonmodifiable_read
      M3  core_h_xout   "| hs.hresp)" -> "| 1'b0)"
                        -> ahb_error_becomes_rresp_slverr, ..._bresp_slverr
      M4  core_h_xout   hexokay ternary -> AXI_RESP_OKAY
                        -> hexokay_becomes_rresp_exokay
      M5  slv_core_resp assign axi_err = 1'b0
                        -> slv_axi_slverr_becomes_two_cycle_ahb_error,
                           slv_error_then_normal_transfer_recovers,
                           slv_axi_slverr_on_write, slv_back_to_back_after_error,
                           slv_locked_pipelined_behind_error
      M6  slv_core_resp every "if (hmastlock)" -> "if (1'b0)"
                        -> slv_hmastlock_forces_lock_error,
                           slv_locked_pipelined_behind_error / _behind_normal
      M7  core_h_xout   acc_hrdata -> 32'h0
                        -> single_read, burst_read, unaligned, error_recovery
      M8  core_xin      ahb_w.hwdata -> 32'h0            -> burst_write
      M9  slv_core_resp assign hexokay = 1'b0            -> slv_exokay_sets_hexokay
      M10 core_h_xout   hexokay ternary -> AXI_RESP_EXOKAY
                        -> mst_shipping_tie_makes_exclusive_read_non_exclusive
                           (and 6 others)
      M11 slv_core_resp assign axi_err = rvalid | bvalid
                        -> slv_shipping_tie_makes_locked_transfer_unreachable
                           (and 3 others)

    Note that M4 does NOT redden test_mst_shipping_tie_..., and M6 does NOT
    redden test_slv_shipping_tie_...: those two tests assert the ABSENCE of
    the feature, so the mutation that removes it leaves them green and the
    mutation that forces it on (M10 / M11) is what catches them.  That
    asymmetry is the point of having both halves.

Copyright 2026, SoC Labs (www.soclabs.org)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, ClockCycles

CLK_NS = 10

# AHB HTRANS
IDLE, BUSY, NONSEQ, SEQ = 0, 1, 2, 3
# AXI xRESP
OKAY, EXOKAY, SLVERR, DECERR = 0, 1, 2, 3
# AXI AxBURST
FIXED, INCR, WRAP = 0, 1, 2


def _i(sig):
    """int() of a signal, treating any x/z as a hard test failure.

    Used wherever an x would be a real defect (a response code, a valid, an
    address that is being acted on).  Do NOT relax this into _lax to make a
    test pass -- an x propagating out of a bridge is exactly the class of bug
    this bench exists to catch.
    """
    v = sig.value
    if v.is_resolvable:
        return int(v)
    raise AssertionError(f"signal {sig._name} is unresolvable: {v!r}")


def _lax(sig, default=0):
    """int() of a signal, returning `default` when it is x/z.

    Only for signals that are legitimately undriven between transfers: the
    XHB500 xreg bypass slice leaves HWDATA/HWSTRB floating while its payload
    register is empty, and an AHB manager is not required to drive the data
    bus outside a data phase.  Anything a test asserts on goes through _i.
    """
    v = sig.value
    return int(v) if v.is_resolvable else default


# ---------------------------------------------------------------------------
# u_mst side: AHB manager port responder
# ---------------------------------------------------------------------------

class AhbSlaveForMst:
    """AHB subordinate answering u_mst's manager port.

    Zero wait states for OKAY.  For an address in `err_addrs` it produces the
    AHB two-cycle ERROR response (HREADY=0/HRESP=1 then HREADY=1/HRESP=1),
    because a one-cycle error is not legal AHB and a manager is entitled to
    behave differently under it -- a test built on an illegal stimulus proves
    nothing about silicon.

    Phase model, one pass per cycle N:
      * the address phase the DUT presented in cycle N-1 was ACCEPTED at the
        edge into cycle N iff this model drove HREADY=1 during cycle N-1;
      * an accepted address phase's data phase is cycle N.
    """

    def __init__(self, dut, mem=None):
        self.dut = dut
        self.mem = mem if mem is not None else {}
        self.err_addrs = set()
        self.exokay = False
        self.beats = []          # (addr, write, size, burst) accepted, in order
        self.stopped = False

    async def run(self):
        """One pass per cycle.  DRIVE AT THE EDGE, SAMPLE IN ReadOnly.

        The order matters and is not style.  Driving from the ReadOnly ->
        NextTimeStep pattern lands the write half-way through the cycle, so
        HRDATA changes underneath a DUT that has already produced RVALID for
        that cycle and underneath any monitor that samples at the start of it.
        That cost this bench a whole debug pass: reads came back one beat late
        while writes -- sampled in the same skewed frame -- looked correct.
        Driving immediately after RisingEdge makes each output stable for
        exactly one whole cycle, which is what an AHB subordinate does.
        """
        d = self.dut
        out = (1, 0, 0, 0)       # HREADY, HRESP, HRDATA, HEXOKAY for this cycle
        dphase = None            # address phase whose DATA phase is this cycle
        err_stage = 0

        while not self.stopped:
            await RisingEdge(d.clk)
            hready_cur, hresp_cur, hrdata_cur, hexokay_cur = out
            d.m_hready.value = hready_cur
            d.m_hresp.value = hresp_cur
            d.m_hrdata.value = hrdata_cur
            d.m_hexokay.value = hexokay_cur

            await ReadOnly()
            htrans = _lax(d.m_htrans, IDLE)
            if htrans & 2:
                # A live address phase: everything the subordinate acts on
                # must be driven.  An x here is a bridge defect, not noise.
                aph = (htrans, _i(d.m_haddr), _i(d.m_hwrite),
                       _i(d.m_hsize), _i(d.m_hburst))
            else:
                aph = None

            # Commit the write whose data phase is the cycle now ending.
            if dphase is not None and dphase[2] and hready_cur and not hresp_cur:
                assert d.m_hwdata.value.is_resolvable, \
                    f"HWDATA is x in the data phase of a write to {dphase[1]:#x}"
                assert d.m_hwstrb.value.is_resolvable, \
                    f"HWSTRB is x in the data phase of a write to {dphase[1]:#x}"
                hwdata = _i(d.m_hwdata)
                hwstrb = _i(d.m_hwstrb)
                word = dphase[1] & ~3
                new = self.mem.get(word, 0)
                for lane in range(4):
                    if hwstrb & (1 << lane):
                        new &= ~(0xFF << (8 * lane))
                        new |= (hwdata & (0xFF << (8 * lane)))
                self.mem[word] = new & 0xFFFFFFFF

            # An address phase presented in this cycle is ACCEPTED at the next
            # edge iff HREADY was high through this cycle; otherwise the
            # current data phase is extended by a wait state.
            if hready_cur:
                nxt_dphase, nxt_err = aph, 0
                if aph is not None:
                    self.beats.append((aph[1], aph[2], aph[3], aph[4]))
            else:
                nxt_dphase, nxt_err = dphase, err_stage

            if nxt_dphase is None:
                out = (1, 0, 0, 0)
            else:
                addr = nxt_dphase[1]
                if addr in self.err_addrs:
                    # AHB two-cycle ERROR: HREADY low with HRESP high, then
                    # HREADY high with HRESP high.  A one-cycle error is not
                    # legal AHB and a manager is entitled to behave differently
                    # under it -- a test built on an illegal stimulus proves
                    # nothing about silicon.
                    if nxt_err == 0:
                        hready, hresp = 0, 1
                        nxt_err = 1
                    else:
                        hready, hresp = 1, 1
                else:
                    hready, hresp = 1, 0
                out = (hready, hresp, self.mem.get(addr & ~3, 0),
                       1 if self.exokay else 0)

            dphase, err_stage = nxt_dphase, nxt_err


class AxiMasterForMst:
    """AXI manager driving u_mst's subordinate port. Always ready for R and B."""

    def __init__(self, dut):
        self.dut = dut
        self.r = []              # (rid, rdata, rresp, rlast)
        self.b = []              # (bid, bresp)
        self.stopped = False

    def idle(self):
        d = self.dut
        for n in ("m_awvalid", "m_arvalid", "m_wvalid", "m_wlast",
                  "m_awlock", "m_arlock"):
            getattr(d, n).value = 0
        d.m_rready.value = 1
        d.m_bready.value = 1
        d.m_awburst.value = INCR
        d.m_arburst.value = INCR
        d.m_awsize.value = 2
        d.m_arsize.value = 2
        d.m_awlen.value = 0
        d.m_arlen.value = 0
        d.m_awid.value = 0
        d.m_arid.value = 0
        d.m_awaddr.value = 0
        d.m_araddr.value = 0
        d.m_awprot.value = 0
        d.m_arprot.value = 0
        d.m_awcache.value = 2
        d.m_arcache.value = 2
        d.m_wstrb.value = 0xF
        d.m_wdata.value = 0
        d.m_awaddr.value = 0

    async def monitor(self):
        d = self.dut
        while not self.stopped:
            await RisingEdge(d.clk)
            await ReadOnly()
            if _lax(d.m_rvalid) and _lax(d.m_rready):
                self.r.append((_i(d.m_rid), _i(d.m_rdata),
                               _i(d.m_rresp), _i(d.m_rlast)))
            if _lax(d.m_bvalid) and _lax(d.m_bready):
                self.b.append((_i(d.m_bid), _i(d.m_bresp)))

    async def _await_ready(self, ready_sig):
        """Complete a VALID/READY handshake whose VALID is ALREADY aligned.

        Alignment matters: a payload written mid-cycle becomes visible to the
        DUT immediately, so the transfer can be accepted at the very next edge.
        Every drive in this class therefore happens straight after a RisingEdge
        so that it is stable for exactly one whole cycle -- without that, each
        AR and AW was issued TWICE and the reads returned two R beats.
        """
        while True:
            await ReadOnly()
            rdy = _lax(ready_sig)
            await RisingEdge(self.dut.clk)
            if rdy:
                return

    async def read(self, addr, arlen=0, arsize=2, arcache=0b0010,
                   arburst=INCR, arid=0, arlock=0):
        d = self.dut
        await RisingEdge(d.clk)
        d.m_araddr.value = addr
        d.m_arlen.value = arlen
        d.m_arsize.value = arsize
        d.m_arcache.value = arcache
        d.m_arburst.value = arburst
        d.m_arid.value = arid
        d.m_arlock.value = arlock
        d.m_arvalid.value = 1
        await self._await_ready(d.m_arready)
        d.m_arvalid.value = 0
        d.m_arlock.value = 0

    async def write(self, addr, beats, awlen=None, awsize=2, awcache=0b0010,
                    awburst=INCR, awid=0, awlock=0, wstrb=0xF):
        """AW and W are presented together: u_mst only asserts WREADY in FIRST
        when AWVALID and WVALID are both high (core_xin.sv FIRST arm)."""
        d = self.dut
        if awlen is None:
            awlen = len(beats) - 1
        await RisingEdge(d.clk)
        d.m_awaddr.value = addr
        d.m_awlen.value = awlen
        d.m_awsize.value = awsize
        d.m_awcache.value = awcache
        d.m_awburst.value = awburst
        d.m_awid.value = awid
        d.m_awlock.value = awlock
        d.m_awvalid.value = 1

        aw_done = False
        for i, data in enumerate(beats):
            d.m_wdata.value = data
            d.m_wstrb.value = wstrb
            d.m_wlast.value = 1 if i == len(beats) - 1 else 0
            d.m_wvalid.value = 1
            while True:
                await ReadOnly()
                wrdy = _i(d.m_wready)
                awrdy = _i(d.m_awready)
                await RisingEdge(d.clk)
                if awrdy and not aw_done:
                    aw_done = True
                    d.m_awvalid.value = 0
                    d.m_awlock.value = 0
                if wrdy:
                    break
        d.m_wvalid.value = 0
        d.m_wlast.value = 0
        if not aw_done:
            d.m_awvalid.value = 0
            d.m_awlock.value = 0


# ---------------------------------------------------------------------------
# u_slv side: AHB manager driver + AXI subordinate responder
# ---------------------------------------------------------------------------

class AhbMasterForSlv:
    """AHB manager driving u_slv's subordinate port.

    Records (hreadyout, hresp, hexokay) for every data-phase cycle so a test
    can assert the exact two-cycle shape of an AHB ERROR response rather than
    just its final value.
    """

    def __init__(self, dut):
        self.dut = dut
        self.dphase_log = []     # (hreadyout, hresp, hexokay, hrdata)

    def idle(self):
        d = self.dut
        d.s_hsel.value = 0
        d.s_htrans.value = IDLE
        d.s_hwrite.value = 0
        d.s_hsize.value = 2
        d.s_hburst.value = 0
        d.s_hmastlock.value = 0
        d.s_hexcl.value = 0
        d.s_hmaster.value = 0
        d.s_hnonsec.value = 0
        d.s_hprot.value = 0b0000001
        d.s_haddr.value = 0
        d.s_hwdata.value = 0

    async def _addr_phase(self, addr, write, size, hmastlock, hexcl, htrans):
        d = self.dut
        await RisingEdge(d.clk)
        d.s_hsel.value = 1
        d.s_haddr.value = addr
        d.s_htrans.value = htrans
        d.s_hwrite.value = 1 if write else 0
        d.s_hsize.value = size
        d.s_hmastlock.value = 1 if hmastlock else 0
        d.s_hexcl.value = 1 if hexcl else 0
        while True:
            await ReadOnly()
            rdy = _i(d.s_hreadyout)
            await RisingEdge(d.clk)
            if rdy:
                return

    async def _data_phase(self, wdata=None):
        """Hold the data phase until HREADYOUT, logging every cycle."""
        d = self.dut
        d.s_hsel.value = 0
        d.s_htrans.value = IDLE
        d.s_hmastlock.value = 0
        d.s_hexcl.value = 0
        if wdata is not None:
            d.s_hwdata.value = wdata
        while True:
            await ReadOnly()
            rdy = _i(d.s_hreadyout)
            self.dphase_log.append((rdy, _i(d.s_hresp), _lax(d.s_hexokay),
                                    _lax(d.s_hrdata)))
            rdata = _lax(d.s_hrdata)
            await RisingEdge(d.clk)
            if rdy:
                return rdata

    async def sequence(self, ops):
        """Back-to-back (pipelined) AHB: the next address phase is presented in
        the same cycle as the current data phase.

        A non-pipelined manager can only ever leave the RESP FSM through
        ...->IDLE_BUSY, which is why RESP_FSM_ERROR->RESP_FSM_SEQ_NSEQ,
        ERROR->LOCK_ERROR and SEQ_NSEQ->LOCK_ERROR stayed uncovered even after
        the error paths themselves were reached.  A real AHB manager pipelines,
        so these arms are live in silicon and worth exercising.

        During the first cycle of a two-cycle ERROR response HREADY is low, so
        the next address phase is simply held -- which is what AHB requires and
        what this loop does by construction.

        ops: list of dicts {addr, write, data, size, hmastlock, hexcl}
        returns: per-op list of (hreadyout, hresp, hexokay, hrdata) data-phase
                 samples.
        """
        d = self.dut
        results = [[] for _ in ops]
        idx = 0                  # next op to present in the address phase
        dp = None                # index of the op whose data phase is this cycle

        await RisingEdge(d.clk)
        while True:
            if idx < len(ops):
                o = ops[idx]
                d.s_hsel.value = 1
                d.s_haddr.value = o["addr"]
                d.s_htrans.value = NONSEQ
                d.s_hwrite.value = 1 if o.get("write") else 0
                d.s_hsize.value = o.get("size", 2)
                d.s_hmastlock.value = 1 if o.get("hmastlock") else 0
                d.s_hexcl.value = 1 if o.get("hexcl") else 0
            else:
                d.s_hsel.value = 0
                d.s_htrans.value = IDLE
                d.s_hmastlock.value = 0
                d.s_hexcl.value = 0
            if dp is not None and ops[dp].get("write"):
                d.s_hwdata.value = ops[dp].get("data", 0)

            await ReadOnly()
            rdy = _i(d.s_hreadyout)
            if dp is not None:
                results[dp].append((rdy, _i(d.s_hresp), _lax(d.s_hexokay),
                                    _lax(d.s_hrdata)))
            await RisingEdge(d.clk)

            if rdy:
                if idx < len(ops):
                    dp = idx
                    idx += 1
                else:
                    dp = None
            if dp is None and idx >= len(ops):
                break

        self.idle()
        return results

    async def read(self, addr, size=2, hmastlock=0, hexcl=0):
        self.dphase_log = []
        await self._addr_phase(addr, False, size, hmastlock, hexcl, NONSEQ)
        return await self._data_phase()

    async def write(self, addr, data, size=2, hmastlock=0, hexcl=0):
        self.dphase_log = []
        await self._addr_phase(addr, True, size, hmastlock, hexcl, NONSEQ)
        return await self._data_phase(wdata=data)


class AxiSlaveForSlv:
    """AXI subordinate answering u_slv's manager port.

    `rresp` / `bresp` are test-settable so an AXI error can be injected into
    the outbound path, which is the only way to reach RESP_FSM_ERROR.
    """

    def __init__(self, dut, mem=None):
        self.dut = dut
        self.mem = mem if mem is not None else {}
        self.rresp = OKAY
        self.bresp = OKAY
        self.aw_seen = []
        self.ar_seen = []
        self.stopped = False

    async def run(self):
        """DRIVE AT THE EDGE, SAMPLE IN ReadOnly -- see AhbSlaveForMst.run.

        Here it is load-bearing for a different reason: `hreadyout` inside the
        RESP FSM is `beat_done & ~axi_err`, and beat_done is rvalid & rready.
        Raising RVALID half-way through a cycle therefore makes HREADYOUT
        glitch mid-cycle, which an AHB manager sampling at the start of the
        cycle never sees -- the transfer completes in the DUT and the bench
        waits forever.  Two tests hung on exactly that.
        """
        d = self.dut
        out = dict(awready=1, arready=1, wready=1,
                   rvalid=0, rdata=0, rresp=OKAY, rlast=0,
                   bvalid=0, bresp=OKAY)
        rq = []          # queued read beats (addr, is_last)
        wpend = 0        # write bursts whose W has completed, awaiting B

        while not self.stopped:
            await RisingEdge(d.clk)
            d.s_awready.value = out["awready"]
            d.s_arready.value = out["arready"]
            d.s_wready.value = out["wready"]
            d.s_rvalid.value = out["rvalid"]
            d.s_rdata.value = out["rdata"]
            d.s_rresp.value = out["rresp"]
            d.s_rlast.value = out["rlast"]
            d.s_bvalid.value = out["bvalid"]
            d.s_bresp.value = out["bresp"]
            d.s_rid.value = 0
            d.s_bid.value = 0

            await ReadOnly()
            if _lax(d.s_arvalid) and out["arready"]:
                araddr, arlen, arsize = (_i(d.s_araddr), _i(d.s_arlen),
                                         _i(d.s_arsize))
                self.ar_seen.append((araddr, arlen, arsize))
                for i in range(arlen + 1):
                    rq.append((araddr + i * (1 << arsize), i == arlen))
            if _lax(d.s_awvalid) and out["awready"]:
                self.aw_seen.append((_i(d.s_awaddr), _i(d.s_awlen),
                                     _i(d.s_awsize)))
            if _lax(d.s_wvalid) and out["wready"]:
                addr = self.aw_seen[-1][0] if self.aw_seen else 0
                self.mem[addr & ~3] = _lax(d.s_wdata)
                if _lax(d.s_wlast):
                    wpend += 1
            r_taken = out["rvalid"] and _lax(d.s_rready)
            b_taken = out["bvalid"] and _lax(d.s_bready)

            if r_taken or not out["rvalid"]:
                if rq:
                    addr, last = rq.pop(0)
                    out["rvalid"] = 1
                    out["rdata"] = self.mem.get(addr & ~3, 0)
                    out["rresp"] = self.rresp
                    out["rlast"] = 1 if last else 0
                else:
                    out["rvalid"] = 0
            if b_taken or not out["bvalid"]:
                if wpend:
                    wpend -= 1
                    out["bvalid"] = 1
                    out["bresp"] = self.bresp
                else:
                    out["bvalid"] = 0


# ---------------------------------------------------------------------------
# Common bring-up
# ---------------------------------------------------------------------------

async def bringup(dut, mst_mem=None, slv_mem=None):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    axm = AxiMasterForMst(dut)
    ahs = AhbSlaveForMst(dut, mst_mem)
    ahm = AhbMasterForSlv(dut)
    axs = AxiSlaveForSlv(dut, slv_mem)

    axm.idle()
    ahm.idle()
    dut.resetn.value = 0
    dut.m_hready.value = 1
    dut.m_hresp.value = 0
    dut.m_hexokay.value = 0
    dut.m_hrdata.value = 0
    dut.s_awready.value = 1
    dut.s_arready.value = 1
    dut.s_wready.value = 1
    dut.s_rvalid.value = 0
    dut.s_bvalid.value = 0
    dut.s_rid.value = 0
    dut.s_bid.value = 0
    dut.s_rlast.value = 0
    dut.s_rdata.value = 0
    dut.s_rresp.value = 0
    dut.s_bresp.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 3)

    cocotb.start_soon(ahs.run())
    cocotb.start_soon(axm.monitor())
    cocotb.start_soon(axs.run())
    await ClockCycles(dut.clk, 3)
    return axm, ahs, ahm, axs


def _fsm_state(dut):
    return int(dut.u_mst.u_core.u_core_xin.fsm_state.value)


# ===========================================================================
# INBOUND BRIDGE (AXI -> AHB) -- core_xin FSM
# ===========================================================================

@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_single_read_returns_memory(dut):
    """A single-beat AXI read reaches AHB as one NONSEQ and returns the word.

    This is the first AXI AR ever driven into the peer-side bridge in this
    repository, so it also proves the bench itself transacts before the
    burst/unaligned/error tests build on it.
    """
    mem = {0x1000_0100: 0xDEADBEEF}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)

    await axm.read(0x1000_0100)
    await ClockCycles(dut.clk, 12)

    reads = [b for b in ahs.beats if not b[1]]
    assert len(reads) == 1, f"expected exactly 1 AHB read beat, got {ahs.beats}"
    assert reads[0][0] == 0x1000_0100, f"AHB address {reads[0][0]:#x}"
    assert reads[0][2] == 2, f"AHB HSIZE should be word, got {reads[0][2]}"
    assert len(axm.r) == 1, f"expected 1 R beat, got {axm.r}"
    rid, rdata, rresp, rlast = axm.r[0]
    assert rdata == 0xDEADBEEF, f"RDATA {rdata:#x} != 0xdeadbeef"
    assert rresp == OKAY, f"RRESP {rresp} != OKAY"
    assert rlast == 1, "RLAST must be set on a single-beat read"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_burst_read_enters_READ_state(dut):
    """A 4-beat INCR read drives core_xin FIRST->READ->...->FIRST.

    Asserts the address sequence the bridge generates, the per-beat data, and
    that RLAST lands on the last beat only -- not merely that the FSM moved.
    """
    base = 0x2000_0000
    mem = {base + 4 * i: 0xA0000000 + i for i in range(4)}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)

    seen_read = []

    async def watch():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            seen_read.append(_fsm_state(dut))

    cocotb.start_soon(watch())

    await axm.read(base, arlen=3, arcache=0b0010)
    await ClockCycles(dut.clk, 25)

    READ = 1
    assert READ in seen_read, "core_xin never entered the READ state"

    reads = [b for b in ahs.beats if not b[1]]
    assert [r[0] for r in reads] == [base, base + 4, base + 8, base + 12], \
        f"AHB burst addresses wrong: {[hex(r[0]) for r in reads]}"
    assert len(axm.r) == 4, f"expected 4 R beats, got {len(axm.r)}"
    assert [r[1] for r in axm.r] == [0xA0000000 + i for i in range(4)], \
        f"R data wrong: {[hex(r[1]) for r in axm.r]}"
    assert [r[3] for r in axm.r] == [0, 0, 0, 1], \
        f"RLAST must be set on the final beat only: {[r[3] for r in axm.r]}"
    assert all(r[2] == OKAY for r in axm.r), "all beats should be OKAY"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_burst_write_enters_WRITE_state(dut):
    """A 2-beat INCR write drives core_xin FIRST->WRITE->FIRST and lands data.

    Asserts the AHB-side memory contents, not just the FSM: a WRITE state that
    is entered but writes the wrong address would pass a state-only check.
    """
    base = 0x3000_0040
    mem = {}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)

    seen = []

    async def watch():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            seen.append(_fsm_state(dut))

    cocotb.start_soon(watch())

    await axm.write(base, [0x11112222, 0x33334444], awlen=1)
    await ClockCycles(dut.clk, 25)

    WRITE = 2
    assert WRITE in seen, "core_xin never entered the WRITE state"
    assert mem.get(base) == 0x11112222, f"beat 0 landed as {mem.get(base)}"
    assert mem.get(base + 4) == 0x33334444, f"beat 1 landed as {mem.get(base + 4)}"
    assert len(axm.b) == 1, f"expected exactly one B response, got {axm.b}"
    assert axm.b[0][1] == OKAY, f"BRESP {axm.b[0][1]} != OKAY"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_unaligned_nonmodifiable_read_enters_UNM_READ(dut):
    """An unaligned NON-MODIFIABLE read must be split, not silently widened.

    AxCACHE[1]=0 forbids the bridge from turning a 3-byte access into a word
    access.  core_xin's UNM_READ arm exists for exactly this and has never run.
    The test asserts the SPLIT (a byte beat then a halfword beat, both inside
    the addressed word) and that byte lane 0 -- which was never requested --
    comes back as zero rather than as fetched memory.
    """
    base = 0x4000_0000
    mem = {base: 0x44332211}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)

    seen = []

    async def watch():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            seen.append(_fsm_state(dut))

    cocotb.start_soon(watch())

    await axm.read(base + 1, arlen=0, arsize=2, arcache=0b0000)
    await ClockCycles(dut.clk, 25)

    UNM_READ = 3
    assert UNM_READ in seen, "core_xin never entered the UNM_READ state"

    reads = [b for b in ahs.beats if not b[1]]
    assert len(reads) == 2, \
        f"unaligned non-modifiable read must split into 2 beats, got {reads}"
    assert (reads[0][0], reads[0][2]) == (base + 1, 0), \
        f"first beat should be a BYTE at +1, got addr={reads[0][0]:#x} size={reads[0][2]}"
    assert (reads[1][0], reads[1][2]) == (base + 2, 1), \
        f"second beat should be a HALFWORD at +2, got addr={reads[1][0]:#x} size={reads[1][2]}"

    assert len(axm.r) == 1, f"expected a single R beat, got {axm.r}"
    _rid, rdata, rresp, rlast = axm.r[0]
    assert rdata & 0xFFFFFF00 == 0x44332200, \
        f"bytes 1..3 must come from memory, got {rdata:#010x}"
    assert rdata & 0xFF == 0, \
        f"byte lane 0 was never requested and must read 0, got {rdata:#010x}"
    assert rresp == OKAY and rlast == 1


# ===========================================================================
# INBOUND BRIDGE response mux -- core_h_xout
# ===========================================================================

@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_ahb_error_becomes_rresp_slverr(dut):
    """An AHB ERROR on a read becomes RRESP=SLVERR, and the bridge recovers.

    The recovery half matters more than the error half: a bridge that returned
    SLVERR forever after one error would pass an error-only check.  This is the
    N1/TL-042 precondition -- the backstops are specified in terms of an AHB
    ERROR actually propagating as an AXI error response.
    """
    good = 0x5000_0000
    bad = 0x5000_0040
    mem = {good: 0xC0FFEE00, bad: 0xBADBAD00}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)
    ahs.err_addrs.add(bad)

    await axm.read(good)
    await ClockCycles(dut.clk, 12)
    await axm.read(bad)
    await ClockCycles(dut.clk, 15)
    await axm.read(good)
    await ClockCycles(dut.clk, 15)

    assert len(axm.r) == 3, f"expected 3 R beats, got {axm.r}"
    assert axm.r[0][2] == OKAY, f"clean read before the error: RRESP={axm.r[0][2]}"
    assert axm.r[1][2] == SLVERR, \
        f"AHB ERROR must surface as RRESP=SLVERR, got {axm.r[1][2]}"
    assert axm.r[2][2] == OKAY, \
        f"bridge did not recover: RRESP={axm.r[2][2]} on the clean read after the error"
    assert axm.r[2][1] == 0xC0FFEE00, "post-error read returned the wrong data"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_ahb_error_becomes_bresp_slverr(dut):
    """An AHB ERROR on a write becomes BRESP=SLVERR and does not corrupt memory."""
    bad = 0x6000_0080
    mem = {bad: 0x0}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)
    ahs.err_addrs.add(bad)

    await axm.write(bad, [0x5A5A5A5A], awlen=0)
    await ClockCycles(dut.clk, 20)

    assert len(axm.b) == 1, f"expected one B response, got {axm.b}"
    assert axm.b[0][1] == SLVERR, \
        f"AHB ERROR on a write must surface as BRESP=SLVERR, got {axm.b[0][1]}"
    assert mem.get(bad) == 0x0, \
        "an errored AHB write must not have updated the target"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_hexokay_becomes_rresp_exokay(dut):
    """HEXOKAY on the AHB data phase becomes RRESP=EXOKAY.

    This proves the response mux at core_h_xout.sv:176 is not broken.  It does
    NOT prove exclusive access works in this SoC -- see the next test, which
    asserts the opposite under the shipping tie-off.
    """
    base = 0x7000_0000
    mem = {base: 0x1234_5678}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)

    await axm.read(base)                      # OKAY
    await ClockCycles(dut.clk, 12)
    ahs.exokay = True
    await axm.read(base, arlock=1)            # EXOKAY
    await ClockCycles(dut.clk, 12)
    ahs.exokay = False
    await axm.read(base)                      # OKAY again
    await ClockCycles(dut.clk, 12)

    assert len(axm.r) == 3, f"expected 3 R beats, got {axm.r}"
    assert axm.r[0][2] == OKAY
    assert axm.r[1][2] == EXOKAY, \
        f"HEXOKAY must surface as RRESP=EXOKAY, got {axm.r[1][2]}"
    assert axm.r[2][2] == OKAY, "response mux stuck at EXOKAY after HEXOKAY dropped"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_mst_shipping_tie_makes_exclusive_read_non_exclusive(dut):
    """With HEXOKAY tied low -- as src/rtl/tidelink_top.sv:3319 ties it -- an
    AXI exclusive read across the die boundary returns OKAY, never EXOKAY.

    An AXI manager reads OKAY on an exclusive read as "the exclusive monitor
    is not present", so exclusive access silently degrades across this bridge
    in silicon.  This test exists to make that a stated, checked property
    rather than an accident nobody has looked at.
    """
    base = 0x7100_0000
    mem = {base: 0x0BADC0DE}
    axm, ahs, _ahm, _axs = await bringup(dut, mst_mem=mem)
    ahs.exokay = False                        # the shipping tie-off

    await axm.read(base, arlock=1)
    await ClockCycles(dut.clk, 15)

    assert len(axm.r) == 1, f"expected 1 R beat, got {axm.r}"
    assert axm.r[0][2] == OKAY, \
        f"with HEXOKAY tied low an exclusive read must return OKAY, got {axm.r[0][2]}"
    assert axm.r[0][2] != EXOKAY


# ===========================================================================
# OUTBOUND BRIDGE (AHB -> AXI) -- slv_core_resp FSM
# ===========================================================================

def _slv_state(dut):
    return int(dut.u_slv.u_core.u_resp.resp_fsm_state.value)


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_axi_slverr_becomes_two_cycle_ahb_error(dut):
    """An AXI SLVERR on a read becomes a protocol-legal two-cycle AHB ERROR.

    RESP_FSM_ERROR has never been entered in any simulation in this repository.
    The assertion is on the SHAPE of the response, not just its value: AHB
    requires HRESP=ERROR for two cycles with HREADYOUT low then high.  A bridge
    that produced a one-cycle error would still set hresp and would still pass
    a value-only check, while wedging a real AHB manager.
    """
    base = 0x100
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={base: 0xFEEDFACE})

    axs.rresp = SLVERR
    await ahm.read(base)
    log = list(ahm.dphase_log)

    err_cycles = [c for c in log if c[1] == 1]
    assert len(err_cycles) >= 2, \
        f"AHB ERROR must be two cycles of HRESP=1, saw {len(err_cycles)}: {log}"
    assert err_cycles[0][0] == 0, \
        f"first ERROR cycle must have HREADYOUT=0, log={log}"
    assert err_cycles[-1][0] == 1, \
        f"last ERROR cycle must have HREADYOUT=1, log={log}"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_error_then_normal_transfer_recovers(dut):
    """After an AHB ERROR the port must accept the next transfer normally.

    A PASSING ESCAPE TEST IS NOT A SAFETY TEST: this asserts the RESP FSM
    leaves ERROR and that the normal path still works, which is the property
    the TL-044 dead-gate work is about.
    """
    base = 0x200
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={base: 0x5150_5150})

    axs.rresp = SLVERR
    await ahm.read(base)
    assert any(c[1] == 1 for c in ahm.dphase_log), "no ERROR was produced"

    axs.rresp = OKAY
    data = await ahm.read(base)
    assert all(c[1] == 0 for c in ahm.dphase_log), \
        f"port still errors after recovery: {ahm.dphase_log}"
    assert data == 0x5150_5150, f"post-error read returned {data:#x}"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_axi_slverr_on_write_becomes_ahb_error(dut):
    """An AXI BRESP=SLVERR on a write becomes an AHB ERROR response."""
    base = 0x300
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={})

    axs.bresp = SLVERR
    await ahm.write(base, 0xABCD_1234)
    assert any(c[1] == 1 for c in ahm.dphase_log), \
        f"BRESP=SLVERR did not produce an AHB ERROR: {ahm.dphase_log}"

    axs.bresp = OKAY
    await ahm.write(base, 0x1111_2222)
    assert all(c[1] == 0 for c in ahm.dphase_log), \
        f"write port still errors after recovery: {ahm.dphase_log}"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_hmastlock_forces_lock_error(dut):
    """HMASTLOCK on an AHB transfer is rejected with ERROR and never reaches AXI.

    RESP_FSM_LOCK_ERROR has never been entered.  The bridge does not support
    locked transfers, and the contract is that it refuses them rather than
    passing them through unlocked -- so the test asserts BOTH that an ERROR
    came back AND that no AR/AW was issued.  The second half is the one that
    would catch a bridge that errored but forwarded anyway.
    """
    base = 0x400
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={base: 0xAAAA_5555})

    ar_before = len(axs.ar_seen)
    await ahm.read(base, hmastlock=1)

    assert any(c[1] == 1 for c in ahm.dphase_log), \
        f"a locked transfer must be answered with ERROR: {ahm.dphase_log}"
    assert len(axs.ar_seen) == ar_before, \
        f"locked transfer leaked onto AXI as {axs.ar_seen[ar_before:]}"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_shipping_tie_makes_locked_transfer_unreachable(dut):
    """With HMASTLOCK tied low -- as src/rtl/tidelink_top.sv:3169 ties it -- the
    same transfer completes normally, so RESP_FSM_LOCK_ERROR is dead as
    integrated.  Stated and checked, not assumed.
    """
    base = 0x500
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={base: 0x9999_1111})

    axs.rresp = OKAY
    data = await ahm.read(base, hmastlock=0)
    assert all(c[1] == 0 for c in ahm.dphase_log), \
        f"unlocked transfer must not error: {ahm.dphase_log}"
    assert data == 0x9999_1111
    assert len(axs.ar_seen) == 1, "unlocked transfer did not reach AXI"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_exokay_sets_hexokay(dut):
    """RRESP=EXOKAY from AXI raises HEXOKAY on the AHB data phase."""
    base = 0x600
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={base: 0x2468_ACE0})

    axs.rresp = OKAY
    await ahm.read(base, hexcl=1)
    assert all(c[2] == 0 for c in ahm.dphase_log), \
        f"HEXOKAY asserted without an AXI EXOKAY: {ahm.dphase_log}"

    axs.rresp = EXOKAY
    await ahm.read(base, hexcl=1)
    assert any(c[2] == 1 for c in ahm.dphase_log), \
        f"RRESP=EXOKAY did not raise HEXOKAY: {ahm.dphase_log}"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_back_to_back_transfer_after_error_is_accepted(dut):
    """A transfer pipelined behind an ERROR response must still be served.

    RESP_FSM_ERROR->RESP_FSM_SEQ_NSEQ.  The non-pipelined recovery test above
    always returns through IDLE_BUSY, so this arm stayed dark even once the
    error path was reachable.  It matters for TL-044: if the port answered the
    error and then swallowed the transfer already in flight behind it, the
    manager would be left waiting on a response that never comes.
    """
    a, b = 0x700, 0x704
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={a: 0x1111_0000,
                                                       b: 0x2222_0000})
    axs.rresp = SLVERR
    logs = await ahm.sequence([
        {"addr": a},
        {"addr": b},
    ])
    assert any(c[1] == 1 for c in logs[0]), \
        f"first transfer should have errored: {logs[0]}"
    assert logs[1], "the pipelined second transfer was never given a data phase"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_locked_transfer_pipelined_behind_error_is_rejected(dut):
    """A LOCKED transfer pipelined behind an ERROR is rejected, not let through.

    RESP_FSM_ERROR->RESP_FSM_LOCK_ERROR.  The bridge must not treat "I am
    already in the error state" as a reason to stop checking HMASTLOCK -- that
    would let a locked transfer reach AXI unlocked.  Asserts BOTH the error
    response and that no AR was issued for it.
    """
    a, b = 0x800, 0x804
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={a: 0xAAA0_0000,
                                                       b: 0xBBB0_0000})
    axs.rresp = SLVERR
    ar_before = len(axs.ar_seen)
    logs = await ahm.sequence([
        {"addr": a},
        {"addr": b, "hmastlock": 1},
    ])
    assert any(c[1] == 1 for c in logs[0]), "first transfer should have errored"
    assert any(c[1] == 1 for c in logs[1]), \
        f"locked transfer behind an error must also error: {logs[1]}"
    assert len(axs.ar_seen) == ar_before + 1, \
        f"the locked transfer leaked onto AXI: {axs.ar_seen[ar_before:]}"


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_slv_locked_transfer_pipelined_behind_normal_is_rejected(dut):
    """A LOCKED transfer pipelined behind a NORMAL one is rejected.

    RESP_FSM_SEQ_NSEQ->RESP_FSM_LOCK_ERROR -- the check has to hold in the
    middle of a healthy stream, not only from idle.
    """
    a, b = 0x900, 0x904
    _axm, _ahs, ahm, axs = await bringup(dut, slv_mem={a: 0xC0DE_0000,
                                                       b: 0xD00D_0000})
    axs.rresp = OKAY
    ar_before = len(axs.ar_seen)
    logs = await ahm.sequence([
        {"addr": a},
        {"addr": b, "hmastlock": 1},
    ])
    assert all(c[1] == 0 for c in logs[0]), \
        f"the leading normal transfer must not error: {logs[0]}"
    assert any(c[1] == 1 for c in logs[1]), \
        f"locked transfer must be rejected with ERROR: {logs[1]}"
    assert len(axs.ar_seen) == ar_before + 1, \
        f"the locked transfer leaked onto AXI: {axs.ar_seen[ar_before:]}"
