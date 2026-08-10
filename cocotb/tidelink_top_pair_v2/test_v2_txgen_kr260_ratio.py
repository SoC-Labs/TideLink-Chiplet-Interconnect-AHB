"""TXGEN throughput at the KR260's REAL clock ratio, plus an a2l-window-depth
probe -- the two follow-up experiments (informally "C7"/"C9") flagged after
the 2026-07-31 overnight throughput campaign
(project_txgen_sim_throughput_measured_2026_07_31 memory) found real KR260
hardware sustaining only ~487.9 hclk-cycles/word against a sim prediction of
~95.8 (ample credit) / ~152 (live credit) -- a ~3.2x-5x gap.

BACKGROUND -- why the campaign's "realistic silicon ratio" was wrong for KR260
The campaign used TIDELINK_SIM_REF_PERIOD_NS=40.0 (link:hclk = 2:1) as its
"realistic silicon ratio" for the ACK/credit FSM, which runs in the LINK
clock domain (FC.scala:143, `withClockAndReset(io.tx.clk.asClock, ...)`).
That 2:1 ratio is the PYNQ-Z2 target's ratio
(fpga/targets/pynq-z2-pair-all/tidelink_design.tcl:236-266, 4.687/2.343 MHz)
-- but the real hardware measurement was taken on KR260
(fpga/targets/kr260-pair-onchip/tidelink_phy_clk_div2.v:12-19, "PHY rate =
clk_out1/8"), whose link:hclk ratio is 8:1, i.e. REF_CLK_PERIOD_NS=160.0 (4x
`hclk`'s CLK_PERIOD_NS=20.0 x2 -- see pair_v2_common.py's REF_CLK_PERIOD_NS
derivation). A back-of-envelope rescale of the campaign's own bandwidth-delay
model at the correct 8:1 ratio predicted ~335 cy/word, closing ~77% of the
log-scale gap from the clock-ratio correction alone, with the remaining gap
attributed to the ample-vs-live credit baseline difference (~1.59x, sim's own
already-measured live-credit number at 2:1 was ~152 vs 95.8 for ample). This
file actually RUNS that predicted experiment instead of leaving it as an
estimate.

Technique/harness reused from (not imported -- this cocotb dir's convention
is one PYTHONPATH root per test file, constants/helpers are deliberately
re-declared rather than cross-imported, see e.g. test_v2_txgen_throughput.py
and test_v2_txgen.py in this same directory): PairV2TB / run_bringup_full /
read_packet_drain / the TXGEN Region-E register map / the PERF_CTRL
SAMPLE_COUNT bracketing technique already used by test_v2_perf_ctrl.py.

WHAT THIS FILE ADDS THAT DIDN'T EXIST BEFORE
  test_txgen_kr260_ratio_ceiling        -- ample-credit baseline @ REF=160,
                                            direct triangulation point.
  test_txgen_kr260_ratio_live_credit    -- "C7": the actual corrected-ratio,
                                            LIVE-credit number to compare
                                            against real hardware's 487.9.
  test_txgen_a2l_full_interval_vs_backlog -- "C9": instruments the a2l_full
                                            (window-full stall) signal
                                            directly and measures whether the
                                            duration of each asserted
                                            interval is constant regardless
                                            of backlog (would justify
                                            deepening the 16-word `fifoSize`,
                                            TideLink.scala:165,169,180,182)
                                            or scales with it (would falsify
                                            that lever).

KNOWN, OUT-OF-SCOPE CONFOUND (do not re-chase here): a genuine, previously
found, NOT-root-caused defect where the LAST packet of a tight-live-credit
finite-budget run is never marked committed on the peer, even though TXGEN's
own DONE/WORDS report clean completion (see the overnight-campcampaign memory
and test_txgen_live_credit_loop_sustained in the sibling
test_v2_txgen_throughput.py file for the original repro). It is orthogonal to
both C7 (a timing measurement, unaffected -- TXGEN's own done_r fires on
admission, not on the peer's commit flag) and C9 (ample credit, no live drain
loop at all). test_txgen_kr260_ratio_live_credit therefore treats the peer
drain/commit step as best-effort/informational, not a hard pass/fail gate.

NEW, SEPARATE, NOT-ROOT-CAUSED FINDING (2026-08-01, first run of this file at
REF=160.0): the same run ALSO produced genuine BYTE mismatches under the live
concurrent drain, starting much earlier than the run-end tail above --
packet index 1 (of 20) had one corrupted payload word (a value that does not
decode as any valid {seq,beat} pair, i.e. looks like a transient/unsettled
sample, not RTL-generated data), and packet index 2's read then returned
packet index 3's true payload (a well-formed {seq=3,...} value where
{seq=2,...} was expected) -- i.e. packet 2 appears to have been skipped in
the FIFO stream entirely, not merely corrupted. This is DISTINCT from the
known last-packet defect above (different packets, different signature: real
data appearing at the wrong sequence position vs. a packet never committing
at all) and was NOT seen in this file's ample-credit tests (ceiling, a2l
probe) at the same REF=160 ratio using the same AHB read primitives
(ahb_fifo_read_word/read_packet_drain, pair_v2_common.py, unmodified) --
which rules out a blanket "AHB read helper broken at this ratio" explanation
and points at something specific to CONCURRENT drain-while-TX-still-running
at this (never-before-exercised) ratio. NOT investigated further here (out
of this task's scope, matches this project's established practice: flag a
newly found defect class rather than chase it inside an unrelated
task) -- left as a genuinely FAILING assertion (drain_mismatches) so the
signal stays visible rather than being silently softened. Does NOT affect
the C7 cycles/word number (measured from TXGEN's own admission-side done_r/
elapsed bracket, captured before this drain loop even starts checking
words).

Run:
  source ./set_env.sh
  TIDELINK_SIM_REF_PERIOD_NS=160.0 make -C cocotb/tidelink_top_pair_v2 \\
      EPOCH_PROFILE=zero MODULE=test_v2_txgen_kr260_ratio
"""
import statistics

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_TIDELINK_BASE, read_packet_drain,
    APB_RELEASE_THRESHOLD, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
)

# ---------------------------------------------------------------------------
# Register map (mirrors test_v2_txgen.py / test_v2_txgen_throughput.py).
# ---------------------------------------------------------------------------
TXGEN_CTRL   = 0x21C0
TXGEN_PKT    = 0x21C4
TXGEN_GAP    = 0x21C8
TXGEN_BUDGET = 0x21CC
TXGEN_STATUS = 0x21D0
TXGEN_WORDS  = 0x21D4
TXGEN_STALL  = 0x21D8
TXGEN_ID     = 0x21DC

CTRL_EN      = 1 << 0
CTRL_START   = 1 << 1
CTRL_CLR     = 1 << 4     # self-clearing; must NOT disturb EN (wdata[0] must stay 1)

ST_STALL_CREDIT = 1 << 2
ST_ERR_AHB      = 1 << 4
ST_EXT_ABORT    = 1 << 5
ST_GATE_ACTIVE  = 1 << 6

APB_RELEASED_ACC = APB_TIDELINK_BASE + 0x020
APB_STATUS       = APB_TIDELINK_BASE + 0x010
ST_OVERRUN         = 1 << 1
ST_PKT_COMMITTED   = 1 << 4

PERF_CTRL     = 0x20A0   # region 5 word 0
PERF_TX_WORDS = 0x20D0   # region 6 word 4
PERF_SAMPLES  = 0x20E8   # region 7 word 2
PERF_EN       = 0x1

# Peer RX SRAM real capacity (tidelink_fifo_ctrl.sv MAX_CREDITS) -- every run
# below must stay under this without an intervening drain.
PEER_RX_CAPACITY_WORDS = 4096

# Settle window between TXGEN's done_r (admission complete) and reading the
# peer's RX FIFO -- the a2l replay FIFO (16 entries) can still have a
# propagation tail in flight the instant done_r fires (same rationale as
# pair_v2_common's other send helpers and test_v2_txgen_throughput.py).
DRAIN_SETTLE_CYCLES = 5000

# KR260's real link:hclk ratio (fpga/targets/kr260-pair-onchip/
# tidelink_phy_clk_div2.v: "PHY rate = clk_out1/8").
KR260_REF_CLK_PERIOD_NS = 160.0
CEILING_HCLK_PER_WORD = 8.0 * (REF_CLK_PERIOD_NS / CLK_PERIOD_NS)


def expected_payload(seq, beat):
    return ((seq & 0xFFFF) << 16) | (beat & 0xFFFF)


def expected_header(pkt_len):
    return (pkt_len << 20) | (0x1 << 18)   # WR_REQ, length pkt_len


def _require_kr260_ratio(tb):
    tb.log.info(f"[kr260-ratio] REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} "
                f"CLK_PERIOD_NS={CLK_PERIOD_NS} -> link ceiling="
                f"{CEILING_HCLK_PER_WORD:.3f} hclk/word")
    assert abs(REF_CLK_PERIOD_NS - KR260_REF_CLK_PERIOD_NS) < 1e-3, (
        f"This suite specifically targets the KR260 8:1 link:hclk ratio -- "
        f"invoke with TIDELINK_SIM_REF_PERIOD_NS={KR260_REF_CLK_PERIOD_NS} "
        f"(got REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS}). For other ratios use "
        f"test_v2_txgen_throughput.py directly.")


async def arm_and_run_txgen_probe(tb, src, pkt_len, npkt, initial_credit_words=None,
                                   max_cycles=6_000_000, sample_a2l=False):
    """Same technique as test_v2_txgen_throughput.py's arm_and_run_txgen, plus
    an optional per-cycle a2l_full sampler that records the hclk-cycle
    duration of every contiguous a2l_full=1 interval (the window-full stall
    condition, tb.a2l_full()/io_obs_a2l_full on tl2wl -- see
    pair_v2_common.py's "a2l replay / credit observability" section)."""
    per_packet = pkt_len + 2
    total_words = per_packet * npkt
    seed = total_words if initial_credit_words is None else initial_credit_words

    m = tb.apb(src)
    gen = tb.top(src)["g_txgen.u_tx_gen"]

    if seed:
        await m.write(APB_RELEASED_ACC, seed)

    await m.write(TXGEN_PKT, pkt_len)
    await m.write(TXGEN_GAP, 0)
    await m.write(TXGEN_BUDGET, total_words)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_CLR)
    samp_before = await m.read(PERF_SAMPLES)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_START)

    credit_stall_cycles = 0
    a2l_intervals = []
    in_full = False
    full_start = 0
    cyc = 0
    for i in range(max_cycles):
        await RisingEdge(tb.dut.hclk)
        cyc += 1
        try:
            state = int(gen.state_r.value)
            if state == 1 and int(gen.running_r.value) and not int(gen.credit_ok.value):
                credit_stall_cycles += 1
        except ValueError:
            pass
        if sample_a2l:
            full = tb.a2l_full(src) == 1
            if full and not in_full:
                in_full = True
                full_start = cyc
            elif not full and in_full:
                in_full = False
                a2l_intervals.append(cyc - full_start)
        if int(gen.done_r.value):
            break
    else:
        raise TimeoutError(
            f"TXGEN on {src} did not complete a {npkt}x{pkt_len}-word "
            f"(total {total_words}) run within {max_cycles} hclk")

    trailing_open = in_full  # a2l_full still asserted the instant done_r fired
    if trailing_open:
        a2l_intervals_closed = list(a2l_intervals)  # exclude the truncated tail
    else:
        a2l_intervals_closed = a2l_intervals

    samp_after = await m.read(PERF_SAMPLES)
    words   = await m.read(TXGEN_WORDS)
    stall   = await m.read(TXGEN_STALL)
    status  = await m.read(TXGEN_STATUS)
    txw     = await m.read(PERF_TX_WORDS)

    return {
        "pkt_len": pkt_len, "npkt": npkt, "per_packet": per_packet,
        "total_words": total_words,
        "elapsed": samp_after - samp_before,
        "words": words, "stall": stall, "status": status,
        "perf_tx_words": txw,
        "credit_stall_cycles": credit_stall_cycles,
        "a2l_intervals": a2l_intervals_closed,
        "a2l_trailing_open": trailing_open,
    }


async def verify_drain(tb, dst, npkt, per_packet, pkt_len, pkt_index_start):
    exp_hdr = expected_header(pkt_len)
    mismatches = []
    for p in range(npkt):
        got = await read_packet_drain(tb, dst, per_packet)
        seq = pkt_index_start + p
        if got[0] != exp_hdr:
            mismatches.append((seq, 0, exp_hdr, got[0]))
        if got[1] != 0:
            mismatches.append((seq, 1, 0, got[1]))
        for b in range(2, per_packet):
            want = expected_payload(seq, b)
            if got[b] != want:
                mismatches.append((seq, b, want, got[b]))
    return mismatches


def _log_result(tb, tag, r):
    cpw = r["elapsed"] / r["words"] if r["words"] else float("inf")
    tb.log.info(
        f"  [{tag}] N={r['pkt_len']:4d} per_pkt={r['per_packet']:4d} "
        f"npkt={r['npkt']:4d} total_words={r['total_words']:5d} "
        f"elapsed={r['elapsed']:7d} hclk  words={r['words']:5d}  "
        f"cycles/word={cpw:8.3f}  ceiling={CEILING_HCLK_PER_WORD:6.3f}  "
        f"ratio={cpw / CEILING_HCLK_PER_WORD if CEILING_HCLK_PER_WORD else float('inf'):5.2f}x  "
        f"TXGEN_STALL={r['stall']:6d}  credit_stall={r['credit_stall_cycles']:6d}  "
        f"STATUS=0x{r['status']:02x}  PERF_TX_WORDS+={r['perf_tx_words']}")
    return cpw


# ---------------------------------------------------------------------------
# C7a: ample-credit baseline @ KR260 ratio -- direct triangulation point
# against the campaign's REF=40 ample-credit number (~95.8 cy/word) and this
# file's own live-credit number below.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_txgen_kr260_ratio_ceiling(dut):
    """Ample (whole-run pre-seeded) credit @ the KR260's real 8:1 ratio."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    _require_kr260_ratio(tb)

    m = tb.apb("m")
    await m.write(PERF_CTRL, PERF_EN)

    PKT_LEN = 124
    NPKT    = 20                        # 2520 words, < 4096 peer capacity
    assert (PKT_LEN + 2) * NPKT < PEER_RX_CAPACITY_WORDS

    r = await arm_and_run_txgen_probe(tb, "m", PKT_LEN, NPKT)
    cpw = _log_result(tb, "kr260-ceiling", r)

    assert r["words"] == r["total_words"], (
        f"TXGEN_WORDS={r['words']} != requested total {r['total_words']}")
    assert (r["status"] & ST_GATE_ACTIVE), "credit gate not compiled in"
    assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
        f"TXGEN raised a sticky fault mid-run: STATUS=0x{r['status']:02x}")

    await ClockCycles(dut.hclk, DRAIN_SETTLE_CYCLES)
    mism = await verify_drain(tb, "s", NPKT, r["per_packet"], PKT_LEN, pkt_index_start=0)
    assert not mism, (
        f"{len(mism)} word mismatches (first: {mism[0]}) -- NOT byte-exact "
        f"at the KR260-ratio ample-credit rate")

    tb.log.info(f"[kr260-ceiling] RESULT: {cpw:.3f} hclk/word (ample credit, "
                f"REF={REF_CLK_PERIOD_NS}ns, 8:1 KR260 ratio), byte-exact.")


# ---------------------------------------------------------------------------
# C7: THE deliverable. Live (non-preseeded) credit @ the KR260's real 8:1
# ratio -- the number to compare directly against real hardware's 487.9.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_txgen_kr260_ratio_live_credit(dut):
    """C7. Seeds only a couple of packets' worth of credit up front and runs
    a background drainer that pops+releases the peer's RX FIFO as packets
    land (REL_THRESHOLD=0, immediate release), so TXGEN depends on the REAL
    hardware credit-return loop for the bulk of the run, at the KR260's
    actual 8:1 link:hclk ratio. Directly comparable to the campaign's own
    REF=40 live-credit number (~152 cy/word) and to real hardware's 487.9.

    See the module docstring for why the peer-side drain/commit completion is
    treated as best-effort here, not a hard gate: it is a channel for a
    separate, already-flagged, NOT-root-caused defect (last packet of a
    tight-live-credit finite-budget run not marked committed on the peer)
    that is orthogonal to the timing number this test exists to produce
    (TXGEN's own done_r/TXGEN_WORDS -- and therefore the elapsed-cycle
    bracket used for cycles/word -- fire on ADMISSION, not on the peer's
    commit flag, so that defect cannot skew the measurement itself)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    _require_kr260_ratio(tb)

    m = tb.apb("m")
    s = tb.apb("s")
    await m.write(PERF_CTRL, PERF_EN)
    await s.write(APB_RELEASE_THRESHOLD, 0)   # immediate release per pop
    await ClockCycles(dut.hclk, 20)

    PKT_LEN = 14                        # 16 words/packet, matches the
    NPKT    = 20                        # campaign's own live-credit repro
    per_packet = PKT_LEN + 2            # sizing (methodology parity)
    SEED_PACKETS = 2                    # deliberately tight

    tb.log.info(f"[kr260-live-credit] seeding only {SEED_PACKETS}/{NPKT} "
                f"packets' worth of credit up front, live hardware "
                f"credit-return loop for the rest")

    drain_mismatches = []
    drain_count = [0]
    DRAIN_MAX_IDLE_POLLS = 30000        # 30000*100 = 3,000,000 hclk soft bound

    async def credit_drain_loop():
        exp_hdr = expected_header(PKT_LEN)
        idle_polls = 0
        while drain_count[0] < NPKT:
            st = await s.read(APB_STATUS)
            if st & ST_PKT_COMMITTED:
                idle_polls = 0
                got = await read_packet_drain(tb, "s", per_packet)
                seq = drain_count[0]
                if got[0] != exp_hdr:
                    drain_mismatches.append((seq, 0, exp_hdr, got[0]))
                if got[1] != 0:
                    drain_mismatches.append((seq, 1, 0, got[1]))
                for b in range(2, per_packet):
                    want = expected_payload(seq, b)
                    if got[b] != want:
                        drain_mismatches.append((seq, b, want, got[b]))
                drain_count[0] += 1
            else:
                idle_polls += 1
                if idle_polls % 3000 == 0:
                    cc = await s.read(APB_TIDELINK_BASE + 0x00C)
                    pcc = await m.read(APB_TIDELINK_BASE + 0x028)
                    tb.log.info(
                        f"  [kr260-live-credit drain] idle_polls={idle_polls} "
                        f"drained={drain_count[0]}/{NPKT} dst_credit_count="
                        f"{cc} src_pair_credit_counter={pcc}")
                if idle_polls > DRAIN_MAX_IDLE_POLLS:
                    # KNOWN, out-of-scope defect (see module docstring): the
                    # very last packet can land without ever setting
                    # PKT_COMMITTED under tight live credit. Do not fail this
                    # timing experiment on that -- log and stop draining.
                    tb.log.warning(
                        f"  [kr260-live-credit drain] gave up after "
                        f"{idle_polls} idle polls with {drain_count[0]}/{NPKT} "
                        f"packets committed -- matches the known, separately "
                        f"tracked last-packet-under-tight-live-credit defect, "
                        f"not re-chased here (see module docstring). "
                        f"Timing measurement above is unaffected.")
                    return
                await ClockCycles(tb.dut.hclk, 100)

    drain_task = cocotb.start_soon(credit_drain_loop())

    r = await arm_and_run_txgen_probe(
        tb, "m", PKT_LEN, NPKT, initial_credit_words=SEED_PACKETS * per_packet,
        max_cycles=6_000_000)
    cpw = _log_result(tb, "kr260-live-credit", r)

    await drain_task

    assert r["words"] == r["total_words"], (
        f"TXGEN_WORDS={r['words']} != requested {r['total_words']}")
    assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
        f"sticky fault STATUS=0x{r['status']:02x}")
    if drain_count[0] != NPKT:
        tb.log.warning(
            f"[kr260-live-credit] only {drain_count[0]}/{NPKT} packets "
            f"confirmed committed on the peer (see known-defect note above); "
            f"cycles/word figure below is still valid (measured from TXGEN's "
            f"own admission completion, not the peer drain).")
    assert not drain_mismatches, (
        f"{len(drain_mismatches)} BYTE mismatches under the live credit loop "
        f"(first: {drain_mismatches[0]}) -- this WOULD be a real corruption "
        f"finding, distinct from the known missing-last-packet defect")

    credit_stall_frac = r["credit_stall_cycles"] / r["elapsed"] if r["elapsed"] else 0.0
    tb.log.info(
        f"[kr260-live-credit] C7 RESULT: {cpw:.3f} hclk/word @ "
        f"REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} (KR260 8:1 ratio), "
        f"credit_stall_cycles={r['credit_stall_cycles']}/elapsed="
        f"{r['elapsed']} ({credit_stall_frac * 100:.2f}%), "
        f"{drain_count[0]}/{NPKT} packets confirmed committed via the LIVE "
        f"hardware credit-return loop. Compare to real KR260 hardware: "
        f"487.9 cy/word (ack_dly_count=7 default).")


# ---------------------------------------------------------------------------
# C9: a2l_full assert-interval duration vs backlog size (ample credit, so the
# ONLY stall mechanism in play is the link's own window-full backpressure,
# not a confounded live-credit-loop stall).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_txgen_a2l_full_interval_vs_backlog(dut):
    """C9. For each of a few backlog sizes (NPKT), run TXGEN to completion
    with ample pre-seeded credit at the KR260 ratio while sampling
    tb.a2l_full("m") (io_obs_a2l_full on tl2wl -- the ARQ replay window's
    "full, cannot admit another word" condition) every hclk cycle, and record
    the duration (in hclk cycles) of every contiguous asserted interval.

    THE QUESTION: is the typical (mean/median) interval duration roughly
    CONSTANT across backlog sizes (-> a fixed per-occurrence ACK-round-trip
    cost that a deeper `fifoSize` -- TideLink.scala:165,169,180,182 -- would
    amortize over more words per occurrence, i.e. a real lever) or does it
    SCALE with backlog (-> the cost is not a fixed per-occurrence RTT and
    widening the window would not obviously help; falsifies the depth-lever
    hypothesis without needing to touch Chisel at all)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    _require_kr260_ratio(tb)

    m = tb.apb("m")
    await m.write(PERF_CTRL, PERF_EN)

    PKT_LEN = 124                        # 126 words/packet
    # Three backlog sizes, each well under the peer's 4096-word capacity.
    # Each config gets its OWN fresh bring-up (see reset() below) so a2l
    # window state never carries over between configs.
    NPKT_VALUES = [4, 10, 20]

    rows = []
    for idx, npkt in enumerate(NPKT_VALUES):
        if idx > 0:
            # Fresh bring-up per config (matches this dir's established
            # multi-@cocotb.test()-per-file pattern of a full reset+bring-up
            # per measurement -- here done manually inside a loop instead of
            # as separate test functions, so the cross-backlog comparison and
            # verdict can be logged as one coherent block).
            await tb.reset()
            tb.force_calibrator_sim_bypass()
            await tb.do_role_lock()
            assert await tb.wait_role_locked(), "role_locked did not re-assert"
            await tb.wait_cal_done()
            await tb.do_to_data_mode()
            await ClockCycles(dut.hclk, 5000)   # parity with run_bringup_full's settle
            assert await tb.wait_cr_crack(), "link did not re-reach CR/CRACK"
            await ClockCycles(dut.hclk, 500)
            await m.write(PERF_CTRL, PERF_EN)

        assert (PKT_LEN + 2) * npkt < PEER_RX_CAPACITY_WORDS
        r = await arm_and_run_txgen_probe(tb, "m", PKT_LEN, npkt, sample_a2l=True)
        cpw = _log_result(tb, f"a2l-probe[npkt={npkt}]", r)

        assert r["words"] == r["total_words"], (
            f"npkt={npkt}: TXGEN_WORDS={r['words']} != {r['total_words']}")
        assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
            f"npkt={npkt}: sticky fault STATUS=0x{r['status']:02x}")

        ivals = r["a2l_intervals"]
        if ivals:
            mean_i   = statistics.mean(ivals)
            median_i = statistics.median(ivals)
            min_i, max_i = min(ivals), max(ivals)
        else:
            mean_i = median_i = min_i = max_i = 0
        tb.log.info(
            f"  [a2l-probe] npkt={npkt:4d} total_words={r['total_words']:5d} "
            f"n_intervals={len(ivals):4d} mean={mean_i:8.1f} "
            f"median={median_i:8.1f} min={min_i:6d} max={max_i:6d} hclk "
            f"trailing_open={r['a2l_trailing_open']}")
        rows.append({
            "npkt": npkt, "total_words": r["total_words"], "cpw": cpw,
            "n_intervals": len(ivals), "mean": mean_i, "median": median_i,
            "min": min_i, "max": max_i,
        })

        # Settle + byte-exact check (informational -- not the point of this
        # test, but cheap insurance that the a2l probe isn't itself perturbing
        # correctness).
        await ClockCycles(dut.hclk, DRAIN_SETTLE_CYCLES)
        mism = await verify_drain(tb, "s", npkt, r["per_packet"], PKT_LEN, 0)
        assert not mism, (
            f"npkt={npkt}: {len(mism)} mismatches (first {mism[0]}) under "
            f"the a2l_full probe -- probe or link corrupted data")

    tb.log.info("  ===== C9 VERDICT: a2l_full assert-interval duration vs backlog =====")
    for row in rows:
        tb.log.info(
            f"    npkt={row['npkt']:4d} total_words={row['total_words']:5d} "
            f"cycles/word={row['cpw']:8.3f} n_intervals={row['n_intervals']:4d} "
            f"mean_interval={row['mean']:8.1f} hclk median={row['median']:8.1f} hclk")

    means = [row["mean"] for row in rows if row["n_intervals"] > 0]
    if len(means) >= 2:
        spread = (max(means) - min(means)) / max(means) if max(means) else 0.0
        tb.log.info(
            f"  mean-interval spread across backlog sizes "
            f"{NPKT_VALUES}: {means} -> relative spread={spread * 100:.1f}% "
            f"-- {'ROUGHLY CONSTANT (supports the fifoSize-depth lever)' if spread < 0.25 else 'SCALES WITH BACKLOG (would falsify/weaken the fifoSize-depth lever)'}")
    else:
        tb.log.warning("  not enough backlog sizes produced intervals to form a verdict")
