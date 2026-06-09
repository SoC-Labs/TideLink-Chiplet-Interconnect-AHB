"""Standalone cocotb UNIT TEST for tidelink_lane_deskew.sv (8-lane deskew FIFO).

Driven through tb_deskew.sv, which fans the DUT's PACKED lane_clk / lane_data
ports out to per-lane SCALAR clocks (lane_clkN) and per-lane 16-bit data
(lane_dataN), so each lane can be clocked + driven INDEPENDENTLY — the only way
to model real per-lane word skew (each lane deserialises on its OWN word clock).

WHY THIS TEST EXISTS
--------------------
On silicon this deskew presents NO usable data to the downstream framer:
out_data never produces coherent words, so 0 packets cross the link and both
FCSMs starve. The PRIOR (single common read pointer) deskew DID deliver. The
new read controller only advances when:

    all_primed = &lane_primed     (every lane has occ >= PRIME_THRESH=4)
    all_ready  = &lane_has_data   (every lane has occ != 0, no negative wrap)

i.e. an 8-way AND over per-lane occupancy occ = wr_ptr_sync1 - rd_ptr - lane_off.

Suspected failure modes this test makes OBSERVABLE:
  (a) one marginal/slow lane stalls ALL reads forever (the AND fragility);
  (b) a spurious lane_off makes a lane's occ wrap negative -> never primes;
  (c) SYNC false-fires on data and loads wrong offsets.

Each @cocotb.test prints "VERDICT scenario=.. result=.. detail=.." and is
bounded by a cycle cap so a stall FAILS ("out_data never updated after N
cycles") rather than hanging.

Module facts (read from the RTL):
  LANES=8 WIDTH=16 DEPTH_LOG=3 DEPTH=8 PRIME_THRESH=4 SYNC_WIN=16
  SYNC_WORD = 128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00
    lane gi carries SYNC_WORD[gi*16 +: 16]:
      lane0=0x1F00 lane1=0x3D2E lane2=0x5B4C lane3=0x796A
      lane4=0x9788 lane5=0xB5A6 lane6=0xD3C4 lane7=0xF1E2
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

LANES = 8
WIDTH = 16
DEPTH = 8
PRIME_THRESH = 4
WORD_NS = 20  # out_clk (and nominal lane) word period

SYNC_WORD = 0xF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00


def sync_slice(gi):
    return (SYNC_WORD >> (gi * WIDTH)) & 0xFFFF


# ---------------------------------------------------------------------------
# Per-lane handle accessors (tb_deskew.sv scalar fan-out)
# ---------------------------------------------------------------------------
def lane_clk(dut, gi):
    return getattr(dut, f"lane_clk{gi}")


def lane_data(dut, gi):
    return getattr(dut, f"lane_data{gi}")


def unpack(busval):
    busval = int(busval)
    return [(busval >> (gi * WIDTH)) & 0xFFFF for gi in range(LANES)]


def out_val(dut):
    try:
        return int(dut.out_data.value)
    except Exception:
        return None


def verdict(scenario, passed, detail):
    res = "PASS" if passed else "FAIL"
    line = f"VERDICT scenario={scenario} result={res} detail={detail}"
    print(line)
    cocotb.log.info(line)
    return line


# ---------------------------------------------------------------------------
# Per-lane clock generator: independent scalar clock with runtime-tunable
# half-period, start phase, and a stall switch (for marginal-lane / drift).
# ---------------------------------------------------------------------------
class LaneClock:
    def __init__(self, dut, gi, half=WORD_NS / 2.0, phase=0.0, wander=0.0):
        self.sig = lane_clk(dut, gi)
        self.half = half
        self.phase = phase
        self.stalled = False
        # wander: peak BOUNDED phase-wander amplitude (ns). Lanes are FREQUENCY-
        # LOCKED (shared forwarded pad_clk/16) so phase wanders but never
        # accumulates unbounded slip — modelled as a tiny slow sinusoidal jitter
        # on each half-period that integrates to zero (returns), staying within
        # the module's +/-1-word tolerance.
        self.wander = wander
        self.gi = gi
        self.sig.value = 0

    async def run(self):
        import math
        if self.phase:
            await Timer(self.phase, units="ns")
        val = 0
        n = 0
        while True:
            while self.stalled:
                await Timer(self.half, units="ns")
            self.sig.value = val
            val ^= 1
            # Bounded zero-mean half-period jitter: a slow sinusoid (period ~50
            # words) of small amplitude, phased per lane. Average half-period
            # stays WORD_NS/2 => no frequency offset, only wander.
            if self.wander:
                dj = self.wander * math.sin(2 * math.pi * (n / 100.0) + self.gi)
            else:
                dj = 0.0
            n += 1
            # Quantize to the 1 ps simulator precision (timescale 1ns/1ps).
            dly = round(max(0.5, self.half + dj), 3)
            await Timer(dly, units="ns")


def start_lane_clocks(dut, phase_ns=None, halfs=None, wander=None):
    if phase_ns is None:
        phase_ns = [0.0] * LANES
    if halfs is None:
        halfs = [WORD_NS / 2.0] * LANES
    if wander is None:
        wander = [0.0] * LANES
    clks = [LaneClock(dut, gi, half=halfs[gi], phase=phase_ns[gi], wander=wander[gi])
            for gi in range(LANES)]
    for c in clks:
        cocotb.start_soon(c.run())
    return clks


async def do_reset(dut):
    dut.rst_n.value = 0
    dut.training_mode.value = 1
    for gi in range(LANES):
        lane_data(dut, gi).value = 0
    await Timer(5 * WORD_NS, units="ns")
    dut.rst_n.value = 1
    await Timer(3 * WORD_NS, units="ns")


async def wait_out_update(dut, cap_cycles):
    """Wait until out_data CHANGES, bounded by cap_cycles out_clk edges.
    Returns (updated, cycle_at_update, first_val, last_val)."""
    await RisingEdge(dut.out_clk)
    prev = out_val(dut)
    for c in range(1, cap_cycles + 1):
        await RisingEdge(dut.out_clk)
        cur = out_val(dut)
        if cur is not None and prev is not None and cur != prev:
            return True, c, prev, cur
        if cur is not None:
            prev = cur
    return False, cap_cycles, prev, prev


# ---------------------------------------------------------------------------
# Per-lane source feeder. Each lane writes a fresh word on ITS OWN clock edge,
# emitting from a shared coherent source sequence. With phase-staggered lane
# clocks this naturally produces cross-lane WORD SKEW. SYNC every `sync_every`
# words. The value carries the source index so coherence == all-lanes-equal.
# ---------------------------------------------------------------------------
def make_source(sync_every, base=0xA000):
    def src(t):
        if sync_every and (t % sync_every == 0):
            return None  # SYNC marker
        return (base | (t & 0x0FFF)) & 0xFFFF
    return src


async def lane_feeder(dut, gi, src, idx_box):
    """On each lane_clk[gi] edge, present this lane's slice of source word idx,
    then advance idx. Independent per-lane index => skew follows clock phase."""
    while True:
        await RisingEdge(lane_clk(dut, gi))
        t = idx_box[gi]
        w = src(t)
        if w is None:
            lane_data(dut, gi).value = sync_slice(gi)
        else:
            lane_data(dut, gi).value = w
        idx_box[gi] = t + 1


# ===========================================================================
# Scenario 1 — zero-skew passthrough (core liveness)
# ===========================================================================
@cocotb.test()
async def test_zero_skew_passthrough(dut):
    """All 8 lane_clk in phase; identical incrementing word on every lane.
    Asserts out_data ACTUALLY UPDATES and carries the driven values coherently."""
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=[0.0] * LANES)
    await do_reset(dut)
    dut.training_mode.value = 0

    # No SYNC needed for the zero-skew no-op path; drive a coherent counter.
    src = make_source(sync_every=0, base=0x1000)
    idx = [0] * LANES
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, src, idx))

    cap = 200
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict("zero_skew_passthrough", False,
                f"out_data NEVER updated after {cap} out_clk cycles "
                f"(stuck=0x{(first or 0):032x}) — core liveness FAIL")
        assert False, "out_data never updated (zero-skew stall)"

    seen = set()
    for _ in range(60):
        await RisingEdge(dut.out_clk)
        lanes = unpack(dut.out_data.value)
        if len(set(lanes)) == 1:
            seen.add(lanes[0])
    coherent = len(seen) > 0
    multiple = len(seen) >= 3
    verdict("zero_skew_passthrough", coherent and multiple,
            f"out_data first updated at out_clk cycle={cyc}; "
            f"distinct coherent words seen={len(seen)} "
            f"(sample={sorted(list(seen))[:5]})")
    assert coherent, "out_data lanes not coherent (not all-equal) in zero skew"
    assert multiple, "out_data did not stream multiple distinct words"


# ===========================================================================
# Scenario 2 — fixed skew + periodic SYNC re-align
# ===========================================================================
@cocotb.test()
async def test_fixed_skew_with_sync(dut):
    """Lanes phase-staggered 0..7 word-periods. Each lane emits the SAME source
    sequence on its OWN edge (=> cross-lane word skew), SYNC every 32 words.
    Assert out_data re-aligns so all lanes present the SAME source word."""
    phases = [gi * WORD_NS for gi in range(LANES)]  # 0..7 word-periods of phase
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=phases)
    await do_reset(dut)
    dut.training_mode.value = 0

    src = make_source(sync_every=32, base=0xA000)
    idx = [0] * LANES
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, src, idx))

    cap = 400
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict("fixed_skew_with_sync", False,
                f"out_data NEVER updated after {cap} cycles — fixed-skew stall")
        assert False, "out_data never updated (fixed-skew stall)"

    # Let several SYNC instances pass (32-word period) so any re-align fires.
    await RisingEdge(dut.out_clk)
    for _ in range(120):
        await RisingEdge(dut.out_clk)

    coherent_cnt = incoherent_cnt = 0
    samples = []
    for _ in range(160):
        await RisingEdge(dut.out_clk)
        lanes = unpack(dut.out_data.value)
        if len(set(lanes)) == 1:
            coherent_cnt += 1
            samples.append(lanes[0])
        else:
            incoherent_cnt += 1
    total = coherent_cnt + incoherent_cnt
    frac = coherent_cnt / total if total else 0.0
    passed = frac >= 0.9
    verdict("fixed_skew_with_sync", passed,
            f"first update cycle={cyc}; coherent={coherent_cnt}/{total} "
            f"({frac*100:.0f}%), incoherent={incoherent_cnt}; sample={samples[:6]}")
    assert passed, (f"out_data lanes not coherent under fixed skew "
                    f"({coherent_cnt}/{total} coherent) — deskew failed to align")


# ===========================================================================
# Scenario 3 — continuous drift (phases wander)
# ===========================================================================
@cocotb.test()
async def test_continuous_drift(dut):
    """Lanes frequency-locked but phases slowly wander (slightly different half-
    periods). Assert out_data keeps flowing (no permanent stall)."""
    # Frequency-locked lanes (equal half-period) with a small BOUNDED per-lane
    # phase wander + an initial 0..2-word phase stagger. This is the real HW
    # condition: lanes never accumulate unbounded slip, the phase just wanders.
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    phases = [(gi % 3) * WORD_NS for gi in range(LANES)]
    wander = [0.6] * LANES  # +/-0.6 ns peak ( << one word ) zero-mean jitter
    start_lane_clocks(dut, phase_ns=phases, wander=wander)
    await do_reset(dut)
    dut.training_mode.value = 0

    src = make_source(sync_every=32, base=0x2000)
    idx = [0] * LANES
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, src, idx))

    cap = 300
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict("continuous_drift", False,
                f"out_data NEVER updated after {cap} cycles — drift stall")
        assert False, "out_data never updated under drift"

    prev = out_val(dut)
    changes = 0
    longest_stall = cur_stall = 0
    for _ in range(800):
        await RisingEdge(dut.out_clk)
        cur = out_val(dut)
        if cur != prev:
            changes += 1
            cur_stall = 0
        else:
            cur_stall += 1
            longest_stall = max(longest_stall, cur_stall)
        prev = cur

    passed = changes >= 100 and longest_stall < 96
    verdict("continuous_drift", passed,
            f"first update cycle={cyc}; out changes={changes}/800, "
            f"longest_stall={longest_stall} cycles")
    assert passed, (f"out_data flow stalled under drift "
                    f"(changes={changes}, longest_stall={longest_stall})")


# ===========================================================================
# Scenario 4 — one marginal lane (exposes the 8-way AND fragility)
# ===========================================================================
@cocotb.test()
async def test_one_lane_marginal(dut):
    """Hold ONE lane's clock stalled mid-stream. Assert whether the deskew stalls
    ALL output (the &lane_has_data / &lane_primed fragility), and whether the
    link RECOVERS once the lane returns. Reports the mechanism regardless."""
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    clks = start_lane_clocks(dut)
    await do_reset(dut)
    dut.training_mode.value = 0

    src = make_source(sync_every=32, base=0x3000)
    idx = [0] * LANES
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, src, idx))

    cap = 200
    updated, cyc, _, _ = await wait_out_update(dut, cap)
    primed_ok = updated

    MARGINAL_LANE = 3

    async def measure(n):
        prev = out_val(dut)
        ch = 0
        for _ in range(n):
            await RisingEdge(dut.out_clk)
            cur = out_val(dut)
            if cur != prev:
                ch += 1
            prev = cur
        return ch

    # --- Probe A: BRIEF marginal hiccup (within the cushion). Stall the lane for
    #     only ~3 lane-periods, then release. A robust deskew rides this out.
    clks[MARGINAL_LANE].stalled = True
    ch_brief_stall = await measure(6)
    clks[MARGINAL_LANE].stalled = False
    ch_after_brief = await measure(40)
    survived_brief = (ch_after_brief > 10)

    # --- Probe B: LONG marginal stall (drains well past DEPTH=8). out_clk keeps
    #     reading => lane_has_data[3]=0 => all_ready drops => read controller
    #     freezes (suspected silicon failure a). Then release and test recovery.
    clks[MARGINAL_LANE].stalled = True
    ch_during_long = await measure(200)
    clks[MARGINAL_LANE].stalled = False
    ch_after_long = await measure(400)

    froze_long = (ch_during_long < 12)         # output starved while lane down
    recovered_long = (ch_after_long > 10)      # self-heals once lane returns

    detail = (f"primed_ok={primed_ok}(@cyc{cyc}); "
              f"BRIEF: during={ch_brief_stall} after={ch_after_brief} "
              f"survived_brief={survived_brief}; "
              f"LONG: during={ch_during_long} (froze={froze_long} -> 8-way AND "
              f"starves ALL on one marginal lane) after_release={ch_after_long} "
              f"(recovered={recovered_long})")
    # PASS criterion: the link must RECOVER once the lane returns (not permanently
    # dead). The starvation-while-stalled is the documented &-fragility, printed
    # always; an over-DEPTH stall with NO recovery path is the silicon dead-end.
    verdict("one_lane_marginal", recovered_long and survived_brief, detail)
    assert primed_ok, "link never primed even with all lanes healthy"
    assert survived_brief, ("a BRIEF (<cushion) one-lane hiccup wedged the whole "
                            "link — extreme &-fragility")
    assert recovered_long, ("link did NOT recover after a long one-lane stall — "
                            "permanent dead-end (no rd/wr re-sync path without a "
                            "training pulse): suspected silicon failure (a)")


# ===========================================================================
# Scenario 5 — liveness after training pulse
# ===========================================================================
@cocotb.test()
async def test_liveness_after_training(dut):
    """Pulse training_mode high then low, drive data, assert out_data starts
    flowing within a bounded number of out_clk (catch the 'never primes' stall)."""
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=[0.0] * LANES)
    await do_reset(dut)

    # Hold training high; drive data that must be IGNORED while training_mode=1.
    dut.training_mode.value = 1
    src = make_source(sync_every=0, base=0x4000)
    idx = [0] * LANES
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, src, idx))

    for _ in range(30):
        await RisingEdge(dut.out_clk)

    base = out_val(dut)
    moved_in_training = False
    for _ in range(20):
        await RisingEdge(dut.out_clk)
        if out_val(dut) != base:
            moved_in_training = True
            base = out_val(dut)

    # Drop training -> bootstrap; output must begin within a bounded window.
    dut.training_mode.value = 0

    cap = 80
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict("liveness_after_training", False,
                f"out_data NEVER updated within {cap} out_clk after training fell "
                f"(stuck=0x{(first or 0):032x}) — 'never primes' stall")
        assert False, "out_data never flowed after training (never-primes stall)"

    prev = out_val(dut)
    changes = 0
    for _ in range(60):
        await RisingEdge(dut.out_clk)
        cur = out_val(dut)
        if cur != prev:
            changes += 1
        prev = cur
    passed = changes >= 20
    verdict("liveness_after_training", passed,
            f"out_data began at out_clk cycle={cyc} after training fell; "
            f"sustained changes={changes}/60; "
            f"moved_during_training={moved_in_training} (should be False)")
    assert passed, "out_data did not sustain flow after training bootstrap"


# ===========================================================================
# Scenario 6 — REAL cross-lane WORD skew via per-lane INDEX (content) offset
# ---------------------------------------------------------------------------
# Scenarios 2-4 (and the integrated pad_skid sim) model "skew" as clock PHASE
# with each lane running its OWN source index from 0 — so the SAME source word
# lands at the SAME wr_ptr in every lane (zero sync_pos difference, lane_off=0).
# That is NOT the hardware's skew. On silicon each lane's deserialiser starts at
# a DIFFERENT point in the one TX word stream (per-lane word-clock phase at
# training-exit), so the SAME source word lands at a DIFFERENT wr_ptr per lane:
# sync_pos DIFFERS => non-zero lane_off. We model that directly by starting each
# lane's source index at delta[gi] (all lanes share one out-rate clock; the skew
# is purely in the CONTENT / wr_ptr position, which is exactly what drives the
# offset computation). Lane 0 (delta 0) ends up with the LARGEST lane_off
# (= max(delta)); on DEPTH=8 an offset >= 2 makes occ = wr_ptr_sync1 - rd_ptr -
# lane_off (already -2 from the 2-flop CDC lag) unable to reach PRIME_THRESH=4
# within DEPTH-1=7 => that lane never primes => all_primed never asserts =>
# out_data NEVER updates. This is the on-silicon "no data delivered" bug.
# ===========================================================================
async def _run_index_skew(dut, deltas, scenario, cap=300):
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=[0.0] * LANES)   # one rate; skew is in the index
    await do_reset(dut)
    dut.training_mode.value = 0
    src = make_source(sync_every=32, base=0xA000)
    idx = list(deltas)                                # lane gi starts at delta[gi]
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, src, idx))
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict(scenario, False,
                f"out_data NEVER updated after {cap} out_clk cycles "
                f"(deltas={deltas}, max_off~={max(deltas)}) — PERMANENT STALL: a "
                f"lane_off >= DEPTH-PRIME_THRESH is unprimable within DEPTH=8")
        assert False, f"out_data never updated under real index skew {deltas} (Bug#1 stall)"
    # let several SYNC instances (period 32) pass so the collective re-align fires
    for _ in range(160):
        await RisingEdge(dut.out_clk)
    coh = inc = 0
    samples = []
    for _ in range(160):
        await RisingEdge(dut.out_clk)
        lanes = unpack(dut.out_data.value)
        if len(set(lanes)) == 1:
            coh += 1
            samples.append(lanes[0])
        else:
            inc += 1
    total = coh + inc
    frac = coh / total if total else 0.0
    passed = frac >= 0.9
    verdict(scenario, passed,
            f"first update cycle={cyc}; coherent={coh}/{total} ({frac*100:.0f}%); "
            f"deltas={deltas}; sample={samples[:6]}")
    assert passed, (f"out_data not coherent under real index skew {deltas} "
                    f"({coh}/{total} coherent) — deskew failed to align")


@cocotb.test()
async def test_index_skew_small(dut):
    """Real word skew spread 2 (just above the +/-1 ignore-band, so the deskew
    MUST correct it). lane_off=2 on the lead lanes — unprimable on DEPTH=8,
    primable + coherent once DEPTH holds cushion+offset."""
    await _run_index_skew(dut, [0, 2, 0, 2, 0, 2, 0, 2], "index_skew_small")


@cocotb.test()
async def test_index_skew_large(dut):
    """Real word skew up to 7 (the HW worst case). On DEPTH=8 with the unclamped
    offset this WEDGES (lane_off 2..7 unprimable) => the exact on-silicon
    'no data out / 0 packets' bug. Passes only once DEPTH holds cushion+skew."""
    await _run_index_skew(dut, [0, 1, 2, 3, 4, 5, 6, 7], "index_skew_large")
