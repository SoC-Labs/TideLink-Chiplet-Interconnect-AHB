"""TXGEN SUSTAINED-THROUGHPUT characterization vs. the link's own ceiling.

The correctness suite (cocotb/tidelink_txgen, test_v2_txgen.py) proves TXGEN
saturates, never over/under-runs, and delivers byte-exact -- but only ever for
ONE small packet. This suite answers a different question: once TXGEN is
armed for a genuinely SUSTAINED run (GAP=0, thousands of words, the real
hardware credit gate ACTIVE, not TXGEN_CREDIT_GATE_DIS), what cycles/word does
it actually achieve, and how does that compare to the link's own theoretical
~16 hclk-cycles/word ceiling (8 UI, and "1 UI == 2 hclk" holds structurally in
every build -- see project_throughput_is_ps_bus_roundtrip_not_the_link
_2026_07_17 memory)?

HONEST SCOPE LIMIT: this sim has no Zynq PS-PL bridge at all. It does NOT
reproduce the hardware's ~96 hclk-cycle/word CPU-driven number (that number is
dominated by ARM Device-memory store semantics and the AXI-GP/AHB-lite bridge,
neither of which exist in this harness). What this suite DOES measure is
TXGEN's own achieved rate against the link's real ceiling -- the number that
actually decides whether TXGEN is a good accelerator, independent of the CPU
path.

THE REF-CLOCK TRAP (read before trusting a number out of this file):
pair_v2_common's default TIDELINK_SIM_REF_PERIOD_NS=8.0 (vs hclk=20ns) is
DELIBERATELY faster than silicon's true ratio, chosen so the a2l replay FIFO
never backpressures and unrelated suites in this directory stay fast and
stable. Under that default the link is NOT the bottleneck here, and this
suite's numbers reflect TXGEN's own state-machine overhead alone, not the
link ceiling. To reproduce the ~16-cycle ceiling this suite compares against,
1 UI must equal 2 hclk periods, i.e. ref_clk period == 2 x hclk period == 40ns
(hclk is fixed at CLK_PERIOD_NS=20ns everywhere in this env):

    TIDELINK_SIM_REF_PERIOD_NS=40.0 make EPOCH_PROFILE=zero \\
        MODULE=test_v2_txgen_throughput

Every test below logs the REF_CLK_PERIOD_NS it actually ran under and the
ceiling that implies (ceiling_hclk_per_word = 8 * REF_CLK_PERIOD_NS /
CLK_PERIOD_NS), so a result is self-documenting even if invoked without the
override -- but only the REF=40.0 run is the one that means anything relative
to the "~16 cycles/word" figure quoted in the design docs and handover notes.

Tests:
  test_txgen_sustained_throughput_ceiling
      The headline number: one long run (~3.8k words, N=124/packet, GAP=0,
      credit gate ACTIVE, credit pre-seeded for the whole run so the ceiling
      measurement is not itself credit-limited), cycles/word computed from
      PERF_CTRL SAMPLE_COUNT bracketing TXGEN_WORDS, full byte-exact +
      in-order drain check after.
  test_txgen_packet_size_overhead_sweep
      Same technique at N=4,8,16,32,64 (all pre-seeded, all one bring-up,
      cumulative words kept under the peer's 4096-word RX capacity) --
      shows whether TXGEN's own per-packet overhead (ARMED-state credit/
      ownership check + inter-packet GAP-state turnaround) is a FIXED
      per-packet cost that amortizes away at larger N, or a per-word cost
      that would not.
  test_txgen_live_credit_loop_sustained
      The other candidate bottleneck named in the task: does the CREDIT
      GATE's own check cadence cost anything once credit is not just
      pre-dumped but has to arrive back over the real hardware credit-return
      loop (peer drain -> release -> sideband credit-return packet -> our
      pair_credit_counter)? Seeds only a few packets' worth up front, runs
      a background drainer that pops the peer's RX FIFO as packets land
      (REL_THRESHOLD=0, immediate release), and separately tallies hclk
      cycles TXGEN spent in S_ARMED with credit_ok==0 (a direct RTL-level
      isolation of "credit-attributable stall", not conflated with the
      generic TXGEN_STALL saturating counter which also counts the
      inter-packet GAP state and AHB backpressure).

Run (fast/optimistic default -- TXGEN's own overhead only, link never binds):
  make EPOCH_PROFILE=zero MODULE=test_v2_txgen_throughput
Run (silicon-ratio -- the one to cite against the ~16-cycle ceiling):
  TIDELINK_SIM_REF_PERIOD_NS=40.0 make EPOCH_PROFILE=zero MODULE=test_v2_txgen_throughput
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_TIDELINK_BASE, read_packet_drain,
    APB_RELEASE_THRESHOLD, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
)

# ---------------------------------------------------------------------------
# Register map (mirrors test_v2_txgen.py / test_v2_perf_ctrl.py -- each
# cocotb dir/file is its own PYTHONPATH root by repo convention, constants
# are deliberately re-declared rather than shared).
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
CTRL_STOP    = 1 << 2
CTRL_FOREVER = 1 << 3
CTRL_CLR     = 1 << 4     # self-clearing; must NOT disturb EN (wdata[0] must stay 1)

ST_RUNNING      = 1 << 0
ST_DONE         = 1 << 1
ST_STALL_CREDIT = 1 << 2
ST_STALL_AHB    = 1 << 3
ST_ERR_AHB      = 1 << 4
ST_EXT_ABORT    = 1 << 5
ST_GATE_ACTIVE  = 1 << 6

APB_RELEASED_ACC = APB_TIDELINK_BASE + 0x020
APB_STATUS       = APB_TIDELINK_BASE + 0x010
ST_OVERRUN         = 1 << 1
ST_PKT_COMMITTED   = 1 << 4

PERF_CTRL     = 0x20A0   # region 5 word 0
PERF_TX_WORDS = 0x20D0   # region 6 word 4
PERF_TX_STALL = 0x20D8   # region 6 word 6
PERF_SAMPLES  = 0x20E8   # region 7 word 2
PERF_EN       = 0x1

# The peer RX SRAM is RAM_ADDR_W=14 bits -> 16 KiB -> 4096 words of real
# capacity (tidelink_fifo_ctrl.sv MAX_CREDITS). Every run below must stay
# under this without an intervening FLUSH/drain, or the "byte-exact after
# a full drain" oracle would be scoring a wrapped/overwritten buffer.
PEER_RX_CAPACITY_WORDS = 4096

# TXGEN's done_r/TXGEN_WORDS measure ADMISSION into the fc_adapter's AHB TX
# port only -- not that those words have finished serializing across the link
# and landing in the peer's RX FIFO. The a2l replay FIFO is 16 entries deep,
# so a propagation TAIL can still be in flight the instant done_r fires. Every
# other send helper in pair_v2_common (send_and_check_burst, _b2b_packets,
# etc.) waits a generous settle window between finishing TX and reading the
# peer's RX FIFO for exactly this reason -- this suite must too, or an
# in-flight read races the write side and can alias onto whatever is
# currently landing (observed directly: draining "packet 0" immediately after
# done_r returned late words from the LAST packet of a 30-packet run).
DRAIN_SETTLE_CYCLES = 5000

# Link ceiling this suite is measuring against: 8 UI/word, and 1 UI == 1
# ref_clk period in this env (ref_clk is the PHY user_ref_clk). See the
# module docstring for why REF_CLK_PERIOD_NS must be 40.0 (== 2 x hclk) for
# this to equal the documented "~16 hclk cycles/word".
CEILING_HCLK_PER_WORD = 8.0 * (REF_CLK_PERIOD_NS / CLK_PERIOD_NS)


def expected_payload(seq, beat):
    """The generator emits {seq[15:0], beat[15:0]} for payload beats (beat is
    the ADDRESS-beat index, 0=header, 1=dest, 2..N+1=payload)."""
    return ((seq & 0xFFFF) << 16) | (beat & 0xFFFF)


def expected_header(pkt_len):
    return (pkt_len << 20) | (0x1 << 18)   # WR_REQ, length pkt_len


async def _apb_read(tb, side, addr):
    return await tb.apb(side).read(addr)


async def arm_and_run_txgen(tb, src, pkt_len, npkt, initial_credit_words=None,
                             max_cycles=3_000_000, track_credit_stall=True):
    """Arm TXGEN on `src` for exactly `npkt` back-to-back packets of `pkt_len`
    payload words (GAP=0, DEST_OFF=0), run to completion, and return raw
    measurements. Does not itself drain the peer or assert anything -- the
    caller decides what to check.

    `initial_credit_words`: credit bumped into pair_credit_counter BEFORE
    starting. Default (None) = the WHOLE run's need (per_packet*npkt), i.e.
    the run is never credit-limited -- isolates TXGEN's own per-word/
    per-packet cost from the credit gate. Pass a smaller number to force the
    run to depend on live credit replenishment (a concurrent drainer must be
    running on the peer, see test_txgen_live_credit_loop_sustained).
    """
    per_packet = pkt_len + 2
    total_words = per_packet * npkt
    seed = total_words if initial_credit_words is None else initial_credit_words

    m = tb.apb(src)
    # tidelink_top.sv wraps the instance in an unlabelled-condition `generate if
    # (TXGEN_PRESENT) begin : g_txgen` block; VCS/cocotb exposes the whole
    # dotted path as ONE child name ("g_txgen.u_tx_gen"), not two nested
    # scopes, so plain attribute chaining (`.g_txgen.u_tx_gen`) does not
    # resolve -- index with the literal dotted name instead.
    gen = tb.top(src)["g_txgen.u_tx_gen"]

    if seed:
        await m.write(APB_RELEASED_ACC, seed)

    await m.write(TXGEN_PKT, pkt_len)                # DEST_OFF = 0
    await m.write(TXGEN_GAP, 0)                       # IPG=0, CREDIT_MARGIN=0
    await m.write(TXGEN_BUDGET, total_words)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_CLR)     # (re)arm + clear WORDS/STALL/DONE
    samp_before = await m.read(PERF_SAMPLES)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_START)

    credit_stall_cycles = 0
    ahb_stall_cycles = 0
    for i in range(max_cycles):
        await RisingEdge(tb.dut.hclk)
        if track_credit_stall:
            try:
                state = int(gen.state_r.value)
                if state == 1 and int(gen.running_r.value) and not int(gen.credit_ok.value):
                    credit_stall_cycles += 1
                if state == 2 and not int(gen.fc_hreadyout.value):
                    ahb_stall_cycles += 1
            except ValueError:
                pass
        if int(gen.done_r.value):
            break
    else:
        raise TimeoutError(
            f"TXGEN on {src} did not complete a {npkt}x{pkt_len}-word "
            f"(total {total_words}) run within {max_cycles} hclk")

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
        "ahb_stall_cycles": ahb_stall_cycles,
    }


async def verify_drain(tb, dst, npkt, per_packet, pkt_len, pkt_index_start):
    """Drain `npkt` packets in order from `dst`'s RX FIFO and byte-compare
    every word (header, dest_addr, every payload word) against what TXGEN's
    RTL is defined to emit (tidelink_tx_gen.sv beat_data). Returns a list of
    mismatches -- empty means byte-exact + in-order across the whole span."""
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
        f"cycles/word={cpw:6.3f}  ceiling={CEILING_HCLK_PER_WORD:6.3f}  "
        f"ratio={cpw / CEILING_HCLK_PER_WORD if CEILING_HCLK_PER_WORD else float('inf'):5.2f}x  "
        f"TXGEN_STALL={r['stall']:6d}  credit_stall={r['credit_stall_cycles']:6d}  "
        f"ahb_stall={r['ahb_stall_cycles']:6d}  STATUS=0x{r['status']:02x}  "
        f"PERF_TX_WORDS+={r['perf_tx_words']}")
    return cpw


@cocotb.test()
async def test_txgen_sustained_throughput_ceiling(dut):
    """The headline number. GAP=0, credit gate ACTIVE (not disabled), credit
    pre-seeded for the WHOLE run (not credit-limited -- see
    test_txgen_live_credit_loop_sustained for that axis), a few thousand
    words so bring-up/startup transients are a small fraction of the total,
    then byte-exact + in-order drain of everything sent."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")
    await m.write(PERF_CTRL, PERF_EN)

    PKT_LEN = 124                       # 126 words/packet
    NPKT    = 30                        # 3780 words total, < 4096 peer capacity
    assert (PKT_LEN + 2) * NPKT < PEER_RX_CAPACITY_WORDS

    tb.log.info(f"[sustained] REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} "
                f"CLK_PERIOD_NS={CLK_PERIOD_NS} -> ceiling="
                f"{CEILING_HCLK_PER_WORD:.3f} hclk/word "
                f"({'REALISTIC silicon ratio' if abs(REF_CLK_PERIOD_NS - 40.0) < 1e-6 else 'NOT the silicon ratio -- see module docstring'})")

    r = await arm_and_run_txgen(tb, "m", PKT_LEN, NPKT)
    cpw = _log_result(tb, "sustained", r)

    assert r["words"] == r["total_words"], (
        f"TXGEN_WORDS={r['words']} != requested total {r['total_words']} "
        f"at DONE -- budget accounting broken")
    assert (r["status"] & ST_GATE_ACTIVE), "credit gate not compiled in"
    assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
        f"TXGEN raised a sticky fault mid-run: STATUS=0x{r['status']:02x}")

    s_status = await tb.apb("s").read(APB_STATUS)
    assert not (s_status & ST_OVERRUN), (
        f"peer RX FIFO overran (STATUS=0x{s_status:08x}) during the sustained run")

    # Settle the propagation tail (see DRAIN_SETTLE_CYCLES) before scoring --
    # this is AFTER the elapsed-cycle measurement (already captured in `r`),
    # so it does not affect the cycles/word figure.
    await ClockCycles(dut.hclk, DRAIN_SETTLE_CYCLES)
    mism = await verify_drain(tb, "s", NPKT, r["per_packet"], PKT_LEN, pkt_index_start=0)
    if mism:
        for seq, idx, want, got in mism[:10]:
            tb.log.error(f"    pkt seq={seq} word[{idx}]: expected 0x{want:08x} got 0x{got:08x}")
    assert not mism, (
        f"{len(mism)} word mismatches across the {NPKT}-packet sustained drain "
        f"(first: {mism[0]}) -- NOT byte-exact/in-order at the sustained rate")

    tb.log.info(f"[sustained] RESULT: {cpw:.3f} hclk/word achieved vs "
                f"{CEILING_HCLK_PER_WORD:.3f} ceiling "
                f"({cpw / CEILING_HCLK_PER_WORD:.2f}x), "
                f"{NPKT} packets byte-exact + in-order.")


@cocotb.test()
async def test_txgen_packet_size_overhead_sweep(dut):
    """Same ample-credit technique at several packet sizes in ONE bring-up
    (cumulative words kept under the peer's 4096-word capacity, no
    drain/flush needed between configs). Shows whether the gap to the
    ceiling (if any) is a FIXED per-packet cost -- which would shrink as a
    fraction of cycles/word as N grows -- or scales with N, which it should
    not if the bottleneck really is TXGEN's own S_ARMED/S_GAP bookkeeping."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")
    await m.write(PERF_CTRL, PERF_EN)

    # (pkt_len, npkt) -- cumulative words = 240+400+720+1020+1320 = 3700 < 4096.
    configs = [(4, 40), (8, 40), (16, 40), (32, 30), (64, 20)]

    tb.log.info(f"[sweep] REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} -> ceiling="
                f"{CEILING_HCLK_PER_WORD:.3f} hclk/word")

    pkt_index = 0
    rows = []
    for pkt_len, npkt in configs:
        r = await arm_and_run_txgen(tb, "m", pkt_len, npkt)
        cpw = _log_result(tb, "sweep", r)

        assert r["words"] == r["total_words"], (
            f"N={pkt_len}: TXGEN_WORDS={r['words']} != {r['total_words']}")
        assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
            f"N={pkt_len}: sticky fault STATUS=0x{r['status']:02x}")

        # Settle the propagation tail before scoring (see DRAIN_SETTLE_CYCLES) --
        # after the elapsed-cycle measurement, so it does not skew cycles/word.
        await ClockCycles(dut.hclk, DRAIN_SETTLE_CYCLES)
        mism = await verify_drain(tb, "s", npkt, r["per_packet"], pkt_len, pkt_index)
        assert not mism, (
            f"N={pkt_len}: {len(mism)} mismatches, first {mism[0]} -- "
            f"not byte-exact/in-order")
        pkt_index += npkt

        # Net out the expected LINK-bound per-word cost (per_packet * ceiling)
        # to isolate TXGEN's own additive per-packet overhead (S_ARMED credit/
        # ownership check + S_GAP turnaround). Only meaningful as "TXGEN
        # overhead in cycles" once the run is actually link-limited (REF=40);
        # under the default fast ref clock this instead reads negative/noisy
        # because the link is NOT the bottleneck there (see module docstring).
        overhead_per_packet = r["elapsed"] / npkt - r["per_packet"] * CEILING_HCLK_PER_WORD
        rows.append((pkt_len, r["per_packet"], cpw, overhead_per_packet))

    s_status = await tb.apb("s").read(APB_STATUS)
    assert not (s_status & ST_OVERRUN), f"peer overran: STATUS=0x{s_status:08x}"

    tb.log.info("  ===== N sweep: cycles/word vs packet size =====")
    for pkt_len, per_packet, cpw, overhead in rows:
        tb.log.info(f"    N={pkt_len:4d} per_pkt={per_packet:4d} "
                    f"cycles/word={cpw:6.3f}  "
                    f"implied_overhead/packet={overhead:6.2f} hclk "
                    f"(elapsed/npkt - per_packet*ceiling)")
    # Larger packets should not be WORSE per-word than smaller ones if the
    # gap is a fixed per-packet cost amortizing away -- the monotonic
    # (non-strict, sim noise tolerance) trend is the actual evidence.
    cpws = [row[2] for row in rows]
    tb.log.info(f"  cycles/word smallest N ({rows[0][0]})={cpws[0]:.3f} -> "
                f"largest N ({rows[-1][0]})={cpws[-1]:.3f}")


@cocotb.test()
async def test_txgen_live_credit_loop_sustained(dut):
    """Does the credit gate's own replenishment cadence cost throughput once
    credit is not pre-dumped but must arrive back over the REAL hardware
    loop (peer RX pop -> release-threshold trigger -> returner sideband
    credit-return packet -> our pair_credit_counter)? Seeds only 3 packets'
    worth up front and runs a background drainer on the peer that pops (and
    byte-checks) each packet as it becomes visible (STATUS[4]
    packet_committed), with the peer's REL_THRESHOLD=0 (immediate release
    per pop, matching test_v2_credit_loop_close.py) so the loop closes as
    fast as this design allows.

    credit_stall_cycles isolates hclk cycles TXGEN spent in S_ARMED with
    credit_ok==0 (an exact RTL-level count, not the generic saturating
    TXGEN_STALL, which also includes the inter-packet GAP state and any AHB
    backpressure) -- the direct answer to "did the credit-check cadence
    force gaps."

    OPEN FINDING (2026-07-31, NOT ROOT-CAUSED -- out of this task's scope,
    flagged for follow-up): under this exact stimulus (SEED_PACKETS held
    deliberately tight, a live concurrent drainer with REL_THRESHOLD=0, GAP=0
    back-to-back admission) the LAST packet of a finite (non-FOREVER) budget
    run is reproducibly never delivered, even though TXGEN's own DONE/
    TXGEN_WORDS report all words cleanly admitted with no ERR_AHB/EXT_ABORT.
    Confirmed genuine (not a settle-time/wall-clock artifact) via a hard
    2,000,000 hclk bounded wait on the peer's packet_committed status: with
    PKT_LEN=14/NPKT=20/SEED_PACKETS=2, packets 0-18 land byte-exact and
    in-order, and packet 19 (the 20th, i.e. the very last one TXGEN admits
    before budget_r hits 0 and it self-parks in S_IDLE) never sets
    packet_committed on the peer, ever. Every OTHER test in this suite (ample
    pre-seeded credit, no live drain race) shows no such loss -- this appears
    specific to a packet landing right at TXGEN's own run-end transition
    while credit is live-tight. Root cause not investigated (would need its
    own dedicated session per this project's established practice for a new
    defect class); this test is left RED to keep the finding visible rather
    than silently softened.
    """
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    m = tb.apb("m")
    s = tb.apb("s")
    await m.write(PERF_CTRL, PERF_EN)
    await s.write(APB_RELEASE_THRESHOLD, 0)   # immediate release per pop
    await ClockCycles(dut.hclk, 20)

    PKT_LEN = 14                     # 16 words/packet -- kept modest: this
                                      # test's concurrent live-drain polling
                                      # loop is far slower in WALL-CLOCK terms
                                      # than test A/B's single measurement
                                      # loop (an earlier 40x32-word attempt at
                                      # this ran for 30+ minutes wall time
                                      # without a bug ever surfacing in the
                                      # log -- almost certainly CPU contention
                                      # from a concurrent `make sim_gate` also
                                      # running in this worktree, not a hang;
                                      # sized down + hard-bounded below so a
                                      # genuine stall fails fast with a
                                      # diagnosis instead of hanging silently)
    NPKT    = 20                     # 320 words total
    per_packet = PKT_LEN + 2
    SEED_PACKETS = 2                 # deliberately tight: forces reliance on
                                      # the live loop for the other 18 packets

    tb.log.info(f"[live-credit] REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} -> "
                f"ceiling={CEILING_HCLK_PER_WORD:.3f} hclk/word; seeding "
                f"only {SEED_PACKETS}/{NPKT} packets' worth of credit up front")

    drain_mismatches = []
    drain_count = [0]
    DRAIN_MAX_IDLE_POLLS = 20000      # 20000*100 = 2,000,000 hclk hard bound

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
                if idle_polls % 2000 == 0:
                    # Diagnostics if this ever stalls for real: peer credit
                    # count (own FIFO free space) + our pair_credit_counter
                    # (belief of peer's free space) + release accumulator.
                    cc = await s.read(APB_TIDELINK_BASE + 0x00C)
                    pcc = await m.read(APB_TIDELINK_BASE + 0x028)
                    tb.log.info(
                        f"  [live-credit drain] idle_polls={idle_polls} "
                        f"drained={drain_count[0]}/{NPKT} dst_credit_count="
                        f"{cc} src_pair_credit_counter={pcc}")
                if idle_polls > DRAIN_MAX_IDLE_POLLS:
                    raise TimeoutError(
                        f"live drainer stalled: only {drain_count[0]}/{NPKT} "
                        f"packets committed after {idle_polls} idle polls "
                        f"({idle_polls * 100} hclk) -- genuine stall, not a "
                        f"wall-clock/CPU-contention artifact")
                # Coarse poll: production is link-limited to roughly
                # 90-100+ hclk/word in this regime, so a 100 cycle poll still
                # notices a completed packet promptly without paying an APB
                # round trip (several hclk + a Python/VPI callback each)
                # every few cycles for the whole run.
                await ClockCycles(tb.dut.hclk, 100)

    drain_task = cocotb.start_soon(credit_drain_loop())

    r = await arm_and_run_txgen(tb, "m", PKT_LEN, NPKT,
                                 initial_credit_words=SEED_PACKETS * per_packet,
                                 max_cycles=2_000_000)
    cpw = _log_result(tb, "live-credit", r)

    # Let the drainer finish popping whatever landed after TXGEN's DONE
    # (hard-bounded via DRAIN_MAX_IDLE_POLLS inside credit_drain_loop itself
    # -- this will raise rather than hang if it's a real stall).
    await drain_task

    assert r["words"] == r["total_words"], (
        f"TXGEN_WORDS={r['words']} != requested {r['total_words']}")
    assert not (r["status"] & (ST_ERR_AHB | ST_EXT_ABORT)), (
        f"sticky fault STATUS=0x{r['status']:02x}")
    assert drain_count[0] == NPKT, (
        f"live drainer only popped {drain_count[0]}/{NPKT} packets")
    assert not drain_mismatches, (
        f"{len(drain_mismatches)} mismatches under the live credit loop "
        f"(first: {drain_mismatches[0]}) -- not byte-exact/in-order under "
        f"sustained live-credit load")

    credit_stall_frac = r["credit_stall_cycles"] / r["elapsed"] if r["elapsed"] else 0.0
    tb.log.info(
        f"[live-credit] RESULT: {cpw:.3f} hclk/word (vs ceiling "
        f"{CEILING_HCLK_PER_WORD:.3f}), credit_stall_cycles="
        f"{r['credit_stall_cycles']} / elapsed={r['elapsed']} "
        f"({credit_stall_frac * 100:.2f}% of total run time attributable to "
        f"S_ARMED-with-credit_ok==0), {NPKT} packets byte-exact + in-order "
        f"via the LIVE hardware credit-return loop (only {SEED_PACKETS} "
        f"packets pre-seeded).")
