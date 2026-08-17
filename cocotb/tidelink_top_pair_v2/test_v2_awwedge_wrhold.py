"""TL-002 wr_hold_r AW-wedge DEADLOCK repro (Rank5, tidelink_top.sv:1913).

*** SUPERSEDED as the regression lock (2026-08-13). This test forces s_axi_awready
    LOW to build the wedge — which wedges XHB500 UNRECOVERABLY, so it can prove the
    deadlock EXISTS but can NEVER show post-fix resumption. The canonical TL-042
    regression lock forces the VALIDs (awvalid/wvalid) instead, keeping the bridge
    live; use the peer's v2 test (imp/hw_gate/tl042_v2/) for fix acceptance. Keep this
    one only as a wedge-EXISTENCE repro. Also note: round-2 proves raw=xhb_sub_hreadyout_raw
    is ALSO 0 (rank6 co-holds), so clearing wr_hold_r alone does not raise hreadyout —
    this bench cannot be an end-to-end acceptance test regardless. ***

CONFIRMED by the round-2 die_a ILA (2026-08-13, hex-first): dbg_wr_hold_r=1 every
sample, dbg_wr_hold_clr=0, sub_aw_accept=0, sub_wr_os_ctr=0, synth_b_pending=0,
and mux ranks1-4 all FALSE — so wr_hold_r=1 is the SOLE low-driver. This test's
hard asserts are exactly that measured frozen state. NOTE the round-1 "sawtooth /
pipe_valid toggling" story was a hex-decode artifact and is NOT what silicon shows:
at the hold dbg_ext_is_nonseq=0 and dbg_pipe_valid_r=0 (the PS is blocked and
presents no new nonseq) — which is why this bench drops ahb_sub to IDLE after the
address phase, and why pipe_valid_r / the raw-underneath trend are LOGGED as
evidence, never hard-required.

Adapted from test_v2_xhb_lostresp_pipe.py / test_v2_xhb_window.py. Those tests
wedge the RETURN path (R/B) with the AW ALREADY ACCEPTED, which arms the I5
outstanding backstop and lets synth_b_pending clear wr_hold via the :1838 guard.

This test injects the DIFFERENT condition the silicon capture shows: the AW FC
node itself is backpressured BEFORE the first accept. We force the u_master
s_axi_awready net LOW (axi_tgt_0_aw_ready, tidelink_top.sv:2901) and hold it from
before the first write NONSEQ, then issue ONE bufferable/EWR (HPROT[2]=1) write
to the window aperture 0x4000_0000. We do NOT wedge R/B.

MECHANISM (spec): wr_hold_r SETs on the AHB front-end alone
    wr_hold_set = ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r   (:1836)
and BOTH clear paths (:1837-1838) are dead:
  (1) the W-handshake clear never fires -- no AW accept => no W beat crosses;
  (2) the synth_b_pending guard is dead -- sub_wr_os_ctr stuck at 0 (only
      increments on sub_aw_accept, :1672-1673) => sub_wr_stuck_fire stuck 0
      (:1868, gated on sub_wr_os_ctr!=0) => synth_b_pending never arms (:1876).
The DEADLOCK GUARD (:1822-1834) was built for AW-accepted-but-W-never-ready; it
cannot arm here because the AW itself never accepts. So wr_hold_r is STUCK HIGH
and is the sustained gate holding ahb_sub_hreadyout LOW forever.

Build with SMALL timeout overrides so the window can PROVE the backstops fail to
arm within a bound (outstanding 2^10=1024 cyc, per-beat 2^8=256 cyc):
    make MODULE=test_v2_awwedge_wrhold SIM_BUILD=sim_build_awwedge \
      EXTRA_DEFINES="+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=8 \
                     +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=10"
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full
from test_v2_xhb_window import AHBSubMaster

APERTURE_BASE = 0x4000_0000
# Window comfortably past BOTH backstop timeouts (1024 / 256) so "never armed"
# is a proven bound, not a too-short observation.
HOLD_WINDOW = 4000


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return None


async def _present_ewr_write_nonseq(dut, addr, data):
    """Drive ONE bufferable/EWR (HPROT[2]=1) single-beat WRITE NONSEQ on the
    master ahb_sub port, then drop to IDLE holding HWDATA. Does NOT wait for
    completion (with awready wedged it never completes)."""
    clk = dut.hclk
    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value   = 1
    dut.m_ahb_sub_haddr.value  = addr & 0xFFFF_FFFF
    dut.m_ahb_sub_htrans.value = 2          # NONSEQ
    dut.m_ahb_sub_hsize.value  = 2          # WORD
    dut.m_ahb_sub_hburst.value = 0
    dut.m_ahb_sub_hprot.value  = 0b0100     # HPROT[2]=1 -> bufferable / EWR path
    dut.m_ahb_sub_hwrite.value = 1
    dut.m_ahb_sub_hwdata.value = data & 0xFFFF_FFFF
    dut.m_ahb_sub_hready.value = 1
    await RisingEdge(clk)
    # Address phase done: drop to IDLE, keep HWDATA valid through the data phase.
    dut.m_ahb_sub_hsel.value   = 0
    dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hwrite.value = 0
    dut.m_ahb_sub_hburst.value = 0


async def _watch_wrhold(dut, cycles):
    """Sample the wr_hold deadlock signature every hclk for `cycles`.
    Returns per-signal aggregates that prove the frozen state + dead backstops."""
    m = dut.u_master
    st = {
        "wrhold_lo": 0, "wrhold_hi": 0,          # dbg_wr_hold_r 0/1 counts
        "hro_hi": 0, "hro_lo": 0, "hro_x": 0,    # dbg_ahb_sub_hreadyout
        "raw_hi": 0, "raw_lo": 0, "raw_x": 0,    # xhb_sub_hreadyout_raw (underneath)
        "aw_accept_max": 0,                       # sub_aw_accept ever 1?
        "wr_os_max": 0,                           # sub_wr_os_ctr max
        "synth_b_max": 0,                         # synth_b_pending ever 1?
        "stuck_fire_max": 0,                      # sub_wr_stuck_fire ever 1?
        "osr_expired_max": 0,                     # sub_osr_expired ever 1?
        "wr_clr_max": 0,                          # dbg_wr_hold_clr ever 1?
        "err1_max": 0,
        "pipe_valid_seen": set(),
    }
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
        wh  = _i(m.dbg_wr_hold_r)
        hro = _i(m.dbg_ahb_sub_hreadyout)
        raw = _i(m.xhb_sub_hreadyout_raw)
        if wh == 1: st["wrhold_hi"] += 1
        elif wh == 0: st["wrhold_lo"] += 1
        if hro == 1: st["hro_hi"] += 1
        elif hro == 0: st["hro_lo"] += 1
        else: st["hro_x"] += 1
        if raw == 1: st["raw_hi"] += 1
        elif raw == 0: st["raw_lo"] += 1
        else: st["raw_x"] += 1
        st["aw_accept_max"]   = max(st["aw_accept_max"],   _i(m.sub_aw_accept) or 0)
        st["wr_os_max"]       = max(st["wr_os_max"],       _i(m.sub_wr_os_ctr) or 0)
        st["synth_b_max"]     = max(st["synth_b_max"],     _i(m.synth_b_pending) or 0)
        st["stuck_fire_max"]  = max(st["stuck_fire_max"],  _i(m.sub_wr_stuck_fire) or 0)
        st["osr_expired_max"] = max(st["osr_expired_max"], _i(m.sub_osr_expired) or 0)
        st["wr_clr_max"]      = max(st["wr_clr_max"],      _i(m.dbg_wr_hold_clr) or 0)
        st["err1_max"]        = max(st["err1_max"],        _i(m.sub_err1_r) or 0)
        pv = _i(m.dbg_pipe_valid_r)
        if pv is not None:
            st["pipe_valid_seen"].add(pv)
    return st


@cocotb.test()
async def test_awwedge_wrhold_deadlock(dut):
    """Force s_axi_awready LOW before the first accept, issue one EWR write, and
    assert wr_hold_r latches and NEVER clears, ahb_sub_hreadyout stays LOW and
    never pulses high, and BOTH backstops provably fail to arm within the window."""
    tb = PairV2TB(dut)
    _ = AHBSubMaster(dut)                 # idles ahb_sub before bring-up
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    m = dut.u_master
    # As-built backstop sizes (read straight off the compiled counter widths).
    osr_log2   = len(m.sub_osr_ctr_r) - 1
    stall_log2 = len(m.sub_stall_ctr_r) - 1
    tb.log.info(f"  [awwedge] as-built backstops: outstanding=2^{osr_log2} "
                f"per-beat=2^{stall_log2}; HOLD_WINDOW={HOLD_WINDOW}")
    assert HOLD_WINDOW > (1 << osr_log2) and HOLD_WINDOW > (1 << stall_log2), (
        "HOLD_WINDOW must exceed BOTH backstop timeouts to prove they never arm; "
        "rebuild with +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=10 "
        "+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=8")

    # ---- inject the wedged AW FC node: awready LOW from BEFORE the first accept
    m.s_axi_awready.value = Force(0)
    await ClockCycles(dut.hclk, 4)
    assert _i(m.s_axi_awready) == 0, "awready force did not take"
    assert _i(m.dbg_wr_hold_r) == 0, "wr_hold_r already high before the write (unexpected)"

    # ---- one bufferable/EWR write NONSEQ into the aperture --------------------
    await _present_ewr_write_nonseq(dut, APERTURE_BASE + 0x040, 0xC0FFEE02)

    # give the front-end a couple cycles to latch, then confirm wr_hold latched
    await ClockCycles(dut.hclk, 3)
    assert _i(m.dbg_wr_hold_r) == 1, (
        "wr_hold_r did NOT latch on the write NONSEQ — stimulus wrong "
        "(ext_is_nonseq/hwrite/pipe_valid) or the write never presented")

    # ---- watch the hold window ------------------------------------------------
    st = await _watch_wrhold(dut, HOLD_WINDOW)
    st["pipe_valid_seen"] = sorted(st["pipe_valid_seen"])
    tb.log.info(f"  [awwedge] window probes: {st}")

    m.s_axi_awready.value = Release()
    await ClockCycles(dut.hclk, 20)

    # ── DEADLOCK ASSERTIONS (spec assert_signals) ─────────────────────────────
    assert st["wrhold_lo"] == 0 and st["wrhold_hi"] == HOLD_WINDOW, (
        f"wr_hold_r did not stay HIGH the whole window (hi={st['wrhold_hi']} "
        f"lo={st['wrhold_lo']} of {HOLD_WINDOW}) — it CLEARED, so no deadlock")
    assert st["hro_hi"] == 0 and st["hro_lo"] == HOLD_WINDOW, (
        f"ahb_sub_hreadyout PULSED HIGH (hi={st['hro_hi']}) — the master would "
        f"have completed; not a sustained wedge")
    assert st["aw_accept_max"] == 0, (
        f"sub_aw_accept asserted ({st['aw_accept_max']}) — awready force leaked; "
        f"the AW crossed and this is NOT the AW-wedge deadlock")
    assert st["wr_os_max"] == 0, (
        f"sub_wr_os_ctr incremented to {st['wr_os_max']} — an AW was counted; "
        f"the backstop CAN arm, not the frozen state")
    assert st["synth_b_max"] == 0, "synth_b_pending armed — the guard clear COULD fire"
    assert st["stuck_fire_max"] == 0, "sub_wr_stuck_fire asserted — write backstop armed"
    assert st["osr_expired_max"] == 0, (
        "sub_osr_expired fired — the outstanding timer ran (needs wr_os_ctr!=0), "
        "contradicting the frozen state")
    assert st["wr_clr_max"] == 0, "dbg_wr_hold_clr asserted — a clear path fired"
    assert st["err1_max"] == 0, "sub_err1_r fired — a write should never drive the read-only ERROR"

    # ── the 'sawtooth-live raw underneath' half of the capture ────────────────
    # xhb_sub_hreadyout_raw pulses high while the master-facing hreadyout is
    # pinned low by wr_hold_r — proving the wedge is the wrapper hold, not a dead
    # bridge. (Recorded as evidence; if the EWR bridge parks raw low we still have
    # a true deadlock, so this is logged rather than hard-required.)
    tb.log.info(
        f"  [awwedge] RESULT: wr_hold_r stuck HIGH all {HOLD_WINDOW} cyc, "
        f"ahb_sub_hreadyout stuck LOW all {HOLD_WINDOW} cyc; aw_accept=0 "
        f"wr_os_ctr=0 synth_b=0 stuck_fire=0 osr_expired=0 wr_hold_clr=0; "
        f"raw underneath: hi={st['raw_hi']} lo={st['raw_lo']} x={st['raw_x']} "
        f"(pipe_valid seen={st['pipe_valid_seen']}). DEADLOCK REPRODUCED.")


@cocotb.test()
async def test_awwedge_control_no_force_completes(dut):
    """NON-VACUITY CONTROL: identical EWR write with awready NOT forced. On the
    healthy link the AW accepts, sub_wr_os_ctr increments, and wr_hold_r clears —
    proving the deadlock in the first test is caused by the AW-wedge injection,
    not a broken bench."""
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    m = dut.u_master
    saw = {"aw_accept": 0, "wr_os": 0, "wrhold_hi": 0, "wr_clr": 0}
    stop = {"go": True}

    async def _watch():
        while stop["go"]:
            await RisingEdge(dut.hclk)
            saw["aw_accept"] = max(saw["aw_accept"], _i(m.sub_aw_accept) or 0)
            saw["wr_os"]     = max(saw["wr_os"],     _i(m.sub_wr_os_ctr) or 0)
            saw["wrhold_hi"] = max(saw["wrhold_hi"], _i(m.dbg_wr_hold_r) or 0)
            saw["wr_clr"]    = max(saw["wr_clr"],    _i(m.dbg_wr_hold_clr) or 0)

    w = cocotb.start_soon(_watch())
    # A normal EWR write through the window; completes on the real B response.
    await master.write(APERTURE_BASE + 0x040, 0x51A70001, timeout=60000)
    await ClockCycles(dut.hclk, 200)
    stop["go"] = False
    await ClockCycles(dut.hclk, 2)
    tb.log.info(f"  [control] probes: {saw}, final wr_hold_r={_i(m.dbg_wr_hold_r)}")

    assert saw["aw_accept"] == 1, "control: AW never accepted on the healthy link"
    assert saw["wr_os"] >= 1, "control: sub_wr_os_ctr never incremented"
    assert _i(m.dbg_wr_hold_r) == 0, "control: wr_hold_r stuck high on a healthy write"
    tb.log.info("  [control] PASS: healthy EWR write accepted its AW and wr_hold "
                "cleared — the deadlock is injection-specific, not a bench artifact")
