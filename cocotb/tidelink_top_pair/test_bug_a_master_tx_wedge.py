"""Bug A — master TX wedge primitive sim test (Build #8 L10/L11 regression bar).

This test EXPOSES the master PS-bus wedge primitive that on silicon caused
the PYNQ ``mmap`` write to hang indefinitely. The previous wedge-recovery
test (``test_buga_wedge_recovery.py``) referenced the old ``wedge_force_ready_r``
single-pulse signal which was renamed in Build #8 to a 4-cycle counter
(``wedge_force_ready_cnt_r`` + ``wedge_force_ready_w``). This file is the
Build #8-aligned regression bar.

Sim gap closed (sim-gate policy, MEMORY.md feedback_sim_gate_before_hw_deploy):
the AHB BFM in ``test_tidelink_pair_doorbell.py:264-269`` caps its hready
wait at 50 cy and silently abandons the data phase — the wedge primitive
was INVISIBLE in current sim, which is how F-1.5 slipped through sim and
killed the PS on HW build #6. This test inspects ``ahb_tx_hreadyout``
directly during/after the BFM gives up, so the primitive is fully visible.

Causal chain proven by RTL audit (docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md):

    slave RX framer drops master DATA pkt (L9 territory — separate fix)
      -> slave a2l_fc_replay never drains
      -> master tl_fc_a2l_ready deasserts (a2l_full latches)
      -> master fc_adapter skid stuck (skid_can_accept=0)
      -> tx_data_phase_r never clears
      -> ahb_tx_hreadyout pegged low (line 251-253)
      -> axi_ahblite_bridge BVALID never asserts
      -> SmartConnect outstanding-write peg
      -> PS mmap hangs in kernel forever

L10/L11 (Build #8, commit bc52f88) breaks the chain INSIDE fc_adapter:
after WEDGE_LIMIT=16 consecutive stuck-low cycles, force HREADYOUT=1 for
FORCE_READY_WIDTH=4 cycles, drop the pending word, bump tx_dropped_cnt_r.
HW Build #8 confirms this converts the wedge from "manual power-cycle"
to "PYNQ watchdog auto-recovery in ~60s".

Two tests:

  1. ``test_wedge_primitive_appears_and_l11_recovers`` — synthetic stimulus:
     Force(``tl_fc_a2l_ready=0``) on the master via the IO net,
     issue AHB writes, assert that:
        a) HREADYOUT does in fact go low for >= WEDGE_LIMIT cycles
           (the wedge primitive is visible).
        b) HREADYOUT recovers to high within WEDGE_LIMIT+FORCE_READY_WIDTH+4
           cycles after that — i.e. L11 fires.
        c) tx_dropped_cnt_r increments.
        d) skid_valid_r=1 throughout the stuck window (correct primitive).

  2. ``test_wedge_primitive_recovers_for_multiple_drops`` — drive several
     back-to-back AHB writes while a2l_ready is forced low; assert that
     L11 recovers EACH ONE (not just the first), proving the 4-cy
     FORCE_READY_WIDTH was Build #7's fix for the 2nd-write regression.

Documented invocation (sim_build per-test to avoid clobbering peer envs):

    source /home/dam1n19/SoCLabs/tidelink/set_env.sh
    cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
    timeout 1500 make MODULE=test_bug_a_master_tx_wedge \
        SIM_BUILD=sim_build_bug_a_wedge TB_TOP_NO_DUMP=1

To run the "without L11" leg, temporarily neutralise the watchdog by
forcing ``wedge_force_ready_cnt_r`` to 0 (i.e. delete the force-arm) and
re-run; expected behaviour is the assertions in test 1 sub-step (b) and
(c) FAIL while sub-step (a) PASSes (the wedge appears but never recovers).
See the run-log capture at the bottom of
``docs/BUG_A_L9_FIX_DESIGN_2026_05_31.md`` for actual outputs.

DO NOT touch RTL. DO NOT touch /research/AAA/ip_library/**.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)
from tidelink.packet import encode_word0, PKT_WR_REQ


# Mirrors localparams in src/rtl/tidelink_fc_adapter.sv:191-192.
WEDGE_LIMIT       = 16
FORCE_READY_WIDTH = 4

# Cycles to observe after the BFM hands the data phase off. Bound chosen
# to span: (BFM 50-cy poll) + (WEDGE_LIMIT) + (FORCE_READY_WIDTH) + slack.
WEDGE_OBSERVE_CY  = 50 + WEDGE_LIMIT + FORCE_READY_WIDTH + 30

TEST_TIMEOUT_NS = 30_000_000

PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]


# ---------------------------------------------------------------------------
# Hierarchical helpers
# ---------------------------------------------------------------------------

def _safe(sig):
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


def _opt(scope, name):
    return getattr(scope, name, None)


def _fc_adapter(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_fc_adapter


def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    return [word0, 0x0] + PAYLOAD


async def _settle_post_bringup(tb):
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)


def _require_build8_l11(fc):
    """Loud assert that Build #8 L11 RTL is present."""
    missing = []
    for sig in ("tx_dropped_cnt_r", "wedge_cnt_r",
                "wedge_force_ready_cnt_r"):
        if _opt(fc, sig) is None:
            missing.append(sig)
    assert not missing, (
        "Build #8 L11 RTL not present in tree. Missing signals: "
        + ", ".join(missing)
        + ". Verify src/rtl/tidelink_fc_adapter.sv lines 191-240 are intact "
        "(commit bc52f88)."
    )


# ===========================================================================
# Test 1 — wedge primitive appears, L11 recovers
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_wedge_primitive_appears_and_l11_recovers(dut):
    """Force tl_fc_a2l_ready=0 on the master AFTER bringup, drive an AHB
    write, observe that (a) the wedge primitive IS visible — HREADYOUT
    holds low for >= WEDGE_LIMIT cy with skid_valid_r=1 — and (b) L11
    breaks it inside WEDGE_LIMIT + FORCE_READY_WIDTH + 4 cy by bumping
    tx_dropped_cnt_r and pulsing HREADYOUT high.

    This is the deterministic sim-side proof of the Bug A wedge primitive
    and its L11 recovery — closes the sim/HW gap from
    test_tidelink_pair_doorbell.py:264-269.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fc  = _fc_adapter(dut, "m")
    m_top = _top(dut, "m")
    _require_build8_l11(m_fc)

    dropped_pre = _safe(m_fc.tx_dropped_cnt_r)
    dut._log.info(f"  PRE-FORCE  M.tx_dropped_cnt_r={dropped_pre}")

    # ---- Force the master's tl_fc_a2l_ready low to simulate a stuck
    # downstream link. The signal exists at u_master.tl_fc_a2l_ready
    # (tidelink_top.sv:497). Force()/Release() because the wire is driven
    # by the FCSM and a plain `.value = 0` deposit would not survive past
    # the next driver update on VCS.
    a2l_ready_sig = _opt(m_top, "tl_fc_a2l_ready")
    assert a2l_ready_sig is not None, (
        "tl_fc_a2l_ready not found at u_master scope; check "
        "tidelink_top.sv:497."
    )
    a2l_ready_sig.value = Force(0)

    # ---- Snapshot trace recorders.
    samples = []     # (cy, hreadyout, tx_data_phase_r, skid_valid_r, dropped)
    hreadyout_max_low_streak  = 0
    hreadyout_low_during_skid = 0   # cy that ho=0 AND skid_valid_r=1

    async def primitive_watcher():
        nonlocal hreadyout_max_low_streak, hreadyout_low_during_skid
        cy = 0
        cur_streak = 0
        had_addr_phase = False
        while True:
            await RisingEdge(dut.hclk)
            cy += 1
            tx_dp = _safe(m_fc.tx_data_phase_r)
            ho    = _safe(m_top.ahb_tx_hreadyout)
            skid  = _safe(m_fc.skid_valid_r)
            cnt   = _safe(m_fc.tx_dropped_cnt_r)
            if tx_dp == 1:
                had_addr_phase = True
            if had_addr_phase and ho == 0:
                cur_streak += 1
                if cur_streak > hreadyout_max_low_streak:
                    hreadyout_max_low_streak = cur_streak
                if skid == 1:
                    hreadyout_low_during_skid += 1
            else:
                cur_streak = 0
            # Sample every 4 cy so the log isn't huge.
            if cy % 4 == 0:
                samples.append((cy, ho, tx_dp, skid, cnt))

    watcher = cocotb.start_soon(primitive_watcher())

    # ---- Drive the AHB write. BFM bails after 50 cy of hready=0 (this is
    # the silent-abort bug that hid the wedge primitive on HW). We then
    # observe for another WEDGE_OBSERVE_CY to give L11 time to fire.
    await tb.ahb_tx_write_packet("m", _packet_words())
    await ClockCycles(dut.hclk, WEDGE_OBSERVE_CY)
    watcher.kill()

    a2l_ready_sig.value = Release()

    dropped_post = _safe(m_fc.tx_dropped_cnt_r)
    dut._log.info(
        f"  POST       M.tx_dropped_cnt_r={dropped_post} "
        f"hreadyout_max_low_streak={hreadyout_max_low_streak} "
        f"hreadyout_low_during_skid={hreadyout_low_during_skid}"
    )
    # Dump a brief tail trace so the failure mode is obvious in logs.
    for row in samples[-12:]:
        dut._log.info(
            f"    cy={row[0]:6d}  ho={row[1]}  tx_dp={row[2]}  "
            f"skid_valid={row[3]}  dropped={row[4]}"
        )

    # ----- ASSERTIONS -----

    # A1 — wedge primitive IS visible: HREADYOUT went low for >= WEDGE_LIMIT
    # cy while skid was valid. If this FAILs, the test stimulus didn't
    # actually back-pressure the skid (e.g. Force didn't take effect, or
    # the BFM-driven address phase never started).
    assert hreadyout_max_low_streak >= WEDGE_LIMIT, (
        f"A1 FAIL: wedge primitive did NOT appear — "
        f"hreadyout_max_low_streak={hreadyout_max_low_streak} < "
        f"WEDGE_LIMIT={WEDGE_LIMIT}. Stimulus is broken; check that "
        "Force on tl_fc_a2l_ready took effect (was the right scope used?)."
    )
    assert hreadyout_low_during_skid >= 1, (
        "A1b FAIL: HREADYOUT never went low while skid_valid_r=1. The "
        "wedge primitive REQUIRES the skid to be valid (skid_can_accept=0) "
        "for HREADYOUT to peg low. Force may have been released too early "
        "or the AHB BFM did not start a data phase."
    )

    # A2 — L11 recovers: HREADYOUT bounced back high inside the bound.
    # WEDGE_LIMIT + FORCE_READY_WIDTH + 4 cy: 16 + 4 + 4 = 24. We allow
    # +2 slack for the BFM's 1-cy address-phase setup.
    assert hreadyout_max_low_streak <= WEDGE_LIMIT + FORCE_READY_WIDTH + 4, (
        f"A2 FAIL: L11 did NOT recover the wedge — max low streak "
        f"{hreadyout_max_low_streak} > limit "
        f"{WEDGE_LIMIT + FORCE_READY_WIDTH + 4}. "
        "wedge_force_ready_cnt_r may not be arming. Check "
        "src/rtl/tidelink_fc_adapter.sv:227-238."
    )

    # A3 — tx_dropped_cnt_r incremented (drop-and-count actually fired).
    assert dropped_post > dropped_pre, (
        f"A3 FAIL: tx_dropped_cnt_r did not increment ({dropped_pre} -> "
        f"{dropped_post}). HREADYOUT may have recovered for another "
        "reason (skid drained naturally?). Verify Force on tl_fc_a2l_ready "
        "was active during the data phase."
    )

    dut._log.info(
        "  L11 PASS: wedge primitive appeared "
        f"({hreadyout_max_low_streak}cy low), L11 recovered, dropped_cnt "
        f"incremented {dropped_pre}->{dropped_post}."
    )


# ===========================================================================
# Test 2 — multi-write recovery (Build #7 → #8 regression bar)
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_wedge_primitive_recovers_for_multiple_drops(dut):
    """Build #7 had a 1-cy force_ready pulse that recovered the 1st AHB
    write but not the 2nd (axi_ahblite_bridge didn't latch BVALID
    cleanly). Build #8 widened the pulse to FORCE_READY_WIDTH=4 cy.

    Test: hold Force(tl_fc_a2l_ready=0) and drive 3 AHB writes
    back-to-back. Assert tx_dropped_cnt_r increments by 3 (one per write).
    Without the width-4 fix, this would lock up by the 2nd or 3rd write.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fc  = _fc_adapter(dut, "m")
    m_top = _top(dut, "m")
    _require_build8_l11(m_fc)

    a2l_ready_sig = _opt(m_top, "tl_fc_a2l_ready")
    assert a2l_ready_sig is not None

    dropped_pre = _safe(m_fc.tx_dropped_cnt_r)
    dut._log.info(f"  PRE  M.tx_dropped_cnt_r={dropped_pre}")

    a2l_ready_sig.value = Force(0)

    # Drive 3 writes. Allow L11 to fire fully between writes.
    N_WRITES = 3
    for i in range(N_WRITES):
        await tb.ahb_tx_write_packet("m", _packet_words())
        # Long enough for the watchdog to fully cycle through arm + drop +
        # FORCE_READY_WIDTH.
        await ClockCycles(dut.hclk, WEDGE_LIMIT + FORCE_READY_WIDTH + 10)
        dropped_now = _safe(m_fc.tx_dropped_cnt_r)
        dut._log.info(
            f"  after write #{i+1} M.tx_dropped_cnt_r={dropped_now}"
        )

    a2l_ready_sig.value = Release()
    dropped_post = _safe(m_fc.tx_dropped_cnt_r)
    dut._log.info(
        f"  POST M.tx_dropped_cnt_r={dropped_post} "
        f"(delta={dropped_post - dropped_pre} over {N_WRITES} writes)"
    )

    # Each write -> ahb_tx_write_packet drives len(words) AHB writes.
    # Each AHB write that starves -> one drop_cnt increment.
    # Per ahb_tx_write_packet (test_tidelink_pair_doorbell.py:281-284),
    # each call drives len(words) = 4 words for our packet. So expect
    # ~ 4 * N_WRITES drops. Be permissive: at least N_WRITES (one per
    # outer iteration) confirms L11 fires on every back-to-back write.
    assert dropped_post - dropped_pre >= N_WRITES, (
        f"B FAIL: only {dropped_post - dropped_pre} drops for "
        f"{N_WRITES} writes (expected >= {N_WRITES}). Build #7-style "
        "1-cy force pulse regression: L11 may be missing the "
        "FORCE_READY_WIDTH=4 widening (line 192). Check "
        "src/rtl/tidelink_fc_adapter.sv:191-240."
    )

    dut._log.info(
        f"  Multi-write L11 PASS: {dropped_post - dropped_pre} drops "
        f"over {N_WRITES} writes (>= {N_WRITES} ok)."
    )
