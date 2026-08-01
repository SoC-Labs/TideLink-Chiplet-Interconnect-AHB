"""AXI data-node error-recovery acceptance test — sim repro of the on-silicon
B-node (write-response) wedge (docs/AXI_DATANODE_RECOVERY_GAP_2026_07_31.md,
docs/CROSS_DIE_WEDGE_ROOTCAUSE.md on the eth-chiplet side).

ROOT CAUSE — two stacked defects, both confirmed here in sim:

1. socl_l7_bringup_forgive NEVER DISARMS on a response receive node (Fix G).
   The forgive gate (Fix A) suppresses bring-up NACK storms and clears only when
   `state==3'h5` (LINK_DATA). But a B/R write/read-RESPONSE receive node's TX FSM
   only sends ACK/NACK and sits in `state==3'h4` (LINK_IDLE) — it NEVER enters
   LINK_DATA. So forgive stayed armed FOREVER, masking crcCorruptSeen/isNotExp ->
   send_nack_req. A mid-stream error is detected but never NACK'd -> no replay ->
   the response never returns -> the initiator hard-wedges. FIX: also latch
   socl_l7_reached_link_data on LINK_IDLE (state 4) — see WlinkGenericFCSM*.v.

2. CRC checking is OFF by RTL reset default on the AXI nodes
   (WlinkGenericFCSM_2.v:713 out_prepend_swi_disable_crc = 1'h1, "SW re-enable via
   bit[16]") and nothing re-enables it. With CRC off, `crc_corrupt` is forced 0,
   so a PAYLOAD (BID/BRESP) bit-error is undetected and mis-delivered. Detection
   needs CRC on (the designed SM_CONTROL[16]=0 bring-up poke, never issued).

WHAT THE SIM CAN PROVE (the AHB tb models "response never returns"; it does NOT
model the PS SmartConnect BID-match wedge, so payload mis-delivery is proven via
the crc_errors detector instead):
  * FORGIVE FIX (Fix G): a not-expected/dropped B beat (byte 4 = pktnum) that
    without the fix parks the response forever (I5 timeout -> HRESP=ERROR), WITH
    the fix NACKs -> replays -> the write completes byte-exact. Discriminator =
    Force socl_l7_reached_link_data=0 (holds forgive on = the pre-fix RTL).
  * CRC ENABLE: with CRC on, a PAYLOAD bit-error (byte 6) is DETECTED
    (crc_errors rises) and drives the NACK (state 7); with CRC off it is silently
    accepted (crc_errors stays 0).

Tests (each run in its own sim -- sequential tests can't share a bring-up):
  test_axi_b_error_recovers          (Fix G on)  -> RECOVER byte-exact + NACK fired
  test_axi_b_error_wedges_no_fix     (Fix G off) -> must NOT recover (the wedge repro)
  test_axi_b_crc_on_detects_payload  (CRC on)    -> payload err detected+NACK'd
  test_axi_b_crc_off_silent_payload  (CRC off)   -> payload err silently accepted
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

AXI_FC_NODES = ["wlink_axiawFC", "wlink_axiwFC", "wlink_axibFC",
                "wlink_axiarFC", "wlink_axirFC"]
B_DATA_ID = 0x82

APER_BASE = 0x4000_0000
OFF_SANITY = 0x100
OFF_INJECT = 0x200
D_SANITY = 0xC0FFEE01
D_INJECT = 0xBEEF1234
REG_OBS_AXI_NODES = 0x21E0

BYTE_PKTNUM = 4      # auto_in_data[7:0]  = pktnum -> caught by isNotExpPacket (forgive path)
BYTE_PAYLOAD = 5     # auto_in_data[15:8] = BID/BRESP payload (l2a_app_data[7:0]) -> CRC-only


class AHBSubMaster:
    """AHB-Lite single-beat master on m_ahb_sub_* (ported from
    tidelink_top_pair_v2/test_v2_xhb_window.py). TimeoutError=response never
    returned; RuntimeError=HRESP=ERROR (I5 backstop unblock); clean=returned."""

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
        self.hburst.value = 0
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

    async def write_bufferable(self, addr, data, node, timeout=80000):
        """Bufferable single write (HPROT[2]=1 -> XHB500 early-write-response path).
        The posted response is zero-wait (hreadyout never dips) and the outstanding
        counter saturates at the hazard-list depth, so completion is detected by THIS
        write's AW being accepted on s_axi (node.s_axi_awvalid & s_axi_awready) — the
        definitive 'issued into the pipeline' event (writes serialise at the AHB
        address phase, so the next AW-accept is ours). Data is held a few cycles past
        acceptance so XHB500 latches the W beat. RuntimeError if the backstop fires
        HRESP=ERROR (hazard list full, a stuck write timed out); TimeoutError if never
        accepted and no error fires."""
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
            if int(self.hreadyout.value) and self._resp():   # backstop fired
                self.idle(); raise RuntimeError(f"ahb_sub bufW 0x{addr:08x} HRESP=ERROR")
        if accepted:
            await ClockCycles(self.clk, 4)       # hold data so the W beat is latched
        self.idle()
        if not accepted: raise TimeoutError(f"ahb_sub bufW 0x{addr:08x} STALL")
        return True


def _axi_node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)


def _slave_bram_peek(dut, off):
    try:    return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception: return None


def _sig(node, name):
    try:    return int(getattr(node, name).value)
    except Exception: return None


def _force_axi_crc(tb, on):
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            try:    _axi_node(tb, side, inst).out_prepend_swi_disable_crc.value = \
                        (Force(0) if on else Release())
            except Exception: pass


def _force_fix_off(tb, off):
    """off=True -> Force socl_l7_reached_link_data=0 on every AXI node (holds
    socl_l7_bringup_forgive armed = the PRE-Fix-G RTL). off=False -> Release."""
    n = 0
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            try:
                _axi_node(tb, side, inst).socl_l7_reached_link_data.value = \
                    (Force(0) if off else Release())
                n += 1
            except Exception: pass
    return n


def _wlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink


async def _arm_injector(tb, side, data_id, byte, bit):
    wl = _wlink(tb, side)
    wl.swi_err_inj_data_id.value = Force(data_id)
    wl.out_prepend_swi_err_inj_byte.value = Force(byte)
    wl.out_prepend_swi_err_inj_bit.value = Force(bit)
    wl.out_prepend_swi_err_inj.value = Force(0)
    await ClockCycles(tb.dut.hclk, 4)
    wl.out_prepend_swi_err_inj.value = Force(1)
    await ClockCycles(tb.dut.hclk, 4)


async def _arm_injector_persistent(tb, side, data_id, byte, bit):
    """PERSISTENT (frozen-marginal-eye) injection: the built-in injector is a
    one-shot -- err_inj_smack self-clears on the matching packet's advance
    (WlinkTxLinkLayer.v:64). Force the smack latch HIGH so EVERY matching B SOP
    (and every NACK-driven REPLAY) is re-corrupted. This models the on-silicon
    persistently-marginal eye where the frozen sample point corrupts every beat,
    so flow-control replay can never converge -- the exact condition the HW
    hard-wedge occurred under."""
    wl = _wlink(tb, side)
    wl.swi_err_inj_data_id.value = Force(data_id)
    wl.out_prepend_swi_err_inj_byte.value = Force(byte)
    wl.out_prepend_swi_err_inj_bit.value = Force(bit)
    wl.lltx.err_inj_smack.value = Force(1)   # never self-clears -> every B corrupts
    await ClockCycles(tb.dut.hclk, 4)


async def _region_f(tb):
    try:    raw = await tb.apb("m").read(REG_OBS_AXI_NODES)
    except Exception: return (None, None, None)
    return ((raw >> 23) & 1, (raw >> 12) & 1 | ((raw >> 17) & 1), raw)


def _release_all(tb):
    """Release every Force so sequential tests in one sim don't pollute each other
    (a left-armed injector or forced CRC corrupts the next test's bring-up)."""
    for side in ("m", "s"):
        wl = _wlink(tb, side)
        for a in ("swi_err_inj_data_id", "out_prepend_swi_err_inj_byte",
                  "out_prepend_swi_err_inj_bit", "out_prepend_swi_err_inj"):
            try:    getattr(wl, a).value = Release()
            except Exception: pass
        try:    wl.lltx.err_inj_smack.value = Release()   # persistent-eye latch
        except Exception: pass
        for inst in AXI_FC_NODES:
            node = _axi_node(tb, side, inst)
            for a in ("out_prepend_swi_disable_crc", "socl_l7_reached_link_data"):
                try:    getattr(node, a).value = Release()
                except Exception: pass


async def _run_scenario(dut, inj_byte, crc_on=True, fix_off=False):
    """Bring up, sanity write, inject ONE B-beat error, one write, classify.
    Monitors the master B node for entering state 7 (SEND_NACK) / send_nack_req."""
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, crc_on)
    nfix = _force_fix_off(tb, fix_off)
    dut._log.info(f"[axirec] CRC={'on' if crc_on else 'off'} FixG={'OFF(forced)' if fix_off else 'on'} "
                  f"({nfix} nodes) inj_byte={inj_byte}")

    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"

    mB = _axi_node(tb, "m", "wlink_axibFC")
    nack = {"state7": False, "nack_req": False, "crc0": _sig(mB, "crc_errors")}

    async def mon(n):
        for _ in range(n):
            await RisingEdge(dut.hclk)
            if _sig(mB, "state") == 7: nack["state7"] = True
            if _sig(mB, "send_nack_req"): nack["nack_req"] = True

    m = cocotb.start_soon(mon(80000))
    await _arm_injector(tb, "s", B_DATA_ID, inj_byte, 0)
    out = {"crc_on": crc_on, "fix_off": fix_off, "byte": inj_byte, "class": None}
    try:
        await master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=80000)
        out["class"] = "RECOVER"
    except TimeoutError:  out["class"] = "WEDGE"
    except RuntimeError:  out["class"] = "ERROR"
    await ClockCycles(dut.hclk, 500)
    m.kill()
    out["crc_errs_rose"] = (_sig(mB, "crc_errors") or 0) > (nack["crc0"] or 0)
    out["nack_fired"] = nack["state7"] or nack["nack_req"]
    out["byte_exact"] = (_slave_bram_peek(dut, OFF_INJECT) == D_INJECT) if out["class"] == "RECOVER" else None
    dh, bsticky, regf = await _region_f(tb)
    out["data_healthy"] = dh; out["b_wedge_sticky"] = bsticky
    dut._log.info(f"[axirec] OUTCOME: {out}")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)
    return out


@cocotb.test()
async def test_axi_b_error_recovers(dut):
    """ACCEPTANCE (Fix G on): a mid-stream not-expected B beat NACKs -> replays ->
    the write-response returns byte-exact. PASS = recovery + a NACK actually fired."""
    o = await _run_scenario(dut, BYTE_PKTNUM, crc_on=True, fix_off=False)
    assert o["class"] == "RECOVER", f"did not recover: class={o['class']}"
    assert o["byte_exact"] is True, "recovered but not byte-exact"
    assert o["nack_fired"] is True, "recovered without a NACK firing — vacuous"
    if o["data_healthy"] is not None:
        assert o["data_healthy"] == 1 and o["b_wedge_sticky"] == 0, "Region F not clean"
    dut._log.info("[axirec] PASS: B-beat error RECOVERED byte-exact via NACK->replay (Fix G)")


@cocotb.test()
async def test_axi_b_error_wedges_no_fix(dut):
    """NON-VACUITY (Fix G forced OFF): the SAME B beat, with forgive held armed
    (socl_l7_reached_link_data=0, the pre-Fix-G RTL), must NOT cleanly recover —
    the NACK is masked, the response never returns -> WEDGE/ERROR. This reproduces
    the on-silicon behaviour and proves Fix G is what recovers it."""
    o = await _run_scenario(dut, BYTE_PKTNUM, crc_on=True, fix_off=True)
    recovered_clean = (o["class"] == "RECOVER" and o["byte_exact"] is True)
    assert not recovered_clean, (
        f"pre-Fix-G unexpectedly recovered — the wedge did not reproduce, so the "
        f"fix test is vacuous. outcome={o}")
    assert o["nack_fired"] is False, (
        f"forgive held armed but a NACK still fired ({o}) — the mask model is wrong")
    dut._log.info(f"[axirec] PASS(repro): pre-Fix-G did NOT recover (class={o['class']}, "
                  f"nack_fired={o['nack_fired']}) — matches the silicon wedge")


@cocotb.test()
async def test_axi_b_crc_on_detects_payload(dut):
    """CRC-ENABLE proof (positive): a PAYLOAD (BID/BRESP) B-beat bit-error with CRC
    ON is DETECTED (crc_errors rises) and drives a NACK (the CRC->recovery path is
    live) -> recovers byte-exact. This is the beat class the on-silicon wedge hits
    that ONLY CRC can catch (pktnum intact, so isNotExpPacket does not fire)."""
    o = await _run_scenario(dut, BYTE_PAYLOAD, crc_on=True, fix_off=False)
    assert o["crc_errs_rose"] is True, "CRC on did not detect the payload error"
    assert o["nack_fired"] is True, "CRC detected but no NACK fired"
    assert o["class"] == "RECOVER" and o["byte_exact"] is True, "did not recover byte-exact"
    dut._log.info("[axirec] PASS: CRC-on DETECTS+NACKs the payload error -> recovers")


@cocotb.test()
async def test_axi_b_crc_off_silent_payload(dut):
    """CRC-ENABLE proof (negative / the shipping default): the SAME payload B-beat
    error with CRC OFF is silently accepted -- crc_errors stays 0, no NACK. On
    silicon this is the mis-delivered wrong-BID beat that hard-wedges the PS. This
    documents why the CRC bring-up enable (SM_CONTROL[16]=0) is required."""
    o = await _run_scenario(dut, BYTE_PAYLOAD, crc_on=False, fix_off=False)
    assert o["crc_errs_rose"] is False, "CRC off unexpectedly detected the error"
    assert o["nack_fired"] is False, "CRC off but a CRC-NACK fired"
    dut._log.info(f"[axirec] PASS: CRC-off silently accepts the payload error "
                  f"(crc_errs_rose=False) -- the un-armed detection the fix enables")


@cocotb.test()
async def test_axi_b_persistent_eye_bounded(dut):
    """PERSISTENT-MARGINAL-EYE experiment (the on-silicon hard-wedge condition).

    The 2026-08-01 HW run hard-wedged die_a (JTAG-POR only) on a B-response error
    even though I5 (the outstanding-response backstop) and Fix G (NACK/replay +
    CRC-on) were BOTH confirmed in the built bitstream. The A/B showed the eye was
    persistently marginal -- every B beat corrupts, so replay can never converge.

    This test reproduces THAT condition in sim: hold err_inj_smack high so every B
    SOP (and every replay) is re-corrupted, with Fix G on + CRC on. The question it
    settles: does the present-and-armed I5 convert the never-returning response
    into a BOUNDED HRESP=ERROR (a recoverable SIGBUS -- no JTAG-POR), or does it
    ALSO wedge (a real residual amplifier bug)?

    PASS = NOT a silent hard-wedge: the write must terminate as HRESP=ERROR (I5 /
    stall backstop fired) rather than hang forever, AND a NACK must have fired
    (the recovery FSM genuinely tried and could not converge on the frozen eye).
    A WEDGE here would mean I5 is defeated even when present -> a real RTL gap."""
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True)              # Fix G bring-up CRC enable
    _force_fix_off(tb, False)            # Fix G forgive-disarm active (shipping fix)

    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"

    mB = _axi_node(tb, "m", "wlink_axibFC")
    obs = {"state7": False, "nack_req": False, "i5_err": False, "os_hi": False}

    async def mon(n):
        for _ in range(n):
            await RisingEdge(dut.hclk)
            if _sig(mB, "state") == 7:        obs["state7"] = True
            if _sig(mB, "send_nack_req"):     obs["nack_req"] = True
            # die-m ahb_sub backstop: sub_err1_r = the 2-cycle AHB ERROR fired
            try:
                if int(dut.u_master.sub_err1_r.value):  obs["i5_err"] = True
                if int(dut.u_master.sub_wr_os_ctr.value): obs["os_hi"] = True
            except Exception: pass

    m = cocotb.start_soon(mon(80000))
    # PERSISTENT corruption on the far (die-s) B transmitter: every B beat flips.
    await _arm_injector_persistent(tb, "s", B_DATA_ID, BYTE_PKTNUM, 0)

    cls = None
    try:
        await master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=80000)
        cls = "RECOVER"
    except TimeoutError:  cls = "WEDGE"
    except RuntimeError:  cls = "ERROR"
    await ClockCycles(dut.hclk, 200)
    m.kill()
    nack_fired = obs["state7"] or obs["nack_req"]
    dut._log.info(f"[axirec] PERSISTENT-EYE OUTCOME: class={cls} nack_fired={nack_fired} "
                  f"i5_err={obs['i5_err']} os_hi={obs['os_hi']}")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)

    assert cls != "WEDGE", (
        "PERSISTENT eye SILENTLY HARD-WEDGED in sim even with I5 present + Fix G on "
        "-> a real residual amplifier bug (I5 defeated). Investigate why sub_err1_r "
        f"never fired (obs={obs}).")
    assert nack_fired, (
        "no NACK fired under persistent corruption -> the recovery FSM never even "
        f"tried; the repro is not exercising the CRC/forgive path (obs={obs})")
    if cls == "ERROR":
        assert obs["i5_err"], (
            "classified ERROR but sub_err1_r never observed -- unexpected error "
            f"source, verify the backstop actually fired (obs={obs})")
    dut._log.info(f"[axirec] PASS: persistent marginal eye -> BOUNDED {cls} "
                  f"(recoverable, no hard-wedge); recovery FSM tried (nack_fired) "
                  f"then the ahb_sub backstop bounded it")


@cocotb.test()
async def test_axi_b_bufferable_multi_outstanding(dut):
    """Fix H (I5 write COUNTER) — the fix for the on-silicon initiator hard-wedge.

    XHB500's early-write-response (bufferable, HPROT[2]=1) path keeps up to 4 writes
    outstanding on s_axi at once (hazard-list depth 4). The OLD I5 tracker was a
    single BIT: a returning B for one write cleared it while another was still
    outstanding, so sub_axi_outstanding falsely read idle, the age timer reset, and a
    genuinely-stuck write was never timed out -> the PS-facing ahb_sub hangs with no
    backstop. On silicon the errinject resume stream is 32 pipelined bufferable
    writes, so this masked a stuck B into a full PS hard-wedge (JTAG-POR).

    This proves the COUNTER fix in two phases:
      A. bufferable writes that COMPLETE -> sub_wr_os_ctr must reach >=2 (a single
         bit could only ever read 0/1) and all land byte-exact -> the EWR
         multi-outstanding path is exercised and recovers.
      B. stall the far terminus so B's never return -> with several writes
         outstanding the backstop STILL fires a bounded HRESP=ERROR, not a silent
         hang. (With the old single bit, once >=2 are outstanding a returning B
         would disarm it; here none return, so this mainly guards the fired path.)"""
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True)
    _force_fix_off(tb, False)
    m = dut.u_master

    # --- Phase A: pipelined bufferable writes that complete ---
    ctr_max = {"v": 0}
    async def watch_ctr(n):
        for _ in range(n):
            await RisingEdge(dut.hclk)
            try:
                c = int(m.sub_wr_os_ctr.value)
                if c > ctr_max["v"]: ctr_max["v"] = c
            except Exception: pass
    w = cocotb.start_soon(watch_ctr(60000))
    NA = 6
    base = 0x300
    for i in range(NA):
        await master.write_bufferable(APER_BASE + base + i * 4, 0xB0000000 + i, m)
    await ClockCycles(dut.hclk, 12000)          # let all B's drain
    w.kill()
    dut._log.info(f"[axirec] MULTI-OUT phase A: max sub_wr_os_ctr={ctr_max['v']}")
    assert ctr_max["v"] >= 2, (
        f"bufferable writes never showed >=2 outstanding (max={ctr_max['v']}) — the "
        f"EWR multi-outstanding path was NOT exercised, so the counter proof is "
        f"vacuous (a single bit would have sufficed)")
    for i in range(NA):
        got = _slave_bram_peek(dut, base + i * 4)
        assert got == (0xB0000000 + i), f"buf write {i} not byte-exact: got {got}"
    dut._log.info(f"[axirec] phase A: {NA} bufferable writes tracked to depth "
                  f"{ctr_max['v']} and all landed byte-exact")

    # --- Phase B: stall the far terminus so B never returns -> backstop must fire ---
    try:    dut.u_s_mng_bram.force_stall.value = Force(1)
    except Exception:
        try: dut.u_s_mng_bram.force_stall.value = 1
        except Exception: dut._log.warning("[axirec] could not force terminus stall")
    cls = "POSTED"
    try:
        for i in range(8):
            await master.write_bufferable(APER_BASE + 0x500 + i * 4,
                                          0xDEAD0000 + i, m, timeout=80000)
    except RuntimeError: cls = "ERROR"
    except TimeoutError: cls = "STALL"
    try:    dut.u_s_mng_bram.force_stall.value = Release()
    except Exception:
        try: dut.u_s_mng_bram.force_stall.value = 0
        except Exception: pass
    await ClockCycles(dut.hclk, 200)
    dut._log.info(f"[axirec] MULTI-OUT phase B (far stall): class={cls}")
    assert cls == "ERROR", (
        f"under a far-terminus stall with multiple bufferable writes outstanding, the "
        f"I5 backstop did not bound it to HRESP=ERROR (got {cls}) — a silent hang")
    dut._log.info("[axirec] PASS: Fix H tracks >=2 outstanding (recover byte-exact) "
                  "AND bounds a stalled multi-outstanding burst to HRESP=ERROR")
