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

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# Compiled self-gating periodic-confirm depth (tb_deskew/SYNC_CONFIRM). The K=1
# negative-control run sets SYNC_CONFIRM=1 in the env (the Makefile forwards it as
# a -pvalue to the DUT param) so the K=1 poison test knows to assert BREAKAGE,
# while the default K>=2 build asserts the self-gating COHERES. Default 2.
SYNC_CONFIRM = int(os.environ.get("SYNC_CONFIRM", "2"))

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


async def do_reset(dut, mask=0xFF):
    dut.rst_n.value = 0
    dut.training_mode.value = 1
    # lane_mask is a real DUT input that gates all_ready / all_primed /
    # all_sync_seen (the `| ~lane_mask` idiom). It MUST be driven — left
    # floating it is X and propagates into advance => out_data never updates
    # (a false "stall"). Default 0xFF = every lane active (the pre-mask
    # behaviour every scenario here assumes); the reduced-mask scenario passes
    # 0xE4 to exercise the masked-subset re-anchor.
    dut.lane_mask.value = mask
    # STICKY-POISON re-arm clear (out_clk domain W1-pulse). Held 0 by default so
    # every legacy scenario is bit-identical; the poison test pulses it explicitly.
    try:
        dut.sync_obs_clr.value = 0
    except Exception:
        pass
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


# ===========================================================================
# Scenario 7 — REDUCED-LANE re-anchor (mask 0xE4: active {2,5,6,7})
# ---------------------------------------------------------------------------
# A SW-selected narrower link: only lanes 2,5,6,7 carry traffic; the masked
# lanes (0,1,3,4) are driven 0x0000 (the PHY TX zeroes inactive lanes) and
# NEVER capture a SYNC slice. The re-anchor must cohere the 4 ACTIVE lanes
# WITHOUT waiting on the masked lanes (`| ~lane_mask` makes their sync_seen /
# has_data / primed terms don't-care), and the masked lanes' garbage anchor
# index must not stretch the span / pull a real lane's offset (the lane_mask[di]
# gates in the RTL max_dist / min_dist fold). Coherence is checked over the
# ACTIVE-lane slices only (the masked slices are don't-care 0x0000).
# ===========================================================================
ACTIVE_E4 = [2, 5, 6, 7]   # set bits of 0xE4


async def masked_lane_feeder(dut, gi):
    """A masked lane: drive a constant 0x0000 on every edge (PHY zeroes it)."""
    while True:
        await RisingEdge(lane_clk(dut, gi))
        lane_data(dut, gi).value = 0x0000


@cocotb.test()
async def test_reduced_mask_e4_reanchor(dut):
    """mask=0xE4, active lanes {2,5,6,7} phase-staggered with real word skew;
    masked lanes carry 0x0000. Assert the 4 active lanes re-align (their slices
    all present the SAME source word) without the masked lanes gating the read."""
    phases = [gi * WORD_NS for gi in range(LANES)]
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=phases)
    await do_reset(dut, mask=0xE4)
    dut.training_mode.value = 0

    src = make_source(sync_every=32, base=0xC000)
    idx = [0] * LANES
    for gi in range(LANES):
        if gi in ACTIVE_E4:
            cocotb.start_soon(lane_feeder(dut, gi, src, idx))
        else:
            cocotb.start_soon(masked_lane_feeder(dut, gi))

    cap = 400
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict("reduced_mask_e4_reanchor", False,
                f"out_data NEVER updated after {cap} cycles — masked-subset stall")
        assert False, "out_data never updated (reduced-mask stall)"

    # let several SYNC instances pass so the masked-subset re-align fires
    await RisingEdge(dut.out_clk)
    for _ in range(120):
        await RisingEdge(dut.out_clk)

    coherent_cnt = incoherent_cnt = 0
    samples = []
    for _ in range(160):
        await RisingEdge(dut.out_clk)
        lanes = unpack(dut.out_data.value)
        active = [lanes[gi] for gi in ACTIVE_E4]   # masked slices are don't-care
        if len(set(active)) == 1:
            coherent_cnt += 1
            samples.append(active[0])
        else:
            incoherent_cnt += 1
    total = coherent_cnt + incoherent_cnt
    frac = coherent_cnt / total if total else 0.0
    passed = frac >= 0.9
    verdict("reduced_mask_e4_reanchor", passed,
            f"first update cycle={cyc}; ACTIVE{ACTIVE_E4} coherent={coherent_cnt}/"
            f"{total} ({frac*100:.0f}%), incoherent={incoherent_cnt}; "
            f"sample={samples[:6]}")
    assert passed, (f"active lanes {ACTIVE_E4} not coherent under mask 0xE4 "
                    f"({coherent_cnt}/{total}) — masked-subset re-anchor failed")


# ===========================================================================
# Scenario 8 — MARGINAL-EYE SYNC slices (THE fix this file proves)
# ---------------------------------------------------------------------------
# This is the before-fail/after-pass that proves the EXACT->TOLERANT change in
# tidelink_lane_deskew g_sync_capture. On SILICON the captured SYNC slice is not
# bit-perfect: a marginal eye drops a few bits, so RX presents e.g. 0x4bac where
# the true SYNC L2 slice is 0x5b4c (Hamming distance 4). The re-anchor's per-lane
# sync_seen capture used an EXACT `==`, so a marginal slice NEVER matched ->
# all_sync_seen never asserted -> reanchored never engaged -> SYNC never cohered
# (silicon: SYNCCNT=0, 0x2124=0, RXW=0 — identical to pre-reanchor). The framer
# (tidelink_phy_sync_detect / WlinkRxLinkLayer) matches the SAME slices TOLERANTLY
# (popcount(slice ^ SYNC) <= tol), so the re-anchor was STRICTER than the framer
# it feeds — the bug.
#
# Model: keep the real cross-lane WORD skew (per-lane index delta, as in
# Scenario 6) AND corrupt every SYNC slice each lane emits by flipping a FIXED
# few-bit error mask (Hamming 3-4, within tol=4) — the marginal eye consistently
# mis-samples the same bits. PAYLOAD is left clean (the eye is marginal only on
# the rarer/edge-positioned SYNC beats in this model; corrupting payload too
# would only make coherence-by-value harder to score and is not what gates the
# re-anchor — the re-anchor keys off SYNC-slice matches alone).
#
# The SAME scenario is run twice from the Makefile/env via SYNC_REANCHOR_TOL:
#   * TOL=0 (EXACT): the dist-3/4 marginal slices never match -> sync_seen never
#     fires -> reanchored stays 0 -> NO coherent re-align (FAIL-to-cohere). The
#     test ASSERTS the tolerant outcome, so an EXACT build makes THIS test FAIL —
#     that is the "before" half (run it with -pvalue+tb_deskew/SYNC_REANCHOR_TOL=0
#     to SEE the exact-match failure; see the module header + the run log).
#   * TOL=4 (default, TOLERANT): the marginal slices match within 4 bits ->
#     sync_seen latches the TRUE SYNC index -> reanchored engages -> the active
#     lanes cohere on the SYNC source word. The test PASSES.
# We also assert the engagement observable (epoch_anchored, repurposed to carry
# `reanchored` in the SYNC_REANCHOR build — FIX 2) goes high under tolerant.
# ===========================================================================
# Per-lane FIXED marginal-eye error mask applied to the SYNC slice ONLY. Chosen
# so each is Hamming 3-4 from 0 (=> dist(corrupted_slice, true_slice) = 3-4,
# inside tol=4, outside tol=0/exact). Distinct per lane (a real eye corrupts each
# lane's slice differently).
SYNC_ERR_MASK = [
    0x000B,  # lane0: 3 bits
    0x0029,  # lane1: 3 bits
    0x00A8,  # lane2: 3 bits
    0x0150,  # lane3: 3 bits
    0x0046,  # lane4: 3 bits
    0x0805,  # lane5: 3 bits
    0x000E,  # lane6: 3 bits
    0x00D0,  # lane7: 3 bits
]


def _hd(a, b):
    return bin((a ^ b) & 0xFFFF).count("1")


async def marginal_sync_feeder(dut, gi, src, idx_box):
    """Like lane_feeder, but every SYNC slice this lane emits is corrupted by a
    FIXED few-bit error (marginal eye). Payload words pass through clean."""
    while True:
        await RisingEdge(lane_clk(dut, gi))
        t = idx_box[gi]
        w = src(t)
        if w is None:  # SYNC beat -> emit the BIT-ERRORED slice
            lane_data(dut, gi).value = sync_slice(gi) ^ SYNC_ERR_MASK[gi]
        else:
            lane_data(dut, gi).value = w
        idx_box[gi] = t + 1


@cocotb.test()
async def test_marginal_eye_sync_reanchor(dut):
    """Real cross-lane word skew + few-BIT-errored SYNC slices (dist 3-4, within
    tol=4). Under the TOLERANT capture (default TOL=4) the re-anchor engages and
    the lanes cohere; under EXACT (TOL=0, run via env) the marginal slices never
    match so it FAILS to cohere. Proves the EXACT->TOLERANT fix."""
    # Announce the marginal error margins so the log is self-documenting.
    dists = [_hd(sync_slice(gi), sync_slice(gi) ^ SYNC_ERR_MASK[gi])
             for gi in range(LANES)]
    cocotb.log.info(f"marginal_eye: per-lane dist(corrupted_sync, true_sync)={dists} "
                    f"(EXACT `==` needs 0; TOLERANT needs <= SYNC_REANCHOR_TOL)")

    deltas = [0, 1, 2, 3, 4, 5, 6, 7]   # real worst-case word skew (as idx_large)
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=[0.0] * LANES)   # one rate; skew is in the index
    await do_reset(dut)
    dut.training_mode.value = 0

    src = make_source(sync_every=32, base=0xA000)
    idx = list(deltas)
    for gi in range(LANES):
        cocotb.start_soon(marginal_sync_feeder(dut, gi, src, idx))

    cap = 400
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict("marginal_eye_sync_reanchor", False,
                f"out_data NEVER updated after {cap} cycles — stall")
        assert False, "out_data never updated under marginal-eye SYNC"

    # let several SYNC instances (period 32) pass so the re-align fires/settles
    for _ in range(200):
        await RisingEdge(dut.out_clk)

    anchored_high = 0
    coh = inc = 0
    samples = []
    span_seen = set()
    for _ in range(200):
        await RisingEdge(dut.out_clk)
        if int(dut.epoch_anchored.value) == 1:
            anchored_high += 1
            span_seen.add(int(dut.epoch_span.value))
        lanes = unpack(dut.out_data.value)
        if len(set(lanes)) == 1:
            coh += 1
            samples.append(lanes[0])
        else:
            inc += 1
    total = coh + inc
    frac = coh / total if total else 0.0
    reanchored = anchored_high > 0
    # Coherent re-align AND the engagement observable asserted = the fix worked.
    passed = (frac >= 0.9) and reanchored
    verdict("marginal_eye_sync_reanchor", passed,
            f"first update cycle={cyc}; coherent={coh}/{total} ({frac*100:.0f}%); "
            f"reanchored(obs epoch_anchored)={reanchored} "
            f"({anchored_high}/{total} beats, span={sorted(span_seen)}); "
            f"sample={samples[:6]}; deltas={deltas}")
    assert frac >= 0.9, (
        f"out_data not coherent under marginal-eye SYNC ({coh}/{total}) — with an "
        f"EXACT `==` the dist-{max(dists)} slices never match so sync_seen never "
        f"fires and the re-anchor cannot engage; TOLERANT (tol>=4) is REQUIRED. "
        f"(If this is an exact/TOL=0 run, this FAIL is the expected 'before' half.)")
    assert reanchored, (
        "re-anchor engagement observable (epoch_anchored<=reanchored) never "
        "asserted — the tolerant sync_seen did not let the re-anchor latch offsets")


# ===========================================================================
# EXPERIMENT 2 — STICKY-POISON LATCH (DEFECT 1)
# ---------------------------------------------------------------------------
# Hypothesis (from the silicon-debug planning workflow): the g_sync_capture
# block (deps/tidelink-phy/rtl/tidelink_lane_deskew.sv ~363-431) arms
# sync_seen_l out of POR and NEVER re-arms it (comment ~line 400 "cold re-arm
# is not needed"). The capture is
#     if (!sync_seen_l && popcount(lane_data ^ sync_slice) <= SYNC_REANCHOR_TOL)
#         sync_idx_l <= wr_ptr_l; sync_seen_l <= 1
# so during the LONG pre-SYNC bring-up window (training / early data, long
# before the SYNC flood is enabled) ANY word within tol (default 4) of a lane's
# SYNC slice PERMANENTLY latches a WRONG sync_idx_l. Then all_sync_seen either
# never completes or completes with mismatched per-lane indices -> wrong
# lane_off -> never coheres. The tolerant match (tol=4) makes this strictly
# WORSE than the old exact `==`.
#
# To isolate the POISON from every other effect we use a payload that is
# Hamming >= 6 from EVERY lane's SYNC slice (PAYLOAD_CLEAN below — 0x0001, dists
# [6,10,9,10,8,10,9,10]) so the ONLY within-tol words a lane ever sees are
# (a) the deliberate pre-SYNC poison word and (b) the true clean SYNC slice.
#
#   CONTROL  (poison_beats=0): clean SYNC + safe payload + real word skew ->
#            the FIRST within-tol word each lane sees IS its true SYNC slice ->
#            sync_idx_l latches the RIGHT index -> reanchored engages -> the
#            active lanes cohere on the SYNC source word. MUST PASS.
#   POISON   (poison_beats>0): BEFORE the first clean SYNC, drive each lane for
#            poison_beats with (its slice ^ a 3-bit mask) (HD=3, inside tol=4)
#            but NOT equal — at DIFFERENT per-lane skew so the poison lands at a
#            different wr_ptr per lane. The sticky latch grabs THOSE wrong
#            indices first and never re-arms -> out_data NEVER == SYNC_WORD on an
#            aligned beat (or never coheres) EVEN THOUGH the eye is bit-perfect.
#
# VERDICT: if CONTROL coheres+reanchors and POISON does NOT, DEFECT 1 CONFIRMED.
#          If the POISONED run STILL coheres, the sticky-latch hypothesis is
#          REFUTED — we say so loudly.
#
# Runs at the silicon FIFO depth: tb_deskew does NOT override DEPTH_LOG, so the
# DUT uses its own default DEPTH_LOG=5 (DEPTH=32) — the EXACT depth the FPGA/ASIC
# build compiles. No reparametrization of tb_deskew was needed (confirmed by
# reading tidelink_lane_deskew.sv:176 `parameter int DEPTH_LOG = 5`).
# ===========================================================================
PAYLOAD_CLEAN = 0x0001        # min Hamming 6 to every SYNC slice (no false-fire)


def _obs(dut):
    """Snapshot the SYNC re-anchor internal taps (tb_deskew g_obs)."""
    def g(n):
        try:
            return int(getattr(dut, n).value)
        except Exception:
            return None
    return dict(seen_wr=g("obs_sync_seen_wr"), seen_s1=g("obs_sync_seen_sync1"),
                all_seen=g("obs_all_sync_seen"), rd_safe=g("obs_sr_rd_safe"),
                reanc=g("obs_reanchored"))


@cocotb.test()
async def test_exp2_diag_reanchor(dut):
    """DIAGNOSTIC: clean SYNC + safe payload + real INDEX skew, dump the re-anchor
    taps every few beats so we can SEE whether/when sync_seen completes, rd_safe
    goes true, and reanchored latches. Not a pass/fail gate — pure observability."""
    deltas = [0, 1, 2, 3, 4, 5, 6, 7]
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=[0.0] * LANES)
    await do_reset(dut)
    dut.training_mode.value = 0
    idx = list(deltas)
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, make_source(32, base=PAYLOAD_CLEAN), idx))
    await wait_out_update(dut, 400)
    for k in range(20):
        for _ in range(8):
            await RisingEdge(dut.out_clk)
        o = _obs(dut)
        cocotb.log.info(
            f"diag k={k*8:3d}: seen_wr=0x{o['seen_wr']:02x} seen_s1=0x{o['seen_s1']:02x} "
            f"all_seen={o['all_seen']} rd_safe={o['rd_safe']} reanchored={o['reanc']}")
    # After settle: score coherence AND whether out_data ever reads SYNC_WORD.
    coh = inc = swb = 0
    for _ in range(300):
        await RisingEdge(dut.out_clk)
        lanes = unpack(dut.out_data.value)
        if len(set(lanes)) == 1:
            coh += 1
        else:
            inc += 1
        if out_val(dut) == SYNC_WORD:
            swb += 1
    o = _obs(dut)
    verdict("exp2_diag_reanchor", True,
            f"final reanchored={o['reanc']} seen_wr=0x{o['seen_wr']:02x}; "
            f"coherent={coh}/{coh+inc}; out_data==SYNC_WORD on {swb} beats")

# Per-lane 3-bit poison mask: applied to a lane's OWN sync_slice so the poison
# word is Hamming-3 from the slice (inside tol=4) but != the slice. Distinct per
# lane (a real pre-SYNC stream corrupts each lane differently).
POISON_MASK = [0x0007, 0x0151, 0x000B, 0x0029, 0x00A8, 0x0150, 0x0046, 0x0805]


async def poison_then_clean_feeder(dut, gi, idx_box, poison_beats, poison_word,
                                   sync_every):
    """Drive `poison_beats` pre-SYNC poison words (slice^mask, HD=3, within tol)
    at THIS lane's skewed index, THEN the clean stream (safe payload + a clean
    SYNC slice every `sync_every` words). The index advances through BOTH phases
    so the clean SYNC lands at the SAME per-lane-skewed wr_ptr as the proven
    clean diagnostic (idx_box[gi] starts at delta[gi]). The poison is therefore a
    PURELY PREPENDED within-tol burst; nothing else about the skew changes."""
    while True:
        await RisingEdge(lane_clk(dut, gi))
        t = idx_box[gi]
        if t < poison_beats:
            lane_data(dut, gi).value = poison_word          # POISON within-tol
        elif sync_every and (t % sync_every == 0):
            lane_data(dut, gi).value = sync_slice(gi)        # clean true SYNC
        else:
            lane_data(dut, gi).value = PAYLOAD_CLEAN
        idx_box[gi] = t + 1


async def _pulse_sync_obs_clr(dut, hold_cycles=2):
    """Model the WavD2DGpio sync_obs_clr_pulse (SoC 0x44032100[5] W1-pulse) in the
    out_clk domain: hold the clear high a couple of out_clk beats (the DUT 2-flop
    re-syncs it into each lane clock and edge-detects a single re-arm pulse), then
    drop it. Re-arms every lane's sticky sync_seen_l + sync_idx_l AND the read-side
    `reanchored` latch so the next clean SYNC captures TRUE indices."""
    dut.sync_obs_clr.value = 1
    for _ in range(hold_cycles):
        await RisingEdge(dut.out_clk)
    dut.sync_obs_clr.value = 0
    await RisingEdge(dut.out_clk)


async def _run_sticky_poison(dut, poison_beats, scenario, clear_after_poison=False):
    """Shared body for the poison CONTROL (poison_beats=0) and POISON runs.
    When clear_after_poison is True, pulse sync_obs_clr ONCE after the poison
    window (and after the clean SYNC has started flowing) — the SW re-arm step.
    Returns (coherent_frac, reanchored, sync_word_beats, cyc)."""
    deltas = [0, 1, 2, 3, 4, 5, 6, 7]   # real worst-case cross-lane word skew
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut, phase_ns=[0.0] * LANES)   # one rate; skew is in the index
    await do_reset(dut)                               # mask 0xFF (all active)
    dut.training_mode.value = 0

    # Pre-compute the per-lane poison word once (slice ^ 3-bit mask).
    poison_words = [sync_slice(gi) ^ POISON_MASK[gi] for gi in range(LANES)]
    pdists = [_hd(poison_words[gi], sync_slice(gi)) for gi in range(LANES)]
    cocotb.log.info(f"{scenario}: poison_beats={poison_beats}; per-lane "
                    f"dist(poison,slice)={pdists} (all must be <=4 to be 'within tol'); "
                    f"payload=0x{PAYLOAD_CLEAN:04x} (HD>=6 from every slice); "
                    f"clear_after_poison={clear_after_poison}")

    idx = list(deltas)   # clean SYNC lands at a per-lane-skewed wr_ptr
    for gi in range(LANES):
        cocotb.start_soon(poison_then_clean_feeder(
            dut, gi, idx, poison_beats, poison_words[gi], sync_every=32))

    cap = 500
    updated, cyc, first, last = await wait_out_update(dut, cap)
    if not updated:
        verdict(scenario, False,
                f"out_data NEVER updated after {cap} cycles (poison_beats={poison_beats})")
        return 0.0, False, 0, cyc

    # SW RE-ARM: pulse the clear AFTER the poison window has been consumed (the
    # sticky latch has grabbed the wrong poison indices) and the clean SYNC flood
    # has begun, so the re-armed capture grabs the TRUE SYNC index. poison_beats
    # lane edges + a margin guarantees we are past the poison and into clean SYNC.
    if clear_after_poison:
        for _ in range(poison_beats + 40):
            await RisingEdge(dut.out_clk)
        o = _obs(dut)
        cocotb.log.info(f"{scenario}: PRE-CLEAR taps seen_wr=0x{o['seen_wr']:02x} "
                        f"reanchored={o['reanc']} (about to pulse sync_obs_clr)")
        await _pulse_sync_obs_clr(dut)
        o = _obs(dut)
        cocotb.log.info(f"{scenario}: POST-CLEAR taps seen_wr=0x{o['seen_wr']:02x} "
                        f"reanchored={o['reanc']} (re-armed; awaiting clean re-capture)")

    # Let many SYNC instances (period 32) pass so any honest re-align settles.
    # (Longer for the poison run: the true clean SYNC starts only after the
    #  poison_beats prefix, so allow the same post-clean settle the control gets.)
    for _ in range(300 + poison_beats):
        await RisingEdge(dut.out_clk)

    # Sample on the FALLING edge (settled mid-cycle) to remove the cocotb
    # rising-edge update/read delta-race (see Experiment 3 diagnostic). CONTROL
    # and POISON use the identical sampling, so the SYNC_WORD-beats differential
    # is the experiment, not a sampling artifact.
    from cocotb.triggers import FallingEdge
    coh = inc = 0
    samples = []
    sync_word_beats = 0
    reanc_high = 0
    for _ in range(300):
        await FallingEdge(dut.out_clk)
        o = _obs(dut)
        if o["reanc"] == 1:
            reanc_high += 1
        lanes = unpack(dut.out_data.value)
        if len(set(lanes)) == 1:
            coh += 1
            samples.append(lanes[0])
        else:
            inc += 1
        if out_val(dut) == SYNC_WORD:
            sync_word_beats += 1
    total = coh + inc
    frac = coh / total if total else 0.0
    reanchored = reanc_high > 0
    o = _obs(dut)
    verdict(scenario, (frac >= 0.9),
            f"poison_beats={poison_beats}; coherent={coh}/{total} ({frac*100:.0f}%); "
            f"reanchored(obs)={reanchored} ({reanc_high}/{total} beats); "
            f"seen_wr=0x{o['seen_wr']:02x} all_seen={o['all_seen']}; "
            f"out_data==SYNC_WORD on {sync_word_beats} beats; "
            f"sample={sorted(set(samples))[:6]}")
    return frac, reanchored, sync_word_beats, cyc


@cocotb.test()
async def test_exp2_poison_control(dut):
    """CONTROL: clean SYNC + safe payload + real skew, NO pre-SYNC poison.
    The first within-tol word each lane sees IS its true SYNC slice -> sticky
    latch grabs the RIGHT index -> re-anchor engages -> lanes cohere. Proves the
    poison test is sound (it's the poison, not the test, that breaks coherence)."""
    frac, reanchored, swb, cyc = await _run_sticky_poison(
        dut, poison_beats=0, scenario="exp2_poison_CONTROL")
    assert frac >= 0.9, (
        f"CONTROL FAILED to cohere ({frac*100:.0f}%) with NO poison — the test "
        f"harness itself cannot reanchor, so the poison experiment is "
        f"inconclusive. Investigate before trusting Experiment 2.")
    assert reanchored, "CONTROL: re-anchor never engaged even with clean SYNC"
    assert swb > 0, ("CONTROL: out_data never read the true SYNC_WORD on an "
                     "aligned beat even though re-anchor engaged")


@cocotb.test()
async def test_exp2_poison_active_noclear(dut):
    """POISON, NO RE-ARM. Pre-SYNC window of within-tol (HD=3) poison words on
    every lane BEFORE the clean SYNC flood, NO clear pulse.

    2026-06-23 — SELF-GATING is now the PRIMARY fix. The per-lane SYNC capture
    only commits a sync_idx after SYNC_CONFIRM consecutive periodic-consistent
    matches, so on the DEFAULT K>=2 build the continuous pre-SYNC poison (which
    matches every beat, keeping the gap counter from ever saturating) is REJECTED
    and the link COHERES without any clear — the defect is GONE by construction.
    On a K=1 build (degenerate first-arrival latch, the historical behaviour) the
    SAME poison STILL breaks coherence — the negative control. So the asserted
    direction is keyed on the compiled SYNC_CONFIRM: K>=2 must COHERE (defect
    resolved by the self-gating arm), K=1 must BREAK."""
    frac, reanchored, swb, cyc = await _run_sticky_poison(
        dut, poison_beats=40, scenario="exp2_poison_NOCLEAR",
        clear_after_poison=False)
    # "Broke" = the eye is bit-perfect yet the SYNC word never assembles on an
    # aligned beat (the original silicon fingerprint).
    broke = (swb == 0) or (frac < 0.5)
    cohered = (frac >= 0.9) and (swb > 0)
    if SYNC_CONFIRM >= 2:
        verdict("exp2_poison_DEFECT1_noclear", cohered,
                f"K(SYNC_CONFIRM)={SYNC_CONFIRM}; poisoned (no clear) coherence="
                f"{frac*100:.0f}% reanchored={reanchored} SYNC_WORD_beats={swb} -> "
                f"DEFECT 1 {'RESOLVED by self-gating (coheres WITHOUT a clear)' if cohered else 'NOT resolved — self-gating failed'}")
        assert cohered, (
            f"SELF-GATING (K={SYNC_CONFIRM}) did NOT resolve the no-clear poison "
            f"(coherent={frac*100:.0f}%, SYNC_WORD_beats={swb}). The periodic-confirm "
            f"arm must reject the pre-SYNC poison on its own (no SW clear).")
    else:
        verdict("exp2_poison_DEFECT1_noclear", broke,
                f"K=1 (degenerate latch); poisoned (no clear) coherence={frac*100:.0f}% "
                f"reanchored={reanchored} SYNC_WORD_beats={swb} -> DEFECT 1 "
                f"{'STILL PRESENT without the self-gating gate (poison breaks a bit-perfect eye)' if broke else 'absent'}")
        assert broke, (
            f"K=1 NO-CLEAR poison did NOT break coherence "
            f"(coherent={frac*100:.0f}%, SYNC_WORD_beats={swb}). The degenerate "
            f"first-arrival latch MUST still fail so the K>=2 self-gating PASS proves "
            f"the consecutive-consistent gate is the fix.")


@cocotb.test()
async def test_exp2_poison_cleared(dut):
    """POISON + SW RE-ARM (the FIX, 'after' half): same pre-SYNC poison, but pulse
    sync_obs_clr ONCE after the poison window (clean SYNC now flowing). The clear
    re-arms every lane's sticky sync_seen_l + the read-side `reanchored` latch, so
    the re-anchor re-measures on the TRUE clean-SYNC indices and out_data reads
    TIDELINK_SYNC_WORD on the aligned beats. PASSES when coherence is RESTORED."""
    frac, reanchored, swb, cyc = await _run_sticky_poison(
        dut, poison_beats=40, scenario="exp2_poison_CLEARED",
        clear_after_poison=True)
    fixed = (frac >= 0.9) and (swb > 0) and reanchored
    verdict("exp2_poison_FIX", fixed,
            f"poisoned+cleared coherence={frac*100:.0f}% reanchored={reanchored} "
            f"SYNC_WORD_beats={swb} -> STICKY-POISON FIX "
            f"{'CONFIRMED (re-arm restores a bit-perfect eye)' if fixed else 'FAILED'}")
    assert frac >= 0.9, (
        f"AFTER FIX: poison+clear did NOT cohere ({frac*100:.0f}%). The SW re-arm "
        f"pulse must let the re-anchor re-capture the clean SYNC indices.")
    assert swb > 0, (
        "AFTER FIX: out_data never read the true SYNC_WORD on an aligned beat even "
        "with the re-arm — the cleared capture did not latch the clean SYNC index.")
    assert reanchored, "AFTER FIX: re-anchor never re-engaged after the clear pulse"


# ===========================================================================
# EXPERIMENT 2b — SELF-GATING PERIODIC-CONFIRM ARM (THE PRIMARY FIX)
# ---------------------------------------------------------------------------
# These two tests prove the self-gating arm (deps/tidelink-phy/rtl/
# tidelink_lane_deskew.sv g_sync_capture, SYNC_CONFIRM consecutive periodic
# re-matches) rejects the pre-SYNC poison WITHOUT any SW clear pulse — so it
# cannot be defeated by the silicon-dead APB->PHY clear routing.
#
#   test_exp2b_poison_selfgating_noclear (DEFAULT build, K>=2): the SAME poison
#       window as test_exp2_poison_active_noclear, NO clear pulse. Because the
#       sticky latch now ONLY commits a sync_idx after SYNC_CONFIRM consecutive
#       matches that recur at a consistent periodic index, the continuous
#       within-tol poison (which matches every beat, so the gap counter never
#       saturates) NEVER commits — only the genuine periodic SYNC does. So the
#       link COHERES (out_data == SYNC_WORD on aligned beats, reanchored engages
#       on the CORRECT indices) with NO clear. This is the KEY NEW GATE.
#
#   test_exp2b_negctl_k1_poison (K=1 build only): with SYNC_CONFIRM=1 the latch
#       degenerates to the historical first-arrival capture (no consecutive-
#       consistent requirement), so the SAME poison STILL breaks coherence —
#       proving the consecutive-consistent gate (K>=2), not the test harness, is
#       what fixes it. Skipped (auto-pass) on a K>=2 build; the dedicated K=1
#       Makefile run (SYNC_CONFIRM=1) exercises it.
# ===========================================================================
@cocotb.test()
async def test_exp2b_poison_selfgating_noclear(dut):
    """KEY NEW GATE: pre-SYNC poison, NO SW clear. The self-gating periodic-confirm
    arm (K>=2) rejects the poison on its own, so the link coheres and out_data
    reads the true SYNC_WORD on aligned beats WITHOUT any clear pulse. On a K=1
    build this would FAIL (that is the negative control below)."""
    frac, reanchored, swb, cyc = await _run_sticky_poison(
        dut, poison_beats=40, scenario="exp2b_poison_SELFGATING_noclear",
        clear_after_poison=False)
    selfgated = (frac >= 0.9) and (swb > 0) and reanchored
    verdict("exp2b_poison_SELFGATING", selfgated,
            f"K(SYNC_CONFIRM)={SYNC_CONFIRM}; poisoned, NO clear -> coherence="
            f"{frac*100:.0f}% reanchored={reanchored} SYNC_WORD_beats={swb} -> "
            f"SELF-GATING {'REJECTS the poison WITHOUT a clear (PRIMARY fix proven)' if selfgated else 'FAILED to reject the poison'}")
    if SYNC_CONFIRM >= 2:
        assert frac >= 0.9, (
            f"SELF-GATING (K={SYNC_CONFIRM}) did NOT cohere under poison without a "
            f"clear ({frac*100:.0f}%). The periodic-confirm arm must reject the "
            f"pre-SYNC poison on its own — the whole point of the primary fix.")
        assert swb > 0, (
            "SELF-GATING: out_data never read the true SYNC_WORD on an aligned beat "
            "without a clear — the periodic-confirm arm did not capture the clean "
            "SYNC index.")
        assert reanchored, (
            "SELF-GATING: re-anchor never engaged without a clear — the periodic "
            "confirm never committed a sync_idx on any lane.")
    else:
        # K=1 build: this test is not the gate (the negative control owns the K=1
        # case). Record the broken outcome but do not fail the K=1 regression here.
        cocotb.log.info(
            f"K=1 build: self-gating disabled; poison-noclear coherence={frac*100:.0f}% "
            f"(expected BROKEN — asserted by test_exp2b_negctl_k1_poison)")


@cocotb.test()
async def test_exp2b_negctl_k1_poison(dut):
    """NEGATIVE CONTROL: with SYNC_CONFIRM=1 (degenerate first-arrival latch, no
    consecutive-consistent gate) the SAME pre-SYNC poison, NO clear, STILL breaks
    coherence — proving the K>=2 periodic-confirm gate is what fixes the poison,
    not the test harness. On a K>=2 build this auto-passes (the gate is owned by
    test_exp2b_poison_selfgating_noclear); run the K=1 Makefile variant
    (SYNC_CONFIRM=1) to exercise the real negative control."""
    if SYNC_CONFIRM != 1:
        verdict("exp2b_negctl_k1", True,
                f"SKIP: build K(SYNC_CONFIRM)={SYNC_CONFIRM} != 1; the K=1 negative "
                f"control runs only in the dedicated SYNC_CONFIRM=1 build")
        return
    frac, reanchored, swb, cyc = await _run_sticky_poison(
        dut, poison_beats=40, scenario="exp2b_negctl_K1_poison",
        clear_after_poison=False)
    # Same silicon fingerprint as the original no-clear defect: the eye is bit-
    # perfect yet the SYNC word never assembles coherently on an aligned beat.
    broke = (swb == 0) or (frac < 0.5)
    verdict("exp2b_negctl_K1", broke,
            f"K=1 (no consecutive gate); poisoned, NO clear -> coherence={frac*100:.0f}% "
            f"reanchored={reanchored} SYNC_WORD_beats={swb} -> NEGATIVE CONTROL "
            f"{'poison STILL breaks K=1 (so K>=2 is the fix)' if broke else 'poison did NOT break K=1 (gate attribution WEAKENED)'}")
    assert broke, (
        f"K=1 NEGATIVE CONTROL did NOT break under poison "
        f"(coherent={frac*100:.0f}%, SYNC_WORD_beats={swb}). The degenerate "
        f"first-arrival latch MUST still fail so the K>=2 self-gating PASS proves "
        f"the consecutive-consistent gate is the fix.")


# ===========================================================================
# EXPERIMENT 3 — MASKED REFERENCE CLOCK (DEFECT 2)
# ---------------------------------------------------------------------------
# Hypothesis: on silicon the deskew out_clk = gpiorx_0_io_link_clk
# (WavD2DGpio.v:707) = LANE 0's recovered word clock. But under mask 0xE4 lane 0
# is MASKED OUT (active lanes {2,5,6,7}); the PHY zeroes lane 0's wire. The
# same-beat all_sync_seen CDC re-sample (deskew.sv g_sync_sync ~594-619 and the
# all_sync_seen fold ~918) runs in out_clk. So the alignment REFERENCE CLOCK is a
# masked, free-running mod-16 divider at an ARBITRARY phase versus the active
# lanes' write clocks. The per-lane sync_seen flags cross into out_clk through a
# 2-flop sync, and all_sync_seen / sr_rd_safe / the lane_off latch all evaluate
# on out_clk edges. If out_clk's phase relative to the active lanes is unlucky,
# the latch beat where the 4 active sync_idx are all valid AND rd_ptr has swept
# past the span may never coincide -> reanchored=0 / no coherence.
#
# MODEL: tb_deskew already exposes out_clk as an independent input and per-lane
# scalar lane_clkN. We drive out_clk AND lane_clk0 from the SAME phase-offset
# clock (out_clk == lane 0's clock, the silicon wiring), hold lane_data0 = 0x0000
# (masked-wire value), set mask=0xE4, apply a fixed cross-lane word skew on the
# active lanes {2,5,6,7}, and run the clean SYNC flood. We SWEEP the lane-0 /
# out_clk phase offset across the word period and ask: does coherence depend on
# that phase? A deterministic PHASE LOTTERY (coherent for some offsets, dead for
# others) = DEFECT 2 CONFIRMED. Phase-INDEPENDENT coherence = REFUTED.
#
# RESULT (2026-06-23): REFUTED. A FIRST pass that sampled out_data on the out_clk
# RISING edge showed a fake lottery (dead at 2,5ns). The diagnostic
# test_exp3_diag_dead_offsets read the SAME dead offsets on the FALLING edge and
# found the active-lane slices COHERENT with reanchored=1 — i.e. the "dead"
# offsets were a cocotb rising-edge update/read DELTA-RACE, not an RTL failure.
# With race-free FALLING-edge sampling the masked-reference sweep is 97% coherent
# at EVERY phase (0..19ns, spread 0%). The masked, phase-arbitrary lane-0
# reference clock does NOT by itself break the active-lane re-anchor in this unit
# model (the eight word clocks are frequency-locked, which this model preserves).
# ===========================================================================
ACTIVE_E4_X3 = [2, 5, 6, 7]


async def _run_masked_phase(dut, lane0_phase_ns, scenario, mask=0xE4):
    """out_clk == lane0 clock at phase lane0_phase_ns. mask=0xE4 (default) masks
    lane 0 (data 0x0000) = the silicon defect-2 condition: the alignment reference
    clock is a masked, free-running divider. mask=0xFF (the ISOLATION CONTROL)
    keeps lane 0 ACTIVE (carries skewed clean SYNC like any other lane) on the
    SAME out_clk wiring — if THAT sweep is phase-independent, the phase lottery is
    SPECIFIC to lane 0 being masked (defect 2), not a tb clocking artifact.
    Returns (coherent frac over the active lanes, reanchored, cyc)."""
    lane0_active = bool((mask >> 0) & 1)
    active = [gi for gi in range(LANES) if (mask >> gi) & 1]

    # out_clk is driven by an explicit coroutine at the SAME phase as lane_clk0 so
    # the deskew read/reference clock == the lane-0 recovered clock (silicon wiring).
    async def ref_clock():
        if lane0_phase_ns:
            await Timer(lane0_phase_ns, units="ns")
        v = 0
        half = WORD_NS / 2.0
        while True:
            dut.out_clk.value = v
            dut.lane_clk0.value = v       # lane0 == out_clk source (silicon wiring)
            v ^= 1
            await Timer(half, units="ns")

    dut.out_clk.value = 0
    cocotb.start_soon(ref_clock())

    # Active lanes (other than lane 0, whose clock IS out_clk) get a real cross-
    # lane word skew (phase stagger). Lane 0's generator from start_lane_clocks is
    # NOT started (ref_clock drives lane_clk0); lane 0 runs at the out_clk phase.
    phases = [0.0] * LANES
    skew_lanes = [gi for gi in active if gi != 0]
    for k, gi in enumerate(skew_lanes):
        phases[gi] = (k + 1) * WORD_NS     # 1..N word-periods of skew on active lanes
    clks = [LaneClock(dut, gi, phase=phases[gi]) for gi in range(1, LANES)]
    for c in clks:
        cocotb.start_soon(c.run())

    await do_reset(dut, mask=mask)
    dut.training_mode.value = 0

    idx = [0] * LANES
    for gi in range(LANES):
        if gi in active:
            cocotb.start_soon(lane_feeder(dut, gi, make_source(32, base=PAYLOAD_CLEAN), idx))
        else:
            if gi != 0:
                cocotb.start_soon(masked_lane_feeder(dut, gi))
    if not lane0_active:
        lane_data(dut, 0).value = 0x0000   # masked lane: PHY zeroes it

    # Score coherence over whichever lanes are active (lane 0 included only when
    # it is active in the mask).
    score_lanes = active

    from cocotb.triggers import FallingEdge
    # Let the re-anchor settle. Sample on the FALLING edge of out_clk: out_data is
    # registered on the RISING edge, so reading at the falling edge is mid-cycle
    # and SETTLED — this removes the cocotb rising-edge update/read delta-race that
    # otherwise mis-scores a phase-offset out_clk as "incoherent" even when the RTL
    # has assembled the word correctly (proven by test_exp3_diag_dead_offsets).
    for _ in range(500):
        await RisingEdge(dut.out_clk)

    anchored_high = 0
    coh = inc = 0
    for _ in range(200):
        await FallingEdge(dut.out_clk)
        if int(dut.epoch_anchored.value) == 1:
            anchored_high += 1
        lanes = unpack(dut.out_data.value)
        act = [lanes[gi] for gi in score_lanes]
        if len(set(act)) == 1:
            coh += 1
        else:
            inc += 1
    total = coh + inc
    frac = coh / total if total else 0.0
    reanchored = anchored_high > 0
    return frac, reanchored, 0


@cocotb.test()
async def test_exp3_masked_phase_sweep(dut):
    """Sweep the masked lane-0 / out_clk phase across the word period; report
    coherence per offset. PHASE-DEPENDENT coherence = DEFECT 2 CONFIRMED
    (deterministic phase lottery); phase-INDEPENDENT = REFUTED."""
    # A few representative offsets across one word period (0..WORD_NS).
    offsets = [0.0, 2.0, 5.0, 7.0, 10.0, 13.0, 17.0, 19.0]
    results = []
    for off in offsets:
        # Each offset needs a fresh DUT state; re-run reset+feeders inside helper.
        # cocotb runs one coroutine tree per @test, so we serialise the sweep here
        # and rely on do_reset to re-zero the FIFO/pointers between offsets.
        frac, reanchored, cyc = await _run_masked_phase(
            dut, lane0_phase_ns=off, scenario=f"exp3_phase_{off:g}ns")
        results.append((off, frac, reanchored))
        cocotb.log.info(f"exp3 offset={off:g}ns -> coherent={frac*100:.0f}% "
                        f"reanchored={reanchored} (first update @cyc{cyc})")

    fracs = [r[1] for r in results]
    coherent_offsets = [r[0] for r in results if r[1] >= 0.9]
    dead_offsets = [r[0] for r in results if r[1] < 0.5]
    spread = max(fracs) - min(fracs)
    phase_dependent = (len(coherent_offsets) > 0 and len(dead_offsets) > 0) or spread >= 0.5
    detail = (f"per-offset coherent%={[f'{r[0]:g}ns:{r[1]*100:.0f}%' for r in results]}; "
              f"coherent_offsets={coherent_offsets}; dead_offsets={dead_offsets}; "
              f"spread={spread*100:.0f}% -> DEFECT 2 "
              f"{'CONFIRMED (phase lottery, not eye)' if phase_dependent else 'REFUTED (phase-independent)'}")
    verdict("exp3_masked_phase_DEFECT2", phase_dependent, detail)
    # We do NOT hard-assert a direction: the experiment is designed to be able to
    # REFUTE. The verdict line above carries the CONFIRMED/REFUTED conclusion.
    # A bare assert keeps the test green so the log (not an exception) is the
    # deliverable; flip to `assert phase_dependent` to gate CI on the defect.
    assert True


@cocotb.test()
async def test_exp3_diag_dead_offsets(dut):
    """DIAGNOSTIC for DEFECT 2: re-run the masked sweep at the DEAD offsets and the
    LIVE offsets, dumping the re-anchor taps (obs_*) and reading out_data on the
    out_clk FALLING edge (off the rising-edge sampling race). Distinguishes a
    GENUINE RTL phase failure (all_sync_seen never co-asserts with sr_rd_safe on a
    latch beat, OR reanchored fires on a phase-warped reference and assembles a
    wrong word) from a cocotb delta-cycle sampling artifact (taps healthy, only
    the Python read races). Pure observability."""
    for off in [2.0, 5.0, 10.0]:   # 2,5 = dead in the masked sweep; 10 = live
        # Fresh feeders per offset (helper drives reset + clocks).
        async def ref_clock(p=off):
            if p:
                await Timer(p, units="ns")
            v = 0
            while True:
                dut.out_clk.value = v
                dut.lane_clk0.value = v
                v ^= 1
                await Timer(WORD_NS / 2.0, units="ns")
        dut.out_clk.value = 0
        cocotb.start_soon(ref_clock())
        phases = [0.0] * LANES
        for k, gi in enumerate(ACTIVE_E4_X3):
            phases[gi] = (k + 1) * WORD_NS
        for gi in range(1, LANES):
            cocotb.start_soon(LaneClock(dut, gi, phase=phases[gi]).run())
        await do_reset(dut, mask=0xE4)
        dut.training_mode.value = 0
        idx = [0] * LANES
        for gi in range(LANES):
            if gi in ACTIVE_E4_X3:
                cocotb.start_soon(lane_feeder(dut, gi, make_source(32, base=PAYLOAD_CLEAN), idx))
            elif gi != 0:
                cocotb.start_soon(masked_lane_feeder(dut, gi))
        lane_data(dut, 0).value = 0x0000
        # Let it run a long while, then sample taps + falling-edge out_data.
        for _ in range(400):
            await RisingEdge(dut.out_clk)
        o = _obs(dut)
        # Read out_data on the FALLING edge (mid-cycle, settled, no rising race).
        from cocotb.triggers import FallingEdge
        await FallingEdge(dut.out_clk)
        lanes = unpack(dut.out_data.value)
        act = [lanes[gi] for gi in ACTIVE_E4_X3]
        coherent = len(set(act)) == 1
        cocotb.log.info(
            f"exp3-DIAG off={off:g}ns: seen_wr=0x{o['seen_wr']:02x} "
            f"seen_s1=0x{o['seen_s1']:02x} all_seen={o['all_seen']} "
            f"rd_safe={o['rd_safe']} reanchored={o['reanc']} | "
            f"active-slice out_data={[hex(x) for x in act]} coherent={coherent}")
        # tear everything down for the next offset by toggling reset
        dut.rst_n.value = 0
        await Timer(4 * WORD_NS, units="ns")
    verdict("exp3_diag_dead_offsets", True, "see per-offset tap dump above")


@cocotb.test()
async def test_exp3_unmasked_phase_control(dut):
    """ISOLATION CONTROL for DEFECT 2: the SAME lane-0/out_clk phase sweep, but
    lane 0 ACTIVE (mask=0xFF) — lane 0 carries its skewed clean SYNC like every
    other lane, on the SAME out_clk wiring. If coherence here is PHASE-INDEPENDENT
    (alive at every offset), the dead offsets in the masked sweep are SPECIFIC to
    lane 0 being MASKED (its reference clock free-running, no live data to anchor
    the reference) — isolating the lottery to DEFECT 2, not a tb clocking
    artifact. If this control ALSO goes dead at some offsets, the masked-clock
    attribution is WEAKENED (the effect is partly generic out_clk/lane0-coincident
    clocking)."""
    offsets = [0.0, 2.0, 5.0, 7.0, 10.0, 13.0, 17.0, 19.0]
    results = []
    for off in offsets:
        frac, reanchored, cyc = await _run_masked_phase(
            dut, lane0_phase_ns=off, scenario=f"exp3ctl_phase_{off:g}ns", mask=0xFF)
        results.append((off, frac, reanchored))
        cocotb.log.info(f"exp3-CONTROL(mask=0xFF) offset={off:g}ns -> "
                        f"coherent={frac*100:.0f}% reanchored={reanchored} (@cyc{cyc})")
    fracs = [r[1] for r in results]
    dead_offsets = [r[0] for r in results if r[1] < 0.5]
    coherent_offsets = [r[0] for r in results if r[1] >= 0.9]
    phase_independent = (len(dead_offsets) == 0)
    detail = (f"per-offset coherent%={[f'{r[0]:g}ns:{r[1]*100:.0f}%' for r in results]}; "
              f"coherent_offsets={coherent_offsets}; dead_offsets={dead_offsets} -> "
              f"control is {'PHASE-INDEPENDENT (lottery is masking-specific => DEFECT 2 isolated)' if phase_independent else 'ALSO phase-dependent (attribution weakened)'}")
    verdict("exp3_unmasked_phase_CONTROL", phase_independent, detail)
    assert True
