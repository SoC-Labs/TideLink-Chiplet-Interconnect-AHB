"""Rank-1 peer-WRITE data-phase drop — reproduce-first acceptance tests.

THE BUG (real-silicon-confirmed 2026-08-05, die_a->die_b cross-die writes lose
their DATA; die_b SRAM reads 0, address crosses fine, 5/5 deterministic):
tidelink's ahb_sub wrapper asserts the master-facing `ahb_sub_hreadyout` HIGH at
XHB500's early-write-response (address-accept) — one-plus cycles BEFORE the AXI W
beat (s_axi_wvalid & s_axi_wready) fires. The AHB master then ends its data phase
and RELEASES HWDATA; under real W-channel backpressure (s_axi_wready low >=1 cycle
because the W FC node buffer is full from a prior in-flight bufferable write /
CDC fill / credits) the W beat slips and XHB500 samples the already-released 0.

THE FIX (tidelink_top.sv, wr_hold_r — the write mirror of the read-side rd_pipe_r):
hold ahb_sub_hreadyout LOW from the peer-write address-latch until the W handshake
completes, so the master holds HWDATA through any W backpressure.

TESTS (each in its own sim — a second run_bringup_full does not re-POR cleanly):

  test_write_hold_hreadyout_waits_for_w_beat  (#1, WHITE-BOX INVARIANT, primary):
      For a BUFFERABLE peer write, dut.u_master.ahb_sub_hreadyout must NOT assert
      high before the W handshake (s_axi_wvalid & s_axi_wready) has occurred.
      Deterministic on an idle link (pre-fix hreadyout leads the W beat by >=1
      cycle). PASS on the fixed RTL; FAIL on the pre-fix RTL (or with
      +define+TIDELINK_DISABLE_WR_HOLD, which recovers the pre-fix behaviour).

  test_write_lands_under_w_backpressure       (#2, DATA-LANDING) — SKIPPED:
      Attempted end-to-end data-landing repro (far-terminus stall + faithful
      master, no s_axi_wready forcing). This tb cannot isolate land-vs-drop on the
      hreadyout axis: measured 2026-08-06, the payload fails to land in BOTH the
      pre- and post-fix builds (the far-stall loses the target for reasons the fix
      does not address), while on the idle link the wdata is captured BEFORE any
      release (no drop). Kept skipped with the measurements; test #1 is the correct
      validation. See its docstring + the report. Real data-landing regression is
      the KR260 bench.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, run_bringup_full
# Reuse the validated recovery-tb helpers (same directory / PYTHONPATH).
from test_axi_datanode_recovery import (
    AHBSubMaster, _slave_bram_peek, _force_axi_crc, _force_fix_off,
    _release_all, APER_BASE,
)


def _sig(h):
    try:    return int(h.value)
    except Exception: return None


async def _drive_bufferable_write_watch(dut, addr, data, timeout=6000,
                                        release_on_ready=False, poison=0,
                                        trace_n=24):
    """Drive ONE bufferable (HPROT[2]=1, EWR) peer write directly on m_ahb_sub_*
    and record, cycle-by-cycle, the ORDER of two die_a-internal events:
      * the master-facing completion   dut.u_master.ahb_sub_hreadyout rising HIGH
        (after the pipeline-fill low), and
      * the AXI W handshake            dut.u_master.s_axi_wvalid & s_axi_wready.

    Sampling starts at the ADDRESS-phase cycle so the pipeline-fill low
    (hreadyout==0) is always captured; the transfer window is then defined as
    'from the first hreadyout==0 (fill stall) onward'. Returns:
      early_ready : hreadyout went HIGH in the transfer window strictly BEFORE the
                    first W handshake  (== the peer-write early-completion bug)
      w_hs_seen / whs_cyc : the W beat fired / its sample index
      completed  / rdy_cyc: hreadyout rose (after the fill low) / its sample index
      trace      : first `trace_n` samples of (pipe_valid, hreadyout, wvalid,
                   wready, wr_hold) for instrument verification.

    release_on_ready models a REAL AHB master: the cycle AFTER it samples
    hreadyout high it drops HWDATA to `poison` (ends its data phase). Off by
    default (invariant test #1 only needs the ordering). On for #2."""
    clk = dut.hclk
    m = dut.u_master
    hsel   = dut.m_ahb_sub_hsel;   haddr  = dut.m_ahb_sub_haddr
    htrans = dut.m_ahb_sub_htrans; hsize  = dut.m_ahb_sub_hsize
    hburst = dut.m_ahb_sub_hburst; hprot  = dut.m_ahb_sub_hprot
    hwrite = dut.m_ahb_sub_hwrite; hwdata = dut.m_ahb_sub_hwdata
    hready = dut.m_ahb_sub_hready

    def _wrhold():
        try:    return int(m.wr_hold_r.value)
        except Exception: return -1

    # XHB500 wdata FSM internals: write_data_valid (a write's data is presented to
    # the wdata regslice) & wdata_in_ready (the regslice can accept it). Their AND-
    # NOT is a DEFERRED wdata sample — the exact condition under which the master's
    # HWDATA release drops the payload. Used as the non-vacuity guard for #2.
    try:    _wd = m.u_xhb_sub.u_core.u_wdata
    except Exception: _wd = None
    def _wdv():
        try:    return int(_wd.write_data_valid.value)
        except Exception: return -1
    def _wir():
        try:    return int(_wd.wdata_in_ready.value)
        except Exception: return -1

    # Address phase: assert on this edge; sampling begins on the NEXT edge so the
    # fill-stall low (driven while ext_is_nonseq & ~pipe_valid_r) is captured.
    await RisingEdge(clk)
    hsel.value = 1; haddr.value = addr & 0xFFFF_FFFF; htrans.value = 2
    hsize.value = 2; hburst.value = 0; hprot.value = 0x4      # bufferable => EWR path
    hwrite.value = 1; hready.value = 1; hwdata.value = data & 0xFFFF_FFFF

    seen_low = False; w_hs = False; early_ready = False; released = False
    rdy_cyc = None; whs_cyc = None; completed = False; trace = []
    deferred_seen = False
    for c in range(timeout):
        await RisingEdge(clk)
        if c == 0:      # end of the single-cycle address phase -> data phase
            hsel.value = 0; htrans.value = 0; hwrite.value = 0; hburst.value = 0
        rdyo = _sig(m.ahb_sub_hreadyout)
        wv   = _sig(m.s_axi_wvalid); wr = _sig(m.s_axi_wready)
        pv   = _sig(m.pipe_valid_r)
        whs  = 1 if (wv and wr) else 0
        # This write's wdata sample is DEFERRED (regslice full): the drop condition.
        if _wdv() == 1 and _wir() == 0:
            deferred_seen = True
        if c < trace_n:
            trace.append((pv, rdyo, wv, wr, _wrhold()))
        # Count this cycle's W handshake BEFORE judging an early ready, so
        # hreadyout rising in the SAME cycle as the W beat is acceptable.
        if whs:
            if not w_hs: whs_cyc = c
            w_hs = True
        if not rdyo:
            seen_low = True
        elif seen_low:                       # hreadyout high, inside the transfer
            if rdy_cyc is None: rdy_cyc = c
            if not w_hs: early_ready = True   # completed BEFORE the W beat = the bug
            completed = True
        # Faithful-master release: one cycle after seeing hreadyout high, drop
        # HWDATA. Deferred W samples now grab `poison`.
        if release_on_ready and seen_low and rdyo and not released:
            hwdata.value = poison & 0xFFFF_FFFF
            released = True
        if completed and w_hs:
            break
    # Idle.
    hsel.value = 0; htrans.value = 0; hwrite.value = 0; hwdata.value = 0
    hready.value = 1
    return {"early_ready": early_ready, "w_hs_seen": w_hs, "completed": completed,
            "rdy_cyc": rdy_cyc, "whs_cyc": whs_cyc, "seen_low": seen_low,
            "deferred_seen": deferred_seen, "trace": trace}


@cocotb.test()
async def test_write_hold_hreadyout_waits_for_w_beat(dut):
    """#1 WHITE-BOX INVARIANT (primary, deterministic): on a BUFFERABLE peer write
    the master-facing ahb_sub_hreadyout must not complete (rise high) before the
    AXI W handshake (s_axi_wvalid & s_axi_wready). Pre-fix it leads the W beat
    (the master releases HWDATA early = the drop mechanism); the fix holds it low
    until the W beat lands.

    Non-vacuity: assert the write actually ran (a W handshake was seen AND the
    write completed) so 'early_ready False' cannot pass by the transfer never
    happening. Bufferable (EWR) is REQUIRED — a non-bufferable write legitimately
    holds hreadyout low until B, which would pass even pre-fix (vacuous)."""
    tb = PairV2TB(dut); master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True); _force_fix_off(tb, False)

    # Clean sanity write first (path is alive).
    await master.write(APER_BASE + 0x100, 0xC0FFEE01)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, 0x100) == 0xC0FFEE01, "sanity write failed"

    o = await _drive_bufferable_write_watch(dut, APER_BASE + 0x200, 0xBEEF1234)
    await ClockCycles(dut.hclk, 2000)
    # Instrument verification: (pipe_valid, hreadyout, wvalid, wready, wr_hold_r).
    dut._log.info(f"[wrhold] trace[c]=(pv,rdyo,wv,wr,wrh): {o['trace']}")
    dut._log.info(f"[wrhold] INVARIANT early_ready={o['early_ready']} "
                  f"w_hs_seen={o['w_hs_seen']} completed={o['completed']} "
                  f"rdy_cyc={o['rdy_cyc']} whs_cyc={o['whs_cyc']} seen_low={o['seen_low']}")

    assert o["seen_low"], f"never saw the pipeline-fill low — instrument miswired ({o})"
    assert o["w_hs_seen"], f"no W handshake ever observed — write did not run ({o})"
    assert o["completed"], f"write never completed (hreadyout never rose) ({o})"
    assert not o["early_ready"], (
        f"ahb_sub_hreadyout asserted HIGH before the W beat (s_axi_wvalid & "
        f"s_axi_wready) — the master would release HWDATA early = the peer-write "
        f"data-drop bug. rdy_cyc={o['rdy_cyc']} < whs_cyc={o['whs_cyc']}. {o}")
    dut._log.info(f"[wrhold] PASS: hreadyout held until the W beat landed "
                  f"(rdy_cyc={o['rdy_cyc']} >= whs_cyc={o['whs_cyc']})")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)


@cocotb.test(skip=True)
async def test_write_lands_under_w_backpressure(dut):
    """#2 DATA-LANDING under real W backpressure (stronger) — SKIPPED: this tb
    CANNOT cleanly isolate the data-drop on the hreadyout axis. Kept (skipped) to
    record the honest attempt + the measurements, per the handover ("if a clean
    data-landing repro is not achievable in this tb, say so explicitly and rely on
    test #1; do NOT ship a test that passes for the wrong reason").

    WHAT WAS TRIED: stall the far terminus (u_s_mng_bram.force_stall — real link
    flow control, NO s_axi_wready forcing) to fill XHB500's wdata regslice so the
    target write's live-hwdata sample is DEFERRED past a faithful master's HWDATA
    release (release the cycle after it sees hreadyout high), then unstall + drain +
    read die_b SRAM. Intended discriminator: die_b SRAM == payload (fixed) vs 0
    (pre-fix).

    WHY IT DOES NOT WORK (measured 2026-08-06, both builds):
      * pre-fix : target=0x00000000, early_ready=True   (hreadyout led the W beat)
      * post-fix: target=0x00000000, early_ready=False  (fix held hreadyout — the
                  wr_hold_r contract is honoured, confirmed by test #1) —
      yet the payload does NOT land in EITHER build, and the intended precondition
      was never observed (deferred_seen=False in both: XHB500's
      write_data_valid & ~wdata_in_ready was not seen while the target was in
      flight). Under the far-terminus stall the target write is lost/never arrives
      for reasons the hreadyout fix does not address, so land-vs-drop is NOT
      decided by the hreadyout timing here. On the OTHER extreme (idle link) the
      wdata sample is captured BEFORE the master releases (test #1 trace:
      wready high, W beat at +2), so there is no drop to fix. There is no operating
      point in this tb where the hreadyout timing alone flips land<->drop.

    The white-box invariant (test #1) IS the correct, deterministic validation of
    the fix's contract (hreadyout must not complete before the W beat) and passes
    post-fix / fails pre-fix. The true data-landing regression is the KR260 bench
    (handover §Verification). The body below is retained as the experiment
    scaffold; it is not executed."""
    tb = PairV2TB(dut); master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True); _force_fix_off(tb, False)
    m = dut.u_master

    # Sanity write (path alive) BEFORE any stall.
    await master.write(APER_BASE + 0x100, 0xC0FFEE01)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, 0x100) == 0xC0FFEE01, "sanity write failed"

    PAYLOAD = 0xD00D5A5A
    TGT_OFF = 0x280

    # Stall the far terminus: real backpressure propagates back to die_a's W path
    # and fills XHB500's wdata regslice (no s_axi_wready forcing => no transport
    # corruption).
    try:    dut.u_s_mng_bram.force_stall.value = Force(1)
    except Exception:
        try:    dut.u_s_mng_bram.force_stall.value = 1
        except Exception: dut._log.warning("[wrhold] could not force terminus stall")

    # Pre-load the pipe with bufferable writes so the wdata regslice is OCCUPIED
    # (wdata_in_ready low) => the target write's live-hwdata sample is DEFERRED.
    # These use the non-faithful helper (detects completion via AW-accept); they
    # only need to occupy the pipe.
    for i in range(3):
        try:
            await master.write_bufferable(APER_BASE + 0x200 + i * 4,
                                          0xA5A50000 + i, m, timeout=20000)
        except Exception as e:
            dut._log.info(f"[wrhold] preload {i} did not AW-accept (pipe full): {e}")
            break

    # Unstall shortly after issuing the target so a fixed-RTL hold is bounded (the
    # target's W beat can only land once the far terminus drains).
    async def unstall_later():
        await ClockCycles(dut.hclk, 3000)
        try:    dut.u_s_mng_bram.force_stall.value = Release()
        except Exception:
            try: dut.u_s_mng_bram.force_stall.value = 0
            except Exception: pass
    u = cocotb.start_soon(unstall_later())

    # Target write with a FAITHFUL master (releases HWDATA to 0 the cycle after it
    # sees hreadyout high — the real AHB data-phase end, and the drop mechanism).
    o = await _drive_bufferable_write_watch(dut, APER_BASE + TGT_OFF, PAYLOAD,
                                            timeout=20000, release_on_ready=True,
                                            poison=0)
    await ClockCycles(dut.hclk, 20000)      # let everything drain post-unstall
    try:    dut.u_s_mng_bram.force_stall.value = Release()
    except Exception:
        try: dut.u_s_mng_bram.force_stall.value = 0
        except Exception: pass

    got = _slave_bram_peek(dut, TGT_OFF)
    dut._log.info(f"[wrhold] DATA-LANDING: target=0x{(got if got is not None else 0):08x} "
                  f"expect=0x{PAYLOAD:08x} deferred_seen={o['deferred_seen']} "
                  f"early_ready={o['early_ready']} completed={o['completed']}")

    # Non-vacuity: the target's wdata sample was actually DEFERRED (regslice full,
    # write_data_valid high while wdata_in_ready low). This holds in BOTH the pre-
    # and post-fix RTL (the far-stall creates it regardless of wr_hold), so it can
    # only fail if the backpressure did not engage — in which case a LAND would be
    # for the wrong reason and we must not conclude.
    assert o["completed"], f"target write never completed ({o})"
    assert o["deferred_seen"], (
        "XHB500 never DEFERRED the target's wdata sample (write_data_valid & "
        "~wdata_in_ready never seen) — the far-terminus stall did not fill the "
        "regslice, so the drop mechanism was not exercised (vacuous). Cannot "
        "conclude the fix from this run; rely on test #1.")
    # Discriminator: with the sample deferred past the master's HWDATA release, the
    # pre-fix RTL captures 0 (DROP); the fix holds hreadyout so the master holds the
    # payload until the W beat lands (LAND). Pre-fix => got==0 (FAIL here);
    # post-fix => got==PAYLOAD (PASS).
    assert got == PAYLOAD, (
        f"peer write DROPPED under real W backpressure: die_b SRAM=0x{got:08x} != "
        f"payload 0x{PAYLOAD:08x}. The master released HWDATA before the deferred W "
        f"beat landed (hreadyout early={o['early_ready']}). This is the silicon drop.")
    dut._log.info("[wrhold] PASS: payload landed byte-exact at die_b — wdata sample "
                  "was deferred (regslice full) yet the hold kept HWDATA to the W beat")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)
