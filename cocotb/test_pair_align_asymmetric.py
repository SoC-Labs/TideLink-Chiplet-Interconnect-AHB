"""§9 per-lane bit-slip calibration with ASYMMETRIC per-lane skews.

The baseline `test_pair_align.py` validates §9 with a single uniform skid
value applied to every lane (`SKID_BITS=N`). That hides the realistic FPGA
case, in which each routing trace has its own propagation delay and so each
lane needs an independent slip value.

This test exercises the per-lane mode of `pad_skid.sv` (2026-05-14):
it programmes a different skid amount on each of the 8 lanes and asserts
that the §9 calibration sweep recovers exactly those values, then runs the
post-training bring-up to FCSM state >= 4 with cr_pkt_seen_rx on both sides.

We can't pass `+define+` plusargs from inside cocotb (the testbench is
already elaborated by the time Python starts), so each scenario must run
as its own `make` invocation. The Makefile environment is set up by the
runner — this file reads the pattern from the `SKID_LANE<n>` env vars
(exported by the Makefile) and asserts the calibrated slips match.

Invocation
----------
    make MODULE=test_pair_align_asymmetric \\
         SKID_LANE0=3 SKID_LANE1=5 SKID_LANE2=0 SKID_LANE3=2 \\
         SKID_LANE4=7 SKID_LANE5=1 SKID_LANE6=4 SKID_LANE7=6
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, snapshot
from test_pair_align import (
    _gpio_path, _set_lane_slip, _set_all_slip, _set_training_mode,
    _read_lane_locked, _toggle_swreset, _calibrate_lane,
)


def _expected_pattern():
    """Read the per-lane expected skid from env vars set by the Makefile.

    SKID_LANE<n> is consumed both by the Makefile (-> +define+ in the
    pad_skid params) and here (the value cocotb expects the calibration to
    recover). A missing SKID_LANE<n> falls back to SKID_BITS (uniform).
    """
    base = int(os.environ.get("SKID_BITS", "0"))
    pat = []
    for n in range(8):
        v = os.environ.get(f"SKID_LANE{n}", "")
        pat.append(int(v) if v.strip() else base)
    return pat


async def _run_one_pattern(dut, label):
    """Calibrate, assert per-lane slips match the expected pattern, bring up."""
    expected = _expected_pattern()
    dut._log.info("=" * 70)
    dut._log.info(f"  test_pair_align_asymmetric[{label}] expected={expected}")
    dut._log.info("=" * 70)

    # Sanity: confirm tb_top picked up the same pattern via its mirrors.
    try:
        observed = [int(getattr(dut, f"SKID_BITS_LANE{n}_EXPOSED").value) for n in range(8)]
        dut._log.info(f"  tb_top mirrors LANE0..7 = {observed}")
        assert observed == expected, (
            f"tb_top per-lane mirrors {observed} != Makefile pattern {expected}"
        )
    except AttributeError:
        dut._log.warning("  per-lane mirrors not visible in tb_top — env-only check")

    await setup(dut)

    # Pre-arm training mode before role-lock so the deserialiser sees the
    # training byte as soon as the link-clock comes alive.
    _set_training_mode(dut, "m", True)
    _set_training_mode(dut, "s", True)
    _set_all_slip(dut, "m", 0)
    _set_all_slip(dut, "s", 0)

    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 500)

    # Per-lane calibration sweep.
    slave_slip  = [None] * 8
    master_slip = [None] * 8
    for lane in range(8):
        s = await _calibrate_lane(dut, "s", lane)
        m = await _calibrate_lane(dut, "m", lane)
        slave_slip[lane]  = s
        master_slip[lane] = m
        dut._log.info(
            f"  lane {lane}: expected={expected[lane]} "
            f"m->s slip={s} s->m slip={m}"
        )

    # Each lane's recovered slip should match the injected skew.
    failures = []
    for lane in range(8):
        if slave_slip[lane] != expected[lane]:
            failures.append(
                f"  slave-RX lane {lane}: got {slave_slip[lane]}, expected {expected[lane]}")
        if master_slip[lane] != expected[lane]:
            failures.append(
                f"  master-RX lane {lane}: got {master_slip[lane]}, expected {expected[lane]}")

    assert _read_lane_locked(dut, "s") == 0xFF, (
        f"Not all slave lanes locked: 0x{_read_lane_locked(dut,'s'):02x}")
    assert _read_lane_locked(dut, "m") == 0xFF, (
        f"Not all master lanes locked: 0x{_read_lane_locked(dut,'m'):02x}")
    assert not failures, "Per-lane calibration mismatched:\n" + "\n".join(failures)

    # Exit training, swreset, bring up.
    _set_training_mode(dut, "m", False)
    _set_training_mode(dut, "s", False)
    await _toggle_swreset(dut)
    await lock_master(dut)
    await lock_slave(dut)

    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_cr      = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_cr      = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    max_m = 0; max_s = 0; cr_m = False; cr_s = False
    for _ in range(5000):
        await ClockCycles(dut.master_clk, 1)
        try:
            max_m = max(max_m, int(m_state_h.value))
            max_s = max(max_s, int(s_state_h.value))
            if int(m_cr.value): cr_m = True
            if int(s_cr.value): cr_s = True
        except ValueError:
            pass
        if cr_m and cr_s and max_m >= 4 and max_s >= 4:
            break

    await snapshot(dut, "m", f"asym[{label}]")
    await snapshot(dut, "s", f"asym[{label}]")

    # -- Concise summary ----------------------------------------------------
    dut._log.info("-" * 70)
    dut._log.info(f"  SUMMARY[{label}]")
    dut._log.info(f"    skid pattern (per-lane)   = {expected}")
    dut._log.info(f"    calibrated slip master->slave = {slave_slip}")
    dut._log.info(f"    calibrated slip slave->master = {master_slip}")
    dut._log.info(f"    final FCSM master={max_m} slave={max_s}")
    dut._log.info(f"    cr_pkt_seen master={cr_m} slave={cr_s}")
    passed = (max_m >= 4 and max_s >= 4 and cr_m and cr_s)
    dut._log.info(f"    RESULT: {'PASS' if passed else 'FAIL'}")
    dut._log.info("-" * 70)

    assert max_m >= 4, f"master FCSM stuck at {max_m}"
    assert max_s >= 4, f"slave FCSM stuck at {max_s}"
    assert cr_m, "master cr_pkt_seen_rx never asserted"
    assert cr_s, "slave cr_pkt_seen_rx never asserted"


@cocotb.test()
async def test_pair_align_asymmetric(dut):
    """Run a single asymmetric per-lane pattern sourced from env.

    The test runner (or test harness) is expected to invoke this test
    multiple times with different SKID_LANE<n> permutations. The whole
    point of the per-lane mechanism is that we can drop in any 8-tuple
    of slip values 0..7 and the calibration should recover all of them.
    """
    label = os.environ.get("SKID_LABEL", "default")
    await _run_one_pattern(dut, label)
