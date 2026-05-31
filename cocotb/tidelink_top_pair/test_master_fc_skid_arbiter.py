"""Bug A — H-A2 / H-A3 localisation: pin down whether master TX is blocked
by the skid buffer (Wlink not draining) or by the TX arbiter starving
FIFO_DATA in favour of sideband / external traffic.

H-A2 (skid backpressure permanent)
    ``skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready``
    (tidelink_fc_adapter.sv:380). If this is 0 forever, the Wlink FIFO never
    drains the skid so no new arbiter word can be loaded.

H-A3 (arbiter starves FIFO_DATA)
    ``sideband_grant = (rtn|servo|ext_grant) & ~sideband_starving``
    (tidelink_fc_adapter.sv:368). FIFO_DATA only wins when sideband_grant=0.
    The fairness gate is ``sideband_starving`` which trips after
    MAX_SIDEBAND_BURST (=4) consecutive sideband grants. If the burst hits
    4 and starving never fires, FIFO_DATA can be starved indefinitely.

NOTE — DO NOT edit any other test file in this directory. This file is a
pure probe module: imports PairTB and run_bringup_full from the doorbell
test, never writes RTL, never touches the IP library.
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the full bringup machinery from the doorbell test.
from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
    APB_DOORBELL,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ----------------------------------------------------------------------------
# Hierarchical helpers — master fc_adapter probe access
# ----------------------------------------------------------------------------

def _fc(dut):
    """Direct handle to master's tidelink_fc_adapter (no generate-block)."""
    return dut.u_master.u_fc_adapter


def _id_get(parent, name):
    """Resolve a hierarchical name that may live inside a generate-block.

    cocotb's _id() with extended=False is the only form that accepts a
    flattened dotted name on VCS — see test_master_ptp_tx_router.py for
    the same pattern.
    """
    # 1. Direct attribute (cocotb-cleanest form).
    try:
        return getattr(parent, name)
    except AttributeError:
        pass
    # 2. Flattened name via _id().
    try:
        return parent._id(name, extended=False)
    except Exception:
        return None


def _safe_read(sig):
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


# ----------------------------------------------------------------------------
# Common: drive a 4-word PKT_WR_REQ packet from master, return for analysis
# ----------------------------------------------------------------------------

PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


async def _settle_post_bringup(tb):
    """Drop SWI training after the LL bootstrap to mirror HW data-mode."""
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


# ============================================================================
# T1 — skid_can_accept high at idle (NO traffic, no AHB writes)
# ============================================================================

@cocotb.test()
async def test_skid_can_accept_initially_high(dut):
    """At idle post-bringup, master ``skid_can_accept`` must be high every cy.

    skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready  (fc_adapter.sv:380)
    With no AHB / servo / returner traffic, skid_valid_r should be 0, so
    skid_can_accept is forced to 1 (independent of Wlink).

    Verdict for H-A2:
        100/100 high → skid backpressure is NOT permanent.
        0/100  high → skid is permanently blocked (H-A2 confirmed).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sig_can = fc.skid_can_accept
    sig_valid = fc.skid_valid_r
    sig_a2lr = fc.tl_fc_a2l_ready

    high = 0
    valid_high = 0
    a2lr_high = 0
    total = 100
    for _ in range(total):
        await RisingEdge(dut.hclk)
        if _safe_read(sig_can)   == 1: high += 1
        if _safe_read(sig_valid) == 1: valid_high += 1
        if _safe_read(sig_a2lr)  == 1: a2lr_high += 1

    dut._log.info(
        f"  T1 idle: skid_can_accept high={high}/{total}  "
        f"skid_valid_r high={valid_high}/{total}  "
        f"tl_fc_a2l_ready high={a2lr_high}/{total}"
    )
    assert high == total, (
        f"skid_can_accept low at idle ({high}/{total}). "
        f"skid_valid_r high cycles={valid_high}, tl_fc_a2l_ready high={a2lr_high}. "
        "H-A2 confirmed: skid backpressure is permanent."
    )


# ============================================================================
# T2 — tl_fc_a2l_ready high post-bringup (Wlink not blocking)
# ============================================================================

@cocotb.test()
async def test_tl_fc_a2l_ready_high(dut):
    """Probe master's ``tl_fc_a2l_ready`` for 100 cy after bringup.

    This is the Wlink FC-side ready signal into the fc_adapter. If 0, Wlink
    is permanently refusing to drain the adapter — implies FCSM is not in
    data-mode (or full FIFO).

    Verdict:
        Mostly 1 → Wlink is offering room. Skid can drain. H-A2 falsified.
        Mostly 0 → Wlink is the blocker (FCSM stuck not-data-mode, etc.).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sig = fc.tl_fc_a2l_ready
    high = 0
    total = 100
    for _ in range(total):
        await RisingEdge(dut.hclk)
        if _safe_read(sig) == 1:
            high += 1

    dut._log.info(
        f"  T2 idle: tl_fc_a2l_ready high {high}/{total} "
        f"({100.0 * high / total:.1f}%)"
    )
    assert high > 0, (
        "tl_fc_a2l_ready stuck low — Wlink not draining. "
        "Most likely FCSM not in data-mode. H-A2 indirectly confirmed."
    )


# ============================================================================
# T3 — skid_valid_r stays low under quiet (no leaks)
# ============================================================================

@cocotb.test()
async def test_skid_drains_under_quiet(dut):
    """Log ``skid_valid_r`` over 500 cy with no AHB / returner / servo traffic.

    Expected: skid_valid_r mostly 0 (no producers). If it stays HIGH the
    skid is loaded with a word that Wlink refuses to accept — that IS the
    H-A2 confirmation.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sig = fc.skid_valid_r
    a2lv = fc.tl_fc_a2l_valid
    a2lr = fc.tl_fc_a2l_ready

    skid_high = 0
    valid_high = 0
    ready_high = 0
    total = 500
    for _ in range(total):
        await RisingEdge(dut.hclk)
        if _safe_read(sig)  == 1: skid_high  += 1
        if _safe_read(a2lv) == 1: valid_high += 1
        if _safe_read(a2lr) == 1: ready_high += 1

    dut._log.info(
        f"  T3 quiet 500cy: skid_valid_r={skid_high}, "
        f"tl_fc_a2l_valid={valid_high}, tl_fc_a2l_ready={ready_high}"
    )
    # Hard assertion: under quiet skid should mostly be empty. A few cy of
    # residual sideband (cr/crack tail-end credit returns) is acceptable;
    # full 500 cy stuck high is the failure mode.
    assert skid_high < total, (
        f"skid_valid_r stuck high for the full {total} cy at idle — "
        f"loaded word never drains. tl_fc_a2l_ready high={ready_high}. "
        "H-A2 confirmed."
    )


# ============================================================================
# T4 — arbiter grants FIFO_DATA at least once for an AHB packet
# ============================================================================

@cocotb.test()
async def test_arbiter_grants_fifo_data(dut):
    """Drive an AHB-write packet on master and watch the arbiter pick
    FIFO_DATA for at least one cycle.

    There is no named ``arb_grant`` — the arbiter is expressed as:
        sideband_grant = (rtn|servo|ext_grant) & ~sideband_starving (line 368)
        FIFO_DATA grant = arb_valid & skid_can_accept & ~sideband_grant

    Verdict for H-A3:
        FIFO_DATA grants > 0 → arbiter does pick TX aperture; H-A3 falsified
                               (or only rarely fires).
        FIFO_DATA grants = 0 → arbiter always picks sideband — H-A3 candidate.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    arb_valid_s     = fc.arb_valid
    skid_can_s      = fc.skid_can_accept
    sideband_grant_s = fc.sideband_grant
    sb_burst_s      = fc.sideband_burst_r
    sb_starv_s      = fc.sideband_starving
    tx_fc_valid_s   = fc.tx_fc_valid

    counts = dict(
        arb_v=0,
        sb_g=0,
        fd_g=0,
        sb_starv=0,
        tx_fc_v=0,
        sb_burst_max=0,
    )

    async def watcher():
        while True:
            await RisingEdge(dut.hclk)
            av = _safe_read(arb_valid_s)
            ca = _safe_read(skid_can_s)
            sg = _safe_read(sideband_grant_s)
            sb = _safe_read(sb_burst_s)
            ss = _safe_read(sb_starv_s)
            tv = _safe_read(tx_fc_valid_s)
            if av == 1: counts["arb_v"] += 1
            if sg == 1: counts["sb_g"]  += 1
            if av == 1 and ca == 1 and sg == 0:
                counts["fd_g"] += 1
            if ss == 1: counts["sb_starv"] += 1
            if tv == 1: counts["tx_fc_v"] += 1
            if sb > counts["sb_burst_max"]:
                counts["sb_burst_max"] = sb

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 200)

    dut._log.info(
        f"  T4 arbiter probes (post-AHB write, 4-word packet): "
        f"arb_valid={counts['arb_v']} cy, sideband_grant={counts['sb_g']} cy, "
        f"FIFO_DATA_grant={counts['fd_g']} cy, sideband_starving={counts['sb_starv']} cy, "
        f"tx_fc_valid={counts['tx_fc_v']} cy, sideband_burst peak={counts['sb_burst_max']}"
    )

    assert counts["fd_g"] > 0, (
        f"arbiter never granted FIFO_DATA — "
        f"arb_valid high {counts['arb_v']} cy, sideband_grant {counts['sb_g']} cy. "
        f"sideband_burst peak={counts['sb_burst_max']}, starving={counts['sb_starv']} cy. "
        "H-A3 confirmed if arb_valid was high but FIFO_DATA never won."
    )


# ============================================================================
# T5 — sideband_starving engages after MAX_SIDEBAND_BURST consecutive grants
# ============================================================================

@cocotb.test()
async def test_sideband_starvation_engages(dut):
    """Trigger a lot of sideband traffic (doorbell ring + AHB packet).
    Watch ``sideband_burst_r`` ramp and ``sideband_starving`` engage.

    Per fc_adapter.sv:264 + 342, after 4 sideband grants with tx_fc_valid
    pending, ``sideband_starving`` must trip and let FIFO_DATA win.

    Verdict for H-A3:
        sideband_burst_r hits 4 AND sideband_starving asserts → gate works.
        sideband_burst_r hits 4 AND starving never fires → gate broken
                                                            (H-A3 confirmed).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    sb_burst_s = fc.sideband_burst_r
    sb_starv_s = fc.sideband_starving
    rtn_v_s    = fc.rtn_fc_valid
    tx_v_s     = fc.tx_fc_valid

    counts = dict(burst_peak=0, starv_high=0, rtn_high=0, tx_v_high=0)

    async def watcher():
        while True:
            await RisingEdge(dut.hclk)
            bp = _safe_read(sb_burst_s)
            st = _safe_read(sb_starv_s)
            rv = _safe_read(rtn_v_s)
            tv = _safe_read(tx_v_s)
            if bp > counts["burst_peak"]: counts["burst_peak"] = bp
            if st == 1: counts["starv_high"] += 1
            if rv == 1: counts["rtn_high"]   += 1
            if tv == 1: counts["tx_v_high"]  += 1

    cocotb.start_soon(watcher())

    # Step 1 — fire a doorbell to spin sideband traffic (returner)
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(dut.hclk, 100)
    # Step 2 — also queue an AHB packet so tx_fc_valid co-asserts with sideband
    # (sideband_starving is gated on tx_fc_valid per line 264-265).
    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 500)

    dut._log.info(
        f"  T5 starvation gate: sideband_burst peak={counts['burst_peak']} "
        f"(MAX=4), sideband_starving high={counts['starv_high']} cy, "
        f"rtn_fc_valid={counts['rtn_high']} cy, tx_fc_valid={counts['tx_v_high']} cy"
    )

    # If the burst never reached 4, we never exercised the starvation gate.
    if counts["burst_peak"] < 4:
        dut._log.info(
            "  T5 NOTE — sideband_burst never reached 4; gate untested. "
            "This is inconclusive for H-A3 but consistent with sideband "
            "traffic being light at idle."
        )
        # Soft pass: report and exit.
        return

    assert counts["starv_high"] > 0, (
        f"sideband_burst hit {counts['burst_peak']} but sideband_starving "
        "never asserted — starvation gate is BROKEN. H-A3 CONFIRMED. "
        "Inspect fc_adapter.sv:264 and the SB_CNT_W comparison."
    )


# ============================================================================
# T6 — tx_fc_valid follows tx_data_phase_r (no extra gating)
# ============================================================================

@cocotb.test()
async def test_tx_fc_valid_asserts_with_data_phase(dut):
    """tx_fc_valid is declared as ``= tx_data_phase_r`` at fc_adapter.sv:198.
    So when tx_data_phase_r=1, tx_fc_valid MUST be 1 in the same cycle
    (continuous assign). Probe both over 500 cy after an AHB write.

    Verdict:
        ever_both_high == 1 → data-phase → fc_valid gate is intact.
        ever_dp == 1 but ever_both_high == 0 → fc_valid gate broken (RTL bug).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut)
    dp_s = fc.tx_data_phase_r
    fv_s = fc.tx_fc_valid

    ever_dp = 0
    ever_fv = 0
    same_cy = 0
    dp_only = 0  # dp=1 but fv=0 — would indicate broken gate

    async def watcher():
        nonlocal ever_dp, ever_fv, same_cy, dp_only
        while True:
            await RisingEdge(dut.hclk)
            dp = _safe_read(dp_s)
            fv = _safe_read(fv_s)
            if dp == 1: ever_dp = 1
            if fv == 1: ever_fv = 1
            if dp == 1 and fv == 1: same_cy += 1
            if dp == 1 and fv == 0: dp_only += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 500)

    dut._log.info(
        f"  T6 tx_data_phase_r vs tx_fc_valid: ever_dp={ever_dp} ever_fv={ever_fv} "
        f"same_cy={same_cy} dp_only(dp=1,fv=0)={dp_only}"
    )

    assert ever_dp == 1, (
        "tx_data_phase_r never asserted — AHB→FC address-phase handshake "
        "did not latch. Re-run test_master_fc_tx_block T1+T2 first."
    )
    assert dp_only == 0, (
        f"tx_data_phase_r asserted {same_cy + dp_only} cy but tx_fc_valid "
        f"missed {dp_only} of those. fc_adapter.sv:198 should make them "
        "identical (continuous assign). RTL gate broken."
    )
    assert same_cy > 0, (
        "tx_fc_valid never coincided with tx_data_phase_r — RTL alias bug."
    )
