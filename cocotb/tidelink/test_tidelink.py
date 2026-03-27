"""Cocotb testbench for the tidelink top-level module.

Tests the integrated system: AHB FIFO (slave), AHB returner (master),
and APB configuration registers.  Uses cocotbext-ahb for both the
AHBLiteMaster (driving the FIFO slave port) and AHBLiteSlaveRAM
(responding to the returner master port).

Infrastructure is object-oriented so it can be reused across tests.
"""

from dataclasses import dataclass
from typing import List

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster, AHBLiteSlaveRAM

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10
RAM_ADDR_W    = 14
MAX_TOKENS    = 1 << (RAM_ADDR_W - 2)

# Default TIDELINK_PAIR_BASE = 0, so returner targets are:
PAIR_RELEASED_TOKENS_ADDR = 0x20  # region 1 accumulator on the paired tidelink
PAIR_DOORBELL_ADDR        = 0x14  # region 0 doorbell on the paired tidelink

# APB register offsets — Region 0 (paddr[5]=0)
APB_REG_PAIR_BASE     = 0x000   # RO: TIDELINK_PAIR_BASE parameter
APB_REG_PKT_WORD_LEN  = 0x008   # RO: packet_word_length sideband from FIFO
APB_REG_TOKEN_COUNT   = 0x00C   # RO: current total token count
APB_REG_STATUS        = 0x010   # RO: [0] write_addr_hit [1] read_addr_hit [2] busy
APB_REG_DOORBELL      = 0x014   # W1C: write any value to trigger doorbell

# APB register offsets — Region 1 (paddr[5]=1)
APB_REG_RELEASED_ACC  = 0x020   # W-add/R-clear: released tokens accumulator


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
        self._psel.value    = 1
        self._penable.value = 0
        self._pwrite.value  = 1
        self._paddr.value   = addr
        self._pwdata.value  = data
        await RisingEdge(self._clk)
        self._penable.value = 1
        await RisingEdge(self._clk)
        while not int(self._pready.value):
            await RisingEdge(self._clk)
        self.idle()

    async def read(self, addr: int) -> int:
        """APB read transfer. Returns read data."""
        self._psel.value    = 1
        self._penable.value = 0
        self._pwrite.value  = 0
        self._paddr.value   = addr
        self._pwdata.value  = 0
        await RisingEdge(self._clk)
        self._penable.value = 1
        await FallingEdge(self._clk)
        while not int(self._pready.value):
            await RisingEdge(self._clk)
            await FallingEdge(self._clk)
        data = int(self._prdata.value)
        await RisingEdge(self._clk)
        self.idle()
        return data


# ── Testbench Environment ────────────────────────────────────────────────────

class TidelinkTB:
    """Reusable testbench environment for the tidelink top-level module."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
        self.ahb_master = AHBLiteMaster(
            ahbs_bus, dut.hclk, dut.hresetn, timeout=200
        )

        ahbm_bus = AHBBus.from_prefix(dut, "ahbm")
        self.ahb_slave = AHBLiteSlaveRAM(
            ahbm_bus, dut.hclk, dut.hresetn,
            mem_size=4096,
        )

        self.apb = APBMaster(dut, dut.hclk)
        self.sw_token_count = MAX_TOKENS

    async def reset(self):
        """Assert active-low reset for 5 cycles, then release."""
        self.apb.idle()
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        # Wait extra cycles for reset deassertion pulse (channel 2) to complete
        await ClockCycles(self.dut.hclk, 10)
        self.sw_token_count = MAX_TOKENS

    # ── APB Helpers ──────────────────────────────────────────────────────

    async def read_token_count(self) -> int:
        return await self.apb.read(APB_REG_TOKEN_COUNT)

    async def read_status(self) -> dict:
        raw = await self.apb.read(APB_REG_STATUS)
        return {
            "write_addr_hit": bool(raw & 1),
            "read_addr_hit":  bool(raw & 2),
            "returner_busy":  bool(raw & 4),
            "raw": raw,
        }

    # ── Packet Write (inline AHB phases) ─────────────────────────────────

    async def write_packet(self, data: List[int], label: str = "") -> bool:
        """Write a packet into the FIFO. Returns True if write_addr_hit fired."""
        pkt = FifoPacket(data=data)
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        await self.ahb_master.write(0x0000, pkt.length)
        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 2)
        self.log.info(f"{prefix}Writing {pkt.length}-word packet")

        hit_fired = False
        for i, word in enumerate(pkt.data):
            addr = (i + 1) * 4
            await RisingEdge(dut.hclk)
            dut.ahbs_hsel.value   = 1
            dut.ahbs_htrans.value = 2
            dut.ahbs_hwrite.value = 1
            dut.ahbs_hsize.value  = 2
            dut.ahbs_haddr.value  = addr
            await RisingEdge(dut.hclk)
            dut.ahbs_hwdata.value = word
            dut.ahbs_htrans.value = 0
            dut.ahbs_hsel.value   = 0
            await FallingEdge(dut.hclk)
            hit = int(dut.u_dut.write_addr_hit.value)
            await RisingEdge(dut.hclk)
            dut.ahbs_hwrite.value = 0
            if hit:
                hit_fired = True

        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 1)
        if hit_fired:
            self.sw_token_count -= pkt.total_words
            self.log.info(f"{prefix}Write complete. sw_tokens={self.sw_token_count}")
        return hit_fired

    # ── Packet Read (inline AHB phases) ──────────────────────────────────

    async def read_packet(self, label: str = "") -> (FifoPacket, bool):
        """Read a packet from the FIFO. Returns (FifoPacket, read_addr_hit_fired)."""
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0
        dut.ahbs_hsize.value  = 2
        dut.ahbs_haddr.value  = 0x0000
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        dut.ahbs_haddr.value  = 0x3FFF
        await ClockCycles(dut.hclk, 3)

        pkt_len = int(dut.u_dut.u_tidelink_ahb.packet_word_length.value)
        self.log.info(f"{prefix}Read length = {pkt_len}")

        hit_fired = False
        data = []
        for i in range(pkt_len):
            addr = (i + 1) * 4
            await RisingEdge(dut.hclk)
            dut.ahbs_hsel.value   = 1
            dut.ahbs_htrans.value = 2
            dut.ahbs_hwrite.value = 0
            dut.ahbs_hsize.value  = 2
            dut.ahbs_haddr.value  = addr
            await RisingEdge(dut.hclk)
            await FallingEdge(dut.hclk)
            hit = int(dut.u_dut.read_addr_hit.value)
            dut.ahbs_htrans.value = 0
            dut.ahbs_hsel.value   = 0
            dut.ahbs_haddr.value  = 0x3FFF
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
        if hit_fired:
            self.sw_token_count += pkt.total_words
            self.log.info(f"{prefix}Read complete ({pkt.length} words). sw_tokens={self.sw_token_count}")
        return pkt, hit_fired

    # ── Returner Helpers ─────────────────────────────────────────────────

    async def wait_returner_idle(self, timeout_cycles: int = 20):
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            if not int(self.dut.u_dut.returner_busy.value):
                return
        raise TimeoutError("Returner still busy after timeout")

    def read_returner_memory(self, addr: int, num_bytes: int = 4) -> int:
        raw = self.ahb_slave.memory.read(addr, num_bytes)
        return int.from_bytes(raw, byteorder="little")


# ── Tests ────────────────────────────────────────────────────────────────────

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
async def test_02_apb_pair_base_readback(dut):
    """Offset 0x000 should return TIDELINK_PAIR_BASE (default 0)."""
    tb = TidelinkTB(dut)
    await tb.reset()

    readback = await tb.apb.read(APB_REG_PAIR_BASE)
    assert readback == 0, \
        f"APB pair base: expected 0x00000000, got 0x{readback:08X}"


@cocotb.test()
async def test_03_write_read_returner_flow(dut):
    """Full functional test:
    1. Check initial token count
    2. Write two packets into the FIFO
    3. Track tokens in software
    4. Read one packet back — returner should fire channel 0
    5. Verify returner wrote token_delta_data to PAIR_RELEASED_TOKENS_ADDR
    6. Read second packet — verify second return
    7. Confirm final token count via APB
    """
    tb = TidelinkTB(dut)
    await tb.reset()

    # ── Step 1: Verify initial token count ───────────────────────────
    hw_tokens = await tb.read_token_count()
    assert hw_tokens == MAX_TOKENS, \
        f"Initial tokens: expected {MAX_TOKENS}, got {hw_tokens}"
    tb.log.info(f"Initial token count = {hw_tokens}")

    # ── Step 2: Write two packets ────────────────────────────────────
    pkt1_data = [0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]
    pkt2_data = [0xBBBB_0001, 0xBBBB_0002]

    hit1 = await tb.write_packet(pkt1_data, label="WR_PKT1")
    assert hit1, "write_addr_hit should fire for packet 1"
    hit2 = await tb.write_packet(pkt2_data, label="WR_PKT2")
    assert hit2, "write_addr_hit should fire for packet 2"

    # ── Step 3: Verify token count after writes ──────────────────────
    pkt1 = FifoPacket(data=pkt1_data)
    pkt2 = FifoPacket(data=pkt2_data)
    expected_tokens = MAX_TOKENS - pkt1.total_words - pkt2.total_words

    hw_tokens = await tb.read_token_count()
    tb.log.info(f"After 2 writes: hw_tokens={hw_tokens}, expected={expected_tokens}")
    assert hw_tokens == expected_tokens
    assert tb.sw_token_count == expected_tokens

    # ── Step 4: Read packet 1 — triggers returner channel 0 ─────────
    # Clear any prior returner writes at the target address
    tb.ahb_slave.memory.write(PAIR_RELEASED_TOKENS_ADDR, b'\x00\x00\x00\x00')

    read_pkt1, rhit1 = await tb.read_packet(label="RD_PKT1")
    assert rhit1, "read_addr_hit should fire for packet 1 read"
    for i, (exp, got) in enumerate(zip(pkt1_data, read_pkt1.data)):
        assert exp == got, f"PKT1 word {i}: expected 0x{exp:08X}, got 0x{got:08X}"
    tb.log.info("PKT1 read data verified OK")

    await tb.wait_returner_idle()

    # ── Step 5: Verify returner transaction ──────────────────────────
    # Channel 0 writes token_delta_data = packet_word_length + 1 = total_words
    returner_data = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)
    expected_delta = pkt1.total_words
    tb.log.info(f"Returner wrote {returner_data} to 0x{PAIR_RELEASED_TOKENS_ADDR:03X} "
                f"(expected delta={expected_delta})")
    assert returner_data == expected_delta, \
        f"Returner delta mismatch: expected {expected_delta}, got {returner_data}"

    # ── Step 6: Read packet 2 — triggers second return ───────────────
    tb.ahb_slave.memory.write(PAIR_RELEASED_TOKENS_ADDR, b'\x00\x00\x00\x00')

    read_pkt2, rhit2 = await tb.read_packet(label="RD_PKT2")
    assert rhit2, "read_addr_hit should fire for packet 2 read"
    for i, (exp, got) in enumerate(zip(pkt2_data, read_pkt2.data)):
        assert exp == got, f"PKT2 word {i}: expected 0x{exp:08X}, got 0x{got:08X}"
    tb.log.info("PKT2 read data verified OK")

    await tb.wait_returner_idle()

    returner_data = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)
    expected_delta = pkt2.total_words
    tb.log.info(f"Returner wrote {returner_data} (expected delta={expected_delta})")
    assert returner_data == expected_delta

    # ── Step 7: Final token check via APB ────────────────────────────
    hw_tokens = await tb.read_token_count()
    tb.log.info(f"Final: hw_tokens={hw_tokens}, sw_tokens={tb.sw_token_count}")
    assert hw_tokens == MAX_TOKENS
    assert tb.sw_token_count == MAX_TOKENS

    tb.log.info("Full write-read-return flow verified successfully")


@cocotb.test()
async def test_04_multiple_packets_token_tracking(dut):
    """Write several packets, read them back one at a time, and verify
    the Python token model matches hardware after every operation."""
    tb = TidelinkTB(dut)
    await tb.reset()

    packets = [
        [0x11110001, 0x11110002],
        [0x22220001, 0x22220002, 0x22220003, 0x22220004],
        [0x33330001],
    ]

    for i, data in enumerate(packets):
        hit = await tb.write_packet(data, label=f"WR{i+1}")
        assert hit, f"write_addr_hit should fire for packet {i+1}"
        hw_tokens = await tb.read_token_count()
        assert hw_tokens == tb.sw_token_count, \
            f"Token mismatch after write {i+1}: hw={hw_tokens}, sw={tb.sw_token_count}"

    for i, data in enumerate(packets):
        pkt = FifoPacket(data=data)
        # Clear target before each read
        tb.ahb_slave.memory.write(PAIR_RELEASED_TOKENS_ADDR, b'\x00\x00\x00\x00')

        read_pkt, rhit = await tb.read_packet(label=f"RD{i+1}")
        assert rhit, f"read_addr_hit should fire for read {i+1}"
        for j, (exp, got) in enumerate(zip(data, read_pkt.data)):
            assert exp == got, f"Pkt {i+1} word {j}: expected 0x{exp:08X}, got 0x{got:08X}"

        await tb.wait_returner_idle()

        # Verify returner wrote token delta
        returner_data = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)
        assert returner_data == pkt.total_words, \
            f"Read {i+1}: returner wrote {returner_data}, expected {pkt.total_words}"

        hw_tokens = await tb.read_token_count()
        assert hw_tokens == tb.sw_token_count, \
            f"Token mismatch after read {i+1}: hw={hw_tokens}, sw={tb.sw_token_count}"
        tb.log.info(f"After read {i+1}: tokens={hw_tokens}")

    assert tb.sw_token_count == MAX_TOKENS
    tb.log.info("All packets verified with correct token tracking")


# ══════════════════════════════════════════════════════════════════════════════
# Bug Regression Tests
# ══════════════════════════════════════════════════════════════════════════════


@cocotb.test()
async def test_bug001_stale_token_delta_data(dut):
    """BUG-001: Returner sends delta=1 instead of actual packet size.

    Root cause: packet_word_length is cleared to 0 on the same cycle
    read_complete fires (tidelink_ahb_fifo_ctrl.sv:142-143). The returner
    captures token_delta_data one cycle later, by which time
    packet_word_length_r = 0, so delta = 0 + 1 = 1.

    This test writes packets of varying sizes, reads them back, and
    verifies the returner writes the correct delta to the AHB slave RAM.
    If the bug is present, delta will always be 1 regardless of packet size.
    """
    tb = TidelinkTB(dut)
    await tb.reset()

    test_cases = [
        ([0xAA000001, 0xAA000002, 0xAA000003], 4),  # 3 data words → delta should be 4
        ([0xBB000001, 0xBB000002], 3),                # 2 data words → delta should be 3
        ([0xCC000001], 2),                             # 1 data word  → delta should be 2
        ([0xDD000001, 0xDD000002, 0xDD000003,          # 5 data words → delta should be 6
          0xDD000004, 0xDD000005], 6),
    ]

    for i, (data, expected_delta) in enumerate(test_cases):
        # Write the packet
        await tb.write_packet(data, label=f"BUG001_WR{i+1}")

        # Clear the slave RAM at the target address before reading
        tb.ahb_slave.memory.write(PAIR_RELEASED_TOKENS_ADDR, b'\x00\x00\x00\x00')

        # Read the packet back — triggers read_complete → returner channel 0
        read_pkt, rhit = await tb.read_packet(label=f"BUG001_RD{i+1}")

        # Wait for the returner to complete its AHB write
        await tb.wait_returner_idle()
        await ClockCycles(dut.hclk, 2)

        # Read what the returner wrote to the slave RAM
        actual_delta = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)

        tb.log.info(
            f"Packet {i+1} ({len(data)} data words): "
            f"expected delta={expected_delta}, actual delta={actual_delta}"
        )

        if actual_delta == 1 and expected_delta != 1:
            tb.log.error(
                f"BUG-001 CONFIRMED: Returner sent delta=1 instead of "
                f"{expected_delta}. packet_word_length was cleared before "
                f"the returner could capture it."
            )

        assert actual_delta == expected_delta, (
            f"BUG-001: Packet {i+1} ({len(data)} data words): "
            f"returner sent delta={actual_delta}, expected {expected_delta}. "
            f"packet_word_length is stale when returner captures it."
        )

    tb.log.info("BUG-001 test passed — all deltas correct")


@cocotb.test()
async def test_bug001_cumulative_token_drift(dut):
    """BUG-001 cumulative impact: after N read-backs, the total tokens
    returned to the pair should equal the total tokens consumed.

    If the bug is present (delta always 1), the pair sees N tokens
    returned instead of the actual total, causing progressive drift.
    """
    tb = TidelinkTB(dut)
    await tb.reset()

    packets = [
        [0x11, 0x22, 0x33],        # 3+1 = 4 tokens
        [0x44, 0x55],               # 2+1 = 3 tokens
        [0x66],                     # 1+1 = 2 tokens
        [0x77, 0x88, 0x99, 0xAA],  # 4+1 = 5 tokens
    ]
    total_expected_delta = sum(len(p) + 1 for p in packets)  # 4+3+2+5 = 14

    # Write all packets
    for i, data in enumerate(packets):
        await tb.write_packet(data, label=f"DRIFT_WR{i+1}")

    # Read all packets back, accumulating deltas
    cumulative_delta = 0
    for i, data in enumerate(packets):
        tb.ahb_slave.memory.write(PAIR_RELEASED_TOKENS_ADDR, b'\x00\x00\x00\x00')

        _, rhit = await tb.read_packet(label=f"DRIFT_RD{i+1}")
        await tb.wait_returner_idle()
        await ClockCycles(dut.hclk, 2)

        delta = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)
        cumulative_delta += delta
        tb.log.info(f"Read {i+1}: delta={delta}, cumulative={cumulative_delta}")

    tb.log.info(
        f"Total delta sent to pair: {cumulative_delta} "
        f"(expected {total_expected_delta})"
    )

    if cumulative_delta == len(packets):  # If delta=1 every time
        tb.log.error(
            f"BUG-001 CONFIRMED: Cumulative delta is {len(packets)} "
            f"(1 per read), should be {total_expected_delta}. "
            f"Token drift = {total_expected_delta - cumulative_delta} tokens lost."
        )

    assert cumulative_delta == total_expected_delta, (
        f"BUG-001: Cumulative token delta drift. "
        f"Pair received {cumulative_delta} tokens, expected {total_expected_delta}. "
        f"Drift = {total_expected_delta - cumulative_delta} tokens."
    )


@cocotb.test()
async def test_bug004_delta_total_accumulator_conflation(dut):
    """BUG-004: Channel 0 deltas and channel 1 totals share the same
    accumulator on the pair side. If a read_complete (channel 0) fires
    and then a doorbell (channel 1) fires before the pair reads the
    accumulator, the values add together, giving an inflated count.

    This test:
    1. Writes and reads a packet (channel 0 fires with delta)
    2. While the returner is still busy or just finished, triggers doorbell
    3. Checks what the pair's accumulator received
    4. Verifies whether the delta and total are conflated
    """
    tb = TidelinkTB(dut)
    await tb.reset()

    pkt_data = [0xAA, 0xBB, 0xCC]  # 3 data words → delta = 4
    expected_delta = len(pkt_data) + 1  # 4

    # Write a packet
    await tb.write_packet(pkt_data, label="CONFLATE_WR")

    # Clear slave RAM
    tb.ahb_slave.memory.write(PAIR_RELEASED_TOKENS_ADDR, b'\x00\x00\x00\x00')

    # Read the packet back — triggers channel 0 (delta)
    _, _ = await tb.read_packet(label="CONFLATE_RD")

    # Wait for channel 0 to complete
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    # Record channel 0 write
    delta_written = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)
    tb.log.info(f"Channel 0 wrote delta = {delta_written}")

    # Now trigger doorbell (channel 1) — writes total tokens
    # The pair's accumulator hasn't been "read" (cleared), so if both
    # channel 0 and channel 1 target the same address, values accumulate
    # in the AHBLiteSlaveRAM (which just stores the last write, not
    # accumulating). But in real hardware, the paired tidelink's
    # write-to-add accumulator WOULD add them.
    #
    # This test documents the architectural concern: channel 0 and
    # channel 1 share PAIR_RELEASED_TOKENS_ADDR, meaning if both fire
    # before the pair CPU reads the accumulator, totals and deltas mix.

    # Trigger doorbell via APB
    await tb.apb.write(APB_REG_DOORBELL, 1)
    await ClockCycles(dut.hclk, 2)
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    # Read what channel 1 wrote (overwrites in slave RAM)
    total_written = tb.read_returner_memory(PAIR_RELEASED_TOKENS_ADDR)
    expected_total = MAX_TOKENS - expected_delta  # tokens freed by read, but delta already consumed

    tb.log.info(
        f"Channel 1 wrote total = {total_written} "
        f"(expected current_token_count = {await tb.read_token_count()})"
    )

    # Document the architectural issue:
    # In real hardware, the pair's accumulator would contain:
    #   delta_written + total_written (if CPU hasn't read in between)
    # This conflates "tokens freed by this read" with "total free tokens".
    # The pair's software must be aware of this protocol.
    hw_token_count = await tb.read_token_count()
    tb.log.info(
        f"Architectural note: Channel 0 (delta={delta_written}) and "
        f"Channel 1 (total={total_written}) both target "
        f"PAIR_RELEASED_TOKENS_ADDR (0x{PAIR_RELEASED_TOKENS_ADDR:03X}). "
        f"In real hardware, pair accumulator would see "
        f"{delta_written + total_written} if CPU hasn't cleared it."
    )

    # Verify channel 1 sent the correct total (current token count)
    assert total_written == hw_token_count, (
        f"Channel 1 (doorbell) should send current token count "
        f"({hw_token_count}), got {total_written}"
    )
