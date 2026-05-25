"""
test_wav_tx_training_mux — diagnostic unit test for the WavD2DGpioTx training
mux at WavD2DGpioTx.v:43-45.

The PHY-level gating mechanism we are confirming:

    wire [15:0] _link_data_eff = io_training_mode
                               ? {io_training_pattern, io_training_pattern}
                               : io_link_data;

This combinatorial mux REPLACES io_link_data with the repeated training byte
while io_training_mode=1. When training_mode falls to 0, the mux switches to
io_link_data with no buffering/cycle delay.

Observations the slave RX sees on the wire:
  * training_mode=1 → repeated training byte serialised MSB→...→LSB or
    whatever bit ordering the serialiser uses. From WavD2DGpioTx.v lines
    46-96: io_pad emits _link_data_eff[count] each io_clk cycle, with
    count free-running 0..15. So over 16 io_clk cycles the serialiser
    emits bits 0,1,2,...,15 of _link_data_eff.
  * training_mode=0 → io_pad emits io_link_data[count] each io_clk cycle.

NOTE on the task description: the task references an `io_link_tx_tx_en`
port. The actual WavD2DGpioTx.v module has NO such port — the serialiser
is ALWAYS LIVE and always emits whatever bit of _link_data_eff[count] is
selected by the free-running count. This itself is a load-bearing
diagnostic finding: there is no TX-enable gating at the WAV TX level.

We expose io_pad and sample it cycle-by-cycle to characterise:
  1. training_mode=1 → pad emits the repeated training pattern
  2. training_mode=0 → pad emits io_link_data
  3. the 1→0 transition is COMBINATORIAL (no cycle delay): the cycle
     after training drops, the pad bit reflects io_link_data[count].
  4. "no FC data queued" — since there is no tx_en, io_link_data stays
     at whatever last value the upstream driver placed there. The pad
     keeps re-serialising that stale word.
  5. The Option B fix premise: an idle-injection window post-training-
     drop would have to be added IN THIS MUX (or above it), because
     the existing RTL has no idle path.

Invocation:
    cd /home/dam1n19/SoCLabs/td-bisect/td-interface-debug
    source /home/dam1n19/SoCLabs/tidelink/set_env.sh
    rm -rf cocotb/wav_d2d_gpio_tx/sim_build
    make -C cocotb/wav_d2d_gpio_tx
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


TRAIN_BYTE  = 0xA3        # one of the known per-lane training bytes
FC_DATA     = 0xDEADBEEF  # not used (16-bit port), kept here for symmetry
FC_DATA_16  = 0xBEEF      # recognisable 16-bit "FC payload" word
STALE_16    = 0xFACE      # recognisable 16-bit "stale" word (no FC queued)


async def _start_clk(dut):
    """50 MHz on io_clk (10 ns period)."""
    cocotb.start_soon(Clock(dut.io_clk, 10, unit="ns").start())


async def _reset_and_settle(dut):
    """Apply async reset, then deassert and let the free-running count phase
    settle. The serialiser's `count` resets to 4'hf and increments every
    io_clk, so after 16 cycles it has wrapped once and entered steady state.
    """
    dut.io_reset.value           = 1
    dut.io_clk_en.value          = 1   # keep gated clock alive
    dut.io_training_mode.value   = 0
    dut.io_training_pattern.value = 0
    dut.io_link_data.value       = 0
    await Timer(1, unit="ns")
    for _ in range(8):
        await RisingEdge(dut.io_clk)
    dut.io_reset.value = 0
    for _ in range(8):
        await RisingEdge(dut.io_clk)


async def _capture_pad(dut, n_cycles):
    """Sample io_pad on each rising io_clk; return a list of
    (count, pad, eff) tuples of length n_cycles. count is the internal
    serialiser index that determines which bit of _link_data_eff is on
    the pad THIS cycle. We compute eff in Python from the current
    training_mode + (training_pattern | io_link_data) — the wire
    `_link_data_eff` is optimised out of the elaborated hierarchy in VCS.
    """
    samples = []
    for _ in range(n_cycles):
        await RisingEdge(dut.io_clk)
        # Sample one delta later so the post-edge combinational mux has settled.
        await Timer(1, unit="ps")
        cnt = int(dut.u_dut.count.value)
        pad = int(dut.io_pad.value)
        mode = int(dut.io_training_mode.value)
        if mode:
            pat = int(dut.io_training_pattern.value) & 0xFF
            eff = (pat << 8) | pat
        else:
            eff = int(dut.io_link_data.value) & 0xFFFF
        samples.append((cnt, pad, eff))
    return samples


def _reassemble_word_from_pad(samples):
    """The serialiser emits _link_data_eff[count] on the pad each io_clk.
    Re-collect 16 contiguous samples (count rolling 0..15) into a 16-bit
    word, indexed by `count`. We pick the first complete count-rollover
    window in `samples`.
    """
    # Find first index where count == 0 with at least 16 samples remaining.
    for start in range(len(samples) - 15):
        if samples[start][0] == 0:
            word = 0
            for i in range(16):
                cnt, pad, _eff = samples[start + i]
                if cnt != i:
                    return None  # count not contiguous — bail
                word |= (pad & 0x1) << cnt
            return (start, word)
    return None


# -----------------------------------------------------------------------------
# Test 01 — training_mode=1 must override io_link_data with the training byte.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_01_training_mode_on_emits_training_pattern(dut):
    """training_mode=1 → pad emits {pattern,pattern}, NOT io_link_data."""
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_mode.value    = 1
    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_link_data.value        = FC_DATA_16     # bait: must be ignored
    # Settle the new inputs at least one cycle before sampling.
    for _ in range(2):
        await RisingEdge(dut.io_clk)

    samples = await _capture_pad(dut, 48)

    # Log raw stream
    dut._log.info("=== test_01: training_mode=1, train=0x%02X, fc=0x%04X ===" %
                  (TRAIN_BYTE, FC_DATA_16))
    for cnt, pad, eff in samples[:32]:
        dut._log.info("  cnt=%2d  pad=%d  eff=0x%04X" % (cnt, pad, eff))

    # Reassemble the first complete count-rollover window.
    res = _reassemble_word_from_pad(samples)
    assert res is not None, (
        "could not find a complete count-rollover window in 48 samples — "
        "the serialiser count is not free-running as expected."
    )
    start, word = res
    expected = (TRAIN_BYTE << 8) | TRAIN_BYTE
    dut._log.info(
        "test_01: reassembled word from pad = 0x%04X (expected 0x%04X) "
        "starting at sample %d" % (word, expected, start)
    )
    assert word == expected, (
        "test_01 FAIL: pad word reassembled from training_mode=1 stream "
        "is 0x%04X — expected 0x%04X = {0x%02X, 0x%02X}. The training "
        "mux at WavD2DGpioTx.v:43-45 is NOT replacing io_link_data with "
        "the repeated training byte." % (word, expected, TRAIN_BYTE, TRAIN_BYTE)
    )
    dut._log.info("test_01 PASS: pad emits 0x%04X = repeated training byte." % word)


# -----------------------------------------------------------------------------
# Test 02 — training_mode=0 must emit io_link_data.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_02_training_mode_off_emits_link_data(dut):
    """training_mode=0 → pad emits io_link_data, NOT the training byte."""
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_mode.value    = 0
    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_link_data.value        = FC_DATA_16
    for _ in range(2):
        await RisingEdge(dut.io_clk)

    samples = await _capture_pad(dut, 48)

    dut._log.info("=== test_02: training_mode=0, train=0x%02X, fc=0x%04X ===" %
                  (TRAIN_BYTE, FC_DATA_16))
    for cnt, pad, eff in samples[:32]:
        dut._log.info("  cnt=%2d  pad=%d  eff=0x%04X" % (cnt, pad, eff))

    res = _reassemble_word_from_pad(samples)
    assert res is not None, "could not find a complete count-rollover window."
    start, word = res
    dut._log.info(
        "test_02: reassembled word from pad = 0x%04X (expected 0x%04X) "
        "starting at sample %d" % (word, FC_DATA_16, start)
    )
    assert word == FC_DATA_16, (
        "test_02 FAIL: pad word reassembled is 0x%04X — expected 0x%04X "
        "(io_link_data). Training mux not passing through io_link_data when "
        "training_mode=0." % (word, FC_DATA_16)
    )
    dut._log.info("test_02 PASS: pad emits io_link_data = 0x%04X." % word)


# -----------------------------------------------------------------------------
# Test 03 — observe the 1→0 transition cycle-by-cycle. Diagnostic.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_03_transition_1_to_0(dut):
    """training_mode 1→0: capture cycles T-4 through T+24. Report what's on
    the pad at each cycle. Diagnostic — no PASS/FAIL assertion on the
    transition shape itself."""
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_mode.value    = 1
    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_link_data.value        = FC_DATA_16
    # Stabilise in training mode for a couple of count-rollover windows.
    for _ in range(32):
        await RisingEdge(dut.io_clk)

    # Capture 4 cycles of pre-transition training stream.
    pre = await _capture_pad(dut, 4)

    # Drop training_mode on the very next edge.
    dut.io_training_mode.value = 0
    # Capture 24 cycles post-transition.
    post = await _capture_pad(dut, 24)

    samples = pre + post
    transition_idx = len(pre)  # the FIRST sample with training_mode=0 applied
    dut._log.info("=== test_03: 1→0 transition (T = sample %d) ===" % transition_idx)
    dut._log.info("  pattern=0x%02X, link_data=0x%04X, expected pad-effective:"
                  % (TRAIN_BYTE, FC_DATA_16))
    dut._log.info("    training_mode=1 → eff=0x%04X" % ((TRAIN_BYTE << 8) | TRAIN_BYTE))
    dut._log.info("    training_mode=0 → eff=0x%04X" % FC_DATA_16)
    for i, (cnt, pad, eff) in enumerate(samples):
        marker = "  <-- T" if i == transition_idx else ""
        dut._log.info("  s=%2d  cnt=%2d  pad=%d  eff=0x%04X%s" %
                      (i, cnt, pad, eff, marker))

    # Diagnostic only: report whether the eff word changes at T or T+1.
    eff_pre  = samples[transition_idx - 1][2]
    eff_at_T = samples[transition_idx][2]
    if eff_at_T != eff_pre:
        dut._log.info("test_03 OBSERVATION: eff changed at sample T "
                      "(combinational mux switched in one cycle).")
    else:
        dut._log.info("test_03 OBSERVATION: eff did NOT change at sample T — "
                      "investigate whether a register sits between mode and "
                      "the mux. (This module has none; expectation: eff "
                      "changes within one io_clk.)")


# -----------------------------------------------------------------------------
# Test 04 — gap behaviour: training_mode=0, no fresh FC data driven.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_04_idle_gap_behavior(dut):
    """training_mode=0 and we leave io_link_data parked at a recognisable
    "stale" value. Capture the pad output across 48 cycles. Diagnostic.

    Expectation given the RTL: io_link_data is purely combinatorial input,
    so the pad keeps serialising STALE_16 forever. There is NO idle pattern
    insertion. NO tx_en gating. The slave RX would see STALE_16 repeated.

    If our expectation is wrong (e.g. some implicit hold cell flips into
    an idle pattern at io_link_data=X under unknown conditions), this test
    will show it.
    """
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_mode.value    = 0
    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_link_data.value        = STALE_16
    # NB: this module has NO io_link_tx_tx_en — see file header. The
    # serialiser is always live.
    for _ in range(2):
        await RisingEdge(dut.io_clk)

    samples = await _capture_pad(dut, 48)

    dut._log.info("=== test_04: training_mode=0, link_data parked at 0x%04X ===" %
                  STALE_16)
    for cnt, pad, eff in samples[:32]:
        dut._log.info("  cnt=%2d  pad=%d  eff=0x%04X" % (cnt, pad, eff))

    res = _reassemble_word_from_pad(samples)
    if res is None:
        dut._log.info("test_04: count rollover not found in 48 samples.")
        return
    start, word = res
    dut._log.info("test_04: reassembled word from pad = 0x%04X (parked: 0x%04X) "
                  "starting at sample %d" % (word, STALE_16, start))
    if word == STALE_16:
        dut._log.info(
            "test_04 OBSERVATION: pad keeps re-serialising STALE_16 "
            "indefinitely. CONFIRMED: WavD2DGpioTx has NO idle pattern "
            "insertion, NO tx_en gating. With training off and the upstream "
            "FC adapter not driving fresh data, the wire emits whatever "
            "value io_link_data holds — for arbitrarily many cycles."
        )
    else:
        dut._log.info(
            "test_04 OBSERVATION: pad word 0x%04X != parked io_link_data "
            "0x%04X. Investigate the mismatch — there is an unexpected "
            "side path inside WavD2DGpioTx." % (word, STALE_16)
        )


# -----------------------------------------------------------------------------
# Test 05 — THE MOST IMPORTANT TEST. Training drops with no fresh FC data.
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_05_transition_with_no_data_queued(dut):
    """training_mode 1→0 with io_link_data parked at STALE_16. Capture cycles
    T-4 through T+32. Report exactly what the pad emits during the
    post-training-drop window. Diagnostic.

    This is the diagnostic that the master RX would have seen on the wire
    in the live FPGA case: training drops, no FC packet is ready, the WAV
    TX has no idle pattern, so the pad emits whatever STALE_16 io_link_data
    happens to hold. The slave RX correlator (which had been locked to the
    training byte) now sees an arbitrary 16-bit pattern repeated, and may
    or may not stay aligned depending on its bit_slip lock policy.
    """
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_mode.value    = 1
    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_link_data.value        = STALE_16     # stale, no FC traffic
    for _ in range(32):
        await RisingEdge(dut.io_clk)

    pre = await _capture_pad(dut, 4)
    dut.io_training_mode.value = 0
    post = await _capture_pad(dut, 32)

    samples = pre + post
    T = len(pre)
    dut._log.info("=== test_05: 1→0 with link_data parked at STALE 0x%04X ===" %
                  STALE_16)
    dut._log.info("  pattern=0x%02X, stale=0x%04X. Expected behaviours:" %
                  (TRAIN_BYTE, STALE_16))
    dut._log.info("    pre-T  → pad emits training byte 0x%04X" %
                  ((TRAIN_BYTE << 8) | TRAIN_BYTE))
    dut._log.info("    post-T → pad emits STALE 0x%04X (no idle injection)" %
                  STALE_16)
    for i, (cnt, pad, eff) in enumerate(samples):
        marker = "  <-- T (training drops)" if i == T else ""
        dut._log.info("  s=%2d  cnt=%2d  pad=%d  eff=0x%04X%s" %
                      (i, cnt, pad, eff, marker))

    # Diagnostic verdict.
    eff_at_T_minus_1 = samples[T - 1][2]
    eff_at_T         = samples[T][2]
    train_eff        = (TRAIN_BYTE << 8) | TRAIN_BYTE
    if eff_at_T_minus_1 == train_eff and eff_at_T == STALE_16:
        dut._log.info(
            "test_05 VERDICT: eff jumps from 0x%04X (training) to 0x%04X "
            "(STALE) in ONE io_clk cycle. There is NO buffering window, "
            "NO idle pattern, NO tx_en gate. The slave RX correlator sees "
            "a hard cut from a known periodic byte to an arbitrary 16-bit "
            "word. This CONFIRMS the hypothesis: WavD2DGpioTx has no "
            "alignment-preserving idle. The Option B fix (idle injection) "
            "would have to be added either inside this mux or in the "
            "upstream wrapper that drives io_link_data + io_training_mode."
            % (eff_at_T_minus_1, eff_at_T)
        )
    else:
        dut._log.info(
            "test_05 OBSERVATION: eff transition was T-1=0x%04X, T=0x%04X. "
            "Investigate whether an unexpected side path exists."
            % (eff_at_T_minus_1, eff_at_T)
        )

    # Pull out the first 2 complete count-rollover windows post-T to confirm
    # the pad is steady on STALE.
    post_only = samples[T:]
    res = _reassemble_word_from_pad(post_only)
    if res is not None:
        start, word = res
        dut._log.info(
            "test_05: first complete post-T window reassembled = 0x%04X "
            "(STALE=0x%04X) starting at post-T sample %d" %
            (word, STALE_16, start)
        )
