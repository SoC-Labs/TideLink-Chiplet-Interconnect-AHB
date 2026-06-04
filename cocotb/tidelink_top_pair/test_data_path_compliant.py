"""Re-test the M->S data path with an AHB-COMPLIANT TX driver.

The stock _ahb_tx_write_word drives hwdata then checks hready in the SAME
timestep; since the FC adapter asserts hreadyout combinationally when the
skid is empty, the loop breaks immediately and re-drives hwdata=0 in that
same cycle -> hwdata is 0 for the whole data phase -> payload ships as 0.
That is a racy non-compliant driver, not necessarily an RTL bug.

This driver HOLDS hwdata across the data-phase cycle (await edge FIRST, then
check hready), which is what a compliant AHB master / the real
axi_ahblite_bridge does. If the payload now arrives intact, the RTL data
path is fine and test_08 was a TB artifact.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full, APB_R8_SLOT0, R8_SLOT0_OFF, APB_PKT_WORD_LEN,
)


async def ahb_tx_write_compliant(tb, side, byte_addr, data):
    dut = tb.dut
    g = lambda n: getattr(dut, f"{side}_ahb_tx_{n}")
    hsel, haddr, htrans = g("hsel"), g("haddr"), g("htrans")
    hsize, hwrite, hwdata = g("hsize"), g("hwrite"), g("hwdata")
    hready = g("hready")

    await RisingEdge(dut.hclk)
    for _ in range(50):
        try:
            if int(hready.value):
                break
        except ValueError:
            pass
        await RisingEdge(dut.hclk)
    # Address phase
    hsel.value, htrans.value, hsize.value, hwrite.value = 1, 2, 2, 1
    haddr.value = byte_addr & ((1 << 14) - 1)
    await RisingEdge(dut.hclk)
    # Data phase — drive data and HOLD it across the cycle.
    hsel.value, htrans.value, hwrite.value = 0, 0, 0
    hwdata.value = data & 0xFFFFFFFF
    for _ in range(50):
        await RisingEdge(dut.hclk)        # hold hwdata for the cycle FIRST
        try:
            if int(hready.value):
                break
        except ValueError:
            pass
    hwdata.value = 0


@cocotb.test()
async def test_data_path_compliant_driver(dut):
    from tidelink.packet import encode_word0, PKT_WR_REQ
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    payload = [0xDEADBEEF, 0xCAFEBABE]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    words = [word0, 0x0] + payload
    for i, w in enumerate(words):
        await ahb_tx_write_compliant(tb, "m", i * 4, w)
        await ClockCycles(dut.hclk, 4)

    await ClockCycles(dut.hclk, 2000)

    s_pkt_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    s_w2 = await tb.ahb_fifo_read_word("s", 0x08)
    s_w3 = await tb.ahb_fifo_read_word("s", 0x0C)
    tb.log.info(f"  [compliant] slave PKT_LEN=0x{s_pkt_len:x} "
                f"FIFO w2=0x{s_w2:08x} w3=0x{s_w3:08x}")
    tb.log.info(f"  [compliant] expected [0x{payload[0]:08x}, 0x{payload[1]:08x}]")

    ok = (s_w2 == payload[0] and s_w3 == payload[1])
    tb.log.info("  [compliant] PASS: data path works with compliant driver "
                "-> test_08 was a TB artifact" if ok else
                "  [compliant] FAIL: payload still wrong -> real RTL data-capture bug")
    assert ok, (f"data mismatch read [0x{s_w2:08x},0x{s_w3:08x}] len=0x{s_pkt_len:x}")
