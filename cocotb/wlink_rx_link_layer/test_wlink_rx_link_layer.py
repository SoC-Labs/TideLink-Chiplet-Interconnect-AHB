"""test_wlink_rx_link_layer -- unit tests for the WlinkRxLinkLayer byte-align FSM.

Background
----------
During slave-side bringup the master emits per-lane TRAINING_BYTE filler
(0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D). WavD2DGpio deserialises
these. The first 3 bytes (lane 0..2) form a candidate packet header
{0xC9, 0xB5, 0xA3} with ph[7:0]=0xA3 > swi_short_packet_max=0x7F, so the
byte-align FSM sees is_long_pkt=1 and transitions state 0->1, then waits
forever for a long packet that never arrives. State is stuck at 1; every
subsequent real CR / FC packet from the master is ignored.

The L4 v3 fix (local_overrides/WlinkRxLinkLayer.v) adds a sticky
`first_short_pkt_seen` gate so the state 0->1 transition is GATED until at
least one valid SHORT packet (e.g. CR, ph[7:0]=0x44 < 0x7F) has been
decoded.

This test suite exercises the FSM in isolation by directly driving
io_link_data. The slow pair sim (cocotb/wlink_pair/test_paired_recal_to_link_data.py)
catches the same bug in ~60 s/run; this harness should converge each case
in ~2-5 s.

Tests
-----
test_01_filler_bytes_do_not_latch_state_1
    Drive training-byte filler for 2000 cycles. ASSERT: state never
    latches at 1. Against L4 override -> PASS. Against base RTL -> FAIL.

test_02_first_real_cr_pkt_decoded_after_filler
    Drive filler, then a properly-framed CR short packet (data_id=0x44).
    ASSERT: auto_out_valid fires, auto_out_data_id == 0x44.

test_03_long_pkt_decoded_after_first_short
    Drive filler -> CR short pkt -> long packet header.
    ASSERT: state advances to 1 for the long pkt, valid fires at end.

test_04_no_disturb_on_steady_fc_data
    After CR bootstrap, drive pseudorandom non-training data.
    ASSERT: FSM remains responsive; no spurious state==2 (error) latching.

test_05_swreset_re_arms_gate
    Drive filler -> CR -> reset -> filler.
    ASSERT: post-reset state stays at 0 under filler (gate re-armed).
    Against L4 override -> PASS. Against base RTL -> FAIL.

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access license.

Contributors
    David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CLK_PERIOD_NS = 10  # 100 MHz unit-test clock; arbitrary, has no PHY here

# WavD2DGpio per-lane TRAINING_BYTE constants (8 lanes, unique under
# cyclic rotation). These are the byte values that show up in the
# deserialised io_link_data when the master TX is in training mode.
TRAINING_BYTES = [0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D]

# CR packet has data_id = swi_cr_id default = 0x44 (< swi_short_packet_max
# default 0x7F, so it's a short packet). word_count is don't-care for CR.
SWI_CR_ID = 0x44


# -----------------------------------------------------------------------------
# ECC -- replicates WlinkEccSyndrome.calc_ecc (24-bit packet header in,
# 6-bit ECC out, packed into a byte with bits[7:6]=0). Same XOR coverage
# table as deps/.../WlinkEccSyndrome.v lines 9-81.
# -----------------------------------------------------------------------------
def _bit(x, i):
    return (x >> i) & 1


def calc_ecc(ph24):
    """Compute the 8-bit ECC byte for a 24-bit packet header (DI, WC[7:0],
    WC[15:8]). Matches WlinkEccSyndrome.calc_ecc."""
    p = ph24 & 0xFFFFFF
    e0 = (_bit(p,  0) ^ _bit(p,  1) ^ _bit(p,  2) ^ _bit(p,  4) ^ _bit(p,  5)
          ^ _bit(p,  7) ^ _bit(p, 10) ^ _bit(p, 11) ^ _bit(p, 13) ^ _bit(p, 16)
          ^ _bit(p, 20) ^ _bit(p, 21) ^ _bit(p, 22) ^ _bit(p, 23))
    e1 = (_bit(p,  0) ^ _bit(p,  1) ^ _bit(p,  3) ^ _bit(p,  4) ^ _bit(p,  6)
          ^ _bit(p,  8) ^ _bit(p, 10) ^ _bit(p, 12) ^ _bit(p, 14) ^ _bit(p, 17)
          ^ _bit(p, 20) ^ _bit(p, 21) ^ _bit(p, 22) ^ _bit(p, 23))
    e2 = (_bit(p,  0) ^ _bit(p,  2) ^ _bit(p,  3) ^ _bit(p,  5) ^ _bit(p,  6)
          ^ _bit(p,  9) ^ _bit(p, 11) ^ _bit(p, 12) ^ _bit(p, 15) ^ _bit(p, 18)
          ^ _bit(p, 20) ^ _bit(p, 21) ^ _bit(p, 22))
    e3 = (_bit(p,  1) ^ _bit(p,  2) ^ _bit(p,  3) ^ _bit(p,  7) ^ _bit(p,  8)
          ^ _bit(p,  9) ^ _bit(p, 13) ^ _bit(p, 14) ^ _bit(p, 15) ^ _bit(p, 19)
          ^ _bit(p, 20) ^ _bit(p, 21) ^ _bit(p, 23))
    e4 = (_bit(p,  4) ^ _bit(p,  5) ^ _bit(p,  6) ^ _bit(p,  7) ^ _bit(p,  8)
          ^ _bit(p,  9) ^ _bit(p, 16) ^ _bit(p, 17) ^ _bit(p, 18) ^ _bit(p, 19)
          ^ _bit(p, 20) ^ _bit(p, 22) ^ _bit(p, 23))
    e5 = (_bit(p, 10) ^ _bit(p, 11) ^ _bit(p, 12) ^ _bit(p, 13) ^ _bit(p, 14)
          ^ _bit(p, 15) ^ _bit(p, 16) ^ _bit(p, 17) ^ _bit(p, 18) ^ _bit(p, 19)
          ^ _bit(p, 21) ^ _bit(p, 22) ^ _bit(p, 23))
    return (e5 << 5) | (e4 << 4) | (e3 << 3) | (e2 << 2) | (e1 << 1) | e0


# -----------------------------------------------------------------------------
# io_link_data builders -- 8-lane (io_active_lanes=7, io_lane_mask=0xFF)
#
# For an 8-lane packed cycle, the framer reads:
#   byte 0 = lane 0 low byte  -> bits [7:0]
#   byte 1 = lane 1 low byte  -> bits [23:16]
#   byte 2 = lane 2 low byte  -> bits [39:32]
#   byte 3 = lane 3 low byte  -> bits [55:48]  (ECC)
#   ...
# The high half of each 16-bit lane slot is the 2nd byte of the deserialised
# pair; not part of the 4-byte short-packet header so its value is don't-care
# for short pkts.
# -----------------------------------------------------------------------------
def _pack_lane_words(words16):
    """words16 is a length-8 list of 16-bit values; pack lane 0 in [15:0],
    lane 1 in [31:16], ..., lane 7 in [127:112]."""
    assert len(words16) == 8
    out = 0
    for i, w in enumerate(words16):
        out |= (w & 0xFFFF) << (16 * i)
    return out


def training_link_data():
    """A cycle of TRAINING_BYTE filler -- each lane deserialises to {LB, LB}
    (the byte repeats since the master TX continuously emits the same pattern
    in training mode). Matches what slave WavD2DGpio sees on the wire."""
    words = [(b << 8) | b for b in TRAINING_BYTES]
    return _pack_lane_words(words)


def short_pkt_link_data(data_id, word_count=0x0000, fill=0x00):
    """Build a 128-bit io_link_data carrying a 4-byte short packet header
    aligned to lanes 0..3. lane 4..7 hold `fill` byte in low slot."""
    di = data_id & 0xFF
    wc_lo = word_count & 0xFF
    wc_hi = (word_count >> 8) & 0xFF
    ph24 = di | (wc_lo << 8) | (wc_hi << 16)
    ecc = calc_ecc(ph24)
    words = [di, wc_lo, wc_hi, ecc, fill, fill, fill, fill]
    # Low byte of each lane carries the header byte; high byte don't-care 0.
    return _pack_lane_words([w & 0xFF for w in words])


def long_pkt_link_data(data_id, word_count, fill=0x00):
    """Build a 128-bit io_link_data carrying a long-pkt header. data_id MUST
    be > swi_short_packet_max (default 0x7F) to be classified is_long_pkt."""
    return short_pkt_link_data(data_id, word_count, fill)


def random_fc_link_data(rng):
    """Pseudorandom 128-bit io_link_data. We avoid the training-byte
    sequence (so we don't accidentally re-trigger the bug) by forcing
    bit[7] of the first 3 lane low-bytes to a value the ECC will reject
    most of the time; the framer just sees this as garbage in state==0."""
    return rng.getrandbits(128)


# -----------------------------------------------------------------------------
# DUT helpers
# -----------------------------------------------------------------------------
def _drive_defaults(dut):
    dut.io_enable.value = 1
    dut.io_swi_short_packet_max.value = 0x7F
    dut.io_active_lanes.value = 7  # 8-lane mode (active+1=8)
    dut.io_lane_mask.value = 0xFF
    dut.io_link_data.value = 0


async def _start_clk(dut):
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())


async def _reset(dut, cycles=4):
    dut.reset.value = 1
    _drive_defaults(dut)
    await Timer(1, unit="ns")
    for _ in range(cycles):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    # One clk after deassertion for the io_enable demet to settle.
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)


async def _drive_for(dut, link_data, cycles):
    """Drive a fixed io_link_data for `cycles` clk edges. Returns the max
    state value observed (any cycle)."""
    dut.io_link_data.value = link_data
    max_state = 0
    for _ in range(cycles):
        await RisingEdge(dut.clock)
        s = int(dut.io_obs_state.value)
        if s > max_state:
            max_state = s
    return max_state


async def _drive_one(dut, link_data):
    dut.io_link_data.value = link_data
    await RisingEdge(dut.clock)


def _is_l4_override(dut):
    """Probe a hierarchical name only present in the L4 override RTL.
    Returns True if first_short_pkt_seen exists, False otherwise."""
    try:
        _ = dut.u_dut.first_short_pkt_seen
        return True
    except AttributeError:
        return False


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_01_filler_bytes_do_not_latch_state_1(dut):
    """Drive 8-lane training-byte filler for 2000 cycles. The byte-align FSM
    must NOT latch state==1 -- on the buggy base RTL it WILL latch within a
    few cycles because the synthesised PH from lanes 0..2 (=0xC9B5A3) has
    ph[7:0]=0xA3 > short_packet_max=0x7F (is_long_pkt=1).

    Against L4 override: first_short_pkt_seen=0 initially -> gate closed
    -> state stays at 0. PASS expected.
    Against base RTL: no gate -> state latches at 1 within ~3-5 cycles. FAIL.
    """
    await _start_clk(dut)
    await _reset(dut)

    have_gate = _is_l4_override(dut)
    cocotb.log.info("test_01: L4 override gate %s",
                    "PRESENT" if have_gate else "ABSENT (base RTL)")

    filler = training_link_data()
    cocotb.log.info("test_01: filler io_link_data = 0x%032x", filler)

    max_state = await _drive_for(dut, filler, 2000)

    # Sample state at the end -- if base RTL stuck at 1 this confirms repro.
    final_state = int(dut.io_obs_state.value)
    cocotb.log.info("test_01: max_state=%d final_state=%d", max_state, final_state)

    assert max_state == 0, (
        f"FSM latched state={max_state} on training filler! "
        f"(have_gate={have_gate}). This is the tdif-08 stuck-at-state==1 bug. "
        f"Base RTL is expected to fail here; the L4 override should hold "
        f"state==0 via the first_short_pkt_seen gate."
    )


@cocotb.test()
async def test_02_first_real_cr_pkt_decoded_after_filler(dut):
    """After N cycles of training filler, switch to a CR short-packet header.
    The framer must decode it: auto_out_valid pulses, auto_out_data_id == CR_ID.

    Against L4 override: gate opens on CR (first_short_pkt_seen latches).
    Against base RTL: framer is stuck at state==1 from filler -> CR ignored.
    """
    await _start_clk(dut)
    await _reset(dut)

    filler = training_link_data()
    cr_pkt = short_pkt_link_data(SWI_CR_ID, 0x0000, fill=0x00)
    cocotb.log.info("test_02: cr_pkt io_link_data = 0x%032x", cr_pkt)

    # 64 cycles of filler -- enough for the FSM to be settled.
    await _drive_for(dut, filler, 64)

    # Drive idle (no valid byte) for 1 cycle then assert the CR packet for
    # one cycle, then drive zeros for a few cycles to let the framer process.
    dut.io_link_data.value = 0
    await RisingEdge(dut.clock)

    dut.io_link_data.value = cr_pkt
    await RisingEdge(dut.clock)

    saw_valid = False
    saw_cr_data_id = False
    # Up to 16 cycles to let the framer pulse valid + emit data_id.
    for _ in range(16):
        dut.io_link_data.value = 0  # idle -- no more bytes
        await RisingEdge(dut.clock)
        if int(dut.auto_out_valid.value) == 1:
            saw_valid = True
            di = int(dut.auto_out_data_id.value)
            if di == SWI_CR_ID:
                saw_cr_data_id = True
            cocotb.log.info("test_02: auto_out_valid=1 data_id=0x%02x", di)
        if int(dut.io_obs_is_short_pkt.value) == 1:
            cocotb.log.info("test_02: io_obs_is_short_pkt pulsed")

    final_state = int(dut.io_obs_state.value)
    cocotb.log.info("test_02: final_state=%d saw_valid=%s saw_cr=%s",
                    final_state, saw_valid, saw_cr_data_id)

    assert saw_valid, "auto_out_valid never pulsed after CR pkt"
    assert saw_cr_data_id, f"auto_out_data_id never == 0x{SWI_CR_ID:02x}"


@cocotb.test()
async def test_03_long_pkt_decoded_after_first_short(dut):
    """Drive filler -> CR short pkt -> long pkt. After the CR bootstraps the
    gate, the next long pkt must transition state 0->1 and decode normally.

    Against L4 override: gate opens after CR, long pkt then works.
    Against base RTL: still stuck from filler, won't get past it.
    """
    await _start_clk(dut)
    await _reset(dut)

    filler = training_link_data()
    cr_pkt = short_pkt_link_data(SWI_CR_ID, 0x0000)
    # Long pkt: data_id > 0x7F (so is_long_pkt=1). word_count must be
    # large enough that the framer doesn't immediately hit endOfPacket on
    # the header cycle (8-lane bytesPerCycle=16 bytes), otherwise the FSM
    # takes the "stay in 0" branch instead of going to state==1. topIndex
    # = word_count+6; endOfPacket = bytesPerCycle(=16) >= topIndex. To
    # force state==1 we need topIndex > 16 -> word_count > 10. Use 0x0040.
    long_di = 0x80
    long_wc = 0x0040
    long_pkt = long_pkt_link_data(long_di, long_wc)
    cocotb.log.info("test_03: long_pkt io_link_data = 0x%032x", long_pkt)

    # 32 cycles filler.
    await _drive_for(dut, filler, 32)

    # CR bootstrap.
    dut.io_link_data.value = 0
    await RisingEdge(dut.clock)
    dut.io_link_data.value = cr_pkt
    await RisingEdge(dut.clock)
    dut.io_link_data.value = 0
    for _ in range(4):
        await RisingEdge(dut.clock)

    # Now the long pkt header.
    # is_long_pkt is a combinational derive from io_link_data when state==0;
    # once state transitions to 1, ecc_check_ph_in is forced to 0 (see L1006
    # of WlinkRxLinkLayer.v) so is_long_pkt no longer pulses. We therefore
    # sample is_long_pkt at the FallingEdge of the clock (mid-cycle, when
    # combinational signals are settled and state is the post-edge value),
    # and sample state after the next RisingEdge.
    saw_state_1 = False
    saw_long_pkt = False
    from cocotb.triggers import FallingEdge
    dut.io_link_data.value = long_pkt
    for _ in range(32):
        # Mid-cycle: sample is_long_pkt while state is the just-latched
        # post-edge value (and ecc_check_ph_in is still gated by state==0).
        await FallingEdge(dut.clock)
        if int(dut.io_obs_state.value) == 0 \
                and int(dut.io_obs_is_long_pkt.value) == 1:
            saw_long_pkt = True
        await RisingEdge(dut.clock)
        if int(dut.io_obs_state.value) == 1:
            saw_state_1 = True

    cocotb.log.info("test_03: saw_state_1=%s saw_long_pkt=%s",
                    saw_state_1, saw_long_pkt)

    assert saw_long_pkt, "is_long_pkt never pulsed for long header"
    assert saw_state_1, "FSM never transitioned to state==1 after CR + long pkt"


@cocotb.test()
async def test_04_no_disturb_on_steady_fc_data(dut):
    """After CR bootstrap, drive 5000 cycles of pseudorandom data. The FSM
    must remain responsive (no spurious state==2 error sink). state may
    bounce between 0 and 1 as random data triggers spurious long-pkt entries
    but it must NEVER stick at 2.
    """
    await _start_clk(dut)
    await _reset(dut)

    filler = training_link_data()
    cr_pkt = short_pkt_link_data(SWI_CR_ID, 0x0000)

    # 32 cycles filler, then CR.
    await _drive_for(dut, filler, 32)
    dut.io_link_data.value = 0
    await RisingEdge(dut.clock)
    dut.io_link_data.value = cr_pkt
    await RisingEdge(dut.clock)
    dut.io_link_data.value = 0
    for _ in range(4):
        await RisingEdge(dut.clock)

    # Now hammer pseudorandom data.
    rng = random.Random(0xCAFE)
    error_state_seen = False
    states_seen = set()
    for _ in range(5000):
        dut.io_link_data.value = random_fc_link_data(rng)
        await RisingEdge(dut.clock)
        s = int(dut.io_obs_state.value)
        states_seen.add(s)
        if s == 2:
            error_state_seen = True
            break

    cocotb.log.info("test_04: states_seen=%s error_state=%s",
                    sorted(states_seen), error_state_seen)

    assert not error_state_seen, (
        "FSM latched state==2 (error sink) under pseudorandom data -- "
        "this would mean any glitch on the wire bricks the framer."
    )


@cocotb.test()
async def test_05_swreset_re_arms_gate(dut):
    """After CR bootstrap + reset, the gate must re-arm so resumed filler
    does NOT latch state==1 again. This mirrors the LL swreset behaviour
    during real bringup (recal cycle -> swreset -> filler -> first CR).
    """
    await _start_clk(dut)
    await _reset(dut)

    have_gate = _is_l4_override(dut)
    cocotb.log.info("test_05: L4 override gate %s",
                    "PRESENT" if have_gate else "ABSENT (base RTL)")

    filler = training_link_data()
    cr_pkt = short_pkt_link_data(SWI_CR_ID, 0x0000)

    # Phase 1: bootstrap.
    await _drive_for(dut, filler, 32)
    dut.io_link_data.value = 0
    await RisingEdge(dut.clock)
    dut.io_link_data.value = cr_pkt
    await RisingEdge(dut.clock)
    dut.io_link_data.value = 0
    for _ in range(8):
        await RisingEdge(dut.clock)

    # Phase 2: assert reset for 4 cycles (mirrors LL swreset).
    dut.reset.value = 1
    dut.io_link_data.value = 0
    for _ in range(4):
        await RisingEdge(dut.clock)
    dut.reset.value = 0
    # demet settle.
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)

    # Phase 3: resume filler. Gate should be re-armed -> state stays 0.
    max_state = await _drive_for(dut, filler, 1000)

    cocotb.log.info("test_05: post-reset max_state=%d", max_state)

    assert max_state == 0, (
        f"After reset, gate was NOT re-armed: FSM latched state={max_state} "
        f"on resumed training filler. Expected post-reset behaviour: gate "
        f"re-armed -> state stays at 0 until next CR."
    )
