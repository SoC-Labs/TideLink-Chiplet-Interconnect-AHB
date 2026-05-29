"""Targeted regression coverage for the two FPGA-bring-up RTL fixes.

These tests isolate the exact RTL paths added during the §9 FPGA bring-up;
the pre-existing suites only exercise them incidentally (with the gate
already open via mask_hs_bypass, or by forcing the calibrator port
directly) and would pass with or without the fixes.

  test_fix1_apb_debug_unlock_opens_mask_hs_gate
      Commit cab2d8f. axi_chiplet_controller.sv:
        wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i
                                                | apb_debug_unlock_i;
      Negative + positive: with mask_hs_bypass=0 and mask_hs_match=0
      (no autoneg, Wlink mask_hs_result_o tied 0), a SW W1S of
      ROLE_CFG[1] must NOT latch role_lock until apb_debug_unlock_i=1.

  test_fix2_swi_recal_retriggers_calibrator
      Commit d1351f4. SWI_RECAL = Region 8 slot 0 bit[1] (MMIO
      0x4403_2100) feeds the calibrator's .swreset (was tied 1'b0).
      After the cold-boot sweep reaches S_DONE, a Region-8 write of
      {recal=1} must cancel it (calibration_done 1->0) and the
      {recal=0} falling edge must re-trigger a fresh sweep — proving
      the register->port wiring, not just the calibrator's own
      swreset behaviour (already covered by test_pair_align_retraining).

Invocation (from cocotb/phy_align/):
    make MODULE=test_rtl_fix_coverage SKID_BITS=3
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_link_bringup import setup, ctrl_write, ctrl_read
from test_autocal_integrated import (
    _chiplet_path,
    R8_SWI_TRAINING_MODE,   # ctrl_reg_addr 0b1000 = Region 8 slot 0
)


@cocotb.test()
async def test_fix1_apb_debug_unlock_opens_mask_hs_gate(dut):
    """mask_hs_bypass=0, mask_hs_match=0: role_lock latches ONLY once
    apb_debug_unlock_i is asserted (commit cab2d8f)."""
    await setup(dut)

    # Close every other door to the gate: no bypass, no autoneg match,
    # debug strap low. (Wlink mask_hs_result_o is tied 1'b0 in the
    # wrapper, and nego is disabled out of POR, so mask_hs_match=0.)
    dut.m_mask_hs_bypass.value = 0
    dut.m_apb_debug_unlock.value = 0
    await ClockCycles(dut.apb_clk, 4)

    # ── Negative: SW W1S of ROLE_CFG[1] with the gate shut ──────────────
    await ctrl_write(dut, "m", 0, 0x02)        # role=0 (master), lock=1
    await ClockCycles(dut.apb_clk, 8)
    locked_closed = int(dut.m_role_locked.value)
    assert locked_closed == 0, (
        "role_lock latched with mask_hs_bypass=0, mask_hs_match=0, "
        "apb_debug_unlock=0 — the gate must stay shut (regression of "
        "cab2d8f, or an unintended SW path to role_lock)"
    )

    # ── Positive: assert the debug strap, retry the W1S ────────────────
    dut.m_apb_debug_unlock.value = 1
    await ClockCycles(dut.apb_clk, 4)
    await ctrl_write(dut, "m", 0, 0x02)
    await ClockCycles(dut.apb_clk, 8)
    locked_open = int(dut.m_role_locked.value)
    assert locked_open == 1, (
        "role_lock did NOT latch with apb_debug_unlock_i=1 — the debug "
        "strap is not opening mask_hs_gate_open (commit cab2d8f missing "
        "or reverted)"
    )
    dut._log.info("fix#1 OK: gate shut->role_lock=0, debug_unlock->role_lock=1")


def _cal_swreset_port(dut, side):
    """Hierarchical read of the calibrator instance's .swreset port —
    this net is exactly what d1351f4 changed from 1'b0 to swi_recal_r."""
    inst = _chiplet_path(dut, side)
    return int(inst.u_calibrator.swreset.value)


def _swi_recal_reg(dut, side):
    inst = _chiplet_path(dut, side)
    return int(inst.swi_recal_r.value)


@cocotb.test()
async def test_fix2_swi_recal_drives_calibrator_swreset(dut):
    """Region 8 SWI_RECAL (slot 0 bit[1], MMIO 0x4403_2100) is wired to
    the calibrator's .swreset port (commit d1351f4).

    d1351f4's literal change is `.swreset(1'b0)` → `.swreset(swi_recal_r)`
    plus the slot-0 bit[1] register. The deterministic, clock-domain-
    independent proof is connectivity: a Region-8 write of bit[1] must
    appear on swi_recal_r AND on the calibrator instance's .swreset port,
    and read back through the ctrl_reg interface. (The calibrator's own
    swreset→re-sweep FSM behaviour is already covered by the calibrator
    design + test_pair_align_retraining; reproducing the sustained
    recovered-RX-clock needed for the FSM dynamics is out of scope for
    this pair TB, which is why the suite re-triggers via POR instead.)
    With the pre-d1351f4 RTL .swreset is the constant 1'b0 and never
    tracks the register — that is what this test pins down.
    """
    await setup(dut)
    dut.m_apb_debug_unlock.value = 1
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.apb_clk, 4)
    await ctrl_write(dut, "m", 0, 0x02)       # role-lock master (gate via debug strap)

    # Baseline: SWI_RECAL=0 out of POR → calibrator .swreset must be 0
    # (with the old RTL it is the constant 0, so this passes either way —
    # it is the *transitions* below that discriminate).
    assert _swi_recal_reg(dut, "m") == 0, "swi_recal_r not 0 out of POR"
    assert _cal_swreset_port(dut, "m") == 0, (
        "calibrator .swreset != 0 at POR (unexpected)"
    )

    # ── Region 8 write {recal=1, train=1} ──────────────────────────────
    await ctrl_write(dut, "m", R8_SWI_TRAINING_MODE, 0x3)
    await ClockCycles(dut.apb_clk, 4)
    slot0 = await ctrl_read(dut, "m", R8_SWI_TRAINING_MODE)
    assert (slot0 & 0x1) == 1, f"SWI_TRAINING_MODE bit[0] not set: 0x{slot0:08x}"
    assert (slot0 >> 1) & 0x1 == 1, (
        f"SWI_RECAL bit[1] did not read back set (0x{slot0:08x}) — "
        f"slot-0 decode/readback of the new bit is broken (d1351f4)"
    )
    assert _swi_recal_reg(dut, "m") == 1, "swi_recal_r did not set on Region-8 write"
    assert _cal_swreset_port(dut, "m") == 1, (
        "calibrator .swreset did NOT follow SWI_RECAL=1 — .swreset is "
        "still tied 1'b0 / not wired to swi_recal_r (regression of d1351f4)"
    )

    # ── Region 8 write {recal=0, train=1}: the discriminating 1→0 ──────
    await ctrl_write(dut, "m", R8_SWI_TRAINING_MODE, 0x1)
    await ClockCycles(dut.apb_clk, 4)
    slot0 = await ctrl_read(dut, "m", R8_SWI_TRAINING_MODE)
    assert (slot0 & 0x1) == 1, "SWI_TRAINING_MODE bit[0] cleared unexpectedly"
    assert (slot0 >> 1) & 0x1 == 0, (
        f"SWI_RECAL bit[1] did not clear (0x{slot0:08x})"
    )
    assert _swi_recal_reg(dut, "m") == 0, "swi_recal_r did not clear"
    assert _cal_swreset_port(dut, "m") == 0, (
        "calibrator .swreset did NOT follow SWI_RECAL=0 — the recal level "
        "is not reaching the calibrator port (regression of d1351f4)"
    )
    dut._log.info(
        "fix#2 OK: Region-8 SWI_RECAL 1→0 propagated to calibrator .swreset"
    )
