"""DIAGNOSTIC (link-survey-2026-08-01, testbench-bug hypothesis investigation).

RESULT (2026-08-01, RUN AND CONFIRMED): **THEORY REFUTED.** The AHB
address-phase-hold fix below (`ahb_fifo_read_word_fixed`) does NOT eliminate
the corruption. Run twice (MAX_IDLE_POLLS=200 matching bidir_throughput.py
exactly, and again at 3000 -- 15x more patience): the ORIGINAL primitive
stalls at a bit-for-bit IDENTICAL 13/20 drained / 156 mismatches in BOTH runs
(fully deterministic given the seed, not a timing-window artifact), and the
FIXED primitive still shows the same class of corruption afterward (168
mismatches @200 polls, 140 @3000 polls -- same signature: whole packets'
worth of data missing/shifted, later reads returning a LATER packet's true
payload). More patience does not recover additional packets either --
confirms this is a genuine PERMANENT desync once triggered, not a transient
stall an insufficiently-generous poll bound would explain.
CONCLUSION: the corruption is not (solely, or even primarily) explained by
`ahb_fifo_read_word`'s AHB-protocol deviation -- see the theory below for why
that deviation looked plausible, and RTL_LEAD below for where this
investigation's remaining evidence points instead (kept here as-is, refuted
theory and all, so a future session does not have to re-derive and re-test
the same idea from scratch).

RTL_LEAD (NOT chased further -- out of a testbench-focused task's scope,
flagged for the RTL-race-hypothesis investigation instead): src/rtl/fifo/
tidelink_fifo_ctrl.sv:249-355 computes `packet_word_length_r` /
`packet_active_r` / `check_addr_r` (and, from the SAME `packet_word_length_nxt`
each cycle, BOTH `write_target_addr_r` AND `read_target_addr_r` --
tidelink_fifo_ctrl.sv:353-354) via ONE shared, priority-encoded `always_comb`
block multiplexing FOUR independent event sources: FC-write packet-start
(`fc_write_addr0`, line 217/295-299, NO `!packet_active_r` guard), AHB-write
packet-start (`capture_write_length_r`, guarded by `ahb_pkt_start_ok`'s
explicit `!packet_active_r` at line 224), and the two-cycle AHB-read length
capture (`check_addr_r` arm at line 320-322, capture at line 344-348). Because
`fc_write_addr0` sits ABOVE the read-side branches in the if/else-if chain
and carries no analogous "a read is already using this metadata" guard, an
INCOMING packet's link-side header write landing on the same cycle as an
in-flight AHB read's `check_addr_r` arm/capture step would hijack the shared
length/active/target-address state out from under the read in progress --
plausible root cause for the observed "packet_active read gets an unrelated
packet's data" / "one whole packet's words vanish from the read stream"
signature. NOT verified at the waveform level here (would need RTL-side
debugging, explicitly out of scope for this testbench-focused investigation).

NOT a permanent gate -- a targeted, minimal repro used to confirm/refute a
specific testbench-bug theory for the concurrent-drain-while-TX-active
corruption seen today in test_v2_bidir_throughput.py and
test_v2_txgen_kr260_ratio.py (both left untouched -- this is a standalone
copy, per this investigation's constraint not to edit either file).

THEORY: pair_v2_common.py's `ahb_fifo_read_word` (used by every drain in this
directory via `read_packet_drain`) does not hold HSEL/HTRANS/HADDR stable
across wait states -- it asserts them for exactly ONE hclk edge and then
unconditionally withdraws them, regardless of whether that edge's hreadyout
was actually 1:

    g("hsel").value, g("htrans").value = 1, 2
    ...
    await RisingEdge(dut.hclk)
    g("hsel").value, g("htrans").value = 0, 0     # <-- withdrawn unconditionally
    for _ in range(50):
        await RisingEdge(dut.hclk)
        if int(hready.value): break                # <-- hready polled AFTER withdrawal

This is silently correct whenever the read's one-shot address-phase edge does
NOT collide with `fc_active` (src/rtl/fifo/tidelink_fifo_mem.sv:91,105,119):
cmsdk_ahb_to_sram (/research/AAA/ip_library/.../cmsdk_ahb_to_sram.v:208) always
asserts its own HREADYOUT=1'b1 (zero-wait-state), so the outer
`hreadyout = ahb_hreadyout_raw && !fc_active` (tidelink_fifo_mem.sv:206) is
normally 1 immediately and the poll loop's first iteration just happens to
land exactly one cycle after the address phase -- which is also exactly when
the SRAM's registered read output becomes valid, so it reads correctly BY
COINCIDENCE.

But `ahb_access = HTRANS[1] & HSEL & HREADY` inside cmsdk_ahb_to_sram (its
`HREADY` INPUT is tidelink_fifo_mem's `ahb_hready_gated = hready && !fc_active`,
line 119) is combinationally gated by the SAME `fc_active`. If `fc_active`
happens to be 1 on the exact edge the testbench presents HSEL/HTRANS/HADDR,
`ahb_access` is FALSE that edge -- the read's address phase is NEVER ACCEPTED
by the RTL. The testbench withdraws HSEL the very next edge regardless, so the
read is never retried -- it is SILENTLY DROPPED. The testbench then polls
`hreadyout` (== `!fc_active`), which usually clears again within a cycle or
two, and captures whatever HRDATA/SRAMRDATA happens to be on the bus at that
point -- data belonging to an unrelated transaction (a different read that DID
land, or the FC write's own address), not the requested offset.

This collision is essentially never exercised by any PRE-EXISTING suite: every
other drain in this codebase either (a) waits for TX to fully finish + a
multi-thousand-cycle settle before reading (fc_active long since idle -- no
window at all), or (b) IS a concurrent drain
(test_v2_txgen_throughput.py::test_txgen_live_credit_loop_sustained) but one so
heavily credit-throttled (~79% of its runtime is S_ARMED/credit_ok==0 stall,
confirmed via this investigation's own control run) that fc_active is asserted
only rarely relative to the huge idle gaps between reads -- low collision
probability, never reported as corruption there (only the separate,
already-known "last packet never delivered" issue). Both NEW files introduce
the first HIGH-DUTY-CYCLE concurrent fc_active stimulus in this codebase's
history (bidir: full pre-seeded credit, GAP=0, back-to-back send; kr260_ratio:
same drain loop as the reference test, just run at REF=160), which is why this
dormant bug is suddenly and dramatically exposed today.

THIS FILE: reproduces bidir_throughput's own uni-directional Phase 1 (M sends
alone at the REALISTIC REF=40 ratio, S drains concurrently) TWICE in one
bring-up -- once with the ORIGINAL `read_packet_drain`/`ahb_fifo_read_word`
(expect the corruption to reproduce, matching bidir's own N16-uni-m2s result:
13/20 drained, ~150+ mismatches), and once (fresh TXGEN re-arm, same
bring-up, continued seq_r) with a FIXED read primitive that holds
HSEL/HTRANS/HADDR asserted across wait states until an edge where hreadyout
is ACTUALLY 1 is observed (mirrors the already-proven-correct
`_await_hready`-before-committing idiom pair_v2_common.py's AHB TX write path
uses), and expects the corruption to disappear (byte-exact, full delivery).

Run:
  source ./set_env.sh
  TIDELINK_SIM_REF_PERIOD_NS=40.0 make EPOCH_PROFILE=zero \\
      MODULE=test_diag_ahb_read_fix
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_TIDELINK_BASE, CLK_PERIOD_NS,
    REF_CLK_PERIOD_NS,
)

TXGEN_CTRL   = 0x21C0
TXGEN_PKT    = 0x21C4
TXGEN_GAP    = 0x21C8
TXGEN_BUDGET = 0x21CC
TXGEN_STATUS = 0x21D0
TXGEN_WORDS  = 0x21D4

CTRL_EN      = 1 << 0
CTRL_START   = 1 << 1
CTRL_CLR     = 1 << 4

ST_DONE          = 1 << 1
APB_RELEASED_ACC = APB_TIDELINK_BASE + 0x020
APB_STATUS       = APB_TIDELINK_BASE + 0x010
ST_PKT_COMMITTED = 1 << 4

PEER_RX_CAPACITY_WORDS = 4096
POLL_GAP = 100
import os
MAX_IDLE_POLLS = int(os.environ.get("DIAG_MAX_IDLE_POLLS", "200"))
                        # default: the SAME tight bound bidir_throughput.py
                        # uses, so this is an apples-to-apples repro of its
                        # exact stimulus/timeout shape. Override via
                        # DIAG_MAX_IDLE_POLLS to test whether "stuck at
                        # 13/20" is a timeout-tightness artifact (delivery
                        # resumes given more patience) or a genuine permanent
                        # stall/desync (stays stuck regardless of bound).


def _expected_payload(seq, beat):
    return ((seq & 0xFFFF) << 16) | (beat & 0xFFFF)


def _expected_header(pkt_len):
    return (pkt_len << 20) | (0x1 << 18)


# ---------------------------------------------------------------------------
# ORIGINAL read primitive (verbatim copy of pair_v2_common.ahb_fifo_read_word
# / read_packet_drain -- reproduced here, not imported, so this file can run
# BOTH the original and the fixed version side by side in one test without
# monkeypatching the shared module other suites in this directory depend on).
# ---------------------------------------------------------------------------
async def ahb_fifo_read_word_original(tb, side, byte_addr):
    dut = tb.dut
    g = lambda n: getattr(dut, f"{side}_ahb_fifo_{n}")
    hready, hrdata = g("hready"), g("hrdata")
    await RisingEdge(dut.hclk)
    for _ in range(50):
        try:
            if int(hready.value):
                break
        except ValueError:
            pass
        await RisingEdge(dut.hclk)
    g("hsel").value, g("htrans").value = 1, 2
    g("hsize").value, g("hwrite").value = 2, 0
    g("haddr").value = byte_addr & ((1 << 14) - 1)
    await RisingEdge(dut.hclk)
    g("hsel").value, g("htrans").value = 0, 0
    for _ in range(50):
        await RisingEdge(dut.hclk)
        try:
            if int(hready.value):
                break
        except ValueError:
            pass
    try:
        return int(hrdata.value)
    except ValueError:
        return 0


async def read_packet_drain_original(tb, dst, n_words):
    return [await ahb_fifo_read_word_original(tb, dst, i * 4) for i in range(n_words)]


# ---------------------------------------------------------------------------
# FIXED read primitive: HOLD hsel/htrans/haddr asserted across wait states
# instead of withdrawing after exactly one edge -- only withdraw once an edge
# is observed where hreadyout was ACTUALLY 1 while the address was still
# being presented (the real, accepted address phase). This is the AHB-legal
# behaviour cmsdk_ahb_to_sram's ahb_access = HTRANS[1]&HSEL&HREADY term
# requires: HSEL/HTRANS must stay asserted on the SAME cycle HREADY (here,
# gated by !fc_active) is finally 1, or the address phase is never sampled.
# ---------------------------------------------------------------------------
async def ahb_fifo_read_word_fixed(tb, side, byte_addr, timeout=2000):
    dut = tb.dut
    g = lambda n: getattr(dut, f"{side}_ahb_fifo_{n}")
    hready, hrdata = g("hready"), g("hrdata")
    await RisingEdge(dut.hclk)
    g("hsel").value, g("htrans").value = 1, 2
    g("hsize").value, g("hwrite").value = 2, 0
    g("haddr").value = byte_addr & ((1 << 14) - 1)
    accepted = False
    for _ in range(timeout):
        await RisingEdge(dut.hclk)
        try:
            if int(hready.value):
                accepted = True
                break
        except ValueError:
            pass
        # hready==0 this edge (e.g. fc_active collided with our address
        # phase) -- HOLD hsel/htrans/haddr (do NOT touch them) and retry next
        # edge. This is the one-line behavioural difference from the
        # original: the original unconditionally zeroed hsel/htrans right
        # here regardless of hready, silently abandoning the transfer.
    if not accepted:
        g("hsel").value, g("htrans").value = 0, 0
        raise TimeoutError(
            f"AHB fifo read address phase on {side}@0x{byte_addr:x} never "
            f"saw hreadyout=1 within {timeout} cycles")
    g("hsel").value, g("htrans").value = 0, 0
    # SRAM registered-read latency: HRDATA (cmsdk_ahb_to_sram's SRAMRDATA
    # passthrough) becomes valid one hclk after the accepted address edge.
    await RisingEdge(dut.hclk)
    try:
        return int(hrdata.value)
    except ValueError:
        return 0


async def read_packet_drain_fixed(tb, dst, n_words):
    return [await ahb_fifo_read_word_fixed(tb, dst, i * 4) for i in range(n_words)]


# ---------------------------------------------------------------------------
# Shared drain-loop / send harness, parameterized on which read primitive to
# use -- otherwise IDENTICAL to bidir_throughput.py's _drain_loop/_run_direction
# for a single uni-directional M->S leg (Phase 1 of that suite).
# ---------------------------------------------------------------------------
async def _drain_loop(tb, dst, npkt, per_packet, pkt_len, mismatches, drained,
                       tag, seq_start, drain_fn):
    exp_hdr = _expected_header(pkt_len)
    idle = 0
    while drained[0] < npkt:
        st = await tb.apb(dst).read(APB_STATUS)
        if st & ST_PKT_COMMITTED:
            idle = 0
            got = await drain_fn(tb, dst, per_packet)
            seq = seq_start + drained[0]
            if got[0] != exp_hdr:
                mismatches.append((seq, 0, exp_hdr, got[0]))
            if got[1] != 0:
                mismatches.append((seq, 1, 0, got[1]))
            for b in range(2, per_packet):
                want = _expected_payload(seq, b)
                if got[b] != want:
                    mismatches.append((seq, b, want, got[b]))
            drained[0] += 1
        else:
            idle += 1
            if idle > MAX_IDLE_POLLS:
                raise TimeoutError(
                    f"{tag}: drain on {dst} stalled at {drained[0]}/{npkt} "
                    f"packets after {idle * POLL_GAP} hclk idle")
            await ClockCycles(tb.dut.hclk, POLL_GAP)


async def _run_uni_direction(tb, src, dst, pkt_len, npkt, tag, seq_start, drain_fn):
    per_packet = pkt_len + 2
    total_words = per_packet * npkt
    m = tb.apb(src)

    await m.write(APB_RELEASED_ACC, total_words)
    await m.write(TXGEN_PKT, pkt_len)
    await m.write(TXGEN_GAP, 0)
    await m.write(TXGEN_BUDGET, total_words)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_CLR)
    await m.write(TXGEN_CTRL, CTRL_EN | CTRL_START)

    mismatches = []
    drained = [0]
    drain_task = cocotb.start_soon(
        _drain_loop(tb, dst, npkt, per_packet, pkt_len, mismatches, drained,
                    tag, seq_start, drain_fn))

    status = 0
    for _ in range(30000):
        status = await m.read(TXGEN_STATUS)
        if status & ST_DONE:
            break
        await ClockCycles(tb.dut.hclk, POLL_GAP)
    else:
        raise TimeoutError(f"{tag}: TXGEN on {src} never completed")

    words = await m.read(TXGEN_WORDS)

    drain_timed_out = False
    try:
        await drain_task
    except TimeoutError as e:
        drain_timed_out = True
        tb.log.warning(f"[{tag}] drain timed out at {drained[0]}/{npkt}: {e}")

    return {
        "tag": tag, "words": words, "total_words": total_words,
        "mismatches": mismatches, "drained": drained[0], "npkt": npkt,
        "drain_timed_out": drain_timed_out,
    }


def _report(tb, r):
    tb.log.info(
        f"  [{r['tag']}] words={r['words']}/{r['total_words']}  "
        f"drained={r['drained']}/{r['npkt']}  mismatches={len(r['mismatches'])}  "
        f"drain_timed_out={r['drain_timed_out']}")
    if r["mismatches"]:
        for m in r["mismatches"][:5]:
            tb.log.info(f"      first mismatches: seq={m[0]} word={m[1]} "
                        f"expected={m[2]} got={m[3]}")


@cocotb.test()
async def test_ahb_read_fix_ab_comparison(dut):
    """A/B: same bring-up, same one-directional stimulus (M->S, ample
    pre-seeded credit, GAP=0, REF=40 -- bidir_throughput.py Phase 1's exact
    config), first drained with the ORIGINAL read primitive (expect the
    corruption to reproduce), then with the FIXED one (expect it to vanish)."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)

    tb.log.info(f"[ahb-read-fix] REF_CLK_PERIOD_NS={REF_CLK_PERIOD_NS} "
                f"CLK_PERIOD_NS={CLK_PERIOD_NS} "
                f"({'REALISTIC silicon ratio' if abs(REF_CLK_PERIOD_NS - 40.0) < 1e-6 else 'NOT REF=40 -- results not comparable to bidir_throughput.py'})")

    PKT_LEN = 14
    NPKT = 20
    assert (PKT_LEN + 2) * NPKT < PEER_RX_CAPACITY_WORDS

    r_orig = await _run_uni_direction(tb, "m", "s", PKT_LEN, NPKT,
                                       "ORIGINAL-read", seq_start=0,
                                       drain_fn=read_packet_drain_original)
    _report(tb, r_orig)

    await ClockCycles(dut.hclk, 2000)

    r_fixed = await _run_uni_direction(tb, "m", "s", PKT_LEN, NPKT,
                                        "FIXED-read", seq_start=NPKT,
                                        drain_fn=read_packet_drain_fixed)
    _report(tb, r_fixed)

    tb.log.info(
        f"  ===== VERDICT =====\n"
        f"    ORIGINAL read primitive: {len(r_orig['mismatches'])} mismatches, "
        f"{r_orig['drained']}/{r_orig['npkt']} drained\n"
        f"    FIXED    read primitive: {len(r_fixed['mismatches'])} mismatches, "
        f"{r_fixed['drained']}/{r_fixed['npkt']} drained\n"
        f"    -> {'FIX CONFIRMED (corruption eliminated)' if r_fixed['mismatches'] == [] and not r_orig['mismatches'] == [] else 'INCONCLUSIVE -- see raw counts above'}")

    # Hard assertions: the FIXED primitive must be clean. The ORIGINAL run is
    # deliberately NOT asserted on (it is expected/allowed to reproduce the
    # known corruption; that is the control half of this A/B, not a pass/fail
    # gate for this diagnostic).
    assert not r_fixed["mismatches"], (
        f"FIXED read primitive still produced {len(r_fixed['mismatches'])} "
        f"mismatches (first {r_fixed['mismatches'][0]}) -- theory REFUTED or "
        f"incomplete, the corruption is not (solely) explained by the "
        f"unconditional-hsel-withdrawal race in ahb_fifo_read_word")
