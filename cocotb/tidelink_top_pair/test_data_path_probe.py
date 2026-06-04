"""Localize the M->S DATA-path cut (sideband works, bulk data doesn't).

Injects one AHB data packet at the master TX aperture and traces, per cycle,
the FCSM state on both dies plus the FC-adapter submit/receive/route signals,
to pinpoint where PKT_FIFO_DATA dies. Key gate (WlinkGenericFCSM_6.v:535):
LINK_IDLE(4) -> LINK_DATA(5) needs a2l_fc_replay_link_valid & ~fe_rx_is_full.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full, APB_R8_SLOT0, R8_SLOT0_OFF, APB_PKT_WORD_LEN,
)


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_data_path_probe(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    mfa  = dut.u_master.u_fc_adapter
    sfa  = dut.u_slave.u_fc_adapter
    mfsm = dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl
    sfsm = dut.u_slave.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl

    # FCSM state BEFORE injecting data.
    tb.log.info(f"[dp] pre-inject  M.fcsm={_i(mfsm.state)} S.fcsm={_i(sfsm.state)} "
                f"M.a2l_link_valid={_i(mfsm.a2l_fc_replay_link_valid)} "
                f"M.fe_rx_full={_i(mfsm.fe_rx_is_full)} "
                f"S.fe_rx_full={_i(sfsm.fe_rx_is_full)}")

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    await tb.ahb_tx_write_packet("m", [word0, 0x0] + payload)

    prev = None
    m_a2l = s_l2a = s_fifo = 0
    for cyc in range(2500):
        await RisingEdge(dut.hclk)
        ms, ss = _i(mfsm.state), _i(sfsm.state)
        ma2l = _i(mfa.tl_fc_a2l_valid); mrdy = _i(mfa.tl_fc_a2l_ready)
        sl2a = _i(sfa.tl_fc_l2a_valid)
        sfv  = _i(sfa.fc_rx_fifo_valid); sif = _i(sfa.rx_is_fifo)
        spt  = _i(sfa.rx_pkt_type)
        mlv  = _i(mfsm.a2l_fc_replay_link_valid); mfull = _i(mfsm.fe_rx_is_full)
        m_a2l += (ma2l or 0); s_l2a += (sl2a or 0); s_fifo += (sfv or 0)
        cur = (ms, ss)
        if cur != prev:
            tb.log.info(f"[dp] cyc={cyc:4d} FCSM M={ms} S={ss}  "
                        f"M.a2l_link_valid={mlv} M.fe_rx_full={mfull}")
            prev = cur
        if ma2l or sl2a or sfv:
            wtxt = _i(sfa.rx_fc_word_r)
            wtxt = "----" if wtxt is None else f"0x{wtxt:012x}"
            tb.log.info(f"[dp] cyc={cyc:4d} M.a2l_v={ma2l}/rdy={mrdy} "
                        f"S.l2a_v={sl2a} S.rx_word={wtxt} ptype={spt} "
                        f"is_fifo={sif} fifo_valid={sfv}")

    s_pkt_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    tb.log.info(f"[dp] SUMMARY  M.a2l={m_a2l} S.l2a={s_l2a} S.fifo_wr={s_fifo}  "
                f"final M.fcsm={_i(mfsm.state)} S.fcsm={_i(sfsm.state)}  "
                f"slave PKT_LEN={s_pkt_len}")
    tb.log.info("[dp] VERDICT: " + (
        "master never submits (a2l=0) -> TX/returner side" if m_a2l == 0 else
        "master submits but FCSM never reaches LINK_DATA(5) -> credit/replay gate" if _i(mfsm.state) != 5 and s_l2a == 0 else
        "data reaches slave but not routed to FIFO -> rx classify" if s_l2a and not s_fifo else
        "data written to FIFO -> read-path bug" if s_fifo else
        "inconclusive"))
