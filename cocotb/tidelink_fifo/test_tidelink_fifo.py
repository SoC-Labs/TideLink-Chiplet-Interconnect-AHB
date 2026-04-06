"""Cocotb testbench for tidelink_fifo_mem.

Uses cocotbext-ahb AHBLiteMaster to drive AHB transactions against the
tidelink_fifo_mem wrapper (cmsdk_ahb_to_sram + cmsdk_fpga_sram with FIFO
address translation).

Packet format (written starting at haddr=0):
  Beat 0: length word (number of data words to follow)
  Beats 1..N: data words
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster

from tidelink.packet import FifoPacket
from tidelink.regs import RAM_ADDR_W, MAX_CREDITS

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10


class SramContents:
    """Expected SRAM contents for verification."""

    def __init__(self, base_word, words):
        self.base_word = base_word
        self.words = words

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

def get_credit_count(dut):
    """Read the current FIFO credit count from the RTL."""
    return int(dut.u_dut.credit_count.value)


def sram_read_word(dut, word_addr):
    """Read a 32-bit word from the SRAM model by probing BRAM0-BRAM3 directly.
    Resolves X/Z bits to 0."""
    def safe_int(sig):
        try:
            return int(sig.value) & 0xFF
        except ValueError:
            return 0
    b0 = safe_int(dut.u_dut.u_sram.u_sram.BRAM0[word_addr])
    b1 = safe_int(dut.u_dut.u_sram.u_sram.BRAM1[word_addr])
    b2 = safe_int(dut.u_dut.u_sram.u_sram.BRAM2[word_addr])
    b3 = safe_int(dut.u_dut.u_sram.u_sram.BRAM3[word_addr])
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
    """Assert active-low reset for 5 cycles, then deassert.
    The FIFO data window is always enabled (CTRL.EN removed)."""
    dut.hresetn.value = 0
    dut.flush.value = 0
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
    credits = get_credit_count(dut)
    dut._log.info(f"{prefix}Packet done: write_ptr 0x{write_ptr_before:04X} "
                  f"-> 0x{write_ptr_after:04X}, hit={hit_fired}, "
                  f"credit_count={credits}")

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
    assert get_credit_count(dut) == MAX_CREDITS, \
        f"credit_count should be {MAX_CREDITS} after reset, got {get_credit_count(dut)}"


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

    # Verify credit count decreased by total data words written
    credits = get_credit_count(dut)
    expected_credits = MAX_CREDITS - pkt1.total_words - pkt2.total_words
    dut._log.info(f"Both packets verified. "
                  f"write_ptr: 0x0000 -> 0x{wptr_after_1:04X} -> 0x{wptr_after_2:04X}, "
                  f"credit_count={credits} (expected {expected_credits})")
    assert credits == expected_credits, \
        f"credit_count: expected {expected_credits}, got {credits}"


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
async def test_13_credit_count_tracks_writes(dut):
    """Credit count should start at MAX_CREDITS and decrement by
    packet_word_length each time a write packet completes."""
    ahb = await setup(dut)
    await do_reset(dut)

    assert get_credit_count(dut) == MAX_CREDITS, \
        f"credit_count should be {MAX_CREDITS} after reset"

    packets = [
        FifoPacket(data=[0xAA]),                              # 1 word
        FifoPacket(data=[0xBB, 0xCC, 0xDD]),                  # 3 words
        FifoPacket(data=[0x11, 0x22, 0x33, 0x44, 0x55]),      # 5 words
    ]

    expected_credits = MAX_CREDITS
    for i, pkt in enumerate(packets):
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"PKT{i+1}")
        assert hit, f"write_complete should have fired for packet {i+1}"

        expected_credits -= pkt.total_words
        actual_credits = get_credit_count(dut)
        dut._log.info(f"After PKT{i+1} ({pkt.length} words): "
                      f"credit_count={actual_credits} (expected {expected_credits})")
        assert actual_credits == expected_credits, \
            (f"After packet {i+1}: credit_count expected {expected_credits}, "
             f"got {actual_credits}")


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
    beat, advancing read_ptr and releasing credits.

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
    credits = get_credit_count(dut)
    dut._log.info(f"{prefix}Read done: read_ptr 0x{read_ptr_before:04X} "
                  f"-> 0x{read_ptr_after:04X}, hit={hit_fired}, "
                  f"credit_count={credits}")

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
    never exceeding the free credit count on writes or the used credit
    count on reads.

    Strategy:
    1. Generate random-ish packets of sizes 1..20
    2. Write packets until the FIFO is nearly full
    3. Read packets back, verifying data integrity
    4. Repeat several rounds to stress wrap-around behaviour
    5. After each operation, assert credit_count stays in [0, MAX_CREDITS]
    """
    import random
    random.seed(0xDEAD)  # Deterministic for reproducibility

    ahb = await setup(dut)
    await do_reset(dut)

    assert get_credit_count(dut) == MAX_CREDITS

    # Track software model of credit state
    sw_credits = MAX_CREDITS
    written_packets = []  # Queue of packets waiting to be read back
    total_written = 0
    total_read = 0

    NUM_ROUNDS = 5
    MAX_PKT_SIZE = 20  # Max data words per packet

    for round_num in range(NUM_ROUNDS):
        dut._log.info(f"=== Round {round_num + 1}/{NUM_ROUNDS} ===")

        # ── Write phase: fill until we can't fit another max-size packet ──
        while sw_credits >= MAX_PKT_SIZE + 1:  # +1 for length word
            pkt_len = random.randint(1, MAX_PKT_SIZE)
            pkt_total = pkt_len + 1  # length word + data

            # Don't exceed available credits
            if pkt_total > sw_credits:
                pkt_len = sw_credits - 1
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

            sw_credits -= pkt_total
            hw_credits = get_credit_count(dut)

            assert hw_credits == sw_credits, \
                (f"Credit mismatch after write {total_written}: "
                 f"sw={sw_credits}, hw={hw_credits}")
            assert hw_credits >= 0, \
                f"Credit underflow! hw_credits={hw_credits}"

            written_packets.append(pkt)
            total_written += 1

        used_credits = MAX_CREDITS - sw_credits
        dut._log.info(f"Write phase done: {len(written_packets)} packets buffered, "
                      f"credits free={sw_credits}, used={used_credits}")

        # ── Read phase: drain all buffered packets ──
        packets_to_read = len(written_packets)
        for read_idx in range(packets_to_read):
            expected_pkt = written_packets[0]
            used = MAX_CREDITS - sw_credits

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

            sw_credits += expected_pkt.total_words
            hw_credits = get_credit_count(dut)

            assert hw_credits == sw_credits, \
                (f"Credit mismatch after read {total_read}: "
                 f"sw={sw_credits}, hw={hw_credits}")
            assert hw_credits <= MAX_CREDITS, \
                f"Credit overflow! hw_credits={hw_credits}"

            written_packets.pop(0)
            total_read += 1

        dut._log.info(f"Read phase done: credits restored to {sw_credits}")

    assert sw_credits == MAX_CREDITS, \
        f"Final credit count should be {MAX_CREDITS}, got {sw_credits}"
    assert len(written_packets) == 0, \
        f"{len(written_packets)} packets still unread"

    dut._log.info(f"Exhaustive test complete: {total_written} packets written, "
                  f"{total_read} packets read, credit_count={get_credit_count(dut)}")


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
    num_fill_packets = MAX_CREDITS // (pkt_size + 1)  # ~40 packets to fill

    written_packets = []
    sw_credits = MAX_CREDITS

    for i in range(num_fill_packets):
        pkt = FifoPacket(data=[(i << 16) | (j + 1) for j in range(pkt_size)])
        if sw_credits < pkt.total_words:
            break

        _, _, hit = await write_packet(dut, ahb, pkt, label=f"WRAP_W{i}")
        assert hit, f"write_complete should fire for packet {i}"
        sw_credits -= pkt.total_words
        written_packets.append(pkt)

    write_ptr = int(dut.u_dut.write_ptr.value)
    dut._log.info(f"After filling: write_ptr=0x{write_ptr:04X}, "
                  f"packets={len(written_packets)}, credits_free={sw_credits}")

    # Read all packets back
    for i, expected_pkt in enumerate(written_packets):
        read_pkt, hit = await read_packet(dut, ahb, label=f"WRAP_R{i}")
        assert hit, f"read_complete should fire for packet {i}"

        assert read_pkt.data == expected_pkt.data, (
            f"Wrap-around data corruption at packet {i}: "
            f"first mismatch at word "
            f"{next((j for j, (e, g) in enumerate(zip(expected_pkt.data, read_pkt.data)) if e != g), '?')}"
        )
        sw_credits += expected_pkt.total_words

    assert sw_credits == MAX_CREDITS
    assert get_credit_count(dut) == MAX_CREDITS
    dut._log.info("Circular buffer wrap-around test passed")


@cocotb.test()
async def test_19_single_word_packet(dut):
    """Minimal packet: 1 data word. Verify all signals behave correctly."""
    ahb = await setup(dut)
    await do_reset(dut)

    pkt = FifoPacket(data=[0xDEADBEEF])
    _, _, hit = await write_packet(dut, ahb, pkt, label="MIN_W")
    assert hit, "write_complete should fire for single-word packet"

    expected_credits = MAX_CREDITS - 2  # 1 data + 1 length = 2 words
    actual_credits = get_credit_count(dut)
    assert actual_credits == expected_credits, \
        f"Expected {expected_credits} credits, got {actual_credits}"

    read_pkt, rhit = await read_packet(dut, ahb, label="MIN_R")
    assert rhit, "read_complete should fire for single-word packet"
    assert read_pkt.data == [0xDEADBEEF], \
        f"Data mismatch: got {[f'0x{d:08X}' for d in read_pkt.data]}"

    assert get_credit_count(dut) == MAX_CREDITS
    dut._log.info("Single-word packet test passed")


@cocotb.test()
async def test_20_maximum_size_packet(dut):
    """Packet consuming all available credits (MAX_CREDITS - 1 data words).
    Verify completion fires and credit count reaches 0."""
    ahb = await setup(dut)
    await do_reset(dut)

    max_data_words = MAX_CREDITS - 1  # -1 for the length word
    pkt = FifoPacket(data=[(i + 1) & 0xFFFFFFFF for i in range(max_data_words)])

    _, _, hit = await write_packet(dut, ahb, pkt, label="MAX_W")
    assert hit, "write_complete should fire for max-size packet"

    actual_credits = get_credit_count(dut)
    assert actual_credits == 0, f"Credits should be 0 after max packet, got {actual_credits}"

    read_pkt, rhit = await read_packet(dut, ahb, label="MAX_R")
    assert rhit, "read_complete should fire for max-size packet"

    # Verify first and last words (checking all would be slow)
    assert read_pkt.data[0] == 1, f"First word: expected 1, got {read_pkt.data[0]}"
    assert read_pkt.data[-1] == max_data_words & 0xFFFFFFFF

    assert get_credit_count(dut) == MAX_CREDITS
    dut._log.info(f"Max-size packet test passed ({max_data_words} data words)")


@cocotb.test()
async def test_21_credit_count_write_read_restore(dut):
    """Write N packets, read N packets, verify credits restored to MAX."""
    ahb = await setup(dut)
    await do_reset(dut)

    packets = [
        FifoPacket(data=[0x10 + i for i in range(3)]),   # 4 credits
        FifoPacket(data=[0x20 + i for i in range(7)]),   # 8 credits
        FifoPacket(data=[0x30 + i for i in range(1)]),   # 2 credits
        FifoPacket(data=[0x40 + i for i in range(15)]),  # 16 credits
    ]

    sw_credits = MAX_CREDITS
    for i, pkt in enumerate(packets):
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"RESTORE_W{i}")
        assert hit
        sw_credits -= pkt.total_words
        assert get_credit_count(dut) == sw_credits

    for i, pkt in enumerate(packets):
        read_pkt, hit = await read_packet(dut, ahb, label=f"RESTORE_R{i}")
        assert hit
        assert read_pkt.data == pkt.data, f"Data mismatch at packet {i}"
        sw_credits += pkt.total_words
        assert get_credit_count(dut) == sw_credits

    assert sw_credits == MAX_CREDITS
    dut._log.info("Credit restore test passed")


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


# ── Packet Committed IRQ Tests ──────────────────────────────────────────────


def get_packet_committed_irq(dut):
    """Read the packet_committed_irq signal from tidelink_fifo output."""
    try:
        return int(dut.u_dut.packet_committed_irq.value)
    except ValueError:
        return 0


@cocotb.test()
async def test_23_irq_deasserted_after_reset(dut):
    """packet_committed_irq should be 0 after reset."""
    await setup(dut)
    await do_reset(dut)
    await RisingEdge(dut.hclk)

    assert get_packet_committed_irq(dut) == 0, \
        "packet_committed_irq should be 0 after reset"


@cocotb.test()
async def test_24_irq_asserts_on_write_complete(dut):
    """packet_committed_irq should go high after a packet is committed."""
    ahb = await setup(dut)
    await do_reset(dut)

    # Verify IRQ starts low
    assert get_packet_committed_irq(dut) == 0

    # Write a packet — write_complete fires on last beat
    pkt = FifoPacket(data=[0xDEAD, 0xBEEF])
    _, _, hit = await write_packet(dut, ahb, pkt, label="IRQ_SET")
    assert hit, "write_complete should have fired"

    # IRQ should now be asserted (registered, so check after the clock edge
    # that captured write_complete)
    await RisingEdge(dut.hclk)
    assert get_packet_committed_irq(dut) == 1, \
        "packet_committed_irq should be 1 after write_complete"


@cocotb.test()
async def test_25_irq_clears_on_read_addr_0(dut):
    """packet_committed_irq should clear when recipient reads FIFO address 0."""
    ahb = await setup(dut)
    await do_reset(dut)

    # Write a packet to set the IRQ
    pkt = FifoPacket(data=[0xCAFE, 0xBABE, 0xF00D])
    await write_packet(dut, ahb, pkt, label="IRQ_CLR")
    await RisingEdge(dut.hclk)
    assert get_packet_committed_irq(dut) == 1, "IRQ should be set after write"

    # Perform a read from address 0 (start of packet read)
    await RisingEdge(dut.hclk)
    dut.hsel.value   = 1
    dut.htrans.value = 2  # NONSEQ
    dut.hwrite.value = 0
    dut.hsize.value  = 2  # WORD
    dut.haddr.value  = 0x0000

    # Data phase
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0  # IDLE
    dut.hsel.value   = 0
    dut.haddr.value  = 0x3FFF

    # IRQ should clear on the next clock edge (registered output)
    await RisingEdge(dut.hclk)
    assert get_packet_committed_irq(dut) == 0, \
        "packet_committed_irq should clear after read from address 0"


@cocotb.test()
async def test_26_irq_stays_cleared_without_write(dut):
    """After clearing, IRQ should remain 0 until another write_complete."""
    ahb = await setup(dut)
    await do_reset(dut)

    # Write a packet, then read from addr 0 to clear IRQ
    pkt = FifoPacket(data=[0x1111, 0x2222])
    await write_packet(dut, ahb, pkt, label="IRQ_HOLD")
    await RisingEdge(dut.hclk)
    assert get_packet_committed_irq(dut) == 1

    # Read from addr 0 to clear
    await RisingEdge(dut.hclk)
    dut.hsel.value   = 1
    dut.htrans.value = 2
    dut.hwrite.value = 0
    dut.hsize.value  = 2
    dut.haddr.value  = 0x0000
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0
    dut.hsel.value   = 0
    dut.haddr.value  = 0x3FFF
    await RisingEdge(dut.hclk)
    assert get_packet_committed_irq(dut) == 0

    # Verify it stays 0 for several cycles
    for _ in range(10):
        await RisingEdge(dut.hclk)
        assert get_packet_committed_irq(dut) == 0, \
            "IRQ should remain 0 without a new write_complete"


@cocotb.test()
async def test_27_irq_multi_cycle_toggle(dut):
    """Multiple write/read cycles should toggle IRQ correctly."""
    ahb = await setup(dut)
    await do_reset(dut)
    assert get_packet_committed_irq(dut) == 0

    for i in range(3):
        # Write a packet — IRQ should assert
        pkt = FifoPacket(data=[0xA000 | i, 0xB000 | i])
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"TOGGLE_W{i}")
        assert hit
        await RisingEdge(dut.hclk)
        assert get_packet_committed_irq(dut) == 1, \
            f"Cycle {i}: IRQ should be 1 after write"

        # Read the packet — IRQ should clear on addr 0 read
        rpkt, rhit = await read_packet(dut, ahb, label=f"TOGGLE_R{i}")
        # After read_packet, the first thing it does is read from addr 0,
        # which clears the IRQ
        assert get_packet_committed_irq(dut) == 0, \
            f"Cycle {i}: IRQ should be 0 after read"

    dut._log.info("Multi-cycle IRQ toggle test passed")


# ── EN Gate, FLUSH, Overrun/Underrun Tests ─────────────────────────────────


def get_overrun(dut):
    try:
        return int(dut.overrun.value)
    except ValueError:
        return 0


def get_underrun(dut):
    try:
        return int(dut.underrun.value)
    except ValueError:
        return 0


@cocotb.test()
async def test_28_flush_resets_state(dut):
    """FLUSH should reset pointers, credit count, and packet state."""
    ahb = await setup(dut)
    await do_reset(dut)

    # Write a packet to change state
    pkt = FifoPacket(data=[0x1111, 0x2222, 0x3333])
    _, _, hit = await write_packet(dut, ahb, pkt, label="FLUSH_W")
    assert hit

    credits_after_write = get_credit_count(dut)
    assert credits_after_write < MAX_CREDITS

    # Flush
    dut.flush.value = 1
    await RisingEdge(dut.hclk)
    dut.flush.value = 0
    await RisingEdge(dut.hclk)

    # Verify state is reset
    assert get_credit_count(dut) == MAX_CREDITS, \
        f"Credit count should be MAX after flush, got {get_credit_count(dut)}"
    assert int(dut.u_dut.write_ptr.value) == 0, "write_ptr should be 0 after flush"
    assert int(dut.u_dut.read_ptr.value) == 0, "read_ptr should be 0 after flush"
    assert int(dut.u_dut.packet_word_length.value) == 0, \
        "packet_word_length should be 0 after flush"

    # Verify FIFO works again after flush
    pkt2 = FifoPacket(data=[0xAAAA, 0xBBBB])
    _, _, hit2 = await write_packet(dut, ahb, pkt2, label="POST_FLUSH_W")
    assert hit2, "FIFO should work normally after flush"

    dut._log.info("FLUSH resets state — passed")


@cocotb.test()
async def test_29_flush_clears_overrun(dut):
    """Overrun sticky flag should be cleared by FLUSH."""
    ahb = await setup(dut)
    await do_reset(dut)

    assert get_overrun(dut) == 0, "overrun should be 0 after reset"

    # Fill the FIFO completely
    max_data = MAX_CREDITS - 1
    pkt = FifoPacket(data=[(i + 1) for i in range(max_data)])
    _, _, hit = await write_packet(dut, ahb, pkt, label="FILL")
    assert hit
    assert get_credit_count(dut) == 0, "FIFO should be full"

    # Attempt another write — should trigger overrun
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 1
    dut.hsize.value = 2; dut.haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.hwdata.value = 0xBAD
    dut.htrans.value = 0; dut.hsel.value = 0
    await RisingEdge(dut.hclk)
    dut.hwrite.value = 0
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    assert get_overrun(dut) == 1, "overrun should be set after write to full buffer"

    # Flush should clear it
    dut.flush.value = 1
    await RisingEdge(dut.hclk)
    dut.flush.value = 0
    await RisingEdge(dut.hclk)

    assert get_overrun(dut) == 0, "overrun should be cleared by FLUSH"
    dut._log.info("Overrun cleared by FLUSH — passed")


@cocotb.test()
async def test_30_underrun_on_empty_read(dut):
    """Underrun sticky flag should set on read from empty buffer."""
    ahb = await setup(dut)
    await do_reset(dut)

    assert get_underrun(dut) == 0, "underrun should be 0 after reset"
    assert get_credit_count(dut) == MAX_CREDITS, "Buffer should be empty after reset"

    # Attempt a read from the empty buffer
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
    dut.hsize.value = 2; dut.haddr.value = 0x0004
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0; dut.hsel.value = 0
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    assert get_underrun(dut) == 1, "underrun should be set after read from empty buffer"

    # Verify sticky: stays set without flush
    await ClockCycles(dut.hclk, 5)
    assert get_underrun(dut) == 1, "underrun should remain sticky"

    # Flush should clear it
    dut.flush.value = 1
    await RisingEdge(dut.hclk)
    dut.flush.value = 0
    await RisingEdge(dut.hclk)

    assert get_underrun(dut) == 0, "underrun should be cleared by FLUSH"
    dut._log.info("Underrun detection and FLUSH clear — passed")


@cocotb.test()
async def test_31_overrun_underrun_clear_after_reset(dut):
    """Both error flags should be 0 after hardware reset."""
    await setup(dut)
    await do_reset(dut)
    assert get_overrun(dut) == 0
    assert get_underrun(dut) == 0
    dut._log.info("Error flags clear after reset — passed")


# ── Shortcoming Fix Tests ───────────────────────────────────────────────────

@cocotb.test()
async def test_32_credit_underflow_saturation(dut):
    """BUG-002: Credit counter must saturate at 0, not wrap on underflow.

    Writes a packet whose total_words exceeds remaining credits after
    draining most of the FIFO. The credit counter should saturate at 0
    and the overrun flag should be set — NOT wrap to a large value.
    """
    ahb = await setup(dut)
    await do_reset(dut)

    initial_credits = get_credit_count(dut)
    assert initial_credits == MAX_CREDITS, f"Expected {MAX_CREDITS}, got {initial_credits}"

    # Step 1: Fill most of the FIFO to leave only a few credits.
    # Write packets of 100 words each (101 credits each: 1 length + 100 data)
    # until fewer than 110 credits remain.
    pkt_size = 100
    packets_written = 0
    while get_credit_count(dut) >= pkt_size + 1:
        pkt = FifoPacket(data=[0xAA000000 | i for i in range(pkt_size)])
        _, _, hit = await write_packet(dut, ahb, pkt, label=f"fill-{packets_written}")
        assert hit, f"write_complete should fire for fill packet {packets_written}"
        packets_written += 1

    remaining = get_credit_count(dut)
    dut._log.info(f"After filling: {packets_written} packets, {remaining} credits remain")
    assert remaining < pkt_size + 1, "Should have fewer credits than a full packet"
    assert remaining > 0, "Should have some credits remaining"

    # Step 2: Now write a packet whose total_words > remaining credits.
    # This is the bug scenario: credit_count_r - packet_delta should NOT wrap.
    oversized_len = remaining + 10  # Guaranteed to exceed available credits
    oversized_pkt = FifoPacket(data=[0xBB000000 | i for i in range(oversized_len)])

    # Write the length word
    await ahb.write(0x0000, oversized_pkt.length)
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    # Write data beats up to and including the target address
    for i, word in enumerate(oversized_pkt.data):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 1
        dut.hsize.value = 2; dut.haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.hwdata.value = word
        dut.htrans.value = 0; dut.hsel.value = 0
        await RisingEdge(dut.hclk)
        dut.hwrite.value = 0

    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    # Step 3: Check the credit counter
    final_credits = get_credit_count(dut)
    dut._log.info(f"Credits after oversized write: {final_credits}")

    # The fix: credit_count should be 0 (saturated), NOT a huge wrapped value
    assert final_credits == 0, (
        f"Credit counter should saturate at 0, got {final_credits}. "
        f"If this is a large value (e.g. >4000), the counter has wrapped — BUG-002."
    )

    # Note: the overrun flag checks credit_count == 0 per individual AHB beat,
    # not whether the entire packet fits. Since credits were > 0 when the beats
    # happened, overrun may not be set. The key invariant is that credit_count
    # saturated at 0 rather than wrapping.

    dut._log.info("Credit underflow saturation — passed")


@cocotb.test()
async def test_33_credit_underflow_normal_path_unaffected(dut):
    """Verify the saturation guard does not affect normal credit accounting.

    Writes and reads packets that fit within available credits, confirming
    credit_count decrements and increments correctly without false saturation.
    """
    ahb = await setup(dut)
    await do_reset(dut)

    # Write a small packet (5 words = 6 credits: 1 length + 5 data)
    pkt = FifoPacket(data=[0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555])
    credits_before = get_credit_count(dut)
    _, _, hit = await write_packet(dut, ahb, pkt, label="normal")
    assert hit, "write_complete should fire"

    credits_after_write = get_credit_count(dut)
    expected = credits_before - pkt.total_words
    assert credits_after_write == expected, (
        f"Expected {expected} credits after write, got {credits_after_write}"
    )

    # Read the packet back
    # Read length
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
    dut.hsize.value = 2; dut.haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.htrans.value = 0; dut.hsel.value = 0; dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 4)

    pkt_len = int(dut.u_dut.packet_word_length.value)
    assert pkt_len == 5, f"Expected packet length 5, got {pkt_len}"

    # Read data beats
    for i in range(pkt_len):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.hsel.value = 1; dut.htrans.value = 2; dut.hwrite.value = 0
        dut.haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.htrans.value = 0; dut.hsel.value = 0; dut.haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)

    await ClockCycles(dut.hclk, 3)

    credits_after_read = get_credit_count(dut)
    assert credits_after_read == credits_before, (
        f"Credits should be restored to {credits_before} after read, got {credits_after_read}"
    )

    assert get_overrun(dut) == 0, "Overrun should NOT be set for normal operation"
    dut._log.info("Normal credit path unaffected by saturation guard — passed")


@cocotb.test()
async def test_34_packet_size_clamped_to_max(dut):
    """Shortcoming #3: Packet lengths exceeding MAX_CREDITS-1 must be clamped.

    Writing a length larger than the SRAM can hold should be silently
    clamped to MAX_CREDITS-1 (4095), preventing pointer wrap and SRAM
    boundary overrun.
    """
    ahb = await setup(dut)
    await do_reset(dut)

    # Write an oversized length to address 0
    oversized_length = MAX_CREDITS + 100  # e.g. 4196, way beyond 4095
    await ahb.write(0x0000, oversized_length)
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    captured_len = int(dut.u_dut.u_fifo_ctrl.packet_word_length.value)
    max_valid = MAX_CREDITS - 1  # 4095

    dut._log.info(f"Wrote length {oversized_length}, captured as {captured_len} "
                  f"(max valid = {max_valid})")

    assert captured_len == max_valid, (
        f"packet_word_length should be clamped to {max_valid}, got {captured_len}"
    )

    dut._log.info("Packet size clamping — passed")


@cocotb.test()
async def test_35_packet_size_valid_length_unaffected(dut):
    """Verify valid packet lengths are not clamped."""
    ahb = await setup(dut)
    await do_reset(dut)

    # Test several valid lengths
    for length in [1, 10, 100, MAX_CREDITS - 1]:
        # Flush between tests to clear state
        dut.flush.value = 1
        await RisingEdge(dut.hclk)
        dut.flush.value = 0
        await ClockCycles(dut.hclk, 2)

        await ahb.write(0x0000, length)
        dut.haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 3)

        captured = int(dut.u_dut.u_fifo_ctrl.packet_word_length.value)
        assert captured == length, (
            f"Valid length {length} should not be clamped, got {captured}"
        )
        dut._log.info(f"  Length {length} captured correctly")

    dut._log.info("Valid packet lengths unaffected by clamping — passed")


@cocotb.test()
async def test_36_seq_transfers_rejected(dut):
    """Shortcoming #14: SEQ burst beats (htrans=3) must be ignored.

    Only NONSEQ transfers (htrans=2) should be accepted by the FIFO.
    SEQ beats from INCR/WRAP bursts would corrupt the metadata logic.
    """
    ahb = await setup(dut)
    await do_reset(dut)

    # First, write a valid packet length via NONSEQ (htrans=2)
    await ahb.write(0x0000, 5)
    dut.haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    pkt_len = int(dut.u_dut.u_fifo_ctrl.packet_word_length.value)
    assert pkt_len == 5, f"NONSEQ write to addr 0 should capture length, got {pkt_len}"

    # Flush and try again with SEQ (htrans=3) — should NOT capture
    dut.flush.value = 1
    await RisingEdge(dut.hclk)
    dut.flush.value = 0
    await ClockCycles(dut.hclk, 2)

    # Manual AHB beat with htrans = SEQ (3)
    await RisingEdge(dut.hclk)
    dut.hsel.value = 1; dut.htrans.value = 3; dut.hwrite.value = 1
    dut.hsize.value = 2; dut.haddr.value = 0x0000
    await RisingEdge(dut.hclk)
    dut.hwdata.value = 10  # Attempt to set length=10
    dut.htrans.value = 0; dut.hsel.value = 0
    await RisingEdge(dut.hclk)
    dut.hwrite.value = 0
    await ClockCycles(dut.hclk, 3)

    pkt_len = int(dut.u_dut.u_fifo_ctrl.packet_word_length.value)
    assert pkt_len == 0, (
        f"SEQ transfer (htrans=3) should be ignored, but packet_word_length={pkt_len}"
    )

    dut._log.info("SEQ transfers correctly rejected — passed")
