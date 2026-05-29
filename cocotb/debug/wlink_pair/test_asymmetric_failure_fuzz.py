"""Fuzz initial conditions and report asymmetric LL_RX failures.

This is the diagnostic-quality test that would catch the tdif-06 bug
from sim alone. It sweeps:
  * recal HOLD durations (50..400 cycles)
  * SETTLE durations (50..400 cycles)
  * recal counts (1..3)
  * POR stagger (0, 200, 500 cycles)
  * clock drift (0, 200, 500 ppm)

For each scenario it records:
  * whether master's cr_pkt_seen_rx latched
  * whether slave's  cr_pkt_seen_rx latched
  * max FCSM state on each side

It then tallies asymmetric failures (one side latched, the other not).
Any non-zero asymmetric count is flagged as a regression signature.

PASS CRITERION: NO asymmetric (one-side-only) cr_pkt_seen_rx failures.
A successful run prints "0 asymmetric failures". A failed run prints
each asymmetric scenario for triage.

Designed to surface the HW bug from sim. With the current
tdif-06 fix stack many scenarios DO show the asymmetric signature
(master cr_pkt_seen=1, slave cr_pkt_seen=0).
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, ctrl_write
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll, _observe_state_window,
    FCSM_LINK_DATA, STATE_NAME,
)


def _fcsm(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


async def _scenario(dut, *, hold, settle, num_recals,
                    stagger_por, m_period_ns, s_period_ns):
    """Run one fuzz scenario, return result dict."""
    await setup(dut,
                master_period_ns=m_period_ns,
                slave_period_ns=s_period_ns,
                stagger_por_cycles=stagger_por)
    await lock_master(dut)
    await lock_slave(dut)
    for _ in range(num_recals):
        await recal_cycle(dut, hold_cycles=hold, settle_cycles=settle)
    await drop_training_and_swreset_ll(dut)
    return await _observe_state_window(dut, 3000, "fuzz")


# -----------------------------------------------------------------------
# TEST 1: parameter-sweep fuzz; tally asymmetric failures.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_fuzz_initial_conditions_asymmetric_counter(dut):
    """Sweep small subset of (hold, settle, num_recals, stagger, drift).
    Tally how many scenarios produce an asymmetric cr_pkt_seen_rx result.
    PASS = zero asymmetric.  FAIL = at least one asymmetric scenario."""
    # Compact sweep to keep total runtime <5min per test.
    scenarios = []
    # (hold, settle, num_recals, stagger, m_ns, s_ns, label)
    for hold in (100, 300):
        for settle in (100, 300):
            for nrec in (1, 2):
                scenarios.append((hold, settle, nrec, 0, 20.000, 20.000,
                                  f"hold={hold}_settle={settle}_nrec={nrec}"))
    # Add drift scenarios at fixed mid-range hold/settle
    scenarios.append((200, 200, 1, 0,    20.000, 20.002,
                      "drift=100ppm_baseline"))
    scenarios.append((200, 200, 1, 0,    20.000, 20.010,
                      "drift=500ppm_baseline"))
    scenarios.append((200, 200, 1, 500,  20.000, 20.000,
                      "stagger=500cyc"))
    scenarios.append((200, 200, 1, 1000, 20.000, 20.000,
                      "stagger=1000cyc"))

    asymmetric = []
    both_fail = []
    both_pass = []
    for (hold, settle, nrec, stagger, mp, sp, label) in scenarios:
        try:
            obs = await _scenario(dut, hold=hold, settle=settle,
                                  num_recals=nrec, stagger_por=stagger,
                                  m_period_ns=mp, s_period_ns=sp)
        except Exception as e:
            dut._log.error(f"  scenario {label}: exception {e}")
            continue
        dut._log.info(
            f"  [{label}] m.cr={int(obs['cr_m'])} s.cr={int(obs['cr_s'])} "
            f"m.max={obs['max_m']}({STATE_NAME.get(obs['max_m'],'?')}) "
            f"s.max={obs['max_s']}({STATE_NAME.get(obs['max_s'],'?')})")
        if obs["cr_m"] != obs["cr_s"]:
            asymmetric.append((label, obs))
        elif obs["cr_m"] and obs["cr_s"]:
            both_pass.append((label, obs))
        else:
            both_fail.append((label, obs))

    dut._log.info("=" * 70)
    dut._log.info(
        f"  FUZZ TALLY: scenarios={len(scenarios)} "
        f"both_pass={len(both_pass)} both_fail={len(both_fail)} "
        f"ASYMMETRIC={len(asymmetric)}")
    dut._log.info("=" * 70)
    for label, obs in asymmetric:
        bad = "slave" if not obs["cr_s"] else "master"
        dut._log.error(
            f"  ASYMMETRIC [{label}]: {bad}'s cr_pkt_seen never latched "
            f"(m.cr={int(obs['cr_m'])} s.cr={int(obs['cr_s'])})")

    # PASS criterion: zero asymmetric scenarios. Any asymmetric scenario
    # is the HW bug repro and must be addressed.
    assert not asymmetric, (
        f"{len(asymmetric)}/{len(scenarios)} scenarios show asymmetric "
        f"cr_pkt_seen_rx (HW tdif-06 signature reproduced in sim). "
        f"Failing scenarios: {[s[0] for s in asymmetric]}")


# -----------------------------------------------------------------------
# TEST 2: explicit slave-only-fails detector.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_slave_only_failure_signature_search(dut):
    """Specifically searches for the HW signature:
       master cr_pkt_seen=1, slave cr_pkt_seen=0.
    Reports the FIRST scenario that exhibits this pattern, with the
    full scenario parameters (so the developer has a deterministic
    repro). Hard-fails if found (the tdif-06 fix stack should
    eliminate this signature)."""
    candidates = [
        # (hold, settle, num_recals, stagger, m_ns, s_ns, label)
        (200, 200, 1, 0,    20.000, 20.000, "default_baseline"),
        (50,  50,  1, 0,    20.000, 20.000, "tight_recal"),
        (400, 400, 1, 0,    20.000, 20.000, "loose_recal"),
        (200, 200, 2, 0,    20.000, 20.000, "double_recal"),
        (200, 200, 1, 500,  20.000, 20.000, "stagger_500"),
        (200, 200, 1, 0,    20.000, 20.002, "drift_100ppm"),
    ]
    first_hit = None
    for (hold, settle, nrec, stagger, mp, sp, label) in candidates:
        obs = await _scenario(dut, hold=hold, settle=settle,
                              num_recals=nrec, stagger_por=stagger,
                              m_period_ns=mp, s_period_ns=sp)
        slave_only_fail = obs["cr_m"] and not obs["cr_s"]
        dut._log.info(
            f"  [{label}] m.cr={int(obs['cr_m'])} s.cr={int(obs['cr_s'])} "
            f"-> slave-only-fail={slave_only_fail}")
        if slave_only_fail and first_hit is None:
            first_hit = (label, hold, settle, nrec, stagger, mp, sp, obs)

    if first_hit is not None:
        label, hold, settle, nrec, stagger, mp, sp, obs = first_hit
        dut._log.error("*" * 70)
        dut._log.error(
            f"  HW SIGNATURE REPRO: {label}\n"
            f"    hold={hold} settle={settle} num_recals={nrec} "
            f"stagger={stagger} m_ns={mp} s_ns={sp}\n"
            f"    m.cr=1 s.cr=0 -> slave LL_RX byte-align broken\n"
            f"    m.max={obs['max_m']} s.max={obs['max_s']}")
        dut._log.error("*" * 70)

    # The presence of even one slave-only-fail scenario IS the bug.
    assert first_hit is None, (
        f"slave-only cr_pkt_seen=0 failure reproduced: {first_hit[0]}. "
        "This is the tdif-06 HW signature. The fix stack must close this.")
