"""TL-0xx — W-FC-NODE STARVATION -> rank-5 wr_hold_r self-latch (unit repro).

MECHANISM UNDER TEST (deduced from the die_a frozen state, not hypothesised):
  ahb_sub_hreadyout is held 0 by rank-5 `wr_hold_r` (tidelink_top.sv, the
  f3857392 / PRE-TL-043 form `wr_hold_clr = (wvalid&wready&wlast) |
  synth_b_pending`).  It never releases because the W handshake never
  completes, while the AW channel keeps flowing -- AW and W feed SEPARATE FC
  nodes (AXI4ToWlink.v:430 wlink_axiawFC vs :432 wlink_axiwFC), the exact
  hazard the built RTL names in its own comment.

WHAT THIS BENCH IS FOR (the decisive, undetermined measurement): WHICH of the
three terms of wr_hold_clr's W handshake is missing -- s_axi_wready (W node
starved), s_axi_wvalid (XHB500 presenting nothing) or s_axi_wlast (a multibeat
write that never reaches its last beat).  All three are unprobed on silicon,
indistinguishable in the capture, and have different fixes.

ARMS
  A  test_w_freeze_hard          W a2l ACK pointer frozen forever.
  B  test_w_freeze_paced         W a2l ACK pointer advanced by exactly ONE
                                 entry every PACE hclk -- the measured silicon
                                 AW cadence (col15 2234/3002/3770 => 768).
  C  test_aw_freeze_discrimination   DISCRIMINATION CONTROL: freeze the AW
                                 node instead; awready MUST collapse (silicon
                                 showed col34 awready = 1 x4096, so the AW node
                                 was NOT the starved one).  If the bench cannot
                                 tell the nodes apart it cannot test this.
  neg (make target) same as A with +define+TIDELINK_DISABLE_WR_HOLD -- the hold
                                 is tied to 0, so ahb_sub_hreadyout MUST go
                                 high early.  Without this every result is
                                 vacuous.

BUILD PROVENANCE: run with +define+TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT, which
recreates the f3857392 LEVEL guard byte-for-byte (tidelink_top.sv:2005-2008).
The default worktree RTL has the TL-043 edge-qualified release, which is NOT
what is on the FPGA.

TIMESCALE (disclosed): both AHB backstops are 2**16 hclk in the shipping RTL.
That is ~200k hclk to answer the backstop question, so these runs compile with
TIDELINK_SUB_{STALL,OUTSTANDING}_TIMEOUT_LOG2=13 (8192) exactly as every other
backstop test in this suite does.  Every "counter reached / did not reach the
threshold" statement below is therefore about 2**13, scaled.

MASTER FAITHFULNESS (branch E of the decision tree): the suite's existing
AHBSubMaster drops HTRANS to IDLE one cycle after the address phase regardless
of HREADY.  That kills ext_is_nonseq, so wr_hold_set stops re-arming and rank-3
stops masking -- the relay cannot form and the run would be vacuous.  This file
carries its own PIPELINED, HREADY-respecting master.
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full

APER_BASE = 0x4000_0000
OFF_SANITY = 0x100
OFF_FILL = 0x200
D_SANITY = 0xC0FFEE01

PACE = int(os.environ.get("TL0XX_PACE", "768"))       # measured AW spacing
NWRITES = int(os.environ.get("TL0XX_NWRITES", "48"))  # > depth-32 W window
OBSERVE = int(os.environ.get("TL0XX_OBSERVE", "30000"))


def _si(h):
    try:    return int(h.value)
    except Exception: return None


def _osig(obj, name):
    """Read a signal that may not EXIST in this build (A/B arms)."""
    try:    return int(getattr(obj, name).value)
    except Exception: return None


def _node(tb, side, inst):
    return getattr(tb.top(side).u_chiplet_controller.u_wlink.axi2wl, inst)


def _slave_bram_peek(dut, off):
    try:    return int(dut.u_s_mng_bram.mem[off >> 2].value)
    except Exception: return None


# ---------------------------------------------------------------------------
# a2l replay ACK-pointer freeze (the peer-ACK-silence model, ported verbatim in
# spirit from test_h1_a2l_full_no_crc.py:125-138 but RETARGETABLE to any node).
# ---------------------------------------------------------------------------
class A2LFreeze:
    def __init__(self, dut, a2l, name):
        self.dut = dut; self.a2l = a2l; self.name = name
        self.ptr = None; self.on = {"link_ack_update": False, "a2l_link_addr": False}

    def engage(self):
        self.ptr = _si(self.a2l.a2l_link_addr)
        try:
            self.a2l.link_ack_update.value = Force(0)
            self.on["link_ack_update"] = True
        except Exception as e:
            self.dut._log.info(f"[{self.name}] link_ack_update force failed: {e}")
        try:
            self.a2l.a2l_link_addr.value = Force(self.ptr)
            self.on["a2l_link_addr"] = True
        except Exception as e:
            self.dut._log.info(f"[{self.name}] a2l_link_addr force failed: {e}")
        return self.on["link_ack_update"] and self.on["a2l_link_addr"]

    def drain_one(self):
        """Advance the frozen ACK pointer by exactly ONE entry.

        DEVIATION FROM THE SPEC, deliberate and disclosed: the spec said
        'release link_ack_update for one cycle'.  That would re-import whatever
        link_ack_addr happens to hold and drain an UNKNOWN number of entries.
        Stepping the forced pointer by 1 drains exactly one, which is what the
        arm is supposed to model (one W entry per PACE cycles).  a2l_full is
        computed from this pointer through the gray addr-sync
        (WlinkGenericFCReplayV2_3.v:53-56), so the step propagates normally."""
        if not self.on["a2l_link_addr"]:
            return
        self.ptr = (self.ptr + 1) & 0x3F
        self.a2l.a2l_link_addr.value = Force(self.ptr)

    def release(self):
        for sig, on in self.on.items():
            if on:
                try: getattr(self.a2l, sig).value = Release()
                except Exception: pass


async def _pacer(dut, frz, pace):
    while True:
        await ClockCycles(dut.hclk, pace)
        frz.drain_one()


# ---------------------------------------------------------------------------
# Faithful, PIPELINED AHB-Lite master (branch-E guard).
# Holds HSEL/HADDR/HTRANS=NONSEQ/HWRITE/HPROT for as long as HREADY is low, and
# holds HWDATA through the whole data phase.  Drives HREADY from the sampled
# HREADYOUT (single-slave AHB), which is what the silicon bridge does.
# ---------------------------------------------------------------------------
class FaithfulPipelinedWriter:
    def __init__(self, dut, m, hprot=0x4):
        self.dut = dut; self.m = m; self.clk = dut.hclk; self.hprot = hprot
        self.addr_accepted = 0     # address phases that completed
        self.data_done = 0         # data phases that completed
        self.stopped = False

    def _idle(self):
        d = self.dut
        d.m_ahb_sub_hsel.value = 0; d.m_ahb_sub_htrans.value = 0
        d.m_ahb_sub_hwrite.value = 0; d.m_ahb_sub_hwdata.value = 0
        d.m_ahb_sub_hready.value = 1

    async def run(self, addrs, datas, max_cycles):
        d = self.dut
        n = len(addrs)
        pend = 0            # index of the write whose ADDRESS phase is live
        dph = None          # index of the write whose DATA phase is live
        d.m_ahb_sub_hsize.value = 2; d.m_ahb_sub_hburst.value = 0
        for _ in range(max_cycles):
            # drive for the upcoming edge
            if pend < n:
                d.m_ahb_sub_hsel.value = 1
                d.m_ahb_sub_haddr.value = addrs[pend] & 0xFFFF_FFFF
                d.m_ahb_sub_htrans.value = 2          # NONSEQ, HELD
                d.m_ahb_sub_hwrite.value = 1
                d.m_ahb_sub_hprot.value = self.hprot
            else:
                d.m_ahb_sub_hsel.value = 0; d.m_ahb_sub_htrans.value = 0
                d.m_ahb_sub_hwrite.value = 0
            if dph is not None:
                d.m_ahb_sub_hwdata.value = datas[dph] & 0xFFFF_FFFF
            await RisingEdge(self.clk)
            r = _si(self.m.ahb_sub_hreadyout)
            d.m_ahb_sub_hready.value = 1 if r else 0
            if r:
                if dph is not None:
                    self.data_done += 1
                dph = pend if pend < n else None
                if pend < n:
                    pend += 1; self.addr_accepted += 1
                if pend >= n and dph is None:
                    break
        self._idle()
        self.stopped = True


# ---------------------------------------------------------------------------
# Cycle monitor over every assert_signal in the spec.
# ---------------------------------------------------------------------------
class Mon:
    KEYS = ("hrdyo", "raw", "wrhold", "pipe", "nonseq",
            "wv", "wr", "wl", "awv", "awr",
            "sbp", "wros", "e1", "e2", "stall", "osr",
            "wfull", "wapp", "wlink", "awfull",
            "addr_rdyo", "pause_addr", "wdata_in_rdy", "stall_wr", "wdata_out_v")

    def __init__(self, dut, m, wnode, awnode):
        self.dut = dut; self.m = m; self.w = wnode; self.aw = awnode
        try:    self._ca = m.u_xhb_sub.u_core.u_addr
        except Exception: self._ca = None
        try:    self._cw = m.u_xhb_sub.u_core.u_wdata
        except Exception: self._cw = None
        self.run = True
        self.cyc = 0
        self.count = {k: 0 for k in self.Mon_keys()}
        self.max_stall = 0; self.max_osr = 0
        self.stall_zeroings = 0; self._prev_stall = 0
        self.raw_rises = 0; self._prev_raw = 1
        self.hrdyo_highs = 0
        self.max_zero_run = 0; self._zero_run = 0
        self.rawhigh_and_wrhold = 0; self.rawhigh_and_not_wrhold = 0
        self.rawhigh_hrdyo_high = 0
        self.awv_pulses = 0; self._prev_awv = 0
        self.wv_pulses = 0; self._prev_wv = 0
        self.w_handshakes = 0
        self.wapp_trace = []
        self.awv_cycles = []       # cycle index of each s_axi_awvalid rise
        self.hrdyo_cycles = []     # cycle index of each ahb_sub_hreadyout high
        self.start_cyc = None

    @staticmethod
    def Mon_keys():
        return Mon.KEYS

    def sample(self):
        m = self.m
        s = {
            "hrdyo": _si(m.ahb_sub_hreadyout), "raw": _si(m.xhb_sub_hreadyout_raw),
            "wrhold": _osig(m, "wr_hold_r"), "pipe": _si(m.pipe_valid_r),
            "nonseq": _osig(m, "ext_is_nonseq"),
            "wv": _si(m.s_axi_wvalid), "wr": _si(m.s_axi_wready),
            "wl": _si(m.s_axi_wlast),
            "awv": _si(m.s_axi_awvalid), "awr": _si(m.s_axi_awready),
            "sbp": _osig(m, "synth_b_pending"), "wros": _osig(m, "sub_wr_os_ctr"),
            "e1": _osig(m, "sub_err1_r"), "e2": _osig(m, "sub_err2_r"),
            "stall": _osig(m, "sub_stall_ctr_r"), "osr": _osig(m, "sub_osr_ctr_r"),
            "wfull": _si(self.w.a2l_full), "wapp": _si(self.w.a2l_app_addr),
            "wlink": _si(self.w.a2l_link_addr), "awfull": _si(self.aw.a2l_full),
            "addr_rdyo": _osig(self._ca, "address_readyout") if self._ca is not None else None,
            "pause_addr": _osig(self._ca, "pause_addr_submit") if self._ca is not None else None,
            "wdata_in_rdy": _osig(self._cw, "wdata_in_ready") if self._cw is not None else None,
            "stall_wr": _osig(self._cw, "stall_writes") if self._cw is not None else None,
            "wdata_out_v": _osig(self._cw, "wdata_out_valid") if self._cw is not None else None,
        }
        return s

    async def loop(self):
        while self.run:
            await RisingEdge(self.dut.hclk)
            self.cyc += 1
            s = self.sample()
            for k, v in s.items():
                if v:
                    self.count[k] = self.count.get(k, 0) + 1
            if s["hrdyo"]:
                self.hrdyo_highs += 1
                if len(self.hrdyo_cycles) < 200: self.hrdyo_cycles.append(self.cyc)
                self._zero_run = 0
            else:
                self._zero_run += 1
                if self._zero_run > self.max_zero_run:
                    self.max_zero_run = self._zero_run
            if s["raw"]:
                if not self._prev_raw:
                    self.raw_rises += 1
                if s["wrhold"]:
                    self.rawhigh_and_wrhold += 1
                else:
                    self.rawhigh_and_not_wrhold += 1
                if s["hrdyo"]:
                    self.rawhigh_hrdyo_high += 1
            self._prev_raw = s["raw"] or 0
            st = s["stall"] or 0
            if st > self.max_stall: self.max_stall = st
            if st == 0 and self._prev_stall > 4: self.stall_zeroings += 1
            self._prev_stall = st
            if (s["osr"] or 0) > self.max_osr: self.max_osr = s["osr"] or 0
            if s["awv"] and not self._prev_awv:
                self.awv_pulses += 1
                if len(self.awv_cycles) < 200: self.awv_cycles.append(self.cyc)
            self._prev_awv = s["awv"] or 0
            if s["wv"] and not self._prev_wv: self.wv_pulses += 1
            self._prev_wv = s["wv"] or 0
            if s["wv"] and s["wr"]: self.w_handshakes += 1
            if len(self.wapp_trace) < 4000 and self.cyc % 64 == 0:
                self.wapp_trace.append((self.cyc, s["wapp"], s["wlink"],
                                        s["wfull"], s["wr"], s["hrdyo"],
                                        s["wrhold"], s["stall"]))


async def _bringup(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 400)
    return tb


def _report(dut, tag, mon, wr, frz_kind, extra=""):
    n = max(mon.cyc, 1)
    c = mon.count
    dut._log.info(f"===================== {tag} RESULT ({frz_kind}) =====================")
    dut._log.info(f"[{tag}] cycles monitored           = {mon.cyc}")
    dut._log.info(f"[{tag}] AHB addr phases accepted   = {wr.addr_accepted} "
                  f"data phases completed = {wr.data_done}")
    dut._log.info(f"[{tag}] ahb_sub_hreadyout HIGH     = {mon.hrdyo_highs} "
                  f"({100.0*mon.hrdyo_highs/n:.2f}%)  <- THE WITNESS")
    dut._log.info(f"[{tag}] LONGEST CONTIGUOUS hreadyout=0 run = {mon.max_zero_run} hclk")
    dut._log.info(f"[{tag}] xhb_sub_hreadyout_raw HIGH = {c['raw']} "
                  f"(rises={mon.raw_rises})")
    dut._log.info(f"[{tag}]   raw HIGH & wr_hold_r=1   = {mon.rawhigh_and_wrhold}")
    dut._log.info(f"[{tag}]   raw HIGH & wr_hold_r=0   = {mon.rawhigh_and_not_wrhold}")
    dut._log.info(f"[{tag}]   raw HIGH & hreadyout=1   = {mon.rawhigh_hrdyo_high}")
    dut._log.info(f"[{tag}] wr_hold_r HIGH             = {c['wrhold']}")
    dut._log.info(f"[{tag}] pipe_valid_r HIGH          = {c['pipe']}  "
                  f"ext_is_nonseq HIGH = {c['nonseq']}")
    dut._log.info(f"[{tag}] --- THE THREE-WAY wr_hold_clr DISCRIMINATION ---")
    dut._log.info(f"[{tag}]   s_axi_wvalid HIGH        = {c['wv']} (pulses={mon.wv_pulses})")
    dut._log.info(f"[{tag}]   s_axi_wready HIGH        = {c['wr']}")
    dut._log.info(f"[{tag}]   s_axi_wlast  HIGH        = {c['wl']}")
    dut._log.info(f"[{tag}]   W HANDSHAKES (wv&wr)     = {mon.w_handshakes}")
    dut._log.info(f"[{tag}] s_axi_awvalid HIGH         = {c['awv']} (pulses={mon.awv_pulses})")
    dut._log.info(f"[{tag}] s_axi_awready HIGH         = {c['awr']} "
                  f"({100.0*c['awr']/n:.2f}%)")
    dut._log.info(f"[{tag}] wlink_axiwFC  a2l_full HIGH = {c['wfull']} "
                  f"(app={_si(mon.w.a2l_app_addr)} link={_si(mon.w.a2l_link_addr)})")
    dut._log.info(f"[{tag}] wlink_axiawFC a2l_full HIGH = {c['awfull']}  <- CONTROL (col60=0)")
    dut._log.info(f"[{tag}] synth_b_pending HIGH       = {c['sbp']}  "
                  f"sub_wr_os_ctr!=0 = {c['wros']}")
    dut._log.info(f"[{tag}] sub_err1_r={c['e1']} sub_err2_r={c['e2']}")
    dut._log.info(f"[{tag}] sub_stall_ctr_r max={mon.max_stall} re-zeroings={mon.stall_zeroings}")
    dut._log.info(f"[{tag}] sub_osr_ctr_r   max={mon.max_osr}")
    awd = [b - a for a, b in zip(mon.awv_cycles, mon.awv_cycles[1:])]
    dut._log.info(f"[{tag}] awvalid rise cycles  = {mon.awv_cycles[:24]}")
    dut._log.info(f"[{tag}] awvalid rise SPACING = {awd[:24]} "
                  f"(mean={sum(awd)/len(awd):.1f})" if awd else
                  f"[{tag}] awvalid rise SPACING = <2 pulses>")
    dut._log.info(f"[{tag}] ahb_sub_hreadyout HIGH cycles = {mon.hrdyo_cycles[:40]}")
    dut._log.info(f"[{tag}] XHB500: address_readyout HIGH={c['addr_rdyo']} "
                  f"pause_addr_submit HIGH={c['pause_addr']} "
                  f"wdata_in_ready HIGH={c['wdata_in_rdy']} "
                  f"stall_writes HIGH={c['stall_wr']} "
                  f"wdata_out_valid HIGH={c['wdata_out_v']}")
    for row in mon.wapp_trace[::8][:60]:
        dut._log.info(f"[{tag} traj] +{row[0]:6d} wapp={row[1]} wlink={row[2]} "
                      f"wfull={row[3]} wready={row[4]} hrdyo={row[5]} "
                      f"wrhold={row[6]} stall={row[7]}")
    if extra: dut._log.info(f"[{tag}] {extra}")
    dut._log.info("=" * 64)


async def _arm(dut, freeze_node, paced, tag):
    tb = await _bringup(dut)
    m = tb.top("m")
    wnode = _node(tb, "m", "wlink_axiwFC").a2l_fc_replay
    awnode = _node(tb, "m", "wlink_axiawFC").a2l_fc_replay

    # sanity: the link is healthy and a clean peer write lands
    from test_axi_datanode_recovery import AHBSubMaster
    sanity = AHBSubMaster(dut)
    await sanity.write(APER_BASE + OFF_SANITY, D_SANITY, timeout=60000)
    await ClockCycles(dut.hclk, 2000)
    got = _slave_bram_peek(dut, OFF_SANITY)
    assert got == D_SANITY, f"clean sanity write failed: got 0x{(got or 0):08x}"
    dut._log.info(f"[{tag}] sanity OK bram=0x{got:08x}")

    target = wnode if freeze_node == "w" else awnode
    frz = A2LFreeze(dut, target, tag)
    assert frz.engage(), "could not engage the a2l ACK-pointer freeze"
    await ClockCycles(dut.hclk, 20)
    dut._log.info(f"[{tag}] froze {freeze_node.upper()} node a2l ACK ptr at {frz.ptr}")

    pacer = cocotb.start_soon(_pacer(dut, frz, PACE)) if paced else None

    mon = Mon(dut, m, wnode, awnode)
    monco = cocotb.start_soon(mon.loop())

    addrs = [APER_BASE + OFF_FILL + 4 * i for i in range(NWRITES)]
    datas = [0xA5A50000 | i for i in range(NWRITES)]
    wr = FaithfulPipelinedWriter(dut, m)
    wrco = cocotb.start_soon(wr.run(addrs, datas, OBSERVE))

    await ClockCycles(dut.hclk, OBSERVE)
    mon.run = False
    await ClockCycles(dut.hclk, 5)
    monco.kill(); wrco.kill()
    if pacer: pacer.kill()
    frz.release()
    return tb, m, mon, wr, wnode, awnode


# ===========================================================================
# ARM A — hard W freeze
# ===========================================================================
@cocotb.test()
async def test_w_freeze_hard(dut):
    tb, m, mon, wr, wnode, awnode = await _arm(dut, "w", False, "ARM-A")
    got = _slave_bram_peek(dut, OFF_FILL)
    _report(dut, "ARM-A", mon, wr, "hard W a2l ACK freeze",
            extra=f"far-side bram[OFF_FILL]=0x{(got or 0):08x}")
    disabled = mon.count["wrhold"] == 0
    if disabled:
        # NEGATIVE-CONTROL build (+define+TIDELINK_DISABLE_WR_HOLD)
        dut._log.info("[ARM-A] NEGATIVE CONTROL build: wr_hold_r tied 0")
        assert mon.hrdyo_highs > 0, (
            "VACUOUS BENCH: with the hold disabled ahb_sub_hreadyout STILL never "
            "goes high -> something other than wr_hold_r is holding it, and every "
            "result in this file is meaningless")
        return
    n = max(mon.cyc, 1)
    assert mon.count["wfull"] > 0, (
        f"W node never filled (a2l_full always 0) -> starvation not constructed; "
        f"app={_si(wnode.a2l_app_addr)} link={_si(wnode.a2l_link_addr)}")
    # split-FC-node signature: W node starved, AW node healthy (silicon col34/col60)
    assert mon.count["awr"] > 0.8 * n, (
        f"s_axi_awready did NOT stay high ({mon.count['awr']}/{n}) -> not the "
        f"split-node signature silicon showed (col34 = 1 x4096)")
    assert mon.count["awfull"] < 0.2 * n, (
        f"wlink_axiawFC a2l_full went high {mon.count['awfull']}/{n} -> the AW node "
        f"is starved too; silicon col60 says it was not")
    # the relay: raw goes high repeatedly while the master is never answered
    assert mon.raw_rises >= 2, f"xhb_sub_hreadyout_raw rose only {mon.raw_rises}x"
    assert mon.rawhigh_and_wrhold >= 2, (
        "no cycle where xhb_sub_hreadyout_raw=1 AND wr_hold_r=1 -> rank-5 is not "
        "the operative holder in this run")
    assert mon.max_zero_run > 5000, (
        f"longest contiguous ahb_sub_hreadyout=0 run is only {mon.max_zero_run} "
        f"hclk -> no wedge")


# ===========================================================================
# ARM B — paced release at the measured 768-cycle silicon cadence
# ===========================================================================
@cocotb.test()
async def test_w_freeze_paced(dut):
    tb, m, mon, wr, wnode, awnode = await _arm(dut, "w", True, "ARM-B")
    got = _slave_bram_peek(dut, OFF_FILL)
    _report(dut, "ARM-B", mon, wr, f"paced W drain, 1 entry / {PACE} hclk",
            extra=f"far-side bram[OFF_FILL]=0x{(got or 0):08x}")
    n = max(mon.cyc, 1)
    assert mon.count["wfull"] > 0, "W node never filled under the paced arm"
    assert mon.count["awr"] > 0.8 * n, "s_axi_awready did not stay high"
    # BACKSTOP STARVATION (the point of Arm B): sub_stall_ctr_r must SAWTOOTH,
    # re-zeroed by the loop's own partial progress, never nearing its threshold.
    assert mon.stall_zeroings >= 10, (
        f"sub_stall_ctr_r was re-zeroed only {mon.stall_zeroings}x -> not the "
        f"starved-backstop shape")
    assert mon.count["sbp"] == 0, (
        f"synth_b_pending asserted ({mon.count['sbp']} cycles) -> the backstop was "
        f"NOT starved in this arm, so it does not model the silicon wedge")
    assert mon.max_zero_run > 5000, (
        f"longest contiguous ahb_sub_hreadyout=0 run is only {mon.max_zero_run}")


# ===========================================================================
# CONTROL C — freeze the AW node instead; awready MUST collapse
# ===========================================================================
@cocotb.test()
async def test_aw_freeze_discrimination(dut):
    tb, m, mon, wr, wnode, awnode = await _arm(dut, "aw", False, "CTRL-AW")
    _report(dut, "CTRL-AW", mon, wr, "hard AW a2l ACK freeze")
    n = max(mon.cyc, 1)
    assert mon.count["awfull"] > 0, (
        "AW node never filled -> the bench cannot construct AW starvation, so it "
        "cannot discriminate the two FC nodes")
    assert mon.count["awr"] < n, (
        "s_axi_awready NEVER went low under an AW-node freeze -> the bench cannot "
        "tell the AW node from the W node; the mechanism is untestable here")
