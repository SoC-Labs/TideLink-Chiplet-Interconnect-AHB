"""Bug A — Delivery-path localization sweep.

Prior agent (docs/BUG_A_NACK_PREDICATE_SIM_2026_06_01.md) falsified the
NACK loop on the slave RX: pkt_is_data_pkt asserted 26 cy, isExpPacket
25 cy, send_nack_req never fired. So the wedge is NOT in the FCSM NACK
decode — it is either:

  1) DELIVERY: slave RX framer decodes data but the fc_replay app-side
     handshake never advances to the slave fc_adapter, or
  2) MASTER TX: master never put the data on the link in the first
     place (credit gate, a2l_full backpressure, FCSM stuck below
     LINK_DATA), or
  3) SIDEBAND-MISROUTE: pkt_type[47:46] gets corrupted so the slave
     fc_adapter routes a FIFO write down the cfg/APB path or vice versa.

ONE focused test that snapshots BOTH paths concurrently while a single
AHB write drives a PKT_WR_REQ of length=2 (i.e. 2 payload words +
word0+dest = 4 AHB transfers).

Read-only. Reuses PairTB + run_bringup_full. No wave dump.

Run::

  source /home/dam1n19/SoCLabs/tidelink/set_env.sh
  cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
  timeout 900 make MODULE=test_buga_delivery_path \\
      SIM_BUILD=sim_build_delivery TB_TOP_NO_DUMP=1
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
# Hierarchical helpers (mirrors test_buga_nack_predicates style).
# ---------------------------------------------------------------------------

def _fcsm(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _fc_adapter(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_fc_adapter


def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _safe(sig):
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


def _safe_data(sig):
    """Capture full data word without truncation; returns -1 on X/Z."""
    if sig is None:
        return -1
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return -1


def _opt(scope, name):
    s = getattr(scope, name, None)
    if s is not None:
        return s
    try:
        return scope._id(name, extended=False)
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------
# Probe metadata
# ---------------------------------------------------------------------------

# Master-side TX probes (all reachable inside wlink_tidelinktl).
MASTER_FCSM_PROBES = [
    "a2l_fc_replay_app_valid",
    "a2l_fc_replay_app_ready",
    "a2l_fc_replay_link_valid",
    "a2l_fc_replay_link_advance",
    "fe_tx_credit_max",
    "fe_rx_credit_max",
    "pkt_is_cr_pkt",
    "pkt_is_crack_pkt",
    "cr_pkt_seen_rx",
    "crack_pkt_seen_rx",
]

# Slave-side RX delivery probes inside the FCSM.
SLAVE_FCSM_PROBES = [
    "l2a_fc_replay_app_valid",
    "l2a_fc_replay_app_data",
    "l2a_fc_replay_link_valid",
    "l2a_fc_replay_link_advance",
    "exp_pkt_num",
    "ll_rx_pktnum",
    "pkt_is_data_pkt",
    "isExpPacket",
]


PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]
OBSERVE_WINDOW_CY = 800
TEST_TIMEOUT_NS = 50_000_000


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    # words[1] = dest addr (FIFO base offset 0 inside peer's FIFO region).
    return [word0, 0x0] + PAYLOAD


# ===========================================================================
# Test
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_delivery_path(dut):
    tb = PairTB(dut)
    await run_bringup_full(tb)

    # Ensure no training is active.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    m_fcsm = _fcsm(dut, "m")
    s_fcsm = _fcsm(dut, "s")
    m_fc   = _fc_adapter(dut, "m")
    s_fc   = _fc_adapter(dut, "s")
    m_top  = _top(dut, "m")
    s_top  = _top(dut, "s")

    # --- Probe resolution ---------------------------------------------------
    m_fcsm_probes = {n: _opt(m_fcsm, n) for n in MASTER_FCSM_PROBES}
    s_fcsm_probes = {n: _opt(s_fcsm, n) for n in SLAVE_FCSM_PROBES}

    # FC-adapter / top-level probes — names match the RTL ports.
    m_tl_fc_a2l_valid = _opt(m_fc, "tl_fc_a2l_valid")
    m_tl_fc_a2l_ready = _opt(m_fc, "tl_fc_a2l_ready")
    m_tl_fc_a2l_data  = _opt(m_fc, "tl_fc_a2l_data")

    s_tl_fc_l2a_valid  = _opt(s_fc, "tl_fc_l2a_valid")
    s_tl_fc_l2a_accept = _opt(s_fc, "tl_fc_l2a_accept")
    s_tl_fc_l2a_data   = _opt(s_fc, "tl_fc_l2a_data")

    s_fc_rx_fifo_valid = _opt(s_fc, "fc_rx_fifo_valid")
    s_fc_rx_fifo_addr  = _opt(s_fc, "fc_rx_fifo_addr")
    s_fc_rx_cfg_psel   = _opt(s_fc, "fc_rx_cfg_psel")
    s_fc_rx_cfg_paddr  = _opt(s_fc, "fc_rx_cfg_paddr")

    unresolved = []
    for n, h in m_fcsm_probes.items():
        if h is None: unresolved.append(f"m_fcsm.{n}")
    for n, h in s_fcsm_probes.items():
        if h is None: unresolved.append(f"s_fcsm.{n}")
    for n, h in dict(
        m_tl_fc_a2l_valid=m_tl_fc_a2l_valid,
        m_tl_fc_a2l_ready=m_tl_fc_a2l_ready,
        m_tl_fc_a2l_data=m_tl_fc_a2l_data,
        s_tl_fc_l2a_valid=s_tl_fc_l2a_valid,
        s_tl_fc_l2a_accept=s_tl_fc_l2a_accept,
        s_tl_fc_l2a_data=s_tl_fc_l2a_data,
        s_fc_rx_fifo_valid=s_fc_rx_fifo_valid,
        s_fc_rx_fifo_addr=s_fc_rx_fifo_addr,
        s_fc_rx_cfg_psel=s_fc_rx_cfg_psel,
        s_fc_rx_cfg_paddr=s_fc_rx_cfg_paddr,
    ).items():
        if h is None: unresolved.append(n)
    if unresolved:
        dut._log.warning(f"  Unresolved probes: {unresolved}")
    else:
        dut._log.info("  All delivery-path probes resolved.")

    # --- Pre-AHB snapshot ---------------------------------------------------
    dut._log.info(
        f"  PRE-AHB  M.fe_tx_credit_max={_safe(m_fcsm_probes['fe_tx_credit_max'])}  "
        f"M.fe_rx_credit_max={_safe(m_fcsm_probes['fe_rx_credit_max'])}  "
        f"M.cr_pkt_seen_rx={_safe(m_fcsm_probes['cr_pkt_seen_rx'])}  "
        f"M.crack_pkt_seen_rx={_safe(m_fcsm_probes['crack_pkt_seen_rx'])}"
    )
    dut._log.info(
        f"  PRE-AHB  S.exp_pkt_num={_safe(s_fcsm_probes['exp_pkt_num'])}  "
        f"S.ll_rx_pktnum={_safe(s_fcsm_probes['ll_rx_pktnum'])}"
    )

    # --- Watcher state ------------------------------------------------------
    first_cy = {}  # name -> first 1-based cycle observed HIGH
    high_cy  = {}
    for n in MASTER_FCSM_PROBES + SLAVE_FCSM_PROBES + [
        "M.tl_fc_a2l_valid",
        "M.tl_fc_a2l_ready",
        "S.tl_fc_l2a_valid",
        "S.tl_fc_l2a_accept",
        "S.fc_rx_fifo_valid",
        "S.fc_rx_cfg_psel",
    ]:
        first_cy[n] = -1
        high_cy[n] = 0

    # First-fire captures: data + pkt_type at the cycle each is first high.
    first_m_a2l_valid_cy = -1
    first_m_a2l_valid_data = -1
    first_m_a2l_valid_pkttype = -1

    first_s_l2a_valid_cy = -1
    first_s_l2a_valid_data = -1
    first_s_l2a_valid_pkttype = -1

    first_s_replay_app_valid_cy = -1
    first_s_replay_app_data = -1
    first_s_replay_app_pkttype = -1

    first_fc_rx_fifo_valid_cy = -1
    first_fc_rx_cfg_psel_cy = -1
    first_fc_rx_fifo_addr   = -1
    first_fc_rx_cfg_paddr   = -1

    # Stuck-detector: cycle where M.tl_fc_a2l_valid is high but
    # M.tl_fc_a2l_ready is low → master a2l skid backpressured.
    a2l_stall_cycles = 0

    async def watcher():
        nonlocal first_m_a2l_valid_cy, first_m_a2l_valid_data
        nonlocal first_m_a2l_valid_pkttype
        nonlocal first_s_l2a_valid_cy, first_s_l2a_valid_data
        nonlocal first_s_l2a_valid_pkttype
        nonlocal first_s_replay_app_valid_cy, first_s_replay_app_data
        nonlocal first_s_replay_app_pkttype
        nonlocal first_fc_rx_fifo_valid_cy, first_fc_rx_cfg_psel_cy
        nonlocal first_fc_rx_fifo_addr, first_fc_rx_cfg_paddr
        nonlocal a2l_stall_cycles

        cy = 0
        while True:
            await RisingEdge(dut.hclk)
            cy += 1

            # Sample 1-bit lanes for first_cy/high_cy
            for n, h in m_fcsm_probes.items():
                if n in ("fe_tx_credit_max", "fe_rx_credit_max"):
                    continue  # multi-bit
                v = _safe(h)
                if v == 1:
                    high_cy[n] += 1
                    if first_cy[n] < 0:
                        first_cy[n] = cy
            for n, h in s_fcsm_probes.items():
                if n in ("l2a_fc_replay_app_data", "exp_pkt_num",
                         "ll_rx_pktnum"):
                    continue  # multi-bit
                v = _safe(h)
                if v == 1:
                    high_cy[n] += 1
                    if first_cy[n] < 0:
                        first_cy[n] = cy

            # Top-level 1-bit lanes
            m_av = _safe(m_tl_fc_a2l_valid)
            m_ar = _safe(m_tl_fc_a2l_ready)
            s_lv = _safe(s_tl_fc_l2a_valid)
            s_la = _safe(s_tl_fc_l2a_accept)
            s_fv = _safe(s_fc_rx_fifo_valid)
            s_cs = _safe(s_fc_rx_cfg_psel)

            for n, v in (("M.tl_fc_a2l_valid", m_av),
                         ("M.tl_fc_a2l_ready", m_ar),
                         ("S.tl_fc_l2a_valid", s_lv),
                         ("S.tl_fc_l2a_accept", s_la),
                         ("S.fc_rx_fifo_valid", s_fv),
                         ("S.fc_rx_cfg_psel", s_cs)):
                if v == 1:
                    high_cy[n] += 1
                    if first_cy[n] < 0:
                        first_cy[n] = cy

            # First-fire data captures
            if m_av == 1 and first_m_a2l_valid_cy < 0:
                first_m_a2l_valid_cy = cy
                d = _safe_data(m_tl_fc_a2l_data)
                first_m_a2l_valid_data = d
                if d >= 0:
                    first_m_a2l_valid_pkttype = (d >> 46) & 0x3

            if s_lv == 1 and first_s_l2a_valid_cy < 0:
                first_s_l2a_valid_cy = cy
                d = _safe_data(s_tl_fc_l2a_data)
                first_s_l2a_valid_data = d
                if d >= 0:
                    first_s_l2a_valid_pkttype = (d >> 46) & 0x3

            s_rav = _safe(s_fcsm_probes["l2a_fc_replay_app_valid"])
            if s_rav == 1 and first_s_replay_app_valid_cy < 0:
                first_s_replay_app_valid_cy = cy
                d = _safe_data(s_fcsm_probes["l2a_fc_replay_app_data"])
                first_s_replay_app_data = d
                if d >= 0:
                    first_s_replay_app_pkttype = (d >> 46) & 0x3

            if s_fv == 1 and first_fc_rx_fifo_valid_cy < 0:
                first_fc_rx_fifo_valid_cy = cy
                first_fc_rx_fifo_addr = _safe(s_fc_rx_fifo_addr)

            if s_cs == 1 and first_fc_rx_cfg_psel_cy < 0:
                first_fc_rx_cfg_psel_cy = cy
                first_fc_rx_cfg_paddr = _safe(s_fc_rx_cfg_paddr)

            # Stuck-detector: master a2l valid but ready low.
            if m_av == 1 and m_ar == 0:
                a2l_stall_cycles += 1

    w = cocotb.start_soon(watcher())

    # --- Drive the AHB write -----------------------------------------------
    words = _packet_words()
    dut._log.info(f"  AHB write: {[hex(x) for x in words]}")
    await tb.ahb_tx_write_packet("m", words)

    await ClockCycles(dut.hclk, OBSERVE_WINDOW_CY)
    w.kill()

    # --- Post snapshot ------------------------------------------------------
    dut._log.info(
        f"  POST     M.fe_tx_credit_max={_safe(m_fcsm_probes['fe_tx_credit_max'])}  "
        f"S.exp_pkt_num={_safe(s_fcsm_probes['exp_pkt_num'])}  "
        f"S.ll_rx_pktnum={_safe(s_fcsm_probes['ll_rx_pktnum'])}"
    )

    pkt_word_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    dut._log.info(f"  S.REG_PKT_WORD_LEN = 0x{int(pkt_word_len):08x}")

    # =====================================================================
    # Reporting
    # =====================================================================
    dut._log.info("================================================================")
    dut._log.info("  DELIVERY PATH PROBE TABLE (cycles relative to AHB write start)")
    dut._log.info("  signal                                 first_high   total_high")
    dut._log.info("  -------------------------------------- ----------   ----------")
    order = [
        # master FCSM
        "a2l_fc_replay_app_valid",
        "a2l_fc_replay_app_ready",
        "a2l_fc_replay_link_valid",
        "a2l_fc_replay_link_advance",
        "pkt_is_cr_pkt",
        "pkt_is_crack_pkt",
        "cr_pkt_seen_rx",
        "crack_pkt_seen_rx",
        # master top
        "M.tl_fc_a2l_valid",
        "M.tl_fc_a2l_ready",
        # slave FCSM
        "l2a_fc_replay_app_valid",
        "l2a_fc_replay_link_valid",
        "l2a_fc_replay_link_advance",
        "pkt_is_data_pkt",
        "isExpPacket",
        # slave top
        "S.tl_fc_l2a_valid",
        "S.tl_fc_l2a_accept",
        # slave fc_adapter dest
        "S.fc_rx_fifo_valid",
        "S.fc_rx_cfg_psel",
    ]
    for n in order:
        dut._log.info(f"  {n:<38} {first_cy.get(n, -1):>10}   {high_cy.get(n, 0):>10}")
    dut._log.info("================================================================")

    dut._log.info(
        f"  M.tl_fc_a2l first fire: cy={first_m_a2l_valid_cy}  "
        f"data=0x{first_m_a2l_valid_data:012x}  "
        f"pkt_type[47:46]={first_m_a2l_valid_pkttype}"
        if first_m_a2l_valid_cy > 0 else
        "  M.tl_fc_a2l NEVER fired during observation window."
    )
    dut._log.info(
        f"  S.tl_fc_l2a first fire: cy={first_s_l2a_valid_cy}  "
        f"data=0x{first_s_l2a_valid_data:012x}  "
        f"pkt_type[47:46]={first_s_l2a_valid_pkttype}"
        if first_s_l2a_valid_cy > 0 else
        "  S.tl_fc_l2a NEVER fired during observation window."
    )
    dut._log.info(
        f"  S.l2a_fc_replay_app first fire: cy={first_s_replay_app_valid_cy}  "
        f"data=0x{first_s_replay_app_data:012x}  "
        f"pkt_type[47:46]={first_s_replay_app_pkttype}"
        if first_s_replay_app_valid_cy > 0 else
        "  S.l2a_fc_replay_app_valid NEVER fired."
    )
    dut._log.info(
        f"  S.fc_rx_fifo_valid first fire: cy={first_fc_rx_fifo_valid_cy}  "
        f"addr=0x{first_fc_rx_fifo_addr:x}"
        if first_fc_rx_fifo_valid_cy > 0 else
        "  S.fc_rx_fifo_valid NEVER fired (FIFO write-enable absent)."
    )
    dut._log.info(
        f"  S.fc_rx_cfg_psel first fire: cy={first_fc_rx_cfg_psel_cy}  "
        f"paddr=0x{first_fc_rx_cfg_paddr:x}"
        if first_fc_rx_cfg_psel_cy > 0 else
        "  S.fc_rx_cfg_psel NEVER fired (no sideband-APB misroute)."
    )

    dut._log.info(f"  M.a2l stall cycles (valid&!ready): {a2l_stall_cycles}")

    # =====================================================================
    # Verdict
    # =====================================================================
    dut._log.info("================================================================")
    if first_m_a2l_valid_cy < 0:
        verdict = "MASTER_TX_WEDGED__tl_fc_a2l_valid_never_fired"
    elif first_s_l2a_valid_cy < 0:
        verdict = "LINK_DELIVERY_BROKEN__slave_tl_fc_l2a_valid_never_fired"
    elif first_s_replay_app_valid_cy < 0:
        verdict = "SLAVE_FCSM_NEVER_DELIVERED_TO_APP__l2a_fc_replay_app_valid_never_high"
    elif first_fc_rx_fifo_valid_cy < 0 and first_fc_rx_cfg_psel_cy >= 0:
        verdict = "SIDEBAND_MISROUTE__data_landed_in_cfg_apb_path"
    elif first_fc_rx_fifo_valid_cy < 0:
        verdict = "FC_ADAPTER_RX_FSM_WEDGE__no_fifo_write_and_no_cfg_psel"
    else:
        verdict = "DATA_REACHED_FIFO__check_pkt_word_len_or_doorbell_path"
    dut._log.info(f"  VERDICT: {verdict}")
    dut._log.info("================================================================")

    # Instrumentation only — no assertion on path correctness, only
    # sanity that probes resolved.
    assert _safe(m_fcsm_probes["fe_tx_credit_max"]) >= 0, \
        "master fe_tx_credit_max probe failed (-1)"
