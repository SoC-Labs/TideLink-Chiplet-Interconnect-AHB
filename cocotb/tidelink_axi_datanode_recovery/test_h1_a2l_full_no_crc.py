# =============================================================================
# test_h1_a2l_full_no_crc.py -- H1 wedge-trigger viability probe (read-only diag).
#
# QUESTION (single): when the D2D write-wedge H1 condition holds on the die's
# AW-node -- a2l replay FIFO full (a2l_full=1 -> app_ready=0 -> s_axi_awready=0),
# caused by the PEER's ACK stream going SILENT, with NO CRC error injected --
# does the AW FCSM enter state 7 (so socl_l7_wdog_cnt climbs toward its 0x4000
# threshold, making the wdog a viable on-silicon ILA trigger), or does the FSM
# sit in some OTHER state with a2l_full=1/app_ready=0 while wdog stays flat ~0?
#
# METHOD (direct isolation, no CRC):
#   * Clean bring-up. DO NOT enable CRC (_force_axi_crc) and DO NOT arm the
#     injector -- CRC is the state-7 path we are distinguishing AGAINST.
#   * Model peer-ACK silence on die_a's AW node by freezing the a2l replay
#     ACK-pointer advance: Force link_ack_update=0 AND Force the a2l_link_addr
#     reg to its (empty-FIFO) value. This is exactly "the peer never ACKs" as
#     seen by the replay FIFO (a2l_link_addr only advances on a2l_ack_valid,
#     which is gated by link_ack_update; WlinkGenericFCReplayV2_1.v:78-83,168).
#   * Issue peer-aperture AW writes; each pushes one AW word into the depth-8
#     a2l FIFO. With the ACK-ptr frozen, 8 unacked words lap the pointer ->
#     a2l_full=1 -> app_ready=0 (the H1 precondition).
#   * Confirm a2l_full=1/app_ready=0 HOLD, then observe the AW FCSM for >0x4000
#     cycles. Record state[2:0] trajectory, max socl_l7_wdog_cnt vs 0x4000,
#     send_nack_req, socl_l7_real_crc_seen throughout.
#
# The companion test_a2l_r1_probe.py (CRC-inject) is the POSITIVE CONTROL for
# "state 7 + send_nack_req reachable" -- this test is the NEGATIVE (pure H1).
# =============================================================================
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

APER_BASE  = 0x4000_0000
OFF_SANITY = 0x100
OFF_FILL   = 0x200          # base of the fill-write addresses
D_SANITY   = 0xC0FFEE01
WDOG_THRESH = 0x4000        # SOCL_L7_WDOG_THRESHOLD default


def _axi_node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)

def _si(node, name):
    try:    return int(getattr(node, name).value)
    except Exception: return None

def _slave_bram_peek(dut, off):
    try:    return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception: return None


class AWTracer:
    """Records change-events on die_a's AW FCSM + its a2l replay node, tracks
    the max wdog_cnt and a per-state dwell histogram over a tagged window."""
    def __init__(self, dut, fa, a2l):
        self.dut = dut; self.fa = fa; self.a2l = a2l
        self.events = []; self.run = True
        self.max_wdog = 0
        self.prev = {}
        self.tag = "pre"
        self.state_hist = {}          # tag -> {state_value: cycles}

    def _snap(self):
        return {
            "state":   _si(self.fa, "state"),
            "nack":    _si(self.fa, "send_nack_req"),
            "rcrc":    _si(self.fa, "socl_l7_real_crc_seen"),
            "wdogfc":  _si(self.fa, "socl_l7_wdog_force_clear"),
            "a2lfull": _si(self.a2l, "a2l_full"),
            "apprdy":  _si(self.a2l, "app_ready"),
            "laddr":   _si(self.a2l, "a2l_link_addr"),
        }

    async def loop(self):
        cyc = 0
        while self.run:
            await RisingEdge(self.dut.hclk)
            cyc += 1
            w = _si(self.fa, "socl_l7_wdog_cnt") or 0
            if w > self.max_wdog: self.max_wdog = w
            st = _si(self.fa, "state")
            h = self.state_hist.setdefault(self.tag, {})
            h[st] = h.get(st, 0) + 1
            s = self._snap()
            for k, v in s.items():
                if self.prev.get(k) != v:
                    self.events.append((self.tag, cyc, k, self.prev.get(k), v))
            self.prev = s


async def _bringup_no_crc(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 400)
    # NOTE: intentionally NO _force_axi_crc() -> AXI nodes stay CRC-off (RTL
    # default), so there is zero chance of a spurious CRC-corrupt -> state 7.
    return tb


@cocotb.test()
async def test_h1_a2l_full_state(dut):
    from test_axi_datanode_gaps import AHBSubMaster
    tb = await _bringup_no_crc(dut)
    master = AHBSubMaster(dut)

    fa  = _axi_node(tb, "m", "wlink_axiawFC")   # die_a AW-FCSM (transmitter)
    a2l = fa.a2l_fc_replay                       # die_a AW app->link replay node

    # --- sanity: a clean peer write must land (link is healthy, no CRC) -------
    await master.write(APER_BASE + OFF_SANITY, D_SANITY, timeout=60000)
    await ClockCycles(dut.hclk, 2000)
    got = _slave_bram_peek(dut, OFF_SANITY)
    assert got == D_SANITY, f"clean sanity write failed: got 0x{(got or 0):08x}"
    dut._log.info(f"[H1] sanity OK bram=0x{got:08x} "
                  f"a2l_full={_si(a2l,'a2l_full')} app_ready={_si(a2l,'app_ready')} "
                  f"laddr={_si(a2l,'a2l_link_addr')} state={_si(fa,'state')}")

    tr = AWTracer(dut, fa, a2l)
    mon = cocotb.start_soon(tr.loop())

    # --- construct pure H1: freeze die_a AW-node peer-ACK advance -------------
    # (1) Force the decoded ACK strobe into the replay node to 0 (models the
    #     peer's ACK stream going silent at the replay FIFO's ACK input).
    # (2) Belt-and-braces: Force the a2l_link_addr ACK pointer reg to its
    #     current (FIFO-empty) value so it cannot advance by any path.
    laddr0 = _si(a2l, "a2l_link_addr")
    froze = {"link_ack_update": False, "a2l_link_addr": False}
    try:
        a2l.link_ack_update.value = Force(0); froze["link_ack_update"] = True
    except Exception as e:
        dut._log.info(f"[H1] link_ack_update force failed: {e}")
    try:
        a2l.a2l_link_addr.value = Force(laddr0); froze["a2l_link_addr"] = True
    except Exception as e:
        dut._log.info(f"[H1] a2l_link_addr force failed: {e}")
    await ClockCycles(dut.hclk, 20)
    dut._log.info(f"[H1] froze ACK-ptr {froze} laddr0={laddr0}")

    # --- fill the depth-8 a2l FIFO with unacked AW words ----------------------
    tr.tag = "fill"
    full_reached = False
    for i in range(14):
        res = "ok"
        try:
            await master.write(APER_BASE + OFF_FILL + i * 4, 0xA5A50000 | i,
                               timeout=6000)
        except TimeoutError: res = "WEDGE"
        except RuntimeError:  res = "ERROR"
        af, ar = _si(a2l, "a2l_full"), _si(a2l, "app_ready")
        dut._log.info(f"[H1] fill[{i}] {res} a2l_full={af} app_ready={ar} "
                      f"wbin={_si(a2l,'a2l_app_addr')} laddr={_si(a2l,'a2l_link_addr')} "
                      f"state={_si(fa,'state')} wdog={_si(fa,'socl_l7_wdog_cnt')}")
        if af == 1 and ar == 0:
            full_reached = True
            # one more write attempt to demonstrate the AW-accept wedge, then stop
            try:
                await master.write(APER_BASE + OFF_FILL + 0xF0, 0xDEAD0000,
                                   timeout=4000)
                dut._log.info("[H1] post-full write UNEXPECTEDLY completed")
            except TimeoutError:
                dut._log.info("[H1] post-full write WEDGED (awready gated) as expected")
            except RuntimeError:
                dut._log.info("[H1] post-full write ERROR (backstop)")
            break

    af, ar = _si(a2l, "a2l_full"), _si(a2l, "app_ready")
    dut._log.info(f"[H1] H1 precondition: a2l_full={af} app_ready={ar} "
                  f"full_reached={full_reached}")

    # --- OBSERVE for well past the 0x4000 wdog window -------------------------
    tr.tag = "observe"
    OBS = 26000                       # > 0x4000 (16384)
    # sample a coarse state trajectory every 2000 cycles for the report
    traj = []
    for k in range(OBS // 2000):
        await ClockCycles(dut.hclk, 2000)
        traj.append((k * 2000,
                     _si(fa, "state"), _si(fa, "socl_l7_wdog_cnt"),
                     _si(a2l, "a2l_full"), _si(a2l, "app_ready"),
                     _si(fa, "send_nack_req"), _si(fa, "socl_l7_real_crc_seen")))

    tr.run = False
    await ClockCycles(dut.hclk, 10)
    mon.kill()

    # --- release forces (cleanliness) ----------------------------------------
    for sig, on in (("link_ack_update", froze["link_ack_update"]),
                    ("a2l_link_addr",   froze["a2l_link_addr"])):
        if on:
            try: getattr(a2l, sig).value = Release()
            except Exception: pass

    # --- REPORT ---------------------------------------------------------------
    obs_hist = tr.state_hist.get("observe", {})
    obs_states = sorted(obs_hist.keys(), key=lambda x: -obs_hist.get(x, 0))
    dominant = obs_states[0] if obs_states else None
    dut._log.info("========================= H1 RESULT =========================")
    dut._log.info(f"[H1] H1 precondition held during observe: a2l_full={af} app_ready={ar}")
    dut._log.info(f"[H1] AW-FCSM state histogram over observe window: {obs_hist}")
    dut._log.info(f"[H1] dominant state during H1 wedge = {dominant}")
    dut._log.info(f"[H1] socl_l7_wdog_cnt MAX over whole run = {tr.max_wdog} "
                  f"(threshold=0x{WDOG_THRESH:04x}={WDOG_THRESH})")
    dut._log.info(f"[H1] send_nack_req seen high? "
                  f"{'YES' if any(e[2]=='nack' and e[4]==1 for e in tr.events) else 'no'}")
    dut._log.info(f"[H1] socl_l7_real_crc_seen now = {_si(fa,'socl_l7_real_crc_seen')}")
    dut._log.info(f"[H1] state==7 ever entered? "
                  f"{'YES' if any(e[2]=='state' and e[4]==7 for e in tr.events) else 'NO'}")
    for row in traj:
        dut._log.info(f"[H1 traj] +{row[0]:6d} state={row[1]} wdog={row[2]} "
                      f"a2l_full={row[3]} app_ready={row[4]} nack={row[5]} rcrc={row[6]}")
    # verdict
    reached7 = any(e[2] == "state" and e[4] == 7 for e in tr.events)
    if reached7 and tr.max_wdog > 0:
        dut._log.info("[H1] VERDICT: H1 REACHES state 7 + wdog climbs -> wdog trigger VIABLE")
    else:
        dut._log.info(f"[H1] VERDICT: H1 does NOT reach state 7 (FSM sits in state={dominant}, "
                      f"wdog flat at {tr.max_wdog}) -> wdog trigger would NOT fire; re-spin needed")
    dut._log.info("=============================================================")

    # This test is diagnostic; assert only the H1 precondition was constructed.
    assert full_reached and af == 1 and ar == 0, (
        f"could not construct H1: a2l_full={af} app_ready={ar} full_reached={full_reached}")
