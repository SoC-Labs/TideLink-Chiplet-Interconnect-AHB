"""Bug A — REAL fix verification (L9 consumer-side pktnum resync).

Companion to ``docs/BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md``.

V1's L8 patch (``test_buga_fix_link_data_consumer.py``) advances the slave
FCSM from LINK_IDLE -> LINK_DATA but ``tl_fc_l2a_valid`` still stays 0 and
``REG_PKT_WORD_LEN`` stays 0 because the slave's ``exp_pkt_num`` is out of
sync with the master's TX ``link_cur_addr``. The slave decodes the master's
DATA packets, sees ``pkt_is_data_pkt=1`` but ``ll_rx_pktnum != exp_pkt_num``,
enqueues ``pkttypenotifier=3'h1`` into the ack_nack_fifo, L7 disarms once
state==5 is observed, ``isNotExpPacket`` latches ``send_nack_req``, and the
slave bounces 4->7->4 forever.

The L9 fix (proposed manual edit recipe in §5.3 of the deep root-cause doc)
adds a one-shot sticky ``socl_l9_first_data_seen_rx`` that:

  1. On the FIRST ``pkt_is_data_pkt`` cycle, jumps ``exp_pkt_num`` to
     ``ll_rx_pktnum + 1`` (with wraparound on ``fe_tx_credit_max``).
  2. Forces ``l2a_fc_replay.app_valid`` HIGH on that cycle so the packet
     is accepted into the L2A FIFO.
  3. Masks ``isNotExpPacket`` and ``exp_pkt_not_seen`` for that single cycle
     so the ack_nack_fifo never enqueues a spurious notifier.

After L9 latches, upstream behaviour is unchanged: every subsequent
mismatch latches ``send_nack_req`` per spec; every subsequent match
increments ``exp_pkt_num`` per spec.

Tests in this file ASSERT that ALL of the following hold post-stimulus:

  * Slave ``tl_fc_l2a_valid`` PULSES at least once (not just FCSM state).
  * Slave ``REG_PKT_WORD_LEN > 0`` (data physically landed in RX FIFO).
  * Slave ``send_nack_req`` does NOT latch high at any sample (L7
    invariant preserved end-to-end).
  * Slave ``socl_l9_first_data_seen_rx`` sticky is high (sanity that L9
    armed at all).

Pre-L9 expected behaviour:
  - On a tree WITHOUT L9, ``socl_l9_first_data_seen_rx`` will not exist as
    a hierarchical reference. Test 1 will fail on the ``l2a_pulses`` /
    ``pkt_word_len`` assertion (the existing pre-L9 wedge symptom).
  - Test 2 (the resync-witness probe) will mark itself ``skip-equivalent``
    if the L9 sticky doesn't resolve.

Post-L9 expected behaviour:
  - Test 1 passes all 4 assertions.
  - Test 2 reports ``exp_pkt_num`` advanced past 0.

DO NOT touch RTL. DO NOT touch ``/research/AAA/ip_library/**``. This file
is authored offline pursuant to the Bug A V2 deep root-cause investigation.
Run command::

  source /home/dam1n19/SoCLabs/tidelink/set_env.sh
  cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
  timeout 1200 make MODULE=test_buga_real_fix_rx_wedge \\
      SIM_BUILD=sim_build_buga_real_fix TB_TOP_NO_DUMP=1

Sim-time bound: 30 ms (bringup ~8.5 ms + 5000-cy observation + APB reads).
Wall-clock bound: ~10 min on srv04936.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    APB_PKT_WORD_LEN,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ---------------------------------------------------------------------------
# Hierarchical helpers (mirror test_buga_fix_link_data_consumer.py)
# ---------------------------------------------------------------------------

def _fcsm(dut, side):
    """Handle to the FCSM ``state`` register inside the WlinkGenericFCSM_6
    instance, per the path documented in
    ``docs/BUG_A_FORCE_EXPERIMENTS_2026_05_29.md`` section 3."""
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _safe(sig):
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


def _opt_signal(scope, name):
    """Hierarchical signal lookup that tolerates missing nets (so a tree
    without L9 still loads cleanly; the relevant assertion then prints
    ``-1`` for ``socl_l9_first_data_seen_rx`` instead of crashing)."""
    return getattr(scope, name, None)


async def _settle_post_bringup(tb):
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


# A minimal AHB write packet (mirrors test_buga_fix_link_data_consumer.py).
# Two payload words is sufficient to exercise multiple FC frames; L9 only
# needs ONE DATA packet to latch the sticky and resync exp_pkt_num.
PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


# Observation window. With L9, the slave should drain the master's first
# DATA packet into the L2A FIFO on the cycle it's decoded; tl_fc_l2a_valid
# should pulse within a handful of cycles. 5000 is generous and bounds the
# test against PHY/clkdiv jitter and replay-FIFO drain latency.
OBSERVE_WINDOW_CY = 5000

TEST_TIMEOUT_NS = 30_000_000


# ===========================================================================
# Test 1 — the main Bug A "real fix" gate
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_real_fix_slave_rx_drains(dut):
    """L9 verification: slave RX path drains the master's AHB write.

    Sequence:
      1. Bring up pair (CR/CRACK exchange, RX framer locked, app_enable up).
      2. Snapshot pre-stimulus state for diagnostic logging.
      3. Issue one PKT_WR_REQ via master AHB master.
      4. Watch slave for OBSERVE_WINDOW_CY cycles, counting:
           * ``tl_fc_l2a_valid`` pulses.
           * Whether ``send_nack_req`` latches at any cycle (L7 invariant).
      5. APB-read ``REG_PKT_WORD_LEN`` from slave; must be > 0.

    Assertions (all four MUST hold for L9 to be considered functional):
      A1. ``l2a_pulses >= 1``  -- RX path drained.
      A2. ``REG_PKT_WORD_LEN > 0`` -- FIFO actually received the packet.
      A3. ``nack_latched_cy == 0`` -- L7 invariant preserved end-to-end.
      A4. ``socl_l9_first_data_seen_rx == 1`` -- L9 armed at least once.

    Pre-L9: A1, A2 fail (the pre-fix wedge symptom). A3 may also fail
    after L8-only is applied (the regression V1 spotted). A4 is undefined
    (the sticky reg doesn't exist).
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")
    s_top  = _top(dut, "s")

    m_state_pre = _safe(m_fcsm.state)
    s_state_pre = _safe(s_fcsm.state)
    s_exp_pre   = _safe(_opt_signal(s_fcsm, "exp_pkt_num"))
    s_l9_pre    = _safe(_opt_signal(s_fcsm, "socl_l9_first_data_seen_rx"))
    dut._log.info(
        f"  PRE-AHB  M.state={m_state_pre} S.state={s_state_pre} "
        f"S.exp_pkt_num={s_exp_pre} S.socl_l9_first_data_seen_rx={s_l9_pre}"
    )

    # ---- Drive AHB write packet on master, watching slave concurrently.
    l2a_pulses = 0
    nack_latched_cy = -1
    s_first_data_cy = -1

    async def s_watcher():
        nonlocal l2a_pulses, nack_latched_cy, s_first_data_cy
        cy = 0
        while True:
            await RisingEdge(dut.hclk)
            cy += 1
            if _safe(s_top.tl_fc_l2a_valid) == 1:
                l2a_pulses += 1
            snr = _safe(_opt_signal(s_fcsm, "send_nack_req"))
            if snr == 1 and nack_latched_cy < 0:
                nack_latched_cy = cy
            l9 = _safe(_opt_signal(s_fcsm, "socl_l9_first_data_seen_rx"))
            if l9 == 1 and s_first_data_cy < 0:
                s_first_data_cy = cy

    watcher = cocotb.start_soon(s_watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    dut._log.info("  AHB write packet driven; observing slave...")

    await ClockCycles(dut.hclk, OBSERVE_WINDOW_CY)
    watcher.kill()

    m_state_post = _safe(m_fcsm.state)
    s_state_post = _safe(s_fcsm.state)
    s_exp_post   = _safe(_opt_signal(s_fcsm, "exp_pkt_num"))
    s_l9_post    = _safe(_opt_signal(s_fcsm, "socl_l9_first_data_seen_rx"))
    s_snr_final  = _safe(_opt_signal(s_fcsm, "send_nack_req"))

    dut._log.info(
        f"  POST     M.state={m_state_post} S.state={s_state_post} "
        f"S.exp_pkt_num={s_exp_post} S.socl_l9_first_data_seen_rx={s_l9_post} "
        f"S.send_nack_req={s_snr_final}"
    )
    dut._log.info(
        f"  COUNTS   l2a_pulses={l2a_pulses} nack_latched_cy={nack_latched_cy} "
        f"s_first_data_cy={s_first_data_cy}"
    )

    # ---- APB-read slave's PKT_WORD_LEN.
    pkt_word_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    dut._log.info(f"  S.REG_PKT_WORD_LEN = 0x{int(pkt_word_len):08x}")

    # =====================================================================
    # ASSERTIONS — L9 is verified iff all four hold.
    # =====================================================================
    assert l2a_pulses >= 1, (
        f"A1 FAIL: slave tl_fc_l2a_valid never pulsed within "
        f"{OBSERVE_WINDOW_CY} cy. Pre-L9 wedge symptom: RX path did not "
        "drain. Either L9 patch is missing, or the resync is not arming. "
        "Check that 'socl_l9_first_data_seen_rx' is reachable as a "
        "hierarchical ref (presence = patch applied)."
    )
    assert int(pkt_word_len) != 0, (
        f"A2 FAIL: slave REG_PKT_WORD_LEN = 0 after AHB packet. RX FIFO "
        "did not record the master's packet even though l2a_valid pulsed. "
        "Check the L2A replay FIFO drain path downstream of FCSM."
    )
    assert nack_latched_cy < 0, (
        f"A3 FAIL: slave send_nack_req latched at cy={nack_latched_cy}. "
        "L7 invariant regressed. With L9 applied, isNotExpPacket should "
        "be masked during the resync window AND exp_pkt_num should resync "
        "to the master's pktnum, so no isNotExpPacket should ever fire "
        "after that. Check Edit 3/4/6 of the L9 patch recipe."
    )
    assert s_l9_post == 1, (
        f"A4 FAIL: socl_l9_first_data_seen_rx is {s_l9_post}, expected 1. "
        "Either the sticky doesn't exist (patch not applied) or the slave "
        "never observed a pkt_is_data_pkt event. Check the always-block "
        "from L9 patch Edit 7."
    )

    dut._log.info(
        "  L9 PASS: tl_fc_l2a_valid pulsed, REG_PKT_WORD_LEN nonzero, "
        "send_nack_req never latched, L9 sticky armed. RX path "
        "drained correctly."
    )


# ===========================================================================
# Test 2 — independent resync-witness probe
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_real_fix_pktnum_resync_arms(dut):
    """Verifies the L9 resync mechanism armed at the right point.

    Pre-stimulus snapshot of ``exp_pkt_num`` (expected: 0 on fresh
    bringup). Post-stimulus snapshot (expected: > 0, meaning either the
    resync fired or natural increments happened).

    Combined assertion: ``exp_pkt_num`` advanced past 0 within
    ``OBSERVE_WINDOW_CY`` cycles of the stimulus. This is a weaker but
    more direct probe of the L9 resync mechanism — if Test 1 passes but
    Test 2 fails, the issue is purely in the ack_nack-mask path; if Test 2
    passes but Test 1 fails, the resync is wired but the FIFO drain is
    broken further downstream.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    s_fcsm = _fcsm(dut, "s")

    s_exp_pre = _safe(_opt_signal(s_fcsm, "exp_pkt_num"))
    dut._log.info(f"  PRE-AHB  S.exp_pkt_num={s_exp_pre}")

    assert s_exp_pre == 0, (
        f"Pre-AHB exp_pkt_num == {s_exp_pre}, expected 0 (fresh bringup). "
        "If exp_pkt_num is non-zero here, the slave has already drained "
        "packets and this test is not exercising the resync window."
    )

    # Track max observed exp_pkt_num across the window.
    max_exp = s_exp_pre

    async def exp_watcher():
        nonlocal max_exp
        while True:
            await RisingEdge(dut.hclk)
            v = _safe(_opt_signal(s_fcsm, "exp_pkt_num"))
            if v > max_exp:
                max_exp = v

    watcher = cocotb.start_soon(exp_watcher())

    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, OBSERVE_WINDOW_CY)
    watcher.kill()

    s_exp_post = _safe(_opt_signal(s_fcsm, "exp_pkt_num"))
    s_l9_post  = _safe(_opt_signal(s_fcsm, "socl_l9_first_data_seen_rx"))
    dut._log.info(
        f"  POST     S.exp_pkt_num={s_exp_post} max_observed={max_exp} "
        f"S.socl_l9_first_data_seen_rx={s_l9_post}"
    )

    # L9 resync MUST bump exp_pkt_num past 0 within the window.
    assert max_exp > 0, (
        f"exp_pkt_num remained at 0 for entire {OBSERVE_WINDOW_CY}-cy "
        "window. Either no DATA packets reached the slave (RX framer "
        "failure) or the L9 resync didn't fire AND the master's first "
        "DATA pkt happened to have pktnum=0 (in which case standard "
        "exp_pkt_seen path should have advanced exp_pkt_num). "
        f"socl_l9_first_data_seen_rx={s_l9_post}."
    )

    dut._log.info("  L9 resync witness PASS: exp_pkt_num advanced post-stimulus.")
