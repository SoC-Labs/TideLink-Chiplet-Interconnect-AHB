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


def _osig(obj, name):
    """Signal read that tolerates the signal not EXISTING in this build.

    _sig() cannot cover this: `m.some_new_signal` raises on the ATTRIBUTE access,
    before _sig is ever called. Needed for A/B runs where the pre-fix RTL simply
    has no such net — without it the pre-fix arm dies on a missing-child error
    instead of on the assertion under test, which is a VACUOUS failure."""
    try:    return int(getattr(obj, name).value)
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


@cocotb.test(skip=True)
async def test_wr_hold_stuck_escapes_tl042(dut):
    """#3 TL-042 — wr_hold_r must not be able to hold the AHB bus FOREVER.

    ⚠ SKIPPED: THE FIX THIS TEST WAS WRITTEN FOR WAS REJECTED ON HARDWARE
    (2026-08-13). The BUG below is REAL and still OPEN — the test is kept, and
    kept skipped, because it PASSES only against a candidate fix that HW proved
    harmful. Do not re-enable it without a new fix that survives the bench.

    WHAT HAPPENED: the candidate widened the synth-B arm with a 2**16 timer on
    (wr_hold_r high AND sub_wr_os_ctr==0) so the EXISTING synth_b_pending path
    would clear the hold. It PASSED this test and the full recovery suite, then
    REGRESSED THE DATA PLANE ON SILICON:

        arm                     delivery        Region F   die_a post
        baseline  9eadebb8      16/16 exact     PASS       UP
        tl042 fix 0366c344      0/16 (0x0)      FAIL       DOWN   (n=2)

    Same protocol, same die_b image, healthy bring-up on every run (fcsm=4,
    crack_seen=1, both re-anchored). Evidence: imp/hw_gate/control_baseline/,
    imp/hw_gate/retry2/, imp/hw_gate/rep_tl042_r3/.

    ROOT CAUSE OF THE REGRESSION (why the whole APPROACH is wrong, not just the
    tuning): `wr_hold_clr = (W-last handshake) | synth_b_pending` (tidelink_top.sv
    :1838). synth_b_pending therefore DISABLES the TL-002 hold for as long as it
    is asserted. Reusing synth_b_pending as the hold-release lever means that
    whenever the new arm fires, the peer-write data-phase protection is defeated
    and the write drops its payload — exactly the 0x00000000 observed. Worse, the
    companion s_axi_bvalid suppression removes the very handshake that clears
    synth_b_pending (:1939 needs s_axi_bready), so it can latch high.

    WHY THIS TEST DID NOT CATCH IT: it only ever constructs the genuinely-stuck
    state and asserts the escape. It never checks that synth_b_pending CLEARS
    afterwards, nor that a normal write still lands once the arm has fired. Any
    future candidate must be tested for BOTH. (This test's own log shows
    synth_b_pending=1 twenty cycles past the escape — the evidence was on screen
    and unexamined.)

    A CORRECT FIX MUST NOT key on `sub_wr_os_ctr == 0` alone: on the bufferable/
    EWR path the counter can legitimately return to 0 while wr_hold_r is still
    validly waiting for its W beat. Consider instead "no AW accepted SINCE this
    hold was set", and a release path that does NOT route through synth_b_pending.

    ---- original description of the (still open) defect follows ----

    THE SILICON STATE (die_a ILA, 2026-08-13, round-2, 4097 samples — evidence in
    imp/hw_gate/ila_tl035_run_round2/): `dbg_wr_hold_r` 1/1/4096 STUCK HIGH,
    `dbg_wr_hold_clr` never asserts, ext_is_nonseq=0, pipe_valid_r=0, rd_pipe_r=0,
    sub_err1_r=sub_err2_r=0 => in the hreadyout override mux, ranks 1-4 are ALL
    false and rank-5 `wr_hold_r` is the ONLY term driving ahb_sub_hreadyout low.
    With it: sub_aw_accept=0, sub_wr_os_ctr=0, synth_b_pending=0.

    THE CLOSED LOOP (this is TL-002's own guard deadlocking):
        wr_hold_r=1 -> ahb_sub_hreadyout low -> the AHB write never completes ->
        no AW ever reaches s_axi (sub_aw_accept=0) -> sub_wr_os_ctr stays 0 ->
        synth_b_pending cannot arm, because the pre-TL-042 arm is gated on
        `& (sub_wr_os_ctr != 3'd0)` -> wr_hold_clr (W-last handshake | synth_b_
        pending) never asserts -> wr_hold_r stays 1. Forever.
    The round-2 capture also caught sub_stall_ctr_r spanning 0..65536, i.e.
    sub_stall_expired GENUINELY FIRES and arming still cannot happen — so the
    `!= 0` conjunct is the decisive blocker, measured rather than argued.

    WHAT THIS TEST REPRODUCES, AND WHAT IT DOES NOT: it recreates the deadlock
    STATE (wr_hold_r set, no AW acceptable, ctr==0) by holding the AXI subordinate
    handshakes low, then checks the bus escapes. It does NOT reproduce silicon's
    causal ENTRY into that state (which the ILA measured but whose trigger is not
    yet identified). The fix is a state-escape, so the state is the right thing to
    test — but this is not an end-to-end repro and must not be described as one.

    A/B (the non-vacuity contract): FAILS on the pre-TL-042 RTL (wr_hold_r is still
    high after the timeout, hreadyout still low) and PASSES with the fix.

    Also asserts the companion safety property: the escape must NOT inject a
    synthetic B toward XHB500, which has no outstanding write here (ctr==0).
    Injecting one would answer a transaction that does not exist. The RTL enforces
    that by gating on the ARM SOURCE (synth_b_holdclr_only_r) rather than on
    `(sub_wr_os_ctr != 0)` at injection time, because Fix K can legitimately need a
    synth-B at ctr==0 and a ctr-based guard cannot tell the two cases apart."""
    tb = PairV2TB(dut); master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True); _force_fix_off(tb, False)

    m = dut.u_master

    # Sanity: the write path is alive BEFORE we freeze it (guards against a
    # vacuous pass where the bus was already dead and "recovery" is meaningless).
    await master.write(APER_BASE + 0x100, 0xC0FFEE03)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, 0x100) == 0xC0FFEE03, "sanity write failed"

    # Recreate the measured state: no AW can be accepted (=> sub_wr_os_ctr stays 0,
    # exactly as the ILA measured) and no W beat can complete (=> the W-last arm of
    # wr_hold_clr can never fire).
    m.s_axi_awready.value = Force(0)
    m.s_axi_wready.value  = Force(0)
    await ClockCycles(dut.hclk, 10)

    # Address-latch a bufferable peer write -> wr_hold_set = ext_is_nonseq &
    # ahb_sub_hwrite & ~pipe_valid_r.
    clk = dut.hclk
    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value   = 1; dut.m_ahb_sub_haddr.value  = APER_BASE + 0x300
    dut.m_ahb_sub_htrans.value = 2; dut.m_ahb_sub_hsize.value  = 2
    dut.m_ahb_sub_hburst.value = 0; dut.m_ahb_sub_hprot.value  = 0x4   # bufferable
    dut.m_ahb_sub_hwrite.value = 1; dut.m_ahb_sub_hready.value = 1
    dut.m_ahb_sub_hwdata.value = 0xDEAD0042
    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value = 0; dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hwrite.value = 0
    await ClockCycles(clk, 20)

    # Non-vacuity #1: we must actually be IN the deadlock state, or a later
    # "recovered" reading proves nothing.
    assert _sig(m.wr_hold_r) == 1, "wr_hold_r never set — deadlock state not entered"
    assert _sig(m.ahb_sub_hreadyout) == 0, "hreadyout not held low — state not entered"
    assert int(m.sub_wr_os_ctr.value) == 0, (
        f"sub_wr_os_ctr={int(m.sub_wr_os_ctr.value)} != 0 — this is NOT the measured "
        "silicon state (an AW got accepted); the pre-TL-042 arm could fire here, so "
        "the test would pass for the wrong reason")
    dut._log.info("[tl042] deadlock state entered: wr_hold_r=1 hreadyout=0 ctr=0")

    # Watch for the escape. The counter is 2**SUB_OUTSTANDING_TIMEOUT_LOG2 (=65536)
    # hclk; allow generous margin. Pre-fix this loop simply runs out.
    bvalid_seen = 0; escaped_at = None
    for c in range(90_000):
        await RisingEdge(clk)
        if _sig(m.s_axi_bvalid):
            bvalid_seen += 1
        if escaped_at is None and _sig(m.wr_hold_r) == 0:
            escaped_at = c
            # Let hreadyout settle, keep watching B for a few more cycles.
            for _ in range(20):
                await RisingEdge(clk)
                if _sig(m.s_axi_bvalid):
                    bvalid_seen += 1
            break

    dut._log.info(f"[tl042] escaped_at={escaped_at} wr_hold_r={_sig(m.wr_hold_r)} "
                  f"hreadyout={_sig(m.ahb_sub_hreadyout)} "
                  f"synth_b_pending={_sig(m.synth_b_pending)} "
                  f"holdclr_only={_osig(m, 'synth_b_holdclr_only_r')} "
                  f"bvalid_seen={bvalid_seen}")
    # Full override-mux walk, so an incomplete escape names the rank that held the
    # bus instead of leaving it to be guessed. Order matches tidelink_top.sv :1909.
    ranks = {
        "r1_sub_err1_r":      _sig(m.sub_err1_r),
        "r2_sub_err2_r":      _sig(m.sub_err2_r),
        "r3_ext_is_nonseq":   _sig(m.ext_is_nonseq),
        "r3_pipe_valid_r":    _sig(m.pipe_valid_r),
        "r4_rd_pipe_r":       _sig(m.rd_pipe_r),
        "r5_wr_hold_r":       _sig(m.wr_hold_r),
    }
    dut._log.info(f"[tl042] override-mux walk at escape: {ranks}")

    assert escaped_at is not None, (
        "wr_hold_r STILL HIGH after 90k hclk with no AW acceptable and no W beat "
        "possible — the AHB bus is held forever by TL-002's own hold. This is the "
        "die_a ILA state (round-2, 2026-08-13) and it is the TL-042 deadlock.")
    # Every override rank is now false. NOTE: ahb_sub_hreadyout may still read 0
    # here, and that is THIS TEST's artifact, not a wrapper defect — with
    # s_axi_awready/wready forced low, XHB500 is itself stalled and legitimately
    # holds its raw hreadyout low, which the mux passes through at the fallthrough.
    # (Measured: at the escape all six rank terms read 0 while hreadyout read 0.)
    # In the silicon state ranks 1-4 were already false and the bridge was live, so
    # rank 5 was the only thing holding the bus. The meaningful contract is
    # therefore that SERVICE RESUMES once the AXI side can make progress again.
    assert all(v == 0 for v in ranks.values()), (
        f"an override rank is still asserted after the escape: {ranks} — the escape "
        "is incomplete")
    # Companion safety property: no B for a write XHB500 never issued.
    assert bvalid_seen == 0, (
        f"s_axi_bvalid asserted {bvalid_seen} cycles during the hold-release escape "
        "while sub_wr_os_ctr==0 — a synthetic B was injected toward XHB500 for a "
        "write it never issued. The arm-source gate (synth_b_holdclr_only_r) is not "
        "suppressing the injection.")

    # ---- WHAT THIS TEST DELIBERATELY DOES NOT ASSERT (measured, 2026-08-13) ----
    # End-to-end service resumption is NOT provable in this tb, and the attempt is
    # recorded here rather than quietly dropped. The only way to synthesise the
    # deadlock STATE here is to hold s_axi_awready/wready low; sustaining that for
    # the full 65536-cycle timeout wedges XHB500 ITSELF, independently of the
    # wrapper. Measured: after Release() + 2000 cycles, ahb_sub_hreadyout stays low
    # with ALL SIX override ranks reading 0 — i.e. the residual low is the bridge's
    # own raw hreadyout at the mux fallthrough, collateral from the entry
    # mechanism, not the wrapper hold this fix addresses.
    # The silicon state (round-2 ILA) had a LIVE bridge with ranks 1-4 already
    # false, so rank-5 release is the whole of the wrapper-side fix there. Proving
    # that the bus then carries traffic is a BENCH result, not a sim result.
    # This mirrors test #2 in this file, which was kept SKIPPED for the same honest
    # reason: do not ship a test that passes for the wrong reason.
    m.s_axi_awready.value = Release()
    m.s_axi_wready.value  = Release()
    await ClockCycles(clk, 2000)
    dut._log.info(f"[tl042] post-release (NOT asserted, tb limitation): "
                  f"hreadyout={_sig(m.ahb_sub_hreadyout)} "
                  f"wr_hold_r={_sig(m.wr_hold_r)}")
    dut._log.info(f"[tl042] PASS: hold escaped at cycle {escaped_at} (would be "
                  "never pre-fix), all override ranks cleared, and no spurious B "
                  "was presented to XHB500")

    _release_all(tb)
    await ClockCycles(dut.hclk, 50)



# ═══════════════════════════════════════════════════════════════════════════════
# TL-042 v2 (2026-08-13) — acceptance tests for the SECOND candidate fix.
#
# v1 was REJECTED ON SILICON (16/16 byte-exact -> 0/16, n=2, die_b image
# byte-identical, healthy bring-up every run) because it released the hold through
# `synth_b_pending`, which is a term of `wr_hold_clr` and therefore DISABLES the
# TL-002 peer-write data-phase hold wholesale for as long as it is high.
# v1's sim test asserted only that the hold ESCAPES. These tests add the two
# assertions that would have caught it (synth_b_pending must not be the lever and
# must be 0 afterwards; a normal peer write must still land byte-exact once the
# arm has fired) plus the constraint-1 safety property.
#
#   test_tl042_v2_escape_is_clean_and_writes_still_land   (a)+(b)+(c)  [A/B arm]
#   test_tl042_v2_live_write_is_never_released            constraint-1 safety
#   test_tl042_v2_escape_with_stalled_bridge              silicon-faithful variant
#
# All three need a SHORT backstop threshold so the 2**16 age fits in a sim:
#   +define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13   (8192 hclk)
# which is the same knob (and the same value) the GAPS_BACKSTOP tests already use.
# `make tl042v2` passes it; TL042_TIMEOUT_LOG2 must agree with the define.
#
# ── TWO WAYS TO BUILD THE DEADLOCK STATE, AND WHY BOTH EXIST ──────────────────
# The wrapper-visible deadlock is: wr_hold_r=1, ahb_sub_hreadyout=0,
# sub_aw_accept=0, sub_wr_os_ctr=0, synth_b_pending=0, no W handshake possible.
# Two constructions reach it and they differ in ONE measured respect:
#
#   mode="valid_mask"   Force s_axi_awvalid / s_axi_wvalid LOW (the XHB500 side).
#       XHB500 sees ready high, believes both beats went out, and keeps
#       xhb_sub_hreadyout_raw HIGH — a LIVE bridge. The wrapper sees no AW accept
#       and no W handshake, so wr_hold_r latches with ctr=0.
#       MEASURED: raw=1 throughout. This is the only construction in which the
#       rank-5 release can be shown to RESTORE SERVICE, so it is the one the
#       primary test uses.
#
#   mode="ready_freeze" Force s_axi_awready / s_axi_wready LOW (the FC-node side).
#       XHB500 cannot issue the AW it accepted, so it drops
#       xhb_sub_hreadyout_raw to 0 one cycle after taking the address and DOES NOT
#       RECOVER when the freeze is lifted (measured: raw still 0 after 20000
#       cycles, with the AW-only freeze too — imp/hw_gate/tl042_v2/probe_awonly.log).
#       This is the SILICON-faithful variant: the round-2 die_a ILA has
#       sub_stall_ctr_r ramping +1/clk with sub_stall_fill=0 and
#       sub_err{1,2}_r=0, which forces sub_stall_busy=1, i.e.
#       xhb_sub_hreadyout_raw = 0 at the wedge. Releasing rank 5 there does NOT
#       raise ahb_sub_hreadyout, because the mux falls through to raw.
# ═══════════════════════════════════════════════════════════════════════════════
import os

TL042_LOG2 = int(os.environ.get("TL042_TIMEOUT_LOG2", "13"))
TL042_THRESH = 1 << TL042_LOG2


async def _enter_tl042_deadlock(dut, tb, m, addr, data=0xDEAD0042, mode="valid_mask"):
    """Recreate the MEASURED wrapper state (round-2 die_a ILA, 4096 contiguous
    samples, imp/hw_gate/ila_tl035_run_round2/ila_capture.csv):
    wr_hold_r=1, ahb_sub_hreadyout=0, sub_aw_accept=0, sub_wr_os_ctr=0,
    synth_b_pending=0, and no W handshake possible.

    This reproduces the STATE, not silicon's causal ENTRY into it (which the ILA
    measured but whose trigger is not identified). The fix is a state-escape, so
    the state is the right thing to test — this is not an end-to-end repro and
    must not be described as one. See the module header for the two modes."""
    clk = dut.hclk
    if mode == "valid_mask":
        m.s_axi_awvalid.value = Force(0)
        m.s_axi_wvalid.value  = Force(0)
    elif mode == "ready_freeze":
        m.s_axi_awready.value = Force(0)
        m.s_axi_wready.value  = Force(0)
    else:
        raise ValueError(mode)
    await ClockCycles(clk, 10)

    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value   = 1; dut.m_ahb_sub_haddr.value  = addr
    dut.m_ahb_sub_htrans.value = 2; dut.m_ahb_sub_hsize.value  = 2
    dut.m_ahb_sub_hburst.value = 0; dut.m_ahb_sub_hprot.value  = 0x4   # bufferable
    dut.m_ahb_sub_hwrite.value = 1; dut.m_ahb_sub_hready.value = 1
    dut.m_ahb_sub_hwdata.value = data
    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value = 0; dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hwrite.value = 0
    await ClockCycles(clk, 20)

    st = {"mode":            mode,
          "wr_hold_r":       _sig(m.wr_hold_r),
          "hreadyout":       _sig(m.ahb_sub_hreadyout),
          "sub_wr_os_ctr":   _sig(m.sub_wr_os_ctr),
          "synth_b_pending": _sig(m.synth_b_pending),
          "pipe_valid_r":    _sig(m.pipe_valid_r),
          "xhb_raw":         _osig(m, "xhb_sub_hreadyout_raw"),
          "aw_since_hold_r": _osig(m, "aw_since_hold_r")}
    dut._log.info(f"[tl042v2] deadlock entry state: {st}")
    assert st["wr_hold_r"] == 1, f"wr_hold_r never set — deadlock state not entered ({st})"
    assert st["hreadyout"] == 0, f"hreadyout not held low — state not entered ({st})"
    assert st["sub_wr_os_ctr"] == 0, (
        f"sub_wr_os_ctr={st['sub_wr_os_ctr']} != 0 — this is NOT the measured silicon "
        f"state (an AW got accepted), so the PRE-EXISTING synth-B arm could fire and "
        f"the test would pass for the wrong reason ({st})")
    assert st["synth_b_pending"] == 0, f"synth_b_pending already high at entry ({st})"
    return st


def _release_deadlock(m, mode):
    if mode == "valid_mask":
        m.s_axi_awvalid.value = Release(); m.s_axi_wvalid.value = Release()
    else:
        m.s_axi_awready.value = Release(); m.s_axi_wready.value = Release()


async def _watch_escape(dut, m, clk, budget):
    """Run until wr_hold_r drops or the budget expires. Returns the escape cycle
    (or None) plus everything (b) needs to be decided."""
    escaped_at = None; bvalid_seen = 0; sbp_during = 0; clr_at_escape = None
    for c in range(budget):
        await RisingEdge(clk)
        if _sig(m.s_axi_bvalid):    bvalid_seen += 1
        if _sig(m.synth_b_pending): sbp_during  += 1
        if _sig(m.wr_hold_r) == 0:
            escaped_at = c
            clr_at_escape = _osig(m, "wr_hold_clr")
            break
    return {"escaped_at": escaped_at, "bvalid_seen": bvalid_seen,
            "sbp_during": sbp_during, "clr_at_escape": clr_at_escape}


def _rank_walk(m):
    """The ahb_sub_hreadyout override mux, in tidelink_top.sv priority order."""
    return {"r1_sub_err1_r":    _sig(m.sub_err1_r),
            "r2_sub_err2_r":    _sig(m.sub_err2_r),
            "r3_ext_is_nonseq": _sig(m.ext_is_nonseq),
            "r3_pipe_valid_r":  _sig(m.pipe_valid_r),
            "r4_rd_pipe_r":     _sig(m.rd_pipe_r),
            "r5_wr_hold_r":     _sig(m.wr_hold_r)}


def _assert_escape_was_clean(o, m, sbp_after, dut):
    """(b) — the release must clear wr_hold_r ONLY. Three independent ways."""
    assert o["sbp_during"] == 0, (
        f"synth_b_pending was high for {o['sbp_during']} cycles during the escape "
        "window — the hold was released THROUGH the signal that disables it "
        "wholesale (wr_hold_clr = W-last | synth_b_pending). That is the v1 "
        "mechanism that regressed the data plane on silicon (16/16 -> 0/16, n=2).")
    assert o["clr_at_escape"] == 0, (
        f"wr_hold_clr={o['clr_at_escape']} at the escape — the hold was released by "
        "the wholesale-disable path, not by a wr_hold_r-only release.")
    assert _sig(m.synth_b_pending) == 0 and sbp_after == 0, (
        f"synth_b_pending did not return to / stay at 0 after the escape "
        f"(now={_sig(m.synth_b_pending)}, {sbp_after} high cycles post-escape) — "
        "while it is high the TL-002 peer-write hold is disabled and payloads drop.")
    assert o["bvalid_seen"] == 0, (
        f"s_axi_bvalid asserted {o['bvalid_seen']} cycles while sub_wr_os_ctr==0 — a "
        "synthetic B was injected toward XHB500 for a write it never issued.")


@cocotb.test()
async def test_tl042_v2_escape_is_clean_and_writes_still_land(dut):
    """TL-042 v2 PRIMARY — the three properties a candidate must satisfy TOGETHER.

    (a) ESCAPE. From the measured deadlock state, wr_hold_r must drop within the
        starvation timeout and every ahb_sub_hreadyout override rank must clear.
        Pre-fix it never drops — that is the A/B FAIL arm.

    (b) THE ESCAPE MUST NOT GO THROUGH synth_b_pending, AND synth_b_pending MUST
        BE 0 AFTERWARDS. `wr_hold_clr = (W-last handshake) | synth_b_pending`, so
        synth_b_pending DISABLES the TL-002 peer-write hold while it is high. v1
        used it as the release lever and dropped every peer-write payload on
        silicon. Asserted three ways: synth_b_pending never rises across the escape
        window; wr_hold_clr reads 0 at the escape itself; s_axi_bvalid is never
        driven (no synthetic B for a write XHB500 never issued, ctr==0 here).

    (c) A NORMAL PEER WRITE STILL LANDS AFTER THE ARM HAS FIRED — the assertion
        that would have caught v1. Three parts:
          c0 the hold RE-ARMS: a fresh peer-write address phase sets wr_hold_r
             again. With v1's latched synth_b_pending it cannot set at all.
          c1 WHITE-BOX: ahb_sub_hreadyout must not complete before that write's W
             handshake (the TL-002 contract itself).
          c2 END-TO-END: the payload arrives byte-exact in die_b's SRAM.

    A/B (non-vacuity): FAILS on pristine RTL at (a) — "wr_hold_r STILL HIGH".
    Measured 2026-08-13 on RTL md5 b75d391b0f659d808ac0a4cb37310643.
    """
    tb = PairV2TB(dut); master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True); _force_fix_off(tb, False)
    clk = dut.hclk; m = dut.u_master

    # Sanity: the write path is ALIVE before we freeze it (guards a vacuous pass
    # where the bus was already dead and "recovery" would be meaningless).
    await master.write(APER_BASE + 0x100, 0xC0FFEE04)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, 0x100) == 0xC0FFEE04, "sanity write failed"

    st = await _enter_tl042_deadlock(dut, tb, m, APER_BASE + 0x300, mode="valid_mask")
    # Non-vacuity for (c): this construction must leave the BRIDGE live, otherwise
    # "service resumes" would be untestable and (c) would fail for a tb reason.
    assert st["xhb_raw"] == 1, (
        f"xhb_sub_hreadyout_raw={st['xhb_raw']} at entry — the bridge is stalled, so "
        "rank-5 release cannot raise ahb_sub_hreadyout and (c) cannot be decided "
        "here. Use test_tl042_v2_escape_with_stalled_bridge for that case.")

    # ---------------- (a) escape ------------------------------------------------
    o = await _watch_escape(dut, m, clk, TL042_THRESH * 3)
    ranks = _rank_walk(m)
    dut._log.info(f"[tl042v2] escaped_at={o['escaped_at']} (thresh={TL042_THRESH}) "
                  f"wr_hold_clr@escape={o['clr_at_escape']} "
                  f"sbp_cycles_during={o['sbp_during']} bvalid_seen={o['bvalid_seen']} "
                  f"expired={_osig(m,'wr_hold_stuck_expired')} "
                  f"sticky={_osig(m,'wr_hold_stuck_sticky')} ranks={ranks}")
    assert o["escaped_at"] is not None, (
        f"wr_hold_r STILL HIGH after {TL042_THRESH*3} hclk with no AW acceptable and "
        "no W beat possible — the AHB bus is held forever by TL-002's own hold. This "
        "is the die_a round-2 ILA state (imp/hw_gate/ila_tl035_run_round2/) and it is "
        "the TL-042 deadlock.")
    assert all(v == 0 for v in ranks.values()), (
        f"an ahb_sub_hreadyout override rank is still asserted after the escape: "
        f"{ranks} — the escape is incomplete")

    # ---------------- (b) the release cleared wr_hold_r and nothing else --------
    sbp_after = 0
    for _ in range(500):
        await RisingEdge(clk)
        if _sig(m.synth_b_pending): sbp_after += 1
        if _sig(m.s_axi_bvalid):    o["bvalid_seen"] += 1
    dut._log.info(f"[tl042v2] post-escape: hreadyout={_sig(m.ahb_sub_hreadyout)} "
                  f"raw={_osig(m,'xhb_sub_hreadyout_raw')} "
                  f"synth_b_pending={_sig(m.synth_b_pending)} "
                  f"sbp_cycles_after={sbp_after} bvalid_seen={o['bvalid_seen']}")
    _assert_escape_was_clean(o, m, sbp_after, dut)
    # With a LIVE bridge the rank-5 release is the whole of the wrapper-side wedge,
    # so the PS-facing bus must actually come back. (This is the property the v1
    # pre-registration said could not be shown in sim; the valid-mask construction
    # is what makes it showable.)
    assert _sig(m.ahb_sub_hreadyout) == 1, (
        f"ahb_sub_hreadyout still low after the escape with a live bridge "
        f"(raw={_osig(m,'xhb_sub_hreadyout_raw')}, ranks={_rank_walk(m)}) — the "
        "escape did not restore the PS-facing bus.")

    # ---------------- (c) a NORMAL peer write must still land -------------------
    _release_deadlock(m, "valid_mask")
    await ClockCycles(clk, 5000)

    PAYLOAD = 0x5EED0042; TGT = 0x340
    o2 = await _drive_bufferable_write_watch(dut, APER_BASE + TGT, PAYLOAD, timeout=20000)
    await ClockCycles(clk, 20000)
    got = _slave_bram_peek(dut, TGT)
    # c0: did the hold actually RE-ARM on this write? trace[i] = (pv,rdyo,wv,wr,wrh)
    rearmed = any(t[4] == 1 for t in o2["trace"])
    dut._log.info(f"[tl042v2] (c) post-arm normal write: rearmed={rearmed} "
                  f"early_ready={o2['early_ready']} w_hs_seen={o2['w_hs_seen']} "
                  f"completed={o2['completed']} rdy_cyc={o2['rdy_cyc']} "
                  f"whs_cyc={o2['whs_cyc']} die_b=0x{(got if got is not None else 0):08x} "
                  f"exp=0x{PAYLOAD:08x} sbp={_sig(m.synth_b_pending)} trace={o2['trace']}")

    assert o2["seen_low"] and o2["w_hs_seen"] and o2["completed"], (
        f"the post-arm write did not run to completion — (c) would be vacuous ({o2})")
    assert rearmed, (
        "wr_hold_r never SET on the post-arm peer write — the TL-002 peer-write "
        "data-phase hold is DEAD after the escape. This is v1's failure mode: with "
        "synth_b_pending latched high, wr_hold_clr is permanently asserted and the "
        "hold can never engage, so every subsequent peer write drops its payload.")
    assert not o2["early_ready"], (
        "TL-002 IS DEFEATED AFTER THE ARM FIRED: ahb_sub_hreadyout completed BEFORE "
        f"the W beat (rdy_cyc={o2['rdy_cyc']} < whs_cyc={o2['whs_cyc']}) on a normal "
        "bufferable peer write. The master releases HWDATA early and the payload "
        "drops — exactly the silicon regression v1 shipped.")
    assert got == PAYLOAD, (
        f"post-arm peer write did NOT land byte-exact: die_b SRAM=0x{got:08x} != "
        f"0x{PAYLOAD:08x}. The escape damaged the data plane.")

    dut._log.info(f"[tl042v2] PASS: escaped at {o['escaped_at']} without touching "
                  "synth_b_pending, bus restored, hold re-armed, and a normal peer "
                  "write still lands byte-exact")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)


@cocotb.test()
async def test_tl042_v2_live_write_is_never_released(dut):
    """TL-042 v2 SAFETY (constraint 1) — the escape must be UNREACHABLE by a write
    that is legitimately waiting for its W beat.

    v1 armed on `wr_hold_r && (sub_wr_os_ctr == 0)`. On the bufferable/EWR path an
    early B can return that counter to 0 while wr_hold_r is still VALIDLY holding
    for its W beat, so v1's arm could fire on a live write. v2 arms on
    `wr_hold_r && !aw_since_hold_r` — "no AW accepted SINCE this hold was set" —
    which a live write can never satisfy, because its own AW-accept is strictly
    later than its own wr_hold_set (during the pipeline-fill cycle xhb_sub_hready
    is driven low, so XHB500 cannot even take the address until the next cycle).

    CONSTRUCTION: freeze ONLY s_axi_wready. The AW is accepted normally
    (aw_since_hold_r -> 1) while the W beat can never complete, so wr_hold_r holds
    for far longer than the starvation timeout. The age counter must stay pinned
    near 0 and the escape must never fire. Then release wready: the write must
    complete and land byte-exact.

    Only meaningful POST-fix (the probed nets do not exist pre-fix); this is a
    safety property, not the A/B discriminator."""
    tb = PairV2TB(dut); master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True); _force_fix_off(tb, False)
    clk = dut.hclk; m = dut.u_master

    await master.write(APER_BASE + 0x100, 0xC0FFEE05)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, 0x100) == 0xC0FFEE05, "sanity write failed"

    PAYLOAD = 0xA11E0042; TGT = 0x380
    m.s_axi_wready.value = Force(0)          # ONLY W frozen: the AW gets accepted
    await ClockCycles(clk, 10)

    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value   = 1; dut.m_ahb_sub_haddr.value  = APER_BASE + TGT
    dut.m_ahb_sub_htrans.value = 2; dut.m_ahb_sub_hsize.value  = 2
    dut.m_ahb_sub_hburst.value = 0; dut.m_ahb_sub_hprot.value  = 0x4
    dut.m_ahb_sub_hwrite.value = 1; dut.m_ahb_sub_hready.value = 1
    dut.m_ahb_sub_hwdata.value = PAYLOAD
    await RisingEdge(clk)
    dut.m_ahb_sub_hsel.value = 0; dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hwrite.value = 0

    # Watch for 2x the starvation threshold. The AW must be seen, the age counter
    # must stay pinned near 0, and the escape must never fire.
    aw_seen = 0; ctr_max = 0; expired_seen = 0; hold_low = 0
    for _ in range(TL042_THRESH * 2):
        await RisingEdge(clk)
        if _sig(m.sub_aw_accept):                    aw_seen += 1
        v = _osig(m, "wr_hold_stuck_ctr_r")
        if v is not None and v > ctr_max:            ctr_max = v
        if _osig(m, "wr_hold_stuck_expired") == 1:   expired_seen += 1
        if _sig(m.wr_hold_r) == 0:                   hold_low += 1

    dut._log.info(f"[tl042v2-safe] aw_accepts={aw_seen} aw_since_hold_r="
                  f"{_osig(m,'aw_since_hold_r')} stuck_ctr_max={ctr_max} "
                  f"(thresh={TL042_THRESH}) expired_cycles={expired_seen} "
                  f"wr_hold_low_cycles={hold_low} sticky={_osig(m,'wr_hold_stuck_sticky')} "
                  f"sbp={_sig(m.synth_b_pending)} ctr={_sig(m.sub_wr_os_ctr)}")

    assert aw_seen >= 1, (
        "no AW was ever accepted — the intended live-write condition was not built, "
        "so 'the arm did not fire' proves nothing (vacuous).")
    assert expired_seen == 0, (
        f"the TL-042 starvation escape FIRED on a live write (expired for "
        f"{expired_seen} cycles) — it is reachable by a write that is legitimately "
        "waiting for its W beat. That defeats TL-002 and drops the payload.")
    assert ctr_max < TL042_THRESH, (
        f"wr_hold_stuck_ctr_r reached {ctr_max} >= {TL042_THRESH} on a live write — "
        "the starvation age is not being reset by this write's own AW-accept.")
    assert _osig(m, "wr_hold_stuck_sticky") == 0, "TL-042 escape witness set on a live write"

    # Release W: the write must complete normally and land byte-exact.
    m.s_axi_wready.value = Release()
    await ClockCycles(clk, 20000)
    dut.m_ahb_sub_hwdata.value = 0
    got = _slave_bram_peek(dut, TGT)
    dut._log.info(f"[tl042v2-safe] after W release: wr_hold_r={_sig(m.wr_hold_r)} "
                  f"die_b=0x{(got if got is not None else 0):08x} exp=0x{PAYLOAD:08x}")
    assert got == PAYLOAD, (
        f"the held write did not land byte-exact after W backpressure lifted: "
        f"die_b SRAM=0x{got:08x} != 0x{PAYLOAD:08x}")

    dut._log.info("[tl042v2-safe] PASS: a live write never reaches the starvation "
                  "escape, and lands byte-exact once its W beat can complete")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)


@cocotb.test()
async def test_tl042_v2_escape_with_stalled_bridge(dut):
    """TL-042 v2 SCOPE — the escape is NECESSARY BUT NOT SUFFICIENT when XHB500 is
    itself stalled, which is the state the SILICON ILA actually measured.

    WHY THIS TEST EXISTS. The round-2 die_a capture is usually summarised as
    "ranks 1-4 are false, so rank-5 wr_hold_r is the SOLE term driving
    ahb_sub_hreadyout low". That is true about MUX PRIORITY and false as an
    implication, because the mux FALLTHROUGH (xhb_sub_hreadyout_raw) was also 0:
    in the same capture sub_stall_ctr_r ramps +1/clk through 2**16, and
    sub_ext_stalled = (sub_stall_fill || sub_stall_busy) && !sub_err1_r &&
    !sub_err2_r with sub_stall_fill = (ext_is_nonseq && !pipe_valid_r) = 0 and
    sub_err{1,2}_r = 0, so sub_stall_busy = !xhb_sub_hreadyout_raw must be 1.
    Releasing rank 5 therefore does NOT raise ahb_sub_hreadyout on silicon.

    This test pins that down as a property rather than a footnote: with the
    ready-freeze construction the bridge is genuinely stalled, the escape still
    fires cleanly (a + b hold), and ahb_sub_hreadyout stays low at the
    fallthrough. Anyone who later claims "TL-042 v2 unwedges die_a" has to explain
    this test."""
    tb = PairV2TB(dut); master = AHBSubMaster(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 200)
    _force_axi_crc(tb, True); _force_fix_off(tb, False)
    clk = dut.hclk; m = dut.u_master

    await master.write(APER_BASE + 0x100, 0xC0FFEE08)
    await ClockCycles(dut.hclk, 2000)
    assert _slave_bram_peek(dut, 0x100) == 0xC0FFEE08, "sanity write failed"

    st = await _enter_tl042_deadlock(dut, tb, m, APER_BASE + 0x3C0, mode="ready_freeze")
    assert st["xhb_raw"] == 0, (
        f"xhb_sub_hreadyout_raw={st['xhb_raw']} — the ready-freeze construction did "
        "NOT stall the bridge, so this test is not exercising the silicon-faithful "
        "case and its conclusion would be vacuous.")

    o = await _watch_escape(dut, m, clk, TL042_THRESH * 3)
    ranks = _rank_walk(m)
    sbp_after = 0
    for _ in range(500):
        await RisingEdge(clk)
        if _sig(m.synth_b_pending): sbp_after += 1
        if _sig(m.s_axi_bvalid):    o["bvalid_seen"] += 1
    raw_after = _osig(m, "xhb_sub_hreadyout_raw")
    rdyo_after = _sig(m.ahb_sub_hreadyout)
    dut._log.info(f"[tl042v2-stalled] escaped_at={o['escaped_at']} "
                  f"wr_hold_clr@escape={o['clr_at_escape']} sbp_during={o['sbp_during']} "
                  f"sbp_after={sbp_after} bvalid_seen={o['bvalid_seen']} "
                  f"ranks={ranks} raw_after={raw_after} hreadyout_after={rdyo_after}")

    assert o["escaped_at"] is not None, (
        f"wr_hold_r STILL HIGH after {TL042_THRESH*3} hclk — the TL-042 deadlock.")
    assert all(v == 0 for v in ranks.values()), (
        f"an override rank is still asserted after the escape: {ranks}")
    _assert_escape_was_clean(o, m, sbp_after, dut)

    # THE SCOPE STATEMENT, asserted rather than annotated.
    assert raw_after == 0 and rdyo_after == 0, (
        f"expected the stalled-bridge case to leave ahb_sub_hreadyout low at the mux "
        f"fallthrough (raw={raw_after}, hreadyout={rdyo_after}). If this now passes "
        "traffic, the bridge recovered on its own and the scope claim in "
        "imp/hw_gate/tl042_v2/DESIGN_NOTE.md must be revisited.")
    dut._log.info("[tl042v2-stalled] PASS: the escape is clean but the PS-facing bus "
                  "stays low because xhb_sub_hreadyout_raw is 0 — TL-042 v2 is "
                  "NECESSARY BUT NOT SUFFICIENT for the measured silicon wedge")
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)
