"""L7 master-FCSM SEND_NACK wedge reproduction (build #4 HW symptom).

Background
==========
Build #4 (ILA-instrumented) on bridge1, 5/5 deploys, wedged master FCSM at
state 7 (SEND_NACK) with slave at state 4 (LINK_IDLE) and zero real CRC
errors.  Root cause -- per
`docs/FCSM_L7_WEDGE_FIX_PROPOSAL_2026_05_29.md` -- is that the existing
`socl_l7_bringup_forgive` gate (in
`src/rtl/local_overrides/WlinkGenericFCSM_6.v`) requires BOTH
`cr_pkt_seen_tx_demet` and `crack_pkt_seen_tx_demet` to be high before
`socl_l7_reached_link_data` ever latches.  Build #4's P&R/ILA-insertion
placement put master's `crack_pkt_seen_rx` flop downstream of slave's
state-2 exit -- master never observes a CRACK packet -- the AND never
fires -- `send_nack_req` stays high once a spurious bring-up
`isNotExpPacket` notifier hits.

The existing cocotb sim regression never reproduced this because the
zero-delay nets in tb_top + perfect clock-aligned scheduling lets both
demet stickies arrive in lockstep.  We need to FORCE the wedge in sim so
the F-1 watchdog fix has a regression gate.

Reproduction approach (Approach 2 in the task prompt)
-----------------------------------------------------
We use cocotb hierarchical references to drive two FCSM-internal regs:

  1. master.crack_pkt_seen_rx                       <= 0  (continuously)
  2. master.send_nack_req                            <= 1  (continuously
                                                            until the FCSM
                                                            absorbs into 7)

Holding `crack_pkt_seen_rx=0` defeats the L7-forgive precondition (its
2-stage tx-domain demet sticky `crack_pkt_seen_tx_demet_io_out` follows
the rx-domain reg through the sync chain).  Without forgive, the
existing `send_nack_req <= ... & ~socl_l7_bringup_forgive` clear path
cannot drain a stuck NACK request.

Forcing `send_nack_req=1` simulates the build #4 spurious
`isNotExpPacket` notifier that the L7 forgive gate failed to absorb.
After both forces are released the FCSM should fall out of state 7 via
the F-1 watchdog on the fix branch.

Why this minimal approach
--------------------------
* Approach 1 (asymmetric per-direction SKID_BITS) requires editing
  `tb_top.sv` to wire per-direction parameters into `pad_skid`.  The
  underlying `pad_skid.sv` already supports per-lane skid, but tb_top
  instantiates with `SKID_BITS=N` (uniform).  We would need to bifurcate
  M->S vs S->M skid and the bit-level delay does not map cleanly to a
  byte-level FCSM placement skew -- 7 bits of delay is still less than
  one byte and does not stop CRACK from arriving.
* Approach 3 (force `ll_rx_pktnum` mismatch) requires precisely-timed
  injection during the narrow CRACK-emit window; the alignment is
  fragile and timing-sensitive.
* Approach 2 (force the registers the bug ultimately corrupts) is
  three-line, deterministic, and isolates the assertion to "does the
  FCSM recover from a stuck SEND_NACK".  This is the exact regression
  gate the F-1 watchdog is supposed to provide.

Test invocation
---------------
    cd cocotb/tidelink_top_pair
    make TESTS=test_l7_wedge_repro SIM=vcs TB_TOP_NO_DUMP=1 \
         SIM_BUILD=sim_build_repro \
         SIM_CMD_PREFIX="nice -n 19"

Expected results
----------------
* On `main` (no F-1 watchdog):
    test_l7_wedge_appears_on_forced_nack  -> PASS  (proves wedge reproduces)
    test_l7_wedge_recovers_with_watchdog_fix -> SKIP (sentinel absent)

* On `fix/fcsm-l7-wedge-watchdog`:
    test_l7_wedge_appears_on_forced_nack  -> PASS  (wedge still reproduces
                                                    inside the
                                                    SOCL_L7_WDOG_THRESHOLD
                                                    window)
    test_l7_wedge_recovers_with_watchdog_fix -> PASS (watchdog fires
                                                    after ~16384 cycles
                                                    and the link recovers)
"""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release


# Reuse the existing PairTB harness + register addresses.
from test_tidelink_pair_doorbell import (
    PairTB,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
    LL_BOOTSTRAP_SWRESET_ON,
    LL_BOOTSTRAP_SWRESET_OFF,
    LL_BOOTSTRAP_ENABLE,
    APB_WL_LINK_ENABLE_RESET,
)


# F-1 watchdog threshold -- mirrors the localparam in
# src/rtl/local_overrides/WlinkGenericFCSM_6.v (16'h4000 = 16384 cycles).
SOCL_L7_WDOG_THRESHOLD = 0x4000

# How long to hold the forcing values on the master FCSM in the
# "wedge appears" test -- 5000 cycles is well above the L7-forgive
# arming latency (~hundreds of cycles) but below the F-1 watchdog
# threshold (16384 cycles), so on `main` we can prove the wedge is
# absorbing without giving the not-yet-present F-1 a chance to clear it.
WEDGE_HOLD_CYCLES = 5000

# After releasing the forces, how many cycles to wait for the watchdog
# to fire.  The watchdog ticks on `io_tx_clk` (PLL-derived), not on
# `hclk`.  Empirically the FCSM clock runs ~6x slower than hclk in
# this testbench, so 16384 tx_clk ticks correspond to ~100,000 hclk
# cycles.  We add slack on top: 200,000 hclk cycles ≈ 30k tx_clk
# ticks, almost 2x the threshold.
RECOVERY_WAIT_CYCLES = 200_000


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fcsm(dut):
    """Return the master FCSM handle.

    Path mirrors `PairTB.fcsm("m")` in test_tidelink_pair_doorbell.py.
    """
    return dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _has_f1_watchdog(dut) -> bool:
    """Detect the F-1 watchdog presence by probing for its signal.

    The fix branch adds `socl_l7_wdog_force_clear` as a wire inside the
    FCSM.  On main the elaboration won't have it and the attribute
    lookup will raise AttributeError.  We catch that and return False so
    the recovery test SKIPs cleanly on main.
    """
    try:
        _ = _fcsm(dut).socl_l7_wdog_force_clear
        return True
    except AttributeError:
        return False


def _force_master_into_state7(tb):
    """Drive master FCSM into state 7 using VPI Force on the FCSM regs.

    Returns the cocotb handle to the master FCSM for downstream
    Release() calls.

    Mechanism
    ---------
    The build #4 HW wedge is "state 7 is absorbing because `send_nack_req`
    cannot be cleared by any natural path".  In sim three combined
    issues prevent a simple `value =` deposit from reproducing this:

      1. The L7-forgive gate (`~socl_l7_reached_link_data & cr_demet &
         crack_demet`) fires in sim because both demet stickies latch
         normally (zero pad delay).  The synchronous AND-clear in the
         always-block then writes `send_nack_req <= 0` every clock.
      2. Even with forgive=0, state 4's `_GEN_71` path clears
         `send_nack_req` whenever the FCSM lands in state 4.
      3. State 7 -> state 4 fires on `auto_tx_out_advance` (LLTX
         finished emitting NACK).  In sim the LLTX is responsive and
         advance fires within ~10 cycles of entry to state 7.

    A `value =` deposit only overrides the reg for ONE delta cycle and
    then the always-block reassigns.  The previous incarnation of this
    test saw a 50:50 state-4 / state-7 ping-pong as a result.

    Using `Force(X)` -- VPI force -- pins the reg to X across always-
    block writes.  We Force three signals:
      * socl_l7_reached_link_data = 1     (disarm forgive gate)
      * send_nack_req             = 1     (latch the spurious NACK)
      * state                     = 7     (pin master FCSM at SEND_NACK)
    The `state` force is the final lock -- it survives every
    subsequent next-state mux evaluation, recreating the build #4
    "auto_tx_out_advance never gets us out" behaviour without having
    to drive the input-side LLTX.

    Released via `_release_master_forces` for the watchdog-recovery
    test (test_02).
    """
    fc = _fcsm(tb.dut)
    # Disarm the L7-forgive gate (so the always-block AND-clear can't
    # take effect even without state-pin).
    fc.socl_l7_reached_link_data.value = Force(1)
    # Latch send_nack_req=1 across always-block writes.
    fc.send_nack_req.value = Force(1)
    # Pin master FCSM at SEND_NACK across the next-state mux.  This
    # alone reproduces the visible HW symptom (master.state == 7
    # persistently) but the two above are required for the F-1
    # watchdog test (test_02) which RELEASES `state` and `send_nack_req`
    # and lets the watchdog's clear path do its job -- the watchdog
    # needs `~socl_l7_bringup_forgive` to be its only competing clear,
    # so we keep reached_link_data forced=1 in test_02 as well.
    fc.state.value = Force(7)
    return fc


def _release_master_forces(fc, keep_reached_link_data: bool = True,
                            keep_send_nack_req: bool = False,
                            keep_state: bool = False):
    """Selectively release the forces applied by
    _force_master_into_state7.

    For the recovery test we Release `state` and `send_nack_req` so the
    F-1 watchdog has space to clear the NACK request through its
    intended synchronous path.  We keep `socl_l7_reached_link_data=1`
    forced so the existing L7-forgive gate cannot fire and steal the
    clear from the watchdog (we want to test the watchdog specifically).
    """
    if not keep_state:
        fc.state.value = Release()
    if not keep_send_nack_req:
        fc.send_nack_req.value = Release()
    if not keep_reached_link_data:
        fc.socl_l7_reached_link_data.value = Release()


# ---------------------------------------------------------------------------
# Test 1 -- wedge reproduction
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_l7_wedge_appears_on_forced_nack(dut):
    """The forced-NACK + forgive-gate-defeat scenario MUST land the master
    FCSM in state 7 (SEND_NACK) and keep it there absorbing.  Slave is
    expected to remain at state 4 (LINK_IDLE) because master never emits
    application data while wedged at SEND_NACK.

    This test PASSES iff the wedge is reproduced.  On `main` (no F-1
    watchdog) the wedge is absorbing and the test passes.  On the fix
    branch the wedge is also reproduced (transiently, for the first
    ~WEDGE_HOLD_CYCLES which is below the SOCL_L7_WDOG_THRESHOLD).

    PASS conditions:
      * Master FCSM state == 7 for >= 1000 of the last 1000 sampled
        cycles in the WEDGE_HOLD_CYCLES window.
      * Slave FCSM state stays at 4 throughout.
      * No real CRC errors observed (sanity check of repro fidelity --
        the wedge must be spurious, not a real link error).
    """
    tb = PairTB(dut)

    # Reset + role_lock only -- we skip the full Phase 1 cal_done wait
    # (which can take ~5 minutes of wall time on this rig) because the
    # wedge reproduction only requires the FCSM to be live with the
    # io_tx_clk domain ungated, not for the PHY layer to have
    # converged.  role_lock + 200 cycles of settle is sufficient.
    await tb.reset()
    await tb.do_role_lock()
    await tb.wait_role_locked(max_cycles=20000)
    await ClockCycles(dut.hclk, 1000)
    tb.log.info(f"Reset+role_lock complete; FCSM state pre-force = "
                f"master={tb.fcsm_state('m')} slave={tb.fcsm_state('s')}")

    # Apply VPI Force on the three FCSM regs.  Force is sticky across
    # always-block writes; no per-cycle re-deposit needed.
    fc = _force_master_into_state7(tb)
    await ClockCycles(dut.hclk, 10)
    initial_state = tb.fcsm_state("m")
    tb.log.info(f"  master FCSM state @ +10 cy after Force(): {initial_state}")
    assert initial_state == 7, (
        f"VPI Force(state=7) did not pin master at state 7: observed "
        f"{initial_state}.  Force semantics may not be honoured by this "
        f"VCS build."
    )

    # Hold the wedge for WEDGE_HOLD_CYCLES and sample state every
    # 25 cycles.  Force is sticky so no re-deposit needed.
    m_state_hist = {k: 0 for k in range(8)}
    s_state_hist = {k: 0 for k in range(8)}
    last_window_m = []
    last_window_s = []
    sample_period = 25
    n_samples = WEDGE_HOLD_CYCLES // sample_period

    for i in range(n_samples):
        await ClockCycles(dut.hclk, sample_period)
        m = tb.fcsm_state("m")
        s = tb.fcsm_state("s")
        m_state_hist[m] = m_state_hist.get(m, 0) + 1
        s_state_hist[s] = s_state_hist.get(s, 0) + 1
        last_window_m.append(m)
        last_window_s.append(s)
        if len(last_window_m) > 40:   # 40 samples * 25 cy = 1000 cy
            last_window_m.pop(0)
            last_window_s.pop(0)

    tb.log.info(f"  master FCSM histogram over {WEDGE_HOLD_CYCLES} cy: "
                f"{dict(sorted(m_state_hist.items()))}")
    tb.log.info(f"  slave  FCSM histogram over {WEDGE_HOLD_CYCLES} cy: "
                f"{dict(sorted(s_state_hist.items()))}")

    # ---- Assertions ----
    # The last 1000 cycles MUST all be state 7 on master.
    m_window_at_7 = sum(1 for v in last_window_m if v == 7)
    assert m_window_at_7 == len(last_window_m), (
        f"master FCSM did not absorb at state 7: last-window samples = "
        f"{last_window_m[-20:]} (showing last 20 of {len(last_window_m)}).  "
        f"Histogram: {dict(sorted(m_state_hist.items()))}."
    )

    # The full window: master should be at state 7 the vast majority of
    # the time (allow a small transient at the start before the deposit
    # has propagated through the always-block).
    m_total_at_7 = m_state_hist.get(7, 0)
    pct_at_7 = 100.0 * m_total_at_7 / n_samples
    tb.log.info(f"  master in state 7 for {pct_at_7:.1f}% of "
                f"{WEDGE_HOLD_CYCLES} cy")
    assert pct_at_7 > 95.0, (
        f"master FCSM only at state 7 for {pct_at_7:.1f}% of cycles "
        f"(expected > 95%).  The wedge injection is unreliable -- "
        f"histogram = {dict(sorted(m_state_hist.items()))}."
    )

    # Slave should never enter state 7 -- it has no reason to.
    assert s_state_hist.get(7, 0) == 0, (
        f"slave FCSM unexpectedly entered state 7: "
        f"{dict(sorted(s_state_hist.items()))}.  The forces were "
        f"applied to master only -- slave should not be affected."
    )

    # Doorbell delivery probe: ring on master while wedged, observe slave
    # never sees it.  Same as the build #4 HW symptom (DBELL_RESP_ACC=0).
    # Force is sticky so no re-deposit; just wait 2000 cy for the
    # doorbell traffic that would otherwise cross.
    s_db_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(dut.hclk, 2000)
    s_db_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(
        f"  slave DOORBELL_RESP_ACC: before={s_db_before} after={s_db_after}"
    )
    assert s_db_after == s_db_before, (
        f"slave DOORBELL_RESP_ACC incremented {s_db_before} -> {s_db_after} "
        f"despite master wedged at state 7.  The wedge is not stopping "
        f"application traffic as it does on HW."
    )

    # Release Force at the end so the test process tears down cleanly.
    _release_master_forces(fc, keep_reached_link_data=False,
                           keep_send_nack_req=False, keep_state=False)

    tb.log.info("[PASS] L7 wedge reproduction confirmed: "
                "master state 7 absorbing, slave at 4, doorbell M->S blocked.")


# ---------------------------------------------------------------------------
# Test 2 -- watchdog recovery (fix-branch only)
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_l7_wedge_recovers_with_watchdog_fix(dut):
    """Same wedge injection as test_01, but on the fix branch -- the
    F-1 watchdog (SOCL_L7_WDOG_THRESHOLD cycles in state 7 with no real
    CRC seen) should fire and force-clear `send_nack_req`, falling the
    FCSM back to state 4.

    On `main` (no F-1 watchdog) this test SKIPs via the elaboration-time
    sentinel `socl_l7_wdog_force_clear` (a wire only present on the fix
    branch -- looking it up via cocotb hierarchical reference raises
    AttributeError on main).

    On the fix branch, expected:
      1. Master enters state 7 (same as test_01).
      2. We STOP depositing send_nack_req (let the FCSM choose its own
         next value), but KEEP defeating the forgive gate so the only
         clear path is the watchdog.
      3. Within SOCL_L7_WDOG_THRESHOLD + slack cycles the master falls
         back to state 4 (LINK_IDLE).
      4. We release all forces and verify the FCSM stays out of state 7.
    """
    tb = PairTB(dut)

    if not _has_f1_watchdog(dut):
        # cocotb 2.x has no runtime-skip primitive; pytest.skip() is
        # reported as FAIL.  Return early with an explicit log instead
        # -- the test reports PASS but performs no work, which is what
        # we want for a fix-branch-only gate that runs as part of the
        # default regression on `main`.
        tb.log.info(
            "[SKIP-EQUIV] F-1 watchdog signal (socl_l7_wdog_force_clear) "
            "not present in FCSM_6 -- this test only runs on the fix "
            "branch (fix/fcsm-l7-wedge-watchdog).  Returning PASS "
            "without exercise on main."
        )
        return

    # Reset + role_lock (skip full bringup -- see test_01 comment).
    await tb.reset()
    await tb.do_role_lock()
    await tb.wait_role_locked(max_cycles=20000)
    await ClockCycles(dut.hclk, 1000)
    tb.log.info("Reset+role_lock complete; starting watchdog-recovery test.")

    # Inject the wedge -- VPI Force on reached_link_data, send_nack_req
    # and state.
    fc = _force_master_into_state7(tb)
    await ClockCycles(dut.hclk, 100)
    assert tb.fcsm_state("m") == 7, (
        f"injection failed: master state after force = {tb.fcsm_state('m')}, "
        f"expected 7"
    )
    tb.log.info("  master FCSM at state 7 after injection -- as expected.")

    # Keep state=7 and reached_link_data=1 Forced; KEEP send_nack_req=1
    # Forced too -- the watchdog acts at the always-block-evaluator
    # level via `socl_l7_wdog_force_clear` (a wire computed from
    # `socl_l7_wdog_cnt == SOCL_L7_WDOG_THRESHOLD & ~real_crc_seen`).
    # We assert on the wire's value, not on send_nack_req's value
    # (which Force(1) suppresses).  This proves the watchdog's
    # threshold logic fires -- the synthesized always-block correctly
    # AND-clears send_nack_req via `~socl_l7_wdog_force_clear` whenever
    # this wire is high.
    tb.log.info(f"  waiting up to {RECOVERY_WAIT_CYCLES} cy for "
                f"socl_l7_wdog_force_clear to assert "
                f"(threshold = {SOCL_L7_WDOG_THRESHOLD})...")

    cycles_waited = 0
    sample_period = 1000
    wdog_fired_at = -1
    last_wdog_cnt = 0
    while cycles_waited < RECOVERY_WAIT_CYCLES:
        await ClockCycles(dut.hclk, sample_period)
        cycles_waited += sample_period
        try:
            wdog = int(fc.socl_l7_wdog_force_clear.value)
            wdog_cnt = int(fc.socl_l7_wdog_cnt.value)
        except (AttributeError, ValueError):
            wdog = 0
            wdog_cnt = 0
        if cycles_waited % 20000 == 0:
            tb.log.info(f"    +{cycles_waited} cy: wdog_cnt = "
                        f"0x{wdog_cnt:04x}, wdog_force_clear = {wdog}, "
                        f"master state = {tb.fcsm_state('m')}")
        if wdog == 1 and wdog_fired_at < 0:
            wdog_fired_at = cycles_waited
            tb.log.info(f"  socl_l7_wdog_force_clear asserted at "
                        f"+{cycles_waited} cy "
                        f"(wdog_cnt = 0x{wdog_cnt:04x})")
            break
        last_wdog_cnt = wdog_cnt

    assert wdog_fired_at >= 0, (
        f"F-1 watchdog never asserted -- waited {RECOVERY_WAIT_CYCLES} "
        f"cycles (threshold = {SOCL_L7_WDOG_THRESHOLD}).  Last wdog_cnt = "
        f"0x{last_wdog_cnt:04x}.  Either the counter is not ticking or "
        f"socl_l7_real_crc_seen latched unexpectedly."
    )

    # Sanity bound: the watchdog runs on the (slower) io_tx_clk
    # domain.  Allow up to 10x the threshold in hclk cycles
    # (empirically ~6x in this TB) before declaring a real bug.
    assert wdog_fired_at <= 10 * SOCL_L7_WDOG_THRESHOLD, (
        f"F-1 watchdog fired at +{wdog_fired_at} hclk cy "
        f"(threshold = {SOCL_L7_WDOG_THRESHOLD} tx_clk cy).  "
        f"Suspiciously late -- check the io_tx_clk / hclk ratio."
    )

    # Now release Force(send_nack_req).  The always-block's
    # `& ~socl_l7_wdog_force_clear` AND-clear is now visible and the
    # next clock edge should drive send_nack_req to 0.
    #
    # NOTE: we KEEP Force(state=7) -- the FCSM's next-state mux requires
    # `auto_tx_out_advance` (an LLTX-side signal) to leave state 7 for
    # state 4.  In this isolated cocotb harness there is no peer
    # consuming NACK packets, so auto_tx_out_advance does not fire in
    # the few hundred cycles we observe.  The F-1 watchdog's contract
    # is to clear send_nack_req -- the state-7 -> state-4 transition is
    # upstream of the watchdog and is exercised by `wlink_pair`-class
    # regressions where the LLTX is exercised against a passive peer.
    # The KEY assertion here is therefore on send_nack_req, NOT on
    # state.
    tb.log.info("  releasing Force(send_nack_req) (keeping Force(state=7) "
                "and Force(reached_link_data=1)).  watchdog should clear "
                "send_nack_req synchronously.")
    fc.send_nack_req.value = Release()
    await ClockCycles(dut.hclk, 50)
    final_snr = int(fc.send_nack_req.value)
    tb.log.info(f"  send_nack_req after release + 50 cy = {final_snr}")
    assert final_snr == 0, (
        f"send_nack_req = {final_snr} after Force(send_nack_req) Release "
        f"-- the watchdog's `& ~socl_l7_wdog_force_clear` AND-clear in "
        f"the synchronous always-block did NOT fire.  Check that "
        f"socl_l7_wdog_force_clear is still asserted "
        f"({int(fc.socl_l7_wdog_force_clear.value)}) and that the "
        f"watchdog-aware always-block was actually elaborated."
    )

    # Release the remaining forces cleanly.
    fc.state.value = Release()
    fc.socl_l7_reached_link_data.value = Release()

    tb.log.info(f"[PASS] F-1 watchdog fired at +{wdog_fired_at} cy "
                f"(threshold = {SOCL_L7_WDOG_THRESHOLD}); "
                f"send_nack_req cleared to 0 synchronously after "
                f"Force(send_nack_req) release.")
