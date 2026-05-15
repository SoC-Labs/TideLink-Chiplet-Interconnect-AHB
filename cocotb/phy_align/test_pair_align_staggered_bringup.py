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
    ctrl_read,
)


# §9 registers moved out of the deleted interim Wlink-domain shim
# (0x4403_1000) into Region 8 of the TideLink config APB, read via the
# chiplet-controller ctrl_reg interface. ctrl_reg_addr[3]=1 selects
# Region 8. SWI_LANE_STATUS (slot 2) packs everything:
#   [7:0] lane_locked, [15:8] lane_fault, [16] calibration_done.
R8_SWI_LANE_STATUS   = 0b1010  # ctrl_reg_addr {1, 3'h2}, MMIO 0x4403_2108


async def _read_lane_status(dut, side):
    """Return (lane_locked, lane_fault, cal_done) from Region 8."""
    v = await ctrl_read(dut, side, R8_SWI_LANE_STATUS)
    return (v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0x1)


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
    """Staggered-bringup convergence test (§9.8).

    NOTE — §9 INTEGRATION: this test remains a *reproducer* of the FPGA
    staggered-bringup autocal failure, with the status read path
    corrected to Region 8 (the interim 0x4403_1000 shim was deleted; the
    old apb_read of that shim returned garbage that falsely masked the
    slave fault). With the correct read, the failure STILL reproduces:
    the second-running side faults all 8 lanes. The assertion is NOT
    flipped to success — the I²C-coordinated training path that would fix
    staggered bring-up is gated by SHORTCOMINGS-14a (see the TODO at the
    assertion site). The function name is retained for CI continuity.

    Sequence (mimics the FPGA deploy flow):
      1. Enable autocal on both sides.
      2. Bring master out of POR; lock master role.
      3. Wait long enough (>>256 link cycles) for master's autocal sweep to
         have completed if it were going to.
      4. Bring slave out of POR; lock slave role.
      5. Wait for slave's autocal to complete or time out.
      6. Read Region 8 SWI_LANE_STATUS on both sides.
      7. Assert the staggered-bringup FAILURE mode (slave faults 8 lanes):
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

    # Step 6 — read Region 8 SWI_LANE_STATUS on both sides (via ctrl_reg;
    # the interim 0x1000 shim was deleted in the §9 integration). cal_done
    # is bit[16] of SWI_LANE_STATUS; m_cal_done/s_cal_done below keep the
    # bit[0]=cal_done convention the classifier expects.
    m_lane_locked, m_lane_fault, m_cd = await _read_lane_status(dut, "m")
    s_lane_locked, s_lane_fault, s_cd = await _read_lane_status(dut, "s")
    m_cal_done = m_cd
    s_cal_done = s_cd
    dut._log.info(
        f"[r8] master SWI_LANE_LOCKED=0x{m_lane_locked:02x} "
        f"SWI_LANE_FAULT=0x{m_lane_fault:02x} cal_done={m_cal_done}"
    )
    dut._log.info(
        f"[r8] slave  SWI_LANE_LOCKED=0x{s_lane_locked:02x} "
        f"SWI_LANE_FAULT=0x{s_lane_fault:02x} cal_done={s_cal_done}"
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

    # ==================================================================
    # §9 INTEGRATION — assertion KEPT as failure-mode reproducer, with
    # the read path corrected to Region 8 (the interim 0x4403_1000 shim
    # was deleted; the old apb_read of that shim returned garbage that
    # *masked* the slave fault and made the scenario look converged).
    #
    # With the correct Region 8 SWI_LANE_STATUS read, the staggered
    # scenario STILL reproduces the FPGA failure: the side whose autocal
    # sweep runs *after* its peer has exited training-mode (slave in this
    # sim) faults all 8 lanes (lane_fault=0xFF, cal_done=1, FSM=S_DONE)
    # while the first side (master) converges cleanly. Trunk's WavD2DGpio
    # clk_en fix + the in-RTL calibrator are NOT sufficient on their own
    # for staggered bring-up — the second side needs its peer to still be
    # emitting the training pattern when its sweep runs.
    #
    # TODO(SHORTCOMINGS-14a) — FLIP TO assert(master_converged and
    #   slave_converged) once the I²C-coordinated training path works
    #   end-to-end. That path (#4 ST_TRAIN_* autoneg FSM driving
    #   swi_training_mode through Region 8 + #5 mask_hs_bypass=0 + the
    #   physical I²C jumpers) is the mechanism that holds training_mode
    #   HIGH until BOTH sides lock, which fixes exactly this staggered
    #   case. It is currently blocked by the pre-existing autoneg I²C
    #   wedge SHORTCOMINGS-14a (master's I²C "claim" write succeeds but
    #   follow-on multi-byte transactions NACK/wedge). A parallel agent
    #   owns the 14a fix; the §9 ST_TRAIN_* FSM is structurally in place
    #   and wired (Step 4) but cannot be exercised end-to-end until 14a
    #   lands. The FPGA hardware bring-up blocker is NOT closed until
    #   then (on-board CURRENT_CREDITS must read ≠ 4096).
    # ==================================================================
    assert not (master_converged and slave_converged), (
        f"Unexpected: staggered bring-up converged on BOTH sides via the "
        f"corrected Region 8 read (master lf=0x{m_lane_fault:02x} "
        f"cd={m_cal_done}, slave lf=0x{s_lane_fault:02x} cd={s_cal_done}). "
        f"If this is real (not a read-path bug), the I²C-coordinated path "
        f"is no longer required for staggered bring-up — re-evaluate the "
        f"SHORTCOMINGS-14a TODO and flip to assert success."
    )
    # Strong post-condition: the second-running side (slave in this sim)
    # reproduces the FPGA failure mode exactly: all 8 lanes faulted,
    # cal_done=1, FSM at S_DONE.
    assert s_lane_fault == 0xFF, (
        f"Expected the side-running-second (slave) to reproduce the FPGA "
        f"failure mode (lane_fault=0xFF), got slave lane_fault="
        f"0x{s_lane_fault:02x}, cal_done={s_cal_done}, FSM={s_fsm_state}."
    )
    assert (s_cal_done & 0x1) == 1 and s_fsm_state == 4, (
        f"Expected slave cal_done=1 and FSM at S_DONE (4) after the "
        f"isolated failed sweep, got cal_done={s_cal_done}, "
        f"FSM={s_fsm_state}."
    )
    # And the first side (master) converges cleanly — confirms the
    # asymmetry is a sequencing effect, not a global RTL break.
    assert master_converged and m_fsm_state == 4, (
        f"Expected master (side-running-first) to converge cleanly "
        f"(lane_fault=0x00, cal_done=1, FSM=4), got lane_fault="
        f"0x{m_lane_fault:02x}, cal_done={m_cal_done}, FSM={m_fsm_state}."
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
