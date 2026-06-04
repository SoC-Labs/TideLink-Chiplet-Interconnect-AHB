"""Probe what the slave RX adapter actually WRITES into its RX FIFO, with a
compliant AHB TX driver. Master TX is proven correct (skid=0x0008deadbeef);
this checks whether DEADBEEF/CAFEBABE reach the slave FIFO write port -- i.e.
whether the data crosses the link, independent of the AHB readback helper.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full, APB_R8_SLOT0, R8_SLOT0_OFF,
)
from test_data_path_compliant import ahb_tx_write_compliant


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_slave_rx_probe(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    sfa = dut.u_slave.u_fc_adapter
    writes = []

    async def watch(n):
        for _ in range(n):
            await RisingEdge(dut.hclk)
            fv = _i(sfa.fc_rx_fifo_valid)
            if fv:
                addr = _i(sfa.fc_rx_fifo_addr)
                wd   = _i(sfa.fc_rx_fifo_wdata)
                wr   = _i(sfa.fc_rx_fifo_write)
                writes.append((addr, wd))
                tb.log.info(f"[srx] FIFO WRITE addr=0x{addr:x} wdata=0x{wd:08x} write={wr}")

    w = cocotb.start_soon(watch(3000))

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    for i, wd in enumerate([word0, 0x0] + payload):
        await ahb_tx_write_compliant(tb, "m", i * 4, wd)
        await ClockCycles(dut.hclk, 4)
    await ClockCycles(dut.hclk, 2000)
    await w

    tb.log.info(f"[srx] SUMMARY writes={[(hex(a),hex(d)) for a,d in writes]}")
    got = {a: d for a, d in writes}
    ok = got.get(0x8) == 0xDEADBEEF and got.get(0xC) == 0xCAFEBABE
    tb.log.info("[srx] VERDICT: " + (
        "payload REACHES slave FIFO -> link OK, readback helper is the artifact"
        if ok else
        "payload does NOT reach slave FIFO correctly -> real link/RX data loss"))
