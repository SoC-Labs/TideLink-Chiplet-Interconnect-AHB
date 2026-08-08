"""test_calibrator_wrap — REPRODUCE-FIRST for the circular-phase run-tracker bug.

The RX phase axis is CIRCULAR mod-16 (WavD2DGpioRx_v2.v:406, adj_count =
count + io_phase_offset). The calibrator sweep is phase-INNER (0..15) / slip-
OUTER, and the run-tracker RESETS run_len at sweep_phase==15 and scores the
phase axis as LINEAR [0..15]. So a passing eye that STRADDLES the phase-15->0
wrap at a fixed slip -- e.g. {14,15,0,1} -- is split into two short runs
({0,1} and {14,15}); with MIN_LOCK_DWELLS=3 NEITHER reaches the gate, so
best_run never promotes, S_FINALIZE finds no eye-centre, and the lane falls to
the (0,0)/edge fallback = the write-DROP. A CORRECT (circular) tracker stitches
the phase-15<->phase-0 wrap WITHIN a slip and sees one width-4 run.

Contract (reproduce-first A/B), shaping the eye by gating lane_locked on the
live driven (slip,phase) iterator (identical technique to
test_calibrator_centering):
  BROKEN (linear tracker): best_run < 3  -> FAIL (bug reproduced: straddling
                           eye undercounted; lane drops to (0,0) fallback).
  FIXED  (circular stitch): best_run == 4 and the latched phase is the circular
                           centre (~15/0), NOT the (0,0) edge -> PASS.

Runs against DEPS=1 (the deployed deps/tidelink-phy calibrator) like the
centering test, which exposes min_lock_dwells_i + the eye-vis reads.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

S_PROBE    = 7
S_FINALIZE = 8
DWELL_CYCLES = 8

# Straddling eye: slip 0, contiguous CIRCULAR phase run {14,15,0,1} (width 4).
EYE_SLIP        = 0
EYE_PHASES      = (14, 15, 0, 1)
EYE_WIDTH       = 4
MIN_LOCK_DWELLS = 3   # < true width 4, but > each linear sub-run (2) -> the split drops it


def _state(dut):        return int(dut.state.value)
def _lane0_slip(dut):   return int(dut.bit_slip.value) & 0x7
def _lane0_phase(dut):  return int(dut.phase_offset.value) & 0xF
def _in_eye(slip, phase):
    return slip == EYE_SLIP and phase in EYE_PHASES


async def _start(dut, min_lock_dwells):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.min_lock_dwells_i.value     = min_lock_dwells
    dut.eye_lane_sel.value          = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_wrap_straddle_eye_is_not_split(dut):
    """A width-4 eye straddling the phase 15->0 wrap must score best_run>=4 and
    centre near the wrap (NOT fall to the (0,0) edge). Reproduces the linear
    run-tracker split pre-fix; passes only with a circular tracker."""
    await _start(dut, MIN_LOCK_DWELLS)
    dut.role_locked.value = 1

    reached_finalize = False
    latched_phase = latched_slip = None
    for _ in range(16 * 8 * DWELL_CYCLES + 256):
        await RisingEdge(dut.clk)
        s = _state(dut)
        slip  = _lane0_slip(dut)
        phase = _lane0_phase(dut)
        dut.lane_locked.value = 0xFF if _in_eye(slip, phase) else 0x00
        assert s != S_PROBE, "S_PROBE entered in centering mode."
        if s == S_FINALIZE and not reached_finalize:
            reached_finalize = True
            await RisingEdge(dut.clk)
            latched_slip  = _lane0_slip(dut)
            latched_phase = _lane0_phase(dut)
            break

    assert reached_finalize, "S_FINALIZE never reached (sweep did not run)."
    dut.eye_lane_sel.value = 0
    await RisingEdge(dut.clk)
    best       = int(dut.eye_score_best.value)
    best_phase = int(dut.eye_score_best_phase.value)
    best_slip  = int(dut.eye_score_best_slip.value)

    dut._log.info(
        f"[wrap] latched lane0 (slip={latched_slip}, phase={latched_phase}); "
        f"eye-vis best_run={best} start_phase={best_phase} slip={best_slip}  "
        f"(true eye {EYE_PHASES} @ slip {EYE_SLIP}, width {EYE_WIDTH})")

    # (1) the straddling run must be counted whole, not split.
    assert best >= EYE_WIDTH, (
        f"CIRCULAR RUN-TRACKER BUG REPRODUCED: eye-vis best_run={best} < true "
        f"width {EYE_WIDTH}. The width-4 eye {EYE_PHASES} straddling the phase "
        f"15->0 wrap was SPLIT into two sub-runs by the linear run-tracker "
        f"(reset at phase 15), so best_run never reached MIN_LOCK_DWELLS={MIN_LOCK_DWELLS} "
        f"and the lane dropped to the (slip={latched_slip},phase={latched_phase}) "
        f"fallback = the write-DROP. A circular tracker must stitch phase-15<->0.")
    # (2) it must centre near the wrap, not at the (0,0) edge fallback.
    centred_ok = (latched_slip == EYE_SLIP) and (latched_phase in (14, 15, 0, 1))
    assert centred_ok, (
        f"latched (slip={latched_slip},phase={latched_phase}) is not inside the "
        f"straddling eye centre — fell to a fallback framing.")
    dut._log.info(f"PASS: straddling eye scored best_run={best}, centred at "
                  f"phase {latched_phase} (circular stitch OK).")
