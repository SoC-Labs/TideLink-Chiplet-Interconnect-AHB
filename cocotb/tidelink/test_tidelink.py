"""Cocotb testbench for the tidelink top-level module.

Tests the integrated system: AHB FIFO (slave), AHB returner (master),
and APB configuration registers.  Uses cocotbext-ahb for both the
AHBLiteMaster (driving the FIFO slave port) and AHBLiteSlaveRAM
(responding to the returner master port).

Infrastructure is object-oriented so it can be reused across tests.
"""

from dataclasses import dataclass, field
from typing import List, Optional

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster, AHBLiteSlaveRAM

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10
RAM_ADDR_W    = 14
MAX_TOKENS    = 1 << (RAM_ADDR_W - 2)

# APB register offsets
APB_REG_WRITE_ADDR   = 0x000
APB_REG_PKT_WORD_LEN = 0x004
APB_REG_TOKEN_COUNT  = 0x008
APB_REG_STATUS       = 0x00C


# ── Data Objects ─────────────────────────────────────────────────────────────

@dataclass
class FifoPacket:
    """A packet written into / read from the tidelink FIFO."""
    data: List[int]

    @property
    def length(self) -> int:
        return len(self.data)

    @property
    def total_words(self) -> int:
        """Length word + data words."""
        return self.length + 1

    @property
    def addrs(self) -> List[int]:
        """Byte addresses for every beat (length word + data)."""
        return [i * 4 for i in range(self.length + 1)]


@dataclass
class ReturnerTxn:
    """Captured returner master-port transaction."""
    address: int
    data: int


# ── APB Master Driver ────────────────────────────────────────────────────────

class APBMaster:
    """Minimal APB master driver for register access."""

    def __init__(self, dut, clk, prefix="apbs"):
        self._clk     = clk
        self._psel    = getattr(dut, f"{prefix}_psel")
        self._penable = getattr(dut, f"{prefix}_penable")
        self._pwrite  = getattr(dut, f"{prefix}_pwrite")
        self._paddr   = getattr(dut, f"{prefix}_paddr")
        self._pwdata  = getattr(dut, f"{prefix}_pwdata")
        self._prdata  = getattr(dut, f"{prefix}_prdata")
        self._pready  = getattr(dut, f"{prefix}_pready")

    def idle(self):
        """Drive APB signals to idle state."""
        self._psel.value    = 0
        self._penable.value = 0
        self._pwrite.value  = 0
        self._paddr.value   = 0
        self._pwdata.value  = 0

    async def write(self, addr: int, data: int):
        """APB write transfer (setup + access phase)."""
        # Setup phase
        self._psel.value    = 1
        self._penable.value = 0
        self._pwrite.value  = 1
        self._paddr.value   = addr
        self._pwdata.value  = data
        await RisingEdge(self._clk)

        # Access phase
        self._penable.value = 1
        await RisingEdge(self._clk)
        # Wait for pready (always 1 in current RTL, but future-proof)
        while not int(self._pready.value):
            await RisingEdge(self._clk)

        # Return to idle
        self.idle()

    async def read(self, addr: int) -> int:
        """APB read transfer. Returns read data."""
        # Setup phase
        self._psel.value    = 1
        self._penable.value = 0
        self._pwrite.value  = 0
        self._paddr.value   = addr
        self._pwdata.value  = 0
        await RisingEdge(self._clk)

        # Access phase
        self._penable.value = 1
        await RisingEdge(self._clk)
        while not int(self._pready.value):
            await RisingEdge(self._clk)

        data = int(self._prdata.value)
        self.idle()
        return data


# ── Testbench Environment ────────────────────────────────────────────────────

class TidelinkTB:
    """Reusable testbench environment for the tidelink top-level module.

    Provides:
      - AHBLiteMaster on the FIFO slave port (for simple reads/writes)
      - Inline AHB helpers for packet write/read operations
      - AHBLiteSlaveRAM on the returner master port
      - APBMaster for configuration and status registers
      - Software token-count model
    """

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        # Start clock
        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        # AHB master to drive FIFO slave port
        ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
        self.ahb_master = AHBLiteMaster(
            ahbs_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # AHB slave RAM to respond to returner master port
        ahbm_bus = AHBBus.from_prefix(dut, "ahbm")
        self.ahb_slave = AHBLiteSlaveRAM(
            ahbm_bus, dut.hclk, dut.hresetn,
            mem_size=4096,
        )

        # APB master for configuration/status
        self.apb = APBMaster(dut, dut.hclk)

        # Software token model
        self.sw_token_count = MAX_TOKENS

    # ── Reset ────────────────────────────────────────────────────────────

    async def reset(self):
        """Assert active-low reset for 5 cycles, then release."""
        self.apb.idle()
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 2)
        self.sw_token_count = MAX_TOKENS

    # ── APB Helpers ──────────────────────────────────────────────────────

    async def configure_returner_addr(self, addr: int):
        """Set the returner's write target address via APB."""
        await self.apb.write(APB_REG_WRITE_ADDR, addr)
        self.log.info(f"Configured returner write address = 0x{addr:08X}")

    async def read_token_count(self) -> int:
        """Read the hardware token count via APB."""
        return await self.apb.read(APB_REG_TOKEN_COUNT)

    async def read_status(self) -> dict:
        """Read the status register via APB. Returns decoded fields."""
        raw = await self.apb.read(APB_REG_STATUS)
        return {
            "write_addr_hit": bool(raw & 1),
            "read_addr_hit":  bool(raw & 2),
            "returner_busy":  bool(raw & 4),
            "raw": raw,
        }

    # ── Packet Write (inline AHB phases) ─────────────────────────────────

    async def write_packet(self, data: List[int], label: str = "") -> bool:
        """Write a packet into the FIFO using inline AHB phases.

        Returns True if write_addr_hit fired on the last beat.
        Updates the software token model.
        """
        pkt = FifoPacket(data=data)
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        # Beat 0: write length word to address 0x0000
        await self.ahb_master.write(0x0000, pkt.length)
        # Move haddr away from 0 to prevent check_addr re-trigger
        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 2)

        self.log.info(
            f"{prefix}Writing {pkt.length}-word packet"
        )

        # Data beats via inline AHB phases (precise hit sampling)
        hit_fired = False
        for i, word in enumerate(pkt.data):
            addr = (i + 1) * 4

            # Address phase
            await RisingEdge(dut.hclk)
            dut.ahbs_hsel.value   = 1
            dut.ahbs_htrans.value = 2   # NONSEQ
            dut.ahbs_hwrite.value = 1
            dut.ahbs_hsize.value  = 2   # WORD
            dut.ahbs_haddr.value  = addr

            # Data phase
            await RisingEdge(dut.hclk)
            dut.ahbs_hwdata.value = word
            dut.ahbs_htrans.value = 0   # IDLE
            dut.ahbs_hsel.value   = 0

            # Sample hit on falling edge
            await FallingEdge(dut.hclk)
            hit = int(dut.u_dut.write_addr_hit.value)

            await RisingEdge(dut.hclk)
            dut.ahbs_hwrite.value = 0

            if hit:
                hit_fired = True

        # Park haddr away from 0
        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 1)

        # Update software model
        if hit_fired:
            self.sw_token_count -= pkt.total_words
            self.log.info(
                f"{prefix}Write complete (hit fired). "
                f"sw_tokens={self.sw_token_count}"
            )

        return hit_fired

    # ── Packet Read (inline AHB phases) ──────────────────────────────────

    async def read_packet(self, label: str = "") -> (FifoPacket, bool):
        """Read a packet from the FIFO using inline AHB phases.

        Returns (FifoPacket, read_addr_hit_fired).
        Updates the software token model.
        """
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        # Address phase: read length from address 0x0000
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2   # NONSEQ
        dut.ahbs_hwrite.value = 0
        dut.ahbs_hsize.value  = 2   # WORD
        dut.ahbs_haddr.value  = 0x0000

        # Data phase
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        dut.ahbs_haddr.value  = 0x3FFF

        # Wait for check_addr -> rdata capture -> packet_word_length update
        await ClockCycles(dut.hclk, 3)

        pkt_len = int(dut.u_dut.u_tidelink_ahb.packet_word_length.value)
        self.log.info(f"{prefix}Read length = {pkt_len}")

        # Data beats
        hit_fired = False
        data = []
        for i in range(pkt_len):
            addr = (i + 1) * 4

            # Address phase
            await RisingEdge(dut.hclk)
            dut.ahbs_hsel.value   = 1
            dut.ahbs_htrans.value = 2
            dut.ahbs_hwrite.value = 0
            dut.ahbs_hsize.value  = 2
            dut.ahbs_haddr.value  = addr

            # Data phase - sample hit
            await RisingEdge(dut.hclk)
            await FallingEdge(dut.hclk)
            hit = int(dut.u_dut.read_addr_hit.value)

            # Idle bus
            dut.ahbs_htrans.value = 0
            dut.ahbs_hsel.value   = 0
            dut.ahbs_haddr.value  = 0x3FFF

            # Capture hrdata
            await RisingEdge(dut.hclk)
            try:
                word = int(dut.ahbs_hrdata.value)
            except ValueError:
                word = 0
            data.append(word)

            if hit:
                hit_fired = True

        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 3)

        pkt = FifoPacket(data=data)

        # Update software model
        if hit_fired:
            self.sw_token_count += pkt.total_words
            self.log.info(
                f"{prefix}Read complete (hit fired, {pkt.length} words). "
                f"sw_tokens={self.sw_token_count}"
            )

        return pkt, hit_fired

    # ── Returner Helpers ─────────────────────────────────────────────────

    async def wait_returner_idle(self, timeout_cycles: int = 20):
        """Wait until the returner is no longer busy."""
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            busy = int(self.dut.u_dut.returner_busy.value)
            if not busy:
                return
        raise TimeoutError("Returner still busy after timeout")

    def read_returner_memory(self, addr: int, num_bytes: int = 4) -> int:
        """Read a 32-bit word from the AHBLiteSlaveRAM backing memory."""
        raw = self.ahb_slave.memory.read(addr, num_bytes)
        value = int.from_bytes(raw, byteorder="little")
        return value


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_00_apb_register_dump(dut):
    """Diagnostic: dump all APB registers after reset to verify the address decode."""
    tb = TidelinkTB(dut)
    await tb.reset()

    for offset in [0x000, 0x004, 0x008, 0x00C, 0x010, 0x014]:
        val = await tb.apb.read(offset)
        tb.log.info(f"APB[0x{offset:03X}] (paddr[4:2]={offset>>2}) = 0x{val:08X} ({val})")

    # Also probe RTL signals directly for comparison
    tc = int(dut.u_dut.current_token_count.value)
    pwl = int(dut.u_dut.packet_word_length.value)
    tb.log.info(f"Direct probe: current_token_count={tc}, packet_word_length={pwl}")


@cocotb.test()
async def test_01_reset_and_initial_tokens(dut):
    """After reset the APB token-count register should read MAX_TOKENS."""
    tb = TidelinkTB(dut)
    await tb.reset()

    hw_tokens = await tb.read_token_count()
    tb.log.info(f"Token count after reset: {hw_tokens} (expected {MAX_TOKENS})")
    assert hw_tokens == MAX_TOKENS, \
        f"Expected {MAX_TOKENS}, got {hw_tokens}"


@cocotb.test()
async def test_02_apb_write_addr_readback(dut):
    """Write a returner address via APB and read it back."""
    tb = TidelinkTB(dut)
    await tb.reset()

    test_addr = 0xDEAD_0100
    await tb.configure_returner_addr(test_addr)
    readback = await tb.apb.read(APB_REG_WRITE_ADDR)
    assert readback == test_addr, \
        f"APB readback: expected 0x{test_addr:08X}, got 0x{readback:08X}"


@cocotb.test()
async def test_03_write_read_returner_flow(dut):
    """Full functional test:
    1. Configure returner write address via APB
    2. Check initial token count
    3. Write two packets into the FIFO
    4. Track tokens in software
    5. Read one packet back — returner should fire
    6. Verify returner wrote correct address & data
    7. Read second packet — verify second return
    8. Confirm final token count via APB
    """
    tb = TidelinkTB(dut)
    await tb.reset()

    RETURNER_ADDR = 0x0000_0100

    # ── Step 1: Configure returner target address ────────────────────
    await tb.configure_returner_addr(RETURNER_ADDR)

    # ── Step 2: Verify initial token count ───────────────────────────
    hw_tokens = await tb.read_token_count()
    assert hw_tokens == MAX_TOKENS, \
        f"Initial tokens: expected {MAX_TOKENS}, got {hw_tokens}"
    tb.log.info(f"Initial token count = {hw_tokens}")

    # ── Step 3: Write two packets ────────────────────────────────────
    pkt1_data = [0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]
    pkt2_data = [0xBBBB_0001, 0xBBBB_0002]

    hit1 = await tb.write_packet(pkt1_data, label="WR_PKT1")
    assert hit1, "write_addr_hit should fire for packet 1"

    hit2 = await tb.write_packet(pkt2_data, label="WR_PKT2")
    assert hit2, "write_addr_hit should fire for packet 2"

    # ── Step 4: Verify token count after writes ──────────────────────
    pkt1 = FifoPacket(data=pkt1_data)
    pkt2 = FifoPacket(data=pkt2_data)
    expected_tokens = MAX_TOKENS - pkt1.total_words - pkt2.total_words

    hw_tokens = await tb.read_token_count()
    tb.log.info(f"After 2 writes: hw_tokens={hw_tokens}, "
                f"sw_tokens={tb.sw_token_count}, expected={expected_tokens}")
    assert hw_tokens == expected_tokens, \
        f"Tokens after writes: expected {expected_tokens}, got {hw_tokens}"
    assert tb.sw_token_count == expected_tokens, \
        f"SW model mismatch: {tb.sw_token_count} != {expected_tokens}"

    # ── Step 5: Read packet 1 — triggers returner ────────────────────
    read_pkt1, rhit1 = await tb.read_packet(label="RD_PKT1")
    assert rhit1, "read_addr_hit should fire for packet 1 read"

    # Verify read data integrity
    for i, (exp, got) in enumerate(zip(pkt1_data, read_pkt1.data)):
        assert exp == got, \
            f"PKT1 word {i}: expected 0x{exp:08X}, got 0x{got:08X}"
    tb.log.info("PKT1 read data verified OK")

    # Wait for returner to complete its AHB master transaction
    await tb.wait_returner_idle()

    # ── Step 6: Verify returner transaction ──────────────────────────
    returner_data = tb.read_returner_memory(RETURNER_ADDR)
    tb.log.info(f"Returner wrote 0x{returner_data:08X} to "
                f"0x{RETURNER_ADDR:08X} (expected {pkt1.length})")
    assert returner_data == pkt1.length, \
        (f"Returner data mismatch: expected {pkt1.length} "
         f"(packet_word_length), got {returner_data}")

    # ── Step 7: Read packet 2 — triggers second return ───────────────
    read_pkt2, rhit2 = await tb.read_packet(label="RD_PKT2")
    assert rhit2, "read_addr_hit should fire for packet 2 read"

    for i, (exp, got) in enumerate(zip(pkt2_data, read_pkt2.data)):
        assert exp == got, \
            f"PKT2 word {i}: expected 0x{exp:08X}, got 0x{got:08X}"
    tb.log.info("PKT2 read data verified OK")

    await tb.wait_returner_idle()

    # The returner writes to the same address, overwriting the previous
    # value with pkt2's packet_word_length
    returner_data = tb.read_returner_memory(RETURNER_ADDR)
    tb.log.info(f"Returner wrote 0x{returner_data:08X} to "
                f"0x{RETURNER_ADDR:08X} (expected {pkt2.length})")
    assert returner_data == pkt2.length, \
        (f"Returner data mismatch: expected {pkt2.length}, "
         f"got {returner_data}")

    # ── Step 8: Final token check via APB ────────────────────────────
    hw_tokens = await tb.read_token_count()
    tb.log.info(f"Final: hw_tokens={hw_tokens}, "
                f"sw_tokens={tb.sw_token_count}, "
                f"expected={MAX_TOKENS}")
    assert hw_tokens == MAX_TOKENS, \
        f"Final tokens: expected {MAX_TOKENS}, got {hw_tokens}"
    assert tb.sw_token_count == MAX_TOKENS, \
        f"SW model: expected {MAX_TOKENS}, got {tb.sw_token_count}"

    tb.log.info("Full write-read-return flow verified successfully")


@cocotb.test()
async def test_04_multiple_packets_token_tracking(dut):
    """Write several packets, read them back one at a time, and verify
    the Python token model matches hardware after every operation."""
    tb = TidelinkTB(dut)
    await tb.reset()

    RETURNER_ADDR = 0x0000_0200
    await tb.configure_returner_addr(RETURNER_ADDR)

    packets = [
        [0x11110001, 0x11110002],                               # 2 words
        [0x22220001, 0x22220002, 0x22220003, 0x22220004],       # 4 words
        [0x33330001],                                            # 1 word
    ]

    # Write all packets
    for i, data in enumerate(packets):
        hit = await tb.write_packet(data, label=f"WR{i+1}")
        assert hit, f"write_addr_hit should fire for packet {i+1}"

        hw_tokens = await tb.read_token_count()
        assert hw_tokens == tb.sw_token_count, \
            (f"Token mismatch after write {i+1}: "
             f"hw={hw_tokens}, sw={tb.sw_token_count}")

    # Read all packets back
    for i, data in enumerate(packets):
        pkt = FifoPacket(data=data)
        read_pkt, rhit = await tb.read_packet(label=f"RD{i+1}")
        assert rhit, f"read_addr_hit should fire for read {i+1}"

        # Verify data
        for j, (exp, got) in enumerate(zip(data, read_pkt.data)):
            assert exp == got, \
                f"Packet {i+1} word {j}: expected 0x{exp:08X}, got 0x{got:08X}"

        # Wait for returner and verify its transaction
        await tb.wait_returner_idle()
        returner_data = tb.read_returner_memory(RETURNER_ADDR)
        assert returner_data == pkt.length, \
            (f"Read {i+1}: returner wrote {returner_data}, "
             f"expected {pkt.length}")

        # Verify token count
        hw_tokens = await tb.read_token_count()
        assert hw_tokens == tb.sw_token_count, \
            (f"Token mismatch after read {i+1}: "
             f"hw={hw_tokens}, sw={tb.sw_token_count}")
        tb.log.info(f"After read {i+1}: tokens={hw_tokens}")

    assert tb.sw_token_count == MAX_TOKENS, \
        f"All tokens should be restored: {tb.sw_token_count} != {MAX_TOKENS}"
    tb.log.info("All packets verified with correct token tracking")
