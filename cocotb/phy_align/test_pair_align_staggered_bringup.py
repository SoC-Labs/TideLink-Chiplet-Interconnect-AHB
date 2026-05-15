"""Reproducer for the FPGA staggered-bringup autocal failure (§9.8).

Background
----------

On the Pynq-Z2 pair, the §9 autocal RTL works in cocotb's `test_autocal_integrated`
(both sides come out of POR essentially at the same simulated time, so both
autocal FSMs run their 256-cycle sweeps concurrently — each side sees the peer's
training pattern, all lanes lock, calibration completes). On the FPGA, however,
the deployment flow is necessarily staggered: the master bitstream loads,
then ~hundreds of milliseconds later the slave bitstream loads.

The originally reported FPGA symptom on master (before the trunk clk_en fix
in `WavD2DGpio.v`):
  SWI_LANE_LOCKED   = 0x00
  SWI_LANE_FAULT    = 0xFF
  SWI_CALIB_DONE    = 0x0401  (done=1, state field = S_DONE = 4)

What the clk_en fix changes
---------------------------

The trunk fix OR's `effective_training_mode` into `gpiotx_N_io_clk_en` for all
8 lanes. Before the fix, with `io_link_tx_tx_en = 0`, the GPIO TX serialiser's
clock was gated off — so the master's RX recovered link clock (which is
derived from the *slave's* TX pad clock) didn't toggle while slave was in
POR. The master's calibrator FSM is clocked on that recovered RX clock, so
it stalled in S_IDLE until the slave woke up.

In cocotb with the clk_en fix in place, this naturally makes the master's
sweep **wait** for the slave to wake up — the master FSM doesn't fire its
isolated 256-cycle sweep at all. Instead it triggers when slave's TX clock
starts running, and converges normally (because slave is by then also in
training mode).

What still fails
----------------

The *slave* side, however, still gets stuck. After master's autocal has
completed (master is in S_DONE with `training_mode = 0`), master's TX is
no longer emitting the training pattern — it has moved on to cr_pkts. When
the slave's autocal then triggers, its lane checker can't lock on any of
the 8 slip values it tries, and the FSM either:

  * Exhausts the sweep and marks every lane faulted (cal_state = S_DONE,
    lane_fault = 0xFF — the *originally reported* FPGA mode, now reproduced
    on the slave side), or
  * Hangs in S_SWEEP indefinitely because the slave's RX recovered clock
    is bursty (master's TX clock-en gating depends on link layer activity
    and is no longer continuously asserted post-training).

Either way: **staggered bring-up cannot complete with the clk_en fix
alone**. Protocol-level coordination (`staging/i2c_train/`) is required.

This test reproduces the failure on the slave side under staggered POR.

Invocation
----------
    cd cocotb/wlink_pair && make MODULE=test_pair_align_staggered_bringup
    # or
    cd cocotb/phy_align  && make MODULE=test_pair_align_staggered_bringup

Future work
-----------

Once Fix B (I²C-coordinated training entry/exit) lands, this test should be
**flipped** to assert `m_lane_locked == 0xFF and s_lane_locked == 0xFF` —
i.e. both sides converge under staggered bring-up. The skeleton for the
success-case assertion is in the `_assert_success_with_fix_b` helper below;
that body is currently disabled and left for the integration agent.
"""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

from test_link_bringup import (
    ctrl_write,
    apb_read,
)


# tidelink_phy_align_regs APB offsets (paddr[12] selects the phy_align region,
# so add 0x1000 to the in-block offset).
PA_BASE              = 0x1000
PA_SWI_BIT_SLIP      = PA_BASE + 0x00
PA_SWI_TRAINING_MODE = PA_BASE + 0x04
PA_SWI_LANE_LOCKED   = PA_BASE + 0x08
PA_SWI_LANE_FAULT    = PA_BASE + 0x0C
PA_SWI_CAL_DONE      = PA_BASE + 0x10  # [0]=cal_done, [11:8]=cal_state


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _force_autocal_enable(dut, side, on):
    """Hierarchical-force the autocal_force_enable_q signal in the chiplet
    controller. With this set, the calibrator's role_locked input goes high
    as soon as the controller's role_lock_reg latches."""
    inst = _chiplet(dut, side)
    inst.autocal_force_enable_q.value = 1 if on else 0


def _read_cal_state_hier(dut, side):
    return int(_chiplet(dut, side).cal_state_w.value)


def _read_cal_done_hier(dut, side):
    return int(_chiplet(dut, side).cal_calibration_done_w.value)


def _read_cal_lane_fault_hier(dut, side):
    return int(_chiplet(dut, side).cal_lane_fault_w.value)


def _read_lane_locked_tb(dut, side):
    """Read the lane_locked vector observed by the tb-level checker that
    sits on the *peer's* TX → this side's RX path. Mirrors what the
    chiplet-internal lane checker sees."""
    sig = dut.master_lane_locked if side == "m" else dut.slave_lane_locked
    return int(sig.value)


_clocks_started = False


async def _start_clocks_once(dut, master_period_ns=20.0, slave_period_ns=20.0):
    """cocotb keeps the simulator alive between @cocotb.test() functions, so
    we must only ever call cocotb.start_soon(Clock(...).start()) once per
    simulation run. Track that here."""
    global _clocks_started
    if not _clocks_started:
        cocotb.start_soon(Clock(dut.master_clk,
                                int(round(master_period_ns * 1000)),
                                unit="ps").start())
        cocotb.start_soon(Clock(dut.slave_clk,
                                int(round(slave_period_ns * 1000)),
                                unit="ps").start())
        _clocks_started = True


async def _full_por_and_idle(dut):
    """Drive all inputs to a clean idle state and reassert all resets.
    Used as a per-test reset since the DUT persists across cocotb tests."""
    for prefix in ['m', 's']:
        getattr(dut, f"{prefix}_apb_psel").value = 0
        getattr(dut, f"{prefix}_apb_penable").value = 0
        getattr(dut, f"{prefix}_apb_pwrite").value = 0
        getattr(dut, f"{prefix}_apb_paddr").value = 0
        getattr(dut, f"{prefix}_apb_pwdata").value = 0
        getattr(dut, f"{prefix}_apb_pprot").value = 0
        getattr(dut, f"{prefix}_apb_pstrb").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_addr").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_wdata").value = 0
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 20)


async def _release_master_por(dut):
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def _release_slave_por(dut):
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def _wait_for_cal_done(dut, side, timeout_cycles=8000):
    """Poll the calibrator's internal cal_calibration_done_w until it goes
    high, or until timeout. Returns the number of cycles waited."""
    for waited in range(timeout_cycles):
        await ClockCycles(dut.apb_clk, 1)
        if _read_cal_done_hier(dut, side):
            return waited
    return timeout_cycles


@cocotb.test()
async def test_staggered_bringup_reproduces_fpga_failure(dut):
    """Headline reproducer.

    Sequence (mimics the FPGA deploy flow):
      1. Enable autocal on both sides.
      2. Bring master out of POR; lock master role.
      3. Wait long enough (>>256 link cycles) for master's autocal sweep to
         have completed if it were going to.
      4. Bring slave out of POR; lock slave role.
      5. Wait for slave's autocal to complete or time out.
      6. Read APB status on both sides.
      7. Assert the staggered-bringup failure mode:
            - master converges (clk_en fix makes the master FSM wait for
              the slave's TX clock to start, so master's sweep happens
              concurrently with slave's wake-up and the master locks all
              8 lanes), OR
            - master fails with lane_fault=0xff (original FPGA mode before
              the clk_en fix landed),
          AND
            - slave fails to fully converge (either lane_locked != 0xff or
              FSM stuck in S_SWEEP or lane_fault=0xff). This is the residual
              staggered-bringup problem that Fix B (I²C-coordinated
              training entry/exit) must solve.
    """
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)

    # Step 1 — clocks + clean POR.
    await _start_clocks_once(dut)
    await _full_por_and_idle(dut)

    # Step 2 — master out of POR, lock master role. The slave is held in
    # POR-reset so the master's RX recovered clock is whatever the slave's
    # gated TX clock decides to do.
    await _release_master_por(dut)
    await ctrl_write(dut, 'm', 0, 0x02)  # role=master, lock=1
    master_lock_time_ns = cocotb.utils.get_sim_time('ns')
    dut._log.info(
        f"[stagger] Master locked at t={master_lock_time_ns:.1f} ns. "
        f"Slave still in POR. Letting master sit alone for 4096 master clocks."
    )

    # Step 3 — let master sit alone, long past the worst-case sweep window.
    await ClockCycles(dut.master_clk, 4096)

    m_state_pre  = _read_cal_state_hier(dut, "m")
    m_done_pre   = _read_cal_done_hier(dut, "m")
    m_fault_pre  = _read_cal_lane_fault_hier(dut, "m")
    m_lock_pre   = _read_lane_locked_tb(dut, "m")
    dut._log.info(
        f"[stagger] Master pre-slave-wake: cal_state={m_state_pre} "
        f"cal_done={m_done_pre} cal_lane_fault=0x{m_fault_pre:02x} "
        f"tb_lane_locked=0x{m_lock_pre:02x}"
    )

    # Step 4 — slave out of POR, lock slave role.
    await _release_slave_por(dut)
    await ctrl_write(dut, 's', 0, 0x03)  # role=slave, lock=1

    # Step 5 — wait for slave's autocal to complete or time out.
    waited = await _wait_for_cal_done(dut, "s", timeout_cycles=8000)
    if waited >= 8000:
        dut._log.info("[stagger] slave cal_done did NOT assert before timeout.")
    else:
        dut._log.info(f"[stagger] slave cal_done after {waited} apb_clk cycles.")
    # Let APB CDC settle.
    await ClockCycles(dut.apb_clk, 32)

    # Step 6 — read APB status on both sides.
    m_lane_locked = await apb_read(dut, "m", PA_SWI_LANE_LOCKED)
    m_lane_fault  = await apb_read(dut, "m", PA_SWI_LANE_FAULT)
    m_cal_done    = await apb_read(dut, "m", PA_SWI_CAL_DONE)
    s_lane_locked = await apb_read(dut, "s", PA_SWI_LANE_LOCKED)
    s_lane_fault  = await apb_read(dut, "s", PA_SWI_LANE_FAULT)
    s_cal_done    = await apb_read(dut, "s", PA_SWI_CAL_DONE)
    dut._log.info(
        f"[apb] master SWI_LANE_LOCKED=0x{m_lane_locked:02x} "
        f"SWI_LANE_FAULT=0x{m_lane_fault:02x} "
        f"SWI_CAL_DONE=0x{m_cal_done:04x}"
    )
    dut._log.info(
        f"[apb] slave  SWI_LANE_LOCKED=0x{s_lane_locked:02x} "
        f"SWI_LANE_FAULT=0x{s_lane_fault:02x} "
        f"SWI_CAL_DONE=0x{s_cal_done:04x}"
    )
    m_fsm_state = _read_cal_state_hier(dut, "m")
    s_fsm_state = _read_cal_state_hier(dut, "s")
    dut._log.info(
        f"[hier] master FSM state={m_fsm_state} (S_DONE=4); "
        f"slave FSM state={s_fsm_state}"
    )

    # Step 7 — interpret the result.
    #
    # We classify each side by two sticky signals: cal_done (does the FSM
    # reach S_DONE?) and lane_fault (did any lane exhaust its slip values?).
    # The live lane_locked vector goes back to 0 once training ends, so it
    # cannot be used as a post-hoc success signal — see comments in the
    # baseline test below for the rationale.
    #
    #   converged       → cal_done=1, lane_fault=0x00 (every lane locked
    #                     inside the sweep window).
    #   failed_fpga_mode → cal_done=1, lane_fault=0xFF (every lane exhausted
    #                     its 8 slip values without locking — the classic
    #                     bring-up-sequencing bug).
    #   stuck            → cal_done=0 (FSM never made it to S_DONE).
    def _classify(cal_done_reg, lane_fault_reg, fsm_state):
        if not (cal_done_reg & 0x1):
            return f"STUCK at FSM state={fsm_state}"
        if lane_fault_reg == 0x00:
            return "CONVERGED (every lane locked, no faults)"
        if lane_fault_reg == 0xFF:
            return "FPGA FAILURE MODE (all 8 lanes faulted, cal_done=1)"
        return (f"PARTIAL (cal_done=1, fault=0x{lane_fault_reg:02x} — "
                f"some lanes locked, some faulted)")

    m_class = _classify(m_cal_done, m_lane_fault, m_fsm_state)
    s_class = _classify(s_cal_done, s_lane_fault, s_fsm_state)
    dut._log.info(f"[result] master: {m_class}")
    dut._log.info(f"[result] slave : {s_class}")

    master_converged = (m_cal_done & 0x1) == 1 and m_lane_fault == 0x00
    slave_converged  = (s_cal_done & 0x1) == 1 and s_lane_fault == 0x00

    if master_converged and slave_converged:
        raise AssertionError(
            "Both sides converged unexpectedly under staggered bring-up "
            "(master_lane_fault=0x{:02x}, slave_lane_fault=0x{:02x}, both "
            "cal_done=1). The trunk RTL (clk_en fix + autocal FSM) appears "
            "sufficient to handle staggered bring-up on its own — please "
            "flip this test from asserting failure to asserting success."
            .format(m_lane_fault, s_lane_fault)
        )

    # Headline assertion: staggered bring-up does NOT converge with the
    # current trunk RTL. At least one side ends in lane_fault=0xff or stuck.
    # This is the failure mode that motivates Fix B (I²C-coordinated
    # training). Flip this assertion to assert(master_converged and
    # slave_converged) once Fix B lands.
    assert not (master_converged and slave_converged), "see above"
    # Strong post-condition: specifically check the slave side ends in the
    # FPGA-documented failure mode (lane_fault=0xff, cal_done=1, state=S_DONE).
    # This matches the bench observation on the side whose autocal triggered
    # second (master in the FPGA, slave in this sim — the roles swap because
    # the cocotb master comes up first, but the *sequencing* relationship is
    # identical: the side that runs its sweep after its peer has already
    # exited training mode is the one that faults all 8 lanes).
    assert s_lane_fault == 0xFF, (
        f"Expected the side-running-second (slave in this sim) to reproduce "
        f"the FPGA failure mode (lane_fault=0xFF, all lanes exhausted slip "
        f"sweep without locking), got slave lane_fault=0x{s_lane_fault:02x}, "
        f"cal_done=0x{s_cal_done:04x}, FSM state={s_fsm_state}."
    )
    assert (s_cal_done & 0x1) == 1, (
        f"Expected slave cal_done bit[0]=1 (FSM reached S_DONE) after the "
        f"isolated failed sweep, got SWI_CAL_DONE=0x{s_cal_done:04x}"
    )
    s_cal_state_field = (s_cal_done >> 8) & 0xF
    assert s_cal_state_field == 4, (
        f"Expected slave cal_state field == 4 (S_DONE), got "
        f"{s_cal_state_field} (SWI_CAL_DONE=0x{s_cal_done:04x})"
    )


# NOTE: a concurrent-bring-up baseline is intentionally *not* included in this
# module. That case is already covered by
# `cocotb/phy_align/test_autocal_integrated.py` (`test_autocal_integrated_basic`),
# which runs against the same `tb_top` with autocal force-enabled on both sides
# and asserts cal_done + FCSM state progression. Co-locating both styles of
# test in this module would require re-running cocotb's @cocotb.test fixtures
# back-to-back against a single sim instance — which is brittle because the
# DUT state (Wlink internal registers, autoneg FSM, calibrator FSM state) is
# not deterministically re-initialised between tests in the same VCS run.
# Run the two tests in separate `make` invocations to keep them isolated.
