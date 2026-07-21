"""F14-B follow-up (lane Z-D) — IS THE BEACON CAUSAL? (control for the ladder)

`test_ei_recovery_ladder.py` walks rungs in order, so "the link came back at
rung b2" is confounded: by the time b2 runs, several thousand hclk have passed
AND the earlier rungs' health checks have themselves pushed packets into the
link. Either could have re-synced it on its own. A sequential ladder can only
ever produce a rung ORDERING, never a causal claim about one rung.

These three tests separate the beacon from the wait:

  test_20  ISOLATION — wedge, then apply ONLY the beacon burst (R8=0x0C), with
           no preceding rungs. If this recovers, the beacon is sufficient.
  test_21  CONTROL   — wedge, then do NOTHING but wait and probe, matching
           test_20's elapsed cycles and health-probe count as closely as the
           harness allows. If this ALSO recovers, the ladder result was time,
           not beacon, and the F14-B recovery claim must be withdrawn.
  test_22  DOSE      — wedge, then apply the beacon with the force_always bit
           CLEARED (R8=0x04, insert_en only). The beacon inserter is gated by
           `io_link_tx_tx_idle & (postcount==0)` unless force_always drops that
           gate (WavD2DGpio_v2.v:626-629), so a data-mode wedge should NOT be
           cleared by 0x04 — the idle slots the gate needs are exactly what a
           wedged link stops producing. This is the mechanism check: it should
           FAIL, and its failing is what proves the recovery rides on the
           beacon actually reaching the wire rather than on the R8 write.

Read together: test_20 pass + test_21 fail-to-recover + test_22 fail-to-recover
is the evidence that a transient forced SYNC beacon is the causal, minimal,
firmware-only recovery for a data-mode framing wedge.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
from errinj_common import (
    inject_data, clear_all, link_healthy, burst_during_fault, M_FLIP,
)
from recovery_common import (
    rung_b_beacon, liveness_snapshot, fmt_liveness, link_healthy_tagged,
    R8_SYNC_EN, R8_SYNC_FORCE,
)

# Every pass/fail decision in this file uses the STALE-PROOF check
# (recovery_common.link_healthy_tagged): drained RX + a payload tag unique per
# call. These are the load-bearing causal claims, so a stale RX-FIFO word must
# not be able to score a recovery that did not happen.

WEDGE_PAYLOADS = [[0xBEEF0001, 0xF00D0002], [0xBEEF0003, 0xF00D0004],
                  [0xBEEF0005, 0xF00D0006]]

# rung_b_beacon's own dwell + settle, so the control waits the same wall time.
BEACON_DWELL  = 6000
BEACON_SETTLE = 2000


async def _wedge(dut, tag):
    """Bring up, prove healthy, then wedge s->m with all-lane corruption.
    Returns (tb, wedged_ok) — asserts the wedge actually took."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: link never reached CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: link not healthy pre-injection ({detail})"

    await burst_during_fault(tb, "s", "m", WEDGE_PAYLOADS,
                             fault_setup=lambda: inject_data(dut, "s2m", M_FLIP, 0xFF),
                             fault_clear=lambda: clear_all(dut), ctx=tag)
    clear_all(dut)
    await ClockCycles(dut.hclk, 2000)

    ok, detail = await link_healthy_tagged(tb, "s", "m")
    tb.log.info(f"  [{tag}] post-fault wedged? healthy={ok} ({detail})")
    assert not ok, (f"{tag}: the fault did not wedge the link (healthy={detail}) — "
                    f"this test cannot say anything about recovery. Re-tune the "
                    f"injection window before reading any verdict from this file.")
    tb.log.info(f"  [{tag}] wedged obs: {fmt_liveness(await liveness_snapshot(tb))}")
    return tb


@cocotb.test()
async def test_20_beacon_alone_recovers(dut):
    """ISOLATION: wedge -> beacon burst R8=0x0C on both dies -> healthy?"""
    tb = await _wedge(dut, "B20_isolation")
    await rung_b_beacon(tb, word=R8_SYNC_EN | R8_SYNC_FORCE,
                        dwell=BEACON_DWELL)
    ok, detail = await link_healthy_tagged(tb, "s", "m")
    tb.log.info(f"VERDICT[B20_beacon_alone]: recovered={ok} ({detail}) | "
                f"obs: {fmt_liveness(await liveness_snapshot(tb))}")
    assert ok, (
        "The beacon burst alone did NOT recover the wedge, but the sequential "
        "ladder recovered at the b2 rung. That means the ladder's b2 result was "
        "an artefact of the preceding rungs or of elapsed time, and the "
        "'firmware-only recovery' claim in docs/LINK_RECOVERY_MECHANISM.md must "
        f"be withdrawn. detail={detail}")


@cocotb.test()
async def test_21_control_wait_does_not_recover(dut):
    """CONTROL: wedge -> wait the same time, probe the same way, write NOTHING."""
    tb = await _wedge(dut, "B21_control")
    # Same elapsed cycles as rung_b_beacon, with NO R8 write anywhere.
    await ClockCycles(dut.hclk, BEACON_DWELL + BEACON_SETTLE)
    ok, detail = await link_healthy_tagged(tb, "s", "m")
    tb.log.info(f"VERDICT[B21_control_wait]: recovered={ok} ({detail}) | "
                f"obs: {fmt_liveness(await liveness_snapshot(tb))}")
    assert not ok, (
        "CONTROL FAILED: the wedge cleared itself with no intervention at all, "
        "after only the beacon rung's dwell. The link is then self-healing on a "
        "timescale the ladder cannot resolve, and NO rung of the ladder — "
        f"including b2 — may be claimed as causal. detail={detail}")


@cocotb.test()
async def test_23_swi_recal_is_a_noop_after_first_lock(dut):
    """DIRECT MEASUREMENT of why rungs (a) and (e) cannot work.

    tidelink_phy_align_calibrator.sv latches `calibrated_once_q` the first time
    the sweep reaches S_DONE, and then gates BOTH re-trigger edges with it:

        wire swreset_fall_eff = swreset_fall & ~calibrated_once_q;
        assign trigger_now = role_locked_rise_eff | (swreset_fall_eff & role_locked_sync);

    so after one good lock the SWI_RECAL falling edge is a NO-OP and only `rst`
    (POR) can clear the sticky. That was a deliberate fix for a real bug (the
    autoneg winner's spurious training-exit recal pulse wedging the master FCSM
    at state 2), and the RTL comment names the consequence out loud: "if
    production SW needs an explicit forced recal of an already-locked link, it
    should issue it via a POR or a dedicated W1P".

    This test measures that claim on a HEALTHY link rather than inferring it
    from a failed recovery rung: pulse SWI_RECAL and watch the calibrator FSM.
    If the calibrator never leaves S_DONE, there is NO firmware-reachable PHY
    retrain in this design — which is the crux of the field-recoverability
    verdict, so it deserves its own measurement."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: link never reached CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    before = {s: tb.cal_state_name(s) for s in ("m", "s")}
    tb.log.info(f"  [B23] cal state before recal pulse: {before}")

    from recovery_common import R8_RECAL, R8_TRAIN
    for s in ("m", "s"):
        await tb.apb(s).write(0x2100, R8_RECAL | R8_TRAIN)
    await ClockCycles(dut.hclk, 400)
    for s in ("m", "s"):
        await tb.apb(s).write(0x2100, R8_TRAIN)      # the RECAL FALLING edge

    # Sample densely across the window in which S_DONE->S_ARM would show up.
    seen = set()
    for _ in range(60):
        await ClockCycles(dut.hclk, 50)
        for s in ("m", "s"):
            seen.add(f"{s}:{tb.cal_state_name(s)}")
    for s in ("m", "s"):
        await tb.apb(s).write(0x2100, 0)

    left_done = {x for x in seen if not x.endswith(":DONE")}
    tb.log.info(f"VERDICT[B23_recal_sticky]: cal states observed after the "
                f"SWI_RECAL falling edge = {sorted(seen)} | "
                f"left S_DONE = {sorted(left_done) if left_done else 'NEVER'}")
    tb.log.info(
        "VERDICT[B23_recal_sticky]: "
        + ("the calibrator DID re-trigger — calibrated_once_q does not block the "
           "recal path, and a firmware-only PHY retrain IS available."
           if left_done else
           "the calibrator NEVER left S_DONE — SWI_RECAL is a no-op after first "
           "lock (calibrated_once_q), so NO firmware-reachable PHY retrain exists."))


@cocotb.test()
async def test_22_insert_en_without_force_does_not_recover(dut):
    """DOSE/MECHANISM: wedge -> beacon with force_always CLEARED (R8=0x04)."""
    tb = await _wedge(dut, "B22_no_force")
    await rung_b_beacon(tb, word=R8_SYNC_EN, dwell=BEACON_DWELL)
    ok, detail = await link_healthy_tagged(tb, "s", "m")
    tb.log.info(f"VERDICT[B22_insert_en_only]: recovered={ok} ({detail}) | "
                f"obs: {fmt_liveness(await liveness_snapshot(tb))}")
    assert not ok, (
        "R8=0x04 (insert_en, idle-gated) recovered the wedge on its own. Then "
        "force_always is NOT required for the recovery routine, and the routine "
        "in docs/LINK_RECOVERY_MECHANISM.md should drop it — force_always is a "
        "known word-deleter over live traffic, so the weaker dose is strictly "
        f"preferable if it suffices. detail={detail}")
