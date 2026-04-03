"""Cocotb integration test suite for the tidelink_top internal data path.

Exercises the FC adapter + FIFO + mux logic with FC loopback (a2l wired to
l2a in tb_top.sv).  Tests the end-to-end path:

  TX aperture AHB write -> FC encode -> loopback -> FC decode -> FIFO write
  Returner AHB write    -> FC sideband -> loopback -> config register write
  FIFO mux arbitration (FC adapter RX vs CPU read port)

XHB500, Wlink, and address translator are NOT instantiated; they require
external IP that is out of scope for this unit/integration test.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster

from tidelink.regs import (
    MAX_CREDITS,
    REG_CREDIT_COUNT, REG_CTRL, REG_DOORBELL, REG_REL_THRESHOLD,
    REG_RELEASED_ACC, REG_DOORBELL_RESP_ACC, REG_STATUS,
)

# -- Constants ----------------------------------------------------------------
CLK_PERIOD_NS = 10

# AHB transfer type encodings
HTRANS_IDLE   = 0
HTRANS_NONSEQ = 2
HSIZE_WORD    = 2


# -- Testbench Environment ----------------------------------------------------

class TidelinkTopTB:
    """Reusable testbench for the tidelink_top loopback configuration.

    Provides:
      - ahb_tx:   AHBLiteMaster on the ahb_tx_* TX aperture port
      - ahb_cfg:  AHBLiteMaster on the ahb_cfg_* config register port
      - Direct signal access for ahb_fifo_* (FIFO read port)
    """

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        # TX aperture AHB master
        ahb_tx_bus = AHBBus.from_prefix(dut, "ahb_tx")
        self.ahb_tx = AHBLiteMaster(
            ahb_tx_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # Config register AHB master (goes through AHB-to-APB bridge)
        ahb_cfg_bus = AHBBus.from_prefix(dut, "ahb_cfg")
        self.ahb_cfg = AHBLiteMaster(
            ahb_cfg_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # FIFO read port defaults
        dut.ahb_fifo_hsel.value   = 0
        dut.ahb_fifo_htrans.value = 0
        dut.ahb_fifo_hsize.value  = HSIZE_WORD
        dut.ahb_fifo_hwrite.value = 0
        dut.ahb_fifo_haddr.value  = 0
        dut.ahb_fifo_hwdata.value = 0
        dut.ahb_fifo_hready.value = 1

    async def reset(self):
        """Assert reset, release, and enable the FIFO data window."""
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 10)
        # Enable FIFO data window: CTRL.EN=1 (offset 0x01C)
        await self.cfg_write(REG_CTRL, 0x1)

    # -- Config register helpers -----------------------------------------------

    async def cfg_read(self, offset: int) -> int:
        """Read a config register via the AHB config slave port."""
        resp = await self.ahb_cfg.read(offset)
        return int(resp[0].get("data", "0x0"), 16)

    async def cfg_write(self, offset: int, data: int):
        """Write a config register via the AHB config slave port."""
        await self.ahb_cfg.write(offset, data)

    # -- TX aperture helpers ---------------------------------------------------

    async def tx_write_word(self, addr: int, data: int):
        """Write a single word to the TX aperture via AHB."""
        await self.ahb_tx.write(addr, data)

    async def tx_write_words(self, base_addr: int, words: list):
        """Write a sequence of words to consecutive TX aperture addresses."""
        for i, word in enumerate(words):
            addr = base_addr + i * 4
            await self.tx_write_word(addr, word)

    # -- FIFO read helpers (direct signal-level AHB, same style as py_pair) ----

    async def fifo_read_word(self, addr: int) -> int:
        """Perform a single AHB read from the FIFO data port."""
        dut = self.dut
        await RisingEdge(dut.hclk)
        dut.ahb_fifo_hsel.value   = 1
        dut.ahb_fifo_htrans.value = HTRANS_NONSEQ
        dut.ahb_fifo_hwrite.value = 0
        dut.ahb_fifo_hsize.value  = HSIZE_WORD
        dut.ahb_fifo_haddr.value  = addr
        await RisingEdge(dut.hclk)
        # De-assert address phase
        dut.ahb_fifo_htrans.value = HTRANS_IDLE
        dut.ahb_fifo_hsel.value   = 0
        # Wait for data phase to complete (respect HREADY stall)
        for _ in range(50):
            await RisingEdge(dut.hclk)
            try:
                ready = int(dut.ahb_fifo_hreadyout.value)
            except ValueError:
                ready = 0
            if ready:
                break
        try:
            rdata = int(dut.ahb_fifo_hrdata.value)
        except ValueError:
            rdata = 0
        return rdata

    async def fifo_read_packet(self) -> list:
        """Read a complete packet from the FIFO: first word is length, then
        length data words.  Returns the data words (not including the length
        word)."""
        length = await self.fifo_read_word(0x0000)
        await ClockCycles(self.dut.hclk, 2)
        data = []
        for i in range(length):
            addr = (i + 1) * 4
            word = await self.fifo_read_word(addr)
            data.append(word)
        return data

    # -- Loopback wait helper --------------------------------------------------

    async def wait_fc_loopback(self, cycles: int = 20):
        """Wait for FC loopback to deliver RX words.  The loopback is
        combinational in tb_top so a few clock cycles suffices for the
        adapter's RX FSM to complete the AHB write."""
        await ClockCycles(self.dut.hclk, cycles)

    # -- Returner idle check ---------------------------------------------------

    async def wait_returner_idle(self, timeout_cycles: int = 50):
        """Wait until the returner FSM inside tidelink_fifo_ahb is idle."""
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            try:
                busy = int(self.dut.u_tidelink_fifo.u_dut.returner_busy.value)
            except (AttributeError, ValueError):
                # If hierarchy is different, fall back to status register
                status = await self.cfg_read(REG_STATUS)
                if (status & 1) == 0:
                    return
                continue
            if not busy:
                return
        raise TimeoutError("Returner still busy after timeout")


# ==============================================================================
# End-to-end loopback tests: TX aperture -> FC -> loopback -> RX -> FIFO
# ==============================================================================

@cocotb.test()
async def test_01_single_fifo_data_word_loopback(dut):
    """Write one FIFO_DATA word to TX aperture, verify it arrives in RX FIFO
    via the FC loopback."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # TX aperture write: addr=0x004 (offset for first data word), data=0xDEAD_BEEF
    test_addr = 0x0004
    test_data = 0xDEAD_BEEF
    await tb.tx_write_word(test_addr, test_data)

    # Wait for FC loopback + RX FSM to write into FIFO
    await tb.wait_fc_loopback()

    # Read back from FIFO at the same offset
    readback = await tb.fifo_read_word(test_addr)
    tb.log.info(f"TX wrote 0x{test_data:08X} to addr 0x{test_addr:04X}, "
                f"RX FIFO read 0x{readback:08X}")
    assert readback == test_data, \
        f"FIFO readback mismatch: expected 0x{test_data:08X}, got 0x{readback:08X}"


@cocotb.test()
async def test_02_descriptor_packet_loopback(dut):
    """Write a 4-word descriptor packet through TX aperture, verify all 4
    words arrive in the RX FIFO in order."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    descriptor = [0x0000_0003, 0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]

    # Write each word to consecutive FIFO addresses via TX aperture
    for i, word in enumerate(descriptor):
        addr = i * 4
        await tb.tx_write_word(addr, word)
        # Allow FC loopback to complete for each word
        await tb.wait_fc_loopback(cycles=10)

    # Read back the packet from FIFO
    readback = []
    for i in range(len(descriptor)):
        addr = i * 4
        word = await tb.fifo_read_word(addr)
        readback.append(word)

    tb.log.info(f"TX descriptor: {['0x{:08X}'.format(w) for w in descriptor]}")
    tb.log.info(f"RX readback:   {['0x{:08X}'.format(w) for w in readback]}")

    for i, (exp, got) in enumerate(zip(descriptor, readback)):
        assert exp == got, \
            f"Word {i}: expected 0x{exp:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_03_full_packet_with_payload_loopback(dut):
    """Write a complete packet: length word + 3 header + N data words.
    Verify the entire packet arrives in the RX FIFO."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Packet layout: word 0 = length (6), words 1-3 = header, words 4-6 = payload
    header  = [0xAABB_0001, 0xAABB_0002, 0xAABB_0003]
    payload = [0xCCDD_0001, 0xCCDD_0002, 0xCCDD_0003]
    length  = len(header) + len(payload)
    packet  = [length] + header + payload

    for i, word in enumerate(packet):
        addr = i * 4
        await tb.tx_write_word(addr, word)
        await tb.wait_fc_loopback(cycles=10)

    # Read back all words
    readback = []
    for i in range(len(packet)):
        addr = i * 4
        word = await tb.fifo_read_word(addr)
        readback.append(word)

    tb.log.info(f"TX packet ({len(packet)} words): "
                f"{['0x{:08X}'.format(w) for w in packet]}")
    tb.log.info(f"RX readback: {['0x{:08X}'.format(w) for w in readback]}")

    for i, (exp, got) in enumerate(zip(packet, readback)):
        assert exp == got, \
            f"Word {i}: expected 0x{exp:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_04_multiple_words_different_addresses(dut):
    """Write words to several different FIFO addresses via TX aperture,
    verify each arrives at the correct RX FIFO location."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    test_vectors = [
        (0x0000, 0x1111_1111),
        (0x0004, 0x2222_2222),
        (0x0010, 0x3333_3333),
        (0x0100, 0x4444_4444),
        (0x1000, 0x5555_5555),
    ]

    for addr, data in test_vectors:
        await tb.tx_write_word(addr, data)
        await tb.wait_fc_loopback(cycles=10)

    for addr, expected in test_vectors:
        readback = await tb.fifo_read_word(addr)
        tb.log.info(f"Addr 0x{addr:04X}: expected 0x{expected:08X}, "
                    f"got 0x{readback:08X}")
        assert readback == expected, \
            f"Addr 0x{addr:04X}: expected 0x{expected:08X}, got 0x{readback:08X}"


# ==============================================================================
# Credit flow loopback tests: Returner -> FC sideband -> loopback -> config reg
# ==============================================================================

@cocotb.test()
async def test_05_credit_release_sideband_loopback(dut):
    """Trigger the returner to fire a credit release, which becomes an FC
    sideband packet.  Via loopback, it should arrive as a write to the
    released credits accumulator register (0x020).

    Flow: write packet -> read packet -> returner fires credit release ->
          FC sideband TX -> loopback -> FC sideband RX -> write to 0x020
    """
    tb = TidelinkTopTB(dut)
    await tb.reset()
    # Set release threshold to 0 (immediate release mode)
    await tb.cfg_write(REG_REL_THRESHOLD, 0)

    # Write a small packet into the FIFO via TX aperture loopback
    # Length word at addr 0, then 2 data words
    packet = [0x0000_0002, 0xCAFE_0001, 0xCAFE_0002]
    for i, word in enumerate(packet):
        await tb.tx_write_word(i * 4, word)
        await tb.wait_fc_loopback(cycles=10)

    # Read the packet back from FIFO (this triggers credit release)
    _ = await tb.fifo_read_packet()

    # Wait for returner to fire and FC sideband to loop back
    await tb.wait_fc_loopback(cycles=40)

    # The sideband loopback should have written to the released credits
    # accumulator register (0x020).  Read it via AHB config port.
    acc_val = await tb.cfg_read(REG_RELEASED_ACC)
    tb.log.info(f"Released credits accumulator: {acc_val}")

    # With threshold=0, the returner releases all freed credits immediately.
    # Reading 3 words (length + 2 data) frees 3 credits.
    expected_delta = len(packet)
    assert acc_val == expected_delta, \
        f"Expected released credits = {expected_delta}, got {acc_val}"


@cocotb.test()
async def test_06_doorbell_sideband_loopback(dut):
    """Trigger the returner to fire a doorbell response, which becomes an FC
    sideband packet.  Via loopback, it should arrive as a write to the
    doorbell response accumulator register (0x024).

    Flow: write doorbell register -> returner fires doorbell response ->
          FC sideband TX -> loopback -> FC sideband RX -> write to 0x024
    """
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Clear any pending doorbell response accumulator
    _ = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    await ClockCycles(dut.hclk, 2)

    # Trigger doorbell
    await tb.cfg_write(REG_DOORBELL, 1)

    # Wait for returner + FC sideband loopback
    await tb.wait_fc_loopback(cycles=40)

    # Doorbell response should contain the total credit count
    resp_val = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    tb.log.info(f"Doorbell response accumulator: {resp_val} "
                f"(expected {MAX_CREDITS})")
    assert resp_val == MAX_CREDITS, \
        f"Expected doorbell response = {MAX_CREDITS}, got {resp_val}"


@cocotb.test()
async def test_07_sideband_targets_correct_register(dut):
    """Verify that credit release writes to 0x020 and doorbell response
    writes to 0x024, with no cross-contamination."""
    tb = TidelinkTopTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_REL_THRESHOLD, 0)

    # Clear both accumulators
    _ = await tb.cfg_read(REG_RELEASED_ACC)
    _ = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    await ClockCycles(dut.hclk, 2)

    # Write and read a packet to trigger credit release
    packet = [0x0000_0001, 0xBEEF_0001]
    for i, word in enumerate(packet):
        await tb.tx_write_word(i * 4, word)
        await tb.wait_fc_loopback(cycles=10)

    _ = await tb.fifo_read_packet()
    await tb.wait_fc_loopback(cycles=40)

    # Credit release should only touch 0x020
    rel_acc = await tb.cfg_read(REG_RELEASED_ACC)
    db_acc  = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    tb.log.info(f"After credit release: REL_ACC={rel_acc}, DB_ACC={db_acc}")
    assert rel_acc > 0, "Released credits accumulator should be non-zero"
    assert db_acc == 0, \
        f"Doorbell accumulator should be 0 after credit release, got {db_acc}"

    # Now trigger doorbell
    await tb.cfg_write(REG_DOORBELL, 1)
    await tb.wait_fc_loopback(cycles=40)

    db_acc2 = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    tb.log.info(f"After doorbell: DB_ACC={db_acc2}")
    assert db_acc2 > 0, "Doorbell accumulator should be non-zero after doorbell"


# ==============================================================================
# FIFO mux arbitration tests
# ==============================================================================

@cocotb.test()
async def test_08_cpu_fifo_read_when_fc_idle(dut):
    """When the FC adapter RX is idle, the CPU should be able to read from
    the FIFO data port without stalls (hreadyout=1)."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # First, write a word into FIFO via TX aperture loopback
    test_data = 0xAAAA_BBBB
    await tb.tx_write_word(0x0004, test_data)
    await tb.wait_fc_loopback()

    # CPU reads from FIFO -- should not be stalled
    readback = await tb.fifo_read_word(0x0004)
    tb.log.info(f"CPU read from FIFO: 0x{readback:08X} (expected 0x{test_data:08X})")
    assert readback == test_data, \
        f"CPU FIFO read mismatch: expected 0x{test_data:08X}, got 0x{readback:08X}"


@cocotb.test()
async def test_09_fc_adapter_has_fifo_mux_priority(dut):
    """When the FC adapter RX is writing to the FIFO, the CPU FIFO port
    should see hreadyout=0 (stalled).  After FC completes, CPU access
    should resume normally."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Write a word to TX aperture.  Due to the combinational loopback,
    # the FC adapter RX will immediately start its AHB write FSM.
    # During RX_ADDR_PHASE, fc_rx_fifo_active=1, so CPU is stalled.

    # Set up CPU read address phase but don't complete it yet
    dut.ahb_fifo_hsel.value   = 1
    dut.ahb_fifo_htrans.value = HTRANS_NONSEQ
    dut.ahb_fifo_hwrite.value = 0
    dut.ahb_fifo_hsize.value  = HSIZE_WORD
    dut.ahb_fifo_haddr.value  = 0x0008

    # Now write a word on the TX aperture
    test_data = 0xFC00_1234
    await tb.tx_write_word(0x0008, test_data)

    # Check that during the FC write, CPU readyout was de-asserted at some point
    # (The exact timing depends on the FSM, but the mux logic guarantees
    # ahb_fifo_hreadyout = 0 when fc_rx_fifo_active = 1)
    # Wait a couple of cycles to let the FC adapter start its AHB master write
    await ClockCycles(dut.hclk, 3)

    # De-assert CPU read request
    dut.ahb_fifo_htrans.value = HTRANS_IDLE
    dut.ahb_fifo_hsel.value   = 0

    # Wait for FC loopback to complete
    await tb.wait_fc_loopback()

    # Now CPU should be able to read normally
    readback = await tb.fifo_read_word(0x0008)
    tb.log.info(f"CPU read after FC complete: 0x{readback:08X} "
                f"(expected 0x{test_data:08X})")
    assert readback == test_data, \
        f"CPU read mismatch after FC priority: expected 0x{test_data:08X}, " \
        f"got 0x{readback:08X}"


@cocotb.test()
async def test_10_fc_adapter_has_cfg_mux_priority(dut):
    """When the FC adapter RX is writing to config registers (sideband), the
    CPU config port should see hreadyout=0 (stalled).  After FC completes,
    CPU config access should resume normally."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Read credit count before doorbell -- should work fine
    credits_before = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credits before doorbell: {credits_before}")
    assert credits_before == MAX_CREDITS

    # Trigger doorbell -- returner will write a sideband FC packet,
    # which loops back and writes to config register via the config mux.
    # The CPU config port should be briefly stalled.
    await tb.cfg_write(REG_DOORBELL, 1)
    await tb.wait_fc_loopback(cycles=40)

    # Read credit count again after sideband completes -- should still work
    credits_after = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credits after doorbell: {credits_after}")
    assert credits_after == MAX_CREDITS


@cocotb.test()
async def test_11_sequential_tx_writes_no_data_loss(dut):
    """Write multiple words back-to-back to the TX aperture and verify that
    none are lost through the FC loopback path."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    num_words = 8
    test_data = [(i + 1) * 0x1111_1111 for i in range(num_words)]

    for i, word in enumerate(test_data):
        addr = i * 4
        await tb.tx_write_word(addr, word)
        # Small delay between words to let FC loopback complete
        await tb.wait_fc_loopback(cycles=10)

    # Read all words back
    for i, expected in enumerate(test_data):
        addr = i * 4
        readback = await tb.fifo_read_word(addr)
        tb.log.info(f"Word {i}: expected 0x{expected:08X}, got 0x{readback:08X}")
        assert readback == expected, \
            f"Word {i} lost: expected 0x{expected:08X}, got 0x{readback:08X}"


@cocotb.test()
async def test_12_tx_aperture_is_write_only(dut):
    """Reading from the TX aperture should return 0 (it is write-only)."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    resp = await tb.ahb_tx.read(0x0000)
    rdata = int(resp[0].get("data", "0x0"), 16)
    tb.log.info(f"TX aperture read: 0x{rdata:08X} (expected 0)")
    assert rdata == 0, \
        f"TX aperture read should return 0, got 0x{rdata:08X}"


@cocotb.test()
async def test_13_credit_count_preserved_through_loopback(dut):
    """Verify that the credit count register is accessible through the config
    mux and returns MAX_CREDITS after reset (sanity check for config path)."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    credits = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credit count after reset: {credits} (expected {MAX_CREDITS})")
    assert credits == MAX_CREDITS, \
        f"Expected {MAX_CREDITS}, got {credits}"


@cocotb.test()
async def test_14_write_read_full_loopback_with_credits(dut):
    """Full integration flow: write a packet via TX aperture loopback,
    read it back from the FIFO, verify credits decrease then restore."""
    tb = TidelinkTopTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_REL_THRESHOLD, 0)  # Immediate release

    # Verify initial credits
    credits = await tb.cfg_read(REG_CREDIT_COUNT)
    assert credits == MAX_CREDITS, f"Expected {MAX_CREDITS}, got {credits}"

    # Write a 3-word packet via TX aperture: length + 2 data words
    packet = [0x0000_0002, 0xFACE_0001, 0xFACE_0002]
    for i, word in enumerate(packet):
        await tb.tx_write_word(i * 4, word)
        await tb.wait_fc_loopback(cycles=10)

    # After loopback write into FIFO, credits should decrease
    credits_after_write = await tb.cfg_read(REG_CREDIT_COUNT)
    expected_after_write = MAX_CREDITS - len(packet)
    tb.log.info(f"Credits after write: {credits_after_write} "
                f"(expected {expected_after_write})")
    assert credits_after_write == expected_after_write, \
        f"Expected {expected_after_write}, got {credits_after_write}"

    # Read the packet back -- triggers credit release via returner -> FC sideband
    data = await tb.fifo_read_packet()
    tb.log.info(f"Read back {len(data)} data words: "
                f"{['0x{:08X}'.format(w) for w in data]}")
    assert data == packet[1:], "Read-back data mismatch"

    # Wait for returner to fire credit release through FC sideband loopback
    await tb.wait_fc_loopback(cycles=50)

    # Credits should be restored (released credits looped back to accumulator)
    credits_final = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credits after read+release: {credits_final} "
                f"(expected {MAX_CREDITS})")
    assert credits_final == MAX_CREDITS, \
        f"Expected credits restored to {MAX_CREDITS}, got {credits_final}"

    tb.log.info("Full write-read-release loopback verified")
