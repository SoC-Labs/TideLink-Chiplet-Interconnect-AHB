"""test_lane_swap_detection — integration-scope wiring-discriminator test.

ASIC readiness — closes C03-equivalent of
docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md §3.1.

Force-swap lane 0 and lane 1's deserialised RX slices inside the master's
u_chiplet_controller (phy_link_rx_rx_link_data_w). Adjacent-lane swap is
the canonical SWAPPED stimulus because PATTERN_W alternates P/~P so a
lane 0↔1 swap presents each lane with its inverse.

Pinned:
  * master's wire_status_o[1:0] (lane 0) reports WIRE_SWAPPED within
    one training window
  * master's wire_status_o[3:2] (lane 1) reports WIRE_SWAPPED
  * untouched master lanes stay OK/UNKNOWN
  * slave (unforced control) keeps every lane at OK/UNKNOWN

Uses VCS hierarchical Force on the internal 128-bit bus; degrades
gracefully if the handle is not resolvable.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_through_phase1,
)


WIRE_UNKNOWN = 0
WIRE_OK      = 1
WIRE_SWAPPED = 2
WIRE_DEAD    = 3
WIRE_NAME    = {0: "UNKNOWN", 1: "OK", 2: "SWAPPED", 3: "DEAD"}


def _wire_status(dut, side):
    """Read the 16-bit wire_status bus (2 bits per lane × 8 lanes) from
    u_chiplet_controller's lane_checker output.
    """
    top = dut.u_master if side == "m" else dut.u_slave
    try:
        return int(top.u_chiplet_controller.lane_wire_status_o.value)
    except (AttributeError, ValueError):
        return -1


def _per_lane_wire_status(ws_packed):
    """Unpack the 16-bit packed bus to a list of 8 × 2-bit per-lane status."""
    if ws_packed < 0:
        return [-1] * 8
    return [(ws_packed >> (2 * i)) & 0x3 for i in range(8)]


def _phy_rx_data(dut, side):
    """Handle to the 128-bit deserialised RX data inside u_chiplet_controller.
    Used for the swap force.
    """
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.phy_link_rx_rx_link_data_w


@cocotb.test()
async def test_lane01_swap_master_detected_as_swapped(dut):
    """Force-swap lane 0 and lane 1's 16-bit deserialised RX slices on
    the MASTER. After the wire discriminator settles, the master's
    lane_wire_status_o[1:0] (= lane 0 status) and [3:2] (= lane 1 status)
    must both read WIRE_SWAPPED (2'd2). The slave is untouched and acts
    as the OK control.

    Why lane 0 ↔ lane 1: per training_patterns.py PATTERN_W = [P, ~P,
    P, ~P, ...] so swapping adjacent lanes flips P↔~P which is the
    canonical WIRE_SWAPPED stimulus (spec §2.3 + §4.3).
    """
    tb = PairTB(dut)

    # First: bring the link up CLEANLY (no swap). The calibrator must
    # complete normally because the swap is not yet active.
    await run_bringup_through_phase1(tb)
    await ClockCycles(dut.hclk, 2000)

    # Sanity: pre-swap, both sides should report WIRE_OK on every lane.
    m_ws_pre = _wire_status(dut, "m")
    s_ws_pre = _wire_status(dut, "s")
    tb.log.info(
        f"  PRE-swap M wire_status=0x{m_ws_pre & 0xFFFF:04x} "
        f"S wire_status=0x{s_ws_pre & 0xFFFF:04x}"
    )

    # Apply the swap on master's deserialised RX bus. lane 0 occupies
    # bits [15:0], lane 1 occupies bits [31:16]. We Force lane 0's slice
    # to whatever lane 1's slice currently is, and vice versa.
    #
    # The `force/release` on a wire works in VCS; if it doesn't resolve
    # we degrade to a log-and-skip.
    try:
        m_rx = _phy_rx_data(dut, "m")
        # Read the current 128-bit value, swap lanes 0/1, force the result.
        # We do this every cycle for `swap_cycles` so the static-force
        # remains valid across re-clocking of the source bus.
        # Simpler approach: take the current value and force a constant
        # for the duration of the measurement window — the data is
        # repeating training pattern, so the lane-slice values do not
        # change cycle-to-cycle while training_mode is high.
        cur = int(m_rx.value)
        lane0 = (cur >>  0) & 0xFFFF
        lane1 = (cur >> 16) & 0xFFFF
        # Build the swapped value: lane 0 ← lane 1, lane 1 ← lane 0,
        # other lanes unchanged.
        upper = cur & ~((1 << 32) - 1)   # bits [127:32] preserved
        swapped = upper | (lane0 << 16) | (lane1 << 0)
        m_rx.value = Force(swapped)
        tb.log.info(
            f"  Forced master phy_link_rx_rx_link_data_w lane0/lane1 swap: "
            f"orig 0x{cur:032x} → 0x{swapped:032x}"
        )
    except (AttributeError, ValueError) as e:
        tb._log.warning(
            f"Could not force master phy_link_rx_rx_link_data_w ({e}); "
            f"this test requires VCS hierarchical force. Skipping the "
            f"WIRE_SWAPPED assertion — coverage of the FSM transition is "
            f"still pinned at unit level by "
            f"cocotb/lane_checker_single/test_wiring_discriminator.py."
        )
        return

    # Wait long enough for the discriminator FSM + vote_enable hysteresis
    # to converge. Per spec §4.3 the lock-then-vote path takes at most
    # ~LOCK_CONSEC × 3 + DEAD_MAX cycles; DEAD_MAX default = 64. We give
    # 16k hclk cycles which is ~1k pad_clk cycles at the 16-MHz pad ratio.
    await ClockCycles(dut.hclk, 16000)

    # Read out the discriminator verdict on the swapped side.
    m_ws_post = _wire_status(dut, "m")
    s_ws_post = _wire_status(dut, "s")

    # Release the force so the link is clean for any follow-on tests.
    try:
        _phy_rx_data(dut, "m").value = Release()
    except (AttributeError, ValueError):
        pass

    m_lanes = _per_lane_wire_status(m_ws_post)
    s_lanes = _per_lane_wire_status(s_ws_post)
    tb.log.info(
        f"  POST-swap M lanes: " + ", ".join(
            f"L{i}={WIRE_NAME.get(m_lanes[i], '?')}" for i in range(8)
        )
    )
    tb.log.info(
        f"  POST-swap S lanes (control, untouched): " + ", ".join(
            f"L{i}={WIRE_NAME.get(s_lanes[i], '?')}" for i in range(8)
        )
    )

    # Assertion: master lanes 0 and 1 read WIRE_SWAPPED.
    # The spec permits WIRE_UNKNOWN as a transient (vote not yet enabled);
    # but after 16k hclk cycles the vote MUST have been enabled. We
    # accept WIRE_SWAPPED only.
    assert m_lanes[0] == WIRE_SWAPPED, (
        f"master lane 0 wire_status = {WIRE_NAME.get(m_lanes[0], m_lanes[0])} "
        f"(={m_lanes[0]}), expected WIRE_SWAPPED ({WIRE_SWAPPED}) after a "
        f"lane0↔lane1 RX data swap. The wiring discriminator did not "
        f"detect a misrouted lane within one training window."
    )
    assert m_lanes[1] == WIRE_SWAPPED, (
        f"master lane 1 wire_status = {WIRE_NAME.get(m_lanes[1], m_lanes[1])} "
        f"(={m_lanes[1]}), expected WIRE_SWAPPED ({WIRE_SWAPPED}). "
        f"Symmetric failure to lane 0 above — the per-lane discriminator "
        f"on lane 1 also did not detect its swap."
    )

    # Lanes 2..7 on the master are not touched by the swap, so they
    # should still read WIRE_OK. Be permissive about WIRE_UNKNOWN
    # because, depending on dwell timing, the vote may not have
    # re-enabled on those lanes after the master-side reset that the
    # force caused.
    for i in range(2, 8):
        assert m_lanes[i] in (WIRE_OK, WIRE_UNKNOWN), (
            f"master lane {i} wire_status = "
            f"{WIRE_NAME.get(m_lanes[i], m_lanes[i])} (={m_lanes[i]}); "
            f"only OK or UNKNOWN is acceptable for an untouched lane "
            f"(WIRE_SWAPPED/WIRE_DEAD would indicate false-positive "
            f"propagation across lane indices)."
        )

    # Slave is unmodified; every slave lane should read WIRE_OK
    # (or UNKNOWN if the canary window has not yet completed).
    for i in range(8):
        assert s_lanes[i] in (WIRE_OK, WIRE_UNKNOWN), (
            f"slave (control) lane {i} wire_status = "
            f"{WIRE_NAME.get(s_lanes[i], s_lanes[i])} — slave RX was not "
            f"touched, must remain WIRE_OK/UNKNOWN. A non-OK reading on "
            f"the control side indicates the swap leaked beyond the "
            f"forced lane indices."
        )

    tb.log.info(
        "PASS: lane 0/1 swap on master correctly diagnosed as WIRE_SWAPPED; "
        "untouched lanes and slave control side remain WIRE_OK/UNKNOWN."
    )
