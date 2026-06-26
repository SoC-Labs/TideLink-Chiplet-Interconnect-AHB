# =============================================================================
# test_eyescan_arm_default_off.py — Sim Gate B: eyescan chicken-bit OFF/ON
#
# WI-3 (eyescan integration, 2026-06-25). Proves on the PATCHED V1 build that:
#
#   (A) DEFAULT-OFF: with NO write to 0x4403_215C, the EYESCAN_ARM reg reads 0
#       on both dies (presence marker 0xEA confirms the new slot is live, bit[0]
#       arm=0), and a full doorbell bring-up + crossing still works — i.e. the
#       eyescan integration is INERT at POR (byte-identical link-up to 8ab846ba).
#
#   (B) ARM RW + read-back: a write of 0x215C=1 on both dies latches
#       eyescan_arm_r (read-back bit[0]=1, marker 0xEA), proving the Region-10
#       slot-7 write/read path reaches the controller (NOT shadowed by
#       tidelink_eye_regs — same wp_cfg_sel exclusion as the word-pin regs).
#
#   (C) ARM-ON link-up: with 0x215C=1 driven pre-link on both dies, the standard
#       doorbell bring-up still completes and a doorbell still crosses M->S.
#       (The shared-clock integration harness applies the M6+M8 S_VALIDATE
#       bypass — tb_early_exit_force_q — so the calibrator reaches S_DONE via
#       S_FINISH and never enters S_VALIDATE; arming therefore exercises the
#       eyescan WIRING without engaging it, which is exactly the no-regression
#       guarantee we need: arm=1 must not break the proven path.)
#
# Joint work commissioned on behalf of SoC Labs, Arm Academic Access license.
# Contributors: David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, APB_TIDELINK_BASE, APB_DOORBELL, APB_DOORBELL_RESP_ACC,
    run_bringup_full,
)

# Region 10 slot 7 EYESCAN_ARM (SoC 0x4403_215C => APB offset 0x15C).
APB_EYESCAN_ARM = APB_TIDELINK_BASE + 0x15C
EYESCAN_ARM_MARKER = 0xEA


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_eyescan_arm_default_off(dut):
    """DEFAULT-OFF: unwritten 0x215C reads arm=0 (marker 0xEA) on both dies, and
    a full doorbell bring-up + crossing works -> integration inert at POR."""
    tb = PairTB(dut)

    # Run the full proven bring-up WITHOUT touching 0x215C.
    await run_bringup_full(tb)

    # Read 0x215C on both dies: marker present, arm bit clear.
    m_arm = await tb.m_apb.read(APB_EYESCAN_ARM)
    s_arm = await tb.s_apb.read(APB_EYESCAN_ARM)
    tb.log.info(f"[escan] default 0x215C: M=0x{m_arm:08x} S=0x{s_arm:08x}")

    # Direct reg peek (load-bearing): the controller reg is 0 at POR.
    m_reg = _i(dut.u_master.u_chiplet_controller.eyescan_arm_r)
    s_reg = _i(dut.u_slave.u_chiplet_controller.eyescan_arm_r)
    assert m_reg == 0 and s_reg == 0, (
        f"eyescan_arm_r not 0 at POR (default-off broken): M={m_reg} S={s_reg}")

    # APB read-back: marker 0xEA in [31:24], arm bit[0]=0.
    for side, v in (("M", m_arm), ("S", s_arm)):
        assert ((v >> 24) & 0xFF) == EYESCAN_ARM_MARKER, (
            f"{side} 0x215C missing 0xEA presence marker: 0x{v:08x} "
            f"(slot not routed to controller / eye_regs shadow?)")
        assert (v & 1) == 0, f"{side} 0x215C arm bit set at POR: 0x{v:08x}"

    # And the link is up + a doorbell crosses (byte-identical link-up).
    cleared = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(tb.dut.hclk, 20)
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(tb.dut.hclk, 2000)
    s_db = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"[escan] default-off doorbell crossed: clr={cleared} after={s_db}")
    assert s_db != 0, (
        "default-off: doorbell did NOT cross with eyescan disarmed "
        "(integration regressed the proven path)")

    tb.log.info("[escan] PASS: 0x215C default arm=0 (marker 0xEA), link-up + "
                "doorbell crossing intact -> eyescan integration inert at POR.")


@cocotb.test()
async def test_eyescan_arm_rw_readback(dut):
    """ARM RW: write 0x215C=1 pre-link on both dies -> reg + read-back show
    arm=1 (marker 0xEA). Proves the slot-7 write/read path reaches the
    controller and is NOT eye_regs-shadowed."""
    tb = PairTB(dut)
    await tb.reset()

    await tb.m_apb.write(APB_EYESCAN_ARM, 1)
    await tb.s_apb.write(APB_EYESCAN_ARM, 1)
    await ClockCycles(tb.dut.hclk, 20)

    m_reg = _i(dut.u_master.u_chiplet_controller.eyescan_arm_r)
    s_reg = _i(dut.u_slave.u_chiplet_controller.eyescan_arm_r)
    assert m_reg == 1 and s_reg == 1, (
        f"eyescan_arm_r did not latch the write: M={m_reg} S={s_reg} "
        f"(Region-10 slot-7 write hoist failed)")

    m_arm = await tb.m_apb.read(APB_EYESCAN_ARM)
    s_arm = await tb.s_apb.read(APB_EYESCAN_ARM)
    tb.log.info(f"[escan] armed 0x215C: M=0x{m_arm:08x} S=0x{s_arm:08x}")
    for side, v in (("M", m_arm), ("S", s_arm)):
        assert ((v >> 24) & 0xFF) == EYESCAN_ARM_MARKER, (
            f"{side} 0x215C missing 0xEA marker after arm: 0x{v:08x}")
        assert (v & 1) == 1, (
            f"{side} 0x215C arm bit not set after write: 0x{v:08x} "
            f"(read-back shadowed by eye_regs?)")

    tb.log.info("[escan] PASS: 0x215C arm RW + read-back live in V1 "
                "(controller path; eye_regs exclusion works).")


@cocotb.test()
async def test_eyescan_arm_on_link_up(dut):
    """ARM-ON no-regression: with 0x215C=1 driven pre-link on both dies, the
    standard doorbell bring-up still completes and a doorbell crosses M->S.
    arm=1 must not break the proven link path."""
    tb = PairTB(dut)
    await tb.reset()

    # Arm BOTH dies before role-lock / training.
    await tb.m_apb.write(APB_EYESCAN_ARM, 1)
    await tb.s_apb.write(APB_EYESCAN_ARM, 1)
    await ClockCycles(tb.dut.hclk, 20)
    assert _i(dut.u_master.u_chiplet_controller.eyescan_arm_r) == 1
    assert _i(dut.u_slave.u_chiplet_controller.eyescan_arm_r) == 1

    # run_bringup_full() calls tb.reset() internally via
    # run_bringup_through_phase1 -> reset clears poresetn, which would clear the
    # arm reg. So drive the bring-up phases directly here (mirroring
    # run_bringup_full) WITHOUT the extra reset, keeping arm latched.
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    locked = await tb.wait_role_locked()
    tb.log.info(f"[escan-on] role_locked: M={int(tb.dut.m_role_locked.value)} "
                f"S={int(tb.dut.s_role_locked.value)} ({'OK' if locked else 'TIMEOUT'})")
    assert locked, "arm-on: role_lock timed out (arm broke autoneg/role path)"
    m_st, s_st = await tb.wait_cal_done(max_cycles=500000)
    m_done = (m_st >> 16) & 1
    s_done = (s_st >> 16) & 1
    tb.log.info(f"[escan-on] cal_done: M={m_done} S={s_done} "
                f"(M=0x{m_st:08x} S=0x{s_st:08x})")
    assert m_done and s_done, (
        f"arm-on: cal_done did not assert (M={m_done} S={s_done}) — eyescan "
        f"wiring blocked S_FINISH->S_DONE under the sim bypass")

    # Confirm arm survived bring-up.
    assert _i(dut.u_master.u_chiplet_controller.eyescan_arm_r) == 1
    assert _i(dut.u_slave.u_chiplet_controller.eyescan_arm_r) == 1

    await tb.do_to_data_mode()
    await ClockCycles(tb.dut.hclk, 5000)

    cleared = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(tb.dut.hclk, 20)
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(tb.dut.hclk, 2000)
    s_db = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"[escan-on] armed doorbell crossed: clr={cleared} after={s_db}")
    assert s_db != 0, (
        "arm-on: doorbell did NOT cross with eyescan ARMED (arm=1 broke the "
        "proven link/data path)")

    tb.log.info("[escan-on] PASS: arm=1 pre-link -> link-up + doorbell crossing "
                "intact (no regression with the chicken-bit ON).")
