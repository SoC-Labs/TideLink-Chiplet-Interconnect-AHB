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
  4. Read Region 8 SWI_LANE_STATUS via the ctrl_reg interface (the interim
     0x4403_1000 shim was deleted; regs moved to MMIO 0x4403_2108) and
     confirm calibration_done (bit[16]) = 1.
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
    ctrl_read,
    snapshot,
)


# §9 registers moved out of the interim Wlink-domain shim (deleted) into
# Region 8 of the TideLink config APB, accessed via the chiplet-controller
# ctrl_reg interface. ctrl_reg_addr[3]=1 selects Region 8; bits[2:0] are
# the slot. RDL: 0x100 SWI_TRAINING_MODE (slot0), 0x104 SWI_BIT_SLIP_LO
# (slot1), 0x108 SWI_LANE_STATUS (slot2) = [7:0] lane_locked, [15:8]
# lane_fault, [16] calibration_done.
R8_SWI_TRAINING_MODE = 0b1000  # ctrl_reg_addr {1, 3'h0}
R8_SWI_BIT_SLIP_LO   = 0b1001  # ctrl_reg_addr {1, 3'h1}
R8_SWI_LANE_STATUS   = 0b1010  # ctrl_reg_addr {1, 3'h2}


def _chiplet_path(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _force_autocal_enable(dut, side, on):
    inst = _chiplet_path(dut, side)
    inst.autocal_force_enable_q.value = 1 if on else 0


def _force_early_exit(dut, side, on):
    """§9.9 compat: force the calibrator into legacy first-match-wins mode
    via the hierarchical hook tb_early_exit_force_q. Silicon ships with
    EARLY_EXIT_ON_ALL_LOCKED=0 (best-of-sweep), which requires the full
    128-point sweep to complete before lanes are latched — much longer
    than the timing the existing autocal sim tests were authored for.
    Tests that rely on the §9.7 first-match wall-time call this BEFORE
    role_locked rises.
    """
    inst = _chiplet_path(dut, side)
    inst.u_calibrator.tb_early_exit_force_q.value = 1 if on else 0


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
    #    Also engage the §9.9 first-match-wins compat mode so this test's
    #    4000-cycle cal_done timeout still applies (the silicon-default
    #    best-of-sweep mode walks all 128 dwell windows).
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)
    _force_early_exit(dut, "m", True)
    _force_early_exit(dut, "s", True)

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

    # 5. Read back Region 8 SWI_LANE_STATUS via the ctrl_reg interface to
    #    confirm the calibrator → CDC → Region 8 path is wired up. The
    #    apb_clk-domain 2-flop sync adds a couple of cycles; wait first.
    #    SWI_LANE_STATUS[16] = calibration_done.
    await ClockCycles(dut.apb_clk, 16)
    lane_status_m = await ctrl_read(dut, "m", R8_SWI_LANE_STATUS)
    cal_done_bit = (lane_status_m >> 16) & 0x1
    dut._log.info(
        f"ctrl_reg master R8 SWI_LANE_STATUS = 0x{lane_status_m:08x} "
        f"(lane_locked=0x{lane_status_m & 0xFF:02x}, "
        f"lane_fault=0x{(lane_status_m >> 8) & 0xFF:02x}, "
        f"cal_done={cal_done_bit})"
    )
    assert cal_done_bit == 0x1, (
        f"Region 8 SWI_LANE_STATUS read 0x{lane_status_m:08x}, "
        f"expected calibration_done bit[16]=1"
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
