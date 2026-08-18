"""TL-043 -- the synth-B drain-guard LEVEL defeats Rank-1's wr_hold_r for ANY
concurrent write, not just the one the drain exists to rescue.

THE BUG (src/rtl/tidelink_top.sv, wr_hold_clr, found reviewing the guard added
alongside Rank-1's peer-write data-phase hold, commit e28c898):

    wire wr_hold_set = ext_is_nonseq & ahb_sub_hwrite & ~pipe_valid_r;
    wire wr_hold_clr = (s_axi_wvalid & s_axi_wready & s_axi_wlast)  // W beat landed
                      | synth_b_pending;                            // backstop drain (guard)

`synth_b_pending` is a REGISTER that stays asserted for the WHOLE multi-cycle
synth-B drain (one synthetic OKAY-B per outstanding write until
sub_wr_os_ctr hits 0) -- a LEVEL, not a pulse. Because wr_hold_clr ORs it in
directly, ANY peer write whose address latches (wr_hold_set pulses) at ANY
point while synth_b_pending==1 has its wr_hold_r driven straight back to 0
the SAME cycle it would be set -- defeating the whole Rank-1 TL-002 data-phase
hold for that write, for the entire drain window, not just the specific stuck
write the drain exists to rescue. Reachable from ORDINARY bufferable/EWR
traffic (a stuck write plus any second write) -- no error injection or link
wedge required, just a ~2^16-cycle backstop timeout coinciding with fresh
traffic, which nothing prevents.

THE FIX (this branch, tidelink_top.sv wr_hold_clr): replace the LEVEL term
with an edge-qualified release,

    wire wr_hold_drain_release = synth_b_pending & s_axi_bready & (sub_wr_os_ctr <= 3'd1);
    wire wr_hold_clr = (s_axi_wvalid & s_axi_wready & s_axi_wlast)
                      | wr_hold_drain_release;

the SAME "last synthetic B" predicate the RTL already uses to clear
synth_b_pending itself, re-derived locally (default_nettype none forbids a
forward reference to it). The original deadlock guard (AW/W feed separate FC
nodes, so a write whose W never lands must still be released when the drain
force-completes it inside XHB500) is preserved -- the drain's LAST synthetic B
still releases a genuinely stuck write -- but the release no longer blinds
every OTHER write in flight for the whole drain duration.

DISCLOSED RESIDUAL (not chased): a peer write whose address phase latches on
the SAME cycle as the drain's LAST synthetic B, before its own AW has reached
s_axi, can still see its hold released one cycle early -- a single-cycle race
per drain episode, versus the prior 100%-exposed-for-the-whole-drain-duration
bug. This suite's PRIMARY test deliberately lands on a MID-drain cycle
(ctr_at_inject > 1, i.e. NOT the drain's last beat) specifically so it proves
the general bug/fix and does not accidentally exercise (or get confused with)
this residual -- see _drive_second_write_into_drain()'s docstring.

CONSTRUCTION (mirrors test_n1_read_backstop_defeat.py's stuck-write vehicle):
stall the far AHB terminus (u_s_mng_bram.force_stall) so no B/R ever returns,
post N_POSTED>=2 bufferable (HPROT[2]=1, EWR) writes so XHB500's early-write-
response lets them all post while their B's sit outstanding
(sub_wr_os_ctr=N_POSTED), then let the SHORT I5 outstanding-response timeout
(TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2, built to 13 by the `wrhold_drain_guard`
make target -- see cocotb/tidelink_axi_datanode_recovery/Makefile) expire so
sub_wr_stuck_fire pulses and synth_b_pending asserts. The instant it does, a
SECOND, distinct-payload bufferable write's address phase is driven directly
on m_ahb_sub_* (bypassing AHBSubMaster.write_bufferable's own AW-accept wait,
which would not give the cycle-exact alignment this test needs).

TESTS (each needs its OWN sim -- a second run_bringup_full does not re-POR
cleanly, matching every other suite in this directory):

  test_second_write_survives_drain_guard   (PRIMARY, WHITE-BOX INVARIANT):
      Asserts, in order: (a) non-vacuity -- synth_b_pending was genuinely
      observed ==1, on a MID-drain cycle (ctr_at_inject > 1), at the cycle the
      second write's wr_hold_set pulsed; (b) wr_hold_r LATCHES to 1 following
      that wr_hold_set pulse (pre-fix: it never latches, because wr_hold_clr
      is already 1 that same cycle via the raw synth_b_pending LEVEL -- THE
      FAILURE SIGNATURE); (c) wr_hold_r then stays 1 until a legitimate
      release (the real W handshake, or the now-edge-qualified drain release
      if this write's own AW got folded into the same batch).

  test_second_write_data_landing             (SECONDARY, DATA-LANDING):
      A first attempt at this expected to hit the same documented difficulty
      as test_axi_datanode_writehold.py's own skip=True test #2 (that tb
      cannot isolate land-vs-drop for a write whose own W channel is not
      under real credit backpressure). MEASURED instead: this construction
      (a faithful-master HWDATA release racing a CONCURRENT drain, not a
      fresh write under a real far-terminus stall) is a clean, deterministic,
      non-vacuous discriminator -- pre-fix (or the LEVEL mutant) the payload
      lands 0x00000000 (dropped) at the far terminus; post-fix it lands
      byte-exact. Kept as a real (non-skipped) assertion, corroborating the
      primary white-box test at the data-content level.

BUILD: short I5 outstanding-response timeout so the drain is sim-reachable --
  make -C cocotb/tidelink_axi_datanode_recovery SIM_BUILD=sim_build_wrhold_drain_guard \
       EXTRA_DEFINES=+define+TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2=13 \
       MODULE=test_tl002_wrhold_drain_guard TESTCASE=<name>
or simply `make -C cocotb/tidelink_axi_datanode_recovery wrhold_drain_guard`.

MUTATION BUILDS (both must make the PRIMARY test FAIL with the same
whr_latched==0 signature):
  +define+TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT   -- recreates the pre-fix LEVEL
      guard verbatim (src/rtl/tidelink_top.sv wr_hold_clr, mutant arm).
  imp/hw_gate/tl042_rejected_fix/tl042_fix_REJECTED.patch -- the already-HW-
      rejected TL-042 v1 candidate. It widens synth_b_pending's ARM condition
      (sub_wr_stuck_fire) and adds a companion B-presentation suppression, but
      per its own diff does NOT touch wr_hold_clr's LEVEL term at all -- so it
      carries this exact bug forward unmodified.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

from pair_v2_common import PairV2TB, run_bringup_full          # noqa: F401 (re-export parity)
# Reuse the validated gaps-suite helpers (same directory / PYTHONPATH) -- the
# same import N1 uses for its own stuck-write vehicle.
from test_axi_datanode_gaps import (
    AHBSubMaster, _bringup, _release_all, _slave_bram_peek, APER_BASE,
)
# _set_far_stall only (no @cocotb.test names imported, so nothing leaks into
# this module's regression set).
from test_n1_read_backstop_defeat import _set_far_stall

APER = APER_BASE
WR1_PAGE = 0x0000          # stuck-write page
WR2_PAGE = 0x1000          # second-write page (different 4KB page; no need to
                           # share XHB500's hazard-list address match here --
                           # wr_hold_set/clr are upstream of XHB500 entirely --
                           # kept distinct anyway for cleanliness).
OFF_WR1   = 0x400
# Deliberately DIFFERENT low-order offset from OFF_WR1: the far terminus
# (tb_ahb_bram_slave #(.AW(12)), tb_top.sv:870) is only 4KB, so page bits
# alias away there (N1's own docstring notes this) -- WR1_PAGE and WR2_PAGE
# collapse to the SAME terminus memory. Using the same low-order offset for
# both would let the second write's landed value be indistinguishable from
# one of the (eventually real-completing) stuck writes' own payload landing
# at that same terminus address.
OFF_WR2   = 0x800
ADDR_WR1  = APER + WR1_PAGE + OFF_WR1
ADDR_WR2  = APER + WR2_PAGE + OFF_WR2
D_WR1_BASE = 0xC0DE0000
D_WR2      = 0xBEEF2222

# >=2 so the drain spans more than one synthetic-B cycle: the FIRST cycle
# synth_b_pending reads 1, sub_wr_os_ctr still reads N_POSTED (unchanged --
# both the ctr decrement and the drain's own ctr<=1 clear-check use ctr's
# value from BEFORE that same edge), so injecting on that first sb=1 cycle
# deterministically lands mid-drain (ctr_at_inject == N_POSTED > 1), not on
# the drain's last beat. 3 matches test_n1_read_backstop_defeat.py's margin
# (XHB500's EWR hazard list is depth 4).
N_POSTED = 3

POLL_CYCLES = 20_000    # >> the 2^13 (8192) short I5 timeout used by the
                        # `wrhold_drain_guard` make target, with margin.
RELEASE_WATCH_CYCLES = 4_000


def _g(obj, name, default=None):
    """Read a possibly-absent child signal (a mutant/rejected-patch build may
    not have every net this suite's fixed RTL declares)."""
    try:    return int(getattr(obj, name).value)
    except Exception: return default


async def _drive_second_write_into_drain(dut, m, addr2, data2,
                                          max_wait=POLL_CYCLES,
                                          faithful_release=False, poison=0):
    """Poll synth_b_pending every cycle (tidelink_top.sv :1928 / :1874's own
    predicate). The INSTANT it is first observed high, assert the SECOND
    write's AHB address phase directly on m_ahb_sub_* for exactly one cycle
    (same two-edge protocol as AHBSubMaster.write_bufferable / the sibling
    _drive_bufferable_write_watch helper in test_axi_datanode_writehold.py),
    so its wr_hold_set pulse samples on the immediately-following edge --
    squarely inside the drain LEVEL window.

    With N_POSTED>=2 stuck writes the FIRST cycle synth_b_pending reads 1 is
    guaranteed to be a MID-drain cycle (ctr_at_inject == N_POSTED > 1, see the
    module docstring's derivation) -- deliberately NOT the drain's LAST
    synthetic B, so this exercises the general whole-window bug/fix rather
    than the disclosed one-cycle residual. ctr_at_inject is returned so the
    caller asserts that distinction explicitly instead of trusting it.

    faithful_release: if True, models a REAL AHB master -- one cycle after the
    master-facing hreadyout (dut.m_ahb_sub_hreadyout) is observed high, HWDATA
    is dropped to `poison`. Off by default (the primary test only needs the
    wr_hold_r/set/clr ORDERING, not data content); used by the data-landing
    attempt."""
    clk = dut.hclk
    hsel = dut.m_ahb_sub_hsel; haddr = dut.m_ahb_sub_haddr
    htrans = dut.m_ahb_sub_htrans; hsize = dut.m_ahb_sub_hsize
    hburst = dut.m_ahb_sub_hburst; hprot = dut.m_ahb_sub_hprot
    hwrite = dut.m_ahb_sub_hwrite; hwdata = dut.m_ahb_sub_hwdata
    hready = dut.m_ahb_sub_hready; hreadyout = dut.m_ahb_sub_hreadyout

    o = {"sb_seen_before_inject": False, "injected": False, "inject_cyc": None,
         "ctr_at_inject": None, "whs_pulse": None, "whc_pulse": None,
         "sb_pulse": None, "ctr_pulse": None, "whr_latched": None,
         "trace": [], "released_hwdata": False}

    # Phase-correctness note (measured 2026-08-18, see git history of this
    # file for the mistaken first attempt): a plain register/wire read
    # immediately after `await RisingEdge(clk)` runs in cocotb's Normal phase,
    # which can race the SAME edge's always_ff NBA updates and observe a
    # PRE-update value -- exactly the hazard documented in
    # cocotb/tidelink_fc_adapter/test_pipelining.py's A2LFifoModel.start().
    # Every read below that must reflect a settled post-edge value
    # (wr_hold_set/wr_hold_clr in the (E1,E2) window right after asserting the
    # address phase, and wr_hold_r right after the edge whose always_ff it
    # feeds) goes through `await ReadOnly()` first. Any WRITE for a given
    # edge is issued in that edge's Normal phase, strictly BEFORE that edge's
    # ReadOnly() call, per cocotb 2.x's ReadOnly->ReadWrite transition ban.
    injected = False
    for c in range(max_wait):
        await RisingEdge(clk)
        sb = _g(m, "synth_b_pending"); ctr = _g(m, "sub_wr_os_ctr")
        if len(o["trace"]) < 40:
            o["trace"].append((c, sb, ctr))

        if not injected and sb:
            o["sb_seen_before_inject"] = True
            o["inject_cyc"] = c
            o["ctr_at_inject"] = ctr
            # Normal phase: assert the second write's address phase now, so
            # it is stable throughout the (E1,E2) window that will feed
            # wr_hold_r's flop at the NEXT edge.
            hsel.value = 1; haddr.value = addr2 & 0xFFFF_FFFF; htrans.value = 2
            hsize.value = 2; hburst.value = 0; hprot.value = 0x4
            hwrite.value = 1; hready.value = 1; hwdata.value = data2 & 0xFFFF_FFFF
            injected = True
            o["injected"] = True
            # ReadOnly: sample wr_hold_set/wr_hold_clr as settled in THIS
            # SAME (E1,E2) window (the window that feeds wr_hold_r's update
            # at the NEXT edge -- sampling only after that next edge instead
            # reads the FOLLOWING window, one cycle too late).
            await ReadOnly()
            o["whs_pulse"] = _g(m, "wr_hold_set")
            o["whc_pulse"] = _g(m, "wr_hold_clr")
            o["sb_pulse"] = sb            # == the trigger value, by construction
            o["ctr_pulse"] = ctr
            continue

        if injected and o["whr_latched"] is None:
            # Normal phase: end the one-cycle address phase (move to data
            # phase) BEFORE this edge's ReadOnly() call. This deassert cannot
            # affect wr_hold_r's update for THIS edge (already fixed by the
            # PRE-edge (E1,E2)-window values regardless of what is driven
            # afterward).
            hsel.value = 0; htrans.value = 0; hwrite.value = 0; hburst.value = 0
            # ReadOnly: this edge (E2) just fired wr_hold_r's always_ff using
            # the (E1,E2)-window whs/whc sampled above, so wr_hold_r sampled
            # here (settled) is exactly the answer: did it latch or clear?
            await ReadOnly()
            o["whr_latched"] = _g(m, "wr_hold_r")
            if not faithful_release:
                break
            continue

        if faithful_release and o["whr_latched"] is not None and not o["released_hwdata"]:
            # Normal phase: read-then-maybe-write is safe here (no preceding
            # ReadOnly() this iteration).
            if int(hreadyout.value):
                hwdata.value = poison & 0xFFFF_FFFF
                o["released_hwdata"] = True
                break
    return o


async def _watch_wr_hold_release(dut, m, cycles=RELEASE_WATCH_CYCLES):
    """Track wr_hold_r after it has latched until it clears, and classify WHY:
    the real W handshake (s_axi_wvalid & s_axi_wready & s_axi_wlast) or a
    legitimate (now edge-qualified) drain release (wr_hold_drain_release,
    present under BOTH build arms -- see tidelink_top.sv, declared outside the
    TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT ifdef).

    Callers only ever invoke this right after confirming wr_hold_r just
    latched to 1 (whr_latched==1), so prev_whr is seeded at 1 rather than
    None -- otherwise a release on the very FIRST sampled cycle here (the
    real W beat landing immediately, measured 2026-08-18: it can land the
    edge right after latching when nothing else backpressures this write's
    own W channel) is invisible to a 1-sample-late transition detector and
    reads as 'never released' instead of an instant, legitimate release."""
    clk = dut.hclk
    prev_whr = 1
    release_cyc = None; release_reason = None
    trace = []
    for c in range(cycles):
        await RisingEdge(clk)
        await ReadOnly()   # settled post-edge values; see _drive_second_write_into_drain
        whr = _g(m, "wr_hold_r")
        wv = _g(m, "s_axi_wvalid"); wrd = _g(m, "s_axi_wready"); wl = _g(m, "s_axi_wlast")
        dr = _g(m, "wr_hold_drain_release")
        if len(trace) < 60:
            trace.append((c, whr, wv, wrd, wl, dr))
        if prev_whr == 1 and whr == 0 and release_cyc is None:
            release_cyc = c
            w_hs = bool(wv and wrd and wl)
            release_reason = "W_HANDSHAKE" if w_hs else ("DRAIN_RELEASE" if dr else "UNKNOWN")
            break
        prev_whr = whr
    return {"release_cyc": release_cyc, "release_reason": release_reason, "trace": trace}


async def _construct_stuck_writes(dut, m, n=N_POSTED):
    """Stall the far terminus and post N bufferable (EWR) writes so they all
    post (early-write-response) with their B's outstanding. Mirrors
    test_n1_read_backstop_defeat.py step 2 exactly."""
    master = AHBSubMaster(dut)
    _set_far_stall(dut, True)
    await ClockCycles(dut.hclk, 20)
    posted = 0
    for i in range(n):
        try:
            await master.write_bufferable(ADDR_WR1 + i * 4, D_WR1_BASE + i, m,
                                          timeout=3000)
            posted += 1
        except (TimeoutError, RuntimeError) as e:
            dut._log.info(f"[tl043] stuck write {i}: {e}")
    ctr0 = _g(m, "sub_wr_os_ctr")
    dut._log.info(f"[tl043] posted={posted}/{n} sub_wr_os_ctr={ctr0}")
    return posted


# =============================================================================
# PRIMARY -- white-box invariant.
# =============================================================================
@cocotb.test()
async def test_second_write_survives_drain_guard(dut):
    """TL-043 PRIMARY (white-box invariant, deterministic construction).

    Pre-fix (or either mutant build): FAILS at assertion (b) -- wr_hold_r
    never latches for the second write, because wr_hold_clr is already 1 that
    same cycle via the raw synth_b_pending LEVEL (the drain guard, meant to
    rescue ONE stuck write, blinds every OTHER write in flight for the whole
    drain window).

    Post-fix: PASSES -- wr_hold_r latches and holds through the concurrent
    drain, releasing only on the real W handshake or a legitimately
    edge-qualified drain release."""
    tb, master0 = await _bringup(dut)
    m = dut.u_master

    posted = await _construct_stuck_writes(dut, m, N_POSTED)
    assert posted >= 2, (
        f"CANNOT CONSTRUCT: only {posted} bufferable write(s) posted -- need "
        f">=2 outstanding so the drain spans more than one synthetic-B beat "
        f"(with only 1 outstanding, synth_b_pending's ENTIRE window IS the "
        f"drain's last beat, and this test would only ever be able to "
        f"exercise the disclosed one-cycle residual, not the general "
        f"whole-window bug it targets). Undecided, not a pass.")

    o = await _drive_second_write_into_drain(dut, m, ADDR_WR2, D_WR2)
    dut._log.info(f"[tl043] INJECT: {o}")

    # ── (a) NON-VACUITY ──────────────────────────────────────────────────
    assert o["sb_seen_before_inject"], (
        f"CANNOT CONSTRUCT: synth_b_pending never asserted within "
        f"{POLL_CYCLES} cycles -- the I5 backstop never armed (check the "
        f"build's TIDELINK_SUB_OUTSTANDING_TIMEOUT_LOG2 define), so the "
        f"drain-guard window under test was never entered. trace(first 40)="
        f"{o['trace']}")
    assert o["ctr_at_inject"] is not None and o["ctr_at_inject"] > 1, (
        f"landed on the drain's LAST synthetic B (ctr_at_inject="
        f"{o['ctr_at_inject']}) instead of a mid-drain cycle -- that only "
        f"exercises the disclosed one-cycle residual, not the general "
        f"whole-window bug this test targets. posted={posted}, trace(first "
        f"40)={o['trace']}")
    assert o["whs_pulse"] == 1, (
        f"wr_hold_set never pulsed for the injected second write "
        f"(whs_pulse={o['whs_pulse']}) -- the address phase did not "
        f"latch as expected (pipe_valid_r busy, or ext_is_nonseq/hwrite not "
        f"as driven). Construction failure, not a verdict on the fix. {o}")
    assert o["sb_pulse"] == 1, (
        f"synth_b_pending was NOT 1 at the cycle wr_hold_set pulsed "
        f"(sb_pulse={o['sb_pulse']}) -- the injection missed the drain "
        f"window entirely; the guard under test was never exercised. {o}")
    dut._log.info(
        f"[tl043] (a) NON-VACUITY PASS: synth_b_pending was observed ==1 "
        f"(ctr={o['ctr_at_inject']}, mid-drain) at the exact cycle the "
        f"second write's wr_hold_set pulsed.")

    # ── (b) THE INVARIANT ───────────────────────────────────────────────
    assert o["whr_latched"] == 1, (
        f"TL-043 REPRODUCED: wr_hold_r did NOT latch to 1 following "
        f"wr_hold_set even though it pulsed, because wr_hold_clr was ALSO 1 "
        f"that same cycle (whc_pulse={o['whc_pulse']}) -- "
        f"synth_b_pending (a LEVEL; ctr_at_inject={o['ctr_at_inject']} > 1, "
        f"i.e. explicitly NOT the drain's last beat) cleared the hold the "
        f"instant it was set, defeating the Rank-1 TL-002 data-phase hold "
        f"(e28c898) for this second, unrelated write, for the whole drain "
        f"window. {o}")
    dut._log.info(
        f"[tl043] (b) PASS: wr_hold_r latched (whr_latched=1) with "
        f"synth_b_pending=1 and sub_wr_os_ctr={o['ctr_at_inject']} "
        f"concurrently asserted -- the drain guard no longer blinds this "
        f"write.")

    # ── (c) held until a legitimate release ────────────────────────────
    rel = await _watch_wr_hold_release(dut, m, RELEASE_WATCH_CYCLES)
    dut._log.info(f"[tl043] RELEASE: {rel}")
    assert rel["release_cyc"] is not None, (
        f"wr_hold_r never released within {RELEASE_WATCH_CYCLES} cycles of "
        f"latching -- this looks like a NEW hang introduced by the fix, not "
        f"the TL-043 defeat under test. trace(first 60)={rel['trace']}")
    assert rel["release_reason"] in ("W_HANDSHAKE", "DRAIN_RELEASE"), (
        f"wr_hold_r released for neither the real W handshake nor a "
        f"legitimately edge-qualified drain release (release_reason="
        f"{rel['release_reason']}) -- some OTHER term cleared it. "
        f"trace(first 60)={rel['trace']}")
    dut._log.info(
        f"[tl043] (c) PASS: wr_hold_r released via {rel['release_reason']} "
        f"at +{rel['release_cyc']} cycles after latching (not clobbered "
        f"early by the drain LEVEL).")

    _set_far_stall(dut, False)
    _release_all(tb)
    await ClockCycles(dut.hclk, 50)


# =============================================================================
# SECONDARY -- data-landing (measured non-vacuous; NOT skipped).
# =============================================================================
@cocotb.test()
async def test_second_write_data_landing(dut):
    """TL-043 SECONDARY (DATA-LANDING). An initial attempt (2026-08-18) at
    this test expected to hit the same documented difficulty as
    test_axi_datanode_writehold.py's own test #2 (skip=True there: that tb
    cannot isolate land-vs-drop on the hreadyout axis for a write whose own W
    channel is not under real credit backpressure). MEASURED HERE, this
    construction turns out to be a CLEAN, non-vacuous discriminator instead --
    kept as a real (non-skipped) assertion rather than force-fitting the
    sibling test's skip=True precedent.

    CONSTRUCTION: same stuck-write vehicle as the primary test above (stall
    the far terminus, post N_POSTED bufferable writes, wait for the drain),
    but the second write is driven with `faithful_release=True` -- a REAL AHB
    master model that drops HWDATA to a poison value the cycle AFTER it
    samples the master-facing hreadyout (dut.m_ahb_sub_hreadyout) high --
    i.e. the actual silicon data-drop mechanism Rank-1's hold (e28c898)
    exists to prevent. The far terminus is then unstalled, the link is given
    a long drain window, and the second write's target BRAM offset (aliased
    at the far terminus -- see the OFF_WR2 peek note below) is compared to
    the expected payload.

    WHY IT WORKS HERE (unlike the sibling's #2): that test tried to build
    backpressure via a real far-terminus stall filling XHB500's wdata
    regslice for a FRESH write with nothing else going on -- and measured
    that the wdata sample was captured before release in BOTH builds (no
    drop to fix). This construction instead lands the second write's address
    phase on a cycle where a CONCURRENT, unrelated drain is already in
    flight: pre-fix (or the LEVEL mutant), wr_hold_r never latches at all
    (see the primary test), so the master-facing hreadyout follows XHB500's
    raw early-write-response hreadyout immediately, the faithful-master model
    releases HWDATA right away, and the deferred wdata sample (still pending
    behind the OTHER outstanding writes' own traffic) captures the released
    poison value -- MEASURED: target lands 0x00000000 (dropped) on both the
    pre-fix RTL and the +define+TIDELINK_WR_HOLD_CLR_LEVEL_MUTANT build.
    Post-fix, wr_hold_r correctly latches and holds hreadyout low until the
    real W handshake, so the faithful master never releases HWDATA before the
    live payload is sampled -- MEASURED: target lands byte-exact
    (0xBEEF2222).

    The white-box invariant (test_second_write_survives_drain_guard, above)
    remains the PRIMARY, most direct evidence for this fix (it proves the
    exact RTL predicate, wr_hold_clr, on both sides of the fix without
    depending on a data race at all); this test corroborates it end-to-end at
    the data-content level."""
    tb, master0 = await _bringup(dut)
    m = dut.u_master

    posted = await _construct_stuck_writes(dut, m, N_POSTED)
    assert posted >= 2, (
        f"CANNOT CONSTRUCT: only {posted} bufferable write(s) posted -- need "
        f">=2 outstanding (same rationale as the primary test above).")

    o = await _drive_second_write_into_drain(dut, m, ADDR_WR2, D_WR2,
                                             faithful_release=True, poison=0)
    dut._log.info(f"[tl043-landing] INJECT: {o}")

    # ── NON-VACUITY (same discipline as the primary test) ─────────────────
    assert o["sb_seen_before_inject"], (
        f"CANNOT CONSTRUCT: synth_b_pending never asserted within "
        f"{POLL_CYCLES} cycles -- the drain-guard window was never entered.")
    assert o["ctr_at_inject"] is not None and o["ctr_at_inject"] > 1, (
        f"landed on the drain's LAST synthetic B (ctr_at_inject="
        f"{o['ctr_at_inject']}) instead of a mid-drain cycle -- only the "
        f"disclosed one-cycle residual would be exercised here, not the "
        f"general bug/fix.")
    assert o["whs_pulse"] == 1, (
        f"wr_hold_set never pulsed for the injected second write "
        f"(whs_pulse={o['whs_pulse']}) -- construction failure.")
    assert o["released_hwdata"], (
        "the faithful-master model never observed the master-facing "
        "hreadyout go high, so HWDATA was never released -- the data-drop "
        "mechanism under test was never exercised. o=" + repr(o))

    _set_far_stall(dut, False)
    await ClockCycles(dut.hclk, 20000)   # drain everything

    # NOT WR2_PAGE + OFF_WR2: the far terminus is only 4KB (AW=12), so page
    # bits alias away there -- peek the aliased (page-relative) offset, same
    # as every sibling test in this directory (OFF_POST, OFF_INJECT, etc, all
    # < 4KB with no page component passed to _slave_bram_peek). A first
    # version of this test peeked the un-aliased address and got a GPI
    # "Invalid Index" out-of-range error (mem[] is [0:1023]), silently
    # reading back None/0 -- a construction bug, not a measurement.
    got = _slave_bram_peek(dut, OFF_WR2)
    dut._log.info(
        f"[tl043-landing] target=0x{(got if got is not None else 0):08x} "
        f"expect=0x{D_WR2:08x} sb_seen={o['sb_seen_before_inject']} "
        f"ctr_at_inject={o['ctr_at_inject']} whr_latched={o['whr_latched']} "
        f"released_hwdata={o['released_hwdata']}")

    # ── THE VERDICT ─────────────────────────────────────────────────────
    assert got == D_WR2, (
        f"TL-043 data-drop REPRODUCED: the second write's payload did NOT "
        f"land byte-exact at the far terminus (got=0x"
        f"{(got if got is not None else 0):08x}, expect=0x{D_WR2:08x}). "
        f"wr_hold_r was defeated (whr_latched={o['whr_latched']}) by the "
        f"concurrent drain, the faithful master released HWDATA before the "
        f"deferred W sample, and the released (poison) value was captured "
        f"instead of the live payload -- the silicon data-drop mechanism "
        f"Rank-1's hold (e28c898) exists to prevent, reopened by the "
        f"drain-guard LEVEL bug (TL-043). o={o}")
    dut._log.info(
        f"[tl043-landing] PASS: second write's payload landed byte-exact "
        f"(0x{got:08x}) at the far terminus despite the concurrent drain.")

    _release_all(tb)
    await ClockCycles(dut.hclk, 50)
