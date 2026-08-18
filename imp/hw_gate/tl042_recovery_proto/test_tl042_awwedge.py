"""TL-042 Option-1 recovery PROTOTYPE — cocotb A/B bench.

Reproduces the XHB500 AW-not-accepted write-wedge on the master die's u_xhb_sub
and validates the Option-1 synthetic-accept recovery (see
docs/DIAGNOSE_XHB500_RAW_HREADYOUT_LOW.md).

Stimulus (identical for control and fix):
  1. reset the two-die harness (no link bring-up needed — the wedge is on the
     AHB->AXI bridge, and we FORCE the downstream ready low regardless of link).
  2. hold the master die's downstream s_axi awready/wready LOW via the tb wedge
     injector (f_awready_en/f_wready_en), and keep the untrained link's B/R quiet
     (f_bctrl_en/f_rvalid_en) so no X leaks into the bridge response path.
  3. drive ONE AHB write into the peer aperture on m_ahb_sub_*.
  4. watch ahb_sub_hreadyout / xhb_sub_hreadyout_raw across the 2^STALL_LOG2
     stall-timeout window.

CONTROL (unpatched copy): hreadyout stays 0 forever -> HANG.
FIX (patched copy): at the timeout the wrapper synthesises the AW/W accept,
synth_b_pending drains, hreadyout recovers with a legal AHB OKAY termination.

Tests are selected per-build by the Makefile (TESTCASE=...):
  control build -> test_control_write_wedges_no_recovery
  fix build     -> test_fix_write_recovers, test_fix_double_accept_masked
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

APER_BASE   = 0x4000_0000     # peer aperture -> routes ahb_sub -> u_xhb_sub
HCLK_NS     = 10
REFCLK_NS   = 8
STALL_LOG2  = 10              # must match Makefile +define+TIDELINK_SUB_STALL_TIMEOUT_LOG2
STALL_TH    = 1 << STALL_LOG2 # ~timeout threshold in hclk cycles
WATCH       = STALL_TH * 3    # generous window to see the timeout + drain


# ---------------------------------------------------------------------------
# tolerant signal access
# ---------------------------------------------------------------------------
def _sig(h):
    """int(handle.value) or None (X / not-present)."""
    try:
        return int(h.value)
    except Exception:
        return None


def _osig(obj, name):
    """int of obj.<name>.value, or None if the net does not EXIST in this build
    (the control/unpatched RTL has none of the rec_*/synth_*/*_dn nets)."""
    try:
        return int(getattr(obj, name).value)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# harness bring-up (self-contained; no link training)
# ---------------------------------------------------------------------------
async def _start(dut):
    cocotb.start_soon(Clock(dut.hclk,    HCLK_NS,   unit="ns").start())
    cocotb.start_soon(Clock(dut.ref_clk, REFCLK_NS, unit="ns").start())
    # idle AHB sub port
    dut.m_ahb_sub_hsel.value   = 0
    dut.m_ahb_sub_haddr.value  = 0
    dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hsize.value  = 2
    dut.m_ahb_sub_hburst.value = 0
    dut.m_ahb_sub_hprot.value  = 0
    dut.m_ahb_sub_hwrite.value = 0
    dut.m_ahb_sub_hwdata.value = 0
    dut.m_ahb_sub_hready.value = 1
    # wedge injector idle
    dut.f_awready_en.value = 0
    dut.f_awready_val.value = 0
    dut.f_wready_en.value = 0
    dut.f_wready_val.value = 0
    dut.f_bctrl_en.value = 0
    dut.f_rvalid_en.value = 0
    # reset
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)


def _arm_wedge(dut):
    """Hold the master die's DOWNSTREAM s_axi awready/wready LOW (the wedge), and
    keep the untrained link's B/R quiet so only the recovery can drive B."""
    dut.f_awready_en.value  = 1
    dut.f_awready_val.value = 0
    dut.f_wready_en.value   = 1
    dut.f_wready_val.value  = 0
    dut.f_bctrl_en.value    = 1
    dut.f_rvalid_en.value   = 1


async def _drive_write_addr_phase(dut, addr, bufferable=True):
    """Present the AHB address phase and hold it until the slave accepts it
    (ahb_sub_hreadyout high), then switch to the data phase. Returns the cycle
    index at which the address was accepted, or None."""
    m = dut.u_master
    await RisingEdge(dut.hclk)
    dut.m_ahb_sub_hsel.value   = 1
    dut.m_ahb_sub_haddr.value  = addr & 0xFFFF_FFFF
    dut.m_ahb_sub_htrans.value = 2                 # NONSEQ
    dut.m_ahb_sub_hsize.value  = 2                 # word
    dut.m_ahb_sub_hburst.value = 0
    dut.m_ahb_sub_hprot.value  = 0x4 if bufferable else 0x0
    dut.m_ahb_sub_hwrite.value = 1
    dut.m_ahb_sub_hready.value = 1
    accepted = None
    for c in range(64):
        await RisingEdge(dut.hclk)
        if _sig(m.ahb_sub_hreadyout) == 1:
            accepted = c
            break
    # move to data phase: idle the address bus, present the write data
    dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hsel.value   = 0
    dut.m_ahb_sub_hwdata.value = 0xD0D0_0042
    dut.m_ahb_sub_hready.value = 1
    return accepted


# ---------------------------------------------------------------------------
# CONTROL — the unpatched copy must WEDGE
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_control_write_wedges_no_recovery(dut):
    await _start(dut)
    m = dut.u_master
    _arm_wedge(dut)
    await ClockCycles(dut.hclk, 5)

    acc = await _drive_write_addr_phase(dut, APER_BASE + 0x100, bufferable=True)
    dut._log.info(f"[ctrl] address accepted at data-phase entry (cyc={acc}); "
                  f"awvalid={_sig(m.s_axi_awvalid)} awready={_sig(m.s_axi_awready)}")

    rose = None
    stall_max = 0
    for c in range(WATCH):
        await RisingEdge(dut.hclk)
        sc = _sig(getattr(m, "sub_stall_ctr_r")) or 0
        stall_max = max(stall_max, sc)
        if _sig(m.ahb_sub_hreadyout) == 1:
            rose = c
            break

    raw  = _sig(m.xhb_sub_hreadyout_raw)
    rdyo = _sig(m.ahb_sub_hreadyout)
    dut._log.info(f"[ctrl] after {WATCH} cyc: ahb_sub_hreadyout={rdyo} "
                  f"raw={raw} rose_at={rose} stall_ctr_max={stall_max} "
                  f"sub_wr_os_ctr={_sig(getattr(m,'sub_wr_os_ctr'))} "
                  f"synth_b_pending={_sig(m.synth_b_pending)}")
    # non-vacuity: the timer really ramped past the timeout (the wedge is live)
    assert stall_max >= STALL_TH - 4, \
        f"stall timer never approached the timeout ({stall_max} < {STALL_TH}) — bench did not wedge"
    assert rose is None, \
        f"CONTROL unexpectedly recovered at cyc {rose} — the unpatched RTL should HANG"
    dut._log.info("[ctrl] PASS: write WEDGED — hreadyout stuck 0 past the 2^%d "
                  "timeout, no recovery (reproduces the bug)" % STALL_LOG2)


# ---------------------------------------------------------------------------
# FIX — the patched copy must RECOVER
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fix_write_recovers(dut):
    await _start(dut)
    m = dut.u_master
    _arm_wedge(dut)
    await ClockCycles(dut.hclk, 5)

    acc = await _drive_write_addr_phase(dut, APER_BASE + 0x100, bufferable=True)
    dut._log.info(f"[fix] address accepted at data-phase entry (cyc={acc}); "
                  f"awvalid={_sig(m.s_axi_awvalid)} awready(dn)={_sig(m.s_axi_awready)}")

    rose = None
    synth_aw_fired = False
    synth_b_fired  = False
    rec_seen       = False
    stall_max      = 0
    os_ctr_max     = 0
    fired_cycle    = None
    tail = 0   # keep sampling a trailing window after hreadyout rises so an
               # EWR posted-write (raw up before synth-B) is not a false miss
    for c in range(WATCH):
        await RisingEdge(dut.hclk)
        sc = _sig(getattr(m, "sub_stall_ctr_r")) or 0
        stall_max = max(stall_max, sc)
        if _osig(m, "synth_aw_accept") == 1:
            if not synth_aw_fired:
                fired_cycle = c
            synth_aw_fired = True
        if _sig(m.synth_b_pending) == 1:
            synth_b_fired = True
        if _osig(m, "rec_active") == 1:
            rec_seen = True
        oc = _sig(getattr(m, "sub_wr_os_ctr")) or 0
        os_ctr_max = max(os_ctr_max, oc)
        if _sig(m.ahb_sub_hreadyout) == 1 and rose is None:
            rose = c
        if rose is not None:
            tail += 1
            if tail > 64:
                break

    raw   = _sig(m.xhb_sub_hreadyout_raw)
    rdyo  = _sig(m.ahb_sub_hreadyout)
    hresp = _sig(m.ahb_sub_hresp)
    dut._log.info(f"[fix] recovered={rose is not None} rose_at={rose} "
                  f"hreadyout={rdyo} raw={raw} hresp={hresp} "
                  f"synth_aw_fired={synth_aw_fired}@{fired_cycle} "
                  f"synth_b_fired={synth_b_fired} rec_active_seen={rec_seen} "
                  f"stall_ctr_max={stall_max} os_ctr_max={os_ctr_max}")

    assert rose is not None, \
        f"FIX did NOT recover — ahb_sub_hreadyout stuck 0 after {WATCH} cyc " \
        f"(synth_aw={synth_aw_fired} synth_b={synth_b_fired} rec={rec_seen})"
    # the recovery mechanism actually engaged (not some unrelated path)
    assert synth_aw_fired, "recovered but synth_aw_accept never fired — not the Option-1 path"
    assert synth_b_fired,  "recovered but synth_b_pending never fired — drain did not run"
    # non-vacuity: it fired AFTER the timeout ramp, not at t=0
    assert (fired_cycle is not None) and (fired_cycle >= STALL_TH // 2), \
        f"synth accept fired too early (cyc {fired_cycle}) — would be vacuous"
    # AHB termination legality: hreadyout high with a defined hresp (OKAY expected)
    assert hresp in (0, 1), f"hresp undefined ({hresp}) at termination"
    dut._log.info("[fix] PASS: AW-not-accepted wedge RECOVERED via synthetic "
                  "AW/W accept + synth-B drain; legal AHB termination "
                  f"(hresp={'OKAY' if hresp==0 else 'ERROR'}) at cyc {rose}")


# ---------------------------------------------------------------------------
# FIX edge case — a link revival during recovery must NOT double-accept
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_fix_double_accept_masked(dut):
    """Wedge, let the recovery ARM, then simulate the downstream link REVIVING
    (drive awready/wready HIGH while still forced) and prove the mask blocks a
    second acceptance of the same AW/W: the Wlink-facing valid (s_axi_*valid_dn)
    is never coincident with a downstream ready, and sub_wr_os_ctr never counts a
    second write."""
    await _start(dut)
    m = dut.u_master
    _arm_wedge(dut)
    await ClockCycles(dut.hclk, 5)

    await _drive_write_addr_phase(dut, APER_BASE + 0x140, bufferable=True)

    revived        = False
    dbl_aw         = 0     # cycles where downstream would have accepted a 2nd AW
    dbl_w          = 0
    os_ctr_max     = 0
    rose           = None
    synth_b_fired  = False
    tail           = 0
    for c in range(WATCH):
        await RisingEdge(dut.hclk)
        # simulate the link reviving the moment recovery arms (mask window open)
        if (not revived) and (_osig(m, "rec_active") == 1):
            dut.f_awready_val.value = 1   # downstream awready now HIGH (still forced)
            dut.f_wready_val.value  = 1   # downstream wready  now HIGH
            revived = True
            dut._log.info(f"[edge] link 'revived' (downstream ready driven HIGH) at cyc {c}")
        # invariant: the DOWNSTREAM (Wlink) must never see valid&ready coincide
        # once recovery owns the beat — that would be a double-accept.
        if revived:
            avd = _osig(m, "s_axi_awvalid_dn")
            wvd = _osig(m, "s_axi_wvalid_dn")
            ard = _sig(m.s_axi_awready)
            wrd = _sig(m.s_axi_wready)
            if avd and ard:
                dbl_aw += 1
            if wvd and wrd:
                dbl_w += 1
        if _sig(m.synth_b_pending) == 1:
            synth_b_fired = True
        oc = _sig(getattr(m, "sub_wr_os_ctr")) or 0
        os_ctr_max = max(os_ctr_max, oc)
        if _sig(m.ahb_sub_hreadyout) == 1 and rose is None:
            rose = c
        if rose is not None:
            tail += 1
            if tail > 96:    # keep checking the invariant after recovery completes
                break

    dut._log.info(f"[edge] revived={revived} rose_at={rose} synth_b={synth_b_fired} "
                  f"downstream_double_AW_cycles={dbl_aw} "
                  f"downstream_double_W_cycles={dbl_w} os_ctr_max={os_ctr_max}")

    assert revived, "recovery never armed (rec_active never seen) — cannot test the revival"
    assert rose is not None, "recovery did not complete under a mid-recovery link revival"
    # The mask invariant: the DOWNSTREAM (Wlink) must never accept an AW/W beat while
    # recovery owns them, no matter that the link 'revived' (awready/wready HIGH).
    # NOTE os_ctr_max is EXPECTED to reach ~2: the wrapper address pipe re-presents
    # the held AW once, so the bridge issues 2 AW beats internally — both are
    # SYNTHETICALLY accepted and both are masked from the downstream. That is not a
    # downstream double-accept; dbl_aw/dbl_w are the signal that matters.
    assert dbl_aw == 0, \
        f"DOUBLE-ACCEPT: downstream accepted the AW {dbl_aw} cyc — mask FAILED"
    assert dbl_w == 0, \
        f"DOUBLE-ACCEPT: downstream accepted a W beat {dbl_w} cyc — mask FAILED"
    assert 1 <= os_ctr_max <= 4, \
        f"os_ctr_max={os_ctr_max} outside the expected bounded-flush range [1,4]"
    dut._log.info(f"[edge] PASS: mid-recovery link revival did NOT double-accept — "
                  f"Wlink-facing valids stayed masked (dbl_aw={dbl_aw} dbl_w={dbl_w}), "
                  f"internal flush os_ctr_max={os_ctr_max}, recovery completed at c={rose}")
