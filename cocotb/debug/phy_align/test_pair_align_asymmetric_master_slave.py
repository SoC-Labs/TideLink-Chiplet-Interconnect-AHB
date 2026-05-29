"""§9 asymmetric per-lane skew with DIFFERENT patterns on each direction.

Goal
----
The most realistic FPGA scenario: every routing trace has its own delay,
*and* the master→slave routing differs from the slave→master routing
(different PCB layers / different physical lanes between the two boards).

This test injects two independent per-lane patterns:
    master→slave: [3, 5, 0, 2, 7, 1, 4, 6]
    slave→master: [1, 2, 3, 4, 5, 6, 7, 0]

The slave's RX is fed by master's TX, so the slave's per-lane checker
calibrates on the master→slave pattern. The master's RX is fed by slave's
TX, so the master's checker calibrates on the slave→master pattern. The
two halves must converge independently to their respective patterns.

Invocation
----------
    make MODULE=test_pair_align_asymmetric_master_slave \\
         SKID_LANE0=3 SKID_LANE1=5 SKID_LANE2=0 SKID_LANE3=2 \\
         SKID_LANE4=7 SKID_LANE5=1 SKID_LANE6=4 SKID_LANE7=6 \\
         SKID_S_LANE0=1 SKID_S_LANE1=2 SKID_S_LANE2=3 SKID_S_LANE3=4 \\
         SKID_S_LANE4=5 SKID_S_LANE5=6 SKID_S_LANE6=7 SKID_S_LANE7=0
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, snapshot
from test_pair_align import (
    _gpio_path, _set_all_slip, _set_training_mode,
    _read_lane_locked, _toggle_swreset, _calibrate_lane,
)


def _expected_m2s():
    """Master→slave per-lane skew (slave-RX expectation)."""
    base = int(os.environ.get("SKID_BITS", "0"))
    pat = []
    for n in range(8):
        v = os.environ.get(f"SKID_LANE{n}", "")
        pat.append(int(v) if v.strip() else base)
    return pat


def _expected_s2m():
    """Slave→master per-lane skew (master-RX expectation). Falls back to
    the m2s pattern if S_LANE<n> isn't set, mirroring the Makefile/RTL
    default."""
    m2s = _expected_m2s()
    pat = []
    for n in range(8):
        v = os.environ.get(f"SKID_S_LANE{n}", "")
        pat.append(int(v) if v.strip() else m2s[n])
    return pat


@cocotb.test()
async def test_pair_align_asymmetric_master_slave(dut):
    exp_m2s = _expected_m2s()
    exp_s2m = _expected_s2m()
    dut._log.info("=" * 70)
    dut._log.info("  test_pair_align_asymmetric_master_slave")
    dut._log.info(f"    master->slave pattern = {exp_m2s}")
    dut._log.info(f"    slave->master pattern = {exp_s2m}")
    dut._log.info("=" * 70)

    # Sanity: confirm tb_top has both patterns wired.
    try:
        obs_m2s = [int(getattr(dut, f"SKID_BITS_LANE{n}_EXPOSED").value) for n in range(8)]
        obs_s2m = [int(getattr(dut, f"SKID_BITS_S_LANE{n}_EXPOSED").value) for n in range(8)]
        dut._log.info(f"  tb_top m2s mirror = {obs_m2s}")
        dut._log.info(f"  tb_top s2m mirror = {obs_s2m}")
        assert obs_m2s == exp_m2s, f"tb_top m2s {obs_m2s} != expected {exp_m2s}"
        assert obs_s2m == exp_s2m, f"tb_top s2m {obs_s2m} != expected {exp_s2m}"
    except AttributeError:
        dut._log.warning("  exposed mirrors not visible — env-only check")

    await setup(dut)
    _set_training_mode(dut, "m", True)
    _set_training_mode(dut, "s", True)
    _set_all_slip(dut, "m", 0)
    _set_all_slip(dut, "s", 0)

    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 500)

    # Per-lane sweep: slave-RX calibrates the master→slave path; master-RX
    # calibrates the slave→master path. These are independent patterns.
    slave_slip  = [None] * 8   # observed on master→slave (slave RX)
    master_slip = [None] * 8   # observed on slave→master (master RX)
    for lane in range(8):
        slave_slip[lane]  = await _calibrate_lane(dut, "s", lane)
        master_slip[lane] = await _calibrate_lane(dut, "m", lane)
        dut._log.info(
            f"  lane {lane}: m->s exp={exp_m2s[lane]} got={slave_slip[lane]}  "
            f"s->m exp={exp_s2m[lane]} got={master_slip[lane]}")

    failures = []
    for lane in range(8):
        if slave_slip[lane] != exp_m2s[lane]:
            failures.append(f"  m->s lane {lane}: got {slave_slip[lane]} expected {exp_m2s[lane]}")
        if master_slip[lane] != exp_s2m[lane]:
            failures.append(f"  s->m lane {lane}: got {master_slip[lane]} expected {exp_s2m[lane]}")
    assert _read_lane_locked(dut, "s") == 0xFF, (
        f"Not all slave lanes locked: 0x{_read_lane_locked(dut,'s'):02x}")
    assert _read_lane_locked(dut, "m") == 0xFF, (
        f"Not all master lanes locked: 0x{_read_lane_locked(dut,'m'):02x}")
    assert not failures, "Per-direction calibration mismatched:\n" + "\n".join(failures)

    # Exit training, run real bring-up.
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

    await snapshot(dut, "m", "asym-ms")
    await snapshot(dut, "s", "asym-ms")

    # -- Concise summary ----------------------------------------------------
    dut._log.info("-" * 70)
    dut._log.info("  SUMMARY[asymmetric_master_slave]")
    dut._log.info(f"    skid pattern m->s = {exp_m2s}")
    dut._log.info(f"    skid pattern s->m = {exp_s2m}")
    dut._log.info(f"    calibrated  m->s  = {slave_slip}")
    dut._log.info(f"    calibrated  s->m  = {master_slip}")
    dut._log.info(f"    final FCSM master={max_m} slave={max_s}")
    dut._log.info(f"    cr_pkt_seen master={cr_m} slave={cr_s}")
    passed = (max_m >= 4 and max_s >= 4 and cr_m and cr_s and not failures)
    dut._log.info(f"    RESULT: {'PASS' if passed else 'FAIL'}")
    dut._log.info("-" * 70)

    assert max_m >= 4, f"master FCSM did not advance: state_max={max_m}"
    assert max_s >= 4, f"slave FCSM did not advance: state_max={max_s}"
    assert cr_m, "master cr_pkt_seen_rx never asserted"
    assert cr_s, "slave cr_pkt_seen_rx never asserted"
