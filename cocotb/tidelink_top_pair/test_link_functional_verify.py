"""Does the baseline (zero-skew) link ACTUALLY work, with test artifacts removed?

The probe showed the M->S doorbell IS decoded and acc1_write fires, but
DOORBELL_RESPONSE_ACC is READ-TO-CLEAR (apb_regs.sv:302) and increments by
the packet payload (0x1000), so test_05's read(before)->ring->read(after)
with `after > before` is a flawed comparison (the before-read clears it).

This test removes the artifact two ways and adds the real data path:
  A) Doorbell done right: read-to-clear, ring ONE doorbell, single read ->
     expect the register to read a single increment (nonzero). Also probe
     the raw register signal right after the ring.
  B) Data path (test_08 logic): AHB packet M->S -> read back from slave RX
     FIFO -> expect the payload to match.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_DOORBELL,
    APB_DOORBELL_RESP_ACC,
    APB_PKT_WORD_LEN,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_doorbell_done_right(dut):
    tb = PairTB(dut)
    await run_bringup_full(tb)
    rg = dut.u_slave.u_tidelink_fifo.u_apb_regs

    # Clear the read-to-clear accumulator.
    cleared = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(dut.hclk, 20)
    sig_after_clear = _i(rg.doorbell_response_acc)
    tb.log.info(f"  read-to-clear: APB returned {cleared}; reg signal now = {sig_after_clear}")

    # Ring exactly one M->S doorbell.
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(dut.hclk, 300)
    sig_after_ring = _i(rg.doorbell_response_acc)   # raw signal, NOT read-to-clear
    tb.log.info(f"  after 1 ring: reg signal (raw) = {sig_after_ring}")

    val = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)  # single APB read
    tb.log.info(f"  single APB read after ring = {val}")

    assert sig_after_ring not in (0, None), (
        f"doorbell_response_acc raw signal did not increment after ring "
        f"(={sig_after_ring}) -> doorbell NOT delivered")
    tb.log.info("  PASS: M->S doorbell delivered + consumed (reg incremented)")


@cocotb.test()
async def test_data_path_master_to_slave(dut):
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
    await tb.ahb_tx_write_packet("m", words)
    await ClockCycles(dut.hclk, 2000)

    s_pkt_len = await tb.s_apb.read(APB_PKT_WORD_LEN)
    s_w2 = await tb.ahb_fifo_read_word("s", 0x08)
    s_w3 = await tb.ahb_fifo_read_word("s", 0x0C)
    tb.log.info(f"  slave PKT_LEN=0x{s_pkt_len:x} FIFO w2=0x{s_w2:08x} w3=0x{s_w3:08x}")
    tb.log.info(f"  expected payload [0x{payload[0]:08x}, 0x{payload[1]:08x}]")

    ok = (s_w2 == payload[0] and s_w3 == payload[1])
    tb.log.info("  PASS: data path M->S delivers payload" if ok else
                "  FAIL: data path M->S corrupted/lost")
    assert ok, (f"data path mismatch: read [0x{s_w2:08x},0x{s_w3:08x}] "
                f"len=0x{s_pkt_len:x}")
