"""Bug A interventional force/release experiments — localise the master
TX-path block to ONE of:
  * H-A1  : tx_data_phase_r never latches (AHB→FC adapter handoff)
  * H-A2  : skid_can_accept stuck low (skid backpressure permanent)
  * arbiter starves FIFO_DATA (sideband_grant always wins)
  * Wlink / PHY downstream (fc_adapter offers data but never traverses link)
  * ambiguous / multi-stage (combined #1+#2 still fails)

Observed before this file:
  * master tl_fc_a2l_valid stays 0 for 500 cy after AHB write to AHB_TX.
  * NOT the credit gate (fe_rx_credit_max=0x1f on both dies).
  * NOT slave-RX misdecode (unit test 10/10 PASS).
So the block is on the master TX path before Wlink. The five tests below
inject overrides at well-defined points to discriminate between the
remaining candidates.

Hierarchical-ref pattern: master fc_adapter is at
``dut.u_master.u_fc_adapter`` (no generate-block — see
test_master_fc_skid_arbiter.py for prior art). The pair-level FC wires
``tl_fc_a2l_valid`` / ``tl_fc_a2l_data`` / ``tl_fc_l2a_valid`` /
``tl_fc_l2a_data`` live as named wires inside ``dut.u_master`` and
``dut.u_slave`` (tidelink_top.sv:495-500).

VCS Force/Release: see test_lane_swap_detection.py and
test_bit_order_canary_fail.py — both already prove that VCS hierarchical
force works on wires inside u_master / u_slave.

DO NOT touch RTL. DO NOT touch other tests. DO NOT touch
/research/AAA/ip_library/**.
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge, Timer, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ---------------------------------------------------------------------------
# Hierarchical helpers
# ---------------------------------------------------------------------------

def _fc(dut, side):
    """Handle to ``side``'s tidelink_fc_adapter."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_fc_adapter


def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _safe_read(sig):
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


async def _settle_post_bringup(tb):
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


def _try_force(sig, val, log, label):
    """Attempt VCS Force; log + return False on failure (handle missing)."""
    try:
        sig.value = Force(val)
        log.info(f"  FORCE {label} <= 0x{val:x}")
        return True
    except (AttributeError, ValueError) as e:
        log.warning(f"  FORCE {label} FAILED ({e}) — VCS hierarchical force unsupported")
        return False


def _try_release(sig, log, label):
    try:
        sig.value = Release()
        log.info(f"  RELEASE {label}")
        return True
    except (AttributeError, ValueError) as e:
        log.warning(f"  RELEASE {label} FAILED ({e})")
        return False


PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


# Bounded-time test guard: cocotb.test(timeout_time=...) lets each test
# abort cleanly rather than wedging the harness. NB: run_bringup_full takes
# ~10 ms of sim time on its own (the passive autocal sweep can run up to
# 500k hclk cycles = 10 ms at 50 MHz). Cap each test at 25 ms sim — generous
# headroom for bringup + probe windows + the few-thousand-cy AHB packet
# traversal. Per-test WALL-CLOCK bound is enforced externally by `timeout
# 600` on the make invocation.
TEST_TIMEOUT_NS = 25_000_000


# ===========================================================================
# Test 1 — Force master tx_data_phase_r = 1 for 100 cy
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_force_tx_data_phase_r_high(dut):
    """**H-A1 probe.** Post-bringup, override master ``tx_data_phase_r``
    to 1 for 100 cy. Observe whether ``skid_valid_r`` and
    ``tl_fc_a2l_valid`` rise.

    Verdict:
      * Both rise → H-A1 confirmed (the natural address-phase handshake
        is what fails; once tx_data_phase_r is asserted by force the
        downstream skid + arbiter + Wlink path works).
      * Neither rises → block is downstream of tx_data_phase_r — most
        likely arbiter / skid / Wlink. H-A1 NOT the only fault.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut, "m")
    sig_dp   = fc.tx_data_phase_r
    sig_skid = fc.skid_valid_r
    sig_a2lv = fc.tl_fc_a2l_valid
    sig_arb  = fc.arb_valid

    # Sanity baseline (no force): all should be 0 at idle.
    baseline_skid = _safe_read(sig_skid)
    baseline_a2lv = _safe_read(sig_a2lv)
    tb.log.info(
        f"  baseline (no force) skid_valid_r={baseline_skid} "
        f"tl_fc_a2l_valid={baseline_a2lv}"
    )

    forced = _try_force(sig_dp, 1, tb.log, "M.tx_data_phase_r")
    if not forced:
        # Degrade gracefully — test_lane_swap pattern.
        tb.log.warning("test_force_tx_data_phase_r_high: skipped (no force support)")
        return

    skid_hi = a2lv_hi = arb_hi = 0
    for _ in range(100):
        await RisingEdge(dut.hclk)
        if _safe_read(sig_skid) == 1: skid_hi += 1
        if _safe_read(sig_a2lv) == 1: a2lv_hi += 1
        if _safe_read(sig_arb)  == 1: arb_hi  += 1

    _try_release(sig_dp, tb.log, "M.tx_data_phase_r")
    await ClockCycles(dut.hclk, 50)

    tb.log.info(
        f"  T1 force tx_data_phase_r=1 for 100 cy: "
        f"skid_valid_r high={skid_hi}/100, tl_fc_a2l_valid high={a2lv_hi}/100, "
        f"arb_valid high={arb_hi}/100"
    )

    # Diagnostic verdict — soft assertions favour reporting over fail.
    if skid_hi > 0 and a2lv_hi > 0:
        tb.log.info("  T1 VERDICT: H-A1 confirmed — block was tx_data_phase_r latch")
    elif arb_hi > 0 and skid_hi == 0:
        tb.log.info("  T1 VERDICT: arbiter denies grant even with TX want — H-A3 candidate")
    elif skid_hi == 0 and a2lv_hi == 0:
        tb.log.info("  T1 VERDICT: downstream block — arbiter / skid / Wlink, not H-A1")
    else:
        tb.log.info("  T1 VERDICT: partial flow — mixed/ambiguous")

    # The test only fails if the force handle never resolved (already
    # returned above). We INTENTIONALLY don't fail on a particular
    # downstream pattern — this is an interventional diagnostic, not a
    # pass/fail gate. The log line above is the deliverable.
    assert True


# ===========================================================================
# Test 2 — Force master skid_can_accept = 1, then drive AHB write
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_force_skid_can_accept_high(dut):
    """**H-A2 probe.** Force master ``skid_can_accept`` = 1 for the full
    probe window, then write a 4-word AHB packet. Observe
    ``skid_valid_r`` and ``tl_fc_a2l_valid``.

    Verdict:
      * Both flow (skid_valid_r > 0 AND tl_fc_a2l_valid > 0) → skid
        backpressure WAS the block; H-A2 confirmed.
      * Still 0 → arbiter never picks FIFO_DATA (sideband grant always
        wins, or arb_valid never asserts).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut, "m")
    sig_can  = fc.skid_can_accept
    sig_skid = fc.skid_valid_r
    sig_a2lv = fc.tl_fc_a2l_valid
    sig_arb  = fc.arb_valid
    sig_sbg  = fc.sideband_grant

    forced = _try_force(sig_can, 1, tb.log, "M.skid_can_accept")
    if not forced:
        tb.log.warning("test_force_skid_can_accept_high: skipped (no force support)")
        return

    counts = dict(skid=0, a2lv=0, arb=0, sbg=0)

    async def watcher():
        while True:
            await RisingEdge(dut.hclk)
            if _safe_read(sig_skid) == 1: counts["skid"] += 1
            if _safe_read(sig_a2lv) == 1: counts["a2lv"] += 1
            if _safe_read(sig_arb)  == 1: counts["arb"]  += 1
            if _safe_read(sig_sbg)  == 1: counts["sbg"]  += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 500)

    _try_release(sig_can, tb.log, "M.skid_can_accept")
    await ClockCycles(dut.hclk, 50)

    tb.log.info(
        f"  T2 force skid_can_accept=1 + AHB pkt: "
        f"skid_valid_r={counts['skid']} cy, tl_fc_a2l_valid={counts['a2lv']} cy, "
        f"arb_valid={counts['arb']} cy, sideband_grant={counts['sbg']} cy"
    )

    if counts["skid"] > 0 and counts["a2lv"] > 0:
        tb.log.info("  T2 VERDICT: H-A2 confirmed — backpressure was block")
    elif counts["arb"] > 0 and counts["skid"] == 0:
        tb.log.info(
            "  T2 VERDICT: arbiter wants but skid never loads — "
            "arb path / sideband_grant always wins"
        )
    elif counts["arb"] == 0:
        tb.log.info(
            "  T2 VERDICT: arb_valid stayed 0 — TX request never asserted "
            "(tx_data_phase_r upstream of arbiter), points at H-A1"
        )
    else:
        tb.log.info("  T2 VERDICT: ambiguous")

    assert True


# ===========================================================================
# Test 3 — Direct injection of tl_fc_a2l_valid / data — bypass fc_adapter
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_force_direct_a2l_injection(dut):
    """**Wlink/PHY downstream probe.** Bypass the master fc_adapter
    entirely — directly force ``tl_fc_a2l_valid=1`` + ``tl_fc_a2l_data``
    at the master's tidelink_top boundary. Observe the slave's
    ``tl_fc_l2a_valid`` over a generous window.

    Verdict:
      * Slave fc_l2a_valid pulses → Wlink / PHY is OK; the bug is in the
        master fc_adapter (returner / arbiter / skid).
      * Slave fc_l2a_valid silent → Wlink / PHY is the downstream block,
        regardless of fc_adapter behaviour.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_top = _top(dut, "m")
    s_top = _top(dut, "s")
    m_a2lv = m_top.tl_fc_a2l_valid
    m_a2ld = m_top.tl_fc_a2l_data
    s_l2av = s_top.tl_fc_l2a_valid
    s_l2ad = s_top.tl_fc_l2a_data

    # Spec inject value: 48'h0024_DEAD_BEEF
    INJECT = 0x0024_DEAD_BEEF

    # Sample before, snapshot baseline.
    base_s_l2av = _safe_read(s_l2av)
    base_s_l2ad = _safe_read(s_l2ad)
    tb.log.info(
        f"  baseline slave tl_fc_l2a_valid={base_s_l2av} "
        f"tl_fc_l2a_data=0x{base_s_l2ad:012x}"
    )

    # Force VALID and DATA on master a2l for ONE cycle, then release.
    forced_v = _try_force(m_a2lv, 1, tb.log, "M.tl_fc_a2l_valid")
    forced_d = _try_force(m_a2ld, INJECT, tb.log, "M.tl_fc_a2l_data")
    if not (forced_v and forced_d):
        # Release whichever did force, then skip.
        if forced_v: _try_release(m_a2lv, tb.log, "M.tl_fc_a2l_valid")
        if forced_d: _try_release(m_a2ld, tb.log, "M.tl_fc_a2l_data")
        tb.log.warning("test_force_direct_a2l_injection: skipped (no force support)")
        return

    await RisingEdge(dut.hclk)
    # Release immediately — single-cycle inject.
    _try_release(m_a2lv, tb.log, "M.tl_fc_a2l_valid")
    _try_release(m_a2ld, tb.log, "M.tl_fc_a2l_data")

    # Watch slave for a long window — Wlink has internal pipeline +
    # the GPIO/serdes has latency on the order of dozens of cy.
    s_l2av_hits = 0
    s_l2ad_capture = []
    for _ in range(2000):
        await RisingEdge(dut.hclk)
        if _safe_read(s_l2av) == 1:
            s_l2av_hits += 1
            d = _safe_read(s_l2ad)
            if d != -1:
                s_l2ad_capture.append(d)

    tb.log.info(
        f"  T3 single-cy inject 0x{INJECT:012x} on master a2l: "
        f"slave tl_fc_l2a_valid pulses in 2000 cy = {s_l2av_hits}"
    )
    if s_l2ad_capture:
        # Dedup display
        uniq = list(dict.fromkeys(s_l2ad_capture))[:8]
        tb.log.info(
            f"  T3 first slave l2a_data captures (up to 8): "
            f"{[f'0x{d:012x}' for d in uniq]}"
        )

    if s_l2av_hits > 0:
        tb.log.info(
            "  T3 VERDICT: Wlink/PHY OK — bug is upstream in master fc_adapter"
        )
    else:
        tb.log.info(
            "  T3 VERDICT: Wlink/PHY downstream block — slave never saw the "
            "forced packet"
        )

    assert True


# ===========================================================================
# Test 4 — Release hygiene: after each force, no wedge
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_force_release_hygiene(dut):
    """**Hygiene check.** Apply each force in sequence, release it,
    and confirm the link doesn't wedge in the 1000 cy that follow.
    Read APB doorbell-resp-acc registers as a coarse liveness probe.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut, "m")
    m_top = _top(dut, "m")

    # APB liveness — both sides must remain responsive to APB across the
    # whole sequence (read shouldn't time out).
    async def _liveness(label):
        try:
            v = await tb.m_apb.read(0x2024)  # APB_DOORBELL_RESP_ACC
            tb.log.info(f"  liveness [{label}]: M doorbell_resp_acc = {v}")
        except TimeoutError as e:
            tb.log.error(f"  liveness [{label}] FAILED: {e}")
            raise

    targets = [
        (fc.tx_data_phase_r,   1, "tx_data_phase_r"),
        (fc.skid_can_accept,   1, "skid_can_accept"),
        (m_top.tl_fc_a2l_valid, 1, "tl_fc_a2l_valid"),
    ]

    for sig, val, label in targets:
        if not _try_force(sig, val, tb.log, label):
            tb.log.warning(f"  hygiene: force on {label} skipped")
            continue
        await ClockCycles(dut.hclk, 50)
        _try_release(sig, tb.log, label)
        await ClockCycles(dut.hclk, 1000)
        await _liveness(f"post-release {label}")

    tb.log.info("  T4 release hygiene completed — no wedge observed")
    assert True


# ===========================================================================
# Test 5 — Combined: force tx_data_phase_r=1 AND skid_can_accept=1
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_force_combined_bypass(dut):
    """**Combined bypass probe.** Apply both #1 (tx_data_phase_r=1) and
    #2 (skid_can_accept=1) at the same time. Drive an AHB write. Does
    the packet now reach the slave?

    Verdict:
      * Slave receives the packet (s.tl_fc_l2a_valid pulses OR
        APB_PKT_WORD_LEN > 0) → block was purely on the AHB-side handoff;
        bypassing both handshakes fixes the flow.
      * No reception → multi-stage block. The bug is partly downstream of
        the arbiter / Wlink — at least one extra layer of state is wrong.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    fc = _fc(dut, "m")
    sig_dp  = fc.tx_data_phase_r
    sig_can = fc.skid_can_accept

    s_top = _top(dut, "s")
    s_l2av = s_top.tl_fc_l2a_valid

    forced_dp  = _try_force(sig_dp,  1, tb.log, "M.tx_data_phase_r")
    forced_can = _try_force(sig_can, 1, tb.log, "M.skid_can_accept")

    if not (forced_dp and forced_can):
        if forced_dp:  _try_release(sig_dp,  tb.log, "M.tx_data_phase_r")
        if forced_can: _try_release(sig_can, tb.log, "M.skid_can_accept")
        tb.log.warning("test_force_combined_bypass: skipped (no force support)")
        return

    counts = dict(s_l2av=0, m_a2lv=0)
    sig_a2lv = fc.tl_fc_a2l_valid

    async def watcher():
        while True:
            await RisingEdge(dut.hclk)
            if _safe_read(s_l2av)   == 1: counts["s_l2av"] += 1
            if _safe_read(sig_a2lv) == 1: counts["m_a2lv"] += 1

    cocotb.start_soon(watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, 2000)

    _try_release(sig_dp,  tb.log, "M.tx_data_phase_r")
    _try_release(sig_can, tb.log, "M.skid_can_accept")
    await ClockCycles(dut.hclk, 100)

    # Read slave's REG_PKT_WORD_LEN — non-zero indicates the packet was
    # demuxed into the RX FIFO.
    try:
        s_pkt_len = await tb.s_apb.read(0x2008)   # APB_PKT_WORD_LEN
    except TimeoutError:
        s_pkt_len = -1

    tb.log.info(
        f"  T5 combined force + AHB pkt: "
        f"master tl_fc_a2l_valid={counts['m_a2lv']} cy, "
        f"slave tl_fc_l2a_valid={counts['s_l2av']} cy, "
        f"slave REG_PKT_WORD_LEN=0x{s_pkt_len & 0xffffffff:08x}"
    )

    if counts["s_l2av"] > 0 or (s_pkt_len > 0 and s_pkt_len != -1):
        tb.log.info(
            "  T5 VERDICT: AHB-side handoff was the (sole) block — "
            "bypassing it lets packet cross link"
        )
    elif counts["m_a2lv"] > 0:
        tb.log.info(
            "  T5 VERDICT: master a2l_valid drives but slave never receives — "
            "Wlink/PHY downstream block"
        )
    else:
        tb.log.info(
            "  T5 VERDICT: multi-stage block — even combined force doesn't "
            "produce master a2l_valid; arbiter/skid pipeline has another "
            "internal stall"
        )

    assert True
