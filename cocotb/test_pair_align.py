"""BRINGUP_REPORT.md §9 bit-slip alignment test for the wlink_pair sandbox.

This test exercises the new per-lane bit-slip + training-pattern mechanism in
WavD2DGpio:

  1. Bring both sides through POR and role-lock.
  2. Drive `swi_training_mode = 1` on both u_master / u_slave by hierarchical
     reference (WavD2DGpio.swi_training_mode). Master TX emits the per-lane
     training byte (lane N -> (N+1) * 0x11), so master TX -> slave RX, and
     similarly slave TX -> master RX, both transmit known patterns.
  3. Sweep `swi_bit_slip` per lane 0..7. For each candidate value, run a few
     hundred recovered-clock cycles and read `lane_locked[N]` on both sides.
     The first slip value that locks a lane is recorded as that lane's
     calibrated slip.
  4. Apply the calibrated slip; assert all 8 lanes lock on both sides.
  5. Drive `swi_training_mode = 0` and toggle swreset, then run the normal
     bring-up flow (lock_master / lock_slave) and confirm FCSM advances to
     state >= 4 and cr_pkt_seen_rx asserts on both sides.

Invocation:
    make MODULE=test_pair_align SKID_BITS=3
    make MODULE=test_pair_align SKID_BITS=1
    ...

The Makefile forwards SKID_BITS into tb_top via +define+TB_TOP_SKID_BITS.
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles, Timer

from test_link_bringup import setup, lock_master, lock_slave, snapshot


def _skid_bits():
    try:
        return int(os.environ.get("SKID_BITS", "0"))
    except ValueError:
        return 0


def _gpio_path(dut, side):
    """Return the WavD2DGpio handle for the given side ('m' or 's')."""
    inst = dut.u_master if side == "m" else dut.u_slave
    return inst.u_wlink.phy.gpio


def _set_lane_slip(dut, side, lane, slip):
    """Read-modify-write a single lane's 3-bit slip into swi_bit_slip[3*lane+2 : 3*lane]."""
    gpio = _gpio_path(dut, side)
    cur = int(gpio.swi_bit_slip.value)
    mask = 0x7 << (3 * lane)
    new = (cur & ~mask) | ((slip & 0x7) << (3 * lane))
    gpio.swi_bit_slip.value = new


def _set_all_slip(dut, side, slip_value):
    """Set every lane to the same slip value."""
    gpio = _gpio_path(dut, side)
    packed = 0
    for lane in range(8):
        packed |= (slip_value & 0x7) << (3 * lane)
    gpio.swi_bit_slip.value = packed


def _set_training_mode(dut, side, on):
    _gpio_path(dut, side).swi_training_mode.value = 1 if on else 0


def _read_lane_locked(dut, side):
    sig = dut.master_lane_locked if side == "m" else dut.slave_lane_locked
    return int(sig.value)


async def _toggle_swreset(dut, cycles=200):
    """Re-apply POR + role-lock so the deserialiser pipelines flush after a
    change in training mode."""
    # Drop role-lock + POR.
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
    await ClockCycles(dut.master_clk, cycles)
    dut.m_poresetn.value = 1
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 50)


async def _calibrate_lane(dut, side, lane, settle_cycles=400):
    """Sweep slip 0..7 for the given lane; return the first slip that locks."""
    for slip in range(8):
        _set_lane_slip(dut, side, lane, slip)
        await ClockCycles(dut.master_clk, settle_cycles)
        locked = _read_lane_locked(dut, side)
        if (locked >> lane) & 1:
            return slip
    return None


@cocotb.test()
async def test_pair_align(dut):
    skid = _skid_bits()
    dut._log.info("=" * 70)
    dut._log.info(f"  test_pair_align: SKID_BITS = {skid}")
    dut._log.info("=" * 70)

    # Verify tb_top picked up the same SKID_BITS we expect.
    try:
        tb_skid = int(dut.SKID_BITS_EXPOSED.value)
        assert tb_skid == skid, f"Makefile SKID_BITS={skid} but tb_top reports {tb_skid}"
    except AttributeError:
        dut._log.warning("  SKID_BITS_EXPOSED not visible; relying on env var only")

    # --- Phase A: bring up clocks + POR with training mode pre-armed --------
    await setup(dut)

    # Enable training pattern emission on both sides BEFORE we lock roles, so
    # the very first cycles after the link-clock comes alive carry the known
    # pattern (rather than ECC-protected cr_pkts that haven't been decoded
    # yet because we're still calibrating).
    _set_training_mode(dut, "m", True)
    _set_training_mode(dut, "s", True)
    _set_all_slip(dut, "m", 0)
    _set_all_slip(dut, "s", 0)

    # Role-lock to deassert wlink_por_reset and start the link-clock.
    await lock_master(dut)
    await lock_slave(dut)

    # Let the link-clock start and the deserialiser settle.
    await ClockCycles(dut.master_clk, 500)

    dut._log.info(f"  initial master_lane_locked = 0x{_read_lane_locked(dut,'m'):02x}")
    dut._log.info(f"  initial slave_lane_locked  = 0x{_read_lane_locked(dut,'s'):02x}")

    # --- Phase B: per-lane calibration --------------------------------------
    # The slave's RX is fed by master's TX (through u_skid_m2s). Calibrating
    # slave_lane_locked therefore calibrates the master-TX -> slave-RX path.
    # Likewise master_lane_locked calibrates slave-TX -> master-RX.
    slave_slip  = [None] * 8     # slave's per-lane slip for master->slave path
    master_slip = [None] * 8     # master's per-lane slip for slave->master path
    for lane in range(8):
        s = await _calibrate_lane(dut, "s", lane)
        m = await _calibrate_lane(dut, "m", lane)
        slave_slip[lane]  = s
        master_slip[lane] = m
        dut._log.info(f"  lane {lane}: m->s slip={s}  s->m slip={m}")

    dut._log.info(f"  Final master_lane_locked = 0x{_read_lane_locked(dut,'m'):02x}")
    dut._log.info(f"  Final slave_lane_locked  = 0x{_read_lane_locked(dut,'s'):02x}")

    assert all(s is not None for s in slave_slip), (
        f"slave-side calibration failed: per-lane slip = {slave_slip}"
    )
    assert all(m is not None for m in master_slip), (
        f"master-side calibration failed: per-lane slip = {master_slip}"
    )
    assert _read_lane_locked(dut, "s") == 0xFF, (
        f"Not all slave lanes locked: 0x{_read_lane_locked(dut,'s'):02x}"
    )
    assert _read_lane_locked(dut, "m") == 0xFF, (
        f"Not all master lanes locked: 0x{_read_lane_locked(dut,'m'):02x}"
    )

    # --- Phase C: exit training mode, re-init, run real bring-up ------------
    _set_training_mode(dut, "m", False)
    _set_training_mode(dut, "s", False)
    # Keep the calibrated slip values latched — they persist across the
    # swreset because swi_bit_slip is a sim-only soft strap, not gated by POR.
    await _toggle_swreset(dut)

    # Restore role-lock + ctrl_reg state for the live bring-up phase.
    await lock_master(dut)
    await lock_slave(dut)

    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    m_cr      = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx
    s_cr      = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx

    max_m = 0
    max_s = 0
    cr_m_seen = False
    cr_s_seen = False
    for _ in range(5000):
        await ClockCycles(dut.master_clk, 1)
        try:
            max_m = max(max_m, int(m_state_h.value))
            max_s = max(max_s, int(s_state_h.value))
            if int(m_cr.value): cr_m_seen = True
            if int(s_cr.value): cr_s_seen = True
        except ValueError:
            pass
        if cr_m_seen and cr_s_seen and max_m >= 4 and max_s >= 4:
            break

    await snapshot(dut, "m", "after-calib")
    await snapshot(dut, "s", "after-calib")

    dut._log.info(f"  POST-CALIB: master state_max={max_m} cr_seen={cr_m_seen}")
    dut._log.info(f"  POST-CALIB: slave  state_max={max_s} cr_seen={cr_s_seen}")
    dut._log.info(f"  POST-CALIB: applied slave_slip={slave_slip} master_slip={master_slip}")

    assert max_m >= 4, f"master FCSM did not advance past state={max_m}"
    assert max_s >= 4, f"slave FCSM did not advance past state={max_s}"
    assert cr_m_seen, "master cr_pkt_seen_rx never asserted after calibration"
    assert cr_s_seen, "slave cr_pkt_seen_rx never asserted after calibration"
    dut._log.info(
        f"  RESULT: SKID_BITS={skid} brought up successfully after calibration"
    )
