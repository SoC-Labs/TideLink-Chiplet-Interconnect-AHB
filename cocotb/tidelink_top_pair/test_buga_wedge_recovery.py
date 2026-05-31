"""Bug A — L10 wedge-recovery verification (TX HREADY watchdog).

Companion to ``docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md``.

L10 hypothesis: Bug A's HW-specific master wedge primitive (SSH freeze,
power-cycle recovery) is a propagation chain:

    slave RX framer wedge (L9 territory)
        -> master tl_fc_a2l_ready=0 forever  (A2L CDC FIFO fills)
        -> master fc_adapter skid stuck      (skid_can_accept=0)
        -> tx_data_phase_r stuck             (clear gate at line 189)
        -> ahb_tx_hreadyout=0 forever        (line 202)
        -> axi_ahblite_bridge AXI BVALID never asserts
        -> PS M_AXI_GP0 outstanding-write peg
        -> PYNQ mmap write blocks in kernel
        -> SSH hang

L10 fix breaks the chain at fc_adapter by adding a watchdog: after
``WEDGE_LIMIT=16`` consecutive cycles of HREADYOUT stuck low under
back-pressure, force ``HREADYOUT=1`` for one cycle, drop the pending word,
bump ``tx_dropped_cnt_r``. AHB stays responsive; PS doesn't hang.

This file contains TWO tests:

  1. ``test_hreadyout_recovers_under_force_tx_block`` — synthetic stimulus
     that forces ``tl_fc_a2l_ready=0`` post-bringup, drives an AHB write,
     asserts HREADYOUT bounces back high within ``WEDGE_LIMIT + 4`` cy
     AND ``tx_dropped_cnt_r`` increments.

  2. ``test_hreadyout_recovers_under_natural_buga_wedge`` — bringup + AHB
     write on a tree WITHOUT L9; asserts HREADYOUT eventually recovers.
     Skip-equivalent if L9 is applied (Bug A doesn't wedge in sim).

Both tests are gated by ``hasattr(fc, 'tx_dropped_cnt_r')`` so a pre-L10
tree fails LOUDLY rather than silently regressing.

DO NOT touch RTL. DO NOT touch ``/research/AAA/ip_library/**``. This file
is the regression bar for the L10 wedge-recovery patch; it must PASS once
L10 is applied to ``src/rtl/tidelink_fc_adapter.sv`` (Edits 1-3 of the
L10 recipe in BUG_A_WEDGE_INVESTIGATION_2026_05_31.md).

Run command::

    source /home/dam1n19/SoCLabs/tidelink/set_env.sh
    cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
    timeout 1200 make MODULE=test_buga_wedge_recovery \\
        SIM_BUILD=sim_build_buga_wedge_recovery TB_TOP_NO_DUMP=1

Sim-time bound: 30 ms (bringup ~8.5 ms + force + observation window).
Wall-clock bound: ~10 min on srv04936.
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


# Mirror of the localparam in tidelink_fc_adapter.sv L10 Edit 1.
WEDGE_LIMIT = 16

# Generous post-watchdog window: WEDGE_LIMIT to trip, +4 for HREADYOUT to
# bounce + AHB phase to advance, +20 for safety against the AHB BFM's own
# 50-cy poll inside _ahb_tx_write_word.
RECOVERY_OBSERVE_CY = WEDGE_LIMIT + 4 + 20

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


def _opt_signal(scope, name):
    """Return ``scope.<name>`` or ``None`` (so a tree without L10 still loads
    and the test fails on its gating assertion instead of crashing in a
    hierarchical-ref lookup)."""
    return getattr(scope, name, None)


def _fc_adapter(dut, side):
    """Handle to the side's ``u_fc_adapter`` instance (defined in
    ``src/rtl/tidelink_top.sv:1115``)."""
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


def _require_l10(fc, dut):
    """Skip-equivalent helper. Asserts that the L10 RTL is present in the
    tree; otherwise raises a loud AssertionError describing which Edit is
    missing."""
    missing = []
    if _opt_signal(fc, "tx_dropped_cnt_r") is None:
        missing.append("tx_dropped_cnt_r (L10 Edit 1)")
    if _opt_signal(fc, "wedge_cnt_r") is None:
        missing.append("wedge_cnt_r (L10 Edit 1)")
    if _opt_signal(fc, "wedge_force_ready_r") is None:
        missing.append("wedge_force_ready_r (L10 Edit 1)")
    assert not missing, (
        "L10 RTL not present in tree. Missing signals: "
        + ", ".join(missing)
        + ". Apply Edits 1-3 from "
        "docs/BUG_A_WEDGE_INVESTIGATION_2026_05_31.md to "
        "src/rtl/tidelink_fc_adapter.sv before running this test."
    )


# ===========================================================================
# Test 1 — synthetic force_tx_block: directly assert the L10 watchdog
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_hreadyout_recovers_under_force_tx_block(dut):
    """Force ``tl_fc_a2l_ready=0`` post-bringup on the master, drive an
    AHB write, assert HREADYOUT bounces back high within ``WEDGE_LIMIT+4``
    cycles AND ``tx_dropped_cnt_r`` increments.

    This is the DIRECT regression bar for the L10 watchdog: independent of
    whether Bug A's slave-RX wedge reproduces in sim, the master must
    refuse to hang HREADYOUT indefinitely under back-pressure.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fc  = _fc_adapter(dut, "m")
    m_top = _top(dut, "m")
    _require_l10(m_fc, dut)

    # ---- Snapshot pre-stimulus state.
    dropped_pre  = _safe(m_fc.tx_dropped_cnt_r)
    dut._log.info(f"  PRE-FORCE  M.tx_dropped_cnt_r={dropped_pre}")

    # ---- Force tl_fc_a2l_ready=0 on the master, simulating a downstream
    # link that refuses to drain. We deposit via the top-level wire so the
    # fc_adapter sees ready=0 and the skid backs up on the very next AHB
    # data phase. Restored at end-of-test.
    a2l_ready_sig = _opt_signal(m_top, "tl_fc_a2l_ready")
    assert a2l_ready_sig is not None, (
        "tl_fc_a2l_ready not found at u_master level. Path may have changed"
        "; see tidelink_top.sv:497."
    )
    # Save original drive (combinational from skid drain in tidelink_top.sv;
    # we override at the receiver port by forcing the adapter's input).
    try:
        a2l_ready_sig.value = 0
    except Exception as e:
        raise AssertionError(
            "Cannot deposit on tl_fc_a2l_ready directly; consider using "
            "cocotb's signal.value = ... or move the force one level deeper "
            "into the u_fc_adapter port. Original error: " + repr(e)
        )

    # ---- Watcher: track HREADYOUT low-streak length and tx_dropped_cnt_r.
    hreadyout_max_low_streak = 0
    hreadyout_recovered_cy   = -1
    dropped_observed         = dropped_pre

    async def hready_watcher():
        nonlocal hreadyout_max_low_streak, hreadyout_recovered_cy
        nonlocal dropped_observed
        cy = 0
        cur_streak = 0
        had_addr_phase = False
        while True:
            await RisingEdge(dut.hclk)
            cy += 1
            tx_dp = _safe(m_fc.tx_data_phase_r)
            ho    = _safe(m_top.ahb_tx_hreadyout)
            cnt   = _safe(m_fc.tx_dropped_cnt_r)
            if cnt > dropped_observed:
                dropped_observed = cnt
            if tx_dp == 1:
                had_addr_phase = True
            if had_addr_phase and ho == 0:
                cur_streak += 1
                if cur_streak > hreadyout_max_low_streak:
                    hreadyout_max_low_streak = cur_streak
            else:
                if had_addr_phase and ho == 1 and hreadyout_recovered_cy < 0 \
                   and hreadyout_max_low_streak > 0:
                    hreadyout_recovered_cy = cy
                cur_streak = 0

    watcher = cocotb.start_soon(hready_watcher())

    # ---- Drive the AHB write with the BFM. BFM caps its hready wait at
    # 50 cy (test_tidelink_pair_doorbell.py:264-269) so even if L10 fails
    # to bounce HREADYOUT, we won't deadlock the simulator — the BFM will
    # silently move on and the assertions below will catch the wedge.
    await tb.ahb_tx_write_packet("m", _packet_words())

    # ---- Observe for the recovery window.
    await ClockCycles(dut.hclk, RECOVERY_OBSERVE_CY)
    watcher.kill()

    # ---- Restore a2l_ready (best-effort; sim ends here anyway).
    try:
        a2l_ready_sig.value = 1
    except Exception:
        pass

    dropped_post = _safe(m_fc.tx_dropped_cnt_r)
    dut._log.info(
        f"  POST       M.tx_dropped_cnt_r={dropped_post} "
        f"hreadyout_max_low_streak={hreadyout_max_low_streak} "
        f"hreadyout_recovered_cy={hreadyout_recovered_cy}"
    )

    # ----- ASSERTIONS -----
    # B1: HREADYOUT did NOT stay low for more than WEDGE_LIMIT + 2 cycles.
    # Allow +2 for the one-cycle delay of wedge_force_ready_r and the AHB
    # bridge sampling. If this fails, the watchdog is not tripping.
    assert hreadyout_max_low_streak <= WEDGE_LIMIT + 2, (
        f"B1 FAIL: ahb_tx_hreadyout stayed low for "
        f"{hreadyout_max_low_streak} consecutive cycles (limit "
        f"= WEDGE_LIMIT+2 = {WEDGE_LIMIT + 2}). The L10 wedge watchdog "
        "did not force HREADYOUT high. Check Edit 2/3 of the L10 recipe."
    )

    # B2: HREADYOUT actually recovered to 1 within the observation window
    # AFTER it had been observed low. (The watcher only records a recovery
    # if max_low_streak > 0, so this asserts the round-trip transition.)
    assert hreadyout_recovered_cy > 0 or hreadyout_max_low_streak == 0, (
        f"B2 FAIL: ahb_tx_hreadyout never bounced back to 1 within "
        f"{RECOVERY_OBSERVE_CY} cy of stimulus (max_low_streak="
        f"{hreadyout_max_low_streak}). PS-bus liveness regression."
    )

    # B3: tx_dropped_cnt_r incremented — proving the watchdog actually
    # took the drop-and-recover path (and didn't just happen to drain
    # naturally for some other reason).
    assert dropped_post > dropped_pre, (
        f"B3 FAIL: tx_dropped_cnt_r did not increment ({dropped_pre} -> "
        f"{dropped_post}). HREADYOUT may have recovered for another "
        "reason (skid drained naturally?). Verify the force on "
        "tl_fc_a2l_ready actually held — instrument with a snapshot of "
        "skid_valid_r."
    )

    dut._log.info(
        "  L10 PASS: HREADYOUT bounced within "
        f"{hreadyout_max_low_streak}cy, dropped_cnt incremented "
        f"{dropped_pre}->{dropped_post}, recovery observed at "
        f"cy={hreadyout_recovered_cy}."
    )


# ===========================================================================
# Test 2 — natural Bug A repro: skip-equivalent if L9 applied
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_hreadyout_recovers_under_natural_buga_wedge(dut):
    """End-to-end paired test: drive an AHB write through the full bringup
    + FCSM + slave RX path. If the slave-RX-wedge reproduces (i.e. L9 not
    yet applied or insufficient), the master must STILL keep AHB
    responsive thanks to L10.

    If L9 is applied AND working, this test is skip-equivalent — the
    slave drains the packet, the master's skid never backs up, the
    watchdog never trips. We detect this case by checking whether
    HREADYOUT was ever held low for >= WEDGE_LIMIT cycles; if not, log
    SKIP-EQUIVALENT and pass.

    This is the second pillar of the L10 regression bar: NO HW deploy
    should ever observe a wedge that lasts > WEDGE_LIMIT cy on AHB_TX.
    """
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _settle_post_bringup(tb)

    m_fc  = _fc_adapter(dut, "m")
    m_top = _top(dut, "m")
    _require_l10(m_fc, dut)

    hreadyout_max_low_streak = 0
    dropped_pre = _safe(m_fc.tx_dropped_cnt_r)

    async def hready_watcher():
        nonlocal hreadyout_max_low_streak
        cur_streak = 0
        had_addr_phase = False
        while True:
            await RisingEdge(dut.hclk)
            tx_dp = _safe(m_fc.tx_data_phase_r)
            ho    = _safe(m_top.ahb_tx_hreadyout)
            if tx_dp == 1:
                had_addr_phase = True
            if had_addr_phase and ho == 0:
                cur_streak += 1
                if cur_streak > hreadyout_max_low_streak:
                    hreadyout_max_low_streak = cur_streak
            else:
                cur_streak = 0

    watcher = cocotb.start_soon(hready_watcher())
    await tb.ahb_tx_write_packet("m", _packet_words())

    # Same observation window as test_buga_real_fix_rx_wedge for parity.
    await ClockCycles(dut.hclk, 5000)
    watcher.kill()

    dropped_post = _safe(m_fc.tx_dropped_cnt_r)
    wedge_observed = hreadyout_max_low_streak >= WEDGE_LIMIT

    dut._log.info(
        f"  natural-Bug-A: max_low_streak={hreadyout_max_low_streak} "
        f"dropped {dropped_pre}->{dropped_post} "
        f"wedge_observed={wedge_observed}"
    )

    if not wedge_observed:
        dut._log.info(
            "  L10 SKIP-EQUIVALENT: slave drained naturally (likely L9 "
            "is applied and working), watchdog never tripped. L10 is "
            "still present in the tree (gating assertion passed) so the "
            "regression bar is met."
        )
        return

    # If we did observe a wedge, L10 must have recovered it within the
    # bound + dropped_cnt must have moved.
    assert hreadyout_max_low_streak <= WEDGE_LIMIT + 2, (
        f"C1 FAIL: natural Bug A wedge held HREADYOUT low for "
        f"{hreadyout_max_low_streak} cy (limit {WEDGE_LIMIT + 2}). "
        "L10 watchdog failed to recover the bus."
    )
    assert dropped_post > dropped_pre, (
        f"C2 FAIL: wedge observed but tx_dropped_cnt_r did not "
        f"increment ({dropped_pre} -> {dropped_post})."
    )

    dut._log.info(
        f"  L10 PASS (natural): Bug A wedge captured + recovered, "
        f"dropped_cnt {dropped_pre}->{dropped_post}."
    )
