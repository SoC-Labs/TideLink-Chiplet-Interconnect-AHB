"""test_lane_checker_prbs — unit tests for the PRBS-7 sync-by-prediction
lock-detect path in tidelink_lane_checker (feat/calibrator-prbs).

Test coverage:
  * test_01_locks_on_matching_prbs_stream
      Drive every lane with its OWN lane-tag PRBS stream (the same stream
      TX would emit). All 8 lanes must reach `locked` within a few cycles.

  * test_02_random_data_does_not_lock
      Drive every lane with pseudo-random non-PRBS data (random bytes that
      do NOT follow PRBS-7 evolution). No lane should lock.

  * test_03_cross_lane_stream_rejected
      Drive lane 0 with lane 7's stream (correct PRBS-7 sequence and seed,
      but WRONG lane-tag XOR). Lane 0 must NOT lock; lane 7 (driven with
      its own stream) MUST lock.

  * test_04_constant_pattern_does_not_lock
      Drive every lane with the LEGACY {pattern, pattern} word. The new
      checker must NOT lock on this (eye-data design intent: the lock now
      requires bit transitions, not a constant period-2 byte).

Run:
    cd /home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter
    source set_env.sh
    rm -rf cocotb/tidelink_lane_checker_prbs/sim_build
    make -C cocotb/tidelink_lane_checker_prbs
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


PATTERNS = [0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D]
LOCK_THRESH = 4  # matches tb_top.sv


def _seed_for(tag):
    """PRBS-7 seed for a given lane tag, matching the TX/RX initial seed."""
    return ((tag >> 1) & 0x7F) | 0x01


def _prbs7_advance(state):
    """One advance of the Fibonacci PRBS-7 LFSR (poly x^7 + x^6 + 1).
    Returns the NEW 7-bit state. The OUTPUT BIT emitted on this step is
    `state[6]` (the bit BEFORE this advance) — matches the lookahead RTL
    convention (`word_out[k] = s[k][6]`).
    """
    fb = ((state >> 6) ^ (state >> 5)) & 0x1
    return ((state << 1) & 0x7F) | fb


def _next_prbs_word(state):
    """Compute the 16-bit PRBS word emitted from `state`, and the state
    AFTER 16 advances. Matches tidelink_prbs7_lookahead16 exactly.
    """
    s = state
    word = 0
    for k in range(16):
        bit = (s >> 6) & 0x1   # output bit at step k = s[k][6]
        word |= (bit << k)
        s = _prbs7_advance(s)
    return word, s


class PrbsLane:
    """Free-running per-lane PRBS-7 generator, output XORed with {tag,tag}."""
    def __init__(self, tag):
        self.tag    = tag & 0xFF
        self.state  = _seed_for(self.tag)
        self.tagw16 = (self.tag << 8) | self.tag

    def next_word(self):
        word, self.state = _next_prbs_word(self.state)
        return (word ^ self.tagw16) & 0xFFFF


def _pack_lane_words(words_per_lane):
    """Pack 8 lane words into a 128-bit lane_data bus."""
    packed = 0
    for i, w in enumerate(words_per_lane):
        packed |= (w & 0xFFFF) << (16 * i)
    return packed


async def _start_and_reset(dut, init_words_packed=None):
    """Start clock, hold rst, optionally drive one cycle of valid PRBS data
    on lane_data so that the FIRST post-reset clk edge sees expected_word
    == word_in (the reseed-on-mismatch path is not exercised immediately).
    The caller must continue driving fresh words on every subsequent edge."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())  # 100 MHz
    dut.rst.value       = 1
    dut.lane_data.value = init_words_packed if init_words_packed is not None else 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    # lane_data is still init_words_packed at this point. The next rising
    # edge with rst=0 will sample that word against the seeded predictor.
    await RisingEdge(dut.clk)


# -----------------------------------------------------------------------------
# Test 01 — every lane driven with its own correct PRBS stream MUST lock.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_01_locks_on_matching_prbs_stream(dut):
    # Build PrbsLane generators and pre-compute the FIRST PRBS word per lane,
    # then drive it on lane_data while rst is high. This way the FIRST
    # post-reset clk edge sees expected_word == word_in and the predictor
    # locks in lockstep (no reseed-on-mismatch path is exercised).
    lanes = [PrbsLane(p) for p in PATTERNS]
    first_words = [ln.next_word() for ln in lanes]  # advances lane state past word 0
    await _start_and_reset(dut, init_words_packed=_pack_lane_words(first_words))

    # Run a few cycles and inspect when each lane locks.
    locked_at = [None] * 8
    for cyc in range(64):
        words = [ln.next_word() for ln in lanes]
        dut.lane_data.value = _pack_lane_words(words)
        await RisingEdge(dut.clk)
        ll = int(dut.lane_locked.value)
        # Debug: peek lane 0 internal state (gen-block access via getattr).
        for i in range(8):
            if locked_at[i] is None and ((ll >> i) & 0x1):
                locked_at[i] = cyc
                dut._log.info(
                    f"lane {i} (tag=0x{PATTERNS[i]:02X}) locked at cycle {cyc}"
                )

    fails = [i for i in range(8) if locked_at[i] is None]
    assert not fails, (
        f"test_01 FAIL: lanes {fails} never locked on their own PRBS stream. "
        f"locked_at = {locked_at}"
    )
    dut._log.info(f"test_01 PASS: all lanes locked. locked_at = {locked_at}")


# -----------------------------------------------------------------------------
# Test 02 — random (non-PRBS) data must NOT lock.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_02_random_data_does_not_lock(dut):
    await _start_and_reset(dut, init_words_packed=0)

    # Deterministic non-PRBS bytes per cycle (avoid accidentally hitting a
    # short PRBS subsequence). Use a counter+constant per lane.
    seen_locked = 0x00
    for cyc in range(256):
        words = []
        for i in range(8):
            # 16-bit junk = ((cyc * (i+1)) ^ PATTERNS[i]) repeated.
            v = ((cyc * 0x9E37 + i * 0x1357) ^ (PATTERNS[i] << 4)) & 0xFFFF
            words.append(v)
        dut.lane_data.value = _pack_lane_words(words)
        await RisingEdge(dut.clk)
        seen_locked |= int(dut.lane_locked.value)

    assert seen_locked == 0, (
        f"test_02 FAIL: at least one lane locked on non-PRBS junk. "
        f"lane_locked bits seen = 0x{seen_locked:02X}"
    )
    dut._log.info("test_02 PASS: no lane locked on non-PRBS data.")


# -----------------------------------------------------------------------------
# Test 03 — lane 0 fed lane 7's stream must NOT lock.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_03_cross_lane_stream_rejected(dut):
    # Lane 0 driven by lane-7's stream; lanes 1..7 by their own.
    lanes = [PrbsLane(PATTERNS[7])]  # lane 0 input = lane-7 stream
    for i in range(1, 8):
        lanes.append(PrbsLane(PATTERNS[i]))
    first_words = [ln.next_word() for ln in lanes]
    await _start_and_reset(dut, init_words_packed=_pack_lane_words(first_words))

    saw_lane0_locked = False
    saw_lane7_locked = False
    for cyc in range(128):
        words = [ln.next_word() for ln in lanes]
        dut.lane_data.value = _pack_lane_words(words)
        await RisingEdge(dut.clk)
        ll = int(dut.lane_locked.value)
        if (ll >> 0) & 0x1:
            saw_lane0_locked = True
        if (ll >> 7) & 0x1:
            saw_lane7_locked = True

    assert not saw_lane0_locked, (
        "test_03 FAIL: lane 0 locked while being fed lane-7's stream. "
        "Lane-uniqueness invariant violated — the per-lane LANE_TAG XOR "
        "strip step did not reject the wrong-lane stream."
    )
    assert saw_lane7_locked, (
        "test_03 FAIL: lane 7 (driven with its own stream) did not lock — "
        "stimulus issue, the test cannot validate cross-lane rejection."
    )
    dut._log.info(
        "test_03 PASS: lane 0 did NOT lock on lane-7 stream; lane 7 locked OK."
    )


# -----------------------------------------------------------------------------
# Test 04 — legacy constant {pattern, pattern} word must NOT lock.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_04_constant_pattern_does_not_lock(dut):
    await _start_and_reset(dut, init_words_packed=0)

    # Drive each lane with the static {pattern, pattern} word (the
    # pre-eye-data behaviour). The new PRBS predictor should reject this.
    constant_words = [(PATTERNS[i] << 8) | PATTERNS[i] for i in range(8)]

    seen_locked = 0x00
    for _ in range(256):
        dut.lane_data.value = _pack_lane_words(constant_words)
        await RisingEdge(dut.clk)
        seen_locked |= int(dut.lane_locked.value)

    assert seen_locked == 0, (
        f"test_04 FAIL: at least one lane locked on the legacy constant "
        f"{{P,P}} pattern. lane_locked seen = 0x{seen_locked:02X}. The "
        f"new PRBS predictor must NOT accept a constant period-2 byte — "
        f"the calibrator should only see a lock when the stream exhibits "
        f"PRBS-7 bit transitions."
    )
    dut._log.info("test_04 PASS: legacy {P,P} constant rejected by checker.")
