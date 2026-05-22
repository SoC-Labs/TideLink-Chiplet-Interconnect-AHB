"""
test_t3a_realign — pin the WavD2DGpioRx T3a self-aligning RX (USE_T3A=1).

SoC Labs §9 T3a (2026-05-19). Per-lane WavD2DGpioRx hunts for the lane's
TRAINING_BYTE in the io_pad bit stream and slips `count` once per
io_por_reset so subsequent deserialised words align to the byte boundary.
This kills the per-deploy 16-cycle word-boundary lottery the HW saw 12
deploys in a row (master/slave 0xff hits NEVER SIMULTANEOUSLY because
each side's count started at role-lock + random SSH skew).

The tb_top instantiates 8 parallel WavD2DGpioRx DUTs, one per lane, each
with the lane-specific TRAINING_BYTE constant WavD2DGpio.v overrides at
instantiation (lane 0 = 0xA3 ... lane 7 = 0x2D). For each lane × each of
4 random initial count-skew values (32 sub-checks total), the test:

  1. Holds io_por_reset asserted while priming a free-running periodic
     byte stream on io_pad (each cycle puts bit `(t + skew) mod 8` of
     the lane's training byte on the lane's io_pad input).
  2. Releases io_por_reset (the FSM's settle counter starts).
  3. Waits ~ (SETTLE_CYCLES + a safe HUNT margin + a couple of
     io_link_clk periods) cycles.
  4. Samples io_link_data for that lane.

The assertion: the four sampled io_link_data values per lane are EQUAL.
That is the T3a contract: io_link_data is INVARIANT under the initial
count-skew (the FSM realigned to the SAME byte-boundary in all 4 cases).
The exact 16-bit value depends on bit-order conventions inside the
deserialiser (link_data_pad_clk[i] sampled at count==i) and our test-side
driver convention (MSB-first), and is not load-bearing for this test —
invariance is.

We additionally sanity-check that the captured 16-bit value has both
bytes equal (high byte == low byte) — i.e. the deserialiser is seeing
the SAME pattern repeat in the two byte windows of the 16-bit word.
That holds for any periodic 8-bit stream regardless of bit-order
convention, so it is a strong "we're actually receiving a periodic
byte" sanity check that does NOT depend on MSB-first vs LSB-first
conventions or on the exact byte value seen. The two-byte-equal check
catches the case where the deserialiser is sampling noise (high byte
random vs low byte random) or where the FSM picked an inconsistent
rotation that splits a byte across the word boundary.

Run (clean sim_build first; VCS does NOT rebuild simv on RTL edits):
    rm -rf cocotb/wavd2d_gpiorx_t3a/sim_build
    make -C cocotb/wavd2d_gpiorx_t3a

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# Per-lane training bytes (same constants WavD2DGpio.v wires up to
# gpiotx_<N>.io_training_pattern and as the per-instance TRAINING_BYTE
# parameter override on gpiorx_<N>). Period-8 aperiodic under cyclic byte
# rotation — guarantees the RX hunt FSM has exactly one matching rotation.
LANE_BYTES = [0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D]


def is_periodic_byte_word(word):
    """True iff the 16-bit word is two equal bytes (hi == lo). Strong
    convention-free sanity that the deserialiser captured a periodic
    byte stream, NOT noise."""
    hi = (word >> 8) & 0xFF
    lo = word & 0xFF
    return hi == lo


# Matches the RTL's SETTLE_CYCLES + MAX_HUNT in WavD2DGpioRx.v. We wait at
# least SETTLE + 256 cycles (well under MAX_HUNT=1023) so the FSM has
# definitely seen a match for the period-8 byte (a match must come within
# 8 cycles of S_HUNT entry).
WAIT_AFTER_POR_CYCLES = 64 + 256 + 64    # settle + hunt margin + a few link_clk windows


async def _start_clock(dut):
    """Start the io_pad_clk. cocotb 50 MHz is fine — the t3a logic is
    fully synchronous so frequency doesn't matter."""
    cocotb.start_soon(Clock(dut.io_pad_clk, 10, units="ns").start())


async def _apply_por_and_drive(dut, lane, byte, skew, bits_to_drive):
    """Apply POR for the given lane while driving a periodic byte stream.
    Then release POR and continue driving the stream for `bits_to_drive`
    pad_clk cycles. All other lanes' io_pad bits are driven to 0 (the
    DUTs are independent, but we'd rather not leave them X).

    Bit ordering: at io_pad_clk tick `t` we put bit ((t + skew) % 8) of
    the byte on io_pad[lane]. The MSB-first vs LSB-first convention does
    NOT affect the invariance property — whatever ordering, the FSM and
    deserialiser see a consistent stream and the captured word is the
    same modulo rotation. We pick the bit MSB-first within byte (bit 7
    first) to mirror typical serial-link conventions.
    """
    # Sanity: lane in [0..7], byte 0..255, skew 0..7.
    assert 0 <= lane < 8
    assert 0 <= byte < 256
    assert 0 <= skew < 8

    # ---- Phase 1: POR=1, drive bits for 32 cycles to fill the shifter
    # ----          history with the actual byte stream (so the moment POR
    # ----          deasserts, the shifter is NOT 0x00).
    dut.io_por_reset.value = 1
    # Clear all lane pads to a known 0 (default for un-driven lanes).
    pad_val = 0
    dut.io_pad.value = pad_val
    await RisingEdge(dut.io_pad_clk)
    for t in range(32):
        bit_idx = (t + skew) & 0x7
        # MSB-first: send bit (7 - bit_idx) of byte.
        bit = (byte >> (7 - bit_idx)) & 0x1
        pad_val = (pad_val & ~(1 << lane)) | (bit << lane)
        dut.io_pad.value = pad_val
        await RisingEdge(dut.io_pad_clk)

    # ---- Phase 2: deassert POR, keep streaming.
    dut.io_por_reset.value = 0
    for t in range(32, 32 + bits_to_drive):
        bit_idx = (t + skew) & 0x7
        bit = (byte >> (7 - bit_idx)) & 0x1
        pad_val = (pad_val & ~(1 << lane)) | (bit << lane)
        dut.io_pad.value = pad_val
        await RisingEdge(dut.io_pad_clk)


def _read_link_data(dut, lane):
    """Read the 16-bit deserialised word for the given lane."""
    return (int(dut.io_link_data.value) >> (16 * lane)) & 0xFFFF


@cocotb.test()
async def test_t3a_invariance(dut):
    """For each lane × 4 random initial count-skew values, drive the
    lane's training-byte stream with that skew and verify io_link_data
    settles to the SAME 16-bit value across all 4 skews. This is the T3a
    contract: kill the per-deploy 16-cycle word-boundary lottery."""
    rng = random.Random(0xC0FFEE)
    await _start_clock(dut)

    # Initial idle so the clock is alive.
    dut.io_por_reset.value = 1
    dut.io_pad.value = 0
    await ClockCycles(dut.io_pad_clk, 4)

    # Track all (lane, skew, captured_word) for the final summary print.
    results = []  # list of (lane, byte, skew, captured)
    skew_choices = {
        # Distinct random skews per lane so the test exercises diverse
        # initial conditions. Including 0 keeps one anchor that is the
        # "do nothing" / "byte boundary lines up" reference where the
        # slip should be 0.
        ln: [0] + rng.sample([s for s in range(1, 8)], 3)
        for ln in range(8)
    }

    # Per-lane: which 16-bit word did each (skew) produce?
    per_lane_captured = {ln: {} for ln in range(8)}

    for lane in range(8):
        byte = LANE_BYTES[lane]
        dut._log.info(
            f"---- lane {lane}: TRAINING_BYTE=0x{byte:02X}, "
            f"skews {skew_choices[lane]} ----"
        )
        for skew in skew_choices[lane]:
            # Apply POR + drive the stream for enough cycles that the
            # FSM has SETTLED, HUNTED, found the match, slipped count,
            # and deserialised at least one fresh 16-bit word.
            await _apply_por_and_drive(
                dut, lane, byte, skew, bits_to_drive=WAIT_AFTER_POR_CYCLES
            )
            captured = _read_link_data(dut, lane)
            per_lane_captured[lane][skew] = captured
            results.append((lane, byte, skew, captured))
            dut._log.info(
                f"  lane {lane} skew={skew}: io_link_data = 0x{captured:04X}"
                f"{'  (hi==lo, periodic byte detected)' if is_periodic_byte_word(captured) else '  (hi!=lo, NOT periodic byte — broken capture)'}"
            )
            # Brief idle between sub-tests, with POR re-asserted, to
            # ensure the next sub-test starts from a clean slate.
            dut.io_por_reset.value = 1
            dut.io_pad.value = 0
            await ClockCycles(dut.io_pad_clk, 8)

    # ---- Assertion 1: per-lane invariance under skew ----------------------
    # The captured word must be identical across all 4 skews for a given
    # lane. THIS is the T3a contract being pinned. If it fails, the FSM
    # is NOT correctly aligning to the byte boundary.
    failures = []
    for lane in range(8):
        captures = list(per_lane_captured[lane].values())
        # All-equal check.
        first = captures[0]
        for sk, cap in per_lane_captured[lane].items():
            if cap != first:
                failures.append(
                    f"lane {lane} (byte 0x{LANE_BYTES[lane]:02X}): "
                    f"skew={sk} captured 0x{cap:04X}, but skew=0 captured "
                    f"0x{first:04X} — T3a alignment NOT invariant under skew"
                )

    # ---- Assertion 2: captured word is two equal bytes (hi == lo) --------
    # Convention-free sanity check: the deserialiser must see the SAME
    # 8-bit pattern in both byte windows of the 16-bit word, which holds
    # for ANY periodic 8-bit io_pad stream regardless of MSB-first vs
    # LSB-first conventions or which rotation the hunt FSM picked.
    # If hi != lo, the deserialiser is splitting the byte across the
    # word boundary (alignment failure) or sampling random noise.
    for lane in range(8):
        byte = LANE_BYTES[lane]
        for sk, cap in per_lane_captured[lane].items():
            if not is_periodic_byte_word(cap):
                failures.append(
                    f"lane {lane} skew={sk}: io_link_data 0x{cap:04X} is "
                    f"NOT two equal bytes (hi={cap>>8:02X}, lo={cap&0xFF:02X}) "
                    f"— deserialiser is not capturing a periodic byte stream"
                )
            # Also disallow degenerate values 0x0000 and 0xFFFF: even
            # though both ARE periodic, they are the "no stream" /
            # "stuck" noise floor that would slip past the hi==lo check
            # for an open pad or fail-stuck-at line.
            if cap in (0x0000, 0xFFFF):
                failures.append(
                    f"lane {lane} skew={sk}: io_link_data 0x{cap:04X} is "
                    f"a degenerate stuck-at value — lane appears to not be "
                    f"receiving the training-byte stream at all"
                )

    # ---- Final summary table ---------------------------------------------
    dut._log.info("=" * 70)
    dut._log.info("T3a realign — per-lane captured io_link_data summary:")
    dut._log.info("=" * 70)
    for lane in range(8):
        byte = LANE_BYTES[lane]
        caps = per_lane_captured[lane]
        uniq = set(caps.values())
        dut._log.info(
            f"  lane {lane} byte=0x{byte:02X}: "
            f"{ {sk: f'0x{v:04X}' for sk, v in caps.items()} }  "
            f"=> {len(uniq)} unique value(s)"
        )
    dut._log.info("=" * 70)
    if failures:
        for f in failures:
            dut._log.error(f)
        assert False, (
            f"T3a invariance test failed with {len(failures)} issue(s) — "
            f"see preceding error logs. Per-lane skew-invariance is the "
            f"load-bearing T3a contract; failure means the FSM is not "
            f"correctly aligning `count` to the byte boundary."
        )

    dut._log.info(
        f"OK: T3a invariance holds for all 8 lanes × {len(skew_choices[0])} "
        f"skews — io_link_data is identical across skews per lane, and is "
        f"two equal bytes (hi == lo, non-degenerate). The hunt FSM is "
        f"correctly slipping `count` to align to the byte boundary."
    )
