"""GUARD: V2 pad clock-gate SYNC regression on an IDLE link (the coverage hole).

docs/HANDOVER_SYNC_CLOCK_GATE_2026_07_29.md §7.1.

The bug
-------
The V2 fork dropped the `| sync_insert` term that V1 has from the eight pad
clock-gate enables in src/rtl/local_overrides/WavD2DGpio_v2.v:

    V1  WavD2DGpio.v:1003     clk_en = tx_en | postcount!=0&… | training | sync_insert
    V2  WavD2DGpio_v2.v:1980  clk_en = tx_en | postcount!=0&… | training      <-- DROPPED

Effect on silicon (handover §2, measured on the pair): a die in DATA mode
(training=0) on an IDLE link (tx_en=0) inserts an idle-gated SYNC beacon — the
logical tx_sync_ins_cnt climbs — but the pad serialiser is UNCLOCKED, so
pad_clk_tx (the forwarded clock, == the peer's pad_clk_rx) stays gated off, the
beacon never reaches the wire, and the peer's SYNC-detect never rises
(die_b tx_sync_ins_cnt +13747 in 3 s while die_a sync_detected delta == 0).
`training` is the only term holding the gate open, so the link works while a die
trains and dies the instant it leaves.

Why this shipped — and why this bench must force tx_en
------------------------------------------------------
THE COVERAGE HOLE IS STRUCTURAL. In this integrated pair sim the Wlink TX link
layer continuously clocks IDLE words: io_link_tx_tx_en stays HIGH the whole time
in data mode (verified: 100/100 samples high, tx_idle also high). So the pad
clock is always alive from tx_en, postcount never drains to 0, the idle-gated
inserter never even fires, and the dropped term can NEVER matter. The silicon
operating point — a genuinely idle link with tx_en=0 between packets — is NOT
reachable by any stimulus this harness's LL model produces. That un-reachability
is exactly why v2_syncdet / v2_data / v2_sustained (and test_v2_sync_insert_en's
force_always case) PASS with AND without the fix.

This bench therefore recreates the silicon idle link directly: it FORCES the
master PHY's io_link_tx_tx_en low (the silicon "no application traffic, tx_en=0"
condition), which lets postcount drain and the idle-gated SYNC inserter fire on
its own. It then asserts the two §7.1 conditions at the PHY boundary the fix
touches: pad_clk_tx keeps toggling AND the peer's SYNC-detect count rises.

Expected result
---------------
  * On `main` (fix NOT merged): FAIL — with tx_en idle the pad clock gate has NO
    term for the beacon, so pad_clk_tx is gated off across every idle beacon word
    (0 edges) and the peer's SYNC-detect stays flat, while tx_sync_ins_cnt still
    climbs (the beacon fires logically — proving the path IS exercised).
  * With `| tx_sync_inserting_w` restored (fix/v2-sync-clock-gate @ c8d0e5f):
    PASS — the beacon clocks the serialiser, pad_clk_tx toggles, and the peer's
    SYNC-detect rises. (This also confirms handover §7.2 — the beacon's enable is
    high at the clock-gate sampling instant covering its 16 pad cycles.)

Wired as a SENTINEL (expected-fail) in the root Makefile (sim_gate_pad_clkgate_idle),
NOT in the blocking aggregate; it PROMOTES to a blocking PASS once the fix lands.

Run:
  source ./set_env.sh; export PATH=$VCS_HOME/bin:$PATH TIDELINK_PHY_V2=1
  make -C cocotb/tidelink_pad_clkgate_idle
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import PairV2TB, run_bringup_full, APB_R8_SLOT0, APB_TIDELINK_BASE

# Region 8 slot 0 (0x2100): bit[2]=SWI_SYNC_INSERT_EN, bit[3]=SWI_SYNC_FORCE_ALWAYS.
# Enable ONLY bit[2] (idle-gated insertion). force_always keeps the inserter
# firing regardless of the postcount/idle gate — precisely the path the existing
# (blind) suites already drive; it does not model the idle-link clock-gate case.
R8_SLOT0_SYNC_EN = 0x4

# SYNC_DETECTED_COUNTER — RX-side count of coherent SYNC words reassembled on the
# aligned link bus (Region 8 slot 5, SoC 0x4403_2114, bits [31:16]).
APB_SYNC_DETECTED = APB_TIDELINK_BASE + 0x114     # 0x2114
SYNC_DET_CNT      = lambda v: (v >> 16) & 0xFFFF

# TXSYNC observability (Region 9 slot 0, SoC 0x4403_2120): [15:0] tx_sync_ins_cnt
# (saturating), [16] tx_link_idle_level, [17] tx_training_level, [31:24]=0x5C.
APB_SYNC_OBS   = APB_TIDELINK_BASE + 0x120        # 0x2120
SYNC_OBS_CNT   = lambda v: v & 0xFFFF

# The idle-gated inserter fires when io_link_tx_tx_idle & postcount==0 &
# ~training. Forcing tx_en=0 drives ~tx_en=1 so postcount decrements; the drain
# from its reload value takes a few hundred link words. Poll generously.
INS_FIRE_TIMEOUT_HCLK = 60000

# Accumulation window (hclk cycles) AFTER the first beacon has fired (postcount
# already drained). Long enough that many idle SYNC_PERIODs (32 link words each)
# elapse so the peer-detect / pad-clock deltas are unambiguous.
WINDOW_HCLK = 30000
N_CHUNKS    = 100

# pad_clk_tx is the forwarded (== peer RX capture) clock. Once tx_en is idle and
# postcount has drained, the gate has NO term but the (missing) beacon term, so a
# buggy die yields ~0 edges (RisingEdge never fires); a fixed die pulses ~16 pad
# edges per beacon. Cap keeps "alive" bounded/cheap.
PAD_EDGE_CAP   = 4096
PAD_EDGE_ALIVE = 128     # >> a gated clock (0); << a live clock over the window


def _gpio(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.phy.gpio


def _rd_int(sig):
    try:
        return int(sig.value)
    except (AttributeError, ValueError):
        return -1


@cocotb.test()
async def test_pad_clk_alive_and_peer_syncdet_on_idle_link(dut):
    log = dut._log
    tb = PairV2TB(dut)

    # POR -> role_lock -> passive autocal -> data mode (training released).
    await run_bringup_full(tb)
    gpio_m = _gpio(tb, "m")
    await ClockCycles(dut.hclk, 200)

    # Confirm we are in data mode (training low). effective_training_mode is the
    # ONLY other term that would hold the gate open, so it must be 0 for the test
    # to mean anything.
    etm = _rd_int(gpio_m.effective_training_mode)
    log.info(f"data-mode check: effective_training_mode={etm} "
             f"tx_en(nat)={_rd_int(gpio_m.io_link_tx_tx_en)} "
             f"tx_idle={_rd_int(gpio_m.io_link_tx_tx_idle)}")
    assert etm == 0, (
        f"effective_training_mode={etm} — not in data mode; the training term "
        f"would hold the clock gate open and mask the dropped sync term.")

    # ---- opt in: idle-gated SYNC insertion on the master (NOT force_always) ----
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN)
    rb = await tb.m_apb.read(APB_R8_SLOT0)
    assert (rb >> 2) & 1 == 1 and (rb >> 3) & 1 == 0, \
        f"R8_SLOT0 readback 0x{rb:x}: want SYNC_EN=1, FORCE_ALWAYS=0 (idle-gated)"

    # ---- recreate the SILICON idle link: force the master PHY tx_en low --------
    # See the module docstring: this harness's LL never idles (tx_en pinned high),
    # so the silicon "tx_en=0 between packets" operating point is unreachable
    # otherwise. Forcing tx_en=0 lets postcount drain to 0, at which point the
    # idle-gated inserter fires periodically on its own.
    gpio_m.io_link_tx_tx_en.value = Force(0)
    log.info("FORCED master io_link_tx_tx_en = 0 (emulating the silicon idle link)")

    det_before = SYNC_DET_CNT(await tb.s_apb.read(APB_SYNC_DETECTED))
    ins_before = SYNC_OBS_CNT(await tb.m_apb.read(APB_SYNC_OBS))
    log.info(f"baseline @force: slave RX sync_detected={det_before}  "
             f"master tx_sync_ins_cnt={ins_before}")

    # ---- wait until the idle-gated inserter has actually fired ------------------
    # tx_sync_ins_cnt counts tx_sync_inserting_w pulses, which are the LOGICAL
    # inserts (upstream of the clock gate) — so this climbs on buggy AND fixed
    # RTL. If it never climbs, the inserter path is not being exercised (an
    # instrument failure, not the clock-gate bug).
    ins_now = ins_before
    waited = 0
    while ins_now <= ins_before and waited < INS_FIRE_TIMEOUT_HCLK:
        await ClockCycles(dut.hclk, 500)
        waited += 500
        ins_now = SYNC_OBS_CNT(await tb.m_apb.read(APB_SYNC_OBS))
    log.info(f"idle-gated inserter fired after ~{waited} hclk: "
             f"tx_sync_ins_cnt {ins_before} -> {ins_now}")
    assert ins_now > ins_before, (
        f"idle-gated SYNC inserter never fired within {INS_FIRE_TIMEOUT_HCLK} hclk "
        f"(tx_sync_ins_cnt stuck at {ins_before}) — postcount did not drain / the "
        f"beacon path is not exercised. This is an instrument failure, not the "
        f"clock-gate bug under test.")

    # ---- background pad-clock edge counter on the master forwarded clock -------
    # Started AFTER the first beacon (postcount already 0), so on buggy RTL the
    # gate is fully closed and there are no residual drain edges to count.
    holder = {"n": 0}

    async def _count_edges(sig, h, cap):
        while h["n"] < cap:
            await RisingEdge(sig)
            h["n"] += 1

    edge_task = cocotb.start_soon(_count_edges(dut.m_pad_clk_tx, holder, PAD_EDGE_CAP))

    ins_win0 = ins_now
    await ClockCycles(dut.hclk, WINDOW_HCLK)

    if not edge_task.done():
        edge_task.cancel()
    pad_edges = holder["n"]

    # ---- results ---------------------------------------------------------------
    det_after = SYNC_DET_CNT(await tb.s_apb.read(APB_SYNC_DETECTED))
    ins_after = SYNC_OBS_CNT(await tb.m_apb.read(APB_SYNC_OBS))
    det_delta = det_after - det_before
    ins_delta = ins_after - ins_win0

    log.info("=================== IDLE-LINK CLOCK-GATE RESULTS ===================")
    log.info(f"  window                  : {WINDOW_HCLK} hclk after first beacon")
    log.info(f"  master tx_sync_ins_cnt  : +{ins_delta} in-window "
             f"({ins_before}->{ins_after} total)  [LOGICAL inserts; climbs buggy+fixed]")
    log.info(f"  master pad_clk_tx edges : {pad_edges}  (cap {PAD_EDGE_CAP}, "
             f"alive-threshold {PAD_EDGE_ALIVE})")
    log.info(f"  slave RX sync_detected  : {det_before} -> {det_after} "
             f"(delta {det_delta})  [THE silicon discriminator]")
    log.info("====================================================================")

    # --- setup sanity: the beacon path is live in-window ------------------------
    assert ins_delta > 0, (
        f"tx_sync_ins_cnt did not advance during the window (+{ins_delta}) — the "
        f"idle-gated inserter stopped firing; instrument failure, not the bug.")

    # --- §7.1 condition 1: the forwarded clock STAYS ALIVE ----------------------
    # Buggy RTL: pad_clk_tx gated off across the idle beacon words -> ~0 edges.
    # Fixed RTL: the beacon clocks the serialiser -> the counter climbs.
    assert pad_edges >= PAD_EDGE_ALIVE, (
        f"pad_clk_tx produced only {pad_edges} edges over {WINDOW_HCLK} idle hclk "
        f"(< {PAD_EDGE_ALIVE}) while the master logically inserted {ins_delta} SYNC "
        f"beacons — the forwarded clock is GATED OFF during the idle beacon words. "
        f"This is the dropped `| tx_sync_inserting_w` term (WavD2DGpio_v2.v "
        f"gpiotx_N_io_clk_en).")

    # --- §7.1 condition 2: the PEER's SYNC-detect RISES -------------------------
    assert det_delta > 0, (
        f"peer (slave) RX sync_detected did NOT rise (delta={det_delta}) while the "
        f"master logically inserted {ins_delta} idle-gated SYNC beacons — the beacon "
        f"never reached the wire because pad_clk_tx was gated off. This is the "
        f"measured silicon signature (handover §2: die_a sync_detected delta == 0).")

    gpio_m.io_link_tx_tx_en.value = Release()
    log.info("VERDICT: PASS — on an idle link (tx_en=0) the master's idle-gated SYNC "
             "beacon keeps pad_clk_tx alive AND the peer's SYNC-detect rises "
             "(the dropped `| tx_sync_inserting_w` term is present).")
