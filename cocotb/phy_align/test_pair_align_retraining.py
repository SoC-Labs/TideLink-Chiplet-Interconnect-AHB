"""§9.4 re-training after a transient.

Goal
----
The §9.4 spec claim is: once the link is up, we can re-enter calibration on
the fly (e.g. after a transient bit error count threshold trip) and the
algorithm will re-converge without rebooting the chiplet.

This test:
  1. Calibrates with all-lanes skid=3, achieves FCSM>=4 and cr_pkt_seen.
  2. Lets cr_pkts run for ~100 cycles.
  3. Asserts swi_training_mode=1 again (backdoor) — link layer falls back.
  4. Sweeps calibration again. Confirms the same slips re-converge.
  5. Exits training, verifies the link comes back up to FCSM>=4 with
     cr_pkt_seen_rx on both sides.

Invocation
----------
    make MODULE=test_pair_align_retraining SKID_BITS=3
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, snapshot
from test_pair_align import (
    _gpio_path, _set_all_slip, _set_training_mode,
    _read_lane_locked, _toggle_swreset, _calibrate_lane, _skid_bits,
)


async def _bring_up_to_state4(dut, label, max_cycles=5000):
    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_cr      = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_cr      = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    max_m = 0; max_s = 0; cr_m = False; cr_s = False
    for _ in range(max_cycles):
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
    dut._log.info(f"  [{label}] master state_max={max_m} cr_seen={cr_m}")
    dut._log.info(f"  [{label}] slave  state_max={max_s} cr_seen={cr_s}")
    return max_m, max_s, cr_m, cr_s


@cocotb.test()
async def test_pair_align_retraining(dut):
    skid = _skid_bits()
    dut._log.info("=" * 70)
    dut._log.info(f"  test_pair_align_retraining: SKID_BITS = {skid}")
    dut._log.info("=" * 70)

    await setup(dut)
    _set_training_mode(dut, "m", True)
    _set_training_mode(dut, "s", True)
    _set_all_slip(dut, "m", 0)
    _set_all_slip(dut, "s", 0)

    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 500)

    # --- Initial per-lane calibration ---
    slave_slip_1  = [None] * 8
    master_slip_1 = [None] * 8
    for lane in range(8):
        slave_slip_1[lane]  = await _calibrate_lane(dut, "s", lane)
        master_slip_1[lane] = await _calibrate_lane(dut, "m", lane)
    dut._log.info(f"  INITIAL slave_slip ={slave_slip_1}")
    dut._log.info(f"  INITIAL master_slip={master_slip_1}")
    assert all(s is not None for s in slave_slip_1),  f"initial slave calibration failed: {slave_slip_1}"
    assert all(m is not None for m in master_slip_1), f"initial master calibration failed: {master_slip_1}"

    # --- Exit training, run real bring-up ---
    _set_training_mode(dut, "m", False)
    _set_training_mode(dut, "s", False)
    await _toggle_swreset(dut)
    await lock_master(dut)
    await lock_slave(dut)

    max_m_1, max_s_1, cr_m_1, cr_s_1 = await _bring_up_to_state4(dut, "initial bring-up")
    assert max_m_1 >= 4 and max_s_1 >= 4 and cr_m_1 and cr_s_1, (
        f"initial bring-up failed: m={max_m_1} s={max_s_1} cr_m={cr_m_1} cr_s={cr_s_1}"
    )

    # --- Let cr_pkts run for another ~100 cycles ---
    await ClockCycles(dut.master_clk, 100)

    # --- Re-enter training mode (§9.4: on-the-fly re-calibration) ---
    dut._log.info("  >>> Re-asserting swi_training_mode for re-calibration <<<")
    _set_training_mode(dut, "m", True)
    _set_training_mode(dut, "s", True)
    # Clear slips so we genuinely re-sweep.
    _set_all_slip(dut, "m", 0)
    _set_all_slip(dut, "s", 0)
    await ClockCycles(dut.master_clk, 200)

    # --- Sweep calibration again ---
    slave_slip_2  = [None] * 8
    master_slip_2 = [None] * 8
    for lane in range(8):
        slave_slip_2[lane]  = await _calibrate_lane(dut, "s", lane)
        master_slip_2[lane] = await _calibrate_lane(dut, "m", lane)
    dut._log.info(f"  RECAL   slave_slip ={slave_slip_2}")
    dut._log.info(f"  RECAL   master_slip={master_slip_2}")
    # The same skew is in place, so calibration should give the same answer.
    assert slave_slip_2  == slave_slip_1, (
        f"re-calibration on slave drifted from {slave_slip_1} to {slave_slip_2}")
    assert master_slip_2 == master_slip_1, (
        f"re-calibration on master drifted from {master_slip_1} to {master_slip_2}")

    # --- Exit training again, link should come back up ---
    _set_training_mode(dut, "m", False)
    _set_training_mode(dut, "s", False)
    await _toggle_swreset(dut)
    await lock_master(dut)
    await lock_slave(dut)

    max_m_2, max_s_2, cr_m_2, cr_s_2 = await _bring_up_to_state4(dut, "after re-train")

    await snapshot(dut, "m", "after-retrain")
    await snapshot(dut, "s", "after-retrain")

    # -- Concise summary ----------------------------------------------------
    dut._log.info("-" * 70)
    dut._log.info("  SUMMARY[retraining]")
    dut._log.info(f"    skid pattern              = uniform skid={skid}")
    dut._log.info(f"    initial slip (m->s, s->m) = {slave_slip_1}, {master_slip_1}")
    dut._log.info(f"    re-cal  slip (m->s, s->m) = {slave_slip_2}, {master_slip_2}")
    dut._log.info(f"    initial FCSM m={max_m_1} s={max_s_1} cr_m={cr_m_1} cr_s={cr_s_1}")
    dut._log.info(f"    final   FCSM m={max_m_2} s={max_s_2} cr_m={cr_m_2} cr_s={cr_s_2}")
    passed = (max_m_2 >= 4 and max_s_2 >= 4 and cr_m_2 and cr_s_2 and
              slave_slip_1 == slave_slip_2 and master_slip_1 == master_slip_2)
    dut._log.info(f"    RESULT: {'PASS' if passed else 'FAIL'}")
    dut._log.info("-" * 70)

    assert max_m_2 >= 4, f"master FCSM did not re-advance: state_max={max_m_2}"
    assert max_s_2 >= 4, f"slave FCSM did not re-advance: state_max={max_s_2}"
    assert cr_m_2, "master cr_pkt_seen_rx did not re-assert after re-training"
    assert cr_s_2, "slave cr_pkt_seen_rx did not re-assert after re-training"
