"""Bug A — L8 consumer-side fix regression test
=================================================

**Status**: TEST AUTHORED, NOT YET RUN. Sister patch:
``docs/BUG_A_PROPOSED_FIX_2026_05_29.patch``.

Purpose
-------
After the L8 (consumer-side LINK_IDLE -> LINK_DATA forgive) gate is applied
to ``src/rtl/local_overrides/WlinkGenericFCSM_6.v``, this test demonstrates:

  1. Master AHB write produces a sustained ``tl_fc_a2l_valid`` window on the
     master TX path (the existing T5-style stimulus).
  2. The SLAVE FCSM ``state`` advances from 4 (LINK_IDLE) to 5 (LINK_DATA)
     within ``ADVANCE_WINDOW_CY`` cycles — this is the L8 gate firing.
  3. Slave ``tl_fc_l2a_valid`` asserts at least once after that.
  4. Slave APB ``REG_PKT_WORD_LEN`` becomes non-zero (the RX FIFO actually
     received the packet).

Without the L8 patch this test is expected to FAIL on assertion (2). With
the patch, all four assertions should pass.

Hierarchical-ref pattern matches ``test_fc_tx_force_experiments.py``:
  * master fc adapter  : ``dut.u_master.u_fc_adapter``
  * slave FCSM state   : ``dut.u_slave.u_chiplet_controller.u_wlink.tl2wl.``
                         ``wlink_tidelinktl.state``
  * pair-level FC wires: ``dut.u_master.tl_fc_a2l_valid`` /
                         ``dut.u_slave.tl_fc_l2a_valid``

DO NOT touch RTL. DO NOT touch ``/research/AAA/ip_library/**``. This file is
authored offline pursuant to the Bug A fix-design hand-off; the next
operator should run it via the standard cocotb harness:

::

  source /home/dam1n19/SoCLabs/tidelink/set_env.sh
  cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
  timeout 1200 make MODULE=test_buga_fix_link_data_consumer \\
      SIM_BUILD=sim_build_buga_fix TB_TOP_NO_DUMP=1

(Wall-clock budget: bringup ~8.5 ms + observation window ~few hundred us;
the test is bounded by ``cocotb.test(timeout_time=30 ms)``.)
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# ---------------------------------------------------------------------------
# Hierarchical helpers (mirror test_fc_tx_force_experiments.py)
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


async def _settle_post_bringup(tb):
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


# A minimal AHB write packet (mirrors test_fc_tx_force_experiments.py
# `_packet_words`). Two payload words is enough to exercise multiple
# FC frames; the L8 gate only needs ONE data packet to latch the sticky.
PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


# Observation window after the AHB stimulus completes. With the L8 patch,
# the slave FCSM should leave state 4 within tens of cycles of the first
# decoded data packet — 4096 is *very* generous and keeps the test robust
# against PHY/clkdiv jitter.
ADVANCE_WINDOW_CY = 4096

# APB offset for the SW-mirror ``REG_PKT_WORD_LEN`` (per
# ``docs/HANDOFF_ERRATA_2026_05_29.md`` and ``reference_tidelink_address_map``
# memory entry). The constant is fetched from the doorbell helper module
# if defined; otherwise we fall back to the documented offset 0x064. The
# operator may need to confirm before running.
try:
    from test_tidelink_pair_doorbell import APB_REG_PKT_WORD_LEN  # type: ignore
except ImportError:
    APB_REG_PKT_WORD_LEN = 0x064  # documented in handoff errata


TEST_TIMEOUT_NS = 30_000_000


# ===========================================================================
# Main test
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_fix_slave_advances_to_link_data(dut):
    """Top-level Bug A L8 regression.

    Sequence:
      1. Bring up pair.
      2. Snapshot M.state and S.state -- expect 4 / 4 before AHB stimulus
         (with L7 in place; pre-L8 build #3 HW behaviour).
      3. Issue ONE PKT_WR_REQ from master AHB master.
      4. Observe slave ``state`` for ADVANCE_WINDOW_CY cycles. With L8,
         slave should transition 4 -> 5 within the window.
      5. Confirm slave ``tl_fc_l2a_valid`` asserts >=1 cycle after that.
      6. Read slave APB ``REG_PKT_WORD_LEN`` and confirm non-zero.

    Pre-L8 expected behaviour: assertion (4) fails (slave stays at 4 for
    the full 2126+ cycle window observed in T5).

    Post-L8 expected behaviour: all assertions pass.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")
    s_top = _top(dut, "s")

    # ---- (2) Snapshot post-bringup states.
    m_state_before = _safe(m_fcsm.state)
    s_state_before = _safe(s_fcsm.state)
    dut._log.info(
        f"  PRE-AHB  M.state={m_state_before} S.state={s_state_before}"
    )

    # Sanity: with current L7-only fix, we expect M=5 and S=4 (see
    # BUG_A_FORCE_EXPERIMENTS_2026_05_29.md section 1). If S is already 5,
    # this test is not exercising the L8 gate -- skip-equivalent fail.
    assert s_state_before == 4, (
        f"Pre-AHB slave state == {s_state_before}, expected 4 (LINK_IDLE). "
        "This test is designed to verify L8 forces 4 -> 5; if the slave "
        "is already at 5 the gate is not under test."
    )

    # ---- (3) Drive AHB write on master while watching slave state.
    advanced_at_cy = -1
    l2a_pulses = 0
    cy_after_ahb = 0

    async def s_state_watcher():
        nonlocal advanced_at_cy, l2a_pulses, cy_after_ahb
        while True:
            await RisingEdge(dut.hclk)
            cy_after_ahb += 1
            if advanced_at_cy < 0 and _safe(s_fcsm.state) == 5:
                advanced_at_cy = cy_after_ahb
                dut._log.info(
                    f"  S.state 4 -> 5 at +{advanced_at_cy} cy after AHB"
                )
            if _safe(s_top.tl_fc_l2a_valid) == 1:
                l2a_pulses += 1

    watcher_task = cocotb.start_soon(s_state_watcher())

    # AHB write -- standard pair-TB helper used by other Bug A tests.
    await tb.ahb_tx_write_packet("m", _packet_words())
    dut._log.info("  AHB write packet driven; observing slave...")

    # ---- (4) Observation window.
    await ClockCycles(dut.hclk, ADVANCE_WINDOW_CY)
    watcher_task.kill()

    m_state_after = _safe(m_fcsm.state)
    s_state_after = _safe(s_fcsm.state)
    dut._log.info(
        f"  POST     M.state={m_state_after} S.state={s_state_after} "
        f"advanced_at={advanced_at_cy} l2a_pulses={l2a_pulses}"
    )

    # ---- (5) APB read of REG_PKT_WORD_LEN on slave.
    pkt_word_len = await tb.s_apb.read(APB_REG_PKT_WORD_LEN)
    dut._log.info(f"  S.REG_PKT_WORD_LEN = 0x{int(pkt_word_len):08x}")

    # =====================================================================
    # ASSERTIONS — the L8 fix is verified iff all four hold.
    # =====================================================================
    assert advanced_at_cy > 0, (
        f"Slave FCSM never left LINK_IDLE (state==4) within "
        f"{ADVANCE_WINDOW_CY} cycles after master AHB write. "
        "Bug A L8 gate is either missing or mis-wired. Pre-fix behaviour."
    )
    assert advanced_at_cy <= ADVANCE_WINDOW_CY, (
        f"Slave reached LINK_DATA at cy {advanced_at_cy} which exceeds the "
        f"{ADVANCE_WINDOW_CY}-cy window."
    )
    assert l2a_pulses >= 1, (
        f"Slave tl_fc_l2a_valid never asserted (pulses={l2a_pulses}) "
        f"despite state advancing to 5. RX path not draining."
    )
    assert int(pkt_word_len) != 0, (
        f"Slave REG_PKT_WORD_LEN reads 0 after AHB packet — the RX FIFO "
        "did not record the master's packet. L8 advanced the FCSM but "
        "the data path is still wedged downstream."
    )

    dut._log.info(
        "  L8 PASS: slave advanced 4->5, l2a_valid fired, REG_PKT_WORD_LEN "
        "is non-zero — Bug A consumer-side gate is functional."
    )


# ===========================================================================
# Companion regression — confirm L7 still works (no regression on producer
# side). This test exists to catch the failure mode where the L8 patch
# accidentally breaks the L7 fix.
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_fix_l7_send_nack_still_clears(dut):
    """Sanity: with L8 applied, send_nack_req should still clear during
    bringup forgive window (the existing L7 behaviour). We probe
    ``socl_l7_reached_link_data`` and ``send_nack_req`` and confirm
    the existing L7 invariant: both peers should eventually have
    ``send_nack_req == 0`` and ``socl_l7_reached_link_data == 1``.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")

    # Drive an AHB packet so both sides reach LINK_DATA.
    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, ADVANCE_WINDOW_CY)

    for side, fcsm in (("m", m_fcsm), ("s", s_fcsm)):
        snr = _safe(fcsm.send_nack_req)
        rld = _safe(fcsm.socl_l7_reached_link_data)
        dut._log.info(
            f"  {side}: send_nack_req={snr} socl_l7_reached_link_data={rld}"
        )
        assert snr == 0, (
            f"{side}: send_nack_req latched after L8 fix — L7 regression. "
            "Confirm L8 forgive gate did not interact with send_nack_req "
            "logic."
        )
        assert rld == 1, (
            f"{side}: socl_l7_reached_link_data not latched — either FCSM "
            "never reached state 5 (so L8 did not help) or the L7 sticky "
            "register itself regressed."
        )

    dut._log.info("  L7 regression check PASS — L8 did not break L7.")
