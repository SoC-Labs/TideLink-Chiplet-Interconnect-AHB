"""Verification test for **Bug B fix** — ``hw_sync_force_en_r`` bypasses
``phc_time_reached``.

Bug B (see docs/BUG_B_FIX_PLAN_2026_05_29.md): with the pair tb_top
PHC tie-off ``phc_nanoseconds = 30'h0`` and the reset default
``hw_sync_interval_r = 999_999_999`` (tidelink_ptp.sv:359), the
HW_SYNC FSM wedges in ARMED forever because ``phc_time_reached`` (line
399-401) is permanently false. ``ptp_sp_tx_valid`` never asserts and no
SYNC packet crosses the link.

The proposed fix (docs/BUG_B_PROPOSED_FIX_2026_05_29.patch) makes
``phc_time_reached`` evaluate true when ``hw_sync_force_en_r`` is set,
mirroring the existing bypass behaviour at the IDLE→ARMED gate
(``hw_sync_gate``, line 372) and the TX_WAIT_IDLE→TX_SEND gate
(line 260).

This file does NOT modify the RTL. It is intended to be run **after**
the patch has been applied — the test fails today (Bug B reproduction)
and passes once the patch is in place.

Hierarchical path conventions match
``test_master_ptp_tx_router.py`` / ``test_ptp_corrected_regs.py``:
  ``dut.u_<master|slave>.gen_ptp_real.u_ptp.<sig>``
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_PTP_CTRL,
    APB_HW_SYNC_CTRL,
    APB_HW_SYNC_STATUS,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


PTP_CTRL_MASTER_GM_ENABLE = 0x09   # GM(bit3) | enable(bit0)
PTP_CTRL_SLAVE_ENABLE     = 0x01
HW_SYNC_CTRL_FORCE_ENABLE = 0x05   # force_en(bit2) | enable(bit0)


# ---------------------------------------------------------------------------
# Hierarchical probe helpers (mirroring test_master_ptp_tx_router.py)
# ---------------------------------------------------------------------------
_PTP_HANDLE_CACHE = {}


def _resolve_u_ptp(dut, side):
    cached = _PTP_HANDLE_CACHE.get(side)
    if cached is not None:
        return cached
    top = dut.u_master if side == "m" else dut.u_slave
    candidates = []
    for label, getter in (
        ("top.gen_ptp_real.u_ptp",
         lambda: top.gen_ptp_real.u_ptp),
        ("top._id('gen_ptp_real.u_ptp')",
         lambda: top._id("gen_ptp_real.u_ptp", extended=False)),
        ("top.u_ptp",
         lambda: top.u_ptp),
    ):
        try:
            h = getter()
        except Exception:
            continue
        if h is None:
            continue
        candidates.append((label, h))
    for label, h in candidates:
        try:
            _ = h.tx_state_r
            _PTP_HANDLE_CACHE[side] = h
            return h
        except Exception:
            continue
    if candidates:
        _PTP_HANDLE_CACHE[side] = candidates[0][1]
        return candidates[0][1]
    raise AttributeError(f"could not resolve u_ptp on side={side}")


def _probe(dut, side, name):
    try:
        h = _resolve_u_ptp(dut, side)
    except Exception:
        return -1
    try:
        sig = getattr(h, name)
        return int(sig.value)
    except (AttributeError, ValueError):
        return -1


async def _arm_master_hw_sync(tb):
    """Full pair bringup, then enable PTP on both sides, then fire
    master HW_SYNC_CTRL = 0x05 (force_en | enable).

    The pair tb_top hard-ties ``phc_nanoseconds = 30'h0`` on both sides
    (tb_top.sv:315, 526), which is the **same tie-off as the FPGA BD**
    (tidelink_design.tcl:43-44). HW_SYNC_INTERVAL is left at its reset
    default of 999_999_999 (tidelink_ptp.sv:359). Pre-patch this hits
    Bug B (FSM wedges in ARMED). Post-patch hw_sync_force_en_r bypasses
    phc_time_reached and the FSM advances to FIRE on the cycle after
    the CTRL write.
    """
    await run_bringup_full(tb)

    # Drop training on both sides.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    # Enable PTP on slave then master (slave first so the RX accept gate
    # is open before any SYNC arrives — mirrors test_ptp_corrected_regs).
    await tb.s_apb.write(APB_PTP_CTRL, PTP_CTRL_SLAVE_ENABLE)
    await tb.m_apb.write(APB_PTP_CTRL, PTP_CTRL_MASTER_GM_ENABLE)
    await ClockCycles(tb.dut.hclk, 100)

    # Fire HW_SYNC on master (force_en | enable). Per the proposed
    # patch this should make hw_sync_state_r advance ARMED → FIRE on
    # the first clock after the write commits, despite phc_nanoseconds
    # being tied to 0.
    await tb.m_apb.write(APB_HW_SYNC_CTRL, HW_SYNC_CTRL_FORCE_ENABLE)
    tb.log.info(
        f"  master HW_SYNC_CTRL <= 0x{HW_SYNC_CTRL_FORCE_ENABLE:02x} "
        "(force_en + enable)"
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_force_en_bypasses_phc_time_reached(dut):
    """**Bug B fix probe** — master ``ptp_sp_tx_valid`` must pulse high
    within 500 cy of the ``HW_SYNC_CTRL = 0x05`` write, with the pair
    tb_top's ``phc_nanoseconds = 0`` tie-off in place.

    Pre-fix this fails: phc_time_reached is permanently false because
    target_ns_r = 999_999_999 and phc_nanoseconds = 0. The HW_SYNC FSM
    wedges in ARMED (state code 1) and ptp_sp_tx_valid stays 0.

    Post-fix the new ``hw_sync_force_en_r`` term in phc_time_reached
    evaluates true on the cycle force_en_r latches, ARMED → FIRE fires
    on the next cycle, and ptp_sp_tx_valid pulses one cycle after the
    TX_WAIT_IDLE → TX_SEND transition (which itself bypasses
    tx_router_idle thanks to the existing line-260 bypass).
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)

    sp_tx_valid_pulses = 0
    armed_cycles      = 0
    fire_cycles       = 0
    wait_tx_cycles    = 0
    for _ in range(500):
        await RisingEdge(dut.hclk)
        if _probe(dut, "m", "ptp_sp_tx_valid") == 1:
            sp_tx_valid_pulses += 1
        state = _probe(dut, "m", "hw_sync_state_r")
        if state == 1:
            armed_cycles += 1
        elif state == 2:
            fire_cycles += 1
        elif state == 3:
            wait_tx_cycles += 1

    tb.log.info(
        f"  master 500 cy after HW_SYNC_CTRL write: "
        f"ptp_sp_tx_valid pulses={sp_tx_valid_pulses} "
        f"hw_sync_state ARMED={armed_cycles} FIRE={fire_cycles} "
        f"WAIT_TX={wait_tx_cycles}"
    )

    assert sp_tx_valid_pulses > 0, (
        f"Bug B reproduced (or patch missing): master ptp_sp_tx_valid "
        f"never pulsed in 500 cy after HW_SYNC_CTRL=0x05. "
        f"hw_sync_state occupancy ARMED={armed_cycles}/500 "
        f"FIRE={fire_cycles}/500 WAIT_TX={wait_tx_cycles}/500. "
        f"With the patch hw_sync_force_en_r should bypass "
        f"phc_time_reached (tidelink_ptp.sv:399-401)."
    )


@cocotb.test()
async def test_force_en_slave_receives_sync(dut):
    """**Bug B fix end-to-end probe** — after master fires HW_SYNC with
    force_en, the slave ``ptp_rx_valid_r`` must assert and stay latched
    within a generous settle window.

    Settle window = 5000 cy to cover the full pair pipeline:
        master TX_SEND → ShortPacketToWlink → Wlink LL → GPIO PHY
        → Wlink LL RX → ShortPacketFromWlink → slave ptp_sp_rx_valid
        → slave ptp_rx_valid_r latch

    The 5000 cy figure mirrors the long settle in
    test_ptp_corrected_regs._bringup_then_arm_ptp.
    """
    tb = PairTB(dut)
    await _arm_master_hw_sync(tb)

    # Long settle for end-to-end propagation.
    await ClockCycles(dut.hclk, 5000)

    s_rx_valid_r  = _probe(dut, "s", "ptp_rx_valid_r")
    s_rx_msg_type = _probe(dut, "s", "ptp_rx_msg_type_r")
    m_seq         = _probe(dut, "m", "hw_seq_num_int_r")
    m_hw_sync_status = await tb.m_apb.read(APB_HW_SYNC_STATUS)

    tb.log.info(
        f"  slave  ptp_rx_valid_r={s_rx_valid_r} "
        f"ptp_rx_msg_type_r={s_rx_msg_type}"
    )
    tb.log.info(
        f"  master hw_seq_num_int_r={m_seq} "
        f"HW_SYNC_STATUS=0x{m_hw_sync_status:08x}"
    )

    assert s_rx_valid_r == 1, (
        f"Slave ptp_rx_valid_r still 0 after 5000 cy. "
        f"Master HW_SYNC_STATUS=0x{m_hw_sync_status:08x} "
        f"(seq_num={(m_hw_sync_status >> 2) & 0xFFFF}). "
        f"Either Bug B is still in play (patch missing) or a "
        f"downstream pair-link bug is suppressing the SYNC packet."
    )
    # SYNC = msg_type 0 (DATA_ID_SYNC 0x50 decodes to rx_msg_type 4'h0
    # at tidelink_ptp.sv:297).
    assert s_rx_msg_type == 0, (
        f"Slave latched a packet but msg_type is {s_rx_msg_type}, "
        f"expected 0 (SYNC). Possible RX decode regression."
    )
