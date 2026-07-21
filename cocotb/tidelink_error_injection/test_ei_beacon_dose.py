"""F14-B follow-up (lane Z-D) — DOSE vs TIME: how much beacon recovers a wedge?

This file exists because two of this lane's own results disagreed, and the
disagreement is the interesting part:

  * `test_ei_recovery_ladder` (stale-proof, tagged checks) recovers the W1
    all-lane-corruption wedge at rung `b2`, having already run rung `a`
    (SWI_RECAL pulse) and rung `b1` (beacon 0x04) before it.
  * `test_ei_beacon_recovery.test_20` applies ONE 0x0C beacon burst to the same
    wedge with nothing before it, and does NOT recover.

Both used the drained/tagged check, so neither is a stale-word artefact. The
difference is cumulative: by the time the ladder reaches b2 it has issued
several R8 writes, two earlier beacon windows, and several health probes.

`test_21`'s control was too weak to separate those — it matched the dwell of a
SINGLE beacon rung, not the ladder's cumulative elapsed time and traffic. So it
proved only "the wedge does not clear itself within one beacon window", which is
not the claim that needs controlling.

These two tests are the matched pair that actually settles it:

  test_30  DOSE    — wedge, then apply repeated 0x0C beacon bursts, re-checking
                     after each. Records the burst count at which data returns.
  test_31  CONTROL — wedge, then perform the SAME number of tagged health
                     probes with the SAME total dwell, issuing NO R8 write at
                     all. If this recovers too, the recovery is time/traffic and
                     NOT the beacon, and §1/§6 of
                     docs/LINK_RECOVERY_MECHANISM.md must be rewritten.

Only if test_30 recovers and test_31 does not is a firmware-only beacon
recovery procedure supportable.
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

WEDGE_PAYLOADS = [[0xBEEF0001, 0xF00D0002], [0xBEEF0003, 0xF00D0004],
                  [0xBEEF0005, 0xF00D0006]]
BEACON_DWELL  = 6000
BEACON_SETTLE = 2000
MAX_BURSTS    = 4


async def _wedge(dut, tag):
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
    assert not ok, f"{tag}: the fault did not wedge the link ({detail})"
    tb.log.info(f"  [{tag}] wedged: {fmt_liveness(await liveness_snapshot(tb))}")
    return tb


@cocotb.test()
async def test_30_repeated_beacon_bursts(dut):
    """DOSE: how many 0x0C beacon bursts does the W1 wedge take?"""
    tb = await _wedge(dut, "D30_dose")
    recovered_at = None
    for i in range(1, MAX_BURSTS + 1):
        await rung_b_beacon(tb, word=R8_SYNC_EN | R8_SYNC_FORCE,
                            dwell=BEACON_DWELL)
        ok, detail = await link_healthy_tagged(tb, "s", "m")
        tb.log.info(f"  [D30] after burst #{i}: healthy={ok} ({detail}) | "
                    f"{fmt_liveness(await liveness_snapshot(tb))}")
        if ok:
            recovered_at = i
            break
    tb.log.info(f"VERDICT[D30_beacon_dose]: recovered_after_bursts="
                f"{recovered_at if recovered_at else f'NEVER (>{MAX_BURSTS})'}")


@cocotb.test()
async def test_31_matched_time_control(dut):
    """CONTROL: the same probes and the same dwell, with NO R8 write at all."""
    tb = await _wedge(dut, "D31_control")
    recovered_at = None
    for i in range(1, MAX_BURSTS + 1):
        # Exactly rung_b_beacon's timing, minus the two APB writes per die.
        await ClockCycles(dut.hclk, BEACON_DWELL)
        await ClockCycles(dut.hclk, BEACON_SETTLE)
        ok, detail = await link_healthy_tagged(tb, "s", "m")
        tb.log.info(f"  [D31] after wait #{i}: healthy={ok} ({detail}) | "
                    f"{fmt_liveness(await liveness_snapshot(tb))}")
        if ok:
            recovered_at = i
            break
    tb.log.info(f"VERDICT[D31_time_control]: recovered_after_waits="
                f"{recovered_at if recovered_at else f'NEVER (>{MAX_BURSTS})'}")
    assert recovered_at is None, (
        f"CONTROL FAILED: the wedge cleared after {recovered_at} matched wait "
        f"window(s) with NO register write. The recovery is then elapsed "
        f"time/probe traffic, not the SYNC beacon, and the beacon-based reading "
        f"of the ladder in docs/LINK_RECOVERY_MECHANISM.md must be withdrawn.")
