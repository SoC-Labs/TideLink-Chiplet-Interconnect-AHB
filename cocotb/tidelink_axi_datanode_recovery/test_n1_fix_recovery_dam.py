"""N1 FIX validation (INDEPENDENT, dam) — does the conditional-abandon fix actually
RECOVER a coincident stuck-read that the N1 bug hangs forever?

N1 (confirmed, cycle-exact): on a COINCIDENT stuck read + stuck write, the write's
synth_b_pending masks BOTH cycles of the read backstop's AHB ERROR (:1898/:1906
gate on `& ~synth_b_pending`) while the unconditional `sub_rd_os_r <= 0` (:1675)
abandons the read, and both re-fire sites are `if (sub_rd_os_r)` -> the read ERROR
never reaches the port -> unrecoverable PS hang.

FIX under test (compiled via an OVERRIDE copy of tidelink_top.sv; the tracked tree
is left byte-identical): make the abandon CONDITIONAL —
    if (sub_rd_os_r && (sub_wr_os_ctr==0) && !synth_b_pending) fire ERROR + abandon;
    else keep sub_rd_os_r SET so a LATER timer window delivers a visible 2-cycle
    ERROR once the masking write has drained.

THE RESIDUAL QUESTION: does the deferral actually recover? i.e. does synth_b_pending
CLEAR (write drains -> s_axi_bready=1 -> synth-B beats retire) so the read's ERROR is
delivered in a STRICTLY LATER expiry window?  This test answers it BY MEASUREMENT.

Construction (the only legal one in this TB; mirrors the suppress module):
  * far terminus stalled (u_s_mng_bram.force_stall=1) -> NO real R and NO real B.
  * REAL posted (bufferable/EWR) writes to PAGE 0x40000 -> sub_wr_os_ctr climbs AND
    the XHB500 hazard list is populated with real id-0 entries (this is essential:
    the synth-B drain needs b_ewr=1, i.e. bid==hazard entry; forcing s_axi_awvalid
    directly would leave the hazard list EMPTY -> b_ewr=0 -> a FALSE no-recover).
  * a single pulsed Force(s_axi_arvalid) with araddr on PAGE 0x40001 (CROSS-PAGE)
    sets sub_rd_os_r=1, then RELEASED (AR consumed, R lost, no re-issue).  Forcing
    the read downstream of the bridge guarantees coincidence regardless of any
    XHB500 read-behind-write serialisation.

Only VALIDs are forced (s_axi_arvalid); no READY is ever forced.

Parametrised by N1_EXPECT (env): "recover" (fix build) | "hang" (no-fix control).
N1_TIMEOUT_LOG2 must match the +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2 the
Makefile was invoked with.
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

APER_BASE  = 0x4000_0000
PAGE_W     = 0x0000_0000     # writes  -> page 0x40000
PAGE_R     = 0x0000_1000     # reads   -> page 0x40001  (CROSS-PAGE)
OFF_SANITY = 0x100
OFF_RD     = 0x300
OFF_POST   = 0x400
D_SANITY   = 0xC0FFEE01
D_RD       = 0x5EED0042
D_POST     = 0xA5A50FF0

AXI_FC_NODES = ["wlink_axiawFC", "wlink_axiwFC", "wlink_axibFC",
                "wlink_axiarFC", "wlink_axirFC"]

TIMEOUT_LOG2 = int(os.environ.get("N1_TIMEOUT_LOG2", "11"))
EXPIRY       = 1 << TIMEOUT_LOG2
EXPECT       = os.environ.get("N1_EXPECT", "recover").strip().lower()


# ── minimal AHB-Lite master on m_ahb_sub_* (copied from the suppress module) ────
class AHBSubMaster:
    def __init__(self, dut):
        self.dut = dut; self.clk = dut.hclk
        self.hsel = dut.m_ahb_sub_hsel; self.haddr = dut.m_ahb_sub_haddr
        self.hburst = dut.m_ahb_sub_hburst; self.hprot = dut.m_ahb_sub_hprot
        self.hsize = dut.m_ahb_sub_hsize; self.htrans = dut.m_ahb_sub_htrans
        self.hwdata = dut.m_ahb_sub_hwdata; self.hwrite = dut.m_ahb_sub_hwrite
        self.hready = dut.m_ahb_sub_hready; self.hrdata = dut.m_ahb_sub_hrdata
        self.hresp = dut.m_ahb_sub_hresp; self.hreadyout = dut.m_ahb_sub_hreadyout
        self.idle()

    def idle(self):
        self.hsel.value = 0; self.haddr.value = 0; self.hburst.value = 0
        self.hprot.value = 0; self.hsize.value = 2; self.htrans.value = 0
        self.hwdata.value = 0; self.hwrite.value = 0; self.hready.value = 1

    def _resp(self):
        try:    return int(self.hresp.value)
        except ValueError: return 0

    def _rdata(self):
        try:    return int(self.hrdata.value)
        except ValueError: return -1

    async def _run(self, addr, write, wdata, timeout):
        await RisingEdge(self.clk)
        self.hsel.value = 1; self.haddr.value = addr & 0xFFFF_FFFF
        self.htrans.value = 2; self.hsize.value = 2; self.hburst.value = 0
        self.hprot.value = 0; self.hwrite.value = 1 if write else 0
        self.hready.value = 1
        if write: self.hwdata.value = wdata & 0xFFFF_FFFF
        await RisingEdge(self.clk)
        self.hsel.value = 0; self.htrans.value = 0; self.hwrite.value = 0
        seen_low = False; rdata, resp, done = -1, 0, False
        for _ in range(timeout):
            await RisingEdge(self.clk)
            r = int(self.hreadyout.value)
            if not r: seen_low = True
            elif seen_low:
                rdata = self._rdata(); resp = self._resp(); done = True; break
        self.idle()
        op = "WRITE" if write else "READ"
        if not done: raise TimeoutError(f"ahb_sub {op} 0x{addr:08x} WEDGE")
        if resp:     raise RuntimeError(f"ahb_sub {op} 0x{addr:08x} HRESP=ERROR")
        return rdata

    async def write(self, addr, data, timeout=80000):
        await self._run(addr, True, data, timeout)

    async def read(self, addr, timeout=80000):
        return await self._run(addr, False, 0, timeout)

    async def write_bufferable(self, addr, data, node, timeout=6000):
        """Posted (HPROT[2]=1 EWR) single write; master is released once XHB500
        accepts the AW on s_axi. The write is then outstanding on s_axi (B pending)
        AND recorded in the XHB500 hazard list (real id-0 entry)."""
        await RisingEdge(self.clk)
        self.hsel.value = 1; self.haddr.value = addr & 0xFFFF_FFFF
        self.htrans.value = 2; self.hsize.value = 2; self.hburst.value = 0
        self.hprot.value = 0x4; self.hwrite.value = 1; self.hready.value = 1
        self.hwdata.value = data & 0xFFFF_FFFF
        await RisingEdge(self.clk)
        self.hsel.value = 0; self.htrans.value = 0; self.hwrite.value = 0
        accepted = False
        for _ in range(timeout):
            await RisingEdge(self.clk)
            try:
                if int(node.s_axi_awvalid.value) and int(node.s_axi_awready.value):
                    accepted = True; break
            except ValueError: pass
            if int(self.hreadyout.value) and self._resp():
                self.idle(); raise RuntimeError(f"ahb_sub bufW 0x{addr:08x} HRESP=ERROR")
        if accepted:
            await ClockCycles(self.clk, 4)
        self.idle()
        if not accepted: raise TimeoutError(f"ahb_sub bufW 0x{addr:08x} STALL")
        return True


def _axi_node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)


def _force_axi_crc(tb, on):
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            try:    _axi_node(tb, side, inst).out_prepend_swi_disable_crc.value = \
                        (Force(0) if on else Release())
            except Exception: pass


def _peek(dut, off):
    try:    return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception: return None


def _i(sig):
    try:    return int(sig.value)
    except Exception: return None


def _deep(m, *path):
    """Read a deep DUT signal by attribute path; None if unreachable/unresolvable."""
    node = m
    try:
        for p in path:
            node = getattr(node, p)
        return int(node.value)
    except Exception:
        return None


def _set_stall(dut, on):
    try:    dut.u_s_mng_bram.force_stall.value = (Force(1) if on else Release())
    except Exception:
        try:    dut.u_s_mng_bram.force_stall.value = (1 if on else 0)
        except Exception: pass


async def _bringup(dut):
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True)
    await master.write(APER_BASE + PAGE_W + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _peek(dut, PAGE_W + OFF_SANITY) == D_SANITY, "clean sanity write failed"
    return tb, master


async def _arm_forced_read(dut, araddr, timeout=800):
    """Present ONE AR (cross-page) at the internal AXI bus so sub_rd_os_r latches,
    then RELEASE. Returns True if sub_rd_os_r went high. Never forces a ready."""
    m = dut.u_master
    try:    m.s_axi_araddr.value = Force(araddr & 0xFFFF_FFFF)
    except Exception: pass
    m.s_axi_arvalid.value = Force(1)
    got = False
    for _ in range(timeout):
        await RisingEdge(dut.hclk)
        if _i(m.sub_rd_os_r) == 1:
            got = True; break
    m.s_axi_arvalid.value = Release()
    try:    m.s_axi_araddr.value = Release()
    except Exception: pass
    return got


async def _sample_windows(dut, trace, cycles):
    """Cycle-by-cycle capture with expiry-WINDOW tracking. An expiry event is the
    single cycle sub_osr_ctr_r == EXPIRY (top bit set, counter about to reset).
    Window index = count of expiry events observed so far."""
    m = dut.u_master
    trace.update(rows=[], expiries=[], hresp_err_pulses=[],
                 synthb_fires=0, synthb_clears=0, err1_fires=0,
                 bready_high_during_synthb=False, bready_reg_high_during_synthb=False,
                 b_ewr_high_during_synthb=False, b_ewr_probeable=False,
                 bready_reg_probeable=False, osr_max=0, expiry_count=0,
                 rd_snapshot_after_expiry={}, first_delivery_window=None)
    p_synthb = p_resp = p_err1 = 0
    p_osr = -1
    pending_snap = None   # (expiry_idx, cycles_left) to grab rd/ctr shortly after expiry
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
        e1 = _i(m.sub_err1_r); e2 = _i(m.sub_err2_r); sb = _i(m.synth_b_pending)
        rd = _i(m.sub_rd_os_r); wr = _i(m.sub_wr_os_ctr); osr = _i(m.sub_osr_ctr_r)
        bready = _i(m.s_axi_bready); bvalid = _i(m.s_axi_bvalid)
        bctrl = _i(m.s_axi_bvalid_ctrl)
        b_ewr = _deep(m, "u_xhb_sub", "u_core", "b_ewr")
        breg  = _deep(m, "u_xhb_sub", "u_core", "u_resp", "bready_reg")
        try:    resp = int(dut.m_ahb_sub_hresp.value)
        except ValueError: resp = None
        try:    hro = int(dut.m_ahb_sub_hreadyout.value)
        except ValueError: hro = None

        if osr is not None and osr > trace["osr_max"]:
            trace["osr_max"] = osr
        if b_ewr is not None: trace["b_ewr_probeable"] = True
        if breg  is not None: trace["bready_reg_probeable"] = True

        # expiry event detection (osr hits EXPIRY for exactly one cycle)
        is_expiry = (osr == EXPIRY)
        if is_expiry and p_osr != EXPIRY:
            trace["expiry_count"] += 1
            widx = trace["expiry_count"]
            trace["expiries"].append(dict(win=widx, rd=rd, wr_ctr=wr, synth_b=sb,
                                          osr=osr, bready=bready, b_ewr=b_ewr))
            pending_snap = (widx, 6)   # grab rd/ctr 6 cycles later (post-fire/defer)

        # snapshot of rd/ctr shortly after each expiry (captures defer-vs-abandon)
        if pending_snap is not None:
            widx, left = pending_snap
            left -= 1
            if left == 0:
                trace["rd_snapshot_after_expiry"][widx] = dict(rd=rd, wr_ctr=wr, synth_b=sb)
                pending_snap = None
            else:
                pending_snap = (widx, left)

        # edge counters
        if e1 and not p_err1: trace["err1_fires"] += 1
        if sb and not p_synthb: trace["synthb_fires"] += 1
        if p_synthb and not sb: trace["synthb_clears"] += 1
        if sb:
            if bready:  trace["bready_high_during_synthb"] = True
            if breg == 1: trace["bready_reg_high_during_synthb"] = True
            if b_ewr == 1: trace["b_ewr_high_during_synthb"] = True
        if resp and not p_resp:
            widx = trace["expiry_count"]
            trace["hresp_err_pulses"].append(dict(win=widx, hreadyout=hro))
            if trace["first_delivery_window"] is None:
                trace["first_delivery_window"] = widx

        p_synthb, p_resp, p_err1, p_osr = sb or 0, resp or 0, e1 or 0, (osr if osr is not None else -1)

        near   = (osr is not None and osr >= EXPIRY - 4)
        active = bool(e1 or e2 or sb) or bool(resp) or is_expiry
        if (near or active) and len(trace["rows"]) < 140:
            trace["rows"].append(dict(win=trace["expiry_count"], osr=osr, rd=rd,
                                      wr=wr, e1=e1, e2=e2, sb=sb, resp=resp, hro=hro,
                                      bready=bready, bvalid=bvalid, bctrl=bctrl,
                                      b_ewr=b_ewr, breg=breg))


def _dump(dut, tag, trace):
    L = dut._log.info
    L(f"[N1FIX:{tag}] EXPECT={EXPECT} TIMEOUT_LOG2={TIMEOUT_LOG2} EXPIRY={EXPIRY}")
    L(f"[N1FIX:{tag}] osr_max={trace['osr_max']} expiry_count={trace['expiry_count']} "
      f"err1_fires={trace['err1_fires']} synthb_fires={trace['synthb_fires']} "
      f"synthb_clears={trace['synthb_clears']}")
    L(f"[N1FIX:{tag}] first_delivery_window={trace['first_delivery_window']} "
      f"hresp_err_pulses={trace['hresp_err_pulses']}")
    L(f"[N1FIX:{tag}] bready_high_during_synthb={trace['bready_high_during_synthb']} "
      f"bready_reg_high_during_synthb={trace['bready_reg_high_during_synthb']} "
      f"(probeable={trace['bready_reg_probeable']}) "
      f"b_ewr_high_during_synthb={trace['b_ewr_high_during_synthb']} "
      f"(probeable={trace['b_ewr_probeable']})")
    for e in trace["expiries"]:
        L(f"[N1FIX:{tag}] EXPIRY win={e['win']} rd={e['rd']} wr_ctr={e['wr_ctr']} "
          f"synth_b={e['synth_b']} b_ewr={e['b_ewr']}")
    for w, s in sorted(trace["rd_snapshot_after_expiry"].items()):
        L(f"[N1FIX:{tag}] post-expiry#{w} snapshot: rd={s['rd']} wr_ctr={s['wr_ctr']} "
          f"synth_b={s['synth_b']}")
    for r in trace["rows"]:
        L(f"[N1FIX:{tag}] w{r['win']} osr={r['osr']:>5} rd={r['rd']} wr={r['wr']} "
          f"e1={r['e1']} e2={r['e2']} sb={r['sb']} | hresp={r['resp']} hro={r['hro']} "
          f"| bready={r['bready']} bvalid={r['bvalid']} bctrl={r['bctrl']} "
          f"b_ewr={r['b_ewr']} breg={r['breg']}")


async def _coincident_run(dut, master, n_writes, tag):
    m = dut.u_master
    _set_stall(dut, True)
    for i in range(n_writes):
        try:
            await master.write_bufferable(APER_BASE + PAGE_W + OFF_POST + i * 4,
                                          D_POST + i, m, timeout=6000)
        except (RuntimeError, TimeoutError) as e:
            dut._log.info(f"[N1FIX:{tag}] posted write {i}: {e}")
    ctr0 = _i(m.sub_wr_os_ctr)
    dut._log.info(f"[N1FIX:{tag}] after {n_writes} posted writes: sub_wr_os_ctr={ctr0}")

    trace = {}
    w = cocotb.start_soon(_sample_windows(dut, trace, EXPIRY * 3 + 3000))

    got_rd = await _arm_forced_read(dut, APER_BASE + PAGE_R + OFF_RD)
    ctr1 = _i(m.sub_wr_os_ctr); rd1 = _i(m.sub_rd_os_r)
    dut._log.info(f"[N1FIX:{tag}] armed read: sub_rd_os_r={rd1} sub_wr_os_ctr={ctr1} "
                  f"coincident={bool(got_rd and (ctr1 or 0) >= 2)}")

    await ClockCycles(dut.hclk, EXPIRY * 3 + 2500)
    w.kill()
    _set_stall(dut, False)
    m.s_axi_arvalid.value = Release()
    rd_final = _i(m.sub_rd_os_r)
    _dump(dut, tag, trace)
    dut._log.info(f"[N1FIX:{tag}] final sub_rd_os_r={rd_final}")
    return trace, got_rd, ctr1, rd_final


@cocotb.test()
async def test_n1_coincident_deferred_recovery(dut):
    tb, master = await _bringup(dut)
    trace, got_rd, ctr1, rd_final = await _coincident_run(dut, master, n_writes=4,
                                                          tag=EXPECT)

    # ── construction gates (both builds) ─────────────────────────────────────
    assert got_rd, ("CANNOT-CONSTRUCT: forcing s_axi_arvalid never latched "
                    "sub_rd_os_r (s_axi_arready stayed low). See log.")
    assert (ctr1 or 0) >= 2, (f"CANNOT-CONSTRUCT: sub_wr_os_ctr={ctr1} (<2) at read-arm; "
                              "the ctr>=2 coincident case was not built.")
    assert trace["synthb_fires"] >= 1, ("CANNOT-CONSTRUCT: synth_b_pending never armed; "
                                        "the masking write backstop did not engage.")
    # First expiry must be genuinely coincident (read still outstanding AND >=2 stuck
    # writes) — proves the masking/deferral scenario formed, not a run where the read
    # simply errored first time (which would make any later 'recover' vacuous).
    e1 = next((e for e in trace["expiries"] if e["win"] == 1), None)
    assert e1 is not None, "no expiry #1 captured"
    assert e1["rd"] == 1 and (e1["wr_ctr"] or 0) >= 2, (
        f"expiry #1 was NOT coincident (rd={e1['rd']} wr_ctr={e1['wr_ctr']}); "
        "non-vacuity guard failed.")
    fd = trace["first_delivery_window"]

    if EXPECT == "hang":
        # NON-VACUITY CONTROL (no-fix build): the read is LOST forever.
        assert fd is None, (f"CONTROL FAILED: a HRESP=ERROR reached the port in "
                            f"window {fd} on the NO-FIX build (expected none = hang).")
        snap1 = trace["rd_snapshot_after_expiry"].get(1, {})
        assert snap1.get("rd") == 0, (f"CONTROL: expected sub_rd_os_r abandoned (0) after "
                                      f"expiry #1 on no-fix; got {snap1}.")
        dut._log.info("[N1FIX:hang] VERDICT=N1-REPRODUCED — coincident read masked at "
                      "expiry #1, sub_rd_os_r abandoned, ZERO port ERROR ever = hang.")
        return

    # EXPECT == "recover" (fix build)
    assert fd is not None, ("FIX-DOES-NOT-RECOVER: no HRESP=ERROR ever reached the port; "
                            "the read is still lost.")
    assert fd >= 2, (f"VACUOUS: HRESP=ERROR delivered in window {fd} (not strictly later "
                     f"than the masked expiry #1); deferral not demonstrated.")
    # Prove the deferral chain: read stayed outstanding through window 1, the write
    # drained (synth_b_pending cleared), and bready went high to make that happen.
    snap1 = trace["rd_snapshot_after_expiry"].get(1, {})
    assert snap1.get("rd") == 1, (f"FIX: sub_rd_os_r was NOT kept set after expiry #1 "
                                  f"(got {snap1}); deferral did not happen.")
    assert trace["synthb_clears"] >= 1, ("FIX-DOES-NOT-RECOVER: synth_b_pending never "
                                         "CLEARED; the masking write never drained.")
    assert trace["bready_high_during_synthb"], ("FIX-DOES-NOT-RECOVER: s_axi_bready never "
                                                "reached 1 during synth-B -> drain stuck.")
    assert rd_final == 0, (f"FIX: sub_rd_os_r not cleared after delivery (={rd_final}); "
                           "the recovered read was not retired.")
    dut._log.info(f"[N1FIX:recover] VERDICT=FIX-RECOVERS — coincident read deferred at "
                  f"expiry #1, write drained (synth_b cleared, bready seen high), "
                  f"HRESP=ERROR delivered at expiry window {fd} (strictly later).")
