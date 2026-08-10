# =============================================================================
# test_a2l_r1_probe.py -- R1 FCSM residual root-cause probe (read-only diag).
#
# Reproduces the on-silicon AW error-inject wedge that survives TL-032, in the
# recovery sim env (FCSM recovery + ECC restore + CRC + TL-032 a2l overrides all
# compiled). Injects a PURE-CRC error (BYTE_PAYLOAD, pktnum intact so only CRC
# catches it -> crcCorruptSeen -> real_crc_seen latch -> Fix-D watchdog disabled)
# on the AW node, one-shot, REPEATED (sweep-like), and traces:
#   die_b AW-FCSM: state, send_nack_req, socl_l7_real_crc_seen, socl_l7_wdog_cnt,
#                  socl_l7_wdog_force_clear, crc_errors
#   die_a AW a2l : a2l_full, app_ready, a2l_link_addr
# Classifies RECOVER / WEDGE per inject.
# =============================================================================
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

AW_DATA_ID = 0x80
BYTE_PKTNUM  = 4     # auto_in_data[7:0]  = pktnum
BYTE_PAYLOAD = 5     # auto_in_data[15:8] = payload -> CRC-only (pktnum intact)
APER_BASE  = 0x4000_0000
OFF_SANITY = 0x100
OFF_INJECT = 0x200
D_SANITY   = 0xC0FFEE01
D_INJECT   = 0xBEEF1234


def _axi_node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)

def _wlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink

def _si(node, name):
    try:    return int(getattr(node, name).value)
    except Exception: return None

def _slave_bram_peek(dut, off):
    try:    return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception: return None

def _force_axi_crc(tb, on):
    for side in ("m", "s"):
        for inst in ("wlink_axiawFC","wlink_axiwFC","wlink_axibFC","wlink_axiarFC","wlink_axirFC"):
            try: _axi_node(tb, side, inst).out_prepend_swi_disable_crc.value = (Force(0) if on else Release())
            except Exception: pass

async def _arm_injector(tb, side, data_id, byte, bit=0):
    wl = _wlink(tb, side)
    wl.swi_err_inj_data_id.value = Force(data_id)
    wl.out_prepend_swi_err_inj_byte.value = Force(byte)
    wl.out_prepend_swi_err_inj_bit.value = Force(bit)
    wl.out_prepend_swi_err_inj.value = Force(0)
    await ClockCycles(tb.dut.hclk, 4)
    wl.out_prepend_swi_err_inj.value = Force(1)
    await ClockCycles(tb.dut.hclk, 4)

def _disarm_injector(tb, side):
    wl = _wlink(tb, side)
    for a in ("swi_err_inj_data_id","out_prepend_swi_err_inj_byte",
              "out_prepend_swi_err_inj_bit","out_prepend_swi_err_inj"):
        try: getattr(wl, a).value = Release()
        except Exception: pass


class Tracer:
    """Records signal-CHANGE events (compact transition log) on the AW nodes."""
    def __init__(self, dut, fcsm_b, fcsm_a, a2l_a):
        self.dut = dut; self.b = fcsm_b; self.a = fcsm_a; self.a2l = a2l_a
        self.events = []; self.run = True
        self.max_wdog = 0
        self.prev = {}

    def _snap(self):
        return {
            "b.state":  _si(self.b, "state"),
            "b.nack":   _si(self.b, "send_nack_req"),
            "b.rcrc":   _si(self.b, "socl_l7_real_crc_seen"),
            "b.wdogfc": _si(self.b, "socl_l7_wdog_force_clear"),
            "b.crcerr": _si(self.b, "crc_errors"),
            "a.state":  _si(self.a, "state"),
            "a.nack":   _si(self.a, "send_nack_req"),
            "a2l.full": _si(self.a2l, "a2l_full"),
            "a2l.rdy":  _si(self.a2l, "app_ready"),
            "a2l.laddr":_si(self.a2l, "a2l_link_addr"),
        }

    async def loop(self, tag=""):
        cyc = 0
        while self.run:
            await RisingEdge(self.dut.hclk)
            cyc += 1
            w = _si(self.b, "socl_l7_wdog_cnt") or 0
            if w > self.max_wdog: self.max_wdog = w
            s = self._snap()
            for k, v in s.items():
                if self.prev.get(k) != v:
                    self.events.append((tag, cyc, k, self.prev.get(k), v))
            self.prev = s


async def _bringup(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True)
    return tb


async def _one_inject(dut, tb, master, tr, tag, byte):
    """Arm AW injector, drive the AW-carrying write, classify."""
    await _arm_injector(tb, "m", AW_DATA_ID, byte)
    tr.prev = tr._snap()
    res = "RECOVER"
    try:
        await master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=60000)
    except TimeoutError: res = "WEDGE"
    except RuntimeError: res = "ERROR"
    await ClockCycles(dut.hclk, 1000)
    _disarm_injector(tb, "m")
    await ClockCycles(dut.hclk, 200)
    ve = _slave_bram_peek(dut, OFF_INJECT)
    dut._log.info(f"[R1 {tag}] class={res} bram=0x{(ve or 0):08x} "
                  f"b.state={_si(tr.b,'state')} b.nack={_si(tr.b,'send_nack_req')} "
                  f"b.rcrc={_si(tr.b,'socl_l7_real_crc_seen')} wdog_max={tr.max_wdog} "
                  f"a2l.full={_si(tr.a2l,'a2l_full')} a2l.rdy={_si(tr.a2l,'app_ready')}")
    return res, ve


async def _import_master():
    from test_axi_datanode_gaps import AHBSubMaster
    return AHBSubMaster


@cocotb.test()
async def test_aw_payload_crc_sweep(dut):
    """Repeated one-shot AW pure-CRC inject. Watches whether a LATER inject wedges
    once real_crc_seen has disabled the Fix-D watchdog."""
    AHBSubMaster = await _import_master()
    tb = await _bringup(dut)
    master = AHBSubMaster(dut)
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"

    fb = _axi_node(tb, "s", "wlink_axiawFC")   # die_b AW-FCSM (NACK sender)
    fa = _axi_node(tb, "m", "wlink_axiawFC")   # die_a AW-FCSM (transmitter)
    a2l = fa.a2l_fc_replay                      # die_a AW a2l replay (TL-032)
    tr = Tracer(dut, fb, fa, a2l)
    mon = cocotb.start_soon(tr.loop("sweep"))

    results = []
    for i in range(4):
        r, ve = await _one_inject(dut, tb, master, tr, f"inj{i}", BYTE_PAYLOAD)
        results.append(r)
        # clean write between injects to confirm path still alive
        try:
            await master.write(APER_BASE + OFF_SANITY, D_SANITY + i + 1, timeout=60000)
            alive = (_slave_bram_peek(dut, OFF_SANITY) == D_SANITY + i + 1)
        except Exception:
            alive = False
        dut._log.info(f"[R1 inj{i}] post-inject clean-write alive={alive}")
        if r == "WEDGE" or not alive:
            break

    tr.run = False
    await ClockCycles(dut.hclk, 10)
    mon.kill()
    dut._log.info(f"[R1] sweep results={results}")
    # dump the transition trace (compact)
    dut._log.info(f"[R1] wdog_max_over_run={tr.max_wdog} n_events={len(tr.events)}")
    for (tag, cyc, k, o, n) in tr.events:
        dut._log.info(f"[R1 trace] {tag} +{cyc:6d} {k:10s} {o} -> {n}")

    assert "WEDGE" not in results, f"AW pure-CRC inject WEDGED in sweep: {results}"


@cocotb.test()
async def test_aw_dataid_byte0(dut):
    """The ACTUAL silicon byte: AW byte-0 (data_id) bit-0 flip, ECC ON (restored).
    Does ECC correct it (recover) or does it silent-drop / wedge?"""
    AHBSubMaster = await _import_master()
    tb = await _bringup(dut)
    master = AHBSubMaster(dut)
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, OFF_SANITY) == D_SANITY, "clean sanity write failed"

    fb = _axi_node(tb, "s", "wlink_axiawFC")
    fa = _axi_node(tb, "m", "wlink_axiawFC")
    tr = Tracer(dut, fb, fa, fa.a2l_fc_replay)
    mon = cocotb.start_soon(tr.loop("b0"))
    r, ve = await _one_inject(dut, tb, master, tr, "byte0", BYTE_DATA_ID := 0)
    tr.run = False; await ClockCycles(dut.hclk, 10); mon.kill()
    dut._log.info(f"[R1] byte0 class={r} bram=0x{(ve or 0):08x} "
                  f"b.crcerr={_si(fb,'crc_errors')} b.rcrc={_si(fb,'socl_l7_real_crc_seen')}")
    dut._log.info("[R1] byte0 NOTE: RECOVER+byte-exact => ECC corrected; "
                  "WEDGE/ERROR => silent-drop path (NACK-blind)")


@cocotb.test()
async def test_aw_persistent_stuck(dut):
    """PERSISTENT AW payload corruption (every SOP incl. replays re-corrupted):
    the genuine stuck-state-7 case. Watches whether die_b state 7 sticks, whether
    the (disabled) watchdog would have fired, and whether die_a a2l wedges."""
    AHBSubMaster = await _import_master()
    tb = await _bringup(dut)
    master = AHBSubMaster(dut)
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)

    fb = _axi_node(tb, "s", "wlink_axiawFC")
    fa = _axi_node(tb, "m", "wlink_axiawFC")
    a2l = fa.a2l_fc_replay
    tr = Tracer(dut, fb, fa, a2l)
    mon = cocotb.start_soon(tr.loop("persist"))

    # persistent injector on die_a AW
    wl = _wlink(tb, "m")
    wl.swi_err_inj_data_id.value = Force(AW_DATA_ID)
    wl.out_prepend_swi_err_inj_byte.value = Force(BYTE_PAYLOAD)
    wl.out_prepend_swi_err_inj_bit.value = Force(0)
    try:    wl.lltx.err_inj_smack.value = Force(1)
    except Exception as e: dut._log.info(f"[R1] no err_inj_smack: {e}")
    await ClockCycles(dut.hclk, 4)

    res = "RECOVER"
    try:
        await master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=120000)
    except TimeoutError: res = "WEDGE"
    except RuntimeError: res = "ERROR(backstop)"
    await ClockCycles(dut.hclk, 500)
    tr.run = False; await ClockCycles(dut.hclk, 10); mon.kill()
    dut._log.info(f"[R1] persistent class={res} b.state={_si(fb,'state')} "
                  f"b.nack={_si(fb,'send_nack_req')} b.rcrc={_si(fb,'socl_l7_real_crc_seen')} "
                  f"wdog_max={tr.max_wdog} wdog_thresh=0x4000 "
                  f"a2l.full={_si(a2l,'a2l_full')} a2l.rdy={_si(a2l,'app_ready')} "
                  f"a2l.laddr={_si(a2l,'a2l_link_addr')}")
    # how long did state 7 dwell? count state==7 events
    s7 = [e for e in tr.events if e[2]=="b.state" and e[4]==7]
    dut._log.info(f"[R1] persistent state7_entries={len(s7)} n_events={len(tr.events)}")
    try:    wl.lltx.err_inj_smack.value = Release()
    except Exception: pass
    _disarm_injector(tb, "m")


@cocotb.test()
async def test_wdog_arming_forced_stall(dut):
    """WHITE-BOX backstop proof. Drive a real-CRC AW inject so die_b AW-FCSM sets
    send_nack_req + real_crc_seen, then FREEZE it in state 7 by forcing
    auto_tx_out_advance=0 (models TX-arbiter starvation / no NACK emit). Watch the
    Fix-D/TL-033 state-7 watchdog counter:
      * TL033_LEGACY_WDOG (pre-fix): real_crc_seen pins wdog_cnt=0 -> force_clear
        never asserts (the DEAD backstop).
      * default (TL-033 fix): no forward progress -> wdog_cnt climbs to THRESHOLD
        -> force_clear asserts (backstop ARMED).
    Run with +define+SOCL_L7_WDOG_THRESHOLD_VAL=200 so it trips fast."""
    AHBSubMaster = await _import_master()
    tb = await _bringup(dut)
    master = AHBSubMaster(dut)
    await master.write(APER_BASE + OFF_SANITY, D_SANITY)
    await ClockCycles(dut.hclk, 2000)

    fb = _axi_node(tb, "s", "wlink_axiawFC")   # die_b AW-FCSM (NACK sender)

    # arm a real-CRC inject and drive an AW; poll for send_nack_req, then freeze.
    await _arm_injector(tb, "m", AW_DATA_ID, BYTE_PAYLOAD)
    w = cocotb.start_soon(master.write(APER_BASE + OFF_INJECT, D_INJECT, timeout=60000))
    frozen = False
    for _ in range(60000):
        await RisingEdge(dut.hclk)
        if _si(fb, "send_nack_req") == 1:
            fb.auto_tx_out_advance.value = Force(0)   # starve NACK emission
            frozen = True
            break
    dut._log.info(f"[R1 wdog] froze_at_nack={frozen} state={_si(fb,'state')} "
                  f"nack={_si(fb,'send_nack_req')} rcrc={_si(fb,'socl_l7_real_crc_seen')}")

    max_cnt = 0; fc_seen = False; state7_cnt = 0
    nack_cleared_while_stalled = False
    state_left_7_while_stalled = False
    for _ in range(2000):
        await RisingEdge(dut.hclk)
        c = _si(fb, "socl_l7_wdog_cnt") or 0
        if c > max_cnt: max_cnt = c
        if _si(fb, "socl_l7_wdog_force_clear") == 1:
            fc_seen = True
            if _si(fb, "send_nack_req") == 0: nack_cleared_while_stalled = True
            if _si(fb, "state") != 7: state_left_7_while_stalled = True
        if _si(fb, "state") == 7: state7_cnt += 1

    dut._log.info(f"[R1 wdog] ARMING state7_cycles={state7_cnt} wdog_cnt_max={max_cnt} "
                  f"force_clear_asserted={fc_seen} nack_now={_si(fb,'send_nack_req')} "
                  f"state_now={_si(fb,'state')}")
    dut._log.info(f"[R1 wdog] EFFICACY(advance still 0): nack_cleared={nack_cleared_while_stalled} "
                  f"state_left_7={state_left_7_while_stalled} "
                  f"(force_clear can clear send_nack_req but state-7 EXIT needs auto_tx_out_advance)")

    # Now RELEASE the stall: does the FSM settle at 4 (fixed) or bounce (legacy)?
    try: fb.auto_tx_out_advance.value = Release()
    except Exception: pass
    settled4 = False
    for _ in range(3000):
        await RisingEdge(dut.hclk)
        if _si(fb, "state") == 4 and _si(fb, "send_nack_req") == 0:
            settled4 = True; break
    dut._log.info(f"[R1 wdog] POST-RELEASE settled(state4,nack0)={settled4} "
                  f"state_now={_si(fb,'state')} nack_now={_si(fb,'send_nack_req')}")
    _disarm_injector(tb, "m")
    try: w.kill()
    except Exception: pass
    await ClockCycles(dut.hclk, 50)
