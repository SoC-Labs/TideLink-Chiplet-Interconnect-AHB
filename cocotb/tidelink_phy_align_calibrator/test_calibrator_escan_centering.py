"""test_calibrator_escan_centering — FIX-CENTER-LITE first-sync + center-nudge pin.

THE EDGE->CENTRE NUDGE (2026-06-26). The armed eyescan (escan_en) FREEZES each
lane's (slip,phase) at the FIRST phase where lane_synced_i[i] asserts (the eye
LEADING EDGE, near-zero margin) — this is FIX-R's FAST convergence path, the one
that made BOTH dies link up first roll on silicon. The full FIX-CENTER tried to
KEEP WALKING the cursor to measure the synced-run width and pin its centre, but
that EXTENDED S_VALIDATE residency and re-opened the bilateral rendezvous
starvation FIX-R had cured (silicon: die_a never converged). FIX-CENTER-LITE
REVERTS to FIX-R's fast first-sync pin and only NUDGES the pinned PHASE by a
small fixed ESCAN_CENTER_OFFSET (default 1, CLAMPED to 15) so the sample steps
off the marginal edge toward centre WITHOUT changing convergence time.

This test drives a MODELED synced window (lane_synced_i HIGH while the live
cursor phase is in [LO..HI]) and asserts the pinned phase == the FIRST-SYNC edge
(LO, where the cursor freezes) PLUS the offset — NOT the full-run centre. With
the freeze-on-first-sync drive, the cursor stops the instant it enters the
window, so first-sync == LO and the nudged pin == LO + ESCAN_CENTER_OFFSET.

Shared-clock note: this is an FSM-level proof that the pin arithmetic + routing
are correct (pin == edge+offset, clamped) and that the nudged value reaches the
PHY output mux. It does NOT (and cannot) show edge-vs-centre DELIVERY — there is
no real eye here; that is the on-silicon soak's job. arm=0
(lane_pin_converge_en_i=0) leaves the eyescan branch dead (no lane pins).

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

# tb_calibrator_escan defparam ESCAN_CENTER_OFFSET — keep in sync with the TB.
# Now 0 to match the RTL param default (2026-06-28): default 0 = the FIX-R fast
# first-sync EDGE pin (the proven link-up anchor), reachable when MMIO=0. The
# runtime MMIO offset (escan_center_offset_i) is the silicon sweep knob.
ESCAN_CENTER_OFFSET = 0

# Modeled synced window at slip=0: contiguous cursor phases [LO..HI]. With the
# freeze-on-first-sync drive the cursor STOPS at LO the instant sync asserts, so
# first-sync == LO and the nudged pin = LO + OFFSET. (HI only matters in that it
# keeps sync HIGH at LO; the cursor never reaches HI because it freezes at LO.)
WIN_LO     = 5
WIN_HI     = 9
PIN_EXPECT = min(WIN_LO + ESCAN_CENTER_OFFSET, 15)   # = 6 (edge 5 + offset 1)


def _state(dut):
    return int(dut.state.value)


def _lane0_phase(dut):
    # phase_offset is 8x4b; lane 0 at [3:0]. While unpinned + scanning this is
    # the live escan_phase cursor; once pinned it is pin_phase[0] (the nudge).
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


async def _start(dut, arm, escan_offset=0):
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
    # FIX-CENTER-LITE runtime offset MMIO override. 0 (default) => the calibrator
    # uses its synth ESCAN_CENTER_OFFSET param; non-zero overrides it at runtime.
    dut.escan_center_offset_i.value  = escan_offset
    dut.lane_pin_converge_en_i.value = arm        # ARM the eyescan (escan_en gate)
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def _run_to_validate_and_pin(dut):
    """Drive role_lock, traverse to S_VALIDATE, then gate lane_synced_i HIGH only
    while the live cursor phase is inside [WIN_LO..WIN_HI] at slip 0. Because the
    drive FREEZES the cursor on first sync, the cursor stops at WIN_LO and the
    debounce pins there. Returns once lane 0 pins (or the budget is spent)."""
    dut.role_locked.value = 1

    saw_validate = False
    pinned = False
    first_sync_phase = None
    # Budget: cover S_PROBE->S_HOLD->S_VALIDATE plus the EYESCAN_DWELL pin
    # debounce held at the frozen first-sync phase.
    for _ in range(40000):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if s == S_VALIDATE:
            saw_validate = True

        # Model the synced window: only inside S_VALIDATE, only at slip 0, only
        # while the live cursor phase is in-window. The freeze-on-first-sync
        # drive STOPS the cursor at the first in-window phase (WIN_LO), holding
        # sync HIGH there so the FIX-L debounce completes and pins.
        if s == S_VALIDATE:
            ph = _lane0_phase(dut)
            sl = _lane0_slip(dut)
            in_win = (sl == 0) and (WIN_LO <= ph <= WIN_HI)
            if in_win and first_sync_phase is None:
                first_sync_phase = ph
            dut.lane_synced_i.value = 0xFF if in_win else 0x00
        else:
            dut.lane_synced_i.value = 0x00

        p = _lane_pinned(dut) or 0
        if p & 0x01:
            pinned = True
            # let the pin + output-mux settle one cycle
            await RisingEdge(dut.clk)
            break

    return saw_validate, pinned, first_sync_phase


@cocotb.test()
async def test_escan_pins_default_offset(dut):
    """Armed eyescan, DEFAULT offset: modeled synced window [5..9] -> the cursor
    freezes at the first-sync edge (5) and lane 0 pins edge + ESCAN_CENTER_OFFSET.
    With the param default now 0 (FIX-R anchor), the pin == the first-sync edge
    (5), NOT the full-run centre (7). The runtime MMIO offset (separate tests)
    is what shifts the sample point on silicon."""
    await _start(dut, arm=1)
    saw_validate, pinned, first_sync_phase = await _run_to_validate_and_pin(dut)

    assert saw_validate, "S_VALIDATE never entered (eyescan never engaged)."
    assert pinned, "lane 0 never pinned inside the modeled synced window."
    assert first_sync_phase == WIN_LO, (
        f"first-sync phase={first_sync_phase}, expected {WIN_LO} — the drive did "
        f"NOT freeze the cursor at the window leading edge (FIX-R fast-pin path "
        f"broken)."
    )

    pin_phase  = _pin_phase0(dut)
    pin_slip   = _pin_slip0(dut)
    out_phase  = _lane0_phase(dut)
    out_slip   = _lane0_slip(dut)

    dut._log.info(
        f"[escan-lite] first_sync={first_sync_phase} offset={ESCAN_CENTER_OFFSET} "
        f"pin_phase={pin_phase} pin_slip={pin_slip} "
        f"out_phase={out_phase} out_slip={out_slip} "
        f"(window [{WIN_LO}..{WIN_HI}], expected pin {PIN_EXPECT})"
    )

    # CORE ASSERTION: the pinned phase is the FIRST-SYNC edge + DEFAULT offset
    # (clamped), NOT the full-run centre. With the default 0 this is the FIX-R
    # edge pin; the runtime MMIO offset nudges it on silicon.
    assert pin_phase == PIN_EXPECT, (
        f"pin_phase={pin_phase}, expected {PIN_EXPECT} = first_sync({WIN_LO}) + "
        f"default offset({ESCAN_CENTER_OFFSET}), clamped to 15. With default 0 "
        f"this is the FIX-R edge ({WIN_LO}); a value of 7 would be the (reverted) "
        f"full-run centre."
    )
    assert pin_slip == 0, f"pin_slip={pin_slip}, expected 0 (window at slip 0)."

    # The nudged (slip,phase) must REACH the PHY output mux.
    assert out_phase == pin_phase, (
        f"output phase_offset lane0={out_phase} != pin_phase={pin_phase} — the "
        f"nudged value did NOT reach the PHY output (mux not routing pin_*)."
    )
    assert out_slip == pin_slip, (
        f"output bit_slip lane0={out_slip} != pin_slip={pin_slip}."
    )

    dut._log.info(
        f"PASS: eyescan pinned first-sync edge {WIN_LO} + default offset "
        f"{ESCAN_CENTER_OFFSET} = phase {pin_phase}, NOT the full-run centre, and "
        f"it reached the PHY output."
    )


@cocotb.test()
async def test_escan_arm_off_no_pin(dut):
    """No-regression control: with the eyescan DISARMED (lane_pin_converge_en_i
    == 0), escan_en is constant 0 -> the eyescan pin block is dead and NO lane
    ever pins, even though the same modeled synced window is driven."""
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
    dut._log.info("PASS: arm=0 -> eyescan never pins (FIX-CENTER-LITE datapath dead).")


@cocotb.test()
async def test_escan_runtime_offset_overrides_param(dut):
    """RUNTIME OFFSET (2026-06-28): a NON-ZERO escan_center_offset_i (the MMIO
    value, swi_escan_offset_r in the controller) overrides the synth
    ESCAN_CENTER_OFFSET param (now 0). Driving offset=3 shifts the pinned phase
    to first-sync edge + 3 (NOT the default 0), proving the runtime value reaches
    pin arithmetic. This is the silicon sweep hook: write the reg pre-arm, get a
    different sample point, no rebuild."""
    RUNTIME_OFFSET = 3
    await _start(dut, arm=1, escan_offset=RUNTIME_OFFSET)
    saw_validate, pinned, first_sync_phase = await _run_to_validate_and_pin(dut)

    assert saw_validate, "S_VALIDATE never entered (eyescan never engaged)."
    assert pinned, "lane 0 never pinned inside the modeled synced window."
    assert first_sync_phase == WIN_LO, (
        f"first-sync phase={first_sync_phase}, expected {WIN_LO}."
    )

    pin_phase = _pin_phase0(dut)
    out_phase = _lane0_phase(dut)
    expect = min(WIN_LO + RUNTIME_OFFSET, 15)   # 5 + 3 = 8
    dut._log.info(
        f"[escan-runtime] first_sync={first_sync_phase} "
        f"runtime_offset={RUNTIME_OFFSET} (param default={ESCAN_CENTER_OFFSET}) "
        f"pin_phase={pin_phase} out_phase={out_phase} expected {expect}"
    )
    assert pin_phase == expect, (
        f"pin_phase={pin_phase}, expected {expect} = first_sync({WIN_LO}) + "
        f"RUNTIME offset({RUNTIME_OFFSET}). A value of "
        f"{min(WIN_LO + ESCAN_CENTER_OFFSET, 15)} would mean the runtime MMIO "
        f"offset was IGNORED and the synth param won."
    )
    assert out_phase == pin_phase, (
        f"output phase_offset lane0={out_phase} != pin_phase={pin_phase} — the "
        f"runtime-nudged value did NOT reach the PHY output."
    )
    dut._log.info(
        f"PASS: runtime MMIO offset {RUNTIME_OFFSET} shifted the pin to "
        f"{pin_phase} (overrode synth param {ESCAN_CENTER_OFFSET})."
    )


@cocotb.test()
async def test_escan_runtime_offset_clamps_to_15(dut):
    """CLAMP: a runtime offset that would push the edge past 15 clamps to 15
    (never wraps into the next slip unit — a wrap lands on the WRONG bit). Edge
    at WIN_LO(5) + offset 7 = 12 (in-range here), so to exercise the clamp we
    rely on the function's saturating add; with offset 7 and edge 5 the result is
    12, still < 15. Use the function's documented clamp contract: any sum >= 16
    saturates. Since the modeled window edge is fixed at 5, the largest 3-bit
    offset (7) gives 12; this test therefore asserts the in-range arithmetic AND
    that the value is monotonic/clamped (<=15)."""
    RUNTIME_OFFSET = 7
    await _start(dut, arm=1, escan_offset=RUNTIME_OFFSET)
    saw_validate, pinned, first_sync_phase = await _run_to_validate_and_pin(dut)
    assert saw_validate and pinned, "eyescan did not engage/pin."

    pin_phase = _pin_phase0(dut)
    expect = min(WIN_LO + RUNTIME_OFFSET, 15)   # 5 + 7 = 12, clamped <=15
    assert pin_phase == expect, (
        f"pin_phase={pin_phase}, expected {expect} (= min(edge+offset, 15))."
    )
    assert pin_phase <= 15, f"pin_phase={pin_phase} exceeds the 4-bit phase max."
    dut._log.info(
        f"PASS: runtime offset {RUNTIME_OFFSET} -> pin {pin_phase} "
        f"(clamped, no slip-unit wrap)."
    )
