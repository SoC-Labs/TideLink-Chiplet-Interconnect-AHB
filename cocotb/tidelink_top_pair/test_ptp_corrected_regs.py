"""Paired-die cocotb tests targeting **Bug B** using the corrected PTP
slave-RX visibility registers identified in
``docs/HANDOFF_REPORT_2026_05_29.md §9`` and supported by
``src/rtl/tidelink_ptp.sv:520-547``.

The original Bug B repro (``test_09`` in
``test_tidelink_pair_doorbell.py``) polls ``HW_SYNC_STATUS @ 0x048``,
which is the **initiator-side** state (``hw_sync_en_r``, ``hw_seq_num``,
``phc_locked``). The slave never enables HW_SYNC, so reading 0 there is
expected behaviour, not a bug. Worse, ``tb_top.sv`` ties
``phc_locked_i = 1'b1`` on both sides, so the slave register reads
``0x00040000`` (bit[18]=phc_locked) and the existing ``s_status != 0``
assertion passes spuriously even when zero PTP traffic crosses the link.

The correct slave-RX surfaces are:

* ``PTP_STATUS @ 0x03C`` — register layout (Region 1, 3'h7) per
  ``tidelink_ptp.sv:548``::

      [0] tx_router_idle
      [1] tx_pending_r

  But ``tidelink_ptp.sv:546`` shows the **other** Region 1 entry at
  ``0x034`` (PTP_CTRL) embeds the receive activity:

      [0]    ptp_enable_r
      [1]    1'b0
      [2]    ptp_rx_valid_r            <- slave RX activity surface
      [6:3]  ptp_rx_msg_type_r

  The handoff doc (§9) calls the receive surface ``PTP_STATUS @ 0x03C
  bit[2]``. Empirically both ``tidelink_ptp.sv:546`` (RD of 0x034) and
  the doc point at the same ``ptp_rx_valid_r`` signal — this file
  exercises **both** offsets and the test will tell us which register
  decode actually exposes it on this RTL.

* ``PTP_RX_PAYLOAD @ 0x038`` — direct mirror of the last received
  sync-packet payload latch (``tidelink_ptp.sv:547``).

If Bug B is a real RX failure (per build #3 silicon evidence), the
``ptp_rx_valid_r`` bit and ``PTP_RX_PAYLOAD`` will both stay at zero
after the master fires HW_SYNC — these tests are therefore *expected to
FAIL today*, and the failure mode pinpoints the slave's PTP RX path as
the broken link.

This file **does not modify** ``test_tidelink_pair_doorbell.py`` (per
session constraint — other agents may diff it). It reuses the
``PairTB``/``run_bringup_full`` helpers via in-module import.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the existing pair-TB infrastructure verbatim. The base test file
# defines: PairTB, run_bringup_full, APB_* address constants. Importing
# keeps the bringup sequence identical to the canonical test_09 so any
# divergence is attributable to the new assertions, not the stimulus.
from test_tidelink_pair_doorbell import (  # noqa: E402
    PairTB,
    run_bringup_full,
    APB_TIDELINK_BASE,
    APB_PTP_CTRL,
    APB_HW_SYNC_CTRL,
    APB_HW_SYNC_STATUS,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)

# ---------------------------------------------------------------------------
# Corrected PTP slave-RX register offsets
# Per src/rtl/tidelink_ptp.sv:520-548 (Region 1)
#   3'h5 (0x034) PTP_CTRL       ─ on read: {msg_type[6:3], rx_valid[2], 0, enable[0]}
#   3'h6 (0x038) PTP_RX_PAYLOAD ─ ptp_rx_payload_r (last sync payload)
#   3'h7 (0x03C) PTP_STATUS     ─ {tx_pending_r, tx_router_idle}
#
# NOTE: the handoff doc (§9) attributes the "slave RX activity" bit to
# PTP_STATUS@0x03C bit[2]. Reading the RTL, ptp_rx_valid_r is actually
# mirrored at PTP_CTRL@0x034 bit[2]. Both are exercised below so the
# audit agent's downstream verification of the register decode is
# automatically catered for.
# ---------------------------------------------------------------------------
OFF_PTP_RX_PAYLOAD = 0x038
OFF_PTP_STATUS     = 0x03C

APB_PTP_RX_PAYLOAD = APB_TIDELINK_BASE + OFF_PTP_RX_PAYLOAD   # 0x2038
APB_PTP_STATUS     = APB_TIDELINK_BASE + OFF_PTP_STATUS       # 0x203C

# Master PTP_CTRL: ptp_enable_r=1, GM-mode initiator (bit[3]=1)  -> 0x09
# (Per docs/HANDOFF_REPORT_2026_05_29.md §6 item 5, bit 3 = GM initiator
# on the master.)
PTP_CTRL_MASTER_GM_ENABLE = 0x08 | 0x01    # GM | enable = 0x09 (spec: 0x08)
# Slave PTP_CTRL: ptp_enable_r=1 only
PTP_CTRL_SLAVE_ENABLE     = 0x01

# HW_SYNC_CTRL: force_en (bit[2]) | enable (bit[0]) — same as the
# build #3 sandwich loop and test_09.
HW_SYNC_CTRL_FORCE_ENABLE = 0x05


async def _bringup_then_arm_ptp(tb, master_ptp_ctrl=PTP_CTRL_MASTER_GM_ENABLE):
    """Full pair bringup + PTP arm, exactly as test_09 stages it but
    parameterised on the master PTP_CTRL value (test asks for both 0x08
    and 0x09 — 0x08 alone leaves ptp_enable_r=0, so default is 0x09).

    Returns the pair-bringup snapshot for the caller's logging.
    """
    snaps = await run_bringup_full(tb)

    # Belt-and-braces: drop training mode on both sides (run_bringup_full
    # already does this via do_to_data_mode, but explicit is fine).
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    # Slave first — open ptp_sp_rx_accept gate per tidelink_ptp.sv:288.
    await tb.s_apb.write(APB_PTP_CTRL, PTP_CTRL_SLAVE_ENABLE)
    # Master — GM-mode initiator + enable. The spec requested 0x08 but
    # tidelink_ptp.sv:476 latches hw_sync_en_r on bit[0]; without bit[0]
    # the TX path is parked. Override the caller param if it omitted
    # enable so the test always actually emits traffic.
    if (master_ptp_ctrl & 0x01) == 0:
        tb.log.info(
            f"  master PTP_CTRL=0x{master_ptp_ctrl:02x} missing enable bit; "
            "OR-ing 0x01 so the TX router actually runs"
        )
        master_ptp_ctrl |= 0x01
    await tb.m_apb.write(APB_PTP_CTRL, master_ptp_ctrl)
    await ClockCycles(tb.dut.hclk, 100)

    # Fire HW_SYNC on master (force_en + enable).
    await tb.m_apb.write(APB_HW_SYNC_CTRL, HW_SYNC_CTRL_FORCE_ENABLE)
    tb.log.info(
        f"  master HW_SYNC_CTRL <= 0x{HW_SYNC_CTRL_FORCE_ENABLE:02x} "
        "(force_en + enable)"
    )
    # Long settle so any sync packet has time to propagate end-to-end.
    await ClockCycles(tb.dut.hclk, 5000)
    return snaps


# ===========================================================================
# Hierarchical probe helpers — ShortPacket TX/RX path inside Wlink
#
# Path per deps/axi-chiplet-controller/logical/wlink/Wlink.v:1507
#   <side>.u_chiplet_controller.u_wlink.sp2wl  (ShortPacketToWlink)
# Signals exposed by ShortPacketToWlink.v after the (* mark_debug *)
# annotations at the SoC Labs ILA patch points:
#   tx_valid          : bore_2[25]
#   tx_fifo_io_wfull  : master TX-side back-pressure indicator
#   rx_pkt_valid      : auto_rx_in_valid & sop & dataIdMatch
#   dataIdMatch       : auto_rx_in_data_id == 8'h50 || 8'h51 (SYNC/DELAY_REQ)
# ===========================================================================
def _sp2wl(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.sp2wl


def _sp_tx_valid(dut, side):
    try:
        return int(_sp2wl(dut, side).tx_valid.value)
    except (AttributeError, ValueError):
        return -1


def _sp_tx_wfull(dut, side):
    try:
        return int(_sp2wl(dut, side).tx_fifo_io_wfull.value)
    except (AttributeError, ValueError):
        return -1


def _sp_tx_winc(dut, side):
    try:
        return int(_sp2wl(dut, side).tx_fifo_io_winc.value)
    except (AttributeError, ValueError):
        return -1


def _sp_rx_pkt_valid(dut, side):
    try:
        return int(_sp2wl(dut, side).rx_pkt_valid.value)
    except (AttributeError, ValueError):
        return -1


def _sp_rx_data_id_match(dut, side):
    try:
        return int(_sp2wl(dut, side).dataIdMatch.value)
    except (AttributeError, ValueError):
        return -1


def _sp_rx_in_valid(dut, side):
    try:
        return int(_sp2wl(dut, side).auto_rx_in_valid.value)
    except (AttributeError, ValueError):
        return -1


def _sp_rx_data_id(dut, side):
    try:
        return int(_sp2wl(dut, side).auto_rx_in_data_id.value)
    except (AttributeError, ValueError):
        return -1


def _sp_rx_winc(dut, side):
    try:
        return int(_sp2wl(dut, side).rx_fifo_io_winc.value)
    except (AttributeError, ValueError):
        return -1


async def _sample_short_packet_path(dut, log, n_cycles, label):
    """Sample the ShortPacket TX/RX path cycle-by-cycle on both sides
    and return aggregate cycle-counts. Mirrors the watch_fc_pulses
    helper but for the PTP-bearing short-packet port (not the FC
    application port — those are separate Wlink data_id channels).
    """
    m_tx_v = m_tx_wf = m_tx_w = 0
    s_rx_pv = s_rx_im = s_rx_iv = s_rx_w = 0
    s_rx_data_id_last = 0
    for _ in range(n_cycles):
        await RisingEdge(dut.hclk)
        if _sp_tx_valid(dut, "m") == 1:
            m_tx_v += 1
        if _sp_tx_wfull(dut, "m") == 1:
            m_tx_wf += 1
        if _sp_tx_winc(dut, "m") == 1:
            m_tx_w += 1
        if _sp_rx_pkt_valid(dut, "s") == 1:
            s_rx_pv += 1
        if _sp_rx_data_id_match(dut, "s") == 1:
            s_rx_im += 1
        if _sp_rx_in_valid(dut, "s") == 1:
            s_rx_iv += 1
            s_rx_data_id_last = _sp_rx_data_id(dut, "s")
        if _sp_rx_winc(dut, "s") == 1:
            s_rx_w += 1
    log.info(
        f"  [{label}] ShortPacket over {n_cycles} cy: "
        f"M.tx_valid={m_tx_v} M.tx_wfull={m_tx_wf} M.tx_winc={m_tx_w} | "
        f"S.rx_in_valid={s_rx_iv} S.dataIdMatch={s_rx_im} "
        f"S.rx_pkt_valid={s_rx_pv} S.rx_winc={s_rx_w} "
        f"S.last_data_id=0x{s_rx_data_id_last & 0xff:02x}"
    )
    return dict(
        m_tx_valid=m_tx_v, m_tx_wfull=m_tx_wf, m_tx_winc=m_tx_w,
        s_rx_in_valid=s_rx_iv, s_rx_data_id_match=s_rx_im,
        s_rx_pkt_valid=s_rx_pv, s_rx_winc=s_rx_w,
        s_rx_data_id_last=s_rx_data_id_last,
    )


# ===========================================================================
# Tests
# ===========================================================================

@cocotb.test()
async def test_ptp_rx_valid_bit_after_master_sync(dut):
    """**Bug B re-test with corrected register decode.**

    After full bringup, master writes ``PTP_CTRL=0x09`` (GM-mode +
    enable) and ``HW_SYNC_CTRL=0x05`` (force_en | enable). Slave writes
    ``PTP_CTRL=0x01``. Read slave ``PTP_STATUS @ 0x03C`` (handoff-doc
    surface) AND slave ``PTP_CTRL @ 0x034`` (RTL surface for
    ``ptp_rx_valid_r``) — assert that the rx-valid bit goes HIGH on at
    least one of them.

    Expected FAIL today if Bug B is a real slave-RX failure: neither
    surface will indicate rx-valid because no PTP sync packet ever
    crosses the link.
    """
    tb = PairTB(dut)
    await _bringup_then_arm_ptp(tb)

    s_ptp_status = await tb.s_apb.read(APB_PTP_STATUS)
    s_ptp_ctrl   = await tb.s_apb.read(APB_PTP_CTRL)
    m_ptp_status = await tb.m_apb.read(APB_PTP_STATUS)
    m_ptp_ctrl   = await tb.m_apb.read(APB_PTP_CTRL)
    tb.log.info(
        f"  slave  PTP_STATUS @ 0x03C = 0x{s_ptp_status:08x} "
        f"(bit[0]=tx_router_idle, bit[1]=tx_pending)"
    )
    tb.log.info(
        f"  slave  PTP_CTRL   @ 0x034 = 0x{s_ptp_ctrl:08x} "
        f"(bit[2]=ptp_rx_valid_r)"
    )
    tb.log.info(
        f"  master PTP_STATUS @ 0x03C = 0x{m_ptp_status:08x}  "
        f"master PTP_CTRL @ 0x034 = 0x{m_ptp_ctrl:08x}"
    )

    # The handoff doc says "PTP_STATUS @ 0x03C bit[2] = ptp_rx_valid_r"
    # — accept that surface OR the RTL surface (PTP_CTRL@0x034 bit[2]).
    rx_valid_via_status = (s_ptp_status >> 2) & 1
    rx_valid_via_ctrl   = (s_ptp_ctrl   >> 2) & 1

    assert rx_valid_via_status == 1 or rx_valid_via_ctrl == 1, (
        f"slave ptp_rx_valid_r is 0 on BOTH register surfaces: "
        f"PTP_STATUS[2]={rx_valid_via_status} (0x{s_ptp_status:08x}), "
        f"PTP_CTRL[2]={rx_valid_via_ctrl} (0x{s_ptp_ctrl:08x}). "
        f"Bug B reproduced: no sync packet reached the slave PTP module."
    )


@cocotb.test()
async def test_ptp_rx_payload_latched(dut):
    """After bringup + master HW_SYNC pulse, slave ``PTP_RX_PAYLOAD @
    0x038`` should contain the master's last sync payload. The payload
    is a 16-bit sequence number embedded in the short packet
    (``ptp_sp_tx_payload``) so the latched register should be non-zero
    after at least one sync packet is consumed.

    Expected FAIL today if Bug B is a real slave-RX failure: the latch
    stays at 0x00000000.
    """
    tb = PairTB(dut)
    await _bringup_then_arm_ptp(tb)

    # Snapshot slave's HW_SYNC_CTRL on the master so we have visibility of
    # the initiator-side sequence number for cross-reference.
    m_hw_sync = await tb.m_apb.read(APB_HW_SYNC_STATUS)
    s_hw_sync = await tb.s_apb.read(APB_HW_SYNC_STATUS)
    tb.log.info(
        f"  master HW_SYNC_STATUS = 0x{m_hw_sync:08x} "
        f"(seq_num[17:2]=0x{(m_hw_sync >> 2) & 0xFFFF:04x})"
    )
    tb.log.info(
        f"  slave  HW_SYNC_STATUS = 0x{s_hw_sync:08x} "
        f"(slave-init side; expected 0 modulo phc_locked@bit18)"
    )

    s_payload = await tb.s_apb.read(APB_PTP_RX_PAYLOAD)
    tb.log.info(f"  slave  PTP_RX_PAYLOAD @ 0x038 = 0x{s_payload:08x}")

    # Master *should* have incremented its seq_num at least once if the
    # HW_SYNC TX path is alive — log for context only, do not gate the
    # assertion on it (that is the role of test_short_packet_tx_path_alive).
    m_seq_num = (m_hw_sync >> 2) & 0xFFFF
    tb.log.info(f"  master observed TX seq_num = 0x{m_seq_num:04x}")

    assert s_payload != 0, (
        f"slave PTP_RX_PAYLOAD stuck at 0x00000000 after master HW_SYNC. "
        f"Bug B reproduced: payload never latched (master seq_num "
        f"reached 0x{m_seq_num:04x} but slave saw nothing)."
    )


@cocotb.test()
async def test_short_packet_tx_path_alive(dut):
    """Localise Bug B: is the **master** even emitting on the
    ShortPacketToWlink TX port? Probe ``tx_valid`` and
    ``tx_fifo_io_wfull`` (the SoC Labs ILA-marked nets in
    ``ShortPacketToWlink.v``) over a 5000-cycle window post-HW_SYNC.

    Pass criterion: master observes at least one ``tx_valid=1`` cycle
    OR one ``tx_fifo_io_winc=1`` cycle. If both stay at zero, the bug
    is upstream of Wlink in ``tidelink_ptp`` itself (TX router never
    fires).
    """
    tb = PairTB(dut)
    await _bringup_then_arm_ptp(tb)

    counts = await _sample_short_packet_path(
        dut, tb.log, 5000, "master TX path probe (5000 cy)"
    )

    assert counts["m_tx_valid"] > 0 or counts["m_tx_winc"] > 0, (
        f"master ShortPacket TX path silent: "
        f"tx_valid_cycles={counts['m_tx_valid']}, "
        f"tx_fifo_winc_cycles={counts['m_tx_winc']}. "
        f"PTP TX router never fired — bug is in master tidelink_ptp, "
        f"not the link. (tx_fifo_wfull cycles="
        f"{counts['m_tx_wfull']} — non-zero would point at TX-FIFO "
        f"back-pressure rather than a quiet router.)"
    )


@cocotb.test()
async def test_short_packet_rx_dataidmatch(dut):
    """Localise Bug B further down-stream: does the **slave** Wlink
    sp2wl see incoming short packets at all, and if so does the
    ``dataIdMatch`` filter accept them?

    ``ShortPacketToWlink.v:59`` defines::

        dataIdMatch = (auto_rx_in_data_id == 8'h50) | (auto_rx_in_data_id == 8'h51)
        rx_pkt_valid = auto_rx_in_valid & auto_rx_in_sop & dataIdMatch

    So:
      * ``auto_rx_in_valid=0`` for the whole window means no short
        packets reached the slave Wlink at all (link-layer dead for
        ShortPacket).
      * ``auto_rx_in_valid=1`` but ``dataIdMatch=0`` means the master is
        sending with a non-PTP data_id (encoder bug or wrong port
        binding).
      * ``rx_pkt_valid=1`` with ``rx_fifo_io_winc=0`` would point at FIFO
        full / consumer stall — separate bug class.

    Pass criterion: ``rx_pkt_valid`` toggles at least once during the
    sample window. Fail otherwise, with the dataId / valid pair logged
    so the next pass can tell which sub-mode of Bug B is in play.
    """
    tb = PairTB(dut)
    await _bringup_then_arm_ptp(tb)

    counts = await _sample_short_packet_path(
        dut, tb.log, 5000, "slave RX path probe (5000 cy)"
    )

    # Hard fail with the specific sub-mode identified.
    if counts["s_rx_in_valid"] == 0:
        msg = (
            "slave sp2wl saw NO RX valid cycles at all over 5000 cy — "
            "ShortPacket data never reached the slave Wlink. Link-layer "
            "ShortPacket path is silent."
        )
    elif counts["s_rx_data_id_match"] == 0:
        msg = (
            f"slave sp2wl received {counts['s_rx_in_valid']} RX valid "
            f"cycles but dataIdMatch was 0 for all of them "
            f"(last seen data_id=0x{counts['s_rx_data_id_last']:02x}). "
            f"Master is sending with a non-PTP data_id (expected 0x50/0x51)."
        )
    elif counts["s_rx_pkt_valid"] == 0:
        msg = (
            f"slave sp2wl saw dataIdMatch=1 for "
            f"{counts['s_rx_data_id_match']} cycles but rx_pkt_valid=0 "
            "throughout — sop alignment broken on the RX path."
        )
    elif counts["s_rx_winc"] == 0:
        msg = (
            f"slave sp2wl saw rx_pkt_valid=1 for "
            f"{counts['s_rx_pkt_valid']} cycles but rx_fifo_io_winc never "
            "asserted — RX FIFO full or consumer-side stall."
        )
    else:
        msg = None

    assert msg is None, msg
