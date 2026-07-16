"""REDUCED-LANE link unit test for tidelink_lane_deskew.sv (V2, deps/tidelink-phy).

Proves the lane_mask fix that unblocks a narrower (SW-selected subset) link:

  THE BLOCKER (pre-fix): the word read was gated on ALL 8 lanes carrying data
    all_ready  = &lane_has_data      # every lane occ != 0
    all_primed = &lane_primed        # every lane occ >= PRIME_THRESH
  so a masked/marginal lane that never fills its FIFO held all_ready low forever
  -> out_valid never asserts -> the whole 128-bit word path wedges.

  THE FIX: readiness ignores masked-out lanes via the calibrator/sync-detect
  `| ~lane_mask` idiom:
    all_ready  = &(lane_has_data | ~lane_mask)
    all_primed = &(lane_primed   | ~lane_mask)

WHAT THIS TEST DRIVES
  - lane_mask = 0xE4  (lanes 2,5,6,7 ACTIVE; lanes 0,1,3,4 masked OFF)
  - the MASKED lanes get NO clock and NO data (FIFOs stay empty == the dead /
    marginal conductor the mask exists to drop).
  - the ACTIVE lanes stream a coherent incrementing word.

ASSERTIONS
  1. masked_subset_link_up : out_valid asserts and out_data ACTUALLY updates
     (pre-fix: never — permanent stall). The ACTIVE lanes' 16-bit slices carry
     the driven values; the masked slices are don't-care (Wlink RX gather drops
     them by mask downstream).
  2. default_8lane_noregression : lane_mask=0xFF with all 8 lanes fed behaves
     exactly as before (out_valid asserts, all-lanes-coherent words flow).
  3. masked_lane_garbage : same 0xE4 subset but the masked lanes are CLOCKED and
     fed GARBAGE — the active-lane word path must still flow (masked occupancy /
     content must not gate or corrupt the read).

The module under test is DEPTH_LOG=5 (DEPTH=32, PRIME_THRESH=5).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

LANES = 8
WIDTH = 16
PRIME_THRESH = 5
WORD_NS = 20

ACTIVE_MASK = 0xE4  # lanes 2,5,6,7 active; 0,1,3,4 masked
ACTIVE_LANES = [i for i in range(LANES) if (ACTIVE_MASK >> i) & 1]
MASKED_LANES = [i for i in range(LANES) if not (ACTIVE_MASK >> i) & 1]


def lane_clk(dut, gi):
    return getattr(dut, f"lane_clk{gi}")


def lane_data(dut, gi):
    return getattr(dut, f"lane_data{gi}")


def _word_bits(dut):
    """out_data as a 128-char MSB-first '0/1/x/z' string (X-tolerant)."""
    return dut.out_data.value.binstr.lower()


def _slice_int(bits, gi):
    """Resolve lane gi's 16-bit slice to an int, or None if it holds X/Z.

    Masked-out lanes are never written, so their FIFO slice reads X — that is
    EXPECTED and don't-care (the active lanes carry the link). Parsed from the
    binary string so one X lane does not poison the whole-word read and the
    slicing is independent of the LogicArray indexing convention. bits[0] is the
    MSB (bit 127); lane gi occupies bits [gi*16 +: 16]."""
    hi = 128 - (gi * WIDTH + WIDTH)   # string index of this lane's MSB
    seg = bits[hi:hi + WIDTH]
    if any(c not in "01" for c in seg):
        return None
    return int(seg, 2)


def unpack_active(dut, lanes_of_interest):
    bits = _word_bits(dut)
    return {gi: _slice_int(bits, gi) for gi in lanes_of_interest}


def verdict(scenario, passed, detail):
    res = "PASS" if passed else "FAIL"
    line = f"VERDICT scenario={scenario} result={res} detail={detail}"
    print(line)
    cocotb.log.info(line)
    return line


class LaneClock:
    """Independent scalar lane clock; .stalled freezes it (== dead conductor)."""

    def __init__(self, dut, gi, half=WORD_NS / 2.0, phase=0.0, run=True):
        self.sig = lane_clk(dut, gi)
        self.half = half
        self.phase = phase
        self.stalled = not run
        self.sig.value = 0

    async def run(self):
        if self.phase:
            await Timer(self.phase, units="ns")
        val = 0
        while True:
            while self.stalled:
                await Timer(self.half, units="ns")
            self.sig.value = val
            val ^= 1
            await Timer(self.half, units="ns")


def start_lane_clocks(dut, active_only=None, phase_ns=None):
    if phase_ns is None:
        phase_ns = [0.0] * LANES
    clks = []
    for gi in range(LANES):
        run = True if active_only is None else (gi in active_only)
        c = LaneClock(dut, gi, phase=phase_ns[gi], run=run)
        cocotb.start_soon(c.run())
        clks.append(c)
    return clks


async def do_reset(dut, mask):
    dut.rst_n.value = 0
    dut.training_mode.value = 0
    dut.lane_mask.value = mask
    for gi in range(LANES):
        lane_data(dut, gi).value = 0
    await Timer(5 * WORD_NS, units="ns")
    dut.rst_n.value = 1
    await Timer(3 * WORD_NS, units="ns")


async def lane_feeder(dut, gi, idx_box, base=0xA000, garbage=False):
    """On each lane_clk[gi] edge present this lane's word and advance its index."""
    import random
    rng = random.Random(0xBEEF + gi)
    while True:
        await RisingEdge(lane_clk(dut, gi))
        if garbage:
            lane_data(dut, gi).value = rng.randint(0, 0xFFFF)
        else:
            t = idx_box[gi]
            lane_data(dut, gi).value = (base | (t & 0x0FFF)) & 0xFFFF
            idx_box[gi] = t + 1


async def wait_out_valid(dut, cap_cycles, active):
    """Wait until out_valid asserts AND the ACTIVE-lane slices change. Returns
    (ok, cyc). X on masked lanes is ignored — only active slices are watched."""
    await RisingEdge(dut.out_clk)
    prev = tuple(unpack_active(dut, active).values())
    for c in range(1, cap_cycles + 1):
        await RisingEdge(dut.out_clk)
        ov = int(dut.out_valid.value)
        cur = tuple(unpack_active(dut, active).values())
        if ov == 1 and None not in cur and cur != prev:
            return True, c
        prev = cur
    return False, cap_cycles


# ===========================================================================
# 1 — masked-subset link-up: only lanes 2,5,6,7 active, masked lanes EMPTY
# ===========================================================================
@cocotb.test()
async def test_masked_subset_link_up(dut):
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    # Masked lanes get NO clock and NO data (dead conductor).
    start_lane_clocks(dut, active_only=ACTIVE_LANES)
    await do_reset(dut, ACTIVE_MASK)

    idx = [0] * LANES
    for gi in ACTIVE_LANES:
        cocotb.start_soon(lane_feeder(dut, gi, idx, base=0x1000))

    cap = 300
    ok, cyc = await wait_out_valid(dut, cap, ACTIVE_LANES)
    if not ok:
        verdict("masked_subset_link_up", False,
                f"out_valid NEVER asserted within {cap} out_clk with masked lanes "
                f"empty (mask=0x{ACTIVE_MASK:02x}) — the &lane_has_data wedge")
        assert False, "masked-subset deskew never produced a valid word (wedge)"

    # Active lanes must carry their driven (equal across active lanes) word; the
    # masked lanes are don't-care (read X, ignored). Confirm the ACTIVE subset is
    # self-coherent.
    coh = 0
    samples = []
    for _ in range(80):
        await RisingEdge(dut.out_clk)
        if int(dut.out_valid.value) != 1:
            continue
        act_vals = unpack_active(dut, ACTIVE_LANES)
        act = set(act_vals.values())
        if None not in act and len(act) == 1:
            coh += 1
            samples.append(next(iter(act)))
    passed = coh >= 20 and len(set(samples)) >= 3
    verdict("masked_subset_link_up", passed,
            f"out_valid asserted @cyc{cyc}; active-lanes coherent beats={coh}; "
            f"distinct words={len(set(samples))}; sample={sorted(set(samples))[:5]}; "
            f"active={ACTIVE_LANES} masked={MASKED_LANES}")
    assert passed, ("masked subset did not deliver a streaming coherent word on "
                    "the active lanes")


# ===========================================================================
# 2 — default 8-lane no-regression (mask=0xFF, all lanes fed)
# ===========================================================================
@cocotb.test()
async def test_default_8lane_noregression(dut):
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut)               # all 8 lanes clocked
    await do_reset(dut, 0xFF)

    idx = [0] * LANES
    for gi in range(LANES):
        cocotb.start_soon(lane_feeder(dut, gi, idx, base=0x2000))

    cap = 300
    ok, cyc = await wait_out_valid(dut, cap, list(range(LANES)))
    assert ok, "default 8-lane (0xFF) deskew never produced a valid word"

    coh = 0
    seen = set()
    for _ in range(80):
        await RisingEdge(dut.out_clk)
        if int(dut.out_valid.value) != 1:
            continue
        vals = unpack_active(dut, list(range(LANES)))
        s = set(vals.values())
        if None not in s and len(s) == 1:
            coh += 1
            seen.add(next(iter(s)))
    passed = coh >= 20 and len(seen) >= 3
    verdict("default_8lane_noregression", passed,
            f"out_valid @cyc{cyc}; all-8-coherent beats={coh}; distinct={len(seen)}")
    assert passed, "default 8-lane path regressed (no coherent stream at 0xFF)"


# ===========================================================================
# 3 — masked lanes CLOCKED + GARBAGE: active path must still flow
# ===========================================================================
@cocotb.test()
async def test_masked_lane_garbage(dut):
    Clock(dut.out_clk, WORD_NS, units="ns").start()
    start_lane_clocks(dut)               # ALL lanes clocked (masked too)
    await do_reset(dut, ACTIVE_MASK)

    idx = [0] * LANES
    for gi in ACTIVE_LANES:
        cocotb.start_soon(lane_feeder(dut, gi, idx, base=0x3000))
    for gi in MASKED_LANES:              # masked lanes pump GARBAGE
        cocotb.start_soon(lane_feeder(dut, gi, idx, garbage=True))

    cap = 300
    ok, cyc = await wait_out_valid(dut, cap, ACTIVE_LANES)
    assert ok, "masked-lane-garbage: deskew never produced a valid word"

    coh = 0
    samples = []
    for _ in range(80):
        await RisingEdge(dut.out_clk)
        if int(dut.out_valid.value) != 1:
            continue
        act_vals = unpack_active(dut, ACTIVE_LANES)
        act = set(act_vals.values())
        if None not in act and len(act) == 1:
            coh += 1
            samples.append(next(iter(act)))
    passed = coh >= 20 and len(set(samples)) >= 3
    verdict("masked_lane_garbage", passed,
            f"out_valid @cyc{cyc}; active coherent beats={coh}; "
            f"distinct={len(set(samples))} (masked lanes fed garbage, ignored)")
    assert passed, ("masked-lane garbage corrupted or stalled the active-lane "
                    "word path")
