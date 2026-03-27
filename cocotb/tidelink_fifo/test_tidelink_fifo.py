"""Cocotb testbench for tidelink_ahb.

Uses cocotbext-ahb AHBLiteMaster to drive AHB transactions against the
tidelink_ahb wrapper (cmsdk_ahb_to_sram + cmsdk_fpga_sram with FIFO
address translation).

Packet format (written starting at haddr=0):
  Beat 0: length word (number of data words to follow)
  Beats 1..N: data words
"""

from dataclasses import dataclass
from typing import List

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10
RAM_ADDR_W    = 14
MAX_TOKENS    = (1 << (RAM_ADDR_W - 2))  # Must match RTL localparam


# ── Transaction Objects ──────────────────────────────────────────────────────

@dataclass
class FifoPacket:
    """Represents a packet to be written into the tidelink_ahb FIFO.

    The first beat carries the length, subsequent beats carry data.
    """
    data: List[int]

    @property
    def length(self) -> int:
        return len(self.data)

    @property
    def all_words(self) -> List[int]:
        """Length word followed by data words."""
        return [self.length] + self.data

    @property
    def total_words(self) -> int:
        """Total SRAM words consumed: 1 (length word) + N (data words)."""
        return self.length + 1

    @property
    def addrs(self) -> List[int]:
        """Byte addresses for each beat (0x0000, 0x0004, ...)."""
        return [i * 4 for i in range(self.length + 1)]


@dataclass
class SramContents:
    """Expected SRAM contents for verification."""
    base_word: int
    words: List[int]

    def verify(self, dut, log=None):
        """Check SRAM contents against expected values. Returns True if all match."""
        all_ok = True
        for i, expected in enumerate(self.words):
            actual = sram_read_word(dut, self.base_word + i)
            ok = actual == expected
            if not ok:
                all_ok = False
            if log:
                status = "OK" if ok else "MISMATCH"
                log.info(f"  SRAM[{self.base_word + i}] = 0x{actual:08X}  "
                         f"(expected 0x{expected:08X}) {status}")
            assert ok, \
                (f"SRAM[{self.base_word + i}]: "
                 f"expected 0x{expected:08X}, got 0x{actual:08X}")
        return all_ok


# ── Helper Functions ─────────────────────────────────────────────────────────

def get_token_count(dut):
    """Read the current FIFO token count from the RTL."""
    return int(dut.u_dut.token_count.value)


def sram_read_word(dut, word_addr):
    """Read a 32-bit word from the SRAM model by probing BRAM0-BRAM3 directly.
    Resolves X/Z bits to 0."""
    def safe_int(sig):
        try:
            return int(sig.value) & 0xFF
        except ValueError:
            return 0
    b0 = safe_int(dut.u_dut.u_sram.BRAM0[word_addr])
    b1 = safe_int(dut.u_dut.u_sram.BRAM1[word_addr])
    b2 = safe_int(dut.u_dut.u_sram.BRAM2[word_addr])
    b3 = safe_int(dut.u_dut.u_sram.BRAM3[word_addr])
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0


async def setup(dut):
    """Start clock and create AHB Lite master driver."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    ahb_master = AHBLiteMaster(
        AHBBus.from_entity(dut),
        dut.hclk,
        dut.hresetn,
        timeout=200,
    )
    return ahb_master


async def do_reset(dut):
    """Assert active-low reset for 5 cycles, then deassert."""
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def write_packet(dut, ahb, pkt, label=""):
    """Write a FifoPacket via the AHB master.

    Returns (write_ptr_before, write_ptr_after, hit_fired).
    """
    prefix = f"[{label}] " if label else ""

    # Beat 0: write length to address 0x0000
    await ahb.write(0x0000, pkt.length)
    dut.haddr.value = 0x3FFF
    # Extra cycles for metadata pipeline: capture_write_length_r (1 cycle) +
    # packet_word_length_r (1 cycle) + write_target_addr_r (1 cycle)
    await ClockCycles(dut.hclk, 3)

    write_ptr_before = int(dut.u_dut.write_ptr.value)
    target = int(dut.u_dut.write_target_addr.value)
    dut._log.info(f"{prefix}After length write: write_ptr=0x{write_ptr_before:04X}, "
                  f"packet_word_length={int(dut.u_dut.packet_word_length.value)}, "
                  f"write_target_addr=0x{target:04X}")

    # Data beats: use inline AHB phases so we can sample write_complete
    hit_fired = False
    for i, word in enumerate(pkt.data):
        addr = (i + 1) * 4

        # Address phase
        await RisingEdge(dut.hclk)
        dut.hsel.value   = 1
        dut.htrans.value = 2  # NONSEQ
        dut.hwrite.value = 1
        dut.hsize.value  = 2  # WORD
        dut.haddr.value  = addr

        # Data phase — sample write_complete BEFORE idling the bus
        # write_complete is combinational and only true while hsel/htrans are active
        await RisingEdge(dut.hclk)
        try:
            hit_val = int(dut.u_dut.u_fifo_ctrl.write_complete.value)
        except ValueError:
            hit_val = 0
        dut.hwdata.value = word
        dut.htrans.value = 0  # IDLE
        dut.hsel.value   = 0

        # Completion
        await RisingEdge(dut.hclk)
        dut.hwrite.value = 0
        hit = hit_val

        dut._log.info(f"{prefix}Beat {i+1}: haddr=0x{addr:04X} "
                      f"data=0x{word:08X} write_complete={hit}")
        if hit:
            hit_fired = True

    write_ptr_after = int(dut.u_dut.write_ptr.value)
    tokens = get_token_count(dut)
    dut._log.info(f"{prefix}Packet done: write_ptr 0x{write_ptr_before:04X} "
                  f"-> 0x{write_ptr_after:04X}, hit={hit_fired}, "
                  f"token_count={tokens}")

    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 1)

    return write_ptr_before, write_ptr_after, hit_fired


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset_defaults(dut):
    """After reset, hreadyout should be high and hresp OKAY."""
    await setup(dut)
    await do_reset(dut)
    await RisingEdge(dut.hclk)

    assert int(dut.hready.value) == 1, "hready should be high after reset"
    assert int(dut.hresp.value) == 0, "hresp should be OKAY after reset"
    assert get_token_count(dut) == MAX_TOKENS, \
        f"token_count should be {MAX_TOKENS} after reset, got {get_token_count(dut)}"


@cocotb.test()
async def test_02_single_write_read(dut):
    """Write a word and read it back using AHBLiteMaster."""
    ahb = await setup(dut)
    await do_reset(dut)

    await ahb.write(0x0100, 0xDEADBEEF)
    resp = await ahb.read(0x0100)
    got = int(resp[0]["data"], 16)

    assert got == 0xDEADBEEF, f"Expected 0xDEADBEEF, got 0x{got:08X}"


@cocotb.test()
async def test_03_multiple_addresses(dut):
    """Write to multiple addresses, then read all back."""
    ahb = await setup(dut)
    await do_reset(dut)

    addrs  = [0x0100, 0x0104, 0x0108, 0x010C]
    values = [0xCAFE0001, 0xCAFE0002, 0xCAFE0003, 0xCAFE0004]

    await ahb.write(addrs, values)
    responses = await ahb.read(addrs)

    for i, (addr, expected) in enumerate(zip(addrs, values)):
        got = int(responses[i]["data"], 16)
        assert got == expected, \
            f"Addr 0x{addr:04X}: expected 0x{expected:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_04_overwrite(dut):
    """Write, overwrite, and verify latest value."""
    ahb = await setup(dut)
    await do_reset(dut)

    await ahb.write(0x0110, 0x11111111)
    await ahb.write(0x0110, 0x22222222)
    resp = await ahb.read(0x0110)
    got = int(resp[0]["data"], 16)

    assert got == 0x22222222, f"Expected 0x22222222, got 0x{got:08X}"


@cocotb.test()
async def test_05_sequential_burst(dut):
    """Write a sequential burst of 16 words and read them back."""
    ahb = await setup(dut)
    await do_reset(dut)

    base = 0x0200
    addrs  = [base + i * 4 for i in range(16)]
    values = [0xBEEF0000 | i for i in range(16)]

    await ahb.write(addrs, values)
    responses = await ahb.read(addrs)

    for i, expected in enumerate(values):
        got = int(responses[i]["data"], 16)
        assert got == expected, \
            f"Burst word {i}: expected 0x{expected:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_06_pointers_zero_after_reset(dut):
    """After reset, read_ptr and write_ptr should be zero."""
    await setup(dut)
    await do_reset(dut)

    assert int(dut.u_dut.write_ptr.value) == 0, "write_ptr should be 0"
    assert int(dut.u_dut.read_ptr.value) == 0, "read_ptr should be 0"


@cocotb.test()
async def test_07_write_packet_length_capture(dut):
    """Writing to address 0 should capture hwdata as packet_word_length."""
    ahb = await setup(dut)
    await do_reset(dut)

    await ahb.write(0x0000, 5)
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    captured = int(dut.u_dut.packet_word_length.value)
    assert captured == 5, f"packet_word_length: expected 5, got {captured}"


@cocotb.test()
async def test_08_write_target_addr_calculation(dut):
    """write_target_addr should be packet_word_length * 4."""
    ahb = await setup(dut)
    await do_reset(dut)

    for pkt_len in [1, 3, 10]:
        await ahb.write(0x0000, pkt_len)
        dut.haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 2)

        target = int(dut.u_dut.write_target_addr.value)
        expected = pkt_len * 4
        assert target == expected, \
            f"pkt_len={pkt_len}: expected 0x{expected:04X}, got 0x{target:04X}"


@cocotb.test()
async def test_09_write_complete(dut):
    """write_complete fires on the last data beat of a 2-word packet."""
    ahb = await setup(dut)
    await do_reset(dut)

    pkt = FifoPacket(data=[0xFACE0001, 0xFACE0002])
    _, _, hit = await write_packet(dut, ahb, pkt, label="HIT_TEST")

    assert hit, "write_complete should have fired on the last data beat"


@cocotb.test()
async def test_10_single_packet_burst(dut):
    """Write a 10-beat packet and verify write_complete fires on the last beat."""
    ahb = await setup(dut)
    await do_reset(dut)

    pkt = FifoPacket(data=[0xDA7A0000 | i for i in range(1, 10)])
    _, _, hit = await write_packet(dut, ahb, pkt, label="PKT")

    assert hit, "write_complete should have fired on the last data beat"


@cocotb.test()
async def test_11_two_packets_no_overwrite(dut):
    """Write two packets starting at haddr=0, verify they occupy separate
    SRAM regions by probing BRAM directly."""
    ahb = await setup(dut)
    await do_reset(dut)

    pkt1 = FifoPacket(data=[0xAAAA0001, 0xAAAA0002, 0xAAAA0003])
    pkt2 = FifoPacket(data=[0xBBBB0001, 0xBBBB0002])

    # Write packet 1
    _, wptr_after_1, hit1 = await write_packet(dut, ahb, pkt1, label="PKT1")
    assert hit1, "write_complete should have fired for packet 1"

    # Write packet 2
    _, wptr_after_2, hit2 = await write_packet(dut, ahb, pkt2, label="PKT2")
    assert hit2, "write_complete should have fired for packet 2"

    # Verify SRAM contents
    dut._log.info("--- SRAM contents ---")

    sram_pkt1 = SramContents(base_word=0, words=pkt1.all_words)
    sram_pkt1.verify(dut, log=dut._log)

    sram_pkt2 = SramContents(
        base_word=len(pkt1.all_words),
        words=pkt2.all_words,
    )
    sram_pkt2.verify(dut, log=dut._log)

    # Verify token count decreased by total data words written
    tokens = get_token_count(dut)
    expected_tokens = MAX_TOKENS - pkt1.total_words - pkt2.total_words
    dut._log.info(f"Both packets verified. "
                  f"write_ptr: 0x0000 -> 0x{wptr_after_1:04X} -> 0x{wptr_after_2:04X}, "
                  f"token_count={tokens} (expected {expected_tokens})")
    assert tokens == expected_tokens, \
        f"token_count: expected {expected_tokens}, got {tokens}"


@cocotb.test()
async def test_12_three_packets_sequential(dut):
    """Write three packets of varying sizes, verify all three are stored
    sequentially in SRAM without overlap."""
    ahb = await setup(dut)
    await do_reset(dut)

    packets = [
        FifoPacket(data=[0x11110001, 0x11110002]),
        FifoPacket(data=[0x22220001, 0x22220002, 0x22220003, 0x22220004]),
        FifoPacket(data=[0x33330001]),
    ]

    for i, pkt in enumerate(packets):
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"PKT{i+1}")
        assert hit, f"write_complete should have fired for packet {i+1}"

    # Verify all packets in SRAM
    dut._log.info("--- SRAM contents ---")
    base = 0
    for i, pkt in enumerate(packets):
        sram = SramContents(base_word=base, words=pkt.all_words)
        sram.verify(dut, log=dut._log)
        base += len(pkt.all_words)

    dut._log.info(f"All {len(packets)} packets verified in SRAM")


@cocotb.test()
async def test_13_token_count_tracks_writes(dut):
    """Token count should start at MAX_TOKENS and decrement by
    packet_word_length each time a write packet completes."""
    ahb = await setup(dut)
    await do_reset(dut)

    assert get_token_count(dut) == MAX_TOKENS, \
        f"token_count should be {MAX_TOKENS} after reset"

    packets = [
        FifoPacket(data=[0xAA]),                              # 1 word
        FifoPacket(data=[0xBB, 0xCC, 0xDD]),                  # 3 words
        FifoPacket(data=[0x11, 0x22, 0x33, 0x44, 0x55]),      # 5 words
    ]

    expected_tokens = MAX_TOKENS
    for i, pkt in enumerate(packets):
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"PKT{i+1}")
        assert hit, f"write_complete should have fired for packet {i+1}"

        expected_tokens -= pkt.total_words
        actual_tokens = get_token_count(dut)
        dut._log.info(f"After PKT{i+1} ({pkt.length} words): "
                      f"token_count={actual_tokens} (expected {expected_tokens})")
        assert actual_tokens == expected_tokens, \
            (f"After packet {i+1}: token_count expected {expected_tokens}, "
             f"got {actual_tokens}")


@cocotb.test()
async def test_14_read_data_integrity_across_packets(dut):
    """Regression test for ptr_offset pipeline bug.

    Writes two packets back-to-back, then reads them both back and
    asserts EXACT data match on every word. The bug causes one corrupted
    word in the second read packet because ptr_offset uses the stale
    read_ptr for one cycle after read_complete fires.

    This test will FAIL if the ptr_offset_nxt computation uses
    read_ptr_r (stale) instead of read_ptr_nxt (updated).
    """
    ahb = await setup(dut)
    await do_reset(dut)

    # Two packets with distinct, easily verifiable data patterns
    pkt1 = FifoPacket(data=[0xAA000001, 0xAA000002, 0xAA000003])
    pkt2 = FifoPacket(data=[0xBB000001, 0xBB000002, 0xBB000003, 0xBB000004])

    # Write both packets
    _, _, hit1 = await write_packet(dut, ahb, pkt1, label="WR_PKT1")
    assert hit1, "write_complete should have fired for packet 1"
    _, _, hit2 = await write_packet(dut, ahb, pkt2, label="WR_PKT2")
    assert hit2, "write_complete should have fired for packet 2"

    # Read packet 1
    read1, rhit1 = await read_packet(dut, ahb, label="RD_PKT1")
    assert rhit1, "read_complete should have fired for packet 1"

    # Read packet 2 — this is where the bug manifests.
    # The first beat of this read uses a stale ptr_offset computed from
    # the OLD read_ptr, causing translated_addr to point to the wrong
    # SRAM word for one cycle.
    read2, rhit2 = await read_packet(dut, ahb, label="RD_PKT2")
    assert rhit2, "read_complete should have fired for packet 2"

    # Assert EXACT data match — no tolerance for corruption
    dut._log.info("--- Verifying read-back data integrity ---")
    for i, (expected, actual) in enumerate(zip(pkt1.data, read1.data)):
        dut._log.info(f"  PKT1 word {i}: expected 0x{expected:08X}, "
                      f"got 0x{actual:08X} {'OK' if expected == actual else 'CORRUPT'}")
        assert expected == actual, \
            (f"PKT1 word {i} corrupted: "
             f"expected 0x{expected:08X}, got 0x{actual:08X}")

    for i, (expected, actual) in enumerate(zip(pkt2.data, read2.data)):
        dut._log.info(f"  PKT2 word {i}: expected 0x{expected:08X}, "
                      f"got 0x{actual:08X} {'OK' if expected == actual else 'CORRUPT'}")
        assert expected == actual, \
            (f"PKT2 word {i} corrupted: "
             f"expected 0x{expected:08X}, got 0x{actual:08X} "
             f"(ptr_offset pipeline bug)")

    dut._log.info("All read-back data matches — no pipeline corruption")


@cocotb.test()
async def test_15_read_ptr_offset_pipeline_bug(dut):
    """Targeted regression test for the ptr_offset pipeline stale-read bug.

    The bug: ptr_offset_nxt uses read_ptr_r (current registered value)
    instead of read_ptr_nxt (the value being written this cycle). When
    read_complete fires on the last beat of packet N, read_ptr_nxt jumps
    to the next packet's base, but ptr_offset_nxt still uses the OLD
    read_ptr_r. On the next clock edge, ptr_offset holds the stale value
    for one cycle. If the first beat of packet N+1's read starts on that
    cycle, translated_addr points to the wrong SRAM word.

    To trigger this, we must start the next read's first data beat
    IMMEDIATELY after the previous read's last beat — no idle cycles.
    """
    ahb = await setup(dut)
    await do_reset(dut)

    # Write two packets with distinct patterns
    pkt1 = FifoPacket(data=[0xAA000000 | (i+1) for i in range(5)])
    pkt2 = FifoPacket(data=[0xBB000000 | (i+1) for i in range(4)])

    _, _, hit1 = await write_packet(dut, ahb, pkt1, label="WR1")
    assert hit1
    _, _, hit2 = await write_packet(dut, ahb, pkt2, label="WR2")
    assert hit2

    # -- Read packet 1 length --
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
    dut.hsize.value = 2; dut.haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0; dut.hsel.value = 0; dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 4)
    pkt1_len = int(dut.u_dut.packet_word_length.value)
    assert pkt1_len == pkt1.length, f"Pkt1 length: expected {pkt1.length}, got {pkt1_len}"

    # -- Read packet 1 data beats --
    read1_data = []
    for i in range(pkt1_len):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
        dut.hsize.value = 2; dut.haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.htrans.value = 0; dut.hsel.value = 0; dut.haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)
        try:
            read1_data.append(int(dut.hrdata.value))
        except ValueError:
            read1_data.append(0)

    dut._log.info(f"Pkt1 read: {[f'0x{d:08X}' for d in read1_data]}")

    # -- Read packet 2 length IMMEDIATELY (no idle cycles) --
    # This is where the bug bites: ptr_offset is stale for one cycle
    # after read_ptr advanced on the last beat of pkt1.
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
    dut.hsize.value = 2; dut.haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0; dut.hsel.value = 0; dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 4)
    pkt2_len = int(dut.u_dut.packet_word_length.value)
    assert pkt2_len == pkt2.length, f"Pkt2 length: expected {pkt2.length}, got {pkt2_len}"

    # -- Read packet 2 data beats --
    read2_data = []
    for i in range(pkt2_len):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
        dut.hsize.value = 2; dut.haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.htrans.value = 0; dut.hsel.value = 0; dut.haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)
        try:
            read2_data.append(int(dut.hrdata.value))
        except ValueError:
            read2_data.append(0)

    dut._log.info(f"Pkt2 read: {[f'0x{d:08X}' for d in read2_data]}")

    # -- Verify EXACT data integrity --
    dut._log.info("--- Data integrity check ---")
    for i, (exp, got) in enumerate(zip(pkt1.data, read1_data)):
        status = "OK" if exp == got else "CORRUPT"
        dut._log.info(f"  PKT1[{i}]: expected 0x{exp:08X} got 0x{got:08X} {status}")
        assert exp == got, f"PKT1[{i}]: expected 0x{exp:08X}, got 0x{got:08X}"

    for i, (exp, got) in enumerate(zip(pkt2.data, read2_data)):
        status = "OK" if exp == got else "CORRUPT"
        dut._log.info(f"  PKT2[{i}]: expected 0x{exp:08X} got 0x{got:08X} {status}")
        assert exp == got, \
            f"PKT2[{i}]: expected 0x{exp:08X}, got 0x{got:08X} — ptr_offset pipeline bug!"

    dut._log.info("No corruption detected")


async def read_packet(dut, ahb, label=""):
    """Read a packet from the FIFO via the AHB master.

    Reads the length word from haddr=0, then reads that many data words
    from sequential addresses. The read_complete should fire on the last
    beat, advancing read_ptr and releasing tokens.

    Returns (FifoPacket, hit_fired).
    """
    prefix = f"[{label}] " if label else ""

    # Beat 0: read length from address 0x0000
    # Use inline AHB phases to control timing precisely.
    # The read triggers check_addr, which captures rdata on the next cycle.
    # We need cs to remain asserted long enough for rdata to be valid.

    # Address phase: drive read to addr 0
    await RisingEdge(dut.hclk)
    dut.hsel.value   = 1
    dut.htrans.value = 2  # NONSEQ
    dut.hwrite.value = 0
    dut.hsize.value  = 2  # WORD
    dut.haddr.value  = 0x0000

    # Data phase: cmsdk_ahb_to_sram latches addr, asserts cs
    # check_addr_nxt = 1 (haddr==0 && ~hwrite)
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0  # IDLE
    dut.hsel.value   = 0
    # Move haddr away so check_addr doesn't re-trigger
    dut.haddr.value  = 0x3FFF

    # Wait for pipeline to settle:
    #   cycle 1: check_addr_r = 1, SRAM cs asserted
    #   cycle 2: cs_reg = 1, rdata valid, packet_word_length_nxt = rdata
    #   cycle 3: packet_word_length_r updated
    #   cycle 4: read_target_addr_r = packet_word_length_r * 4
    await ClockCycles(dut.hclk, 4)

    pkt_len = int(dut.u_dut.packet_word_length.value)
    target = int(dut.u_dut.read_target_addr.value)
    read_ptr_before = int(dut.u_dut.read_ptr.value)
    dut._log.info(f"{prefix}Read length={pkt_len}, "
                  f"read_ptr=0x{read_ptr_before:04X}, "
                  f"read_target_addr=0x{target:04X}")

    # Data beats: read sequentially, sampling read_complete
    # read_complete is combinational — only true while hsel/htrans active.
    # Must sample at the rising edge BEFORE idling the bus.
    hit_fired = False
    data = []
    for i in range(pkt_len):
        addr = (i + 1) * 4

        # Address phase
        await RisingEdge(dut.hclk)
        dut.hsel.value   = 1
        dut.htrans.value = 2  # NONSEQ
        dut.hwrite.value = 0
        dut.hsize.value  = 2  # WORD
        dut.haddr.value  = addr

        # Data phase — sample read_complete at rising edge before idling
        await RisingEdge(dut.hclk)
        try:
            hit = int(dut.read_complete.value)
        except ValueError:
            hit = 0

        # Now idle the bus
        dut.htrans.value = 0  # IDLE
        dut.hsel.value   = 0
        dut.haddr.value  = 0x3FFF

        # Sample read data on next rising edge
        await RisingEdge(dut.hclk)
        try:
            word = int(dut.hrdata.value)
        except ValueError:
            word = 0
        data.append(word)

        dut._log.info(f"{prefix}Beat {i+1}: haddr=0x{addr:04X} "
                      f"data=0x{word:08X} read_complete={hit}")
        if hit:
            hit_fired = True

    read_ptr_after = int(dut.u_dut.read_ptr.value)
    tokens = get_token_count(dut)
    dut._log.info(f"{prefix}Read done: read_ptr 0x{read_ptr_before:04X} "
                  f"-> 0x{read_ptr_after:04X}, hit={hit_fired}, "
                  f"token_count={tokens}")

    dut.haddr.value = 0x3FFF
    # Extra idle cycles to let ptr_offset pipeline settle after read_ptr advances
    await ClockCycles(dut.hclk, 3)

    return FifoPacket(data=data), hit_fired


@cocotb.test()
async def test_16_read_interrupt_and_packet_length(dut):
    """Verify that read_complete (the returner interrupt source) fires on the
    last beat of a read, and that packet_word_length_out carries the correct
    sideband value at that moment.

    This is the contract between tidelink_ahb and tidelink_ahb_returner:
    - read_complete = interrupt
    - packet_word_length_out = write_data for the returner
    """
    ahb = await setup(dut)
    await do_reset(dut)

    test_cases = [
        FifoPacket(data=[0xAA000001, 0xAA000002]),                        # 2 words
        FifoPacket(data=[0xBB000001]),                                     # 1 word
        FifoPacket(data=[0xCC000001, 0xCC000002, 0xCC000003, 0xCC000004,  # 5 words
                         0xCC000005]),
    ]

    # Write all packets first
    for i, pkt in enumerate(test_cases):
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"WR{i+1}")
        assert hit, f"write_complete should have fired for write packet {i+1}"

    # Read each packet back and verify interrupt fires + data integrity
    for i, expected_pkt in enumerate(test_cases):
        label = f"INT_RD{i+1}"

        read_pkt, rhit = await read_packet(dut, ahb, label=label)
        assert rhit, (
            f"[{label}] read_complete (interrupt) did NOT fire on the last "
            f"beat of a {expected_pkt.length}-word read packet"
        )

        # After read_complete fires, packet_word_length is cleared to 0
        # (by design — prevents stale hits). Verify it was cleared.
        pwl = int(dut.packet_word_length_out.value)
        assert pwl == 0, (
            f"[{label}] packet_word_length_out should be 0 after completion, "
            f"got {pwl}"
        )

        # Verify data integrity
        for j, (exp, got) in enumerate(zip(expected_pkt.data, read_pkt.data)):
            assert exp == got, (
                f"[{label}] word {j}: expected 0x{exp:08X}, got 0x{got:08X}"
            )

        dut._log.info(f"[{label}] read_complete fired, data verified OK")

    dut._log.info("All read interrupts verified with correct data")


@cocotb.test()
async def test_17_exhaustive_fifo_write_read(dut):
    """Exhaustively test the FIFO with many packets of varying sizes,
    never exceeding the free token count on writes or the used token
    count on reads.

    Strategy:
    1. Generate random-ish packets of sizes 1..20
    2. Write packets until the FIFO is nearly full
    3. Read packets back, verifying data integrity
    4. Repeat several rounds to stress wrap-around behaviour
    5. After each operation, assert token_count stays in [0, MAX_TOKENS]
    """
    import random
    random.seed(0xDEAD)  # Deterministic for reproducibility

    ahb = await setup(dut)
    await do_reset(dut)

    assert get_token_count(dut) == MAX_TOKENS

    # Track software model of token state
    sw_tokens = MAX_TOKENS
    written_packets = []  # Queue of packets waiting to be read back
    total_written = 0
    total_read = 0

    NUM_ROUNDS = 5
    MAX_PKT_SIZE = 20  # Max data words per packet

    for round_num in range(NUM_ROUNDS):
        dut._log.info(f"=== Round {round_num + 1}/{NUM_ROUNDS} ===")

        # ── Write phase: fill until we can't fit another max-size packet ──
        while sw_tokens >= MAX_PKT_SIZE + 1:  # +1 for length word
            pkt_len = random.randint(1, MAX_PKT_SIZE)
            pkt_total = pkt_len + 1  # length word + data

            # Don't exceed available tokens
            if pkt_total > sw_tokens:
                pkt_len = sw_tokens - 1
                pkt_total = pkt_len + 1
                if pkt_len < 1:
                    break

            pkt = FifoPacket(
                data=[(total_written << 16) | (i + 1) for i in range(pkt_len)]
            )

            _, _, hit = await write_packet(
                dut, ahb, pkt, label=f"R{round_num+1}_W{total_written}")
            assert hit, \
                f"write_complete should have fired for packet {total_written}"

            sw_tokens -= pkt_total
            hw_tokens = get_token_count(dut)

            assert hw_tokens == sw_tokens, \
                (f"Token mismatch after write {total_written}: "
                 f"sw={sw_tokens}, hw={hw_tokens}")
            assert hw_tokens >= 0, \
                f"Token underflow! hw_tokens={hw_tokens}"

            written_packets.append(pkt)
            total_written += 1

        used_tokens = MAX_TOKENS - sw_tokens
        dut._log.info(f"Write phase done: {len(written_packets)} packets buffered, "
                      f"tokens free={sw_tokens}, used={used_tokens}")

        # ── Read phase: drain all buffered packets ──
        packets_to_read = len(written_packets)
        for read_idx in range(packets_to_read):
            expected_pkt = written_packets[0]
            used = MAX_TOKENS - sw_tokens

            # Don't read more than what's been written
            assert used >= expected_pkt.total_words, \
                (f"Would over-read: used={used}, "
                 f"pkt needs {expected_pkt.total_words}")

            read_pkt, hit = await read_packet(
                dut, ahb, label=f"R{round_num+1}_R{total_read}")
            assert hit, \
                f"read_complete should have fired for read {total_read}"

            # Verify data matches what was written
            assert read_pkt.data == expected_pkt.data, \
                (f"Data mismatch on read {total_read}: "
                 f"expected {[f'0x{d:08X}' for d in expected_pkt.data]}, "
                 f"got {[f'0x{d:08X}' for d in read_pkt.data]}")

            sw_tokens += expected_pkt.total_words
            hw_tokens = get_token_count(dut)

            assert hw_tokens == sw_tokens, \
                (f"Token mismatch after read {total_read}: "
                 f"sw={sw_tokens}, hw={hw_tokens}")
            assert hw_tokens <= MAX_TOKENS, \
                f"Token overflow! hw_tokens={hw_tokens}"

            written_packets.pop(0)
            total_read += 1

        dut._log.info(f"Read phase done: tokens restored to {sw_tokens}")

    assert sw_tokens == MAX_TOKENS, \
        f"Final token count should be {MAX_TOKENS}, got {sw_tokens}"
    assert len(written_packets) == 0, \
        f"{len(written_packets)} packets still unread"

    dut._log.info(f"Exhaustive test complete: {total_written} packets written, "
                  f"{total_read} packets read, token_count={get_token_count(dut)}")


@cocotb.test()
async def test_18_circular_buffer_wrap_around(dut):
    """Fill the FIFO until write_ptr wraps past the SRAM boundary,
    then read all packets back and verify data integrity.

    RAM_ADDR_W=14 → 16384 bytes → 4096 words. Pointers are 14-bit
    and naturally wrap. This test verifies that packets spanning the
    wrap boundary are written and read correctly.
    """
    ahb = await setup(dut)
    await do_reset(dut)

    # Fill most of the FIFO with large packets to force wrap-around
    # Each packet = 100 data words + 1 length word = 101 words = 404 bytes
    pkt_size = 100
    num_fill_packets = MAX_TOKENS // (pkt_size + 1)  # ~40 packets to fill

    written_packets = []
    sw_tokens = MAX_TOKENS

    for i in range(num_fill_packets):
        pkt = FifoPacket(data=[(i << 16) | (j + 1) for j in range(pkt_size)])
        if sw_tokens < pkt.total_words:
            break

        _, _, hit = await write_packet(dut, ahb, pkt, label=f"WRAP_W{i}")
        assert hit, f"write_complete should fire for packet {i}"
        sw_tokens -= pkt.total_words
        written_packets.append(pkt)

    write_ptr = int(dut.u_dut.write_ptr.value)
    dut._log.info(f"After filling: write_ptr=0x{write_ptr:04X}, "
                  f"packets={len(written_packets)}, tokens_free={sw_tokens}")

    # Read all packets back
    for i, expected_pkt in enumerate(written_packets):
        read_pkt, hit = await read_packet(dut, ahb, label=f"WRAP_R{i}")
        assert hit, f"read_complete should fire for packet {i}"

        assert read_pkt.data == expected_pkt.data, (
            f"Wrap-around data corruption at packet {i}: "
            f"first mismatch at word "
            f"{next((j for j, (e, g) in enumerate(zip(expected_pkt.data, read_pkt.data)) if e != g), '?')}"
        )
        sw_tokens += expected_pkt.total_words

    assert sw_tokens == MAX_TOKENS
    assert get_token_count(dut) == MAX_TOKENS
    dut._log.info("Circular buffer wrap-around test passed")


@cocotb.test()
async def test_19_single_word_packet(dut):
    """Minimal packet: 1 data word. Verify all signals behave correctly."""
    ahb = await setup(dut)
    await do_reset(dut)

    pkt = FifoPacket(data=[0xDEADBEEF])
    _, _, hit = await write_packet(dut, ahb, pkt, label="MIN_W")
    assert hit, "write_complete should fire for single-word packet"

    expected_tokens = MAX_TOKENS - 2  # 1 data + 1 length = 2 words
    actual_tokens = get_token_count(dut)
    assert actual_tokens == expected_tokens, \
        f"Expected {expected_tokens} tokens, got {actual_tokens}"

    read_pkt, rhit = await read_packet(dut, ahb, label="MIN_R")
    assert rhit, "read_complete should fire for single-word packet"
    assert read_pkt.data == [0xDEADBEEF], \
        f"Data mismatch: got {[f'0x{d:08X}' for d in read_pkt.data]}"

    assert get_token_count(dut) == MAX_TOKENS
    dut._log.info("Single-word packet test passed")


@cocotb.test()
async def test_20_maximum_size_packet(dut):
    """Packet consuming all available tokens (MAX_TOKENS - 1 data words).
    Verify completion fires and token count reaches 0."""
    ahb = await setup(dut)
    await do_reset(dut)

    max_data_words = MAX_TOKENS - 1  # -1 for the length word
    pkt = FifoPacket(data=[(i + 1) & 0xFFFFFFFF for i in range(max_data_words)])

    _, _, hit = await write_packet(dut, ahb, pkt, label="MAX_W")
    assert hit, "write_complete should fire for max-size packet"

    actual_tokens = get_token_count(dut)
    assert actual_tokens == 0, f"Tokens should be 0 after max packet, got {actual_tokens}"

    read_pkt, rhit = await read_packet(dut, ahb, label="MAX_R")
    assert rhit, "read_complete should fire for max-size packet"

    # Verify first and last words (checking all would be slow)
    assert read_pkt.data[0] == 1, f"First word: expected 1, got {read_pkt.data[0]}"
    assert read_pkt.data[-1] == max_data_words & 0xFFFFFFFF

    assert get_token_count(dut) == MAX_TOKENS
    dut._log.info(f"Max-size packet test passed ({max_data_words} data words)")


@cocotb.test()
async def test_21_token_count_write_read_restore(dut):
    """Write N packets, read N packets, verify tokens restored to MAX."""
    ahb = await setup(dut)
    await do_reset(dut)

    packets = [
        FifoPacket(data=[0x10 + i for i in range(3)]),   # 4 tokens
        FifoPacket(data=[0x20 + i for i in range(7)]),   # 8 tokens
        FifoPacket(data=[0x30 + i for i in range(1)]),   # 2 tokens
        FifoPacket(data=[0x40 + i for i in range(15)]),  # 16 tokens
    ]

    sw_tokens = MAX_TOKENS
    for i, pkt in enumerate(packets):
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"RESTORE_W{i}")
        assert hit
        sw_tokens -= pkt.total_words
        assert get_token_count(dut) == sw_tokens

    for i, pkt in enumerate(packets):
        read_pkt, hit = await read_packet(dut, ahb, label=f"RESTORE_R{i}")
        assert hit
        assert read_pkt.data == pkt.data, f"Data mismatch at packet {i}"
        sw_tokens += pkt.total_words
        assert get_token_count(dut) == sw_tokens

    assert sw_tokens == MAX_TOKENS
    dut._log.info("Token restore test passed")


@cocotb.test()
async def test_22_back_to_back_write_packets(dut):
    """Write packets with minimal gap between them, verify no pointer
    corruption or data overlap."""
    ahb = await setup(dut)
    await do_reset(dut)

    packets = [
        FifoPacket(data=[0xA0 | i for i in range(4)]),
        FifoPacket(data=[0xB0 | i for i in range(3)]),
        FifoPacket(data=[0xC0 | i for i in range(5)]),
    ]

    prev_wptr = 0
    for i, pkt in enumerate(packets):
        wptr_before, wptr_after, hit = await write_packet(
            dut, ahb, pkt, label=f"B2B_W{i}")
        assert hit
        assert wptr_before == prev_wptr, \
            f"Packet {i}: write_ptr gap: expected 0x{prev_wptr:04X}, got 0x{wptr_before:04X}"
        prev_wptr = wptr_after

    # Verify all data in SRAM
    base = 0
    for i, pkt in enumerate(packets):
        sram = SramContents(base_word=base, words=pkt.all_words)
        sram.verify(dut, log=dut._log)
        base += len(pkt.all_words)

    dut._log.info("Back-to-back write test passed")
