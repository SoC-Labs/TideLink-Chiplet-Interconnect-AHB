# =============================================================================
# test_deskew_bubble.py — DEMONSTRATES the tidelink_lane_deskew bubble bug.
#
# Bug (root-caused): deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv read
# side (lines ~137-148) advances rd_ptr / updates out_data ONLY when the
# internal `all_ready = &lane_has_data` is true; when all_ready is FALSE it
# HOLDS out_data (re-presents the previous 128-bit word). The downstream framer
# (WlinkRxLinkLayer, clocked by out_clk via WavD2DGpio.v:364 / Wlink.v:1849)
# has NO valid/flow-control input and consumes one word per out_clk edge
# unconditionally. So whenever a lane FIFO momentarily empties under per-lane
# phase skew, the framer RE-CONSUMES the held word as a DUPLICATE (bubble),
# advancing its byte_count without a real TX word -> SOP/EOP desync.
#
# This UNIT test drives 8 frequency-locked but PHASE-OFFSET lane write clocks
# and a free-running out_clk (the framer clock, no back-pressure). It writes a
# KNOWN MONOTONIC word sequence per lane and captures out_data on every out_clk
# edge. It then ASSERTS the bug: out_data contains consecutive DUPLICATE words
# (the framer would consume more words than were ever written per lane), and
# every duplicate coincides with all_ready being LOW.
# =============================================================================
import cocotb
from cocotb.triggers import Timer, RisingEdge
from cocotb.clock import Clock

LANES = 8
WIDTH = 16

# Timing (ns). All clocks share the SAME period (frequency-locked); lanes are
# only PHASE-shifted. out_clk is the free-running consumer (framer) clock.
PERIOD      = 16      # nominal word-clock period for out_clk + most lanes
LANE_PHASE  = 2       # lane k starts delayed by k*LANE_PHASE ns (skew offset)
# Per-lane recovered word clocks are NOT perfectly frequency-locked on silicon:
# each lane derives its own count from its own pad-clock alignment, so a
# trailing lane drifts a fraction of a word-period slower. We model that with a
# small per-lane period stretch on the trailing lanes. This makes the trailing
# lane's FIFO drain recurrently relative to the (faster) framer out_clk ->
# all_ready glitches low -> out_data is HELD -> the free-running framer
# re-consumes the held word as a DUPLICATE/bubble. (See module header: "lanes'
# count counters reset/start at different pad_clk cycles".)
LANE_PERIOD = {        # lane -> its own word-clock period (ns)
    0: 16, 1: 16, 2: 16, 3: 16,
    4: 17, 5: 17, 6: 18, 7: 18,   # trailing lanes run slightly slower
}
N_WORDS     = 60      # distinct words pushed per lane


def word_for(lane, tag):
    # Distinct, monotonic per (lane, tag): high byte = tag, low nibble = lane.
    # tag is shared across lanes for a given source word so the assembled
    # 128-bit out_data word is unambiguous and a "duplicate" is unmistakable.
    return ((tag & 0xFFF) << 4) | (lane & 0xF)


async def lane_clock(dut, lane, period, phase_delay):
    """Generate one lane's phase-shifted write clock + drive its monotonic data
    on each rising edge. Each lane has its OWN scalar clk/data handle, so no
    cross-task read-modify-write race on a packed bus."""
    clk_sig  = getattr(dut, f"lane_clk_{lane}")
    data_sig = getattr(dut, f"lane_data_{lane}")
    if phase_delay > 0:
        await Timer(phase_delay, units="ns")
    tag = 0
    while True:
        # present this lane's data BEFORE its rising edge samples it
        if tag < N_WORDS:
            data_sig.value = word_for(lane, tag)
        clk_sig.value = 1
        await Timer(period // 2, units="ns")
        clk_sig.value = 0
        await Timer(period - period // 2, units="ns")
        if tag < N_WORDS:
            tag += 1


@cocotb.test()
async def test_deskew_bubble(dut):
    # ---- init ----
    dut.rst_n.value = 0
    dut.training_mode.value = 1
    for k in range(LANES):
        getattr(dut, f"lane_clk_{k}").value = 0
        getattr(dut, f"lane_data_{k}").value = 0
    dut.out_clk.value = 0

    await Timer(20, units="ns")
    dut.rst_n.value = 1
    await Timer(20, units="ns")

    # Drop training FIRST so the very first lane edges capture FIFO[0] as data.
    dut.training_mode.value = 0
    await Timer(4, units="ns")

    # Start per-lane phase-shifted write clocks. Lanes 1..7 are progressively
    # phase-delayed AND the trailing lanes run a fraction slower (LANE_PERIOD)
    # -> the trailing lane's FIFO drains recurrently relative to the framer
    # clock, exactly the per-lane skew/drift the deskew is meant to absorb.
    for k in range(LANES):
        cocotb.start_soon(lane_clock(dut, k, LANE_PERIOD[k], k * LANE_PHASE))

    # The framer consumer clock (out_clk) is lane-0's word clock in real RTL
    # (WavD2DGpio.v:364 / Wlink.v:1849). Here it free-runs at lane-0's nominal
    # rate with NO read-cushion head-start; when a trailing lane has drained,
    # the deskew read STALLS (all_ready low) and HOLDS out_data, and this
    # free-running consumer re-samples the held word as a BUBBLE/duplicate.
    cocotb.start_soon(Clock(dut.out_clk, PERIOD, units="ns").start())

    # ---- capture out_data on every out_clk rising edge (free-running consume) ----
    # Bound the capture to the STREAMING window only: stop a few cycles before
    # the slowest lane would exhaust its N_WORDS writes, so end-of-stream
    # repetition (a test artefact, not the bug) does not pollute the count.
    slow_period = max(LANE_PERIOD.values())
    stream_end_ns = (LANES - 1) * LANE_PHASE + (N_WORDS - 2) * slow_period
    cycles = max(8, int(stream_end_ns // PERIOD))

    seen = []            # list of (cycle, out_data, all_ready, has_data)
    for c in range(cycles):
        await RisingEdge(dut.out_clk)
        od = int(dut.out_data.value)
        ar = int(dut.all_ready_o.value)
        hd = int(dut.lane_has_data_o.value)
        seen.append((c, od, ar, hd))
        if ar == 0:
            dut._log.info(f"  all_ready LOW @ out_clk cycle {c:3d}  "
                          f"has_data=0x{hd:02x} (read STALLS, out_data HELD)")

    # ---- analysis ----
    # Drop the leading zero/settle words (before first real data appears).
    first_real = None
    for i, (c, od, ar, hd) in enumerate(seen):
        if od != 0:
            first_real = i
            break
    assert first_real is not None, "out_data never produced non-zero data"

    stream = seen[first_real:]
    total_consumes = len(stream)

    # A BUBBLE = a consume edge c whose out_data equals the previous edge's
    # out_data. The HOLD that produced it happened because all_ready was LOW at
    # the PREVIOUS edge (c-1): the read side did not advance rd_ptr/out_data, so
    # the free-running consumer re-sampled the held word. We therefore correlate
    # each bubble with all_ready at edge c-1.
    bubbles = []                 # (cycle, value, all_ready_at_prev_edge)
    for i in range(1, len(stream)):
        c, od, ar, hd = stream[i]
        pc, pod, par, phd = stream[i - 1]
        if od == pod:
            bubbles.append((c, od, par))

    n_distinct = len(set(s[1] for s in stream))
    bubbles_caused_by_ar_low = [b for b in bubbles if b[2] == 0]

    dut._log.info("=" * 74)
    dut._log.info("tidelink_lane_deskew BUBBLE / duplicate-word demonstration")
    dut._log.info("=" * 74)
    dut._log.info(f"words WRITTEN per lane              : {N_WORDS}")
    dut._log.info(f"out_clk consume edges (streaming)  : {total_consumes}")
    dut._log.info(f"DISTINCT words seen at out_data     : {n_distinct}")
    dut._log.info(f"DUPLICATE/BUBBLE consume edges      : {len(bubbles)}")
    dut._log.info("-" * 74)
    for (c, od, par) in bubbles[:24]:
        dut._log.info(
            f"  BUBBLE @ out_clk cycle {c:3d}: out_data=0x{od:032x} "
            f"== prev  (all_ready was {par} at cycle {c-1} -> read HELD)"
        )
    dut._log.info("-" * 74)
    dut._log.info(
        f"bubbles total = {len(bubbles)}, "
        f"caused by all_ready LOW at the prior (hold) edge = "
        f"{len(bubbles_caused_by_ar_low)}"
    )
    dut._log.info(
        f"DEMONSTRATED: a free-running framer would consume {total_consumes} "
        f"words but only {n_distinct} distinct TX words exist => "
        f"{total_consumes - n_distinct} PHANTOM (bubble) consumes that advance "
        f"byte_count without a real TX word -> SOP/EOP desync."
    )
    dut._log.info("=" * 74)

    # ---- SANITY: the duplicates we counted must be attributable to the bug ----
    # Every counted bubble is explained by all_ready being LOW at the prior
    # (hold) edge. If this ever fails, the demonstration's attribution is wrong
    # (a different cause), so we guard it before tripping the regression gate.
    assert len(bubbles_caused_by_ar_low) == len(bubbles), (
        f"{len(bubbles) - len(bubbles_caused_by_ar_low)} duplicate(s) NOT "
        "explained by an all_ready-low hold edge -> attribution mismatch."
    )

    # ---- REGRESSION GATE ----
    # On the CURRENT (buggy) RTL this MUST trip: the all_ready-gated hold at
    # tidelink_lane_deskew.sv:141/147 (the `else: hold out_data` branch), feeding
    # a free-running framer with NO out_valid/flow-control port, inserts bubble
    # duplicates. The fix (add an out_valid the framer honours, or de-gate the
    # read) must drive bubbles -> 0, at which point this assertion PASSES.
    assert len(bubbles) == 0, (
        f"DESKEW BUBBLE BUG present: {len(bubbles)} duplicate out_data word(s) "
        f"in the streaming window, all caused by the all_ready-gated hold "
        f"(tidelink_lane_deskew.sv:141/147) re-presenting the previous 128-bit "
        f"word to the free-running framer. {total_consumes} consume edges vs "
        f"{n_distinct} distinct TX words => "
        f"{total_consumes - n_distinct} phantom consumes. The module exposes NO "
        f"out_valid port, so the framer cannot skip the held word -> SOP/EOP "
        f"desync. Fix the deskew read/valid handshake to clear this gate."
    )
