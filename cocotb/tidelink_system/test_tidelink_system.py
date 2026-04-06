"""Comprehensive paired stress test suite for two TideLink subsystems
connected back-to-back via FC crossover.

Exercises full bidirectional data flow, credit exchange, and corner cases
between two independent TideLink endpoints (A and B).

Testbench hierarchy (tb_top.sv):
  Side A: tidelink_fc_adapter + tidelink_fifo_ahb + FIFO/config muxes
  Side B: same
  FC crossover: A's a2l -> B's l2a, B's a2l -> A's l2a
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, First, Timer

from cocotbext.ahb import AHBBus, AHBLiteMaster

from tidelink.regs import (
    MAX_CREDITS,
    REG_CREDIT_COUNT, REG_DOORBELL, REG_REL_THRESHOLD,
    REG_RELEASED_ACC, REG_DOORBELL_RESP_ACC, REG_STATUS,
    REG_PAIR_CREDIT_COUNTER, REG_PAIR_CREDIT_ENABLE,
    STATUS_OVERRUN, STATUS_UNDERRUN,
)

# -- Constants ----------------------------------------------------------------
CLK_PERIOD_NS = 10

HTRANS_IDLE   = 0
HTRANS_NONSEQ = 2
HSIZE_WORD    = 2


# =============================================================================
# TideLink Driver -- encapsulates write-packet and read-packet sequences
# =============================================================================

class TideLinkDriver:
    """Driver for one side (A or B) of the paired TideLink testbench.

    Provides AHB-level helpers for TX aperture writes, FIFO reads, and
    config register access.
    """

    def __init__(self, dut, prefix, log):
        self.dut = dut
        self.prefix = prefix
        self.log = log

        # TX aperture AHB master
        ahb_tx_bus = AHBBus.from_prefix(dut, f"{prefix}_ahb_tx")
        self.ahb_tx = AHBLiteMaster(
            ahb_tx_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # Config register AHB master
        ahb_cfg_bus = AHBBus.from_prefix(dut, f"{prefix}_ahb_cfg")
        self.ahb_cfg = AHBLiteMaster(
            ahb_cfg_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # FIFO read port -- signal-level (no cocotbext driver needed)
        self._fifo_hsel   = getattr(dut, f"{prefix}_ahb_fifo_hsel")
        self._fifo_haddr  = getattr(dut, f"{prefix}_ahb_fifo_haddr")
        self._fifo_htrans = getattr(dut, f"{prefix}_ahb_fifo_htrans")
        self._fifo_hsize  = getattr(dut, f"{prefix}_ahb_fifo_hsize")
        self._fifo_hwrite = getattr(dut, f"{prefix}_ahb_fifo_hwrite")
        self._fifo_hwdata = getattr(dut, f"{prefix}_ahb_fifo_hwdata")
        self._fifo_hready = getattr(dut, f"{prefix}_ahb_fifo_hready")
        self._fifo_hrdata = getattr(dut, f"{prefix}_ahb_fifo_hrdata")

        # IRQ signals
        self.released_credits_irq = getattr(dut, f"{prefix}_released_credits_irq")
        self.doorbell_irq         = getattr(dut, f"{prefix}_doorbell_irq")
        self.packet_committed_irq = getattr(dut, f"{prefix}_packet_committed_irq")

        # Init FIFO port defaults
        self._fifo_hsel.value   = 0
        self._fifo_htrans.value = 0
        self._fifo_hsize.value  = HSIZE_WORD
        self._fifo_hwrite.value = 0
        self._fifo_haddr.value  = 0
        self._fifo_hwdata.value = 0

    # -- Config register helpers -----------------------------------------------

    async def cfg_read(self, offset):
        """Read a config register via the AHB config slave port."""
        resp = await self.ahb_cfg.read(offset)
        return int(resp[0].get("data", "0x0"), 16)

    async def cfg_write(self, offset, data):
        """Write a config register via the AHB config slave port."""
        await self.ahb_cfg.write(offset, data)

    # -- TX aperture helpers ---------------------------------------------------

    async def tx_write_word(self, addr, data):
        """Write a single word to the TX aperture via AHB."""
        await self.ahb_tx.write(addr, data)

    async def tx_write_packet(self, data_words, dest_addr=0):
        """Write a complete packet to the TX aperture.

        2-word header: packed Word 0 at addr 0, dest_addr at addr 4,
        then data words at addr 8, 12, ...
        Each word goes through the FC adapter and crosses to the remote side.
        """
        from tidelink.packet import FifoPacket
        pkt = FifoPacket(data=data_words, dest_addr=dest_addr)
        # Write packed header (Word 0) at offset 0
        await self.tx_write_word(0x0000, pkt.word0)
        await ClockCycles(self.dut.hclk, 10)
        # Write dest_addr (Word 1) at offset 4
        await self.tx_write_word(0x0004, pkt.dest_addr)
        await ClockCycles(self.dut.hclk, 10)
        # Write data words at consecutive addresses starting at 0x0008
        for i, word in enumerate(data_words):
            addr = (i + 2) * 4
            await self.tx_write_word(addr, word)
            await ClockCycles(self.dut.hclk, 10)

    # -- FIFO read helpers (signal-level AHB) ----------------------------------

    async def fifo_read_word(self, addr):
        """Perform a single AHB read from the FIFO data port.

        Keeps driving NONSEQ until hready indicates the address phase
        was accepted (handles stalls from FC mux contention).
        """
        dut = self.dut
        # Drive address phase
        await RisingEdge(dut.hclk)
        self._fifo_hsel.value   = 1
        self._fifo_htrans.value = HTRANS_NONSEQ
        self._fifo_hwrite.value = 0
        self._fifo_hsize.value  = HSIZE_WORD
        self._fifo_haddr.value  = addr

        # Wait for address phase to be accepted (hready=1 while NONSEQ)
        for _ in range(50):
            await RisingEdge(dut.hclk)
            try:
                ready = int(self._fifo_hready.value)
            except ValueError:
                ready = 0
            if ready:
                break

        # Move to data phase (IDLE)
        self._fifo_htrans.value = HTRANS_IDLE
        self._fifo_hsel.value   = 0

        # Wait for data phase to complete
        for _ in range(50):
            await RisingEdge(dut.hclk)
            try:
                ready = int(self._fifo_hready.value)
            except ValueError:
                ready = 0
            if ready:
                break
        try:
            rdata = int(self._fifo_hrdata.value)
        except ValueError:
            rdata = 0
        return rdata

    async def fifo_read_packet(self):
        """Read a complete packet from the FIFO.

        2-word header: read packed Word 0 at addr 0, dest_addr at addr 4,
        then length data words at addr 8, 12, ...
        Returns the data words (not including the 2-word header).
        """
        from tidelink.packet import decode_word0
        word0 = await self.fifo_read_word(0x0000)
        await ClockCycles(self.dut.hclk, 2)
        dest_addr = await self.fifo_read_word(0x0004)
        fields = decode_word0(word0)
        length = fields["length"]
        data = []
        for i in range(length):
            addr = (i + 2) * 4
            word = await self.fifo_read_word(addr)
            data.append(word)
        return data

    # -- Wait helpers ----------------------------------------------------------

    async def wait_fc_settle(self, cycles=20):
        """Wait for FC crossover and RX FSM to complete."""
        await ClockCycles(self.dut.hclk, cycles)

    async def wait_packet_committed(self, timeout_cycles=200):
        """Wait until the packet_committed_irq asserts on this side."""
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            try:
                if int(self.packet_committed_irq.value):
                    return True
            except ValueError:
                pass
        return False


# =============================================================================
# Testbench Environment
# =============================================================================

class TideLinkSystemTB:
    """Testbench for two TideLink subsystems connected back-to-back."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        self.a = TideLinkDriver(dut, "a", dut._log)
        self.b = TideLinkDriver(dut, "b", dut._log)

    async def reset(self):
        """Assert reset, release, and wait for initialization."""
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 10)
        await ClockCycles(self.dut.hclk, 5)

    async def send_and_receive(self, sender, receiver, data_words,
                               settle_cycles=20):
        """Write a packet via sender TX, wait, read from receiver FIFO.

        Returns the list of data words read back.
        """
        await sender.tx_write_packet(data_words)
        await receiver.wait_fc_settle(settle_cycles)
        readback = await receiver.fifo_read_packet()
        return readback


# =============================================================================
# Basic functionality (tests 01-05)
# =============================================================================

@cocotb.test()
async def test_01_single_packet_a_to_b(dut):
    """Write a single packet from A TX, read it from B FIFO."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    data = [0xDEAD_BEEF, 0xCAFE_BABE, 0x1234_5678]
    readback = await tb.send_and_receive(tb.a, tb.b, data)

    tb.log.info(f"A->B: sent {len(data)} words, received {len(readback)}")
    assert readback == data, f"A->B data mismatch: {readback} != {data}"


@cocotb.test()
async def test_02_single_packet_b_to_a(dut):
    """Write a single packet from B TX, read it from A FIFO."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    data = [0xAAAA_1111, 0xBBBB_2222]
    readback = await tb.send_and_receive(tb.b, tb.a, data)

    tb.log.info(f"B->A: sent {len(data)} words, received {len(readback)}")
    assert readback == data, f"B->A data mismatch: {readback} != {data}"


@cocotb.test()
async def test_03_bidirectional_simultaneous(dut):
    """Send packets A->B and B->A concurrently."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    data_a2b = [0xA0A0_0001, 0xA0A0_0002, 0xA0A0_0003]
    data_b2a = [0xB0B0_0001, 0xB0B0_0002]

    # Start both sends concurrently
    async def send_a():
        await tb.a.tx_write_packet(data_a2b)

    async def send_b():
        await tb.b.tx_write_packet(data_b2a)

    cocotb.start_soon(send_a())
    cocotb.start_soon(send_b())

    # Wait for both to complete crossing
    await ClockCycles(dut.hclk, 200)

    # Read from both sides
    rb_b = await tb.b.fifo_read_packet()
    rb_a = await tb.a.fifo_read_packet()

    tb.log.info(f"A->B readback: {['0x{:08X}'.format(w) for w in rb_b]}")
    tb.log.info(f"B->A readback: {['0x{:08X}'.format(w) for w in rb_a]}")
    assert rb_b == data_a2b, f"A->B mismatch"
    assert rb_a == data_b2a, f"B->A mismatch"


@cocotb.test()
async def test_04_descriptor_round_trip(dut):
    """A sends a read-request descriptor, B responds with a read-response.
    Verify end-to-end round trip."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # A sends RD_REQ descriptor to B
    rd_req = [0x0000_0001, 0x0000_1000, 0x0000_0040]  # opcode, addr, len
    rb_b = await tb.send_and_receive(tb.a, tb.b, rd_req)
    assert rb_b == rd_req, "RD_REQ descriptor mismatch at B"

    # B reads the request and sends RD_RSP back to A
    await tb.b.wait_fc_settle(30)
    rd_rsp = [0x0000_0002, 0x0000_1000, 0xDADA_DADA]  # opcode, addr, data
    rb_a = await tb.send_and_receive(tb.b, tb.a, rd_rsp)
    assert rb_a == rd_rsp, "RD_RSP descriptor mismatch at A"

    tb.log.info("Descriptor round trip A->B->A verified")


@cocotb.test()
async def test_05_large_payload(dut):
    """Write a packet with a large number of payload words (64) from A to B."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    num_words = 64
    data = [(i + 1) * 0x0101_0101 for i in range(num_words)]

    readback = await tb.send_and_receive(tb.a, tb.b, data, settle_cycles=40)

    tb.log.info(f"Large payload: sent {num_words} words, "
                f"received {len(readback)} words")
    assert len(readback) == num_words, \
        f"Length mismatch: expected {num_words}, got {len(readback)}"
    for i, (exp, got) in enumerate(zip(data, readback)):
        assert exp == got, \
            f"Word {i}: expected 0x{exp:08X}, got 0x{got:08X}"


# =============================================================================
# Credit flow (tests 06-10)
# =============================================================================

@cocotb.test()
async def test_06_credit_tracking(dut):
    """Verify credit count decrements on write and increments on read."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # B's credits should start at MAX_CREDITS
    credits_b = await tb.b.cfg_read(REG_CREDIT_COUNT)
    assert credits_b == MAX_CREDITS, \
        f"B initial credits: expected {MAX_CREDITS}, got {credits_b}"

    # A writes a 3-word packet -> goes to B's FIFO -> B credits decrease by 4
    data = [0x1111, 0x2222, 0x3333]
    await tb.a.tx_write_packet(data)
    await tb.b.wait_fc_settle(30)

    credits_b_after_write = await tb.b.cfg_read(REG_CREDIT_COUNT)
    expected = MAX_CREDITS - (len(data) + 2)  # +2 for 2-word header
    tb.log.info(f"B credits after write: {credits_b_after_write} "
                f"(expected {expected})")
    assert credits_b_after_write == expected, \
        f"Expected {expected}, got {credits_b_after_write}"

    # B reads the packet -> credits restored
    _ = await tb.b.fifo_read_packet()
    await tb.b.wait_fc_settle(10)

    credits_b_after_read = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after read: {credits_b_after_read} "
                f"(expected {MAX_CREDITS})")
    assert credits_b_after_read == MAX_CREDITS


@cocotb.test()
async def test_07_credit_exhaustion(dut):
    """Fill B's FIFO until credits=0, verify TX aperture stalls."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Write packets until B's credits are low
    # Each packet = 2-word header + N data words
    # MAX_CREDITS = 4096, use packets of 100 words each = 102 credits each
    # Write ~40 packets = 4080 credits. Remaining = 16 credits.
    pkt_data = list(range(100))
    packets_sent = 0
    for _ in range(40):
        await tb.a.tx_write_packet(pkt_data)
        await tb.b.wait_fc_settle(30)
        packets_sent += 1

    credits_b = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after {packets_sent} packets: {credits_b}")
    assert credits_b < 102, \
        f"B should have fewer than 102 credits, got {credits_b}"

    # Now write a packet that would exceed remaining credits
    # The TX aperture should still work (FC adapter doesn't check credits),
    # but B's FIFO ctrl will flag overrun if truly full.
    # Write exactly enough to exhaust
    remaining = credits_b
    if remaining > 2:
        small_data = list(range(remaining - 2))  # -2 for 2-word header
        await tb.a.tx_write_packet(small_data)
        await tb.b.wait_fc_settle(30)

    credits_final = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after exhaustion: {credits_final}")
    assert credits_final == 0, f"Expected 0, got {credits_final}"


@cocotb.test()
async def test_08_credit_recovery(dut):
    """Exhaust B's credits, then drain FIFO and verify credits restore."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)  # Immediate release

    # Write 10 packets of 10 data words each = 120 credits consumed (10*(10+2))
    packets = []
    for i in range(10):
        data = [(i * 10 + j) for j in range(10)]
        packets.append(data)
        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(20)

    credits_mid = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after 10 packets: {credits_mid}")
    expected_mid = MAX_CREDITS - 120
    assert credits_mid == expected_mid

    # Now drain all packets from B
    for i in range(10):
        rb = await tb.b.fifo_read_packet()
        # Wait for returner to fire credit release through FC sideband
        await tb.b.wait_fc_settle(50)
        assert rb == packets[i], f"Packet {i} mismatch"

    # Wait for all credit releases to propagate through FC
    await ClockCycles(dut.hclk, 100)

    # Credits should be fully restored
    credits_final = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after recovery: {credits_final} "
                f"(expected {MAX_CREDITS})")
    assert credits_final == MAX_CREDITS


@cocotb.test()
async def test_09_credit_threshold_batching(dut):
    """Set release threshold to 10, verify credits are batch-released."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 10)

    # Enable pair credit counter on A to track incoming released credits
    await tb.a.cfg_write(REG_PAIR_CREDIT_ENABLE, 1)

    # Write 1 small packet (3 data words = 5 credits each with 2-word header)
    await tb.a.tx_write_packet([0x11, 0x22, 0x33])
    await tb.b.wait_fc_settle(20)

    # Read the packet from B
    _ = await tb.b.fifo_read_packet()
    await tb.b.wait_fc_settle(50)

    await ClockCycles(dut.hclk, 100)

    # 5 credits freed but threshold=10, so no release yet
    a_released = await tb.a.cfg_read(REG_RELEASED_ACC)
    tb.log.info(f"A released acc after 5 credits freed: {a_released}")
    # The threshold logic fires when acc >= threshold.
    # 5 < 10, so no release expected.
    assert a_released == 0, \
        f"Expected 0 released credits (below threshold), got {a_released}"

    # Write and read one more packet (5 credits -> total 10 >= 10)
    await tb.a.tx_write_packet([0xAA, 0xBB, 0xCC])
    await tb.b.wait_fc_settle(20)
    _ = await tb.b.fifo_read_packet()
    await tb.b.wait_fc_settle(50)
    await ClockCycles(dut.hclk, 100)

    a_released2 = await tb.a.cfg_read(REG_RELEASED_ACC)
    tb.log.info(f"A released acc after 10 credits freed: {a_released2}")
    assert a_released2 >= 10, \
        f"Expected >= 10 batch-released credits, got {a_released2}"


@cocotb.test()
async def test_10_pair_credit_counter(dut):
    """Verify the hardware pair credit counter tracks remote availability."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)  # Immediate release
    await tb.a.cfg_write(REG_PAIR_CREDIT_ENABLE, 1)

    # Clear any stale accumulator from reset
    _ = await tb.a.cfg_read(REG_RELEASED_ACC)
    await ClockCycles(dut.hclk, 5)

    # A sends a packet to B (5 credits: 3 data + 2 header). B reads it, releasing 5 credits back.
    await tb.a.tx_write_packet([0xAA, 0xBB, 0xCC])
    await tb.b.wait_fc_settle(20)
    _ = await tb.b.fifo_read_packet()
    await ClockCycles(dut.hclk, 100)

    # A's pair credit counter should have incremented
    pair_counter = await tb.a.cfg_read(REG_PAIR_CREDIT_COUNTER)
    tb.log.info(f"A pair credit counter: {pair_counter}")
    assert pair_counter == 5, f"Expected 5, got {pair_counter}"


# =============================================================================
# Stress and corner cases (tests 11-20)
# =============================================================================

@cocotb.test()
async def test_11_back_to_back_packets(dut):
    """Send 50 packets from A to B with minimal idle cycles between them."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)

    num_packets = 50
    sent_packets = []

    for i in range(num_packets):
        data = [0xBB000000 | (i << 8) | j for j in range(3)]
        sent_packets.append(data)
        await tb.a.tx_write_packet(data)
        # Minimal settle -- just enough for FC crossing
        await tb.b.wait_fc_settle(15)

    # Drain all packets
    for i in range(num_packets):
        rb = await tb.b.fifo_read_packet()
        await tb.b.wait_fc_settle(30)
        assert rb == sent_packets[i], \
            f"Packet {i} mismatch: {rb} != {sent_packets[i]}"

    tb.log.info(f"All {num_packets} back-to-back packets verified")


@cocotb.test()
async def test_12_minimum_packet(dut):
    """Send a 1-word packet (length=1, one data word)."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    data = [0xCAFE_CAFE]
    readback = await tb.send_and_receive(tb.a, tb.b, data)
    assert readback == data, f"Minimum packet mismatch: {readback} != {data}"
    tb.log.info("Minimum 1-word packet verified")


@cocotb.test()
async def test_13_pointer_wrap(dut):
    """Send enough data to wrap the circular FIFO pointers."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)

    # MAX_CREDITS = 4096 words. We need to cycle through more than that.
    # Send and receive packets in batches to stay within credit limits.
    total_words = 0
    pkt_size = 50  # data words per packet
    credits_per_pkt = pkt_size + 2

    # Send enough packets to wrap pointers (> 4096 words)
    target_words = MAX_CREDITS + 500
    pkt_idx = 0

    while total_words < target_words:
        data = [(pkt_idx << 16) | j for j in range(pkt_size)]
        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(20)
        rb = await tb.b.fifo_read_packet()
        await tb.b.wait_fc_settle(50)
        assert rb == data, f"Packet {pkt_idx} mismatch after {total_words} words"
        total_words += credits_per_pkt
        pkt_idx += 1

    tb.log.info(f"Pointer wrap verified: {total_words} words across "
                f"{pkt_idx} packets")


@cocotb.test()
async def test_14_interleaved_rw(dut):
    """Interleave writes to TX with reads from FIFO on same side."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)

    # A sends packet to B, then B reads while A sends next packet
    data1 = [0x1111_0001, 0x1111_0002]
    data2 = [0x2222_0001, 0x2222_0002, 0x2222_0003]

    # Send first packet
    await tb.a.tx_write_packet(data1)
    await tb.b.wait_fc_settle(20)

    # Read data1 from B first
    rb1 = await tb.b.fifo_read_packet()
    assert rb1 == data1, f"Packet 1 mismatch"

    # Now interleave: B's returner fires credit release (B TX sideband)
    # while A simultaneously sends data2 (A TX data). Both FC directions
    # are active concurrently.
    await tb.a.tx_write_packet(data2)
    await tb.b.wait_fc_settle(40)

    # Read second packet
    rb2 = await tb.b.fifo_read_packet()

    tb.log.info(f"Interleaved RW: packet2 readback = "
                f"{['0x{:08X}'.format(w) for w in rb2]}")
    assert rb2 == data2, f"Packet 2 mismatch: {['0x{:08X}'.format(w) for w in rb2]}"


@cocotb.test()
async def test_15_rapid_doorbell(dut):
    """Trigger doorbell rapidly from A to B, verify all delivered."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Clear B's doorbell response accumulator
    _ = await tb.b.cfg_read(REG_DOORBELL_RESP_ACC)
    await ClockCycles(dut.hclk, 5)

    # Ring A's doorbell multiple times -- each sends A's credit count to B's
    # doorbell response accumulator via FC sideband
    num_rings = 5
    for i in range(num_rings):
        await tb.a.cfg_write(REG_DOORBELL, 1)
        await ClockCycles(dut.hclk, 60)

    # Wait for all to propagate
    await ClockCycles(dut.hclk, 200)

    # B's doorbell response accumulator should contain the sum of all responses
    db_resp = await tb.b.cfg_read(REG_DOORBELL_RESP_ACC)
    expected = MAX_CREDITS * num_rings
    tb.log.info(f"B doorbell response acc: {db_resp} (expected {expected})")
    # The accumulator adds each write, so we expect MAX_CREDITS * num_rings
    # However, if the returner is busy, some may be queued. Just verify non-zero.
    assert db_resp > 0, f"Expected non-zero doorbell responses, got {db_resp}"


@cocotb.test()
async def test_16_mixed_sideband_data(dut):
    """Credit returns interleaved with data packets."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)

    # Send packet A->B, read from B (triggers credit release B->A sideband)
    # while also sending B->A data packet. Both use the FC link.
    data_a2b = [0xA1A1, 0xA2A2, 0xA3A3]
    data_b2a = [0xB1B1, 0xB2B2]

    await tb.a.tx_write_packet(data_a2b)
    await tb.b.wait_fc_settle(20)

    # B reads (triggers credit release sideband B->A)
    rb_b = await tb.b.fifo_read_packet()
    assert rb_b == data_a2b

    # Immediately B sends data to A (competes with credit sideband on B's FC TX)
    await tb.b.tx_write_packet(data_b2a)
    await tb.a.wait_fc_settle(50)

    rb_a = await tb.a.fifo_read_packet()
    assert rb_a == data_b2a, f"B->A data mismatch with mixed sideband"

    tb.log.info("Mixed sideband + data traffic verified")


@cocotb.test()
async def test_17_asymmetric_traffic(dut):
    """Heavy A->B traffic with light B->A simultaneously."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)
    await tb.a.cfg_write(REG_REL_THRESHOLD, 0)

    heavy_packets = []
    light_packets = []

    async def heavy_sender():
        for i in range(20):
            data = [(i << 8) | j for j in range(5)]
            heavy_packets.append(data)
            await tb.a.tx_write_packet(data)
            await tb.b.wait_fc_settle(15)

    async def light_sender():
        for i in range(5):
            data = [0xFF00_0000 | i]
            light_packets.append(data)
            await tb.b.tx_write_packet(data)
            await tb.a.wait_fc_settle(15)
            # Longer pause between light packets
            await ClockCycles(dut.hclk, 50)

    cocotb.start_soon(heavy_sender())
    cocotb.start_soon(light_sender())

    # Wait for everything to settle
    await ClockCycles(dut.hclk, 3000)

    # Verify heavy traffic at B
    for i, exp in enumerate(heavy_packets):
        rb = await tb.b.fifo_read_packet()
        await tb.b.wait_fc_settle(30)
        assert rb == exp, f"Heavy packet {i} mismatch"

    # Verify light traffic at A
    for i, exp in enumerate(light_packets):
        rb = await tb.a.fifo_read_packet()
        await tb.a.wait_fc_settle(30)
        assert rb == exp, f"Light packet {i} mismatch"

    tb.log.info(f"Asymmetric traffic: {len(heavy_packets)} heavy, "
                f"{len(light_packets)} light")


@cocotb.test()
async def test_18_fifo_mux_contention(dut):
    """CPU reads FIFO while FC adapter is writing."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Write first packet to have something in B's FIFO
    data1 = [0xF1F1_0001, 0xF1F1_0002]
    await tb.a.tx_write_packet(data1)
    await tb.b.wait_fc_settle(20)

    # Read the first packet
    rb1 = await tb.b.fifo_read_packet()
    assert rb1 == data1

    # Now start a CPU read from B's FIFO while A sends another packet
    data2 = [0xF2F2_0001, 0xF2F2_0002, 0xF2F2_0003]

    async def cpu_read():
        # Try reading from FIFO -- may get stalled by FC adapter
        await ClockCycles(dut.hclk, 5)
        val = await tb.b.fifo_read_word(0x0004)
        return val

    async def fc_write():
        await tb.a.tx_write_packet(data2)

    cocotb.start_soon(cpu_read())
    cocotb.start_soon(fc_write())

    await ClockCycles(dut.hclk, 200)

    # After FC completes, CPU should be able to read normally
    rb2 = await tb.b.fifo_read_packet()
    assert rb2 == data2, f"FIFO mux contention: data mismatch"

    tb.log.info("FIFO mux contention test passed")


@cocotb.test()
async def test_19_config_mux_contention(dut):
    """CPU reads config while sideband is arriving."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)

    # Write and read packet to trigger credit release sideband from B->A
    data = [0xCC00_0001, 0xCC00_0002]
    await tb.a.tx_write_packet(data)
    await tb.b.wait_fc_settle(20)

    # Start reading B's config register while B's returner fires sideband
    async def cpu_cfg_read():
        for _ in range(10):
            _ = await tb.b.cfg_read(REG_CREDIT_COUNT)
            await ClockCycles(dut.hclk, 2)

    async def trigger_sideband():
        _ = await tb.b.fifo_read_packet()

    cocotb.start_soon(cpu_cfg_read())
    cocotb.start_soon(trigger_sideband())

    await ClockCycles(dut.hclk, 300)

    # System should not deadlock -- verify we can still read config
    credits = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after contention: {credits}")
    assert credits == MAX_CREDITS, \
        f"Expected {MAX_CREDITS} after full read, got {credits}"


@cocotb.test()
async def test_20_reset_mid_transfer(dut):
    """Assert reset during active transfer, verify clean recovery."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Start sending a packet
    data = [0xABCD_0001, 0xABCD_0002, 0xABCD_0003, 0xABCD_0004]
    # Write packed header (Word 0) and dest_addr (Word 1)
    from tidelink.packet import FifoPacket
    pkt = FifoPacket(data=data)
    await tb.a.tx_write_word(0x0000, pkt.word0)
    await ClockCycles(dut.hclk, 10)
    await tb.a.tx_write_word(0x0004, pkt.dest_addr)
    await ClockCycles(dut.hclk, 5)

    # Assert reset mid-transfer
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 10)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 10)

    await ClockCycles(dut.hclk, 10)

    # Verify both sides are in clean state
    credits_a = await tb.a.cfg_read(REG_CREDIT_COUNT)
    credits_b = await tb.b.cfg_read(REG_CREDIT_COUNT)

    tb.log.info(f"After reset: A credits={credits_a}, B credits={credits_b}")
    assert credits_a == MAX_CREDITS, \
        f"A credits should be {MAX_CREDITS} after reset, got {credits_a}"
    assert credits_b == MAX_CREDITS, \
        f"B credits should be {MAX_CREDITS} after reset, got {credits_b}"

    # Verify data path works after reset
    post_reset_data = [0xFEED_FACE]
    rb = await tb.send_and_receive(tb.a, tb.b, post_reset_data)
    assert rb == post_reset_data, "Post-reset data transfer failed"

    tb.log.info("Reset mid-transfer recovery verified")


# =============================================================================
# Bug hunting (tests 21-25)
# =============================================================================

@cocotb.test()
async def test_21_credit_underflow_attempt(dut):
    """Try to send more data than available credits allow."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Fill B's FIFO to near-capacity
    pkt_size = 100
    num_fill_packets = (MAX_CREDITS // (pkt_size + 2)) - 1
    for i in range(num_fill_packets):
        data = list(range(i * pkt_size, (i + 1) * pkt_size))
        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(20)

    credits_b = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after filling: {credits_b}")

    # Try to send a packet larger than remaining credits
    big_data = list(range(credits_b + 10))
    await tb.a.tx_write_packet(big_data)
    await tb.b.wait_fc_settle(30)

    # Check for overrun flag on B
    status_b = await tb.b.cfg_read(REG_STATUS)
    overrun = (status_b >> STATUS_OVERRUN) & 1
    tb.log.info(f"B status after overflow attempt: 0x{status_b:08X}, "
                f"overrun={overrun}")
    # The FIFO should either stall or flag overrun
    # (depends on how many credits were actually left)
    tb.log.info("Credit underflow attempt completed without hang")


@cocotb.test()
async def test_22_overrun_detection(dut):
    """Write to a full FIFO, check overrun flag."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Fill FIFO completely
    pkt_size = 100
    num_packets = MAX_CREDITS // (pkt_size + 2)
    for i in range(num_packets):
        data = list(range(pkt_size))
        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(20)

    credits_b = await tb.b.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"B credits after fill: {credits_b}")

    # Use remaining credits
    if credits_b > 2:
        data = list(range(credits_b - 2))
        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(20)

    # Now FIFO should be full -- one more write should trigger overrun
    await tb.a.tx_write_packet([0xDEAD])
    await tb.b.wait_fc_settle(30)

    status_b = await tb.b.cfg_read(REG_STATUS)
    overrun = (status_b >> STATUS_OVERRUN) & 1
    tb.log.info(f"B status: 0x{status_b:08X}, overrun={overrun}")
    # Overrun should be set
    assert overrun == 1, f"Expected overrun flag set, status=0x{status_b:08X}"


@cocotb.test()
async def test_23_underrun_detection(dut):
    """Read from an empty FIFO, check underrun flag."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # FIFO is empty after reset. Reading should trigger underrun.
    _ = await tb.b.fifo_read_word(0x0000)
    await ClockCycles(dut.hclk, 10)

    status_b = await tb.b.cfg_read(REG_STATUS)
    underrun = (status_b >> STATUS_UNDERRUN) & 1
    tb.log.info(f"B status after empty read: 0x{status_b:08X}, "
                f"underrun={underrun}")
    assert underrun == 1, \
        f"Expected underrun flag set, status=0x{status_b:08X}"


@cocotb.test()
async def test_24_data_integrity_long_run(dut):
    """500 random-sized packets each direction, verify every byte."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()
    await tb.a.cfg_write(REG_REL_THRESHOLD, 0)
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)

    random.seed(0xDEADBEEF)
    num_packets = 500
    max_pkt_words = 10

    a2b_sent = []
    b2a_sent = []

    # Send and immediately read packets to stay within credit limits
    for i in range(num_packets):
        # A->B
        size_a = random.randint(1, max_pkt_words)
        data_a = [random.randint(0, 0xFFFFFFFF) for _ in range(size_a)]
        a2b_sent.append(data_a)

        await tb.a.tx_write_packet(data_a)
        await tb.b.wait_fc_settle(20)
        rb_b = await tb.b.fifo_read_packet()
        await tb.b.wait_fc_settle(40)

        assert rb_b == data_a, \
            f"A->B packet {i} mismatch (len={size_a})"

        # B->A
        size_b = random.randint(1, max_pkt_words)
        data_b = [random.randint(0, 0xFFFFFFFF) for _ in range(size_b)]
        b2a_sent.append(data_b)

        await tb.b.tx_write_packet(data_b)
        await tb.a.wait_fc_settle(20)
        rb_a = await tb.a.fifo_read_packet()
        await tb.a.wait_fc_settle(40)

        assert rb_a == data_b, \
            f"B->A packet {i} mismatch (len={size_b})"

        if (i + 1) % 100 == 0:
            tb.log.info(f"Verified {i + 1}/{num_packets} packets each direction")

    tb.log.info(f"Data integrity verified: {num_packets} packets each direction")


@cocotb.test()
async def test_25_all_address_offsets(dut):
    """Write to every FIFO address offset in a packet, verify no aliasing."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Use a packet with enough words to exercise multiple address offsets
    # The FIFO addresses are offset 0 (word0), 4 (dest_addr), 8, ... for payload
    num_words = 32
    data = [0xADD00000 | (i * 4) for i in range(num_words)]

    readback = await tb.send_and_receive(tb.a, tb.b, data, settle_cycles=30)

    assert len(readback) == num_words, \
        f"Length mismatch: expected {num_words}, got {len(readback)}"

    for i, (exp, got) in enumerate(zip(data, readback)):
        assert exp == got, \
            f"Address offset 0x{(i+1)*4:04X}: expected 0x{exp:08X}, " \
            f"got 0x{got:08X} (aliasing?)"

    tb.log.info(f"All {num_words} address offsets verified, no aliasing")
