"""N1 independent verification — does the WRITE backstop (synth_b_pending) permanently
SUPPRESS the READ backstop and hang a stuck read forever?

CLAIM (imp/hw_gate/ESCAPE_VS_SAFETY_AUDIT_2026_08_13.md, section N1), against the
current working-tree src/rtl/tidelink_top.sv:
  * ONE timer (sub_osr_ctr_r) + ONE predicate (sub_axi_outstanding = sub_rd_os_r |
    (sub_wr_os_ctr!=0), :1573) serve BOTH the read ERROR backstop and the write
    synth-B backstop.
  * The read's 2-cycle AHB ERROR is delivered ONLY when ~synth_b_pending
    (:1898 hreadyout, :1906 hresp).
  * At the shared-timer expiry T, a coincident stuck WRITE arms synth_b_pending
    (:1865) which MASKS the read ERROR; :1675 unconditionally clears sub_rd_os_r;
    and both re-fire sites are `if (sub_rd_os_r)` (:1645,:1674) so the read ERROR
    can NEVER re-fire -> the AHB read master hangs unrecoverably.

This module is an INDEPENDENT construction (it does NOT read imp/hw_gate/n1_repro/).
It builds the coincident state the ONLY legal way in this TB:
  * far terminus stalled (dut.u_s_mng_bram.force_stall=1) -> NO real R and NO real
    B ever return  (holds both responses off; forces NO ready).
  * real posted (bufferable/EWR) writes -> sub_wr_os_ctr climbs REALISTICALLY, with
    XHB500 tracking them so s_axi_bready is the real bridge value (synth-B drains
    the way it would on silicon).
  * a SINGLE pulsed Force(s_axi_arvalid) sets sub_rd_os_r=1 and is then RELEASED.
    Pulsing (not holding) is essential: the N1 "can never re-fire" claim is about a
    read whose AR was ALREADY consumed by the link (R lost, no re-issue). Holding
    arvalid would inject a fresh AR every cycle and RE-ARM sub_rd_os_r artificially.

The harness rule (force VALIDs, never READYs) is honoured: only s_axi_arvalid is
forced; awready/wready/arready are never touched.

Tests (one sim each; a second bring-up does not re-POR cleanly):
  test_n1_control_read_backstop_recovers        CONTROL / non-vacuity: stuck read
      ALONE (no write) must get its HRESP=ERROR and recover -> proves TB + read
      backstop work when synth_b_pending is absent.
  test_n1_coincident_ctr_ge2_suppresses_read    PRIMARY: stuck read + stuck write
      with sub_wr_os_ctr>=2 -> the N1 predicted hang.
  test_n1_coincident_ctr_eq1_single_write       COMPARATOR (adversarial Q1): stuck
      read + a SINGLE stuck write (ctr==1) -> synth-B drains in one cycle; does the
      read ERROR reach the port on T+2?
  test_n1_realtraffic_serialisation_probe        Q3: can a real AHB read (no force)
      ever set sub_rd_os_r while sub_wr_os_ctr>0, or does XHB500 serialise it away?
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

APER_BASE  = 0x4000_0000
OFF_SANITY = 0x100
OFF_RD     = 0x300
OFF_POST   = 0x400
D_SANITY   = 0xC0FFEE01
D_RD       = 0x5EED0042
D_POST     = 0xA5A50FF0

AXI_FC_NODES = ["wlink_axiawFC", "wlink_axiwFC", "wlink_axibFC",
                "wlink_axiarFC", "wlink_axirFC"]

# SUB_OUTSTANDING_TIMEOUT_LOG2 is passed as 13 by the make target below.
TIMEOUT_LOG2 = int(os.environ.get("N1_TIMEOUT_LOG2", "13"))
EXPIRY = 1 << TIMEOUT_LOG2


# ── minimal AHB-Lite master on m_ahb_sub_* (mirrors the suite's AHBSubMaster) ──
class AHBSubMaster:
    def __init__(self, dut):
        self.dut = dut; self.clk = dut.hclk
        self.hsel = dut.m_ahb_sub_hsel; self.haddr = dut.m_ahb_sub_haddr
        self.hburst = dut.m_ahb_sub_hburst; self.hprot = dut.m_ahb_sub_hprot
        self.hsize = dut.m_ahb_sub_hsize; self.htrans = dut.m_ahb_sub_htrans
        self.hwdata = dut.m_ahb_sub_hwdata; self.hwrite = dut.m_ahb_sub_hwrite
        self.hready = dut.m_ahb_sub_hready; self.hrdata = dut.m_ahb_sub_hrdata
        self.hresp = dut.m_ahb_sub_hresp; self.hreadyout = dut.m_ahb_sub_hreadyout
        self.outstanding = False
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
        self.hburst.value = 0
        self.outstanding = True
        seen_low = False; rdata, resp, done = -1, 0, False
        for _ in range(timeout):
            await RisingEdge(self.clk)
            r = int(self.hreadyout.value)
            if not r: seen_low = True
            elif seen_low:
                rdata = self._rdata(); resp = self._resp(); done = True; break
        self.outstanding = False
        self.idle()
        op = "WRITE" if write else "READ"
        if not done: raise TimeoutError(f"ahb_sub {op} 0x{addr:08x} WEDGE")
        if resp:     raise RuntimeError(f"ahb_sub {op} 0x{addr:08x} HRESP=ERROR")
        return rdata

    async def write(self, addr, data, timeout=80000):
        await self._run(addr, True, data, timeout)

    async def read(self, addr, timeout=80000):
        return await self._run(addr, False, 0, timeout)

    async def write_bufferable(self, addr, data, node, timeout=80000):
        """Posted (HPROT[2]=1 EWR) single write. Master is released as soon as XHB500
        accepts the AW on s_axi; the write is then outstanding on s_axi (B pending)."""
        await RisingEdge(self.clk)
        self.hsel.value = 1; self.haddr.value = addr & 0xFFFF_FFFF
        self.htrans.value = 2; self.hsize.value = 2; self.hburst.value = 0
        self.hprot.value = 0x4; self.hwrite.value = 1; self.hready.value = 1
        self.hwdata.value = data & 0xFFFF_FFFF
        await RisingEdge(self.clk)
        self.hsel.value = 0; self.htrans.value = 0; self.hwrite.value = 0
        self.outstanding = True
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
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"
    return tb, master


async def _sample_across_expiry(dut, trace, cycles):
    """Sample the five audit signals (+ sub_rd_os_r, sub_wr_os_ctr, s_axi_bready,
    s_axi_bvalid_ctrl) every cycle. Record a row whenever we are near the timer
    expiry OR any backstop signal is active, so the expiry window is captured
    cycle-exact. Also keep running edge counts and a re-fire witness."""
    m = dut.u_master
    trace.setdefault("rows", [])
    trace["err1_fires"] = 0
    trace["err2_fires"] = 0
    trace["synthb_fires"] = 0
    trace["hresp_err_pulses"] = []     # (hreadyout at the pulse)
    trace["rd_os_recleared"] = False   # sub_rd_os_r went 1->0 then 0->1 again (re-arm)
    trace["osr_max"] = 0
    pe1 = ps = pr = 0
    presp = 0
    rd_os_was_cleared = False
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
        e1 = _i(m.sub_err1_r); e2 = _i(m.sub_err2_r); sb = _i(m.synth_b_pending)
        rd = _i(m.sub_rd_os_r); wr = _i(m.sub_wr_os_ctr); osr = _i(m.sub_osr_ctr_r)
        bready = _i(m.s_axi_bready); bctrl = _i(m.s_axi_bvalid_ctrl)
        try:    resp = int(dut.m_ahb_sub_hresp.value)
        except ValueError: resp = None
        try:    hro = int(dut.m_ahb_sub_hreadyout.value)
        except ValueError: hro = None
        if osr is not None and osr > trace["osr_max"]:
            trace["osr_max"] = osr
        if e1 and not pe1: trace["err1_fires"] += 1
        if e2 and not (trace.get("_pe2", 0)): trace["err2_fires"] += 1
        trace["_pe2"] = e2 or 0
        if sb and not ps: trace["synthb_fires"] += 1
        if resp and not presp:
            trace["hresp_err_pulses"].append({"hreadyout": hro})
        # re-arm witness: rd_os cleared (1->0) then set again (0->1)
        if pr == 1 and rd == 0: rd_os_was_cleared = True
        if rd_os_was_cleared and pr == 0 and rd == 1:
            trace["rd_os_recleared"] = True
        pe1, ps, pr, presp = e1 or 0, sb or 0, rd or 0, resp or 0
        near = (osr is not None and osr >= EXPIRY - 6)
        active = bool(e1 or e2 or sb) or bool(resp)
        if (near or active) and len(trace["rows"]) < 60:
            trace["rows"].append(dict(osr=osr, rd_os=rd, wr_ctr=wr, err1=e1, err2=e2,
                                      synth_b=sb, hresp=resp, hreadyout=hro,
                                      bready=bready, bvalid_ctrl=bctrl))


def _dump(dut, tag, trace):
    dut._log.info(f"[N1:{tag}] osr_max={trace['osr_max']} err1_fires={trace['err1_fires']} "
                  f"err2_fires={trace['err2_fires']} synthb_fires={trace['synthb_fires']} "
                  f"hresp_err_pulses={trace['hresp_err_pulses']} "
                  f"rd_os_reArmed={trace['rd_os_recleared']}")
    for r in trace["rows"]:
        dut._log.info(
            f"[N1:{tag}] osr={r['osr']:>5} rd_os={r['rd_os']} wr_ctr={r['wr_ctr']} "
            f"err1={r['err1']} err2={r['err2']} synth_b={r['synth_b']} "
            f"| ahb_sub_hresp={r['hresp']} hreadyout={r['hreadyout']} "
            f"| s_axi_bready={r['bready']} bvalid_ctrl={r['bvalid_ctrl']}")


async def _arm_forced_read(dut, timeout=800):
    """Present ONE AR at the internal AXI bus so sub_rd_os_r latches, then RELEASE.
    Returns True if sub_rd_os_r was observed high. Never forces a ready."""
    m = dut.u_master
    m.s_axi_arvalid.value = Force(1)
    got = False
    for _ in range(timeout):
        await RisingEdge(dut.hclk)
        if _i(m.sub_rd_os_r) == 1:
            got = True; break
    m.s_axi_arvalid.value = Release()
    return got


# =============================================================================
# CONTROL / non-vacuity: a stuck READ ALONE must get its ERROR and recover.
# =============================================================================
@cocotb.test()
async def test_n1_control_read_backstop_recovers(dut):
    tb, master = await _bringup(dut)
    m = dut.u_master

    # Prove the read path works before we stall it.
    await master.write(APER_BASE + OFF_RD, D_RD)
    await ClockCycles(dut.hclk, 2000)
    assert (await master.read(APER_BASE + OFF_RD)) == D_RD, "clean read failed"

    _set_stall(dut, True)                 # far terminus wedged: R will never return
    trace = {}
    w = cocotb.start_soon(_sample_across_expiry(dut, trace, EXPIRY + 4000))

    # Real AHB read; its R never returns (stall). NO write outstanding, so
    # sub_wr_os_ctr==0 and synth_b_pending can never arm -> the read backstop
    # is unmasked.
    cls = None
    try:
        await master.read(APER_BASE + OFF_RD, timeout=EXPIRY + 3000)
        cls = "RECOVER-DATA"
    except RuntimeError: cls = "ERROR"
    except TimeoutError: cls = "HANG"
    await ClockCycles(dut.hclk, 200)
    w.kill()
    _set_stall(dut, False)
    m.s_axi_arvalid.value = Release()
    _dump(dut, "control", trace)
    dut._log.info(f"[N1:control] class={cls}")

    assert cls == "ERROR", (
        f"CONTROL FAILED (vacuous): a stuck read ALONE did not recover via "
        f"HRESP=ERROR (class={cls}). The TB or the read backstop is broken; the "
        f"coincident-write tests would be meaningless.")
    assert trace["err1_fires"] > 0, "read errored but sub_err1_r never fired"
    assert len(trace["hresp_err_pulses"]) > 0, "no HRESP=ERROR pulse at the port"
    assert trace["synthb_fires"] == 0, "synth-B fired on a pure read stuck (unexpected)"


# =============================================================================
# PRIMARY: coincident stuck read + stuck write, sub_wr_os_ctr>=2 -> N1 hang.
# =============================================================================
async def _coincident_body(dut, master, n_writes, tag):
    m = dut.u_master
    _set_stall(dut, True)

    # Real posted writes: sub_wr_os_ctr climbs; B held off by the stall.
    for i in range(n_writes):
        try:
            await master.write_bufferable(APER_BASE + OFF_POST + i * 4,
                                          D_POST + i, m, timeout=6000)
        except (RuntimeError, TimeoutError) as e:
            dut._log.info(f"[N1:{tag}] posted write {i}: {e}")
    ctr0 = _i(m.sub_wr_os_ctr)
    ar0  = _i(m.s_axi_arready)
    dut._log.info(f"[N1:{tag}] after {n_writes} posted writes: sub_wr_os_ctr={ctr0} "
                  f"s_axi_arready={ar0}")

    # Start sampling BEFORE arming the read so we catch the whole run to expiry.
    trace = {}
    w = cocotb.start_soon(_sample_across_expiry(dut, trace, EXPIRY + 6000))

    # Present a single AR -> sub_rd_os_r=1, then release (AR consumed; no re-issue).
    got_rd = await _arm_forced_read(dut)
    ctr1 = _i(m.sub_wr_os_ctr); rd1 = _i(m.sub_rd_os_r)
    dut._log.info(f"[N1:{tag}] armed read: sub_rd_os_r={rd1} sub_wr_os_ctr={ctr1} "
                  f"(coincident={bool(got_rd and (ctr1 or 0) > 0)})")

    # Run through the shared-timer expiry and a good while after.
    await ClockCycles(dut.hclk, EXPIRY + 5000)
    w.kill()
    _set_stall(dut, False)
    m.s_axi_arvalid.value = Release()
    rd_final = _i(m.sub_rd_os_r)
    _dump(dut, tag, trace)
    dut._log.info(f"[N1:{tag}] final sub_rd_os_r={rd_final}")
    return trace, got_rd, ctr1


@cocotb.test()
async def test_n1_coincident_ctr_ge2_suppresses_read(dut):
    tb, master = await _bringup(dut)
    trace, got_rd, ctr1 = await _coincident_body(dut, master, n_writes=4, tag="ge2")

    assert got_rd, ("CANNOT-CONSTRUCT: forcing s_axi_arvalid never latched "
                    "sub_rd_os_r (s_axi_arready stayed low). See log.")
    assert (ctr1 or 0) >= 2, (
        f"could not hold sub_wr_os_ctr>=2 coincident with the stuck read "
        f"(ctr={ctr1}); the ctr>=2 case was not constructed.")
    # The N1 question, answered by measurement:
    #   HANG  = the read ERROR was masked on BOTH expiry cycles AND sub_rd_os_r was
    #           cleared with no re-fire -> zero HRESP=ERROR pulses at the port.
    #   SAFE  = an HRESP=ERROR pulse reached the port despite the coincident write.
    n_err_port = len(trace["hresp_err_pulses"])
    if n_err_port == 0:
        dut._log.info("[N1:ge2] VERDICT=REPRODUCED — read ERROR suppressed at the "
                      "port for the full window; sub_rd_os_r abandoned.")
        # This is the reproduction: assert it is genuinely a hang (no port ERROR,
        # backstop internally gated).
        assert trace["synthb_fires"] > 0, "write backstop (synth-B) never fired"
        assert not trace["rd_os_recleared"], "sub_rd_os_r re-armed (construction artifact)"
    else:
        dut._log.info(f"[N1:ge2] VERDICT=NOT-A-HANG — {n_err_port} HRESP=ERROR "
                      f"pulse(s) reached the port: {trace['hresp_err_pulses']}")
    # Record-only test: it must not fail either way; the verdict is in the log +
    # the returned trace. (A hard assert would bias an adversarial probe.)


@cocotb.test()
async def test_n1_coincident_ctr_eq1_single_write(dut):
    tb, master = await _bringup(dut)
    trace, got_rd, ctr1 = await _coincident_body(dut, master, n_writes=1, tag="eq1")

    assert got_rd, "CANNOT-CONSTRUCT: forcing s_axi_arvalid never latched sub_rd_os_r"
    n_err_port = len(trace["hresp_err_pulses"])
    dut._log.info(f"[N1:eq1] ctr_at_arm={ctr1} HRESP=ERROR pulses at port={n_err_port} "
                  f"({trace['hresp_err_pulses']})")
    # Adversarial Q1 discriminator: with a SINGLE stuck write, synth-B drains in one
    # cycle, so synth_b_pending should mask ONLY T+1 and the read ERROR should reach
    # the port on T+2 (possibly the degenerate single-cycle HRESP=1/HREADYOUT=1).
    # Record-only.


# =============================================================================
# Q3: can a REAL AHB read (no force) ever coincide with sub_wr_os_ctr>0?
# =============================================================================
@cocotb.test()
async def test_n1_realtraffic_serialisation_probe(dut):
    tb, master = await _bringup(dut)
    m = dut.u_master
    _set_stall(dut, True)

    # Posted writes -> sub_wr_os_ctr>0, all B's held by the stall.
    for i in range(4):
        try:
            await master.write_bufferable(APER_BASE + OFF_POST + i * 4,
                                          D_POST + i, m, timeout=6000)
        except (RuntimeError, TimeoutError) as e:
            dut._log.info(f"[N1:q3] posted write {i}: {e}")
    ctr0 = _i(m.sub_wr_os_ctr)
    dut._log.info(f"[N1:q3] sub_wr_os_ctr after posted writes = {ctr0}")

    # Watch whether a REAL AHB read's AR is ever accepted (sub_rd_os_r=1) while a
    # write is outstanding — NO force applied.
    witness = {"coincident_seen": False, "rd_max": 0, "reason": None}
    async def watch(n):
        for _ in range(n):
            await RisingEdge(dut.hclk)
            rd = _i(m.sub_rd_os_r) or 0
            wr = _i(m.sub_wr_os_ctr) or 0
            if rd > witness["rd_max"]: witness["rd_max"] = rd
            if rd == 1 and wr > 0: witness["coincident_seen"] = True
    w = cocotb.start_soon(watch(EXPIRY + 5000))

    # A real read issued behind the posted writes (bufferable release freed the bus).
    cls = None
    try:
        await master.read(APER_BASE + OFF_RD, timeout=EXPIRY + 3000)
        cls = "RECOVER"
    except RuntimeError: cls = "ERROR"
    except TimeoutError: cls = "HANG"
    await ClockCycles(dut.hclk, 200)
    w.kill()
    _set_stall(dut, False)
    dut._log.info(f"[N1:q3] real-read class={cls} coincident(sub_rd_os_r=1 & ctr>0)="
                  f"{witness['coincident_seen']} rd_os_max={witness['rd_max']}")
    # Record-only: the value of witness['coincident_seen'] is the Q3 answer.
