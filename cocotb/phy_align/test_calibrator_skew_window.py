"""§9 calibrator bit-slip × phase SEARCH-WINDOW contract.

WHY THIS TEST EXISTS
--------------------
`src/rtl/tidelink_phy_align_calibrator.sv` is the autonomous §9 per-lane
calibrator. On `role_locked_rise | (swreset_fall & role_locked)` it sweeps,
PER LANE, a shared (phase, slip) iterator looking for each lane's capture
point against the training pattern.

The Pynq-Z2 GPIO-PHY FPGA bring-up is blocked by build-to-build PHY
routing-skew NONDETERMINISM: the calibrator can only rescue a lane if the
build-time clk-to-data skew lands INSIDE its finite slip×phase search
window. The whole timing-determinism remediation plan
(/tmp/timing_determinism_investigation_brief.md) assumes that window is a
KNOWN, STABLE size. If a future RTL edit silently shrinks it — fewer slip
values, fewer phase steps, a shorter dwell, or a narrower lock/fault
criterion that gives up before the space is exhausted — the determinism
work breaks WITHOUT any existing test failing (test_phase_sweep /
test_autocal_integrated converge under a SKID that locks early and never
push the iterator to its edges).

This test makes the window an EXPLICIT, ASSERTED CONTRACT by *exercising*
the calibrator to its edges, not by reading parameters blindly.

DOCUMENTED WINDOW DIMENSIONS  (read from the RTL, with line refs — these
are the numbers a future edit must not shrink; see the file at
src/rtl/tidelink_phy_align_calibrator.sv on this branch):

  * BIT-SLIP values swept : 8   (slip ∈ [0..7])
      - `logic [2:0] sweep_slip;  // 0..7`                       line 245
      - wrap test `if (sweep_slip == 3'd7)`                      line 353
      - header "search space per lane is slip ∈ [0..7] ..."   lines  99-103
  * PHASE values swept    : 16  (phase ∈ [0..15])
      - `logic [3:0] sweep_phase; // 0..15`                      line 246
      - exhaust test `if (sweep_phase == 4'd15)`                 line 355
      - else `sweep_phase <= sweep_phase + 4'd1;`                line 366
  * Per-(slip,phase) DWELL : DWELL_CYCLES (default 32)
      - `parameter int DWELL_CYCLES = 32`                        line 147
      - `localparam int DWELL_MAX = DWELL_CYCLES - 1`            line 248
      - advance gate `if (dwell_ctr == DWELL_MAX...)`            line 347
  * FAULT criterion        : a lane faults ONLY after the FULL
    8×16 = 128-point space is exhausted (phase==15 && slip==7
    with no lock) — lines 353-364 ; header lines 122-123
      `A lane is faulted only after the full 128-point space is exhausted`

  => TOTAL SEARCH CARDINALITY  = 8 (slip) × 16 (phase) = 128 points.

CONTRACT ASSERTED HERE
  (A) bit-slip range  ≥ 8  values  (iterator must actually emit slip==7)
  (B) phase range     ≥ 16 values  (iterator must actually emit phase==15)
  (C) per-(slip,phase) dwell ≥ 16 cycles (≥ lane-checker LOCK_THRESH;
      a shorter dwell would skip valid capture points)
  (D) total cardinality == 128 and the FSM does NOT declare lane_fault
      for an un-lockable lane until it has TRAVERSED the whole 128-point
      space — i.e. it really searches the entire window before giving up.

HOW THE WINDOW EDGES ARE FORCED (honest method statement)
  A STUCK lane (tb_top STUCK_LANES_MASK — its serial line pinned to 0)
  NEVER locks, so for that lane the calibrator is OBLIGED to walk the
  shared (phase,slip) iterator across the entire 128-point space before
  it may set lane_fault.  We enable the autocal calibrator, role-lock,
  and sample the calibrator's INTERNAL shared iterator
  (u_calibrator.sweep_slip / .sweep_phase) every link clock, recording
  the maxima it reaches and the (phase,slip) at which lane_fault for the
  stuck lane finally asserts.  This observes the calibrator ACTUALLY
  traversing the full space (requirement 2), rather than asserting on
  parameters alone.  A structural cross-check on the iterator widths and
  the DWELL_CYCLES parameter backs the dynamic observation.

NEGATIVE CONTROL (documented in README; reproduced by the parent task):
  Capping the phase iterator (e.g. `sweep_phase == 4'd7`) or faulting
  after fewer combos shrinks the window; rerun (after
  `rm -rf cocotb/*/sim_build`) FAILS contract (B)/(D) with a message
  naming the timing-determinism dependency. Restoring the RTL PASSES.

Invocation (from cocotb/phy_align/):
    rm -rf sim_build ../wlink_pair/sim_build
    make MODULE=test_calibrator_skew_window SKID_BITS=3 STUCK_LANES_MASK=16
"""
import os

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout

# SimTimeoutError moved across cocotb releases (cocotb.result in 1.x,
# cocotb.triggers in 2.x). Resolve it portably so the RX-clock stall
# guard works on whichever cocotb the sim Makefile pulls in.
try:  # cocotb 2.x
    from cocotb.triggers import SimTimeoutError
except ImportError:  # cocotb 1.x
    from cocotb.result import SimTimeoutError

from test_link_bringup import setup, lock_master, lock_slave, ctrl_read
from test_autocal_integrated import (
    _chiplet_path,
    _force_autocal_enable,
    _read_cal_state,
    _read_cal_lane_fault,
    _read_cal_bit_slip,
    R8_SWI_LANE_STATUS,
)

# ---------------------------------------------------------------------------
# DOCUMENTED WINDOW CONTRACT CONSTANTS (mirror the RTL; see module docstring
# for the exact line references in tidelink_phy_align_calibrator.sv). These
# are the asserted floor — a future RTL edit MUST NOT shrink them.
# ---------------------------------------------------------------------------
EXPECT_NUM_SLIP   = 8     # slip ∈ [0..7]   (sweep_slip [2:0], wrap at 3'd7)
EXPECT_NUM_PHASE  = 16    # phase ∈ [0..15] (sweep_phase[3:0], exhaust 4'd15)
EXPECT_MAX_SLIP   = 7
EXPECT_MAX_PHASE  = 15
EXPECT_CARDINALITY = EXPECT_NUM_SLIP * EXPECT_NUM_PHASE       # 8 × 16 = 128
MIN_DWELL_CYCLES  = 16    # ≥ wlink_lane_checker LOCK_THRESH (16); default 32

# The stuck lane (tb_top STUCK_LANES_MASK=16 == 1<<4). This lane's serial
# line is pinned to 0, so it can NEVER lock — forcing the calibrator to
# traverse the entire 128-point window before it may fault the lane.
STUCK_LANE = 4
EXPECT_STUCK_MASK = 1 << STUCK_LANE


def _cal(dut, side):
    """The tidelink_phy_align_calibrator instance (u_calibrator lives
    directly inside the axi_chiplet_controller = dut.u_master/u_slave)."""
    return _chiplet_path(dut, side).u_calibrator


def _sweep_slip(dut, side):
    return int(_cal(dut, side).sweep_slip.value)


def _sweep_phase(dut, side):
    return int(_cal(dut, side).sweep_phase.value)


def _dwell_cycles(dut, side):
    """DWELL_CYCLES parameter as elaborated into the instance."""
    return int(_cal(dut, side).DWELL_CYCLES.value)


def _cal_state(dut, side):
    return int(_cal(dut, side).cur_state.value)


@cocotb.test()
async def test_calibrator_skew_window_structural(dut):
    """STRUCTURAL floor: the calibrator's elaborated iterator widths and
    dwell parameter must be ≥ the documented window. Width-narrowing or a
    too-short dwell is caught here even before the dynamic traversal."""
    await setup(dut)

    for side in ("m", "s"):
        cal = _cal(dut, side)

        # Bit-slip iterator: sweep_slip declared `logic [2:0]` (line 245);
        # 3 bits ⇒ can represent 0..7 = 8 values.
        slip_w = len(cal.sweep_slip)
        slip_range = 1 << slip_w
        assert slip_range >= EXPECT_NUM_SLIP, (
            f"[{side}] sweep_slip is {slip_w}-bit ⇒ only {slip_range} bit-slip "
            f"values; the §9 skew window REQUIRES ≥ {EXPECT_NUM_SLIP} "
            f"(slip ∈ [0..7]). Narrowing it shrinks the FPGA "
            f"timing-determinism skew margin (see "
            f"/tmp/timing_determinism_investigation_brief.md)."
        )

        # Phase iterator: sweep_phase declared `logic [3:0]` (line 246);
        # 4 bits ⇒ can represent 0..15 = 16 values.
        ph_w = len(cal.sweep_phase)
        ph_range = 1 << ph_w
        assert ph_range >= EXPECT_NUM_PHASE, (
            f"[{side}] sweep_phase is {ph_w}-bit ⇒ only {ph_range} phase "
            f"values; the §9 skew window REQUIRES ≥ {EXPECT_NUM_PHASE} "
            f"(phase ∈ [0..15]). Narrowing it shrinks the FPGA "
            f"timing-determinism skew margin."
        )

        # Per-(slip,phase) dwell. A dwell shorter than the lane-checker
        # LOCK_THRESH (16) would step past valid capture points without
        # ever seeing a lock — a silent window shrink in the time domain.
        dwell = _dwell_cycles(dut, side)
        assert dwell >= MIN_DWELL_CYCLES, (
            f"[{side}] DWELL_CYCLES={dwell} < {MIN_DWELL_CYCLES} "
            f"(wlink_lane_checker LOCK_THRESH). A dwell below the lock "
            f"threshold skips valid capture points — a silent shrink of "
            f"the §9 skew window's time dimension."
        )

        dut._log.info(
            f"[{side}] structural: sweep_slip={slip_w}b ({slip_range} vals) "
            f"sweep_phase={ph_w}b ({ph_range} vals) DWELL_CYCLES={dwell}"
        )

    dut._log.info(
        f"STRUCTURAL OK: iterator widths admit ≥ {EXPECT_NUM_SLIP} slip × "
        f"≥ {EXPECT_NUM_PHASE} phase = ≥ {EXPECT_CARDINALITY} search points; "
        f"dwell ≥ {MIN_DWELL_CYCLES}."
    )


@cocotb.test()
async def test_calibrator_skew_window_traversal(dut):
    """DYNAMIC contract: with an un-lockable (stuck) lane, the calibrator
    MUST traverse the ENTIRE documented 8×16=128 (slip,phase) window before
    it declares lane_fault for that lane. We observe the internal shared
    iterator reach slip==7 AND phase==15, and verify lane_fault for the
    stuck lane is NOT asserted until the full space is exhausted.

    This is the unfakeable check: a window-shrinking RTL edit either never
    emits the documented maxima (caps the iterator) or faults early
    (narrower give-up criterion) — both fail an assertion below whose
    message names the timing-determinism dependency.
    """
    # Hard requirement: the stuck-lane mechanism must be compiled in,
    # otherwise this test cannot force the iterator to the window edges.
    try:
        stuck = int(dut.STUCK_LANES_MASK.value)
    except AttributeError:
        stuck = None
    assert stuck is not None and (stuck & EXPECT_STUCK_MASK) == EXPECT_STUCK_MASK, (
        f"tb_top.STUCK_LANES_MASK=0x{0 if stuck is None else stuck:02x} does "
        f"not mark lane {STUCK_LANE} stuck. This test REQUIRES "
        f"STUCK_LANES_MASK={EXPECT_STUCK_MASK} on the make line so the "
        f"calibrator is forced to walk the full window. Invoke:\n"
        f"  make MODULE=test_calibrator_skew_window SKID_BITS=3 "
        f"STUCK_LANES_MASK={EXPECT_STUCK_MASK}"
    )
    dut._log.info(f"  tb_top.STUCK_LANES_MASK = 0x{stuck:02x} (lane {STUCK_LANE} stuck)")

    # Enable the autocal calibrator on both sides BEFORE leaving POR, then
    # role-lock so role_locked rises and the sweep triggers. No SW slip
    # writes — the calibrator drives the whole search itself.
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # The calibrator runs on the recovered RX *link* clock
    # (phy_link_rx_rx_link_clk_w) — a divide-by-8 of the serial pad clock,
    # NOT apb_clk. tb_top exposes it as dut.s_rx_link_clk. The shared
    # (phase,slip) iterator can change at most once per RX-link-clock edge,
    # so we sample ON that edge: precise (no aliasing) and far cheaper than
    # polling tens of thousands of apb_clk cycles.
    #
    # The SLAVE side's RX is fed by the master TX through the m2s pad_skid
    # that contains the stuck lane, so the SLAVE calibrator's lane
    # STUCK_LANE can never lock and is the one obliged to exhaust the whole
    # window. Worst case = 16 phase × 8 slip × DWELL_CYCLES link clocks.
    dwell = _dwell_cycles(dut, "s")
    assert dwell >= MIN_DWELL_CYCLES, (
        f"DWELL_CYCLES={dwell} < {MIN_DWELL_CYCLES} (lane-checker "
        f"LOCK_THRESH) — time-domain window shrink (see structural test)."
    )
    rx_clk = dut.s_rx_link_clk
    # 128 points × dwell, plus a generous FSM-entry / settle margin in RX
    # link clocks. A correct full traversal completes well inside this.
    edge_budget = EXPECT_CARDINALITY * dwell + 4 * dwell + 512

    max_slip_seen = -1
    max_phase_seen = -1
    # Maxima the iterator had reached at the FIRST edge the stuck lane is
    # observed faulted — proves the FULL window was walked before give-up.
    slip_at_fault = None
    phase_at_fault = None
    fault_seen = False
    cal_done_s = 0

    stalled = False
    for _ in range(edge_budget):
        # Bound each edge wait in sim time so a stalled/never-toggling RX
        # clock can't hang the test — on timeout we break and let the
        # contract assertions report what was (not) observed.
        try:
            await with_timeout(RisingEdge(rx_clk), 100, "us")
        except SimTimeoutError:
            stalled = True
            break
        try:
            ss = _sweep_slip(dut, "s")
            sp = _sweep_phase(dut, "s")
        except ValueError:
            continue
        if ss > max_slip_seen:
            max_slip_seen = ss
        if sp > max_phase_seen:
            max_phase_seen = sp
        if not fault_seen:
            f = _read_cal_lane_fault(dut, "s")
            if (f >> STUCK_LANE) & 1:
                # The stuck lane is now faulted. Per RTL lines 353-364
                # lane_fault_q is REGISTERED, set in the dwell-expiry cycle
                # that detects sweep_phase==15 && sweep_slip==7; it is
                # therefore visible one RX edge later, by which point
                # sweep_slip has wrapped 7→0 and sweep_phase holds at 15.
                # The robust, register-stage-independent contract is: the
                # iterator must have ALREADY reached the documented window
                # maxima (max slip==7 AND max phase==15) BEFORE the fault
                # is allowed to assert — i.e. the whole 128-point space
                # was searched. Snapshot the maxima at this edge.
                fault_seen = True
                slip_at_fault = max_slip_seen
                phase_at_fault = max_phase_seen
        st = _read_cal_state(dut, "s")
        if st == 4:  # S_DONE — sweep complete
            cal_done_s = 1
            max_slip_seen = max(max_slip_seen, ss)
            max_phase_seen = max(max_phase_seen, sp)
            break

    fault_s = _read_cal_lane_fault(dut, "s")
    state_s = _read_cal_state(dut, "s")
    slip_bus_s = _read_cal_bit_slip(dut, "s")
    dut._log.info(
        f"TRAVERSAL: max_slip_seen={max_slip_seen} max_phase_seen="
        f"{max_phase_seen} fault_seen={fault_seen} "
        f"(slip,phase)@fault=({slip_at_fault},{phase_at_fault}) "
        f"cal_done_s={cal_done_s} state_s={state_s} stalled={stalled} "
        f"lane_fault_s=0x{fault_s:02x} slip_bus_s=0x{slip_bus_s:06x} "
        f"dwell={dwell} edge_budget={edge_budget}"
    )

    # ---- (A) BIT-SLIP RANGE ≥ 8 : iterator actually emitted slip==7 ----
    assert max_slip_seen >= EXPECT_MAX_SLIP, (
        f"calibrator never drove sweep_slip to {EXPECT_MAX_SLIP} "
        f"(max seen={max_slip_seen}). The bit-slip search window has been "
        f"SHRUNK below the documented {EXPECT_NUM_SLIP} values "
        f"(slip ∈ [0..7]). The FPGA timing-determinism remediation "
        f"(/tmp/timing_determinism_investigation_brief.md) DEPENDS on the "
        f"full slip range to rescue build-time clk-to-data skew."
    )

    # ---- (B) PHASE RANGE ≥ 16 : iterator actually emitted phase==15 ----
    assert max_phase_seen >= EXPECT_MAX_PHASE, (
        f"calibrator never drove sweep_phase to {EXPECT_MAX_PHASE} "
        f"(max seen={max_phase_seen}). The PHASE search window has been "
        f"SHRUNK below the documented {EXPECT_NUM_PHASE} values "
        f"(phase ∈ [0..15]). Sub-bit routing skew that lands beyond the "
        f"truncated phase range would no longer be rescued — silently "
        f"breaking the FPGA timing-determinism plan."
    )

    # ---- (D) FULL-WINDOW SEARCH BEFORE GIVING UP ----------------------
    # The stuck lane can never lock, so the calibrator is obliged to walk
    # the ENTIRE 128-point space before faulting it. Per RTL lines
    # 353-364 lane_fault_q is REGISTERED and set in the dwell-expiry cycle
    # that detects (sweep_phase==15 && sweep_slip==7) with no lock — the
    # LAST point of the window. Because it is a registered output the
    # observation lands one RX edge later (slip already wrapped 7→0,
    # phase held at 15), so the register-stage-INDEPENDENT contract is:
    # by the time the stuck lane's fault is first visible, the iterator
    # must ALREADY have reached BOTH documented maxima — i.e. it really
    # searched the whole 8×16 window before giving up.
    assert fault_seen, (
        f"stuck lane {STUCK_LANE} never faulted within edge budget "
        f"({edge_budget} RX edges, state_s={state_s}, stalled={stalled}). "
        f"The calibrator did not complete a full window traversal — "
        f"cannot certify the §9 skew window."
    )
    assert slip_at_fault >= EXPECT_MAX_SLIP and phase_at_fault >= EXPECT_MAX_PHASE, (
        f"stuck lane {STUCK_LANE} faulted after the iterator had only "
        f"reached slip={slip_at_fault}, phase={phase_at_fault} — the "
        f"give-up criterion fired BEFORE the full {EXPECT_CARDINALITY}-"
        f"point slip×phase space (max slip {EXPECT_MAX_SLIP}, max phase "
        f"{EXPECT_MAX_PHASE}) was exhausted. The calibrator abandons "
        f"un-rescued lanes early, so the effective skew window is SMALLER "
        f"than the documented {EXPECT_NUM_SLIP}×{EXPECT_NUM_PHASE}. This "
        f"is exactly the silent shrink the FPGA timing-determinism "
        f"remediation (/tmp/timing_determinism_investigation_brief.md) "
        f"must be protected against."
    )

    # ---- Cardinality contract, expressed as an asserted constant ------
    cardinality = (max_slip_seen + 1) * (max_phase_seen + 1)
    assert cardinality == EXPECT_CARDINALITY, (
        f"observed slip×phase search cardinality "
        f"({max_slip_seen + 1}×{max_phase_seen + 1}={cardinality}) != "
        f"the documented {EXPECT_NUM_SLIP}×{EXPECT_NUM_PHASE}="
        f"{EXPECT_CARDINALITY}. The §9 calibrator's skew-search window "
        f"changed size; the FPGA timing-determinism remediation plan "
        f"assumes a STABLE {EXPECT_CARDINALITY}-point window — update the "
        f"plan and this contract together, deliberately, never silently."
    )

    # The stuck lane MUST have faulted (it can never lock); other lanes
    # under the uniform SKID lock during the phase=0 inner pass.
    assert (fault_s >> STUCK_LANE) & 1 == 1, (
        f"stuck lane {STUCK_LANE} did NOT fault (lane_fault=0x{fault_s:02x}) "
        f"even though its serial line is pinned to 0 — the full-window "
        f"traversal / fault path is broken."
    )

    # Region 8 status path consistency cross-check (the same external
    # surface the bring-up uses): lane_fault for the stuck lane visible.
    await ClockCycles(dut.apb_clk, 16)
    st = await ctrl_read(dut, "s", R8_SWI_LANE_STATUS)
    r8_fault = (st >> 8) & 0xFF
    dut._log.info(
        f"R8 SWI_LANE_STATUS slave = 0x{st:08x} (lane_fault=0x{r8_fault:02x})"
    )
    assert (r8_fault >> STUCK_LANE) & 1 == 1, (
        f"R8 SWI_LANE_STATUS lane_fault=0x{r8_fault:02x} does not show the "
        f"stuck lane {STUCK_LANE} faulted — calibrator→Region 8 status "
        f"path inconsistent with the internal fault."
    )

    dut._log.info(
        f"CONTRACT OK: calibrator traversed the FULL documented window — "
        f"slip 0..{max_slip_seen} ({max_slip_seen + 1} values) × "
        f"phase 0..{max_phase_seen} ({max_phase_seen + 1} values) = "
        f"{cardinality} points; un-lockable lane {STUCK_LANE} was NOT "
        f"faulted until the iterator had reached BOTH maxima "
        f"(slip={slip_at_fault}, phase={phase_at_fault}). The §9 "
        f"slip×phase skew window the FPGA timing-determinism plan "
        f"depends on is intact ({EXPECT_CARDINALITY} points, dwell "
        f"{dwell})."
    )
