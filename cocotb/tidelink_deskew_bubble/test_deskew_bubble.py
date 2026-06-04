# =============================================================================
# test_deskew_bubble.py — RED->GREEN gate for the tidelink_lane_deskew bubble bug.
#
# REAL-HW SCENARIO modelled here: the 8 per-lane recovered word clocks are
# FREQUENCY-LOCKED (one forwarded pad_clk divided by 16 -> identical average
# rate) and differ only in PHASE (each lane's count counter starts at a
# different pad_clk cycle during calibration). This is NOT a frequency-drift
# scenario; all lanes and out_clk share the SAME period, lane k merely delayed
# by k*LANE_PHASE ns.
#
# BUG (root-caused): deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv read
# side originally started advancing rd_ptr as soon as `all_ready =
# &lane_has_data` was true, i.e. when each lane FIFO held >=1 word. The
# phase-late lane then sat at occupancy ~1 and emptied for part of every word
# period, so all_ready GLITCHED LOW recurrently; on each low cycle the read
# HELD out_data and the downstream framer (out_clk-clocked, NO flow control)
# re-consumed the held word as a DUPLICATE/bubble -> byte_count desync -> SOP/
# EOP break. Even frequency-locked, the phase offset alone triggers it.
#
# FIX (prime-and-continuous): the read side primes a per-lane cushion
# (>= PRIME_THRESH words) before the first read, then reads continuously gated
# by all_ready. Because rd-rate==wr-rate the occupancy holds ~PRIME_THRESH so
# all_ready stays HIGH for the whole burst -> zero bubbles, no clock gating.
#
# This UNIT test drives the frequency-locked phase-offset clocks, captures
# out_data on every out_clk edge, and asserts: post-prime there are ZERO
# all_ready-low cycles AND ZERO duplicate out_data words.
#   - UNFIXED RTL: MUST FAIL (bubbles present; all_ready glitches low).
#   - FIXED  RTL : MUST PASS (0 bubbles; all_ready stays high post-prime).
# =============================================================================
import cocotb
import random
from cocotb.triggers import Timer, RisingEdge
from cocotb.clock import Clock

LANES = 8
WIDTH = 16

# Timing. FREQUENCY-LOCKED: every lane AND out_clk share the SAME nominal PERIOD
# (one forwarded pad_clk / 16). Lanes differ only in PHASE: a fixed per-lane
# offset (lane k delayed by k*LANE_PHASE ns) PLUS bounded, ZERO-MEAN per-edge
# phase JITTER that models recovered-clock dither. The jitter is zero-mean and
# bounded (|j| <= JITTER_PS) so the long-run average period is EXACTLY PERIOD —
# i.e. the lanes stay frequency-locked, there is NO cumulative frequency drift;
# the trailing lane only dithers in phase across the out_clk sampling boundary.
# That phase dither is precisely what makes a lane sitting at occupancy ~1
# (the UNFIXED occupancy-1 read start) momentarily underrun -> all_ready glitches
# low -> out_data HELD -> the free-running framer re-consumes a duplicate.
PERIOD     = 16      # ns nominal word-clock period for out_clk AND all 8 lanes
LANE_PHASE = 2       # ns: lane k base phase offset = k*LANE_PHASE
JITTER_PS  = 5000    # ps: per-edge zero-mean phase jitter bound (~0.31*PERIOD)
N_WORDS    = 80      # distinct words pushed per lane


def word_for(lane, tag):
    # Distinct, monotonic per (lane, tag): high bits = tag, low nibble = lane.
    return ((tag & 0xFFF) << 4) | (lane & 0xF)


async def lane_clock(dut, lane, base_phase_ns):
    """One lane's frequency-locked, phase-offset+jittered write clock with
    monotonic data on each rising edge. Rising edges are scheduled at ABSOLUTE
    nominal times (n*PERIOD + base_phase) plus bounded ZERO-MEAN jitter, so the
    average rate is exactly PERIOD (frequency-locked) but a trailing lane's edge
    dithers across the out_clk boundary. Each lane has its OWN scalar clk/data
    handle (no packed-bus RMW race)."""
    clk_sig  = getattr(dut, f"lane_clk_{lane}")
    data_sig = getattr(dut, f"lane_data_{lane}")
    rng      = random.Random(1000 + lane)
    base_ps  = base_phase_ns * 1000
    half_ps  = (PERIOD * 1000) // 2
    prev_ps  = 0
    tag      = 0
    while True:
        j = rng.randint(-JITTER_PS, JITTER_PS) if JITTER_PS > 0 else 0
        target = base_ps + tag * PERIOD * 1000 + j   # absolute rising-edge time
        dt = target - prev_ps
        if dt > 0:
            await Timer(dt, units="ps")
        prev_ps = target
        if tag < N_WORDS:
            data_sig.value = word_for(lane, tag)
        clk_sig.value = 1
        await Timer(half_ps, units="ps")
        clk_sig.value = 0
        prev_ps += half_ps
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

    # Drop training FIRST so the first lane edges capture FIFO[0] as data.
    dut.training_mode.value = 0
    await Timer(4, units="ns")

    # Start per-lane FREQUENCY-LOCKED, PHASE-OFFSET (+ bounded jitter) clocks.
    for k in range(LANES):
        cocotb.start_soon(lane_clock(dut, k, k * LANE_PHASE))

    # Free-running framer consume clock (out_clk). Same PERIOD as the lanes.
    cocotb.start_soon(Clock(dut.out_clk, PERIOD, units="ns").start())

    # ---- capture out_data on every out_clk rising edge (free-running consume) --
    # Bound to the streaming window: stop a few cycles before the slowest lane
    # exhausts its N_WORDS writes so end-of-stream repetition (a test artefact,
    # not the bug) does not pollute the count.
    stream_end_ns = (LANES - 1) * LANE_PHASE + (N_WORDS - 2) * PERIOD
    cycles = max(8, int(stream_end_ns // PERIOD))

    seen = []            # list of (cycle, out_data, all_ready, has_data)
    for c in range(cycles):
        await RisingEdge(dut.out_clk)
        od = int(dut.out_data.value)
        ar = int(dut.all_ready_o.value)
        hd = int(dut.lane_has_data_o.value)
        seen.append((c, od, ar, hd))

    # ---- analysis ----
    # The first non-zero out_data edge marks the first real READ. On the FIXED
    # RTL nothing is read until the per-lane cushion is primed, so this edge is
    # the prime-complete point; on the UNFIXED RTL it is the occupancy-1 start.
    # Either way it is the start of the real stream; bubbles are counted from
    # here on (the pre-data settle window is excluded as a test artefact).
    first_real = None
    for i, (c, od, ar, hd) in enumerate(seen):
        if od != 0:
            first_real = i
            break
    assert first_real is not None, "out_data never produced non-zero data"

    prime_cycle = seen[first_real][0]   # out_clk cycle of the first real read
    stream = seen[first_real:]
    total_consumes = len(stream)

    # all_ready-low cycles DURING streaming (post first real word). On the fixed
    # RTL this MUST be 0; on the unfixed RTL the phase-late lane drives it >0.
    ar_low_streaming = [s for s in stream if s[2] == 0]

    # A BUBBLE = a consume edge whose out_data equals the previous edge's, caused
    # by the read HOLDING (all_ready was low at the prior edge).
    bubbles = []                 # (cycle, value, all_ready_at_prev_edge)
    for i in range(1, len(stream)):
        c, od, ar, hd = stream[i]
        pc, pod, par, phd = stream[i - 1]
        if od == pod:
            bubbles.append((c, od, par))

    n_distinct = len(set(s[1] for s in stream))
    bubbles_caused_by_ar_low = [b for b in bubbles if b[2] == 0]

    dut._log.info("=" * 74)
    dut._log.info("tidelink_lane_deskew prime-and-continuous bubble gate "
                  "(FREQUENCY-LOCKED, phase-offset)")
    dut._log.info("=" * 74)
    dut._log.info(f"per-lane / out_clk period (ns)     : {PERIOD} "
                  f"(frequency-locked); phase step = {LANE_PHASE} ns; "
                  f"jitter = +-{JITTER_PS} ps (zero-mean)")
    dut._log.info(f"words WRITTEN per lane              : {N_WORDS}")
    dut._log.info(f"PRIME latency (first read @ out_clk): cycle {prime_cycle}")
    dut._log.info(f"out_clk consume edges (streaming)  : {total_consumes}")
    dut._log.info(f"DISTINCT words seen at out_data     : {n_distinct}")
    dut._log.info(f"all_ready-LOW cycles (streaming)    : {len(ar_low_streaming)}")
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
        f"words consumed = {total_consumes}, distinct TX words = {n_distinct}, "
        f"phantom (bubble) consumes = {total_consumes - n_distinct}"
    )
    dut._log.info("=" * 74)

    # ---- SANITY: counted duplicates must be attributable to the bug ----
    assert len(bubbles_caused_by_ar_low) == len(bubbles), (
        f"{len(bubbles) - len(bubbles_caused_by_ar_low)} duplicate(s) NOT "
        "explained by an all_ready-low hold edge -> attribution mismatch."
    )

    # ---- REGRESSION GATE ----
    # Frequency-locked, phase-offset only:
    #   UNFIXED RTL -> phase-late lane glitches all_ready low -> bubbles > 0 (FAIL)
    #   FIXED   RTL -> primed cushion holds all_ready high     -> bubbles = 0 (PASS)
    assert len(ar_low_streaming) == 0, (
        f"DESKEW BUBBLE BUG present: {len(ar_low_streaming)} all_ready-LOW "
        f"cycle(s) during sustained streaming -> the read HELD out_data and the "
        f"free-running framer re-consumed it. Frequency-locked lanes should hold "
        f"occupancy steady post-prime; any low cycle means the read started "
        f"before priming a cushion (occupancy-1 start). Apply prime-and-"
        f"continuous fix."
    )
    assert len(bubbles) == 0, (
        f"DESKEW BUBBLE BUG present: {len(bubbles)} duplicate out_data word(s) "
        f"in the streaming window (phantom consumes = "
        f"{total_consumes - n_distinct}), all from the all_ready-gated hold "
        f"re-presenting the previous 128-bit word to the free-running framer. "
        f"Prime-and-continuous read must keep all_ready high and clear bubbles."
    )
