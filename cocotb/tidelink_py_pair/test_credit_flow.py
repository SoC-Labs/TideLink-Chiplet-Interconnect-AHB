"""Tests for write/read packets with credit tracking."""

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from py_pair_helpers import (
    setup_with_pair, apb_write, apb_read, fifo_write_packet,
    OFF_DOORBELL, OFF_DOORBELL_RESPONSE, OFF_CREDIT_COUNT,
    MAX_CREDITS,
)


@cocotb.test()
async def test_06_write_packets_then_pair_resets(dut):
    """Write several packets into the DUT's FIFO (consuming credits), then
    simulate the pair resetting. The DUT should respond with the correct
    REDUCED free credit count.

    1. Both sides come out of reset, exchange initial credit counts
    2. Write 3 packets of known sizes into DUT's FIFO (consuming credits)
    3. Read DUT's credit count via APB to confirm it decreased
    4. Pair resets -- rings DUT's doorbell
    5. DUT responds with its current (reduced) free credit count
    """
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)  # Clear doorbell response accumulator/IRQ
    await ClockCycles(dut.hclk, 2)

    # Write packets into the FIFO
    packets = [
        [0xAA000001, 0xAA000002, 0xAA000003],            # 3 data words -> 5 credits
        [0xBB000001, 0xBB000002],                          # 2 data words -> 4 credits
        [0xCC000001, 0xCC000002, 0xCC000003, 0xCC000004,  # 5 data words -> 7 credits
         0xCC000005],
    ]

    total_credits_used = 0
    for i, pkt_data in enumerate(packets):
        credits_for_pkt = len(pkt_data) + 2  # data + 2-word header
        total_credits_used += credits_for_pkt
        dut._log.info(f"Writing packet {i+1}: {len(pkt_data)} data words "
                      f"({credits_for_pkt} credits)")
        await fifo_write_packet(dut, pkt_data)

    expected_free = MAX_CREDITS - total_credits_used
    dut._log.info(f"Total credits used: {total_credits_used}, "
                  f"expected free: {expected_free}")

    # Wait for any returner activity from write_completes to complete
    await ClockCycles(dut.hclk, 20)

    # Verify DUT's credit count via APB
    hw_credit_count = await apb_read(dut, OFF_CREDIT_COUNT)
    dut._log.info(f"DUT credit count (APB read): {hw_credit_count}")
    assert hw_credit_count == expected_free, \
        f"DUT credit count: expected {expected_free}, got {hw_credit_count}"

    # Pair resets -- rings DUT's doorbell
    dut._log.info("=== Pair resets ===")
    pair.reset()
    pair.released_credits_acc = 0

    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    dut._log.info(f"Pair received from DUT: {pair.released_credits_acc} credits "
                  f"(expected {expected_free})")
    assert pair.released_credits_acc == expected_free, \
        (f"DUT should report {expected_free} free credits after writing "
         f"{total_credits_used} credits, got {pair.released_credits_acc}")

    for line_out in pair.log_lines:
        dut._log.info(line_out)


@cocotb.test()
async def test_07_write_and_read_packets_then_pair_resets(dut):
    """Write packets, read some back (freeing credits), then pair resets.
    Verify the DUT reports the correct credit count reflecting both
    writes and reads.

    1. Write 3 packets (consume 16 credits)
    2. Read 1 packet back (free 5 credits)
    3. Pair resets -- DUT should report MAX_CREDITS - 16 + 5 = MAX_CREDITS - 11
    """
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)  # Clear doorbell response accumulator
    await ClockCycles(dut.hclk, 2)
    pair.released_credits_acc = 0

    # Write 3 packets
    pkt1_data = [0xAA000001, 0xAA000002, 0xAA000003]  # 5 credits
    pkt2_data = [0xBB000001, 0xBB000002]               # 4 credits
    pkt3_data = [0xCC000001, 0xCC000002, 0xCC000003,
                 0xCC000004, 0xCC000005]                # 7 credits

    for pkt_data in [pkt1_data, pkt2_data, pkt3_data]:
        await fifo_write_packet(dut, pkt_data)

    await ClockCycles(dut.hclk, 20)

    credits_written = (len(pkt1_data)+2) + (len(pkt2_data)+2) + (len(pkt3_data)+2)
    dut._log.info(f"Credits written: {credits_written}")

    hw_after_write = await apb_read(dut, OFF_CREDIT_COUNT)
    dut._log.info(f"Credit count after writes: {hw_after_write}")
    assert hw_after_write == MAX_CREDITS - credits_written

    # Read back packet 1 (free 5 credits)
    # Read Word 0 (packed header) from addr 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
    dut.ahbs_haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    # Read Word 1 (dest_addr) from addr 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
    dut.ahbs_haddr.value = 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
    dut.ahbs_haddr.value = 0x3FFF
    await RisingEdge(dut.hclk)

    # Read payload from addr 0x0008+
    for i in range(len(pkt1_data)):
        addr = (i + 2) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
        dut.ahbs_haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
        dut.ahbs_haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 15)

    credits_read_back = len(pkt1_data) + 2  # 5 credits freed
    expected_free = MAX_CREDITS - credits_written + credits_read_back
    dut._log.info(f"Credits read back: {credits_read_back}, "
                  f"expected free: {expected_free}")

    hw_after_read = await apb_read(dut, OFF_CREDIT_COUNT)
    dut._log.info(f"Credit count after read: {hw_after_read}")
    assert hw_after_read == expected_free, \
        f"Expected {expected_free}, got {hw_after_read}"

    # Pair resets -- rings DUT's doorbell
    dut._log.info("=== Pair resets ===")
    pair.reset()
    pair.released_credits_acc = 0

    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    dut._log.info(f"Pair received from DUT: {pair.released_credits_acc} credits "
                  f"(expected {expected_free})")
    assert pair.released_credits_acc == expected_free, \
        (f"DUT should report {expected_free} free credits "
         f"(wrote {credits_written}, read back {credits_read_back}), "
         f"got {pair.released_credits_acc}")

    for line_out in pair.log_lines:
        dut._log.info(line_out)
