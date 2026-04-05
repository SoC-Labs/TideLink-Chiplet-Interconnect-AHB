"""Bug regression tests for tidelink pair."""

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from py_pair_helpers import (
    setup_with_pair, apb_write, apb_read, fifo_write_packet,
    OFF_DOORBELL, OFF_DOORBELL_RESPONSE, OFF_PKT_WORD_LEN, OFF_CREDIT_COUNT,
    MAX_CREDITS,
)


@cocotb.test()
async def test_bug1_metadata_stable_on_idle_bus(dut):
    """FIXED: packet_word_length is no longer corrupted by idle bus at haddr=0.

    After a packet completes, packet_word_length is cleared to 0 (by design).
    With haddr=0 and hsel=0 on an idle bus, the metadata capture should NOT
    fire (gated on valid_ahb_access = hsel && htrans[1] && hready).
    """
    pair = await setup_with_pair(dut)

    # Write a packet -- packet_word_length will be cleared to 0 on completion
    await fifo_write_packet(dut, [0x11, 0x22, 0x33])
    await ClockCycles(dut.hclk, 5)

    pkt_len_after_write = await apb_read(dut, OFF_PKT_WORD_LEN)
    dut._log.info(f"packet_word_length after write completion: {pkt_len_after_write}")
    assert pkt_len_after_write == 0, \
        f"packet_word_length should be cleared after completion, got {pkt_len_after_write}"

    # Leave bus idle at haddr=0 -- should NOT corrupt packet_word_length
    dut.ahbs_haddr.value  = 0
    dut.ahbs_hwrite.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_htrans.value = 0
    await ClockCycles(dut.hclk, 10)

    pkt_len_after_idle = await apb_read(dut, OFF_PKT_WORD_LEN)
    dut._log.info(f"packet_word_length after idle at addr 0: {pkt_len_after_idle}")
    assert pkt_len_after_idle == 0, \
        f"packet_word_length should remain 0 during idle, got {pkt_len_after_idle}"


@cocotb.test()
async def test_bug2_doorbell_lost_when_returner_busy(dut):
    """BUG: Doorbell pulse lost if returner is busy with another channel.

    doorbell_trigger is a 1-cycle self-clearing pulse. The returner only
    captures interrupts in ST_IDLE. If channel 0 (read completion) is
    mid-transfer when the doorbell fires, the pulse is gone before the
    returner can service it.
    """
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)  # Clear doorbell response accumulator
    await ClockCycles(dut.hclk, 2)
    pair.released_credits_acc = 0
    pair.log_lines.clear()

    # Write a packet
    await fifo_write_packet(dut, [0xAA, 0xBB, 0xCC])
    await ClockCycles(dut.hclk, 10)

    # Read the packet back -- last beat triggers read_complete -> channel 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
    dut.ahbs_haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    for i in range(3):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
        dut.ahbs_haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
        dut.ahbs_haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)

    # Channel 0 now active -- IMMEDIATELY ring doorbell while busy
    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 20)

    # Check what the pair received
    dut._log.info(f"Pair accumulated: {pair.released_credits_acc}")
    for line_out in pair.log_lines:
        dut._log.info(line_out)

    received_doorbell = any("4096" in l for l in pair.log_lines)

    dut._log.info(f"Doorbell response received by pair: {received_doorbell}")

    if not received_doorbell:
        dut._log.error("BUG CONFIRMED: Doorbell pulse was lost because "
                       "returner was busy with channel 0.")
    assert received_doorbell, \
        (f"BUG: Pair received {pair.released_credits_acc} credits but "
         f"no doorbell response (MAX_CREDITS={MAX_CREDITS}) was seen. "
         f"Doorbell pulse lost while returner was busy.")


@cocotb.test()
async def test_bug3_stale_packet_length_causes_spurious_hit(dut):
    """BUG: packet_word_length not cleared after packet completion.

    After a packet completes, the old packet_word_length persists and
    write_target_addr remains at old_length * 4. A subsequent AHB write
    to that stale address triggers a spurious completion.
    """
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)  # Clear doorbell response from reset
    await ClockCycles(dut.hclk, 2)

    # Write a packet with length=3. Target addr = 3*4 = 0xC
    await fifo_write_packet(dut, [0x11, 0x22, 0x33])
    await ClockCycles(dut.hclk, 10)

    credits_after_pkt = await apb_read(dut, OFF_CREDIT_COUNT)
    dut._log.info(f"Credit count after packet: {credits_after_pkt}")

    # Now do a raw AHB write to haddr=0xC (stale target address)
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x000C
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = 0xDEAD
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hwrite.value = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await ClockCycles(dut.hclk, 10)

    credits_after_spurious = await apb_read(dut, OFF_CREDIT_COUNT)
    dut._log.info(f"Credit count after spurious write to 0xC: {credits_after_spurious}")

    if credits_after_spurious != credits_after_pkt:
        dut._log.error(f"BUG CONFIRMED: Stale packet_word_length caused "
                       f"spurious hit. Credits {credits_after_pkt} -> "
                       f"{credits_after_spurious}.")
    assert credits_after_spurious == credits_after_pkt, \
        (f"BUG: Credit count changed from {credits_after_pkt} to "
         f"{credits_after_spurious}. packet_word_length should be "
         f"cleared after packet completion.")


@cocotb.test()
async def test_bug4_hit_fires_on_wrong_direction(dut):
    """BUG: write_complete fires during read operations.

    The hit signals are not gated on hwrite direction. write_complete
    can fire during a READ if haddr matches the write target address.
    """
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)  # Clear doorbell response from reset
    await ClockCycles(dut.hclk, 2)

    # Write a packet with length=2. Target = 2*4 = 0x8
    await fifo_write_packet(dut, [0xAA, 0xBB])
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 10)

    # Now do an AHB READ at haddr=0x8 (the write target address)
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0  # READ
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0008

    await RisingEdge(dut.hclk)
    await FallingEdge(dut.hclk)
    try:
        w_hit = int(dut.u_dut.u_fifo_mem.u_fifo_ctrl.write_complete.value)
    except ValueError:
        w_hit = 0

    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await RisingEdge(dut.hclk)

    dut._log.info(f"write_complete during READ at 0x8: {w_hit}")

    if w_hit == 1:
        dut._log.error("BUG CONFIRMED: write_complete fired during a READ. "
                       "Hit signal is not gated on hwrite direction.")
    assert w_hit == 0, \
        ("BUG: write_complete fired during a READ at the write target "
         "address. Hit signals should be gated on transfer direction.")
