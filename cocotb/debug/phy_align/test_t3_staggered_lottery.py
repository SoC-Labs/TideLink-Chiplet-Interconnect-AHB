"""T3 per-deploy-lottery reproducer + negative control (staggered role_lock).

WHAT THIS PROVES
----------------

On real HW the two chiplets' `role_lock` assert ms apart (SSH-staggered
fpga_manager loads). Each side's autocal calibrator
(`tidelink_phy_align_calibrator.sv`) only emits the TX training pattern
while `training_mode=1`, and pre-fix `training_mode` was high *only* during
the local one-shot ~82 µs sweep (S_ARM/S_SWEEP, 128 phase×slip combos ×
DWELL_CYCLES=32 ≈ 4096 calibrator clocks). The slower side therefore swept
while its peer was NOT transmitting the training pattern → every lane
FAULTED → pre-fix S_FINISH unconditionally went to S_DONE with
`calibration_done=1` and `lane_fault=0xFF`, and *stayed there forever*. That
is the per-deploy lottery (HW-confirmed: 7/10 deploys dead).

THE FIX (commit b248148, this branch feat/td-calibrator-resweep)
----------------------------------------------------------------

`S_FINISH` now advances to `S_DONE` (→ calibration_done=1) ONLY if
`sweep_success` (zero faulted lanes) or `retry_exhausted`
(MAX_RESWEEPS cap; default 0 = never while role_locked). Otherwise, with
`role_locked` still high, it goes back to `S_ARM` and re-sweeps, holding
`training_mode` high across retries — so two skew-triggered nodes keep
re-sweeping + transmitting training until their windows coincide and both
lock.

WHY AN FSM-LEVEL DISCRIMINATOR + STUCK LANES (modelling limitation)
-------------------------------------------------------------------

Two modelling limitations of this `tb_top` shape the test:

  (a) The end-state "both lanes locked" is NOT representable under a real
      stagger. The first-running side waits for the peer TX clock,
      converges, reaches S_DONE and *drops* `training_mode`; its training
      pattern then permanently disappears (it moved on to cr_pkts) and the
      lane-checker model never lets the second side lock afterwards. So we
      assert the robust, model-independent FSM discriminator that *is*
      precisely the committed RTL change, not the "both lock" end-state.

  (b) A side whose peer is NOT in training_mode sees a *stalled* recovered
      RX clock (the GPIO TX serialiser clk_en is gated unless that peer is
      in training_mode or actively driving the link). With a plain
      staggered POR the second side's calibrator clock therefore freezes
      mid-S_SWEEP and never reaches S_FINISH — so the faulting-sweep path
      (the thing the fix changes) is never exercised at all, making any
      assertion vacuous (and the negative control toothless).

To make the faulting sweep DETERMINISTIC and clock-stable while keeping the
staggered role_lock that models the HW skew, this test pins ALL eight lanes
to 0 in BOTH directions (`STUCK_LANES_MASK=0xFF STUCK_LANES_MASK_S=0xFF`).
Neither side's lane checker can ever lock, so each side's calibrator runs a
full sweep and FAULTS all 8 lanes — and because each side stays in
`training_mode` while sweeping, `gpiotx_N_io_clk_en` (OR'd with
`effective_training_mode`) keeps BOTH TX clocks free-running, so both
calibrator clocks stay alive through the full sweep. This is the lottery's
essence — a side sweeps without ever getting a lockable peer pattern — made
reproducible without the clock-burst nondeterminism.

The discriminator, applied to BOTH sides (and especially the
later-locked slave, the lottery victim):

  After a sweep that FAULTS while `role_locked` is still high:
    * PRE-FIX  : calibrator latches `state==S_DONE(4)`,
                 `calibration_done==1`, `lane_fault==0xFF` and STAYS there;
                 `training_mode==0` (gives up — the per-deploy lottery).
    * POST-FIX : calibrator NEVER reaches S_DONE; it re-arms (`state`
                 returns to S_ARM/S_SWEEP), `calibration_done` stays 0,
                 `training_mode` stays 1 (keeps transmitting training so a
                 skew-staggered peer can still converge).

On feat/td-calibrator-resweep this PASSES; reverting only the calibrator
fix to its pre-fix parent (96c57d7) makes it FAIL (S_DONE + 0xFF latch).

Invocation
----------
    cd cocotb/phy_align && make MODULE=test_t3_staggered_lottery \
        STUCK_LANES_MASK=0xFF STUCK_LANES_MASK_S=0xFF
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from test_link_bringup import ctrl_write


# Calibrator FSM state encoding (see tidelink_phy_align_calibrator.sv).
S_IDLE, S_ARM, S_SWEEP, S_FINISH, S_DONE, S_CANCEL = 0, 1, 2, 3, 4, 5


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _force_autocal_enable(dut, side, on):
    """Hierarchical-force autocal_force_enable_q in the chiplet controller so
    the calibrator's role_locked input rises as soon as role_lock_reg latches
    (same hook the autocal_integrated / staggered tests use)."""
    _chiplet(dut, side).autocal_force_enable_q.value = 1 if on else 0


def _cal_state(dut, side):
    return int(_chiplet(dut, side).cal_state_w.value)


def _cal_done(dut, side):
    return int(_chiplet(dut, side).cal_calibration_done_w.value)


def _cal_lane_fault(dut, side):
    return int(_chiplet(dut, side).cal_lane_fault_w.value)


def _cal_training_mode(dut, side):
    return int(_chiplet(dut, side).cal_training_mode_w.value)


def _role_locked(dut, side):
    return int(getattr(dut, f"{side}_role_locked").value)


async def _por_idle(dut):
    """Drive a clean idle state and assert all resets (the DUT persists
    across cocotb tests in a single VCS run)."""
    for p in ("m", "s"):
        getattr(dut, f"{p}_apb_psel").value = 0
        getattr(dut, f"{p}_apb_penable").value = 0
        getattr(dut, f"{p}_apb_pwrite").value = 0
        getattr(dut, f"{p}_apb_paddr").value = 0
        getattr(dut, f"{p}_apb_pwdata").value = 0
        getattr(dut, f"{p}_apb_pprot").value = 0
        getattr(dut, f"{p}_apb_pstrb").value = 0
        getattr(dut, f"{p}_ctrl_reg_write").value = 0
        getattr(dut, f"{p}_ctrl_reg_addr").value = 0
        getattr(dut, f"{p}_ctrl_reg_wdata").value = 0
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 20)


# One full sweep is 128 (phase×slip) combos × DWELL_CYCLES(32) = 4096
# CALIBRATOR clocks. The calibrator clock is the recovered RX *link*
# clock, which WavD2DGpioRx derives as pad_clk / 16 (count[3] of a 4-bit
# pad-clk counter). With a 20 ns pad clock the link clock is 320 ns, so
# one full sweep ≈ 4096 × 320 ns ≈ 1.31 ms. In apb_clk (== 20 ns pad
# clock) cycles that is 4096 × 16 = 65536 cycles per sweep.
SWEEP_LINK_CLKS = 128 * 32          # 4096 calibrator (link) clocks
PAD_PER_LINK    = 16                # WavD2DGpioRx: io_link_clk = pad_clk/16
SWEEP_APB       = SWEEP_LINK_CLKS * PAD_PER_LINK   # 65536 apb cycles / sweep

# Deliberate role_lock stagger between the two sides, in master clocks —
# MUCH larger than one full sweep period (the sim analogue of the ms-scale
# HW role_lock skew). The master's calibrator clock is stalled during the
# stagger (the un-locked slave isn't transmitting), so this is cheap in
# sim time despite being >> one sweep of role_lock skew.
STAGGER_CLKS = 5 * SWEEP_LINK_CLKS  # ≈ 5 sweep periods of skew


@cocotb.test()
async def test_t3_staggered_lottery_resweep(dut):
    """Staggered role_lock + stuck lanes: prove the pre-fix lottery is gone.

    1. Autocal force-enabled on both sides; both out of POR together.
    2. Lock the MASTER role. The slave is still idle (no role_lock), so
       its TX clock is gated and the master's calibrator clock barely
       ticks — the master waits, exactly like a real first-up board whose
       peer hasn't loaded yet.
    3. Wait STAGGER_CLKS (>> one full sweep period) — a deliberate
       role_lock stagger, the sim analogue of the ms HW skew.
    4. Lock the SLAVE role. Both sides now enter training_mode, so both
       GPIO TX clocks free-run (clk_en | effective_training_mode), keeping
       both calibrator clocks alive. Because ALL eight lanes are pinned to
       0 in BOTH directions (STUCK_LANES_MASK / _S = 0xFF), neither lane
       checker can ever lock → every sweep FAULTS all 8 lanes. This is the
       lottery's essence (a side sweeps without ever getting a lockable
       peer pattern) made deterministic and clock-stable.
    5. Poll BOTH calibrators for several sweep periods and assert the
       FSM-level discriminator that IS the committed b248148 change:
         POST-FIX (this branch, PASS): neither side ever latches
           state==S_DONE / calibration_done==1; each re-arms after a
           faulting sweep and holds training_mode==1.
         PRE-FIX (negative control, FAIL): the side faults and latches
           state==S_DONE, calibration_done==1, lane_fault==0xFF, stays.
    """
    # 1. Enable the calibrator on both sides before POR release.
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)

    # Clocks (started once — this module has exactly one test).
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk, 20000, unit="ps").start())
    await _por_idle(dut)

    # 2. Both sides out of POR together; lock the MASTER role only.
    dut.m_poresetn.value = 1
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await ctrl_write(dut, "m", 0, 0x02)  # role=master, lock=1
    t_master_lock = cocotb.utils.get_sim_time("ns")
    dut._log.info(
        f"[T3] master role-locked at t={t_master_lock:.0f} ns; slave NOT "
        f"yet locked. Staggering slave role_lock by {STAGGER_CLKS} master "
        f"clocks (>> one {SWEEP_LINK_CLKS}-clk sweep)."
    )

    # 3. Large role_lock stagger — the sim analogue of the ms HW skew.
    await ClockCycles(dut.master_clk, STAGGER_CLKS)
    dut._log.info(
        f"[T3] pre-slave-lock: master state={_cal_state(dut,'m')} "
        f"done={_cal_done(dut,'m')} fault=0x{_cal_lane_fault(dut,'m'):02x} "
        f"train={_cal_training_mode(dut,'m')}"
    )

    # 4. Lock the SLAVE role — long after the master.
    await ctrl_write(dut, "s", 0, 0x03)  # role=slave, lock=1
    t_slave_lock = cocotb.utils.get_sim_time("ns")
    dut._log.info(
        f"[T3] slave role-locked at t={t_slave_lock:.0f} ns "
        f"(stagger = {t_slave_lock - t_master_lock:.0f} ns >> one sweep)."
    )

    # 5. Watch BOTH calibrators for several full faulting-sweep periods.
    #    The state-machine's S_FINISH/S_ARM live for only ~1 calibrator
    #    clock each and the recovered RX clock is slower than apb_clk, so
    #    instead of trying to catch those transient states we key off the
    #    robust STICKY signals that distinguish the two RTLs:
    #      - cal_done / state==S_DONE ever asserting (PRE-FIX latch), and
    #      - lane_fault returning to 0 after having been non-zero, which
    #        can ONLY happen via the S_ARM mass-clear on a re-sweep — i.e.
    #        positive proof the FIXED FSM re-armed instead of finishing.
    #    Both are immune to the apb_clk-vs-link-clk sampling rate.
    POLL = 5 * SWEEP_APB          # apb_clk cycles ≈ 5 full sweep periods
    PROGRESS = POLL // 12

    obs = {
        "m": dict(done_ever=0, sdone_fault_ever=False, fault_ever=False,
                  fault_then_clear=False, train_low_while_active=False,
                  prev_fault=0),
        "s": dict(done_ever=0, sdone_fault_ever=False, fault_ever=False,
                  fault_then_clear=False, train_low_while_active=False,
                  prev_fault=0),
    }
    prev_state = {"m": _cal_state(dut, "m"), "s": _cal_state(dut, "s")}

    for i in range(POLL):
        await ClockCycles(dut.apb_clk, 1)
        for sd in ("m", "s"):
            o = obs[sd]
            st = _cal_state(dut, sd)
            cd = _cal_done(dut, sd)
            lf = _cal_lane_fault(dut, sd)
            tm = _cal_training_mode(dut, sd)
            rl = _role_locked(dut, sd)

            if cd:
                o["done_ever"] = 1
            # PRE-FIX lottery signature: S_DONE reached with faulted lanes
            # while role_locked is still high (the fix makes this
            # unreachable under the stagger).
            if st == S_DONE and lf != 0 and rl == 1:
                o["sdone_fault_ever"] = True
            if lf != 0:
                o["fault_ever"] = True
            # FIX signature (sticky, sampling-robust): lane_fault was
            # non-zero and is now zero again. The ONLY datapath that clears
            # lane_fault_q is the S_ARM mass-clear — so this is positive
            # proof the FSM re-armed (S_FINISH→S_ARM) after a faulted
            # sweep instead of latching S_DONE.
            if o["prev_fault"] != 0 and lf == 0 and rl == 1:
                o["fault_then_clear"] = True
            # While actively arming/sweeping under role_lock the training
            # pattern MUST stay up so the skew-staggered peer can converge.
            if rl == 1 and st in (S_ARM, S_SWEEP) and tm == 0:
                o["train_low_while_active"] = True
            o["prev_fault"] = lf

            if st != prev_state[sd]:
                dut._log.info(
                    f"[T3 +{i:6d}] {sd} state {prev_state[sd]}->{st} "
                    f"done={cd} fault=0x{lf:02x} train={tm} rl={rl}"
                )
            prev_state[sd] = st
        if i % PROGRESS == 0:
            dut._log.info(
                f"[T3 +{i:6d}] m(state={_cal_state(dut,'m')} "
                f"done={_cal_done(dut,'m')} "
                f"fault=0x{_cal_lane_fault(dut,'m'):02x} "
                f"train={_cal_training_mode(dut,'m')}) "
                f"s(state={_cal_state(dut,'s')} "
                f"done={_cal_done(dut,'s')} "
                f"fault=0x{_cal_lane_fault(dut,'s'):02x} "
                f"train={_cal_training_mode(dut,'s')})"
            )

        # Early exit once the outcome is unambiguous, to bound sim time:
        #  - PRE-FIX: a faulted sweep latched S_DONE on either side — the
        #    lottery is reproduced, no need to keep polling (FAIL fast).
        #  - POST-FIX: both sides faulted and then RE-ARMED (lane_fault
        #    cleared back to 0) with cal_done still 0 — the fix is proven
        #    (continuous re-sweep), no need to keep polling (PASS fast).
        if obs["s"]["sdone_fault_ever"] or obs["m"]["sdone_fault_ever"]:
            dut._log.info(f"[T3 +{i}] PRE-FIX latch seen — stopping early.")
            break
        if (obs["s"]["fault_then_clear"] and obs["m"]["fault_then_clear"]
                and obs["s"]["done_ever"] == 0 and obs["m"]["done_ever"] == 0):
            dut._log.info(
                f"[T3 +{i}] both sides re-armed after a faulted sweep with "
                f"cal_done still 0 — fix proven, stopping early."
            )
            break

    for sd in ("m", "s"):
        o = obs[sd]
        dut._log.info(
            f"[T3] FINAL {sd}: state={_cal_state(dut,sd)} "
            f"done={_cal_done(dut,sd)} "
            f"fault=0x{_cal_lane_fault(dut,sd):02x} "
            f"train={_cal_training_mode(dut,sd)} "
            f"rl={_role_locked(dut,sd)} | observed done_ever={o['done_ever']} "
            f"sdone_fault_ever={o['sdone_fault_ever']} "
            f"fault_ever={o['fault_ever']} "
            f"fault_then_clear={o['fault_then_clear']} "
            f"train_low_while_active={o['train_low_while_active']}"
        )

    # The later-locked SLAVE is the lottery victim — the discriminator is
    # asserted there. (The master is observed too and asserted, since with
    # stuck-both-ways it faults identically — a second independent witness.)
    s, m = obs["s"], obs["m"]

    # Sanity: the scenario must actually exercise the faulting-sweep path,
    # else the negative control is vacuous.
    assert s["fault_ever"], (
        "Slave calibrator never faulted a lane within the poll window — "
        "the staggered lottery scenario was not exercised (check the "
        "STUCK_LANES_MASK make args / increase POLL). Negative control "
        "would be vacuous."
    )

    # ---- THE DISCRIMINATOR (this IS the committed b248148 change) --------
    #
    # PRE-FIX (negative control): S_FINISH unconditionally → S_DONE, so a
    # faulted sweep latches S_DONE + calibration_done=1 + lane_fault=0xFF
    # and STAYS there. These two assertions FIRE on the pre-fix calibrator.
    assert not s["sdone_fault_ever"], (
        "PRE-FIX LOTTERY LATCH DETECTED: slave calibrator reached "
        "state==S_DONE with lane_fault!=0 while role_locked==1. The fix "
        "(b248148) must NOT latch calibration_done on a faulted sweep — it "
        "must re-sweep while role_locked. This is the per-deploy lottery."
    )
    assert s["done_ever"] == 0, (
        "PRE-FIX LOTTERY LATCH DETECTED: slave calibration_done asserted "
        "after a faulting sweep under staggered role_lock. The fix must "
        "hold calibration_done=0 and re-sweep until the peer's training "
        "window overlaps — it must keep trying, not give up."
    )
    assert not m["sdone_fault_ever"] and m["done_ever"] == 0, (
        "PRE-FIX LOTTERY LATCH DETECTED on the master witness "
        f"(sdone_fault_ever={m['sdone_fault_ever']}, "
        f"done_ever={m['done_ever']}): a faulted sweep latched S_DONE / "
        "calibration_done instead of re-sweeping."
    )

    # POST-FIX positive evidence: lane_fault went non-zero then back to 0
    # (only the S_ARM mass-clear does that → the FSM re-armed after a
    # faulted sweep instead of finishing), and training_mode never dropped
    # while actively arming/sweeping under role_lock (the pattern is held
    # up across retries so a skew-staggered peer can still converge). This
    # is the continuous re-sweep that turns the fatal ms non-overlap into
    # a benign convergence delay.
    assert s["fault_then_clear"], (
        "Expected the fixed slave calibrator to RE-ARM after a faulted "
        "sweep (lane_fault non-zero → cleared via the S_ARM mass-clear, "
        "with role_locked high) — the core of the T3 fix — but lane_fault "
        "never cleared back to 0, so no re-sweep was observed."
    )
    assert not s["train_low_while_active"], (
        "Fixed slave calibrator dropped training_mode while still actively "
        "arming/sweeping under role_lock — it must hold the training "
        "pattern up across re-sweeps so the skew-staggered peer can "
        "eventually lock."
    )

    dut._log.info(
        "[T3] PASS — under a role_lock stagger >> one sweep period the "
        "calibrator does NOT latch the pre-fix lottery state; it re-sweeps "
        "continuously with training_mode held high (commit b248148)."
    )
