"""Bug A — Address-aliasing + PKT_WORD_LEN deep probe.

Successor to test_buga_addr_collapse.py (which proved the FIFO addresses
0,4,8,c transit master→slave intact). This run drills past the address
issue and asks: *why is REG_PKT_WORD_LEN still 0 when the slave FIFO RAM
sees 4 writes?*

Probes added vs addr_collapse:
  * full packet payload (4 distinct values + correctly-formed word0 with
    length=2 in bits[31:20])
  * slave fc_wr_* INTO fifo_ctrl (one level up from fc_rx_fifo_*)
  * slave fifo_ctrl internal state: packet_word_length_r,
    packet_active_r, write_target_addr_r, fc_write_addr0,
    fc_write_complete (the PKT_WORD_LEN write-enable path)
  * master ahb_tx_haddr / ahb_tx_hwdata sampled in BOTH addr-phase and
    data-phase cycles (the collapse test only sampled at addr phase,
    which was a probe artifact — hwdata is only valid 1 cy later).

Read-only RTL. Reuses PairTB + run_bringup_full. No wave dump.

Run::

  source /home/dam1n19/SoCLabs/tidelink/set_env.sh
  cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
  timeout 900 make MODULE=test_buga_addr_aliasing \\
      SIM_BUILD=sim_build_addr_alias TB_TOP_NO_DUMP=1
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


def _fifo_ctrl(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl


def _fifo_mem(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_tidelink_fifo.u_fifo_mem


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
# Stimulus
# ---------------------------------------------------------------------------

PAYLOAD = [0xDEADBEEF, 0xCAFEBABE]
OBSERVE_WINDOW_CY = 800
TEST_TIMEOUT_NS = 50_000_000


def _packet_words():
    word0 = encode_word0(length=len(PAYLOAD), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    # words[1] = dest addr inside peer FIFO (0); PAYLOAD = N data words.
    return [word0, 0x0] + PAYLOAD


def _pkt_type_name(t):
    return {0: "FIFO_DATA", 1: "SIDEBAND", 2: "EXT", 3: "RSVD"}.get(t & 0x3, "?")


# ===========================================================================
# Test
# ===========================================================================
async def _ahb_tx_write_word_fixed(tb, side, byte_addr, data):
    """BFM that drives hwdata BEFORE the data-phase rising edge.

    Differs from PairTB._ahb_tx_write_word: hwdata is set in the same
    code block as haddr (one cycle earlier), so cocotb 2.x scheduling
    delivers it before the FC adapter samples it in the data phase.
    """
    from cocotb.triggers import RisingEdge, ClockCycles  # local import
    dut = tb.dut
    hsel    = getattr(dut, f"{side}_ahb_tx_hsel")
    haddr   = getattr(dut, f"{side}_ahb_tx_haddr")
    htrans  = getattr(dut, f"{side}_ahb_tx_htrans")
    hsize   = getattr(dut, f"{side}_ahb_tx_hsize")
    hwrite  = getattr(dut, f"{side}_ahb_tx_hwrite")
    hwdata  = getattr(dut, f"{side}_ahb_tx_hwdata")
    hready  = getattr(dut, f"{side}_ahb_tx_hready")

    # Pre-arm hwdata one cycle before the data phase to dodge the
    # cocotb 2.x deferred-write scheduling.
    hwdata.value = data & 0xFFFFFFFF
    await RisingEdge(dut.hclk)
    hsel.value   = 1
    htrans.value = 2
    hsize.value  = 2
    hwrite.value = 1
    haddr.value  = byte_addr & ((1 << 14) - 1)
    await RisingEdge(dut.hclk)
    hsel.value   = 0
    htrans.value = 0
    hwrite.value = 0
    # Keep hwdata held into the data phase (AHB-Lite protocol).
    for _ in range(50):
        try:
            if int(hready.value):
                break
        except ValueError:
            pass
        await RisingEdge(dut.hclk)


async def _ahb_tx_write_packet_fixed(tb, side, words):
    from cocotb.triggers import ClockCycles
    for i, w in enumerate(words):
        await _ahb_tx_write_word_fixed(tb, side, i * 4, w)
        await ClockCycles(tb.dut.hclk, 4)


@cocotb.test(timeout_time=TEST_TIMEOUT_NS, timeout_unit="ns")
async def test_buga_addr_aliasing(dut):
    tb = PairTB(dut)
    await run_bringup_full(tb)

    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 200)

    m_fc        = _fc_adapter(dut, "m")
    s_fc        = _fc_adapter(dut, "s")
    s_fifo_ctrl = _fifo_ctrl(dut, "s")
    s_fifo_mem  = _fifo_mem(dut, "s")

    # --- Probe resolution -------------------------------------------------
    # Master fc_adapter
    m_ahb_tx_haddr        = _opt(m_fc, "ahb_tx_haddr")
    m_ahb_tx_hwdata       = _opt(m_fc, "ahb_tx_hwdata")
    m_ahb_tx_hwrite       = _opt(m_fc, "ahb_tx_hwrite")
    m_ahb_tx_hsel         = _opt(m_fc, "ahb_tx_hsel")
    m_ahb_tx_htrans       = _opt(m_fc, "ahb_tx_htrans")
    m_ahb_tx_hready       = _opt(m_fc, "ahb_tx_hready")
    m_tx_valid_addr_phase = _opt(m_fc, "tx_valid_addr_phase")
    m_tx_addr_r           = _opt(m_fc, "tx_addr_r")
    m_tx_data_phase_r     = _opt(m_fc, "tx_data_phase_r")
    m_tx_fc_word          = _opt(m_fc, "tx_fc_word")
    m_tl_fc_a2l_valid     = _opt(m_fc, "tl_fc_a2l_valid")
    m_tl_fc_a2l_ready     = _opt(m_fc, "tl_fc_a2l_ready")
    m_tl_fc_a2l_data      = _opt(m_fc, "tl_fc_a2l_data")

    # Slave fc_adapter
    s_tl_fc_l2a_valid  = _opt(s_fc, "tl_fc_l2a_valid")
    s_tl_fc_l2a_accept = _opt(s_fc, "tl_fc_l2a_accept")
    s_tl_fc_l2a_data   = _opt(s_fc, "tl_fc_l2a_data")
    s_rx_addr_offset   = _opt(s_fc, "rx_addr_offset")
    s_rx_pkt_type      = _opt(s_fc, "rx_pkt_type")
    s_rx_payload       = _opt(s_fc, "rx_payload")
    s_rx_state_r       = _opt(s_fc, "rx_state_r")
    s_fc_rx_fifo_valid = _opt(s_fc, "fc_rx_fifo_valid")
    s_fc_rx_fifo_addr  = _opt(s_fc, "fc_rx_fifo_addr")
    s_fc_rx_fifo_wdata = _opt(s_fc, "fc_rx_fifo_wdata")

    # Slave fifo_mem: fc_wr_* INTO fifo_ctrl
    s_fm_fc_wr_valid   = _opt(s_fifo_mem, "fc_wr_valid")
    s_fm_fc_wr_write   = _opt(s_fifo_mem, "fc_wr_write")
    s_fm_fc_wr_addr    = _opt(s_fifo_mem, "fc_wr_addr")
    s_fm_fc_wr_wdata   = _opt(s_fifo_mem, "fc_wr_wdata")

    # Slave fifo_ctrl: the PKT_WORD_LEN write-enable path
    s_fc_packet_word_length_r  = _opt(s_fifo_ctrl, "packet_word_length_r")
    s_fc_packet_word_length_nx = _opt(s_fifo_ctrl, "packet_word_length_nxt")
    s_fc_packet_active_r       = _opt(s_fifo_ctrl, "packet_active_r")
    s_fc_write_target_addr_r   = _opt(s_fifo_ctrl, "write_target_addr_r")
    s_fc_write_addr0           = _opt(s_fifo_ctrl, "fc_write_addr0")
    s_fc_write_complete        = _opt(s_fifo_ctrl, "write_complete")
    s_fc_fc_write_complete     = _opt(s_fifo_ctrl, "fc_write_complete")
    s_fc_fc_write_valid        = _opt(s_fifo_ctrl, "fc_write_valid")
    s_fc_packet_committed_irq  = _opt(s_fifo_ctrl, "packet_committed_irq_r")

    probes = dict(
        m_ahb_tx_haddr=m_ahb_tx_haddr,
        m_ahb_tx_hwdata=m_ahb_tx_hwdata,
        m_tx_valid_addr_phase=m_tx_valid_addr_phase,
        m_tx_addr_r=m_tx_addr_r,
        m_tx_data_phase_r=m_tx_data_phase_r,
        m_tx_fc_word=m_tx_fc_word,
        m_tl_fc_a2l_valid=m_tl_fc_a2l_valid,
        m_tl_fc_a2l_ready=m_tl_fc_a2l_ready,
        m_tl_fc_a2l_data=m_tl_fc_a2l_data,
        s_tl_fc_l2a_valid=s_tl_fc_l2a_valid,
        s_tl_fc_l2a_data=s_tl_fc_l2a_data,
        s_rx_addr_offset=s_rx_addr_offset,
        s_rx_pkt_type=s_rx_pkt_type,
        s_rx_payload=s_rx_payload,
        s_fc_rx_fifo_valid=s_fc_rx_fifo_valid,
        s_fc_rx_fifo_addr=s_fc_rx_fifo_addr,
        s_fc_rx_fifo_wdata=s_fc_rx_fifo_wdata,
        s_fm_fc_wr_valid=s_fm_fc_wr_valid,
        s_fm_fc_wr_addr=s_fm_fc_wr_addr,
        s_fm_fc_wr_wdata=s_fm_fc_wr_wdata,
        s_fc_packet_word_length_r=s_fc_packet_word_length_r,
        s_fc_packet_active_r=s_fc_packet_active_r,
        s_fc_write_target_addr_r=s_fc_write_target_addr_r,
        s_fc_write_addr0=s_fc_write_addr0,
        s_fc_write_complete=s_fc_write_complete,
        s_fc_fc_write_complete=s_fc_fc_write_complete,
        s_fc_fc_write_valid=s_fc_fc_write_valid,
        s_fc_packet_committed_irq=s_fc_packet_committed_irq,
    )
    unresolved = [n for n, h in probes.items() if h is None]
    if unresolved:
        dut._log.warning(f"  Unresolved probes: {unresolved}")
    else:
        dut._log.info("  All addr-aliasing/PKT_WORD_LEN probes resolved.")

    # --- Watcher state ----------------------------------------------------
    m_ahb_trace        = []   # (cy, hsel, htrans, hwrite, haddr, hwdata) every cy
    m_tx_data_trace    = []   # (cy, tx_data_phase_r, tx_addr_r, ahb_tx_hwdata, tx_fc_word)
    m_a2l_fire_trace   = []   # (cy, data) on valid&ready
    s_l2a_fire_trace   = []   # (cy, data) on valid&accept
    s_fifo_wr_trace    = []   # (cy, addr, wdata) on fc_rx_fifo_valid
    s_fm_fc_wr_trace   = []   # (cy, addr, wdata, write) on fc_wr_valid (into fifo_ctrl)
    s_pkt_len_changes  = []   # (cy, prev, new) when packet_word_length_r changes
    s_pkt_active_chgs  = []   # (cy, prev, new) when packet_active_r changes
    s_write_complete_trace = []  # (cy, write_complete, fc_write_complete, fc_write_valid)
    s_fc_write_addr0_trace = []  # (cy, fc_write_addr0)
    s_pkt_committed_trace  = []  # (cy, value)

    async def watcher():
        cy = 0
        prev_pwl = -1
        prev_pa  = -1
        prev_pci = -1
        while True:
            await RisingEdge(dut.hclk)
            cy += 1

            # Master AHB-bus snapshot every cy (find addr & data phases)
            hsel  = _safe(m_ahb_tx_hsel)
            htr   = _safe(m_ahb_tx_htrans)
            hwr   = _safe(m_ahb_tx_hwrite)
            hadr  = _safe(m_ahb_tx_haddr)
            hwdt  = _safe(m_ahb_tx_hwdata)
            if hsel == 1 and (htr & 0x2):  # NONSEQ valid addr phase
                m_ahb_trace.append((cy, hsel, htr, hwr, hadr, hwdt))

            # Master TX data-phase snapshot (when tx_data_phase_r=1)
            dp = _safe(m_tx_data_phase_r)
            if dp == 1:
                m_tx_data_trace.append((
                    cy,
                    _safe(m_tx_addr_r),
                    _safe(m_ahb_tx_hwdata),
                    _safe(m_tx_fc_word),
                ))

            # Master TX a2l fire
            if _safe(m_tl_fc_a2l_valid) == 1 and _safe(m_tl_fc_a2l_ready) == 1:
                m_a2l_fire_trace.append((cy, _safe(m_tl_fc_a2l_data)))

            # Slave RX l2a fire
            if _safe(s_tl_fc_l2a_valid) == 1 and _safe(s_tl_fc_l2a_accept) == 1:
                s_l2a_fire_trace.append((cy, _safe(s_tl_fc_l2a_data)))

            # Slave fc_rx_fifo write pulse
            if _safe(s_fc_rx_fifo_valid) == 1:
                s_fifo_wr_trace.append((
                    cy,
                    _safe(s_fc_rx_fifo_addr),
                    _safe(s_fc_rx_fifo_wdata),
                ))

            # Slave fifo_mem fc_wr (the level that enters fifo_ctrl)
            if _safe(s_fm_fc_wr_valid) == 1:
                s_fm_fc_wr_trace.append((
                    cy,
                    _safe(s_fm_fc_wr_addr),
                    _safe(s_fm_fc_wr_wdata),
                    _safe(s_fm_fc_wr_write),
                ))

            # Track fc_write_addr0 / write_complete pulses
            if _safe(s_fc_write_addr0) == 1:
                s_fc_write_addr0_trace.append((cy,))
            wcomp = _safe(s_fc_write_complete)
            fc_wcomp = _safe(s_fc_fc_write_complete)
            fc_wval  = _safe(s_fc_fc_write_valid)
            if wcomp == 1 or fc_wcomp == 1 or fc_wval == 1:
                s_write_complete_trace.append((cy, wcomp, fc_wcomp, fc_wval))

            # packet_word_length_r transitions
            pwl = _safe(s_fc_packet_word_length_r)
            if pwl != prev_pwl and prev_pwl >= 0:
                s_pkt_len_changes.append((cy, prev_pwl, pwl))
            prev_pwl = pwl

            pa = _safe(s_fc_packet_active_r)
            if pa != prev_pa and prev_pa >= 0:
                s_pkt_active_chgs.append((cy, prev_pa, pa))
            prev_pa = pa

            pci = _safe(s_fc_packet_committed_irq)
            if pci != prev_pci and prev_pci >= 0:
                s_pkt_committed_trace.append((cy, prev_pci, pci))
            prev_pci = pci

    w = cocotb.start_soon(watcher())

    # --- Drive the AHB packet ---------------------------------------------
    words = _packet_words()
    dut._log.info("================================================================")
    dut._log.info("  AHB write sequence (offset:value):")
    for i, w_ in enumerate(words):
        dut._log.info(f"    {i*4:#04x}: 0x{w_:08x}")
    dut._log.info("================================================================")
    await _ahb_tx_write_packet_fixed(tb, "m", words)

    await ClockCycles(dut.hclk, OBSERVE_WINDOW_CY)
    w.cancel()

    # --- Post APB read ----------------------------------------------------
    pkt_word_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    dut._log.info(f"  S.REG_PKT_WORD_LEN = 0x{int(pkt_word_len):08x}")
    dut._log.info(f"  S.packet_word_length_r (final) = "
                  f"{_safe(s_fc_packet_word_length_r)}")
    dut._log.info(f"  S.packet_active_r (final)      = "
                  f"{_safe(s_fc_packet_active_r)}")
    dut._log.info(f"  S.packet_committed_irq_r (final) = "
                  f"{_safe(s_fc_packet_committed_irq)}")

    # =====================================================================
    # Reporting
    # =====================================================================
    dut._log.info("================================================================")
    dut._log.info("  MASTER AHB addr-phase trace (every NONSEQ pulse):")
    dut._log.info("    cycle   hwrite   haddr        hwdata (sampled @ addr phase)")
    dut._log.info("    -----   ------   ----------   --------")
    for (cy, _, _, hwr, ha, hw) in m_ahb_trace[:12]:
        dut._log.info(
            f"    {cy:>5}   {hwr:>6}   0x{ha & 0x3FFF:08x}   0x{hw & 0xFFFFFFFF:08x}"
        )

    dut._log.info("================================================================")
    dut._log.info("  MASTER TX data-phase trace (tx_data_phase_r=1):")
    dut._log.info("    cycle   tx_addr_r    ahb_tx_hwdata    tx_fc_word")
    dut._log.info("    -----   ----------   --------------   ----------")
    for (cy, ta, hw, fw) in m_tx_data_trace[:24]:
        dut._log.info(
            f"    {cy:>5}   0x{ta & 0x3FFF:08x}   0x{hw & 0xFFFFFFFF:08x}      "
            f"0x{fw & ((1<<48)-1):012x}"
        )

    dut._log.info("================================================================")
    dut._log.info("  MASTER tl_fc_a2l fires (valid&ready) — FC word on the link:")
    dut._log.info("    cycle   pkt_type  addr_offset   payload      48-bit word")
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
    dut._log.info("  SLAVE fc_rx_fifo_valid pulses (write into fifo_mem):")
    dut._log.info("    cycle   fc_rx_fifo_addr   fc_rx_fifo_wdata")
    for (cy, ad, wd) in s_fifo_wr_trace:
        dut._log.info(
            f"    {cy:>5}   0x{ad & 0x3FFF:04x}              0x{wd & 0xFFFFFFFF:08x}"
        )

    dut._log.info("================================================================")
    dut._log.info("  SLAVE fifo_mem→fifo_ctrl fc_wr_* (PKT_WORD_LEN write-enable path):")
    dut._log.info("    cycle   write   fc_wr_addr   fc_wr_wdata[31:20]")
    dut._log.info("    -----   -----   ----------   ------------------")
    for (cy, ad, wd, wr) in s_fm_fc_wr_trace:
        # wdata is {2'b0, fc_rx_fifo_wdata[31:20]} per tidelink_fifo_mem.sv:156
        dut._log.info(
            f"    {cy:>5}   {wr:>5}   0x{ad & 0x3FFF:08x}   0x{wd & 0x3FFF:04x}"
        )

    dut._log.info("================================================================")
    dut._log.info("  SLAVE fifo_ctrl write-side pulses:")
    dut._log.info("    cycle   write_complete   fc_write_complete   fc_write_valid")
    for (cy, wc, fwc, fwv) in s_write_complete_trace:
        dut._log.info(
            f"    {cy:>5}        {wc:>1}                {fwc:>1}                {fwv:>1}"
        )

    dut._log.info("================================================================")
    dut._log.info("  SLAVE fifo_ctrl fc_write_addr0 pulses:")
    for (cy,) in s_fc_write_addr0_trace:
        dut._log.info(f"    cy={cy}")

    dut._log.info("================================================================")
    dut._log.info("  SLAVE packet_word_length_r transitions:")
    for (cy, p, n) in s_pkt_len_changes:
        dut._log.info(f"    cy={cy}  {p} → {n}")

    dut._log.info("  SLAVE packet_active_r transitions:")
    for (cy, p, n) in s_pkt_active_chgs:
        dut._log.info(f"    cy={cy}  {p} → {n}")

    dut._log.info("  SLAVE packet_committed_irq_r transitions:")
    for (cy, p, n) in s_pkt_committed_trace:
        dut._log.info(f"    cy={cy}  {p} → {n}")

    # =====================================================================
    # Verdict
    # =====================================================================
    m_a2l_payloads = []
    for (_, d) in m_a2l_fire_trace:
        if d < 0:
            continue
        if ((d >> 46) & 0x3) == 0:
            m_a2l_payloads.append(d & 0xFFFFFFFF)
    s_fifo_wdatas = [wd & 0xFFFFFFFF for (_, _, wd) in s_fifo_wr_trace]

    # Compare with expected payload sequence (4 words from _packet_words)
    expected = [w & 0xFFFFFFFF for w in words]

    payload_intact_master_tx = (m_a2l_payloads == expected)
    payload_intact_slave_rx  = (s_fifo_wdatas == expected)

    word0_to_fifo_ctrl_len = None
    for (cy, ad, wd, wr) in s_fm_fc_wr_trace:
        if (ad & 0x3FFF) == 0:
            # fc_wr_wdata into fifo_ctrl is already {2'b0, fc_wr_wdata[31:20]}.
            word0_to_fifo_ctrl_len = wd & 0x3FFF
            break

    dut._log.info("================================================================")
    dut._log.info(f"  expected payload seq:  {[hex(x) for x in expected]}")
    dut._log.info(f"  master tl_fc_a2l data: {[hex(x) for x in m_a2l_payloads]}")
    dut._log.info(f"  slave fc_rx_fifo wdat: {[hex(x) for x in s_fifo_wdatas]}")
    dut._log.info(f"  word0→fifo_ctrl length field: {word0_to_fifo_ctrl_len}")

    if not m_a2l_payloads:
        verdict = "NO_MASTER_TX_FIRE"
    elif not payload_intact_master_tx:
        verdict = "BFM_OR_FC_PAYLOAD_CORRUPT__master_a2l_data_does_not_match_AHB_write"
    elif not payload_intact_slave_rx:
        verdict = "LINK_PAYLOAD_CORRUPT__slave_fc_rx_fifo_wdata_does_not_match_a2l_payload"
    elif word0_to_fifo_ctrl_len == 0 and (expected[0] >> 20) & 0xFFF != 0:
        verdict = "FIFO_CTRL_INPUT_DROPPED_LENGTH__word0_length_field_lost_pre_fifo_ctrl"
    elif _safe(s_fc_packet_word_length_r) == 0 and len(s_pkt_len_changes) > 0:
        verdict = "PKT_WORD_LEN_RESET_AFTER_CAPTURE__write_complete_fired_before_full_pkt"
    elif len(s_fc_write_addr0_trace) == 0:
        verdict = "FC_WRITE_ADDR0_NEVER_FIRED__length_capture_never_armed"
    elif _safe(s_fc_packet_word_length_r) == 0:
        verdict = "PKT_WORD_LEN_NEVER_LATCHED"
    else:
        verdict = "PKT_WORD_LEN_OK__bug_is_elsewhere"

    dut._log.info("================================================================")
    dut._log.info(f"  VERDICT: {verdict}")
    dut._log.info("================================================================")

    assert _safe(m_tx_addr_r) >= 0, "m_tx_addr_r probe failed (-1)"
