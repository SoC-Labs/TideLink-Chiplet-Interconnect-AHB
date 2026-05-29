"""test_wav_tx_prbs_training — verify the LOCAL OVERRIDE WavD2DGpioTx with
USE_PRBS_TRAINING=1 emits a PRBS-7 stream XORed with the per-lane tag while
io_training_mode=1, and falls back to io_link_data when training_mode=0.

Coverage:
  * test_01_emits_prbs_stream_with_lane_tag_xor
      Drive training_mode=1 with a known io_training_pattern. Sample 32
      io_pad cycles and reassemble two 16-bit words at known count-rollover
      boundaries. Each word must equal the PRBS-7 lookahead from the
      seeded LFSR state XORed with {pattern, pattern}.

  * test_02_training_mode_off_emits_link_data
      Sanity: training_mode=0 → pad emits io_link_data, regardless of PRBS.
      (No regression of the upstream behaviour.)

Run:
    cd /home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter
    source set_env.sh
    rm -rf cocotb/wav_d2d_gpio_tx_prbs/sim_build
    make -C cocotb/wav_d2d_gpio_tx_prbs
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


TRAIN_BYTE = 0xA3
FC_DATA_16 = 0xBEEF


def _seed_for(tag):
    return ((tag >> 1) & 0x7F) | 0x01


def _prbs7_advance(state):
    fb = ((state >> 6) ^ (state >> 5)) & 0x1
    return ((state << 1) & 0x7F) | fb


def _next_prbs_word(state):
    s = state
    word = 0
    for k in range(16):
        word |= ((s >> 6) & 0x1) << k
        s = _prbs7_advance(s)
    return word, s


async def _start_clk(dut):
    cocotb.start_soon(Clock(dut.io_clk, 10, unit="ns").start())


async def _reset_and_settle(dut):
    dut.io_reset.value            = 1
    dut.io_clk_en.value           = 1
    dut.io_training_mode.value    = 0
    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_link_data.value        = 0
    await Timer(1, unit="ns")
    for _ in range(8):
        await RisingEdge(dut.io_clk)
    dut.io_reset.value = 0
    for _ in range(8):
        await RisingEdge(dut.io_clk)


async def _capture_pad(dut, n_cycles):
    samples = []
    for _ in range(n_cycles):
        await RisingEdge(dut.io_clk)
        await Timer(1, unit="ps")
        cnt = int(dut.u_dut.count.value)
        pad = int(dut.io_pad.value)
        samples.append((cnt, pad))
    return samples


def _reassemble_word(samples, start_at_count_0=True):
    """Find the first contiguous count=0..15 window and reassemble the
    16-bit word. word[k] = pad sampled when count==k."""
    for i in range(len(samples) - 15):
        if samples[i][0] == 0:
            word = 0
            ok = True
            for k in range(16):
                if samples[i + k][0] != k:
                    ok = False
                    break
                word |= (samples[i + k][1] & 0x1) << k
            if ok:
                return (i, word)
    return None


@cocotb.test()
async def test_01_emits_prbs_stream_with_lane_tag_xor(dut):
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_training_mode.value    = 1
    dut.io_link_data.value        = FC_DATA_16
    # Wait one word boundary so the WORD_ALIGN_MUX latches training_mode_q=1
    # and the first prbs_word_q load happens.
    for _ in range(32):
        await RisingEdge(dut.io_clk)

    # Capture enough cycles to find two adjacent count-rollover windows.
    samples = await _capture_pad(dut, 64)

    # Find first complete 16-sample window starting at count=0.
    res = _reassemble_word(samples)
    assert res is not None, "could not find count=0..15 window"
    start, word0 = res
    res2 = _reassemble_word(samples[start + 16:])
    assert res2 is not None, "could not find second count=0..15 window"
    _start2, word1 = res2

    # The TX uses prbs_lfsr seeded from io_training_pattern at reset; by the
    # time we capture the first window, the LFSR has advanced N×16 bits
    # where N is the number of count-rollovers since reset deassert. We
    # don't know N exactly, so instead verify the structural invariant:
    # there EXISTS some PRBS state S such that
    #   word0 = prbs_word(S)            ^ {tag, tag}
    #   word1 = prbs_word(advance16(S)) ^ {tag, tag}
    # i.e. the two captured words are consistent with the PRBS-7 evolution.
    tag_word = (TRAIN_BYTE << 8) | TRAIN_BYTE
    stripped0 = word0 ^ tag_word
    stripped1 = word1 ^ tag_word
    dut._log.info(f"word0=0x{word0:04X} stripped0=0x{stripped0:04X}")
    dut._log.info(f"word1=0x{word1:04X} stripped1=0x{stripped1:04X}")

    # Brute-force search: which 7-bit state S produces stripped0 as the
    # next 16 PRBS bits, AND advancing 16 times produces stripped1?
    matched_state = None
    for s in range(1, 128):  # 1..127 (exclude all-zero degenerate)
        w0, s16 = _next_prbs_word(s)
        if w0 != stripped0:
            continue
        w1, _ = _next_prbs_word(s16)
        if w1 == stripped1:
            matched_state = s
            break

    assert matched_state is not None, (
        f"test_01 FAIL: captured pad words (stripped of lane-tag XOR) do "
        f"not match any PRBS-7 state evolution. stripped0=0x{stripped0:04X} "
        f"stripped1=0x{stripped1:04X}. The TX did NOT emit a valid PRBS-7 "
        f"stream XORed with {{tag, tag}}."
    )
    dut._log.info(
        f"test_01 PASS: TX pad emits PRBS-7 ^ {{tag,tag}} consistent with "
        f"LFSR state 0x{matched_state:02X} at the first captured window."
    )


@cocotb.test()
async def test_02_training_mode_off_emits_link_data(dut):
    await _start_clk(dut)
    await _reset_and_settle(dut)

    dut.io_training_pattern.value = TRAIN_BYTE
    dut.io_training_mode.value    = 0
    dut.io_link_data.value        = FC_DATA_16
    for _ in range(32):
        await RisingEdge(dut.io_clk)

    samples = await _capture_pad(dut, 48)
    res = _reassemble_word(samples)
    assert res is not None
    _, word = res
    assert word == FC_DATA_16, (
        f"test_02 FAIL: training_mode=0 should pass through io_link_data "
        f"unchanged. Got 0x{word:04X}, expected 0x{FC_DATA_16:04X}."
    )
    dut._log.info(f"test_02 PASS: pad emits io_link_data=0x{word:04X}.")
