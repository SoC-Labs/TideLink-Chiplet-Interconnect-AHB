"""Post-watchdog doorbell delivery -- build #5 secondary wedge sim repro.

Background
==========
Build #5 (fix/fcsm-l7-wedge-watchdog HW deploy):
  * The F-1 watchdog ASSERTS at +~16384 io_tx_clk cycles in state 7 as
    designed (ILA shows socl_l7_wdog_force_clear high).
  * The synchronous always-block AND-clears send_nack_req to 0 -- exactly
    what F-1 is meant to do.
  * BUT: returner_busy (APB REG_STATUS[0]) stays asserted, the master
    FCSM does NOT visibly transition out of state 7 into state 4, and a
    subsequent doorbell ring on master never increments slave's
    DOORBELL_RESP_ACC.  Application traffic is still wedged.

The existing `test_l7_wedge_recovers_with_watchdog_fix` only asserts
that send_nack_req clears.  It deliberately keeps Force(state=7) high
across the watchdog event and notes "state-7 -> state-4 transition is
upstream of F-1 and is exercised by wlink_pair-class regressions".
That sidesteps the build #5 secondary symptom entirely.

What this test adds
-------------------
1. Same wedge injection mechanism as the existing repro
   (`_force_master_into_state7`):  Force send_nack_req=1, Force state=7,
   Force socl_l7_reached_link_data=1.
2. WAIT for socl_l7_wdog_force_clear to assert (proves F-1 fires).
3. RELEASE Force(state) AND Release(send_nack_req) -- give the FCSM
   freedom to run the next-state mux now that the watchdog is clearing
   the NACK request.
4. Sample for ≥4096 hclk cycles after release:
     * does state actually fall out of 7 -> 4?
     * does returner_busy clear?
     * does a doorbell ring on master make it to slave?

If sim reproduces the HW secondary wedge -> doorbells stay 0,
returner_busy stays 1, FCSM may stay at 7 even after Force release.
Then we have a fast iteration loop for the F-1.5 design.
If sim does NOT reproduce -> the build #5 symptom is synthesis /
placement-induced and lives outside RTL logic that the cocotb harness
exercises.

Probe coverage
--------------
After Force release we sample (every 100 hclk cy):
  * tb.fcsm_state("m")                                       -- expect 4
  * fc.send_nack_req                                          -- expect 0
  * fc.auto_tx_out_advance                                    -- pulse?
  * fc.ack_nack_fifo_valid / fc.ack_nack_fifo_io_rinc        -- drained?
  * fc.pkt_is_cr_pkt / fc.pkt_is_crack_pkt                    -- ?
  * APB REG_STATUS bit 0 (returner_busy)                      -- expect 0
  * APB DOORBELL_RESP_ACC on slave before/after 10 rings      -- expect bumps

Invocation
----------
    cd cocotb/tidelink_top_pair
    make MODULE=test_post_watchdog_doorbell_delivery \
         SIM=vcs TB_TOP_NO_DUMP=1 SIM_BUILD=sim_build_postwdog
"""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release


from test_tidelink_pair_doorbell import (
    PairTB,
    APB_TIDELINK_BASE,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)

# REG_STATUS offset inside the TideLink APB region:
#   Region 0, paddr[4:2] = 3'h4 => byte offset 0x10 from APB_TIDELINK_BASE.
APB_REG_STATUS = APB_TIDELINK_BASE + 0x010

# F-1 watchdog threshold mirrors src/rtl/local_overrides/WlinkGenericFCSM_6.v.
SOCL_L7_WDOG_THRESHOLD = 0x4000

# Maximum hclk cycles to wait for socl_l7_wdog_force_clear to assert.
# Same scaling factor as the existing recovery test (~6x hclk/tx_clk).
WDOG_FIRE_WAIT_CYCLES = 200_000

# After Release(state) + Release(send_nack_req), how long to give the FCSM
# to drain and the doorbell paths to drain.
POST_RELEASE_OBSERVE_CYCLES = 8000

# Number of doorbell rings to attempt after release.
N_DOORBELLS = 10


# ---------------------------------------------------------------------------
# Helpers (kept private to this module -- the existing l7 repro helpers are
# tightly coupled to the test_01 / test_02 assertion sequence; we duplicate
# only the bits we need to keep the two tests behaviourally independent).
# ---------------------------------------------------------------------------

def _fcsm(dut):
    return dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _has_f1_watchdog(dut) -> bool:
    try:
        _ = _fcsm(dut).socl_l7_wdog_force_clear
        return True
    except AttributeError:
        return False


def _safe_int(handle):
    """Read a hierarchical handle, returning -1 on any read error (X-prop)."""
    try:
        return int(handle.value)
    except (AttributeError, ValueError):
        return -1


def _force_master_into_state7(tb):
    fc = _fcsm(tb.dut)
    fc.socl_l7_reached_link_data.value = Force(1)
    fc.send_nack_req.value = Force(1)
    fc.state.value = Force(7)
    return fc


# ---------------------------------------------------------------------------
# The single test
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_post_watchdog_doorbell_delivery(dut):
    """Drive the master FCSM into the state-7 wedge, wait for F-1 watchdog,
    release the Force, then check whether application traffic actually
    flows again.

    Expected outcomes (per task prompt):
      (a) Sim shows doorbells deliver after watchdog
          -> sim does NOT reproduce HW secondary wedge.  RTL-vs-synthesis
             divergence -- F-1.5 needed at the placement / hold-margin
             level, not at the RTL level.
      (b) Sim shows doorbells DON'T deliver after watchdog
          -> sim DOES reproduce.  We get a fast iteration loop.

    The test always exercises every probe and logs; the final PASS/FAIL
    is INFORMATIONAL only -- a failure of doorbell delivery is the bug
    we're trying to characterise, not a test-infrastructure failure.  We
    use `tb.log.error(...)` for the doorbell-not-delivered case so it is
    obvious in the log without aborting the test (so subsequent probes
    still run).
    """
    tb = PairTB(dut)

    if not _has_f1_watchdog(dut):
        tb.log.info(
            "[SKIP-EQUIV] F-1 watchdog signal (socl_l7_wdog_force_clear) "
            "not present in FCSM_6 -- this test is meaningful only on "
            "fix/fcsm-l7-wedge-watchdog.  Returning PASS without exercise."
        )
        return

    # ----- Reset + role_lock --------------------------------------------
    await tb.reset()
    await tb.do_role_lock()
    await tb.wait_role_locked(max_cycles=20000)
    await ClockCycles(dut.hclk, 1000)
    tb.log.info(
        f"Reset+role_lock complete; FCSM state pre-force = "
        f"master={tb.fcsm_state('m')} slave={tb.fcsm_state('s')}"
    )

    # Capture pre-wedge baseline for the doorbell counter so we can attribute
    # any later increment to the post-watchdog rings (and not to bringup).
    s_db_baseline = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_status_baseline = await tb.m_apb.read(APB_REG_STATUS)
    tb.log.info(
        f"  baseline: slave DBRA = {s_db_baseline}, "
        f"master REG_STATUS = 0x{m_status_baseline:08x} "
        f"(returner_busy bit0 = {m_status_baseline & 1})"
    )

    # ----- Inject the wedge ----------------------------------------------
    fc = _force_master_into_state7(tb)
    await ClockCycles(dut.hclk, 100)
    assert tb.fcsm_state("m") == 7, (
        f"injection failed: master state = {tb.fcsm_state('m')}, expected 7"
    )
    tb.log.info("  master FCSM at state 7 after Force injection.")

    # ----- Wait for the F-1 watchdog to assert ---------------------------
    tb.log.info(
        f"  polling socl_l7_wdog_force_clear up to {WDOG_FIRE_WAIT_CYCLES} "
        f"hclk cy (threshold = 0x{SOCL_L7_WDOG_THRESHOLD:x} tx_clk cy)..."
    )
    cycles_waited = 0
    sample_period = 1000
    wdog_fired_at = -1
    last_wdog_cnt = 0
    while cycles_waited < WDOG_FIRE_WAIT_CYCLES:
        await ClockCycles(dut.hclk, sample_period)
        cycles_waited += sample_period
        wdog = _safe_int(fc.socl_l7_wdog_force_clear)
        wdog_cnt = _safe_int(fc.socl_l7_wdog_cnt)
        if cycles_waited % 20000 == 0:
            tb.log.info(
                f"    +{cycles_waited} cy: wdog_cnt = 0x{wdog_cnt:04x}, "
                f"wdog_force_clear = {wdog}, master state = "
                f"{tb.fcsm_state('m')}"
            )
        if wdog == 1 and wdog_fired_at < 0:
            wdog_fired_at = cycles_waited
            tb.log.info(
                f"  socl_l7_wdog_force_clear asserted at +{cycles_waited} cy "
                f"(wdog_cnt = 0x{wdog_cnt:04x})"
            )
            break
        last_wdog_cnt = wdog_cnt

    assert wdog_fired_at >= 0, (
        f"F-1 watchdog never asserted in {WDOG_FIRE_WAIT_CYCLES} cy "
        f"(last wdog_cnt = 0x{last_wdog_cnt:04x}).  Cannot proceed with "
        f"post-watchdog observation."
    )

    # ----- Release Force(state) + Force(send_nack_req) -------------------
    # KEEP Force(socl_l7_reached_link_data=1) for symmetry with the
    # existing recovery test -- the gate has long since latched naturally
    # by this point, but we want to isolate the watchdog clear path so any
    # post-release wedge is attributable to the F-1 fix, not to the
    # forgive gate winning the race.
    #
    # Release `state` first so the FCSM is FREE to re-enter the next-state
    # mux.  Then release `send_nack_req` so the always-block's
    # `& ~socl_l7_wdog_force_clear` AND-clear can take effect.
    tb.log.info(
        "  RELEASING Force(state) and Force(send_nack_req) -- FCSM is now "
        "free to drain state 7 via the natural next-state mux."
    )
    fc.state.value = Release()
    fc.send_nack_req.value = Release()
    await ClockCycles(dut.hclk, 50)

    snr_post_release = _safe_int(fc.send_nack_req)
    state_post_release = tb.fcsm_state("m")
    tb.log.info(
        f"  +50 cy after release: state = {state_post_release}, "
        f"send_nack_req = {snr_post_release}"
    )

    # ----- Probe sweep over POST_RELEASE_OBSERVE_CYCLES ------------------
    # Histogram every 100 hclk cy for `POST_RELEASE_OBSERVE_CYCLES` cycles.
    # We capture state, send_nack_req, auto_tx_out_advance pulses,
    # ack_nack_fifo_valid pulses, pkt_is_cr/crack_pkt pulses.
    sweep_samples = POST_RELEASE_OBSERVE_CYCLES // 100
    state_hist = {k: 0 for k in range(8)}
    snr_high_cnt = 0
    wdog_clear_still_high_cnt = 0
    auto_tx_out_advance_pulses = 0
    ack_nack_fifo_valid_pulses = 0
    ack_nack_fifo_rinc_pulses = 0
    pkt_is_cr_pkt_pulses = 0
    pkt_is_crack_pkt_pulses = 0
    for i in range(sweep_samples):
        await ClockCycles(dut.hclk, 100)
        state_hist[tb.fcsm_state("m")] = (
            state_hist.get(tb.fcsm_state("m"), 0) + 1
        )
        if _safe_int(fc.send_nack_req) == 1:
            snr_high_cnt += 1
        if _safe_int(fc.socl_l7_wdog_force_clear) == 1:
            wdog_clear_still_high_cnt += 1
        if _safe_int(fc.auto_tx_out_advance) == 1:
            auto_tx_out_advance_pulses += 1
        if _safe_int(fc.ack_nack_fifo_valid) == 1:
            ack_nack_fifo_valid_pulses += 1
        if _safe_int(fc.ack_nack_fifo_io_rinc) == 1:
            ack_nack_fifo_rinc_pulses += 1
        if _safe_int(fc.pkt_is_cr_pkt) == 1:
            pkt_is_cr_pkt_pulses += 1
        if _safe_int(fc.pkt_is_crack_pkt) == 1:
            pkt_is_crack_pkt_pulses += 1

    tb.log.info(
        f"  post-release {POST_RELEASE_OBSERVE_CYCLES} cy sweep "
        f"({sweep_samples} samples @ /100 cy):"
    )
    tb.log.info(f"    state histogram     : {dict(sorted(state_hist.items()))}")
    tb.log.info(f"    send_nack_req high  : {snr_high_cnt}/{sweep_samples}")
    tb.log.info(f"    wdog_force_clear hi : {wdog_clear_still_high_cnt}/{sweep_samples}")
    tb.log.info(f"    auto_tx_out_advance : {auto_tx_out_advance_pulses}/{sweep_samples}")
    tb.log.info(f"    ack_nack_fifo_valid : {ack_nack_fifo_valid_pulses}/{sweep_samples}")
    tb.log.info(f"    ack_nack_fifo_rinc  : {ack_nack_fifo_rinc_pulses}/{sweep_samples}")
    tb.log.info(f"    pkt_is_cr_pkt       : {pkt_is_cr_pkt_pulses}/{sweep_samples}")
    tb.log.info(f"    pkt_is_crack_pkt    : {pkt_is_crack_pkt_pulses}/{sweep_samples}")

    state_after_release = tb.fcsm_state("m")
    snr_final = _safe_int(fc.send_nack_req)
    tb.log.info(
        f"  final (end of sweep): state = {state_after_release}, "
        f"send_nack_req = {snr_final}"
    )

    # ----- Probe REG_STATUS for returner_busy ----------------------------
    m_status_post = await tb.m_apb.read(APB_REG_STATUS)
    returner_busy = m_status_post & 1
    tb.log.info(
        f"  master REG_STATUS post-release: 0x{m_status_post:08x} "
        f"(returner_busy bit0 = {returner_busy})"
    )

    # ----- Ring N_DOORBELLS doorbells from master ------------------------
    tb.log.info(f"  ringing {N_DOORBELLS} doorbells on master...")
    s_db_pre_rings = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_local_pre = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    for i in range(N_DOORBELLS):
        await tb.m_apb.write(APB_DOORBELL, 1)
        await ClockCycles(dut.hclk, 200)
    # Drain time for the last ring to traverse M->S.
    await ClockCycles(dut.hclk, 4000)
    s_db_post_rings = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    m_db_local_post = await tb.m_apb.read(APB_DOORBELL_RESP_ACC)
    s_status_post = await tb.s_apb.read(APB_REG_STATUS)
    m_status_post2 = await tb.m_apb.read(APB_REG_STATUS)
    n_delivered = s_db_post_rings - s_db_pre_rings

    tb.log.info(
        f"  slave  DOORBELL_RESP_ACC: pre={s_db_pre_rings} "
        f"post={s_db_post_rings} delivered={n_delivered}/{N_DOORBELLS}"
    )
    tb.log.info(
        f"  master DOORBELL_RESP_ACC: pre={m_db_local_pre} "
        f"post={m_db_local_post}"
    )
    tb.log.info(
        f"  master REG_STATUS post-rings: 0x{m_status_post2:08x} "
        f"(returner_busy bit0 = {m_status_post2 & 1})"
    )
    tb.log.info(
        f"  slave  REG_STATUS post-rings: 0x{s_status_post:08x} "
        f"(returner_busy bit0 = {s_status_post & 1})"
    )

    # ----- Verdict (logged, not asserted -- this test characterises) ----
    if n_delivered == N_DOORBELLS:
        verdict = ("OUTCOME (a): doorbells DELIVERED after watchdog clear. "
                   "Sim does NOT reproduce build #5 HW secondary wedge -- "
                   "the symptom is likely synth/placement-induced.")
        tb.log.info(f"[VERDICT] {verdict}")
    elif n_delivered == 0:
        verdict = ("OUTCOME (b): doorbells BLOCKED after watchdog clear. "
                   "Sim REPRODUCES build #5 HW secondary wedge -- F-1.5 "
                   "fast iteration loop available.")
        tb.log.error(f"[VERDICT] {verdict}")
    else:
        verdict = (f"OUTCOME (partial): {n_delivered}/{N_DOORBELLS} "
                   f"doorbells delivered.  Pipeline drained partially.")
        tb.log.warning(f"[VERDICT] {verdict}")

    # ----- Clean release of the remaining Force --------------------------
    fc.socl_l7_reached_link_data.value = Release()

    # The test itself ALWAYS PASSES if it reached this point -- the outcome
    # is informational.  The reason: the body of this test exists to
    # characterise the behaviour, not to gate CI.  A future regression
    # gate can convert these prints to asserts once we know whether (a)
    # or (b) is the expected post-fix outcome.
    tb.log.info("[DONE] test_post_watchdog_doorbell_delivery completed; "
                "see VERDICT line above for the build #5 sim-repro result.")
