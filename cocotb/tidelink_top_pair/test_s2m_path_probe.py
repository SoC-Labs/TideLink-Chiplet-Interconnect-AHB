"""S->M (slave->master) sideband path localisation probe.

Replicates test_04's S->M trigger (push M->S packet, drain slave RX FIFO with
real reads -> read_complete -> release_credits_trigger -> slave returner emits
an S->M sideband), then traces, per cycle, the ENTIRE S->M path from the slave
Wlink TX submit to the master FC-adapter l2a output, to find the EXACT cut
point where the slave's packet dies.

Probe taps (slave TX side):
  slave FC adapter   : tl_fc_a2l_valid / _ready / _data
  slave FCSM         : state (does it reach LINK_DATA=5 for the S->M xfer?),
                       a2l_fc_replay_link_valid, fe_rx_is_full,
                       auto_tx_out_valid / _sop / _data_id (what it transmits)
On-wire:
  slave TX pads      : s_pad_tx (DUT top), into u_skid_s2m -> master RX
Master RX framer (master FCSM):
  auto_rx_in_valid / _sop / _data_id, pkt_is_{cr,crack,ack,nack,data}_pkt,
  crc_corrupt, state, and the local swi_*_id classifier config
Master FC adapter RX:
  tl_fc_l2a_valid, rx_fc_word_r, rx_pkt_type, rx_is_fifo,
  fc_rx_cfg_psel, fc_rx_cfg_paddr

For reference the WORKING M->S direction is traced symmetrically (master FCSM
TX + slave FCSM RX + slave adapter l2a) so we can diff the asymmetry directly.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full,
    APB_R8_SLOT0, R8_SLOT0_OFF,
    APB_RELEASE_THRESHOLD, APB_PAIR_CREDIT_COUNTER, APB_RELEASED_ACC,
)


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


def fcsm(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def fca(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_fc_adapter


def dump_swi(tb, dut, side):
    f = fcsm(dut, side)
    tb.log.info(
        f"  [{side} FCSM swi cfg] data_id_1=0x{_i(f.swi_data_id_1):02x} "
        f"cr_id=0x{_i(f.swi_cr_id):02x} crack_id=0x{_i(f.out_prepend_swi_crack_id):02x} "
        f"ack_id=0x{_i(f.out_prepend_swi_ack_id):02x} nack_id=0x{_i(f.out_prepend_swi_nack_id):02x} "
        f"disable_crc={_i(f.out_prepend_swi_disable_crc)}"
    )


@cocotb.test()
async def test_s2m_path_probe(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)

    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    # Immediate credit-release on the slave's first FIFO read_complete.
    await tb.s_apb.write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 50)

    # Dump the static classifier config on both sides — a role-dependent
    # data_id mismatch would silently kill cross-direction classification.
    dump_swi(tb, dut, "m")
    dump_swi(tb, dut, "s")

    s_f = fcsm(dut, "s")   # slave FCSM (TX side for S->M)
    m_f = fcsm(dut, "m")   # master FCSM (RX side for S->M)
    s_a = fca(dut, "s")    # slave adapter (a2l submit)
    m_a = fca(dut, "m")    # master adapter (l2a receive)

    # Per-cycle tracer. Logs only when something on the S->M path is active.
    log = tb.log

    async def trace(n, label):
        seen_s_a2l = seen_s_tx = seen_m_rx = seen_m_classify = seen_m_l2a = 0
        for cyc in range(n):
            await RisingEdge(dut.hclk)
            # --- slave TX submit (adapter -> slave FCSM) ---
            s_a2l_v = _i(s_a.tl_fc_a2l_valid)
            s_a2l_r = _i(s_a.tl_fc_a2l_ready)
            s_a2l_d = _i(s_a.tl_fc_a2l_data)
            # --- slave FCSM TX engine ---
            s_state = _i(s_f.state)
            s_repl  = _i(s_f.a2l_fc_replay_link_valid)
            s_full  = _i(s_f.fe_rx_is_full)
            s_tx_adv = _i(s_f.auto_tx_out_advance)
            s_tx_sop = _i(s_f.auto_tx_out_sop)
            s_tx_id  = _i(s_f.auto_tx_out_data_id)
            s_tx_v  = s_tx_adv  # FCSM has no tx_valid; advance gates the xfer
            # --- on wire: slave TX pads ---
            s_pad = _i(dut.s_pad_tx)
            # --- master RX framer ---
            m_rx_v   = _i(m_f.auto_rx_in_valid)
            m_rx_sop = _i(m_f.auto_rx_in_sop)
            m_rx_id  = _i(m_f.auto_rx_in_data_id)
            m_is_cr  = _i(m_f.pkt_is_cr_pkt)
            m_is_crk = _i(m_f.pkt_is_crack_pkt)
            m_is_ack = _i(m_f.pkt_is_ack_pkt)
            m_is_nak = _i(m_f.pkt_is_nack_pkt)
            m_is_dat = _i(m_f.pkt_is_data_pkt)
            m_crc    = _i(m_f.crc_corrupt)
            m_state  = _i(m_f.state)
            # --- master adapter RX ---
            m_l2a_v  = _i(m_a.tl_fc_l2a_valid)
            m_rxword = _i(m_a.rx_fc_word_r)
            m_rxtype = _i(m_a.rx_pkt_type)
            m_rxfifo = _i(m_a.rx_is_fifo)
            m_cfg_ps = _i(m_a.fc_rx_cfg_psel)
            m_cfg_pa = _i(m_a.fc_rx_cfg_paddr)

            interesting = (s_a2l_v or s_repl or s_tx_v or m_rx_v or
                           m_l2a_v or m_is_cr or m_is_crk or m_is_ack or
                           m_is_nak or m_is_dat or m_crc)
            if interesting:
                if s_a2l_v: seen_s_a2l += 1
                if s_tx_v:  seen_s_tx += 1
                if m_rx_v:  seen_m_rx += 1
                if (m_is_cr or m_is_crk or m_is_ack or m_is_nak or m_is_dat):
                    seen_m_classify += 1
                if m_l2a_v: seen_m_l2a += 1
                log.info(
                    f"[{label} c{cyc:4d}] "
                    f"S.a2l(v={s_a2l_v},r={s_a2l_r},d={_h(s_a2l_d,12)}) "
                    f"S.fcsm(st={s_state},repl={s_repl},full={s_full},"
                    f"tx_adv={s_tx_adv},sop={s_tx_sop},id={_h(s_tx_id,2)}) "
                    f"wire(s_pad={_h(s_pad,4)}) || "
                    f"M.rx(v={m_rx_v},sop={m_rx_sop},id={_h(m_rx_id,2)},"
                    f"cr={m_is_cr},crk={m_is_crk},ack={m_is_ack},nak={m_is_nak},"
                    f"dat={m_is_dat},crc={m_crc},st={m_state}) "
                    f"M.l2a(v={m_l2a_v},w={_h(m_rxword,12)},type={m_rxtype},"
                    f"fifo={m_rxfifo},cfg_ps={m_cfg_ps},cfg_pa={_h(m_cfg_pa,4)})"
                )
        log.info(
            f"[{label} SUMMARY] s_a2l_cyc={seen_s_a2l} s_tx_cyc={seen_s_tx} "
            f"m_rx_valid_cyc={seen_m_rx} m_classify_cyc={seen_m_classify} "
            f"m_l2a_cyc={seen_m_l2a}"
        )

    # ------------------------------------------------------------------
    # PART A: prime the slave RX FIFO with an M->S packet (this is the
    # WORKING direction; we expect master FCSM TX -> slave RX to deliver).
    # ------------------------------------------------------------------
    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    log.info("=== PART A: M->S packet push (prime slave RX FIFO) ===")
    tA = cocotb.start_soon(trace(2500, "M2S"))
    await tb.ahb_tx_write_packet("m", words)
    await ClockCycles(dut.hclk, 1500)
    await tA

    # ------------------------------------------------------------------
    # PART B: drain the slave RX FIFO -> read_complete -> release ->
    # slave returner emits an S->M sideband credit-release. Trace S->M.
    # ------------------------------------------------------------------
    log.info("=== PART B: drain slave RX FIFO -> S->M sideband ===")
    tB = cocotb.start_soon(trace(4500, "S2M"))
    for off in (0x00, 0x04, 0x08, 0x0C):
        rv = await tb.ahb_fifo_read_word("s", off)
        log.info(f"  slave FIFO read[0x{off:02x}] = 0x{rv:08x}")
    await ClockCycles(dut.hclk, 3000)
    await tB

    m_rel = await tb.m_apb.read(APB_RELEASED_ACC)
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    log.info(f"  master RELEASED_CREDITS_ACC=0x{m_rel:08x} PAIR_CREDIT_COUNTER=0x{m_pcc:08x}")


def _h(v, w):
    if v is None:
        return "x" * w
    return f"{v:0{w}x}"
