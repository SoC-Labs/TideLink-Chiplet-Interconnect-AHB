"""S->M slave TX chain localisation: the slave FCSM reaches LINK_DATA(5) and
asserts auto_tx_out (sop, advance, id=0xa1) but s_pad_tx stays 0x0000. This
probe traces the slave TX chain BETWEEN the FCSM tx_out and the package pads to
find where the transmit dies:

  slave FCSM   : auto_tx_out_sop / _advance / _data_id   (proven asserting)
  Wlink.tl2wl  : tl2wl_auto_wlink_tidelinktl_tx_out_{sop,advance,data_id}
  txrouter en  : txrouter_io_enable
  lltx en      : lltx_io_enable, out_prepend_swi_lltx_enable, swi_sb_reset_in_muxed
  lltx inputs  : lltx_auto_in_{sop,advance,data_id}, lltx_io_ll_tx_valid
  PHY link out : phy_link_tx_tx_link_data, phy_link_tx_tx_link_clk
  pads         : s_pad_tx (top)

Compared against the WORKING master side TX chain (same nodes on u_master), so
we can see whether the master's lltx_io_enable is set but the slave's is not
(role/bootstrap asymmetry), or whether the chain is identical and the difference
is upstream gating.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full,
    APB_R8_SLOT0, R8_SLOT0_OFF, APB_RELEASE_THRESHOLD,
    APB_PAIR_CREDIT_COUNTER, APB_RELEASED_ACC,
)


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


def wlink(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink


def static_enables(tb, dut, side):
    w = wlink(dut, side)
    tb.log.info(
        f"  [{side} TX enables] txrouter_en={_i(w.txrouter_io_enable)} "
        f"lltx_en={_i(w.lltx_io_enable)} "
        f"swi_lltx_enable={_i(w.out_prepend_swi_lltx_enable)} "
        f"swi_lltx_enable_1(rx)={_i(w.out_prepend_swi_lltx_enable_1)} "
        f"sb_reset_muxed={_i(w.swi_sb_reset_in_muxed)} "
        f"tx_link_idle={_i(w.tx_link_idle)}"
    )


@cocotb.test()
async def test_s2m_txchain_probe(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)
    await tb.s_apb.write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 50)

    # Compare static TX-chain enables master vs slave.
    static_enables(tb, dut, "m")
    static_enables(tb, dut, "s")

    sw = wlink(dut, "s")
    mw = wlink(dut, "m")
    log = tb.log

    def snap(w, side):
        return (
            f"{side}: txr_en={_i(w.txrouter_io_enable)} lltx_en={_i(w.lltx_io_enable)} "
            f"tl2wl(sop={_i(w.tl2wl_auto_wlink_tidelinktl_tx_out_sop)},"
            f"adv={_i(w.tl2wl_auto_wlink_tidelinktl_tx_out_advance)},"
            f"id={_h(_i(w.tl2wl_auto_wlink_tidelinktl_tx_out_data_id),2)}) "
            f"lltx_in(sop={_i(w.lltx_auto_in_sop)},adv={_i(w.lltx_auto_in_advance)},"
            f"id={_h(_i(w.lltx_auto_in_data_id),2)},txvalid={_i(w.lltx_io_ll_tx_valid)}) "
            f"phy_data={_h(_i(w.phy_link_tx_tx_link_data),32)}"
        )

    async def trace(n, label):
        for cyc in range(n):
            await RisingEdge(dut.hclk)
            s_adv = _i(sw.tl2wl_auto_wlink_tidelinktl_tx_out_advance)
            s_llv = _i(sw.lltx_io_ll_tx_valid)
            s_phy = _i(sw.phy_link_tx_tx_link_data)
            s_pad = _i(dut.s_pad_tx)
            if s_adv or s_llv or (s_phy not in (0, None)) or (s_pad not in (0, None)):
                log.info(
                    f"[{label} c{cyc:4d}] {snap(sw,'S')} | s_pad={_h(s_pad,4)}"
                )

    # Prime slave RX FIFO with an M->S packet.
    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    await tb.ahb_tx_write_packet("m", [word0, 0x0] + payload)
    await ClockCycles(dut.hclk, 1500)

    # Snapshot master TX chain once (the WORKING side) for direct compare.
    log.info(f"  [master TX chain snapshot] {snap(mw,'M')} "
             f"m_pad={_h(_i(dut.m_pad_tx),4)}")

    log.info("=== S->M: drain slave FIFO, trace slave TX chain ===")
    tB = cocotb.start_soon(trace(4500, "S2M"))
    for off in (0x00, 0x04, 0x08, 0x0C):
        await tb.ahb_fifo_read_word("s", off)
    await ClockCycles(dut.hclk, 3000)
    await tB

    m_rel = await tb.m_apb.read(APB_RELEASED_ACC)
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    log.info(f"  master RELEASED_ACC=0x{m_rel:08x} PAIR_CREDIT=0x{m_pcc:08x}")


def _h(v, w):
    if v is None:
        return "x" * w
    return f"{v:0{w}x}"
