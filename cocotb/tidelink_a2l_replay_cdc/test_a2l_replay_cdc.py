"""Unit tests that ISOLATE the TideLink a2l (app->link) replay-FIFO clock-domain
crossing and reproduce / gate the silicon "false-FULL on the first write" bug.

DUT: WlinkGenericFCReplayV2_13 (app->link replay FIFO, WITH revert), standalone
in tb_top with INDEPENDENT app_clk (fast, =hclk) and link_clk (slow, =hclk/16)
and INDEPENDENTLY-controllable app_reset / link_reset deassert timing.

Silicon bug (proven via OBS tap 0x44032158): idle app_ready=1; on the very
first app write a2l_full asserts because the synced ACK ptr (a2l_link_addr_app_clk)
sits a full lap AHEAD of the write ptr (captured value 0b10001 = 17 while
wbin_ptr = 0b00000). a2l_full = (wptr[4]!=ack[4]) & (wptr[3:0]==ack[3:0]).

ROOT CAUSE (code-confirmed): the synced ACK ptr lives in WavMultibitSync_18, a
toggle/ping-pong CDC whose two halves are reset by DIFFERENT domains
(w_reset=link_reset, r_reset=app_reset). On an asymmetric reset-deassert
between the fast app_clk and the slow link_clk, the read-side handshake can
fire (r_ready = rptr ^ wptr_demet) and latch a stale / not-yet-coherent value
into the synced ACK ptr -> a2l_full=1 on the first write -> app_ready=0 ->
the FCSM never transmits.

Phase-1  : reset-coherency sweep (the actual bug), no link/ack traffic.
Phase-2  : functional app-write / link-read / ack / revert.
Adversarial: force the AddrSync read-side reset to release strictly AFTER the
            write side -> must FAIL pre-fix, PASS post-fix.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
from cocotb.handle import Force, Release

# ── clock periods (link_clk = app_clk / 16, as on silicon) ─────────────────
APP_PERIOD_NS  = 20      # 50 MHz-ish fast app/hclk domain
LINK_PERIOD_NS = 320     # app/16 slow link domain

# ── DUT-source provenance (just for the log banner) ────────────────────────
USE_DEPS_DUT = os.environ.get("USE_DEPS_DUT", "0") == "1"


def _sigint(sig):
    try:
        return int(sig.value)
    except ValueError:
        return -1   # X/Z


def probe(dut):
    """Return the four key nets as ints (-1 if X/Z)."""
    return dict(
        wbin_ptr   = _sigint(dut.dut.fifo_io_wbin_ptr),
        synced_ack = _sigint(dut.dut.a2l_link_addr_app_clk),
        a2l_full   = _sigint(dut.dut.a2l_full),
        app_ready  = _sigint(dut.dut.app_ready),
        link_empty = _sigint(dut.dut.link_empty),
    )


async def start_clocks(dut):
    cocotb.start_soon(Clock(dut.app_clk,  APP_PERIOD_NS,  units="ns").start())
    cocotb.start_soon(Clock(dut.link_clk, LINK_PERIOD_NS, units="ns").start())


def tie_idle(dut):
    """Tie all DUT inputs to a sane idle state (no traffic)."""
    dut.app_enable.value      = 1     # link enabled (enable demets resolve to 1)
    dut.app_data.value        = 0
    dut.app_valid.value       = 0
    dut.link_ack_update.value = 0
    dut.link_ack_addr.value   = 0
    dut.link_revert.value     = 0
    dut.link_revert_addr.value = 0
    dut.link_advance.value    = 0


async def reset_with_skew(dut, skew_link_cycles):
    """Assert both resets, then deassert app_reset and link_reset with a
    controllable relative skew measured in link_clk cycles.

    skew_link_cycles > 0  ->  link_reset deasserts LATER than app_reset
                              (app domain runs free while link still in reset --
                               the silicon condition: app_reset releases EARLY).
    skew_link_cycles < 0  ->  app_reset deasserts later than link_reset.
    skew_link_cycles == 0 ->  both deassert on the same link edge.
    """
    tie_idle(dut)
    dut.app_reset.value  = 1
    dut.link_reset.value = 1
    # hold both resets well past the randomize delay (#0.002) and several
    # cycles of the slow clock so all flops settle in reset.
    await ClockCycles(dut.link_clk, 4)

    if skew_link_cycles >= 0:
        # app_reset releases first, on an app edge
        await RisingEdge(dut.app_clk)
        dut.app_reset.value = 0
        # then link_reset releases skew link-cycles later
        if skew_link_cycles > 0:
            await ClockCycles(dut.link_clk, skew_link_cycles)
        await RisingEdge(dut.link_clk)
        dut.link_reset.value = 0
    else:
        await RisingEdge(dut.link_clk)
        dut.link_reset.value = 0
        await ClockCycles(dut.link_clk, -skew_link_cycles)
        await RisingEdge(dut.app_clk)
        dut.app_reset.value = 0

    # let both domains run a bit so the synced ACK ptr fully propagates
    await ClockCycles(dut.app_clk, 8)
    await ClockCycles(dut.link_clk, 2)
    await ClockCycles(dut.app_clk, 8)


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  PHASE 1 — RESET COHERENCY (the actual bug), no link/ack traffic          ║
# ╚══════════════════════════════════════════════════════════════════════════╝

async def _phase1_one_skew(dut, skew):
    """Run reset at the given skew, then idle for >=64 app_clk with ZERO link
    traffic and check the FIFO is coherently empty/not-full.
    Returns (ok, captured_state_dict)."""
    await reset_with_skew(dut, skew)

    # observe for >=64 app_clk with no traffic; capture worst (any) violation
    worst = None
    for _ in range(80):
        await RisingEdge(dut.app_clk)
        st = probe(dut)
        bad = not (st["synced_ack"] == 0 and st["wbin_ptr"] == 0
                   and st["a2l_full"] == 0 and st["app_ready"] == 1)
        if bad and worst is None:
            worst = dict(st)
    ok = worst is None
    return ok, worst


@cocotb.test()
async def test_phase1_reset_coherency_sweep(dut):
    """Sweep app/link reset-deassert skew across 0..40 link_clk cycles.

    GATE: at EVERY skew, after both resets deassert and >=64 idle app_clk with
    NO link traffic:  synced_ack==0 && wbin_ptr==0 && a2l_full==0 && app_ready==1.

    On the PRE-FIX RTL this is expected to FAIL at some skews (synced_ack!=0,
    a2l_full=1, app_ready=0) -- that reproduction is reported, then asserted.
    """
    await start_clocks(dut)
    dut._log.info("DUT source = %s",
                  "deps (PRE-FIX)" if USE_DEPS_DUT else "local-override-if-present")

    failing = []      # list of (skew, captured_state)
    SKEWS = list(range(0, 41))
    for skew in SKEWS:
        ok, st = await _phase1_one_skew(dut, skew)
        if ok:
            dut._log.info("skew=%2d link-cyc : COHERENT (ack=0, not-full, ready)", skew)
        else:
            ack = st["synced_ack"]
            failing.append((skew, ack, st))
            dut._log.error(
                "skew=%2d link-cyc : INCOHERENT  synced_ack=%s (0b%s) "
                "wbin_ptr=%d a2l_full=%d app_ready=%d  <-- BUG REPRODUCED",
                skew, ack, format(ack & 0x1f, "05b") if ack >= 0 else "X",
                st["wbin_ptr"], st["a2l_full"], st["app_ready"])

    if failing:
        acks = sorted({a for _, a, _ in failing})
        dut._log.error("PHASE-1 FAILING SKEWS (link-cyc): %s",
                       [s for s, _, _ in failing])
        dut._log.error("PHASE-1 captured synced_ack values: %s "
                       "(silicon signature = 17 = 0b10001)", acks)

    assert not failing, (
        f"a2l replay FIFO reset-INCOHERENT at skews "
        f"{[s for s,_,_ in failing]}; captured synced_ack values "
        f"{sorted({a for _,a,_ in failing})} (expected all 0). "
        f"Silicon signature is synced_ack=17=0b10001 -> false-FULL on first write.")


@cocotb.test()
async def test_phase1_first_write_not_falsely_full(dut):
    """Direct silicon-signature check at the most app-early skew: after a
    coherent-empty reset, the FIRST app write must be accepted (app_ready=1,
    winc fires, wbin_ptr advances 0->1) and must NOT see a2l_full."""
    await start_clocks(dut)
    # worst real-world case: app_reset releases MANY link cycles before link
    await reset_with_skew(dut, 20)

    st = probe(dut)
    dut._log.info("post-reset idle: %s", st)
    assert st["synced_ack"] == 0, (
        f"synced ACK ptr = {st['synced_ack']} (0b{st['synced_ack']&0x1f:05b}) "
        f"after reset -- should be 0. This is the bug (ack ahead of wptr).")
    assert st["app_ready"] == 1 and st["a2l_full"] == 0

    # present one app word and complete the handshake
    dut.app_data.value  = 0x0000_DEAD_BEEF
    dut.app_valid.value = 1
    await RisingEdge(dut.app_clk)        # winc = app_ready & app_valid this edge
    await RisingEdge(dut.app_clk)
    dut.app_valid.value = 0
    st2 = probe(dut)
    dut._log.info("after first write: %s", st2)
    assert st2["wbin_ptr"] == 1, (
        f"first write did not advance write ptr (wbin_ptr={st2['wbin_ptr']}); "
        f"winc never fired -> app_ready stuck low -> FCSM never transmits.")
    assert st2["a2l_full"] == 0 and st2["app_ready"] == 1, \
        "FIFO falsely full after a single write into an empty FIFO"
    # write-ptr CDC into the slow link domain takes a few link clocks
    await ClockCycles(dut.link_clk, 4)
    assert _sigint(dut.dut.link_empty) == 0, "FIFO should be non-empty after a write"


async def link_ack(dut, addr, pulses=1):
    """Drive an ACK on the link side: link_ack_update high for `pulses`
    link cycles with link_ack_addr=addr. This is exactly how the FCSM drives
    a2l_fc_replay.link_ack_update on receipt of an ACK packet
    (WlinkGenericFCSM_6.v:614-615)."""
    dut.link_ack_addr.value   = addr
    for _ in range(pulses):
        dut.link_ack_update.value = 1
        await RisingEdge(dut.link_clk)
    dut.link_ack_update.value = 0


@cocotb.test()
async def test_phase1_predata_ack_lap_ahead(dut):
    """REPRODUCTION of the exact silicon mechanism: an ACK whose addr is a full
    lap ahead of the (still-zero) write ptr arrives BEFORE any app data write.

    On silicon the FCSM drove a2l_fc_replay.link_ack_update during bring-up with
    link_ack_addr that left the synced ACK ptr = 17 = 0b10001 while wptr=0.
    Idle then shows app_ready=1 (wptr=0 not full), but the FIRST app write makes
    wptr=1 and a2l_full = (wptr[4]!=ack[4]) & (wptr[3:0]==ack[3:0]) = TRUE ->
    app_ready=0 -> winc never fires -> wbin_ptr stuck -> FCSM never transmits.

    GATE: after a spurious pre-data ACK, the FIRST app write must still be
    accepted (wbin_ptr advances 0->1, a2l_full stays 0). The fix must ignore /
    bound the ACK ptr against the write ptr so it can never sit a lap ahead.
    """
    await start_clocks(dut)
    await reset_with_skew(dut, 5)

    # idle is healthy
    st = probe(dut)
    assert st["wbin_ptr"] == 0 and st["app_ready"] == 1
    dut._log.info("pre-ACK idle: %s", st)

    # a spurious pre-data ACK acknowledging addr 1 of the NEXT lap (=17)
    await link_ack(dut, 17, pulses=2)
    # let the AddrSync carry it into app_clk
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) != 0:
            break
    ack = _sigint(dut.dut.a2l_link_addr_app_clk)
    st = probe(dut)
    dut._log.info("after spurious ACK(17): synced_ack=%s (0b%s) wbin_ptr=%d "
                  "a2l_full=%d app_ready=%d",
                  ack, format(ack & 0x1f, "05b") if ack >= 0 else "X",
                  st["wbin_ptr"], st["a2l_full"], st["app_ready"])

    # GATE: a spurious pre-data ACK must NOT leave the synced ACK ptr a lap
    # ahead of the write ptr. With an empty FIFO (only 1 word ever written)
    # the FIFO can NEVER be legitimately full at depth 16, so a2l_full=1 after
    # a single write is the false-full bug.
    dut.app_data.value  = 0x0000_DEAD_BEEF
    dut.app_valid.value = 1
    # complete one write
    for _ in range(8):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.fifo_io_wbin_ptr) == 1:
            break
    dut.app_valid.value = 0
    await RisingEdge(dut.app_clk)
    wp   = _sigint(dut.dut.fifo_io_wbin_ptr)
    full = _sigint(dut.dut.a2l_full)
    rdy  = _sigint(dut.dut.app_ready)
    ackf = _sigint(dut.dut.a2l_link_addr_app_clk)
    dut._log.info("after first write: wbin_ptr=%d synced_ack=%d a2l_full=%d app_ready=%d",
                  wp, ackf, full, rdy)
    assert full == 0 and rdy == 1, (
        f"FALSE-FULL reproduced (silicon 'Bug A'): a pre-data ACK(17) left the "
        f"synced ACK ptr a lap ahead (synced_ack={ackf}=0b{ackf&0x1f:05b}); after "
        f"a single write the FIFO reports a2l_full={full}, app_ready={rdy} even "
        f"though only 1 of 16 slots is used. The next write is blocked -> winc "
        f"stalls -> FCSM never transmits. The ACK ptr must be bounded so it can "
        f"never sit ahead of the write ptr.")


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  PHASE 2 — FUNCTIONAL: app writes + link reads + ack + revert             ║
# ╚══════════════════════════════════════════════════════════════════════════╝

async def app_write(dut, data, timeout=200):
    """Drive exactly ONE app word with the app_ready handshake (single winc).
    Returns wbin_ptr after the write."""
    # present data/valid combinationally and wait until app_ready is high at a
    # rising edge -- that is the edge winc fires (winc = app_ready & app_valid).
    cycles = 0
    while True:
        dut.app_data.value  = data
        dut.app_valid.value = 1
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.app_ready) == 1:
            # winc fired on THIS edge; drop valid immediately so only one beat
            dut.app_valid.value = 0
            break
        cycles += 1
        assert cycles < timeout, "app_ready never asserted (FIFO stuck full?)"
    # one more edge so the registered wbin_ptr settles
    await RisingEdge(dut.app_clk)
    return _sigint(dut.dut.fifo_io_wbin_ptr)


async def link_read_one(dut):
    """Pop one word on the link side via link_advance when link_valid."""
    cycles = 0
    while _sigint(dut.dut.link_valid) != 1:
        await RisingEdge(dut.link_clk)
        cycles += 1
        assert cycles < 200, "link_valid never asserted"
    data = _sigint(dut.dut.link_data)
    cur  = _sigint(dut.dut.link_cur_addr)
    dut.link_advance.value = 1
    await RisingEdge(dut.link_clk)
    dut.link_advance.value = 0
    return data, cur


@cocotb.test()
async def test_phase2_functional_write_read_ack_revert(dut):
    """End-to-end functional check of the replay FIFO across the CDC."""
    await start_clocks(dut)
    await reset_with_skew(dut, 5)

    # lap-aware invariant: synced_ack must never be strictly "ahead" of wptr in
    # a way that makes the FIFO falsely full at this depth. With no acks issued,
    # synced_ack stays 0 and writes must keep being accepted until the FIFO
    # actually fills (16 deep). We never falsely full.
    assert probe(dut)["a2l_full"] == 0

    # ── write 4 words, each must advance the write ptr ──
    payloads = [0x111111_000001, 0x222222_000002,
                0x333333_000003, 0x444444_000004]
    for i, p in enumerate(payloads):
        wp = await app_write(dut, p)
        dut._log.info("write %d data=0x%012X -> wbin_ptr=%d", i, p, wp)
        assert wp == i + 1, f"write {i}: wbin_ptr={wp}, expected {i+1}"
        assert probe(dut)["a2l_full"] == 0, "never falsely full at depth 4/16"

    # let the write ptr cross the CDC to the link side
    await ClockCycles(dut.link_clk, 4)
    assert _sigint(dut.dut.link_empty) == 0, "link side should see data"

    # ── read the 4 words on the link side, in order ──
    got = []
    for _ in range(len(payloads)):
        data, cur = await link_read_one(dut)
        got.append(data)
        await ClockCycles(dut.link_clk, 1)
    dut._log.info("link read back: %s", [hex(g) for g in got])
    assert got == payloads, f"link read mismatch: {[hex(g) for g in got]} != {[hex(p) for p in payloads]}"

    # ── ACK of addr K must advance the synced ack to K within bounded latency ──
    K = 3
    dut.link_ack_addr.value   = K
    dut.link_ack_update.value = 1
    await RisingEdge(dut.link_clk)
    dut.link_ack_update.value = 0
    # wait bounded latency for the ack ptr to cross into app_clk
    advanced = False
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) == K:
            advanced = True
            break
    assert advanced, (
        f"ACK of addr {K} did not advance synced ack within bound "
        f"(got {_sigint(dut.dut.a2l_link_addr_app_clk)})")
    dut._log.info("ACK addr=%d propagated to synced ack OK", K)
    # app_ready must remain healthy (not falsely full) after the ack
    assert probe(dut)["app_ready"] in (0, 1)  # defined, not X
    assert _sigint(dut.dut.a2l_full) == 0

    # ── link_revert must rewind the read ptr without corrupting app_ready ──
    rdy_before = _sigint(dut.dut.app_ready)
    dut.link_revert_addr.value = 0
    dut.link_revert.value      = 1
    await RisingEdge(dut.link_clk)
    dut.link_revert.value      = 0
    await ClockCycles(dut.app_clk, 4)
    rdy_after = _sigint(dut.dut.app_ready)
    dut._log.info("revert: app_ready %d -> %d", rdy_before, rdy_after)
    assert rdy_after != -1, "app_ready went X after revert"
    # after revert the data is replayable again -> link not empty
    await ClockCycles(dut.link_clk, 3)
    assert _sigint(dut.dut.link_empty) == 0, "revert should make data replayable"
    dut._log.info("Phase-2 functional PASS")


@cocotb.test()
async def test_phase2_genuine_full_still_works(dut):
    """Regression guard for the fix: a GENUINELY full FIFO (16 un-acked words)
    must still report a2l_full=1 / app_ready=0, and an ACK must free it.
    This proves the lap-aware ACK gate did not break real backpressure."""
    await start_clocks(dut)
    await reset_with_skew(dut, 3)

    # write 16 words (the FIFO depth). The 17th must block.
    DEPTH = 16
    for i in range(DEPTH):
        wp = await app_write(dut, (i + 1) | (i << 8))
        assert wp == ((i + 1) & 0x1f), f"write {i}: wbin_ptr={wp}"
    await ClockCycles(dut.app_clk, 2)
    full = _sigint(dut.dut.a2l_full)
    rdy  = _sigint(dut.dut.app_ready)
    occ_dbg = (_sigint(dut.dut.fifo_io_wbin_ptr),
               _sigint(dut.dut.a2l_link_addr_app_clk))
    dut._log.info("after 16 writes: wptr/ack=%s a2l_full=%d app_ready=%d",
                  occ_dbg, full, rdy)
    assert full == 1 and rdy == 0, (
        f"GENUINE full not detected after 16 writes (a2l_full={full}, "
        f"app_ready={rdy}) -- the fix must preserve real backpressure.")

    # now read+ack some words on the link side -> FIFO must un-full
    for _ in range(4):
        # pop one word
        c = 0
        while _sigint(dut.dut.link_valid) != 1:
            await RisingEdge(dut.link_clk)
            c += 1
            assert c < 200
        dut.link_advance.value = 1
        await RisingEdge(dut.link_clk)
        dut.link_advance.value = 0
        await RisingEdge(dut.link_clk)
    rd_ptr = _sigint(dut.dut.link_cur_addr)
    # ack up to the current read pointer
    await link_ack(dut, rd_ptr, pulses=2)
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_full) == 0:
            break
    full2 = _sigint(dut.dut.a2l_full)
    rdy2  = _sigint(dut.dut.app_ready)
    dut._log.info("after read+ACK(%d): a2l_full=%d app_ready=%d", rd_ptr, full2, rdy2)
    assert full2 == 0 and rdy2 == 1, (
        f"ACK after a genuine full did not free the FIFO "
        f"(a2l_full={full2}, app_ready={rdy2}).")
    dut._log.info("genuine-full backpressure + ACK-release PASS")


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  ADVERSARIAL negative control — worst-case asymmetric reset release        ║
# ║  COMBINED with the real bring-up trigger (a lap-ahead pre-data ACK).       ║
# ║  MUST FAIL on pre-fix RTL, MUST PASS on the fixed RTL.                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝

@cocotb.test()
async def test_adversarial_addrsync_reset_skew(dut):
    """Adversarial negative control. Two things conspire here, exactly as on
    silicon during bring-up:

      1. The AddrSync read-side reset (r_reset = app_reset) is released MANY
         link cycles BEFORE / AFTER the write side (worst asymmetric skew), and
      2. a spurious ACK whose addr is a full lap ahead of the write ptr is
         driven on the link side before ANY app data is written (the FCSM does
         exactly this on receipt of an ACK packet during CR/CRACK bring-up).

    The combination must NEVER leave the synced ACK ptr ahead of the write ptr.
    On the PRE-FIX RTL it does (a2l_full=1 on the first write, app_ready=0); the
    fix must bound the ACK ptr so the FIFO can never falsely-full."""
    await start_clocks(dut)
    tie_idle(dut)

    # ── 1. worst-case asymmetric reset release ──
    dut.app_reset.value  = 1
    dut.link_reset.value = 1
    await ClockCycles(dut.link_clk, 4)
    # release the WRITE side (link) first, hold the app/read side much longer
    await RisingEdge(dut.link_clk)
    dut.link_reset.value = 0
    await ClockCycles(dut.link_clk, 30)
    await RisingEdge(dut.app_clk)
    dut.app_reset.value = 0
    await ClockCycles(dut.app_clk, 16)
    await ClockCycles(dut.link_clk, 3)

    # ── 2. spurious lap-ahead pre-data ACK (the real bring-up trigger) ──
    await link_ack(dut, 17, pulses=2)
    for _ in range(64):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) != 0:
            break

    st = probe(dut)
    dut._log.info("adversarial post-reset+ACK: synced_ack=%s (0b%s) wbin_ptr=%d "
                  "a2l_full=%d app_ready=%d",
                  st["synced_ack"],
                  format(st["synced_ack"] & 0x1f, "05b") if st["synced_ack"] >= 0 else "X",
                  st["wbin_ptr"], st["a2l_full"], st["app_ready"])

    # idle must be healthy (no false-full) before the write
    pre = probe(dut)
    assert pre["a2l_full"] == 0 and pre["app_ready"] == 1, (
        f"ADVERSARIAL: worst-case reset skew + lap-ahead pre-data ACK left the "
        f"FIFO falsely full at idle ({pre}); the synced ACK ptr is ahead of the "
        f"write ptr (silicon 'Bug A').")

    # the first write must be accepted (single clean beat) and must not full
    wp = await app_write(dut, 0xABCD_0000_1234)
    full = _sigint(dut.dut.a2l_full)
    rdy  = _sigint(dut.dut.app_ready)
    dut._log.info("adversarial first write: wbin_ptr=%d a2l_full=%d app_ready=%d",
                  wp, full, rdy)
    assert wp == 1 and full == 0 and rdy == 1, (
        f"ADVERSARIAL: first write rejected / false-full after reset skew + "
        f"lap-ahead ACK (wbin_ptr={wp}, a2l_full={full}, app_ready={rdy})."
    )
    dut._log.info("adversarial PASS: first write accepted, no false-full")
