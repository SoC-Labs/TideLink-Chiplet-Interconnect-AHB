"""S->M master RX chain localisation.

Established by test_s2m_txchain_probe: the SLAVE transmits fine — its FCSM
reaches LINK_DATA, lltx loads phy_data=...00a1 and s_pad_tx toggles
(001a/0008/0004). So the packet IS on the wire. Yet the master FCSM
auto_rx_in_valid never asserts. The cut point is the MASTER RX chain.

This probe traces the master RX chain and compares it, in the SAME run, to the
slave RX chain during the WORKING M->S delivery (PART A primes the slave FIFO,
so the slave RX chain successfully decodes a data packet — a known-good
reference). Per cycle:

  pad_rx in    : master pad_rx (=s_pad_tx_skid) ; slave pad_rx (=m_pad_tx_skid)
  PHY RX       : phy_link_rx_rx_link_data, phy_link_rx_rx_link_clk
  llrx config  : llrx_io_enable, llrx_io_active_lanes, llrx_io_lane_mask
  llrx in/out  : llrx_io_link_data, llrx_auto_out_valid/_sop/_data_id
  FCSM RX      : auto_rx_in_valid/_sop/_data_id, pkt_is_*; crc_corrupt; state
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


def _h(v, w):
    return "x" * w if v is None else f"{v:0{w}x}"


def wlink(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_wlink


def fcsm(dut, side):
    return wlink(dut, side).tl2wl.wlink_tidelinktl


def rx_static(tb, dut, side, padsig):
    w = wlink(dut, side)
    tb.log.info(
        f"  [{side} RX cfg] llrx_en={_i(w.llrx_io_enable)} "
        f"active_lanes={_h(_i(w.llrx_io_active_lanes),2)} "
        f"lane_mask={_h(_i(w.llrx_io_lane_mask),2)} "
        f"rx_lane_mask={_h(_i(w.phy_link_rx_rx_lane_mask),2)} "
        f"pad_rx={_h(_i(padsig),4)}"
    )


@cocotb.test()
async def test_s2m_rxchain_probe(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ

    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)
    await tb.s_apb.write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 50)

    log = tb.log
    # master pad_rx is fed by s_pad_tx_skid; slave pad_rx by m_pad_tx_skid.
    rx_static(tb, dut, "m", dut.s_pad_tx_skid)
    rx_static(tb, dut, "s", dut.m_pad_tx_skid)

    def rxsnap(side, padsig):
        w = wlink(dut, side)
        f = fcsm(dut, side)
        return (
            f"{side} pad_rx={_h(_i(padsig),4)} "
            f"phy_rx={_h(_i(w.phy_link_rx_rx_link_data),32)} "
            f"llrx_in={_h(_i(w.llrx_io_link_data),32)} "
            f"llrx_out(v={_i(w.llrx_auto_out_valid)},sop={_i(w.llrx_auto_out_sop)},"
            f"id={_h(_i(w.llrx_auto_out_data_id),2)}) "
            f"fcsm_rx(v={_i(f.auto_rx_in_valid)},sop={_i(f.auto_rx_in_sop)},"
            f"id={_h(_i(f.auto_rx_in_data_id),2)},dat={_i(f.pkt_is_data_pkt)},"
            f"cr={_i(f.pkt_is_cr_pkt)},crk={_i(f.pkt_is_crack_pkt)},"
            f"crc={_i(f.crc_corrupt)},st={_i(f.state)})"
        )

    # ---- PART A: M->S data, trace the SLAVE RX chain (WORKING reference) ----
    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)

    async def trace_slave_rx(n):
        for cyc in range(n):
            await RisingEdge(dut.hclk)
            w = wlink(dut, "s"); f = fcsm(dut, "s")
            if (_i(w.llrx_auto_out_valid) or _i(f.auto_rx_in_valid) or
                    _i(f.pkt_is_data_pkt) or _i(w.phy_link_rx_rx_link_data)):
                log.info(f"[M2S/sRX c{cyc:4d}] {rxsnap('s', dut.m_pad_tx_skid)}")

    log.info("=== PART A: M->S data -> SLAVE RX chain (WORKING reference) ===")
    tA = cocotb.start_soon(trace_slave_rx(2500))
    await tb.ahb_tx_write_packet("m", [word0, 0x0] + payload)
    await ClockCycles(dut.hclk, 1500)
    await tA

    # ---- PART B: S->M sideband, trace the MASTER RX chain (BROKEN) ----
    async def trace_master_rx(n):
        for cyc in range(n):
            await RisingEdge(dut.hclk)
            w = wlink(dut, "m"); f = fcsm(dut, "m")
            if (_i(dut.s_pad_tx_skid) or _i(w.phy_link_rx_rx_link_data) or
                    _i(w.llrx_io_link_data) or _i(w.llrx_auto_out_valid) or
                    _i(f.auto_rx_in_valid)):
                log.info(f"[S2M/mRX c{cyc:4d}] {rxsnap('m', dut.s_pad_tx_skid)}")

    log.info("=== PART B: S->M sideband -> MASTER RX chain (BROKEN) ===")
    tB = cocotb.start_soon(trace_master_rx(4500))
    for off in (0x00, 0x04, 0x08, 0x0C):
        await tb.ahb_fifo_read_word("s", off)
    await ClockCycles(dut.hclk, 3000)
    await tB

    m_rel = await tb.m_apb.read(APB_RELEASED_ACC)
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    log.info(f"  master RELEASED_ACC=0x{m_rel:08x} PAIR_CREDIT=0x{m_pcc:08x}")
