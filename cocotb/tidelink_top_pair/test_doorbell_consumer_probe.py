"""Probe the slave RX consumer during a single M->S doorbell (zero-skew baseline).

Question: the M->S doorbell reaches the slave FC adapter (l2a=1) but
DOORBELL_RESPONSE_ACC never increments. Is the received 48-bit FC word a
correct SIDEBAND doorbell (pkt_type==0b01, addr 0x024) that a real consumer
bug drops -- or is it garbage (mis-classified -> dumped to FIFO)?

Captures, every slave-hclk cycle in a window after the ring, the decisive
signals named by the RTL trace:
  rx_fc_word_r[47:0], rx_pkt_type[1:0], rx_is_fifo, rx_state_r,
  fc_rx_cfg_psel, fc_rx_cfg_paddr, fc_rx_fifo_valid,
  apb_regs.acc1_write, apb_regs.doorbell_response_acc
"""
import cocotb
from cocotb.triggers import RisingEdge

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
)


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_doorbell_consumer_probe(dut):
    tb = PairTB(dut)
    await run_bringup_full(tb)

    fa = dut.u_slave.u_fc_adapter
    rg = dut.u_slave.u_tidelink_fifo.u_apb_regs

    s_before = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"[probe] slave DOORBELL_RESP_ACC before = {s_before}")

    # Ring one M->S doorbell.
    await tb.m_apb.write(APB_DOORBELL, 1)

    seen_l2a = 0
    seen_cfg = 0
    seen_fifo = 0
    seen_acc1 = 0
    for cyc in range(800):
        await RisingEdge(dut.hclk)
        l2a   = _i(fa.tl_fc_l2a_valid)
        psel  = _i(fa.fc_rx_cfg_psel)
        fifo  = _i(fa.fc_rx_fifo_valid)
        acc1  = _i(rg.acc1_write)
        # Log any "interesting" cycle.
        if l2a or psel or fifo or acc1:
            word  = _i(fa.rx_fc_word_r)
            ptype = _i(fa.rx_pkt_type)
            isf   = _i(fa.rx_is_fifo)
            st    = _i(fa.rx_state_r)
            paddr = _i(fa.fc_rx_cfg_paddr)
            wtxt = "----" if word is None else f"0x{word:012x}"
            ptxt = "-" if ptype is None else f"0b{ptype:02b}"
            patxt = "---" if paddr is None else f"0x{paddr:03x}"
            tb.log.info(
                f"[probe] cyc={cyc:4d} l2a={l2a} word={wtxt} ptype={ptxt} "
                f"is_fifo={isf} rx_state={st} | cfg_psel={psel} cfg_paddr={patxt} "
                f"fifo_valid={fifo} acc1={acc1}"
            )
        seen_l2a  += (l2a  or 0)
        seen_cfg  += (psel or 0)
        seen_fifo += (fifo or 0)
        seen_acc1 += (acc1 or 0)

    s_after = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(
        f"[probe] SUMMARY  l2a_cycles={seen_l2a} cfg_psel_cycles={seen_cfg} "
        f"fifo_valid_cycles={seen_fifo} acc1_cycles={seen_acc1}  "
        f"RESP_ACC {s_before}->{s_after}"
    )
    tb.log.info(
        "[probe] VERDICT: "
        + ("acc1 fired -> consumer OK (bug elsewhere)" if seen_acc1 else
           "doorbell routed to FIFO (mis-classified word)" if seen_fifo and not seen_cfg else
           "took SIDEBAND route but no acc1 (decode/addr gate)" if seen_cfg and not seen_acc1 else
           "l2a never pulsed (nothing arrived)" if not seen_l2a else
           "inconclusive")
    )
