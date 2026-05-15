"""End-to-end integration test for the §9.6 in-RTL auto-cal FSM.

Validates that with the new tidelink_phy_align_calibrator instantiated inside
each side of the wlink_pair sandbox, role-lock alone is enough to drive the
per-lane bit-slip sweep to completion. Specifically:

  1. Set SKID_BITS=3 (uniform per-lane skid) on the m2s / s2m pad_skid paths.
  2. Bring both sides through POR and role-lock — no SW slip sweep, no
     hierarchical writes to swi_bit_slip/swi_training_mode.
  3. The calibrator (gated on by a hierarchical-force on the
     `autocal_force_enable_q` cocotb hook in each chiplet controller) drives
     the sweep autonomously: ~256 link-clock cycles, then asserts
     calibration_done on both sides.
  4. Read the autocal status reg via APB at the new offset 0x4403_1010
     (master side) and confirm cal_done=1.
  5. Run the existing bring-up flow (drop training, lock master/slave) and
     confirm FCSM reaches state>=4 on both sides.

Invocation (from cocotb/phy_align/):
    make MODULE=test_autocal_integrated SKID_BITS=3
"""
import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles, Timer

from test_link_bringup import (
    setup,
    lock_master,
    lock_slave,
    apb_read,
    snapshot,
)


# tidelink_phy_align_regs APB offsets (paddr[12] mux gates region: 0x1000+)
PA_BASE              = 0x1000
PA_SWI_BIT_SLIP      = PA_BASE + 0x00
PA_SWI_TRAINING_MODE = PA_BASE + 0x04
PA_SWI_LANE_LOCKED   = PA_BASE + 0x08
PA_SWI_LANE_FAULT    = PA_BASE + 0x0C
PA_SWI_CAL_DONE      = PA_BASE + 0x10  # [0]=cal_done, [11:8]=cal_state


def _chiplet_path(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _force_autocal_enable(dut, side, on):
    inst = _chiplet_path(dut, side)
    inst.autocal_force_enable_q.value = 1 if on else 0


def _read_lane_locked_tb(dut, side):
    sig = dut.master_lane_locked if side == "m" else dut.slave_lane_locked
    return int(sig.value)


def _read_cal_done_hier(dut, side):
    """Backdoor read of cal_calibration_done_w via hierarchical reference.

    The APB CDC takes a couple of apb_clk cycles; for the assertion check we
    just read the raw FSM output (which lives at the calibrator's `state`).
    """
    inst = _chiplet_path(dut, side)
    return int(inst.cal_calibration_done_w.value)


def _read_cal_state(dut, side):
    inst = _chiplet_path(dut, side)
    return int(inst.cal_state_w.value)


def _read_cal_lane_fault(dut, side):
    inst = _chiplet_path(dut, side)
    return int(inst.cal_lane_fault_w.value)


def _read_cal_bit_slip(dut, side):
    inst = _chiplet_path(dut, side)
    return int(inst.cal_bit_slip_w.value)


@cocotb.test()
async def test_autocal_integrated_basic(dut):
    """Role-lock → autocal sweep → calibration_done → FCSM reaches state>=4."""
    # 1. Enable the calibrator on both sides BEFORE coming out of POR.
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)

    # 2. Boot both sides.
    await setup(dut)

    # 3. Lock both roles → role_locked rises → calibrator triggers.
    await lock_master(dut)
    await lock_slave(dut)

    # 4. Wait for calibration_done on both sides. Worst case the FSM needs
    #    8 slip × 32 dwell cycles ≈ 256 link clocks. The link clock is the
    #    recovered RX clock which runs at the TX clock rate (~50 MHz in this
    #    sim) — so 256 cycles is ~5.1 µs. Wait up to 2000 apb_clk cycles to
    #    be safe (apb_clk == master_clk here).
    timeout_cycles = 4000
    cal_done_m = 0
    cal_done_s = 0
    for _ in range(timeout_cycles):
        await ClockCycles(dut.apb_clk, 1)
        cal_done_m = _read_cal_done_hier(dut, "m")
        cal_done_s = _read_cal_done_hier(dut, "s")
        if cal_done_m and cal_done_s:
            break

    # Diagnostics on assertion failure.
    state_m = _read_cal_state(dut, "m")
    state_s = _read_cal_state(dut, "s")
    slip_m = _read_cal_bit_slip(dut, "m")
    slip_s = _read_cal_bit_slip(dut, "s")
    fault_m = _read_cal_lane_fault(dut, "m")
    fault_s = _read_cal_lane_fault(dut, "s")
    lock_m = _read_lane_locked_tb(dut, "m")
    lock_s = _read_lane_locked_tb(dut, "s")
    dut._log.info(
        f"After {timeout_cycles} cycles: cal_done m={cal_done_m} s={cal_done_s} "
        f"state m={state_m} s={state_s} bit_slip m=0x{slip_m:06x} s=0x{slip_s:06x} "
        f"fault m=0x{fault_m:02x} s=0x{fault_s:02x} "
        f"lane_locked m=0x{lock_m:02x} s=0x{lock_s:02x}"
    )
    assert cal_done_m == 1, (
        f"master calibration_done did not assert after {timeout_cycles} cycles "
        f"(state={state_m}, slip=0x{slip_m:06x}, fault=0x{fault_m:02x}, "
        f"lane_locked=0x{lock_m:02x})"
    )
    assert cal_done_s == 1, (
        f"slave calibration_done did not assert after {timeout_cycles} cycles "
        f"(state={state_s}, slip=0x{slip_s:06x}, fault=0x{fault_s:02x}, "
        f"lane_locked=0x{lock_s:02x})"
    )

    # 5. Read back the new APB RO reg to confirm the APB path is wired up.
    #    The CDC adds a couple of cycles; wait a bit more before the read.
    await ClockCycles(dut.apb_clk, 16)
    cal_done_apb_m = await apb_read(dut, "m", PA_SWI_CAL_DONE)
    dut._log.info(f"APB master PA_SWI_CAL_DONE = 0x{cal_done_apb_m:08x}")
    assert (cal_done_apb_m & 0x1) == 0x1, (
        f"APB read of cal_done returned 0x{cal_done_apb_m:08x}, expected bit[0]=1"
    )

    # 6. Confirm FCSM advances. cr_pkts can only flow after the calibrator
    #    drops training_mode (which it does in S_DONE), so by now the FCSM
    #    should have started progressing. Poll the TideLk FCSM state.
    m_state_h = dut.u_master.u_wlink.tl2wl.wlink_tidelinktl.state
    s_state_h = dut.u_slave.u_wlink.tl2wl.wlink_tidelinktl.state
    max_state_m = 0
    max_state_s = 0
    for _ in range(200):
        await ClockCycles(dut.master_clk, 50)
        max_state_m = max(max_state_m, int(m_state_h.value))
        max_state_s = max(max_state_s, int(s_state_h.value))
        if max_state_m >= 4 and max_state_s >= 4:
            break
    await snapshot(dut, "m", "after autocal")
    await snapshot(dut, "s", "after autocal")
    dut._log.info(f"FCSM max state master={max_state_m} slave={max_state_s}")
    assert max_state_m >= 4, (
        f"FCSM master did not reach LINK_DATA (max_state={max_state_m})"
    )
    assert max_state_s >= 4, (
        f"FCSM slave did not reach LINK_DATA (max_state={max_state_s})"
    )
