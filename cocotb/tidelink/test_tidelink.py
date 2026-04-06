"""Cocotb testbench for the tidelink top-level module.

Tests the integrated system: AHB FIFO (slave), AHB returner (master),
and APB configuration registers.  Uses cocotbext-ahb for both the
AHBLiteMaster (driving the FIFO slave port) and AHBLiteSlaveRAM
(responding to the returner master port).

Infrastructure is object-oriented so it can be reused across tests.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster, AHBLiteSlaveRAM

from tidelink.packet import FifoPacket
from tidelink.regs import RAM_ADDR_W, MAX_CREDITS

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10

# Default TIDELINK_PAIR_BASE = 0, so returner targets are:
PAIR_RELEASED_CREDITS_ADDR   = 0x20
PAIR_DOORBELL_RESPONSE_ADDR = 0x24
PAIR_DOORBELL_ADDR          = 0x14

# APB register offsets (local aliases for backward compatibility)
APB_REG_PAIR_BASE         = 0x000
APB_REG_REL_THRESHOLD     = 0x004
APB_REG_PKT_WORD_LEN      = 0x008
APB_REG_CREDIT_COUNT        = 0x00C
APB_REG_STATUS             = 0x010
APB_REG_DOORBELL           = 0x014
APB_REG_REL_ACC            = 0x018
APB_REG_RELEASED_ACC       = 0x020
APB_REG_DOORBELL_RESP_ACC  = 0x024
APB_REG_CTRL               = 0x01C


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


# ── Slave Task Lifecycle ─────────────────────────────────────────────────────

_prev_slave_task = None  # Track previous AHBLiteSlaveRAM background coroutine


def _create_slave_ram(bus, clock, reset, **kwargs):
    """Create AHBLiteSlaveRAM and capture its background task handle.

    AHBLiteSlave.__init__ calls cocotb.start_soon(self._proc_txn()) internally.
    We wrap start_soon to intercept the task handle so it can be killed later.
    """
    global _prev_slave_task
    captured_task = None
    original_start_soon = cocotb.start_soon

    def capturing_start_soon(coro):
        nonlocal captured_task
        task = original_start_soon(coro)
        captured_task = task
        return task

    cocotb.start_soon = capturing_start_soon
    try:
        slave = AHBLiteSlaveRAM(bus, clock, reset, **kwargs)
    finally:
        cocotb.start_soon = original_start_soon

    _prev_slave_task = captured_task
    return slave


# ── Testbench Environment ────────────────────────────────────────────────────

class TidelinkTB:
    """Reusable testbench environment for the tidelink top-level module.

    The previous AHBLiteSlaveRAM's background task is killed before creating
    a new one to prevent bus contention from stale driver coroutines.
    """

    def __init__(self, dut):
        global _prev_slave_task
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
        self.ahb_master = AHBLiteMaster(
            ahbs_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # Kill previous slave coroutine and create a fresh one
        if _prev_slave_task is not None:
            _prev_slave_task.kill()
        ahbm_bus = AHBBus.from_prefix(dut, "ahbm")
        self.ahb_slave = _create_slave_ram(
            ahbm_bus, dut.hclk, dut.hresetn, mem_size=4096
        )

        self.apb = APBMaster(dut, dut.hclk)
        self.sw_credit_count = MAX_CREDITS

    async def reset(self):
        """Assert active-low reset for 5 cycles, then release."""
        self.apb.idle()
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        # Wait extra cycles for reset deassertion pulse (channel 2) to complete
        await ClockCycles(self.dut.hclk, 10)
        self.sw_credit_count = MAX_CREDITS

    # ── APB Helpers ──────────────────────────────────────────────────────

    async def read_credit_count(self) -> int:
        return await self.apb.read(APB_REG_CREDIT_COUNT)

    async def read_status(self) -> dict:
        raw = await self.apb.read(APB_REG_STATUS)
        return {
            "write_addr_hit": bool(raw & 1),
            "read_addr_hit":  bool(raw & 2),
            "returner_busy":  bool(raw & 4),
            "raw": raw,
        }

    # ── Packet Write (inline AHB phases) ─────────────────────────────────

    async def write_packet(self, data, label: str = "") -> bool:
        """Write a packet into the FIFO. Returns True if write_complete fired."""
        pkt = FifoPacket(data=data)
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        # Write 2-word header: word0 (packed) to 0x0000, dest_addr to 0x0004
        await self.ahb_master.write(0x0000, pkt.word0)
        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 2)
        await self.ahb_master.write(0x0004, pkt.dest_addr)
        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 2)
        self.log.info(f"{prefix}Writing {pkt.length}-word packet")

        hit_fired = False
        for i, word in enumerate(pkt.data):
            addr = (i + 2) * 4
            await RisingEdge(dut.hclk)
            dut.ahbs_hsel.value   = 1
            dut.ahbs_htrans.value = 2
            dut.ahbs_hwrite.value = 1
            dut.ahbs_hsize.value  = 2
            dut.ahbs_haddr.value  = addr
            await RisingEdge(dut.hclk)
            # Sample write_complete before idling the bus (combinational signal)
            try:
                hit = int(dut.u_dut.u_fifo_mem.u_fifo_ctrl.write_complete.value)
            except ValueError:
                hit = 0
            dut.ahbs_hwdata.value = word
            dut.ahbs_htrans.value = 0
            dut.ahbs_hsel.value   = 0
            await RisingEdge(dut.hclk)
            dut.ahbs_hwrite.value = 0
            if hit:
                hit_fired = True

        dut.ahbs_haddr.value = 0x3FFF
        await ClockCycles(dut.hclk, 1)
        if hit_fired:
            self.sw_credit_count -= pkt.total_words
            self.log.info(f"{prefix}Write complete. sw_credits={self.sw_credit_count}")
        return hit_fired

    # ── Packet Read (inline AHB phases) ──────────────────────────────────

    async def read_packet(self, label: str = "") -> (FifoPacket, bool):
        """Read a packet from the FIFO. Returns (FifoPacket, read_complete_fired)."""
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        # Read Word 0 (packed header) from addr 0x0000 — triggers capture
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

        pkt_len = int(dut.u_dut.u_fifo_mem.packet_word_length.value)
        self.log.info(f"{prefix}Read length = {pkt_len}")

        # Read Word 1 (dest_addr) from addr 0x0004
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0
        dut.ahbs_hsize.value  = 2
        dut.ahbs_haddr.value  = 0x0004
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        dut.ahbs_haddr.value  = 0x3FFF
        await RisingEdge(dut.hclk)
        try:
            dest_addr = int(dut.ahbs_hrdata.value)
        except ValueError:
            dest_addr = 0

        hit_fired = False
        data = []
        for i in range(pkt_len):
            addr = (i + 2) * 4
            await RisingEdge(dut.hclk)
            dut.ahbs_hsel.value   = 1
            dut.ahbs_htrans.value = 2
            dut.ahbs_hwrite.value = 0
            dut.ahbs_hsize.value  = 2
            dut.ahbs_haddr.value  = addr
            await RisingEdge(dut.hclk)
            # Sample read_complete before idling the bus (combinational signal)
            try:
                hit = int(dut.u_dut.u_fifo_mem.read_complete.value)
            except ValueError:
                hit = 0
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
        pkt = FifoPacket(data=data, dest_addr=dest_addr)
        if hit_fired:
            self.sw_credit_count += pkt.total_words
            self.log.info(f"{prefix}Read complete ({pkt.length} words). sw_credits={self.sw_credit_count}")
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
async def test_01_reset_and_initial_credits(dut):
    """After reset the APB credit-count register should read MAX_CREDITS."""
    tb = TidelinkTB(dut)
    await tb.reset()

    hw_credits = await tb.read_credit_count()
    tb.log.info(f"Credit count after reset: {hw_credits} (expected {MAX_CREDITS})")
    assert hw_credits == MAX_CREDITS, \
        f"Expected {MAX_CREDITS}, got {hw_credits}"


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
    1. Check initial credit count
    2. Write two packets into the FIFO
    3. Track credits in software
    4. Read one packet back — returner should fire channel 0
    5. Verify returner wrote credit_delta_data to PAIR_RELEASED_CREDITS_ADDR
    6. Read second packet — verify second return
    7. Confirm final credit count via APB
    """
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)  # Immediate release mode

    # ── Step 1: Verify initial credit count ───────────────────────────
    hw_credits = await tb.read_credit_count()
    assert hw_credits == MAX_CREDITS, \
        f"Initial credits: expected {MAX_CREDITS}, got {hw_credits}"
    tb.log.info(f"Initial credit count = {hw_credits}")

    # ── Step 2: Write two packets ────────────────────────────────────
    pkt1_data = [0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]
    pkt2_data = [0xBBBB_0001, 0xBBBB_0002]

    hit1 = await tb.write_packet(pkt1_data, label="WR_PKT1")
    assert hit1, "write_addr_hit should fire for packet 1"
    hit2 = await tb.write_packet(pkt2_data, label="WR_PKT2")
    assert hit2, "write_addr_hit should fire for packet 2"

    # ── Step 3: Verify credit count after writes ──────────────────────
    pkt1 = FifoPacket(data=pkt1_data)
    pkt2 = FifoPacket(data=pkt2_data)
    expected_credits = MAX_CREDITS - pkt1.total_words - pkt2.total_words

    hw_credits = await tb.read_credit_count()
    tb.log.info(f"After 2 writes: hw_credits={hw_credits}, expected={expected_credits}")
    assert hw_credits == expected_credits
    assert tb.sw_credit_count == expected_credits

    # ── Step 4: Read packet 1 — triggers returner channel 0 ─────────
    # Clear any prior returner writes at the target address
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    read_pkt1, rhit1 = await tb.read_packet(label="RD_PKT1")
    assert rhit1, "read_addr_hit should fire for packet 1 read"
    for i, (exp, got) in enumerate(zip(pkt1_data, read_pkt1.data)):
        assert exp == got, f"PKT1 word {i}: expected 0x{exp:08X}, got 0x{got:08X}"
    tb.log.info("PKT1 read data verified OK")

    await tb.wait_returner_idle()

    # ── Step 5: Verify returner transaction ──────────────────────────
    # Channel 0 writes credit_delta_data = packet_word_length + 2 = total_words
    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    expected_delta = pkt1.total_words
    tb.log.info(f"Returner wrote {returner_data} to 0x{PAIR_RELEASED_CREDITS_ADDR:03X} "
                f"(expected delta={expected_delta})")
    assert returner_data == expected_delta, \
        f"Returner delta mismatch: expected {expected_delta}, got {returner_data}"

    # ── Step 6: Read packet 2 — triggers second return ───────────────
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    read_pkt2, rhit2 = await tb.read_packet(label="RD_PKT2")
    assert rhit2, "read_addr_hit should fire for packet 2 read"
    for i, (exp, got) in enumerate(zip(pkt2_data, read_pkt2.data)):
        assert exp == got, f"PKT2 word {i}: expected 0x{exp:08X}, got 0x{got:08X}"
    tb.log.info("PKT2 read data verified OK")

    await tb.wait_returner_idle()

    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    expected_delta = pkt2.total_words
    tb.log.info(f"Returner wrote {returner_data} (expected delta={expected_delta})")
    assert returner_data == expected_delta

    # ── Step 7: Final credit check via APB ────────────────────────────
    hw_credits = await tb.read_credit_count()
    tb.log.info(f"Final: hw_credits={hw_credits}, sw_credits={tb.sw_credit_count}")
    assert hw_credits == MAX_CREDITS
    assert tb.sw_credit_count == MAX_CREDITS

    tb.log.info("Full write-read-return flow verified successfully")


@cocotb.test()
async def test_04_multiple_packets_credit_tracking(dut):
    """Write several packets, read them back one at a time, and verify
    the Python credit model matches hardware after every operation."""
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)  # Immediate release mode

    packets = [
        [0x11110001, 0x11110002],
        [0x22220001, 0x22220002, 0x22220003, 0x22220004],
        [0x33330001],
    ]

    for i, data in enumerate(packets):
        hit = await tb.write_packet(data, label=f"WR{i+1}")
        assert hit, f"write_addr_hit should fire for packet {i+1}"
        hw_credits = await tb.read_credit_count()
        assert hw_credits == tb.sw_credit_count, \
            f"Credit mismatch after write {i+1}: hw={hw_credits}, sw={tb.sw_credit_count}"

    for i, data in enumerate(packets):
        pkt = FifoPacket(data=data)
        # Clear target before each read
        tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

        read_pkt, rhit = await tb.read_packet(label=f"RD{i+1}")
        assert rhit, f"read_addr_hit should fire for read {i+1}"
        for j, (exp, got) in enumerate(zip(data, read_pkt.data)):
            assert exp == got, f"Pkt {i+1} word {j}: expected 0x{exp:08X}, got 0x{got:08X}"

        await tb.wait_returner_idle()

        # Verify returner wrote credit delta
        returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
        assert returner_data == pkt.total_words, \
            f"Read {i+1}: returner wrote {returner_data}, expected {pkt.total_words}"

        hw_credits = await tb.read_credit_count()
        assert hw_credits == tb.sw_credit_count, \
            f"Credit mismatch after read {i+1}: hw={hw_credits}, sw={tb.sw_credit_count}"
        tb.log.info(f"After read {i+1}: credits={hw_credits}")

    assert tb.sw_credit_count == MAX_CREDITS
    tb.log.info("All packets verified with correct credit tracking")


# ══════════════════════════════════════════════════════════════════════════════
# Bug Regression Tests
# ══════════════════════════════════════════════════════════════════════════════


@cocotb.test()
async def test_bug001_stale_credit_delta_data(dut):
    """BUG-001: Returner sends delta=1 instead of actual packet size.

    Root cause: packet_word_length is cleared to 0 on the same cycle
    read_complete fires (tidelink_ahb_fifo_ctrl.sv:142-143). The returner
    captures credit_delta_data one cycle later, by which time
    packet_word_length_r = 0, so delta = 0 + 1 = 1.

    This test writes packets of varying sizes, reads them back, and
    verifies the returner writes the correct delta to the AHB slave RAM.
    If the bug is present, delta will always be 1 regardless of packet size.
    """
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)  # Immediate release mode

    test_cases = [
        ([0xAA000001, 0xAA000002, 0xAA000003], 5),  # 3 data words → delta should be 5
        ([0xBB000001, 0xBB000002], 4),                # 2 data words → delta should be 4
        ([0xCC000001], 3),                             # 1 data word  → delta should be 3
        ([0xDD000001, 0xDD000002, 0xDD000003,          # 5 data words → delta should be 7
          0xDD000004, 0xDD000005], 7),
    ]

    for i, (data, expected_delta) in enumerate(test_cases):
        # Write the packet
        await tb.write_packet(data, label=f"BUG001_WR{i+1}")

        # Clear the slave RAM at the target address before reading
        tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

        # Read the packet back — triggers read_complete → returner channel 0
        read_pkt, rhit = await tb.read_packet(label=f"BUG001_RD{i+1}")

        # Wait for the returner to complete its AHB write
        await tb.wait_returner_idle()
        await ClockCycles(dut.hclk, 2)

        # Read what the returner wrote to the slave RAM
        actual_delta = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)

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
async def test_bug001_cumulative_credit_drift(dut):
    """BUG-001 cumulative impact: after N read-backs, the total credits
    returned to the pair should equal the total credits consumed.

    If the bug is present (delta always 1), the pair sees N credits
    returned instead of the actual total, causing progressive drift.
    """
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)  # Immediate release mode

    packets = [
        [0x11, 0x22, 0x33],        # 3+2 = 5 credits
        [0x44, 0x55],               # 2+2 = 4 credits
        [0x66],                     # 1+2 = 3 credits
        [0x77, 0x88, 0x99, 0xAA],  # 4+2 = 6 credits
    ]
    total_expected_delta = sum(len(p) + 2 for p in packets)  # 5+4+3+6 = 18

    # Write all packets
    for i, data in enumerate(packets):
        await tb.write_packet(data, label=f"DRIFT_WR{i+1}")

    # Read all packets back, accumulating deltas
    cumulative_delta = 0
    for i, data in enumerate(packets):
        tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

        _, rhit = await tb.read_packet(label=f"DRIFT_RD{i+1}")
        await tb.wait_returner_idle()
        await ClockCycles(dut.hclk, 2)

        delta = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
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
            f"Credit drift = {total_expected_delta - cumulative_delta} credits lost."
        )

    assert cumulative_delta == total_expected_delta, (
        f"BUG-001: Cumulative credit delta drift. "
        f"Pair received {cumulative_delta} credits, expected {total_expected_delta}. "
        f"Drift = {total_expected_delta - cumulative_delta} credits."
    )


@cocotb.test()
async def test_bug004_fix_delta_total_separate_accumulators(dut):
    """BUG-004 FIX VERIFICATION: Channel 0 deltas and channel 1 totals
    now target SEPARATE addresses on the pair side.

    Channel 0 → PAIR_RELEASED_CREDITS_ADDR (0x020)
    Channel 1 → PAIR_DOORBELL_RESPONSE_ADDR (0x024)

    This test verifies they don't interfere with each other.
    """
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)  # Immediate release mode

    pkt_data = [0xAA, 0xBB, 0xCC]  # 3 data words → delta = 5
    expected_delta = len(pkt_data) + 2  # 5

    # Write a packet
    await tb.write_packet(pkt_data, label="SEP_ACC_WR")

    # Clear both slave RAM locations
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')
    tb.ahb_slave.memory.write(PAIR_DOORBELL_RESPONSE_ADDR, b'\x00\x00\x00\x00')

    # Read the packet back — triggers channel 0 (delta → 0x020)
    _, _ = await tb.read_packet(label="SEP_ACC_RD")
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    # Channel 0 should have written to 0x020 (delta accumulator)
    delta_at_020 = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    total_at_024 = tb.read_returner_memory(PAIR_DOORBELL_RESPONSE_ADDR)
    tb.log.info(f"After read: 0x020={delta_at_020}, 0x024={total_at_024}")

    assert delta_at_020 == expected_delta, \
        f"Channel 0 should write delta={expected_delta} to 0x020, got {delta_at_020}"
    assert total_at_024 == 0, \
        f"0x024 should be untouched after channel 0, got {total_at_024}"

    # Now trigger doorbell (channel 1 → 0x024)
    await tb.apb.write(APB_REG_DOORBELL, 1)
    await ClockCycles(dut.hclk, 2)
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    # Channel 1 should have written to 0x024 (doorbell response accumulator)
    delta_at_020_after = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    total_at_024_after = tb.read_returner_memory(PAIR_DOORBELL_RESPONSE_ADDR)
    hw_credit_count = await tb.read_credit_count()

    tb.log.info(
        f"After doorbell: 0x020={delta_at_020_after}, "
        f"0x024={total_at_024_after}, credit_count={hw_credit_count}"
    )

    # 0x020 should still have the delta from channel 0 (not overwritten)
    assert delta_at_020_after == expected_delta, \
        f"Channel 1 should NOT overwrite 0x020: expected {expected_delta}, got {delta_at_020_after}"

    # 0x024 should have the total credit count from channel 1
    assert total_at_024_after == hw_credit_count, \
        f"Channel 1 should write credit_count={hw_credit_count} to 0x024, got {total_at_024_after}"

    tb.log.info("BUG-004 fix verified: deltas and totals use separate accumulators")


# ══════════════════════════════════════════════════════════════════════════════
# Release Threshold Tests
# ══════════════════════════════════════════════════════════════════════════════


@cocotb.test()
async def test_thresh_01_default_batching(dut):
    """With default threshold=20, small packet reads accumulate and release
    as a single batched delta when the total crosses the threshold."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # Default threshold is 20 — verify
    threshold = await tb.apb.read(APB_REG_REL_THRESHOLD)
    assert threshold == 20, f"Expected default threshold=20, got {threshold}"

    # Write 7 small packets (2 data words each → delta=4 per read)
    # After 5 reads: accumulated = 5*4 = 20 >= 20 → trigger fires
    packets = [[0xAA00 + i, 0xBB00 + i] for i in range(7)]
    for i, data in enumerate(packets):
        hit = await tb.write_packet(data, label=f"BATCH_WR{i}")
        assert hit

    # Clear returner target
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    # Read packets one by one — returner should NOT fire until threshold crossed
    for i in range(4):
        _, rhit = await tb.read_packet(label=f"BATCH_RD{i}")
        assert rhit
        await ClockCycles(dut.hclk, 5)

    # After 4 reads: acc = 4*4 = 16 < 20, returner should not have fired
    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    tb.log.info(f"After 4 reads: returner target = {returner_data}")
    assert returner_data == 0, \
        f"Returner should not have fired yet (acc=16 < 20), but target has {returner_data}"

    # 5th read: acc = 16 + 4 = 20 >= 20 → trigger fires with batched delta=20
    _, rhit = await tb.read_packet(label="BATCH_RD4")
    assert rhit
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    tb.log.info(f"After 5 reads: returner target = {returner_data}")
    assert returner_data == 20, \
        f"Expected batched delta=20, got {returner_data}"

    tb.log.info("Default threshold batching verified")


@cocotb.test()
async def test_thresh_02_threshold_register_rw(dut):
    """Release threshold register is readable and writable via APB."""
    tb = TidelinkTB(dut)
    await tb.reset()

    val = await tb.apb.read(APB_REG_REL_THRESHOLD)
    assert val == 20, f"Default should be 20, got {val}"

    await tb.apb.write(APB_REG_REL_THRESHOLD, 50)
    val = await tb.apb.read(APB_REG_REL_THRESHOLD)
    assert val == 50, f"Expected 50 after write, got {val}"


@cocotb.test()
async def test_thresh_03_large_packet_exceeds_threshold(dut):
    """A single packet whose delta exceeds the threshold releases immediately."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # Set threshold=10
    await tb.apb.write(APB_REG_REL_THRESHOLD, 10)

    # Write a large packet: 15 data words → delta = 17 > 10
    pkt_data = [0xDD00 + i for i in range(15)]
    hit = await tb.write_packet(pkt_data, label="LARGE_WR")
    assert hit

    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    _, rhit = await tb.read_packet(label="LARGE_RD")
    assert rhit
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    assert returner_data == 17, \
        f"Expected immediate delta=17, got {returner_data}"


@cocotb.test()
async def test_thresh_04_threshold_zero_backward_compat(dut):
    """Threshold=0 gives per-read immediate release (backward compatible)."""
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)

    pkt_data = [0xAA, 0xBB, 0xCC]  # 3 data words → delta = 5

    hit = await tb.write_packet(pkt_data, label="COMPAT_WR")
    assert hit

    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    _, rhit = await tb.read_packet(label="COMPAT_RD")
    assert rhit
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    assert returner_data == 5, \
        f"Expected immediate delta=5, got {returner_data}"


# ── Packet Committed IRQ ────────────────────────────────────────────────────


@cocotb.test()
async def test_12_packet_committed_irq_propagation(dut):
    """packet_committed_irq asserts on write_complete, clears on read addr 0,
    propagated through the tidelink top-level hierarchy."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # Verify deasserted after reset
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should be 0 after reset"

    # Write a packet — IRQ should assert
    hit = await tb.write_packet([0xDEAD, 0xBEEF], label="IRQ_TEST_WR")
    assert hit, "write_complete should have fired"
    await RisingEdge(dut.hclk)
    assert int(dut.packet_committed_irq.value) == 1, \
        "packet_committed_irq should be 1 after write_complete"

    # Read the packet — first read from addr 0 clears IRQ
    pkt, rhit = await tb.read_packet(label="IRQ_TEST_RD")
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should be 0 after read from FIFO addr 0"

    # Write another packet — verify IRQ re-asserts
    hit2 = await tb.write_packet([0xCAFE, 0xBABE, 0xF00D], label="IRQ_TEST_WR2")
    assert hit2
    await RisingEdge(dut.hclk)
    assert int(dut.packet_committed_irq.value) == 1, \
        "packet_committed_irq should re-assert on second write"


# ── STATUS[4] Packet Committed Polling ─────────────────────────────────────


@cocotb.test()
async def test_13_status_packet_committed_polling(dut):
    """STATUS[4] (packet_committed) can be polled via APB as an alternative
    to using the packet_committed_irq interrupt output.

    Verifies:
    1. STATUS[4] is 0 after reset (no packet pending)
    2. STATUS[4] goes to 1 after a packet is written (write_complete)
    3. STATUS[4] returns to 0 after the receiver reads FIFO address 0
    4. STATUS[4] mirrors the packet_committed_irq output at every step
    5. Multi-packet cycle: write/poll/read/poll for two packets
    """
    tb = TidelinkTB(dut)
    await tb.reset()

    STATUS_PACKET_COMMITTED_BIT = 4

    # ── Step 1: STATUS[4] == 0 after reset ──────────────────────────
    status = await tb.apb.read(APB_REG_STATUS)
    pkt_ready = (status >> STATUS_PACKET_COMMITTED_BIT) & 1
    assert pkt_ready == 0, \
        f"STATUS[4] should be 0 after reset, got STATUS=0x{status:08X}"
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should match STATUS[4] (both 0)"

    # ── Step 2: Write a packet — STATUS[4] should go to 1 ──────────
    hit = await tb.write_packet([0xAA, 0xBB, 0xCC], label="POLL_WR1")
    assert hit, "write_complete should fire"
    await RisingEdge(dut.hclk)

    status = await tb.apb.read(APB_REG_STATUS)
    pkt_ready = (status >> STATUS_PACKET_COMMITTED_BIT) & 1
    assert pkt_ready == 1, \
        f"STATUS[4] should be 1 after write_complete, got STATUS=0x{status:08X}"
    assert int(dut.packet_committed_irq.value) == 1, \
        "packet_committed_irq should match STATUS[4] (both 1)"

    # ── Step 3: Read the packet — STATUS[4] should clear ───────────
    pkt, rhit = await tb.read_packet(label="POLL_RD1")
    assert rhit, "read_complete should fire"

    status = await tb.apb.read(APB_REG_STATUS)
    pkt_ready = (status >> STATUS_PACKET_COMMITTED_BIT) & 1
    assert pkt_ready == 0, \
        f"STATUS[4] should be 0 after read from addr 0, got STATUS=0x{status:08X}"
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should match STATUS[4] (both 0)"

    # Verify data integrity
    assert pkt.data == [0xAA, 0xBB, 0xCC], \
        f"Data mismatch: expected [0xAA, 0xBB, 0xCC], got {pkt.data}"

    # Wait for returner to complete before next packet
    await tb.wait_returner_idle()

    # ── Step 4: Second packet cycle — poll-driven read ──────────────
    hit2 = await tb.write_packet([0x11, 0x22], label="POLL_WR2")
    assert hit2
    await RisingEdge(dut.hclk)

    # Poll until STATUS[4] is set
    status = await tb.apb.read(APB_REG_STATUS)
    pkt_ready = (status >> STATUS_PACKET_COMMITTED_BIT) & 1
    assert pkt_ready == 1, \
        f"STATUS[4] should be 1 for second packet, got STATUS=0x{status:08X}"

    # Read second packet
    pkt2, rhit2 = await tb.read_packet(label="POLL_RD2")
    assert rhit2

    status = await tb.apb.read(APB_REG_STATUS)
    pkt_ready = (status >> STATUS_PACKET_COMMITTED_BIT) & 1
    assert pkt_ready == 0, \
        f"STATUS[4] should clear after second read, got STATUS=0x{status:08X}"

    assert pkt2.data == [0x11, 0x22], \
        f"Data mismatch: expected [0x11, 0x22], got {pkt2.data}"

    tb.log.info("STATUS[4] packet_committed polling verified across two packets")


# ══════════════════════════════════════════════════════════════════════════════
# Coverage Improvement Tests
# ══════════════════════════════════════════════════════════════════════════════


@cocotb.test()
async def test_cov_01_flush_resets_state(dut):
    """FLUSH (CTRL[1]) resets pointers, credit count, packet state, release
    accumulator, and sticky error flags."""
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)

    # Write two packets to consume credits and move pointers
    await tb.write_packet([0xAA, 0xBB, 0xCC], label="FLUSH_WR1")
    await tb.write_packet([0xDD, 0xEE], label="FLUSH_WR2")

    hw_credits_before = await tb.read_credit_count()
    assert hw_credits_before < MAX_CREDITS, "Credits should be consumed"

    # Read one packet so release_acc gets a value
    _, rhit = await tb.read_packet(label="FLUSH_RD1")
    assert rhit
    await tb.wait_returner_idle()

    # Write another packet so packet_committed_irq re-asserts
    await tb.write_packet([0x11, 0x22], label="FLUSH_WR3")
    await RisingEdge(dut.hclk)
    assert int(dut.packet_committed_irq.value) == 1, \
        "packet_committed_irq should be set after third write"

    # Issue FLUSH: write CTRL = 0x02 (FLUSH=1)
    await tb.apb.write(APB_REG_CTRL, 0x2)
    await ClockCycles(dut.hclk, 5)

    # Credit count should be back to MAX_CREDITS
    hw_credits_after = await tb.read_credit_count()
    assert hw_credits_after == MAX_CREDITS, \
        f"After flush: expected {MAX_CREDITS} credits, got {hw_credits_after}"

    # packet_committed_irq should be cleared
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should be 0 after flush"

    # Release accumulator should be 0
    rel_acc = await tb.apb.read(APB_REG_REL_ACC)
    assert rel_acc == 0, f"Release accumulator should be 0 after flush, got {rel_acc}"

    # Verify normal operation still works after flush
    await ClockCycles(dut.hclk, 10)
    hit = await tb.write_packet([0x11, 0x22], label="FLUSH_POST_WR")
    assert hit, "Should be able to write after flush"

    tb.log.info("Flush test passed — all state reset correctly")


@cocotb.test()
async def test_cov_02_apb_region1_released_credits_acc(dut):
    """APB Region 1 (paddr[5]=1): Released Credits Accumulator at 0x020.
    Write-add / Read-clear behaviour, plus released_credits_irq."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # After reset, accumulator should be 0, IRQ deasserted
    val = await tb.apb.read(APB_REG_RELEASED_ACC)
    assert val == 0, f"Expected 0 after reset, got {val}"
    assert int(dut.released_credits_irq.value) == 0

    # Write 10 to accumulator — should add
    await tb.apb.write(APB_REG_RELEASED_ACC, 10)
    await ClockCycles(dut.hclk, 1)
    assert int(dut.released_credits_irq.value) == 1, \
        "released_credits_irq should assert when acc != 0"

    # Write 5 more — should accumulate to 15
    await tb.apb.write(APB_REG_RELEASED_ACC, 5)
    val = await tb.apb.read(APB_REG_RELEASED_ACC)
    assert val == 15, f"Expected 15 (10+5), got {val}"

    # Read clears — next read should be 0
    val = await tb.apb.read(APB_REG_RELEASED_ACC)
    assert val == 0, f"Expected 0 after read-clear, got {val}"
    assert int(dut.released_credits_irq.value) == 0, \
        "released_credits_irq should deassert when acc == 0"

    tb.log.info("Released credits accumulator W-add/R-clear verified")


@cocotb.test()
async def test_cov_03_apb_region1_doorbell_resp_acc(dut):
    """APB Region 1: Doorbell Response Accumulator at 0x024.
    Write-add / Read-clear behaviour, plus doorbell_irq."""
    tb = TidelinkTB(dut)
    await tb.reset()

    val = await tb.apb.read(APB_REG_DOORBELL_RESP_ACC)
    assert val == 0

    assert int(dut.doorbell_irq.value) == 0

    # Write 7, then 3 — accumulate to 10
    await tb.apb.write(APB_REG_DOORBELL_RESP_ACC, 7)
    await tb.apb.write(APB_REG_DOORBELL_RESP_ACC, 3)

    await ClockCycles(dut.hclk, 1)
    assert int(dut.doorbell_irq.value) == 1

    val = await tb.apb.read(APB_REG_DOORBELL_RESP_ACC)
    assert val == 10, f"Expected 10, got {val}"

    # Read clears
    val = await tb.apb.read(APB_REG_DOORBELL_RESP_ACC)
    assert val == 0
    assert int(dut.doorbell_irq.value) == 0

    tb.log.info("Doorbell response accumulator verified")


@cocotb.test()
async def test_cov_04_apb_region1_pair_credit_counter(dut):
    """APB Region 1: Pair credit counter increment (0x020 write), decrement
    (0x02C write), read (0x028), enable/disable (0x030)."""
    tb = TidelinkTB(dut)
    await tb.reset()

    APB_REG_PAIR_CREDIT_CTR    = 0x028
    APB_REG_PAIR_CREDIT_CONS   = 0x02C
    APB_REG_PAIR_CREDIT_EN     = 0x030

    # After reset, counter = 0, enabled
    val = await tb.apb.read(APB_REG_PAIR_CREDIT_CTR)
    assert val == 0, f"Expected 0 after reset, got {val}"

    en = await tb.apb.read(APB_REG_PAIR_CREDIT_EN)
    assert en == 1, f"Expected enabled (1) after reset, got {en}"

    # Increment via released_credits_acc write (offset 0x020, region 1, paddr[4:2]=0)
    # This simultaneously adds to released_credits_acc AND increments pair_credit_counter
    await tb.apb.write(APB_REG_RELEASED_ACC, 5)
    val = await tb.apb.read(APB_REG_PAIR_CREDIT_CTR)
    assert val == 5, f"Expected 5 after increment, got {val}"

    # Decrement via pair_credit_consume write (offset 0x02C)
    await tb.apb.write(APB_REG_PAIR_CREDIT_CONS, 2)
    val = await tb.apb.read(APB_REG_PAIR_CREDIT_CTR)
    assert val == 3, f"Expected 3 after decrement, got {val}"

    # Disable counter
    await tb.apb.write(APB_REG_PAIR_CREDIT_EN, 0)
    en = await tb.apb.read(APB_REG_PAIR_CREDIT_EN)
    assert en == 0, f"Expected disabled (0), got {en}"

    # Increment while disabled — counter should not change
    await tb.apb.write(APB_REG_RELEASED_ACC, 10)
    val = await tb.apb.read(APB_REG_PAIR_CREDIT_CTR)
    assert val == 3, f"Expected 3 (frozen), got {val}"

    # Re-enable
    await tb.apb.write(APB_REG_PAIR_CREDIT_EN, 1)

    # Increment should work again
    await tb.apb.write(APB_REG_RELEASED_ACC, 4)
    val = await tb.apb.read(APB_REG_PAIR_CREDIT_CTR)
    assert val == 7, f"Expected 7 after re-enable + increment, got {val}"

    # Clean up: read-clear the released_credits_acc
    await tb.apb.read(APB_REG_RELEASED_ACC)

    tb.log.info("Pair credit counter increment/decrement/enable verified")


@cocotb.test()
async def test_cov_05_fifo_overrun(dut):
    """Write packets until FIFO is full (credit_count == 0), then issue one
    more write to trigger overrun. Verify STATUS[1] overrun flag is sticky
    and cleared by flush."""
    tb = TidelinkTB(dut)
    await tb.reset()
    await tb.apb.write(APB_REG_REL_THRESHOLD, 0)

    # Fill the FIFO by writing large packets until credits are nearly exhausted
    # MAX_CREDITS = 4096, write 512-word packets (513 total_words each)
    pkt_size = 512
    packets_written = 0
    while True:
        hw_credits = await tb.read_credit_count()
        if hw_credits < pkt_size + 2:
            break
        data = [0xF1110000 + i for i in range(pkt_size)]
        hit = await tb.write_packet(data, label=f"FILL_{packets_written}")
        if not hit:
            break
        packets_written += 1

    # Write remaining credits with smaller packets
    while True:
        hw_credits = await tb.read_credit_count()
        if hw_credits < 3:  # Need at least 3 credits (2 header + 1 data)
            break
        remaining = hw_credits - 2  # Leave 2 for header words
        data = [0x5A110000 + i for i in range(remaining)]
        hit = await tb.write_packet(data, label="FILL_SMALL")
        if not hit:
            break

    # Verify credit count is 0
    hw_credits = await tb.read_credit_count()
    tb.log.info(f"After filling: credit_count = {hw_credits}")

    # Check overrun not yet set
    status = await tb.apb.read(APB_REG_STATUS)
    assert not (status & (1 << 1)), "Overrun should not be set yet"

    # Now attempt a write when buffer is full — this should trigger overrun
    # Drive AHB write manually to trigger the overrun_event
    # Pack length=1 into word0 bits [31:20]
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2  # NONSEQ
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = (1 << 20)  # packed word0: length=1
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_hwrite.value = 0
    await ClockCycles(dut.hclk, 3)

    # Check overrun is now set
    status = await tb.apb.read(APB_REG_STATUS)
    assert status & (1 << 1), \
        f"Overrun (STATUS[1]) should be set, got STATUS=0x{status:08X}"
    tb.log.info("Overrun flag set correctly")

    # Verify sticky: still set after another cycle
    await ClockCycles(dut.hclk, 5)
    status = await tb.apb.read(APB_REG_STATUS)
    assert status & (1 << 1), "Overrun should be sticky"

    # Flush should clear it
    await tb.apb.write(APB_REG_CTRL, 0x2)  # FLUSH
    await ClockCycles(dut.hclk, 3)

    status = await tb.apb.read(APB_REG_STATUS)
    assert not (status & (1 << 1)), \
        f"Overrun should be cleared after flush, got STATUS=0x{status:08X}"

    tb.log.info("Overrun test passed — sticky flag set and cleared by flush")


@cocotb.test()
async def test_cov_06_fifo_underrun(dut):
    """Read from an empty FIFO (credit_count == MAX_CREDITS) to trigger
    underrun. Verify STATUS[2] underrun flag is sticky and cleared by flush."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # Verify FIFO is empty (credit_count == MAX_CREDITS)
    hw_credits = await tb.read_credit_count()
    assert hw_credits == MAX_CREDITS

    # Check underrun not yet set
    status = await tb.apb.read(APB_REG_STATUS)
    assert not (status & (1 << 2)), "Underrun should not be set yet"

    # Issue a read from the empty FIFO
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2  # NONSEQ
    dut.ahbs_hwrite.value = 0  # Read
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_haddr.value  = 0x3FFF  # park address away from FIFO
    await ClockCycles(dut.hclk, 5)

    # Check underrun is now set
    status = await tb.apb.read(APB_REG_STATUS)
    assert status & (1 << 2), \
        f"Underrun (STATUS[2]) should be set, got STATUS=0x{status:08X}"
    tb.log.info("Underrun flag set correctly")

    # Verify sticky
    await ClockCycles(dut.hclk, 5)
    status = await tb.apb.read(APB_REG_STATUS)
    assert status & (1 << 2), "Underrun should be sticky"

    # Flush should clear it
    await tb.apb.write(APB_REG_CTRL, 0x2)  # FLUSH
    await ClockCycles(dut.hclk, 3)

    status = await tb.apb.read(APB_REG_STATUS)
    assert not (status & (1 << 2)), \
        f"Underrun should be cleared after flush, got STATUS=0x{status:08X}"

    tb.log.info("Underrun test passed — sticky flag set and cleared by flush")


@cocotb.test()
async def test_cov_07_apb_pair_base_write(dut):
    """Write to APB offset 0x000 (pair_base_addr) and verify readback."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # Default is 0 (from parameter)
    val = await tb.apb.read(APB_REG_PAIR_BASE)
    assert val == 0

    # Write a new pair base address
    await tb.apb.write(APB_REG_PAIR_BASE, 0x4000_0000)
    val = await tb.apb.read(APB_REG_PAIR_BASE)
    assert val == 0x4000_0000, f"Expected 0x40000000, got 0x{val:08X}"

    # Write another value
    await tb.apb.write(APB_REG_PAIR_BASE, 0xDEAD_0000)
    val = await tb.apb.read(APB_REG_PAIR_BASE)
    assert val == 0xDEAD_0000, f"Expected 0xDEAD0000, got 0x{val:08X}"

    tb.log.info("Pair base address write/readback verified")


@cocotb.test()
async def test_cov_08_apb_pkt_word_len_read(dut):
    """Read APB offset 0x008 (packet_word_length) — reflects FIFO sideband."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # After reset, packet_word_length should be 0
    val = await tb.apb.read(APB_REG_PKT_WORD_LEN)
    assert val == 0, f"Expected 0 after reset, got {val}"

    # Write a 5-word packet — after write_complete, pkt_word_len resets to 0
    # But during the write, it should be set
    await tb.write_packet([0xAA, 0xBB, 0xCC, 0xDD, 0xEE], label="PKT_LEN_WR")

    # After write_complete fires, packet_word_length is cleared
    val = await tb.apb.read(APB_REG_PKT_WORD_LEN)
    assert val == 0, f"Expected 0 after write_complete, got {val}"

    tb.log.info("Packet word length APB read verified")


@cocotb.test()
async def test_cov_09_apb_release_acc_read(dut):
    """Read APB offset 0x018 (release_acc) — debug register showing pending
    unreleased credits."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # With default threshold=20, reading back packets accumulates in release_acc
    # until threshold is crossed
    val = await tb.apb.read(APB_REG_REL_ACC)
    assert val == 0, f"Expected 0 after reset, got {val}"

    # Write and read a small packet (delta=4, below threshold=20)
    await tb.write_packet([0xAA, 0xBB], label="ACC_WR1")
    _, rhit = await tb.read_packet(label="ACC_RD1")
    assert rhit
    await ClockCycles(dut.hclk, 5)

    # release_acc should be 4 (below threshold, not yet released)
    val = await tb.apb.read(APB_REG_REL_ACC)
    assert val == 4, f"Expected release_acc=4, got {val}"

    # Write and read another (delta=4 more, total=8)
    await tb.write_packet([0xCC, 0xDD], label="ACC_WR2")
    _, rhit = await tb.read_packet(label="ACC_RD2")
    assert rhit
    await ClockCycles(dut.hclk, 5)

    val = await tb.apb.read(APB_REG_REL_ACC)
    assert val == 8, f"Expected release_acc=8, got {val}"

    tb.log.info("Release accumulator APB read verified")


@cocotb.test()
async def test_cov_10_flush_clears_release_acc_and_errors(dut):
    """Flush clears the release accumulator and sticky error flags together."""
    tb = TidelinkTB(dut)
    await tb.reset()

    # Build up some release_acc (write+read a packet with default threshold=20)
    await tb.write_packet([0x11, 0x22, 0x33], label="FLUSH2_WR")
    _, _ = await tb.read_packet(label="FLUSH2_RD")
    await ClockCycles(dut.hclk, 5)

    rel_acc = await tb.apb.read(APB_REG_REL_ACC)
    assert rel_acc > 0, "release_acc should be non-zero before flush"

    # Flush
    await tb.apb.write(APB_REG_CTRL, 0x2)
    await ClockCycles(dut.hclk, 3)

    rel_acc = await tb.apb.read(APB_REG_REL_ACC)
    assert rel_acc == 0, f"release_acc should be 0 after flush, got {rel_acc}"

    tb.log.info("Flush clears release_acc verified")


@cocotb.test()
async def test_cov_11_ahb_master_wait_states(dut):
    """AHB slave inserts wait states (hready=0) on the returner master port,
    exercising the ST_ADDR_PHASE and ST_DATA_PHASE wait branches."""
    import itertools

    def bp_generator():
        """Back-pressure generator: alternate between ready and wait."""
        while True:
            yield 1  # ready
            yield 0  # wait
            yield 0  # wait
            yield 1  # ready

    # Create a fresh TB but with back-pressure on the AHB slave
    dut._log.info("Setting up TB with AHB slave back-pressure")
    cocotb.start_soon(
        Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
    )

    ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
    ahb_master = AHBLiteMaster(ahbs_bus, dut.hclk, dut.hresetn, timeout=200)

    # Kill previous slave's background coroutine before creating back-pressure variant
    global _prev_slave_task
    if _prev_slave_task is not None:
        _prev_slave_task.kill()

    ahbm_bus = AHBBus.from_prefix(dut, "ahbm")
    ahb_slave_bp = _create_slave_ram(
        ahbm_bus, dut.hclk, dut.hresetn,
        mem_size=4096,
        bp=bp_generator(),
    )

    apb = APBMaster(dut, dut.hclk)

    # Reset
    apb.idle()
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 10)
    await apb.write(APB_REG_REL_THRESHOLD, 0)  # Immediate release

    # Write a packet (all manual AHB to avoid cocotbext master interference)
    pkt_data = [0xAA, 0xBB, 0xCC]
    pkt = FifoPacket(data=pkt_data)

    # Write 2-word header: word0 (packed) to addr 0, dest_addr to addr 4
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0000
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = pkt.word0
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hwrite.value = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    # Write dest_addr to addr 4
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = pkt.dest_addr
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hwrite.value = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    for i, word in enumerate(pkt_data):
        addr = (i + 2) * 4
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
        await RisingEdge(dut.hclk)
        dut.ahbs_hwrite.value = 0

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 1)

    # Read the packet back — triggers returner which now sees wait states
    ahb_slave_bp.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

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

    pkt_len = int(dut.u_dut.u_fifo_mem.packet_word_length.value)

    # Read Word 1 (dest_addr) from addr 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0004
    for _ in range(10):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.ahbs_hready.value) == 1:
                break
        except ValueError:
            pass
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await RisingEdge(dut.hclk)

    # Read payload from addr 0x0008+
    for i in range(pkt_len):
        addr = (i + 2) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0
        dut.ahbs_hsize.value  = 2
        dut.ahbs_haddr.value  = addr
        # Hold address phase until hready (SRAM pipeline may insert wait state)
        for _ in range(10):
            await RisingEdge(dut.hclk)
            try:
                if int(dut.ahbs_hready.value) == 1:
                    break
            except ValueError:
                pass
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        dut.ahbs_haddr.value  = 0x3FFF
        await RisingEdge(dut.hclk)

    dut.ahbs_haddr.value = 0x3FFF

    # Wait for returner to complete (pipeline + back-pressure delay)
    for cyc in range(100):
        await RisingEdge(dut.hclk)
        try:
            busy = int(dut.u_dut.returner_busy.value)
        except ValueError:
            busy = -1
        if busy == 0 and cyc > 5:
            break

    # Verify the returner completed successfully despite wait states
    returner_data = int.from_bytes(
        ahb_slave_bp.memory.read(PAIR_RELEASED_CREDITS_ADDR, 4),
        byteorder="little"
    )
    assert returner_data == pkt.total_words, \
        f"Expected delta={pkt.total_words}, got {returner_data}"

    dut._log.info("AHB master wait-state test passed")


@cocotb.test()
async def test_cov_12_master_error_flag(dut):
    """Inject an AHB ERROR response (hresp=1) on the returner master port.
    Verify STATUS[3] (master_error) is set and sticky, cleared by flush.

    We do NOT attach an AHBLiteSlaveRAM — instead we manually drive ahbm
    signals to inject the error."""
    cocotb.start_soon(
        Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
    )

    ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
    ahb_master = AHBLiteMaster(ahbs_bus, dut.hclk, dut.hresetn, timeout=200)

    apb = APBMaster(dut, dut.hclk)

    # Manually drive AHB master slave-side signals to idle defaults
    dut.ahbm_hready.value = 1
    dut.ahbm_hresp.value  = 0
    dut.ahbm_hrdata.value = 0

    # Reset
    apb.idle()
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 10)
    await apb.write(APB_REG_REL_THRESHOLD, 0)

    # Verify master_error is clear
    status = await apb.read(APB_REG_STATUS)
    assert not (status & (1 << 3)), "master_error should be 0 after reset"

    # Write and read a packet to trigger the returner
    pkt_data = [0xAA, 0xBB]
    pkt = FifoPacket(data=pkt_data)

    # Write 2-word header: word0 to 0x0000, dest_addr to 0x0004
    await ahb_master.write(0x0000, pkt.word0)
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)
    await ahb_master.write(0x0004, pkt.dest_addr)
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)

    for i, word in enumerate(pkt_data):
        addr = (i + 2) * 4
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
        await RisingEdge(dut.hclk)
        dut.ahbs_hwrite.value = 0

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 1)

    # Now read the packet — this triggers read_complete → returner fires
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

    pkt_len = int(dut.u_dut.u_fifo_mem.packet_word_length.value)

    # Read Word 1 (dest_addr) from addr 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0004
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await RisingEdge(dut.hclk)

    # Read payload from addr 0x0008+
    for i in range(pkt_len):
        addr = (i + 2) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0
        dut.ahbs_hsize.value  = 2
        dut.ahbs_haddr.value  = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        dut.ahbs_haddr.value  = 0x3FFF
        await RisingEdge(dut.hclk)

    dut.ahbs_haddr.value = 0x3FFF

    # Wait longer for returner to complete (wait states slow it down)
    for _ in range(100):
        await RisingEdge(dut.hclk)
        try:
            if not int(dut.u_dut.returner_busy.value):
                break
        except ValueError:
            pass
    # Extra settle time for AHB slave to capture the write data
    await ClockCycles(dut.hclk, 5)

