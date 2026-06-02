"""Bug A — Address-collapse probe.

Prior probes (docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md) showed:

  - master TX fires 4× on tl_fc_a2l_valid
  - slave RX delivers 4× as FIFO_DATA (pkt_type=00)
  - slave fc_rx_fifo_valid fires 4× with fc_rx_fifo_addr=0x0
  - REG_PKT_WORD_LEN reads 0 (FIFO writes never accumulated as a packet)

Hypothesis: ALL 4 master writes encode addr_offset=0, so all 4 land on
slot 0 of the slave FIFO and packet_word_length never increments.

ONE focused test that traces the address transit through the FC 48-bit
word for every AHB transfer of a single PKT_WR_REQ packet, plus
fc_rx_fifo_addr on the slave side. Read-only RTL. Reuses PairTB +
run_bringup_full. No wave dump.

Run::

  source /home/dam1n19/SoCLabs/tidelink/set_env.sh
  cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
  timeout 900 make MODULE=test_buga_addr_collapse \\
      SIM_BUILD=sim_build_addr_collapse TB_TOP_NO_DUMP=1
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
# Hierarchical helpers
# ---------------------------------------------------------------------------

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


def _opt(scope, name):
    s = getattr(scope, name, None)
    if s is not None:
        return s
    try:
        return scope._id(name, extended=False)
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------
# Test config
# ---------------------------------------------------------------------------

PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]
OBSERVE_WINDOW_CY = 800
TEST_TIMEOUT_NS = 50_000_000


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    # words[1] = dest addr inside peer FIFO; PAYLOAD = N data words.
    return [word0, 0x0] + PAYLOAD


def _pkt_type_name(t):
    return {0: "FIFO_DATA", 1: "SIDEBAND", 2: "EXT", 3: "RSVD"}.get(t & 0x3, "?")


# ===========================================================================
# Test
# ===========================================================================
@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_addr_collapse(dut):
    tb = PairTB(dut)
    await run_bringup_full(tb)

    # Disable training.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    m_fc = _fc_adapter(dut, "m")
    s_fc = _fc_adapter(dut, "s")
    m_top = _top(dut, "m")
    s_top = _top(dut, "s")

    # --- Probe resolution -------------------------------------------------
    # Master TX construction probes
    m_ahb_tx_haddr        = _opt(m_fc, "ahb_tx_haddr")
    m_ahb_tx_hwdata       = _opt(m_fc, "ahb_tx_hwdata")
    m_tx_valid_addr_phase = _opt(m_fc, "tx_valid_addr_phase")
    m_tx_addr_r           = _opt(m_fc, "tx_addr_r")
    m_tx_data_phase_r     = _opt(m_fc, "tx_data_phase_r")
    m_tx_fc_word          = _opt(m_fc, "tx_fc_word")
    m_tl_fc_a2l_valid     = _opt(m_fc, "tl_fc_a2l_valid")
    m_tl_fc_a2l_ready     = _opt(m_fc, "tl_fc_a2l_ready")
    m_tl_fc_a2l_data      = _opt(m_fc, "tl_fc_a2l_data")

    # Slave RX delivery probes
    s_tl_fc_l2a_valid  = _opt(s_fc, "tl_fc_l2a_valid")
    s_tl_fc_l2a_accept = _opt(s_fc, "tl_fc_l2a_accept")
    s_tl_fc_l2a_data   = _opt(s_fc, "tl_fc_l2a_data")
    s_rx_fc_word_r     = _opt(s_fc, "rx_fc_word_r")
    s_rx_addr_offset   = _opt(s_fc, "rx_addr_offset")
    s_rx_pkt_type      = _opt(s_fc, "rx_pkt_type")
    s_rx_payload       = _opt(s_fc, "rx_payload")
    s_fc_rx_fifo_valid = _opt(s_fc, "fc_rx_fifo_valid")
    s_fc_rx_fifo_addr  = _opt(s_fc, "fc_rx_fifo_addr")
    s_fc_rx_fifo_wdata = _opt(s_fc, "fc_rx_fifo_wdata")

    probes = dict(
        m_ahb_tx_haddr=m_ahb_tx_haddr,
        m_tx_valid_addr_phase=m_tx_valid_addr_phase,
        m_tx_addr_r=m_tx_addr_r,
        m_tx_data_phase_r=m_tx_data_phase_r,
        m_tx_fc_word=m_tx_fc_word,
        m_tl_fc_a2l_valid=m_tl_fc_a2l_valid,
        m_tl_fc_a2l_ready=m_tl_fc_a2l_ready,
        m_tl_fc_a2l_data=m_tl_fc_a2l_data,
        s_tl_fc_l2a_valid=s_tl_fc_l2a_valid,
        s_tl_fc_l2a_data=s_tl_fc_l2a_data,
        s_rx_fc_word_r=s_rx_fc_word_r,
        s_rx_addr_offset=s_rx_addr_offset,
        s_rx_pkt_type=s_rx_pkt_type,
        s_fc_rx_fifo_valid=s_fc_rx_fifo_valid,
        s_fc_rx_fifo_addr=s_fc_rx_fifo_addr,
        s_fc_rx_fifo_wdata=s_fc_rx_fifo_wdata,
    )
    unresolved = [n for n, h in probes.items() if h is None]
    if unresolved:
        dut._log.warning(f"  Unresolved probes: {unresolved}")
    else:
        dut._log.info("  All address-collapse probes resolved.")

    # --- Watcher state ----------------------------------------------------
    m_addr_phase_trace = []   # list of (cy, haddr) when tx_valid_addr_phase=1
    m_a2l_fire_trace   = []   # list of (cy, data) when tl_fc_a2l_valid&ready
    s_l2a_fire_trace   = []   # list of (cy, data) when tl_fc_l2a_valid&accept
    s_fifo_wr_trace    = []   # list of (cy, addr, wdata) when fc_rx_fifo_valid

    async def watcher():
        cy = 0
        prev_m_av = 0
        prev_s_lv = 0
        prev_s_fv = 0
        while True:
            await RisingEdge(dut.hclk)
            cy += 1

            # Master TX addr phase pulse
            if _safe(m_tx_valid_addr_phase) == 1:
                m_addr_phase_trace.append(
                    (cy, _safe(m_ahb_tx_haddr), _safe(m_ahb_tx_hwdata))
                )

            # Master TX a2l fire — sample on the cycle valid&ready both high.
            m_av = _safe(m_tl_fc_a2l_valid)
            m_ar = _safe(m_tl_fc_a2l_ready)
            if m_av == 1 and m_ar == 1:
                d = _safe(m_tl_fc_a2l_data)
                m_a2l_fire_trace.append((cy, d))
            prev_m_av = m_av

            # Slave RX l2a fire — valid&accept both high (handoff completed).
            s_lv = _safe(s_tl_fc_l2a_valid)
            s_la = _safe(s_tl_fc_l2a_accept)
            if s_lv == 1 and s_la == 1:
                d = _safe(s_tl_fc_l2a_data)
                s_l2a_fire_trace.append((cy, d))
            prev_s_lv = s_lv

            # Slave fc_rx_fifo write pulse
            s_fv = _safe(s_fc_rx_fifo_valid)
            if s_fv == 1:
                s_fifo_wr_trace.append(
                    (cy, _safe(s_fc_rx_fifo_addr), _safe(s_fc_rx_fifo_wdata))
                )
            prev_s_fv = s_fv

    w = cocotb.start_soon(watcher())

    # --- Drive the AHB packet ---------------------------------------------
    words = _packet_words()
    dut._log.info("================================================================")
    dut._log.info("  AHB write sequence (offset:value):")
    for i, w_ in enumerate(words):
        dut._log.info(f"    {i*4:#04x}: 0x{w_:08x}")
    dut._log.info("================================================================")
    await tb.ahb_tx_write_packet("m", words)

    await ClockCycles(dut.hclk, OBSERVE_WINDOW_CY)
    w.kill()

    # --- Post APB read ----------------------------------------------------
    pkt_word_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    dut._log.info(f"  S.REG_PKT_WORD_LEN = 0x{int(pkt_word_len):08x}")

    # =====================================================================
    # Reporting
    # =====================================================================
    dut._log.info("================================================================")
    dut._log.info("  MASTER TX addr-phase trace (each AHB transfer):")
    dut._log.info("    cycle   ahb_tx_haddr   ahb_tx_hwdata")
    dut._log.info("    -----   ------------   -------------")
    for (cy, ha, hw) in m_addr_phase_trace:
        dut._log.info(f"    {cy:>5}   0x{ha & 0x3FFF:08x}     0x{hw & 0xFFFFFFFF:08x}")

    dut._log.info("================================================================")
    dut._log.info("  MASTER tl_fc_a2l fires (valid&ready):")
    dut._log.info("    cycle   pkt_type  addr_offset   payload      48-bit word")
    dut._log.info("    -----   --------  -----------   --------     -----------")
    for (cy, d) in m_a2l_fire_trace:
        if d < 0:
            dut._log.info(f"    {cy:>5}   <X/Z>")
            continue
        pt   = (d >> 46) & 0x3
        ao   = (d >> 32) & 0x3FFF
        pyld = d & 0xFFFFFFFF
        dut._log.info(
            f"    {cy:>5}   {pt}={_pkt_type_name(pt):<8}  0x{ao:04x}        "
            f"0x{pyld:08x}   0x{d & ((1<<48)-1):012x}"
        )

    dut._log.info("================================================================")
    dut._log.info("  SLAVE tl_fc_l2a fires (valid&accept):")
    dut._log.info("    cycle   pkt_type  addr_offset   payload      48-bit word")
    dut._log.info("    -----   --------  -----------   --------     -----------")
    for (cy, d) in s_l2a_fire_trace:
        if d < 0:
            dut._log.info(f"    {cy:>5}   <X/Z>")
            continue
        pt   = (d >> 46) & 0x3
        ao   = (d >> 32) & 0x3FFF
        pyld = d & 0xFFFFFFFF
        dut._log.info(
            f"    {cy:>5}   {pt}={_pkt_type_name(pt):<8}  0x{ao:04x}        "
            f"0x{pyld:08x}   0x{d & ((1<<48)-1):012x}"
        )

    dut._log.info("================================================================")
    dut._log.info("  SLAVE fc_rx_fifo_valid pulses (final FIFO write side):")
    dut._log.info("    cycle   fc_rx_fifo_addr   fc_rx_fifo_wdata")
    dut._log.info("    -----   ---------------   ----------------")
    for (cy, ad, wd) in s_fifo_wr_trace:
        dut._log.info(
            f"    {cy:>5}   0x{ad & 0x3FFF:04x}              0x{wd & 0xFFFFFFFF:08x}"
        )
    dut._log.info("================================================================")

    # =====================================================================
    # Verdict
    # =====================================================================
    # Build a per-stage addr-list for comparison.
    m_addr_phase_addrs = [ha & 0x3FFF for (_, ha, _) in m_addr_phase_trace]
    m_a2l_addrs = []
    for (_, d) in m_a2l_fire_trace:
        if d < 0:
            continue
        if ((d >> 46) & 0x3) == 0:  # FIFO_DATA only
            m_a2l_addrs.append((d >> 32) & 0x3FFF)
    s_l2a_addrs = []
    for (_, d) in s_l2a_fire_trace:
        if d < 0:
            continue
        if ((d >> 46) & 0x3) == 0:
            s_l2a_addrs.append((d >> 32) & 0x3FFF)
    s_fifo_addrs = [ad & 0x3FFF for (_, ad, _) in s_fifo_wr_trace]

    dut._log.info("  Address-list summary (FIFO_DATA only):")
    dut._log.info(f"    m_addr_phase  : {[hex(a) for a in m_addr_phase_addrs]}")
    dut._log.info(f"    m_tl_fc_a2l   : {[hex(a) for a in m_a2l_addrs]}")
    dut._log.info(f"    s_tl_fc_l2a   : {[hex(a) for a in s_l2a_addrs]}")
    dut._log.info(f"    s_fc_rx_fifo  : {[hex(a) for a in s_fifo_addrs]}")

    def all_zero(xs):
        return len(xs) > 0 and all(x == 0 for x in xs)

    def unique(xs):
        return len(set(xs)) > 1

    if not m_a2l_addrs:
        verdict = "NO_MASTER_TX_FIRE__a2l_never_fired_with_FIFO_DATA"
    elif all_zero(m_a2l_addrs):
        if unique(m_addr_phase_addrs):
            verdict = "MASTER_TX_ADDR_COLLAPSE__tx_addr_r_stuck_at_0_despite_distinct_haddr"
        else:
            verdict = "MASTER_AHB_HADDR_NOT_DISTINCT__ahb_driver_problem"
    elif s_l2a_addrs and all_zero(s_l2a_addrs) and not all_zero(m_a2l_addrs):
        verdict = "LINK_ADDR_CORRUPTION__master_TX_distinct_but_slave_RX_zeroed"
    elif s_fifo_addrs and all_zero(s_fifo_addrs) and not all_zero(s_l2a_addrs):
        verdict = "SLAVE_FC_RX_FSM_ADDR_LOSS__rx_addr_offset_decode_to_fc_rx_fifo_addr_broken"
    elif m_a2l_addrs == s_l2a_addrs == s_fifo_addrs and unique(m_a2l_addrs):
        verdict = "ADDR_TRANSITS_INTACT__bug_is_downstream_of_fc_rx_fifo_addr"
    else:
        verdict = "MIXED__see_per_stage_lists"

    dut._log.info("================================================================")
    dut._log.info(f"  VERDICT: {verdict}")
    dut._log.info("================================================================")

    assert _safe(m_tx_addr_r) >= 0, "m_tx_addr_r probe failed (-1)"
