"""§9 partial-failure test — one un-calibratable lane.

Goal
----
Verify the §9 RTL behaves gracefully when a single lane cannot be locked at
any slip value (e.g. a broken trace, EMC-induced bit corruption, missing
solder ball). The expectations are:

  - The calibration sweep over lane 4 returns None (no slip in 0..7 locks).
  - `lane_locked[4]` stays 0 throughout the sweep.
  - Other lanes (0..3, 5..7) still calibrate correctly.
  - FCSM never advances past state 1 because the link-layer ECC cannot
    decode cr_pkts on the broken lane → cr_pkt_seen_rx never asserts.

This is the partial-failure observability story for the §9 calibration
algorithm: even if one lane is dead, we should be able to *see* which lane
is dead (via the per-lane `lane_locked` checker output) and from that
diagnose the problem rather than just seeing "FCSM stuck at 1".

Stimulus
--------
The Makefile exposes STUCK_LANES_MASK; we set it to 0x10 (= 1 << 4) so the
m2s pad_skid forces lane 4's serial line to constant 0. With the lane-4
training byte 0x65, the 16-bit deserialised word will be 0x0000 at every
slip — no match, so lane_locked[4] never asserts.

Invocation
----------
    make MODULE=test_pair_align_partial_failure STUCK_LANES_MASK=16
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, snapshot
from test_pair_align import (
    _gpio_path, _set_all_slip, _set_training_mode,
    _read_lane_locked, _calibrate_lane,
)


FAILING_LANE = 4   # matches STUCK_LANES_MASK=16 (= 1 << 4)


@cocotb.test()
async def test_pair_align_partial_failure(dut):
    dut._log.info("=" * 70)
    dut._log.info(f"  test_pair_align_partial_failure: FAILING_LANE = {FAILING_LANE}")
    dut._log.info("=" * 70)

    # Sanity: confirm tb_top really stuck the right lane.
    try:
        stuck = int(dut.STUCK_LANES_MASK.value)
        dut._log.info(f"  tb_top.STUCK_LANES_MASK = 0x{stuck:02x}")
        assert (stuck >> FAILING_LANE) & 1, (
            f"STUCK_LANES_MASK=0x{stuck:02x} doesn't mark lane {FAILING_LANE} stuck. "
            f"Did you set STUCK_LANES_MASK={1<<FAILING_LANE} on the make line?"
        )
    except AttributeError:
        dut._log.warning("  STUCK_LANES_MASK not visible on tb_top — recompile needed")

    await setup(dut)

    _set_training_mode(dut, "m", True)
    _set_training_mode(dut, "s", True)
    _set_all_slip(dut, "m", 0)
    _set_all_slip(dut, "s", 0)

    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 500)

    # Per-lane calibration. The slave RX is fed by master TX (through the
    # m2s pad_skid which is the one with the stuck lane). The lane-4
    # calibration on the slave side must return None.
    slave_slip  = [None] * 8
    master_slip = [None] * 8
    for lane in range(8):
        s = await _calibrate_lane(dut, "s", lane)
        m = await _calibrate_lane(dut, "m", lane)
        slave_slip[lane]  = s
        master_slip[lane] = m
        dut._log.info(f"  lane {lane}: m->s slip={s} s->m slip={m}")

    dut._log.info(f"  Final master_lane_locked = 0x{_read_lane_locked(dut,'m'):02x}")
    dut._log.info(f"  Final slave_lane_locked  = 0x{_read_lane_locked(dut,'s'):02x}")

    # The stuck lane must NOT have locked on the slave side (m2s direction).
    locked_s = _read_lane_locked(dut, "s")
    assert (locked_s >> FAILING_LANE) & 1 == 0, (
        f"slave_lane_locked[{FAILING_LANE}]=1 but lane is stuck-at-zero — "
        f"checker is incorrectly reporting lock"
    )
    assert slave_slip[FAILING_LANE] is None, (
        f"calibration unexpectedly recovered slip "
        f"{slave_slip[FAILING_LANE]} for stuck lane {FAILING_LANE}"
    )
    # All OTHER lanes should have locked on both sides.
    for lane in range(8):
        if lane == FAILING_LANE:
            continue
        assert slave_slip[lane] is not None, (
            f"slave-side lane {lane} should have calibrated (only lane "
            f"{FAILING_LANE} is stuck)")
        assert master_slip[lane] is not None, (
            f"master-side lane {lane} should have calibrated")

    # Now leave training mode and observe FCSM behaviour. With lane 4 stuck,
    # the link-layer ECC will see corrupted data → cr_pkt_seen_rx never
    # asserts → FCSM stays at SEND_CREDITS1 (state == 1).
    _set_training_mode(dut, "m", False)
    _set_training_mode(dut, "s", False)
    # Apply the calibrated (non-None) slips for the lanes that did lock.
    # Use the per-lane setter; leave lane 4 at 0 since it doesn't matter.
    from test_pair_align import _set_lane_slip
    for lane in range(8):
        if slave_slip[lane]  is not None:
            _set_lane_slip(dut, "s", lane, slave_slip[lane])
        if master_slip[lane] is not None:
            _set_lane_slip(dut, "m", lane, master_slip[lane])

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

    await snapshot(dut, "m", "partial-fail")
    await snapshot(dut, "s", "partial-fail")

    # -- Concise summary ----------------------------------------------------
    dut._log.info("-" * 70)
    dut._log.info("  SUMMARY[partial_failure]")
    dut._log.info(f"    failing lane             = {FAILING_LANE}")
    dut._log.info(f"    slave-side per-lane slip = {slave_slip}")
    dut._log.info(f"    master-side per-lane slip = {master_slip}")
    dut._log.info(f"    final lane_locked m=0x{_read_lane_locked(dut,'m'):02x}"
                  f" s=0x{_read_lane_locked(dut,'s'):02x}")
    dut._log.info(f"    final FCSM master={max_m} slave={max_s}")
    dut._log.info(f"    cr_pkt_seen master={cr_m} slave={cr_s}")
    # FCSM expected to stay at <=1; cr_pkt_seen expected to remain False on
    # at least the side whose RX depends on the stuck direction (slave).
    fcsm_ok = (max_s <= 1)
    cr_ok   = (not cr_s)
    passed = (slave_slip[FAILING_LANE] is None and fcsm_ok and cr_ok)
    dut._log.info(f"    RESULT: {'PASS' if passed else 'FAIL'} — "
                  f"stuck lane {FAILING_LANE} surfaced, slave FCSM stuck at "
                  f"state {max_s}, cr_seen={cr_s}")
    dut._log.info("-" * 70)

    assert fcsm_ok, (
        f"slave FCSM advanced past state 1 ({max_s}) despite a stuck lane — "
        f"the link-layer should have rejected corrupted cr_pkts")
    assert cr_ok, "slave cr_pkt_seen_rx asserted despite a stuck lane"
