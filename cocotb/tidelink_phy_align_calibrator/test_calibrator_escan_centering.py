"""test_calibrator_escan_centering — FIX-CENTER eyescan run-CENTRE pinning.

THE EDGE->CENTRE FIX (2026-06-26). The armed eyescan (escan_en) used to FREEZE
each lane's (slip,phase) at the FIRST phase where lane_synced_i[i] asserted —
the eye LEADING EDGE, near-zero margin. On silicon that edge decodes the slow FC
handshake (cal_done, fcsm=4) but bit-errors arbitrary AHB payload. FIX-CENTER
keeps WALKING the cursor while the lane stays synced, tracks the contiguous
synced-phase run, and pins its CENTRE (mirroring the proven S_FINALIZE best_run
centring).

This test drives a MODELED multi-phase synced window (lane_synced_i HIGH only
while the live cursor phase is inside [LO..HI]) and asserts the pinned phase ==
the run CENTRE, NOT the first-sync EDGE (LO).

Shared-clock note: this is an FSM-level proof that the centring arithmetic +
pin routing are correct. It does NOT (and cannot) show edge-vs-centre DELIVERY —
there is no real eye here; that is the on-silicon soak's job. The value here is:
(a) the pinned phase is the modeled window's MIDDLE, not its leading edge, and
(b) arm=0 (lane_pin_converge_en_i=0) leaves the eyescan branch dead.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# FSM state encodings — mirror tidelink_phy_align_calibrator.sv §state-encoding.
S_IDLE     = 0
S_ARM      = 1
S_SWEEP    = 2
S_FINISH   = 3
S_DONE     = 4
S_CANCEL   = 5
S_HOLD     = 6
S_PROBE    = 7
S_FINALIZE = 8
S_VALIDATE = 9

# Modeled synced window at slip=0: contiguous cursor phases [LO..HI] (width 5).
# Run centre = LO + (HI-LO)//2 = 5 + 2 = 7. The leading EDGE (LO=5) is the value
# the OLD edge-freeze would have pinned, so centre (7) != edge (5) is the proof.
WIN_LO     = 5
WIN_HI     = 9
WIN_CENTRE = WIN_LO + (WIN_HI - WIN_LO) // 2   # = 7


def _state(dut):
    return int(dut.state.value)


def _lane0_phase(dut):
    # phase_offset is 8x4b; lane 0 at [3:0]. While unpinned + scanning this is
    # the live escan_phase cursor.
    return int(dut.phase_offset.value) & 0xF


def _lane0_slip(dut):
    return int(dut.bit_slip.value) & 0x7


def _lane_pinned(dut):
    try:
        return int(dut.u_dut.lane_pinned.value)
    except Exception:
        return None


def _pin_phase0(dut):
    # pin_phase is an unpacked array [0:7] of 4b — index 0.
    try:
        return int(dut.u_dut.pin_phase[0].value)
    except Exception:
        return None


def _pin_slip0(dut):
    try:
        return int(dut.u_dut.pin_slip[0].value)
    except Exception:
        return None


def _esync_best_run0(dut):
    try:
        return int(dut.u_dut.esync_best_run[0].value)
    except Exception:
        return None


def _esync_best_start0(dut):
    try:
        return int(dut.u_dut.esync_best_start_phase[0].value)
    except Exception:
        return None


async def _start(dut, arm):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value            = 0
    dut.swreset.value                = 0
    dut.lane_locked.value            = 0xFF      # all lanes lock at (0,0) -> S_PROBE pass
    dut.lane_mask.value              = 0xFF      # v1 default; FIX guards expect 0xFF
    dut.apb_bit_slip_override.value  = 0
    dut.apb_override_enable.value    = 0
    dut.min_lock_dwells_i.value      = 0          # 0 => S_ARM->S_PROBE fast path to S_HOLD
    dut.cr_pkt_seen_i.value          = 0          # NO confirm: let the eyescan run
    dut.crack_pkt_seen_i.value       = 0
    dut.sync_seen_i.value            = 0
    dut.swi_training_hold_i.value    = 0
    dut.lane_synced_i.value          = 0
    dut.lane_pin_converge_en_i.value = arm        # ARM the eyescan (escan_en gate)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def _run_to_validate_and_pin(dut):
    """Drive role_lock, traverse to S_VALIDATE, then gate lane_synced_i HIGH only
    while the live cursor phase is inside [WIN_LO..WIN_HI] at slip 0. Returns once
    lane 0 pins (or the budget is spent)."""
    dut.role_locked.value = 1

    saw_validate = False
    pinned = False
    # Budget: cover S_PROBE->S_HOLD->S_VALIDATE plus a couple of full cursor
    # passes (16 phases x EYESCAN_DWELL) so the window is hit and the run closes.
    for _ in range(40000):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if s == S_VALIDATE:
            saw_validate = True

        # Model the synced window: only inside S_VALIDATE, only at slip 0, only
        # while the live cursor phase is in-window. Outside -> sync drops, which
        # CLOSES the run and triggers the FIX-CENTER centre pin.
        if s == S_VALIDATE:
            ph = _lane0_phase(dut)
            sl = _lane0_slip(dut)
            in_win = (sl == 0) and (WIN_LO <= ph <= WIN_HI)
            dut.lane_synced_i.value = 0xFF if in_win else 0x00
        else:
            dut.lane_synced_i.value = 0x00

        p = _lane_pinned(dut) or 0
        if p & 0x01:
            pinned = True
            # let the pin + output-mux settle one cycle
            await RisingEdge(dut.clk)
            break

    return saw_validate, pinned


@cocotb.test()
async def test_escan_pins_run_centre_not_edge(dut):
    """Armed eyescan: modeled synced window [5..9] -> lane 0 pins the run CENTRE
    (phase 7), NOT the leading edge (5)."""
    await _start(dut, arm=1)
    saw_validate, pinned = await _run_to_validate_and_pin(dut)

    assert saw_validate, "S_VALIDATE never entered (eyescan never engaged)."
    assert pinned, "lane 0 never pinned inside the modeled synced window."

    best_run   = _esync_best_run0(dut)
    best_start = _esync_best_start0(dut)
    pin_phase  = _pin_phase0(dut)
    pin_slip   = _pin_slip0(dut)
    out_phase  = _lane0_phase(dut)
    out_slip   = _lane0_slip(dut)

    dut._log.info(
        f"[escan-centre] best_run={best_run} best_start={best_start} "
        f"pin_phase={pin_phase} pin_slip={pin_slip} "
        f"out_phase={out_phase} out_slip={out_slip} "
        f"(window [{WIN_LO}..{WIN_HI}], expected centre {WIN_CENTRE})"
    )

    # The synced run the tracker measured must span the modeled window.
    assert best_run is not None and best_run >= (WIN_HI - WIN_LO + 1) - 1, (
        f"best_run={best_run} too short for window [{WIN_LO}..{WIN_HI}] "
        f"(centre pin would be meaningless)."
    )

    # CORE ASSERTION: the pinned phase is the run CENTRE, not the leading edge.
    assert pin_phase != WIN_LO, (
        f"pin_phase={pin_phase} == window leading edge {WIN_LO} — this is the "
        f"OLD edge-freeze bug (near-zero margin). FIX-CENTER must pin the centre."
    )
    assert abs(pin_phase - WIN_CENTRE) <= 1, (
        f"pin_phase={pin_phase}, expected ~{WIN_CENTRE} (centre of the "
        f"[{WIN_LO}..{WIN_HI}] synced run). +/-1 allows dwell-boundary "
        f"run-start sampling jitter."
    )
    assert pin_slip == 0, f"pin_slip={pin_slip}, expected 0 (window at slip 0)."

    # The centred (slip,phase) must REACH the PHY output mux (pin_phase was a
    # dead observability reg before FIX-CENTER routed it through the mux).
    assert out_phase == pin_phase, (
        f"output phase_offset lane0={out_phase} != pin_phase={pin_phase} — the "
        f"centred value did NOT reach the PHY output (mux not routing pin_*)."
    )
    assert out_slip == pin_slip, (
        f"output bit_slip lane0={out_slip} != pin_slip={pin_slip}."
    )

    dut._log.info(
        f"PASS: eyescan pinned the run CENTRE phase={pin_phase} (~{WIN_CENTRE}), "
        f"NOT the edge {WIN_LO}, and it reached the PHY output."
    )


@cocotb.test()
async def test_escan_arm_off_no_pin(dut):
    """No-regression control: with the eyescan DISARMED (lane_pin_converge_en_i
    == 0), escan_en is constant 0 -> the FIX-CENTER run tracker is dead and NO
    lane ever pins, even though the same modeled synced window is driven."""
    await _start(dut, arm=0)
    dut.role_locked.value = 1

    saw_validate = False
    pinned_ever = 0
    for _ in range(40000):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if s == S_VALIDATE:
            saw_validate = True
            ph = _lane0_phase(dut)
            sl = _lane0_slip(dut)
            in_win = (sl == 0) and (WIN_LO <= ph <= WIN_HI)
            dut.lane_synced_i.value = 0xFF if in_win else 0x00
        else:
            dut.lane_synced_i.value = 0x00
        pinned_ever |= (_lane_pinned(dut) or 0)
        if s == S_DONE:
            break

    dut._log.info(
        f"[arm-off] saw_validate={saw_validate} pinned_ever=0x{pinned_ever:02x} "
        f"final_state={_state(dut)}"
    )
    # With arm=0 the calibrator may take the legacy S_HOLD->S_VALIDATE->S_DONE
    # (no confirm -> timeout terminal) OR never linger in S_VALIDATE; the
    # load-bearing invariant is simply that the eyescan NEVER pins a lane.
    assert pinned_ever == 0, (
        f"arm=0 pinned lanes 0x{pinned_ever:02x} — the eyescan datapath is NOT "
        f"dead when disarmed (regression: escan_en should be constant 0)."
    )
    dut._log.info("PASS: arm=0 -> eyescan never pins (FIX-CENTER datapath dead).")
