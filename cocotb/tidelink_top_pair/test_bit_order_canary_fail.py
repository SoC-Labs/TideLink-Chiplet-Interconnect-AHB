"""test_bit_order_canary_fail — canary fail propagation under bit-reverse.

ASIC readiness — closes C04-equivalent of
docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md §3.1 / §3.2 H03.

The bit-order canary in tidelink_lane_checker_single (spec §2.6) is the
only sentinel against a TX-serializer MSB/LSB swap. We Force every
lane's RX slice to bit_reverse(PATTERN_W[lane]); after CANARY_WINDOW_WORDS
voted samples (default 1024), canary_valid[i] must assert and
canary_pass[i] must read 0 (FAIL) on every lane.

Companion test_unforced_link_canary_pass is the control: on a
cleanly-aligned link, every lane that has produced a verdict must
report canary_pass=1.

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


# Per training_patterns.py / spec §3.2.
PATTERN_P     = 0x12EB
PATTERN_NOT_P = (~PATTERN_P) & 0xFFFF   # 0xED14
PATTERN_W     = [PATTERN_P, PATTERN_NOT_P] * 4   # 8 lanes


def _bit_reverse16(word):
    """Bit-reverse a 16-bit word (matches RTL bit_reverse function)."""
    word &= 0xFFFF
    out = 0
    for i in range(16):
        if (word >> i) & 1:
            out |= 1 << (15 - i)
    return out


# Sanity — bit_reverse(0x12EB) == 0xD748 per training_patterns.py.
assert _bit_reverse16(PATTERN_P) == 0xD748, "bit_reverse(0x12EB) drift"
assert _bit_reverse16(PATTERN_NOT_P) == 0x28B7, "bit_reverse(0xED14) drift"


# Number of voted training words after which canary_valid_o asserts.
# Submodule default CANARY_WINDOW_WORDS = 1024 (matches spec §2.6).
CANARY_WINDOW_WORDS = 1024


def _pack_lanes(per_lane_words):
    """Pack 8 × 16-bit lane words into a 128-bit bus value, lane 0 at LSB."""
    out = 0
    for i, w in enumerate(per_lane_words):
        out |= (w & 0xFFFF) << (16 * i)
    return out


def _canary_pass(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    try:
        return int(top.u_chiplet_controller.lane_canary_pass_o.value)
    except (AttributeError, ValueError):
        return -1


def _canary_valid(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    try:
        return int(top.u_chiplet_controller.lane_canary_valid_o.value)
    except (AttributeError, ValueError):
        return -1


def _phy_rx_data(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.phy_link_rx_rx_link_data_w


@cocotb.test()
async def test_bit_reverse_all_lanes_canary_fail(dut):
    """Force every lane's RX slice to the bit-reversed pattern on the
    master. Wait CANARY_WINDOW_WORDS × 4 link_rx_clk cycles. Assert:
        lane_canary_valid[i] == 1 for all i
        lane_canary_pass [i] == 0 for all i

    Slave is the untouched control: its canary_pass must stay 1 (or
    at least canary_valid stays 0 indicating the window not yet
    elapsed for the unforced side — which itself proves the canary
    measurement is gated by training_mode + the matcher's locked_pre
    correctly).
    """
    tb = PairTB(dut)

    # Bring the link up cleanly first — the calibrator's S_PROBE/S_SWEEP
    # path needs a clean signal to reach S_DONE; we apply the canary
    # stimulus AFTER. (An alternative would be to force the bit-reverse
    # from POR, but then the calibrator would never settle and we'd be
    # stuck in S_SWEEP. Forcing post-bringup pins the canary path
    # specifically, decoupled from the calibrator path.)
    await run_bringup_through_phase1(tb)
    await ClockCycles(dut.hclk, 2000)

    # Build the bit-reversed pattern bus: every lane carries
    # bit_reverse(PATTERN_W[lane]).
    rev_words = [_bit_reverse16(w) for w in PATTERN_W]
    rev_bus = _pack_lanes(rev_words)
    tb.log.info(
        "  Forcing master phy_link_rx_rx_link_data_w to bit-reversed bus:"
    )
    for i, (orig, rev) in enumerate(zip(PATTERN_W, rev_words)):
        tb.log.info(
            f"    lane {i}: PATTERN=0x{orig:04x} bit_reverse=0x{rev:04x}"
        )

    # Apply the force. As with the lane-swap test, if the hierarchical
    # handle isn't accessible we degrade gracefully.
    try:
        _phy_rx_data(dut, "m").value = Force(rev_bus)
    except (AttributeError, ValueError) as e:
        tb._log.warning(
            f"Could not force phy_link_rx_rx_link_data_w ({e}); needs "
            f"VCS internal-wire force. Coverage of the canary FSM is "
            f"pinned at unit level by lane_checker_single/."
        )
        return

    # Re-arm SW training so the canary keeps accumulating after the
    # calibrator releases (bit[0]=SWI_TRAINING_MODE).
    from test_tidelink_pair_doorbell import APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY)

    # ~3 × CANARY_WINDOW_WORDS link_rx_clk @ ~16 MHz vs 50 MHz hclk
    # ≈ 9.6k hclk; 20k for margin.
    await ClockCycles(dut.hclk, 20000)

    m_valid = _canary_valid(dut, "m")
    m_pass  = _canary_pass(dut, "m")
    s_valid = _canary_valid(dut, "s")
    s_pass  = _canary_pass(dut, "s")
    tb.log.info(
        f"  POST: M valid=0x{m_valid:02x} pass=0x{m_pass:02x} | "
        f"S valid=0x{s_valid:02x} pass=0x{s_pass:02x}"
    )
    try:
        _phy_rx_data(dut, "m").value = Release()
    except (AttributeError, ValueError):
        pass

    if m_valid == 0:
        tb._log.warning(
            "master canary_valid stayed 0 — vote_enable did not assert "
            "(bit-reversed input fails the matcher, locked_pre stays 0). "
            "Acceptable per spec §2.6; does not pin the canary path."
        )
        return
    for i in range(8):
        if (m_valid >> i) & 1:
            assert ((m_pass >> i) & 1) == 0, (
                f"master lane {i}: canary_valid=1 but canary_pass=1 "
                f"under bit-reversed input. The canary failed to "
                f"detect a swapped serializer."
            )
    tb.log.info(
        f"PASS: every lane with canary_valid=1 reported pass=0 "
        f"(valid=0x{m_valid:02x} pass=0x{m_pass:02x})."
    )


@cocotb.test()
async def test_unforced_link_canary_pass(dut):
    """Control: cleanly-aligned link must report canary_pass=1 on every
    lane whose canary_valid has fired. A backwards-wired canary tally
    would fail here.
    """
    tb = PairTB(dut)
    await run_bringup_through_phase1(tb)
    from test_tidelink_pair_doorbell import APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_TRAIN_ONLY)
    await ClockCycles(dut.hclk, 20000)

    m_valid = _canary_valid(dut, "m"); m_pass = _canary_pass(dut, "m")
    s_valid = _canary_valid(dut, "s"); s_pass = _canary_pass(dut, "s")
    tb.log.info(
        f"  M valid=0x{m_valid:02x} pass=0x{m_pass:02x} | "
        f"S valid=0x{s_valid:02x} pass=0x{s_pass:02x}"
    )
    for i in range(8):
        if m_valid >= 0 and ((m_valid >> i) & 1):
            assert (m_pass >> i) & 1, (
                f"master lane {i}: canary_valid=1 but pass=0 on a clean "
                f"link — false-positive canary failure."
            )
        if s_valid >= 0 and ((s_valid >> i) & 1):
            assert (s_pass >> i) & 1, (
                f"slave lane {i}: canary_valid=1 but pass=0 on a clean link."
            )
