# =============================================================================
# Pipelining throughput test for tidelink_fc_adapter.sv (2026-07-31)
#
# HYPOTHESIS UNDER TEST (from a static design review, never previously run):
# the TX-aperture admission logic --
#   skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready                (L553)
#   the sequential FSM's priority order (a new address-phase acceptance
#   checked before the data-phase-clear branch)                     (L316-334)
#   ahb_tx_hreadyout = tx_data_phase_r
#                       ? (skid_can_accept & ~sideband_grant) : 1'b1 (L371-375)
# -- should ALREADY admit a new 32-bit AHB write every single hclk cycle,
# back-to-back, with zero stall, whenever:
#   (a) the AHB master presents genuinely PIPELINED beats (address phase of
#       word N+1 concurrent with data phase of word N, no idle gap),
#   (b) the downstream 16-deep a2l replay FIFO (in the Wlink FC node) has
#       room, and
#   (c) no sideband arbiter grant preempts that cycle.
#
# This file drives GENUINELY pipelined AHB bursts using cocotbext-ahb's
# AHBLiteMaster.write(..., pip=True) (list-form addresses/values), which
# speculatively presents address phase N+1 while data phase N is still
# outstanding -- exactly condition (a). No RTL is touched here; this is
# verification-only. If corruption or a hang shows up, that is reported as
# a finding, not patched.
#
# THREE questions this file answers, with numbers, not impressions:
#   1) pipelined cycles/word for N=8,16,17,32 (tl_fc_a2l_ready tied high,
#      i.e. condition (b) trivially satisfied -- isolates the admission
#      path's own throughput from any downstream capacity limit).
#   2) the SAME N as a non-pipelined baseline (independent single-beat
#      writes, each awaited to completion) for direct comparison.
#   3) N=17 specifically, against a MODELED 16-deep downstream a2l FIFO (no
#      auto-drain -- the worst case where the link is momentarily not
#      consuming at all). EMPIRICAL RESULT (see the crossing tests near the
#      bottom of this file): the fc_adapter's own 1-entry TX skid sits IN
#      FRONT of that FIFO, so total elasticity is skid(1)+FIFO(16)=17 words
#      -- a 17-word burst is absorbed with ZERO AHB stall, not a stall on
#      the 17th word as the naive "16-deep FIFO" framing would suggest. The
#      REAL backpressure boundary is the 18th word, which this file also
#      exercises: it backpressures CLEANLY (plain AHB wait state, no
#      corruption, no drop, no duplicate, byte-exact once drained).
#
# tb_top.sv is the SAME wrapper used by test_tidelink_fc_adapter.py /
# test_buga.py / test_held_nonseq.py. tl_fc_a2l_ready is a raw input on this
# unit-level tb (the real Wlink FC node / 16-deep replay FIFO is not
# instantiated here), so the "downstream FIFO" is modeled in Python for the
# N=17 crossing test (A2LFifoModel below); for the N=8/16/17/32 cycles/word
# measurement it is simply tied high per precondition (b).
# =============================================================================
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles
from cocotb.utils import get_sim_time

from cocotbext.ahb import AHBBus, AHBLiteMaster

CLK_PERIOD_NS = 10
PKT_FIFO_DATA = 0b00

HTRANS_IDLE = 0b00


def fc_word(addr, data):
    """Expected FC word for a TX-aperture FIFO_DATA write (matches test_buga.py)."""
    return ((PKT_FIFO_DATA & 0x3) << 46) | ((addr & 0x3FFF) << 32) | (data & 0xFFFFFFFF)


def make_words(n, addr0, data_tag):
    """N incrementing word-aligned addresses + a distinguishable data pattern,
    matching the address/data convention used by test_buga.py / the other
    fc_adapter tests (sequential packet-style writes)."""
    addrs = [(addr0 + 4 * i) & 0x3FFF for i in range(n)]
    datas = [(data_tag + i) & 0xFFFFFFFF for i in range(n)]
    return addrs, datas


async def reset_dut(dut):
    """Same reset contract as test_buga.py's reset(), minus the ahb_tx_*
    signals (those are owned by the cocotbext AHBLiteMaster once
    constructed)."""
    dut.hresetn.value = 0
    # System HREADY tie-off for the TX aperture (distinct from hreadyout --
    # see make_ahb_tx_master() below). No interconnect contention in this
    # unit tb, so this is always 1, matching every other fc_adapter test.
    dut.ahb_tx_hready.value = 1
    # Returner idle
    dut.rtn_haddr.value = 0
    dut.rtn_hwdata.value = 0
    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hsize.value = 0b010
    dut.rtn_hwrite.value = 0
    # RX path / tie-offs
    dut.fc_rx_fifo_ready.value = 1
    dut.fc_rx_cfg_prdata.value = 0
    dut.fc_rx_cfg_pready.value = 1
    dut.tc_axis_tx_tvalid.value = 0
    dut.tc_axis_tx_tdata.value = 0
    dut.tc_axis_rx_tready.value = 1
    dut.tc_qos_priority.value = 0
    dut.puf_rdata.value = 0
    dut.puf_ack.value = 0
    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value = 0
    dut.tl_fc_a2l_ready.value = 1
    for _ in range(4):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    for _ in range(2):
        await RisingEdge(dut.hclk)


def make_ahb_tx_master(dut, timeout=500):
    """AHBLiteMaster bound to the ahb_tx aperture.

    cocotbext-ahb's AHBBus requires a signal named "hready" to represent the
    slave's back-pressure. This DUT exposes TWO ready-like signals on the TX
    aperture: ahb_tx_hready (an INPUT -- the shared-bus HREADY the slave
    would see behind a real interconnect; tied high in this unit tb, see
    reset_dut()) and ahb_tx_hreadyout (the slave's OWN output -- the actual
    back-pressure this test cares about, per the design-review hypothesis).
    Remap the bus's logical "hready" to the physical "hreadyout" signal so
    AHBLiteMaster reacts to genuine slave back-pressure, not the tied-high
    system signal.
    """
    signals = {
        "haddr": "haddr", "hsize": "hsize", "htrans": "htrans",
        "hwdata": "hwdata", "hrdata": "hrdata", "hwrite": "hwrite",
        "hready": "hreadyout", "hresp": "hresp",
    }
    bus = AHBBus(dut, "ahb_tx", signals=signals)
    return AHBLiteMaster(bus, dut.hclk, dut.hresetn, timeout=timeout)


class FcA2lMonitor:
    """Captures every tl_fc_a2l_valid&ready handshake (one FC word transferred
    out of the skid), in order. Same pattern as test_buga.py's FcMonitor."""

    def __init__(self, dut):
        self.dut = dut
        self.words = []
        self._task = None

    def start(self):
        self._task = cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            await RisingEdge(self.dut.hclk)
            await ReadOnly()
            v = int(self.dut.tl_fc_a2l_valid.value)
            r = int(self.dut.tl_fc_a2l_ready.value)
            if v == 1 and r == 1:
                self.words.append(int(self.dut.tl_fc_a2l_data.value))


class A2LFifoModel:
    """Models the downstream Wlink FC-node replay FIFO (16-deep in HW) that
    sits behind tl_fc_a2l_ready on real silicon -- NOT present in this
    unit-level tb, so it is modeled here in Python for the N=17 crossing
    test. Deliberately has NO auto-drain: it models the worst case where the
    link is momentarily not consuming at all, so a continuous 17-word
    pipelined burst can genuinely fill it. drain() is called explicitly once
    the test has confirmed the stall, to let the burst complete.
    """

    def __init__(self, dut, depth=16):
        self.dut = dut
        self.depth = depth
        self.occupancy = 0
        self.words = []  # words that entered the FIFO, in order (for byte-exact checks)
        self._reader_task = None
        self._writer_task = None

    def start(self):
        self.dut.tl_fc_a2l_ready.value = 1 if self.occupancy < self.depth else 0
        # Split into a read-only sampler and a write-only driver. cocotb 2.x
        # disallows a direct ReadOnly->ReadWrite transition in one task, and
        # writing before the ReadOnly sample (in the same task) would let the
        # write clobber the very value we're about to sample. Two tasks woken
        # by the same RisingEdge naturally get the right relative ordering:
        # the writer (no ReadOnly wait) runs in the Normal phase immediately
        # on the edge -- BEFORE the reader reaches its ReadOnly phase later
        # in that same time step -- so the writer always drives ready from
        # the occupancy as it stood at the END of the previous cycle, and the
        # reader always samples valid/ready as the RTL actually saw them.
        self._reader_task = cocotb.start_soon(self._reader())
        self._writer_task = cocotb.start_soon(self._writer())

    async def _reader(self):
        while True:
            await RisingEdge(self.dut.hclk)
            await ReadOnly()
            v = int(self.dut.tl_fc_a2l_valid.value)
            r = int(self.dut.tl_fc_a2l_ready.value)
            if v == 1 and r == 1:
                self.words.append(int(self.dut.tl_fc_a2l_data.value))
                self.occupancy += 1

    async def _writer(self):
        while True:
            await RisingEdge(self.dut.hclk)
            self.dut.tl_fc_a2l_ready.value = 1 if self.occupancy < self.depth else 0

    def drain(self, n=None):
        """Pop n entries (default: all) -- models the link finally consuming
        (e.g. successful credit-flow drain on the real Wlink FC node)."""
        self.occupancy = 0 if n is None else max(0, self.occupancy - n)


async def run_pipelined(dut, ahb, addrs, datas):
    """Issue a genuinely pipelined AHB write burst (cocotbext-ahb pip=True):
    address phase of word K+1 concurrent with data phase of word K, no idle
    gap. Returns cycle count from the first address-phase beat to the last
    word's completion."""
    await RisingEdge(dut.hclk)
    t0 = get_sim_time(unit="ns")
    await ahb.write(list(addrs), list(datas), pip=True)
    t1 = get_sim_time(unit="ns")
    return round((t1 - t0) / CLK_PERIOD_NS)


async def run_baseline(dut, ahb, addrs, datas):
    """Non-pipelined baseline: N independent single-beat AHB writes, each
    awaited to completion before the next one's address phase begins
    (cocotbext-ahb default pip=False -- what test_buga.py's burst() helper
    also does, one full transaction at a time)."""
    await RisingEdge(dut.hclk)
    t0 = get_sim_time(unit="ns")
    for a, d in zip(addrs, datas):
        await ahb.write(a, d)
    t1 = get_sim_time(unit="ns")
    return round((t1 - t0) / CLK_PERIOD_NS)


async def pipelined_vs_baseline(dut, n):
    """Core measurement, shared by the N=8/16/17/32 tests below.
    tl_fc_a2l_ready tied high throughout -- downstream FIFO assumed to have
    room (precondition (b)), isolating the ADMISSION PATH's own throughput.
    The FIFO-depth-crossing scenario is covered separately by
    test_pipelined_n17_fills_skid_plus_fifo_no_stall and
    test_pipelined_n18_crosses_admission_elasticity below."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    ahb = make_ahb_tx_master(dut, timeout=max(300, 6 * n))
    mon = FcA2lMonitor(dut)
    mon.start()
    dut.tl_fc_a2l_ready.value = 1

    # --- Pipelined burst ---
    p_addrs, p_datas = make_words(n, addr0=0x0000, data_tag=0xA0000000)
    pipe_cycles = await run_pipelined(dut, ahb, p_addrs, p_datas)
    await ClockCycles(dut.hclk, 10)

    exp_pipe = [fc_word(a, d) for a, d in zip(p_addrs, p_datas)]
    got_pipe = mon.words[:n]
    assert got_pipe == exp_pipe, (
        f"N={n} PIPELINED: word mismatch/drop/dup -- got {len(got_pipe)} words "
        f"{[hex(w) for w in got_pipe]}, expected {len(exp_pipe)} "
        f"{[hex(w) for w in exp_pipe]}"
    )
    mon.words.clear()

    # --- Non-pipelined baseline (different address range, same tb instance) ---
    b_addrs, b_datas = make_words(n, addr0=0x1000, data_tag=0xB0000000)
    base_cycles = await run_baseline(dut, ahb, b_addrs, b_datas)
    await ClockCycles(dut.hclk, 10)

    exp_base = [fc_word(a, d) for a, d in zip(b_addrs, b_datas)]
    got_base = mon.words[:n]
    assert got_base == exp_base, (
        f"N={n} BASELINE: word mismatch/drop/dup -- got {len(got_base)} words "
        f"{[hex(w) for w in got_base]}, expected {len(exp_base)} "
        f"{[hex(w) for w in exp_base]}"
    )

    pipe_cpw = pipe_cycles / n
    base_cpw = base_cycles / n
    dut._log.info(
        f"[VERDICT pipelining N={n}] pipelined={pipe_cycles}cy ({pipe_cpw:.3f} cy/word)  "
        f"baseline={base_cycles}cy ({base_cpw:.3f} cy/word)  "
        f"speedup={base_cpw / pipe_cpw:.2f}x"
    )
    print(
        f"[VERDICT pipelining N={n}] pipelined={pipe_cycles}cy ({pipe_cpw:.3f} cy/word)  "
        f"baseline={base_cycles}cy ({base_cpw:.3f} cy/word)  "
        f"speedup={base_cpw / pipe_cpw:.2f}x"
    )
    return pipe_cpw, base_cpw


# ---------------------------------------------------------------------------
@cocotb.test()
async def test_pipelining_n8(dut):
    """N=8: pipelined vs non-pipelined cycles/word, FC-ready held high."""
    await pipelined_vs_baseline(dut, 8)


@cocotb.test()
async def test_pipelining_n16(dut):
    """N=16: pipelined vs non-pipelined cycles/word, FC-ready held high."""
    await pipelined_vs_baseline(dut, 16)


@cocotb.test()
async def test_pipelining_n17(dut):
    """N=17: pipelined vs non-pipelined cycles/word, FC-ready held high
    (i.e. the admission path in isolation -- see
    test_pipelined_n17_fills_skid_plus_fifo_no_stall and
    test_pipelined_n18_crosses_admission_elasticity for the FIFO-full
    crossing case)."""
    await pipelined_vs_baseline(dut, 17)


@cocotb.test()
async def test_pipelining_n32(dut):
    """N=32: pipelined vs non-pipelined cycles/word, FC-ready held high."""
    await pipelined_vs_baseline(dut, 32)


# ---------------------------------------------------------------------------
# FIFO-depth-crossing tests, N=17 and N=18.
#
# EMPIRICAL CORRECTION (found by running this test, not assumed up front):
# the naive picture ("16-deep FIFO -> the 17th word must stall") misses that
# the fc_adapter's OWN 1-entry TX skid sits IN FRONT of the modeled 16-deep
# downstream FIFO. Total continuous-burst elasticity as seen by the AHB
# master is therefore skid(1) + FIFO(16) = 17 words, not 16. A 17-word
# burst is exactly absorbed with ZERO AHB stall (test_pipelined_n17_*
# below) -- the 17th word lands in the skid and sits there, valid but not
# yet handed to the (full) downstream FIFO; the AHB write already completed
# from the CPU's point of view (correct skid decoupling, not a bug). The
# REAL admission-side backpressure boundary is the 18th word
# (test_pipelined_n18_* below), where skid+FIFO are both genuinely full.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_pipelined_n17_fills_skid_plus_fifo_no_stall(dut):
    """N=17 against a modeled 16-deep downstream a2l FIFO that never
    auto-drains. Demonstrates the skid's extra word of elasticity: all 17
    words are admitted back-to-back with HREADYOUT NEVER deasserting (the
    AHB write completes with zero stall) -- 16 words land in the modeled
    FIFO, the 17th is parked (valid, unconsumed) in the adapter's own skid
    buffer. Once the modeled FIFO drains, that 17th word must still drain
    out byte-exact, in order, with no drop/duplicate.
    """
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    ahb = make_ahb_tx_master(dut, timeout=2000)

    fifo = A2LFifoModel(dut, depth=16)
    fifo.start()

    n = 17
    addrs, datas = make_words(n, addr0=0x2000, data_tag=0xC0DE0000)

    wr_task = cocotb.start_soon(ahb.write(list(addrs), list(datas), pip=True))

    stalled_seen = False
    for _ in range(60):
        await RisingEdge(dut.hclk)
        await ReadOnly()
        if int(dut.ahb_tx_hreadyout.value) == 0:
            stalled_seen = True
        if wr_task.done():
            break
    else:
        assert False, "N=17 AHB write never completed -- unexpected hang"

    words_at_ahb_complete = len(fifo.words)
    skid_pending = int(dut.tl_fc_a2l_valid.value) == 1

    assert not stalled_seen, (
        "HREADYOUT deasserted during the N=17 burst -- expected ZERO AHB "
        "stall, since skid(1)+FIFO(16)=17 total elasticity exactly covers "
        "17 words. A stall here means the skid is NOT providing its extra "
        "word of headroom (contradicts the static RTL read of skid_can_accept)"
    )
    assert wr_task.done(), "N=17 AHB write should complete with zero back-pressure"
    assert words_at_ahb_complete == fifo.depth, (
        f"expected exactly {fifo.depth} words to have reached the modeled FIFO "
        f"by AHB-write completion (the 17th parked in the skid), got "
        f"{words_at_ahb_complete}"
    )
    assert skid_pending, (
        "expected the 17th word to be sitting valid-but-unconsumed in the "
        "adapter's skid (tl_fc_a2l_valid=1, ready=0) after AHB completion"
    )

    # The link finally drains -- release backpressure and let word 17 flow out.
    fifo.drain()
    await ClockCycles(dut.hclk, 5)

    exp = [fc_word(a, d) for a, d in zip(addrs, datas)]
    got = fifo.words
    msg = (f"[VERDICT n17-fifo-cross] AHB write completed with stalled="
           f"{stalled_seen} after admitting {words_at_ahb_complete}/{fifo.depth} "
           f"words to the modeled FIFO (17th parked in skid); "
           f"{len(got)}/{n} total after drain")
    dut._log.info(msg)
    print(msg)
    assert len(got) == n, (
        f"expected exactly {n} words to eventually reach the FIFO, got {len(got)} "
        f"(dropped or duplicated word around the skid+FIFO boundary)"
    )
    assert got == exp, (
        "byte-exact mismatch: word content or ORDER corrupted at the skid+FIFO "
        f"boundary -- got {[hex(w) for w in got]} expected {[hex(w) for w in exp]}"
    )


@cocotb.test()
async def test_pipelined_n18_crosses_admission_elasticity(dut):
    """N=18 against the same modeled 16-deep downstream a2l FIFO: this is
    the ACTUAL admission-side crossing point (skid(1)+FIFO(16)=17 slots all
    full), not N=17 (see test_pipelined_n17_fills_skid_plus_fifo_no_stall).
    The 18th word must backpressure the AHB write CLEANLY -- HREADYOUT
    deasserts (a plain AHB wait state), no corruption, no dropped or
    duplicated word -- and complete byte-exact, in order, once the modeled
    FIFO finally drains.
    """
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    ahb = make_ahb_tx_master(dut, timeout=2000)

    fifo = A2LFifoModel(dut, depth=16)
    fifo.start()

    n = 18
    addrs, datas = make_words(n, addr0=0x2400, data_tag=0xD00D0000)

    wr_task = cocotb.start_soon(ahb.write(list(addrs), list(datas), pip=True))

    stalled_seen = False
    for _ in range(60):
        await RisingEdge(dut.hclk)
        await ReadOnly()
        if int(dut.ahb_tx_hreadyout.value) == 0:
            stalled_seen = True

    words_before_drain = len(fifo.words)
    assert stalled_seen, (
        "AHB write should have shown HREADYOUT=0 (clean back-pressure) once "
        "the 18th word tried to enter an already-full skid+FIFO (17/17 slots)"
    )
    assert not wr_task.done(), (
        "the N=18 burst completed BEFORE the modeled FIFO was drained -- the "
        "18th word slipped through instead of backpressuring (the skid is "
        "over-admitting beyond its 1-entry + FIFO's 16-entry elasticity: "
        "possible RTL bug)"
    )
    assert words_before_drain == fifo.depth, (
        f"expected exactly {fifo.depth} words in the modeled FIFO at the stall "
        f"point (1 more parked in the skid), got {words_before_drain}"
    )

    # The link finally drains -- release backpressure and let the burst finish.
    fifo.drain()
    await wr_task
    await ClockCycles(dut.hclk, 5)

    exp = [fc_word(a, d) for a, d in zip(addrs, datas)]
    got = fifo.words
    msg = (f"[VERDICT n18-fifo-cross] {words_before_drain} words admitted "
           f"before the 18th word's stall was observed, {len(got)}/{n} total "
           f"after drain, stalled={stalled_seen}")
    dut._log.info(msg)
    print(msg)
    assert len(got) == n, (
        f"expected exactly {n} words to eventually reach the FIFO, got {len(got)} "
        f"(dropped or duplicated word at the admission-elasticity boundary)"
    )
    assert got == exp, (
        "byte-exact mismatch: word content or ORDER corrupted at the "
        f"admission-elasticity boundary -- got {[hex(w) for w in got]} "
        f"expected {[hex(w) for w in exp]}"
    )
