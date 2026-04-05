"""Cocotb testbench for tidelink_fifo_ahb (AHB wrapper with AHB-to-APB bridge).

Exercises APB configuration registers over the AHB config slave port (ahbc_*)
using cocotbext-ahb AHBLiteMaster.  Replicates a subset of the py_pair tests
but with all register access going through the cmsdk_ahb_to_apb bridge.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster, AHBLiteSlaveRAM

from tidelink.packet import FifoPacket
from tidelink.regs import (
    MAX_CREDITS,
    REG_PAIR_BASE, REG_REL_THRESHOLD, REG_PKT_WORD_LEN,
    REG_CREDIT_COUNT, REG_STATUS, REG_DOORBELL,
    REG_RELEASED_ACC, REG_DOORBELL_RESP_ACC,
    REG_PAIR_CREDIT_COUNTER, REG_PAIR_CREDIT_CONSUME, REG_PAIR_CREDIT_ENABLE,
    PAIR_RELEASED_CREDITS_OFFSET, PAIR_DOORBELL_RESPONSE_OFFSET,
)

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10

# Default TIDELINK_PAIR_BASE = 0, so returner targets are the raw offsets
PAIR_RELEASED_CREDITS_ADDR   = PAIR_RELEASED_CREDITS_OFFSET
PAIR_DOORBELL_RESPONSE_ADDR = PAIR_DOORBELL_RESPONSE_OFFSET


# ── Testbench Environment ────────────────────────────────────────────────────

class TidelinkAhbTB:
    """Reusable testbench for tidelink_fifo_ahb.

    NOTE: cocotbext AHB drivers spawn persistent coroutines. Multiple
    TidelinkAhbTB instances across tests cause bus contention on the
    returner master bus (ahbm_*). Tests that exercise the returner
    write-back path may fail when run sequentially after other tests.
    """

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        # FIFO data path AHB master
        ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
        self.ahb_fifo = AHBLiteMaster(
            ahbs_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # Config register AHB master (goes through AHB-to-APB bridge)
        ahbc_bus = AHBBus.from_prefix(dut, "ahbc")
        self.ahb_cfg = AHBLiteMaster(
            ahbc_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # Returner AHB slave (captures returner writes)
        ahbm_bus = AHBBus.from_prefix(dut, "ahbm")
        self.ahb_slave = AHBLiteSlaveRAM(
            ahbm_bus, dut.hclk, dut.hresetn,
            mem_size=4096,
        )

        self.sw_credit_count = MAX_CREDITS

    async def reset(self):
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        # Wait for reset deassertion pulse (channel 2) to complete
        await ClockCycles(self.dut.hclk, 10)
        self.sw_credit_count = MAX_CREDITS

    # ── Config register access via AHB ──────────────────────────────────

    async def cfg_read(self, offset: int) -> int:
        """Read a config register via the AHB config slave port."""
        resp = await self.ahb_cfg.read(offset)
        # cocotbext-ahb read returns list of dicts with "data" as hex string
        return int(resp[0].get("data", "0x0"), 16)

    async def cfg_write(self, offset: int, data: int):
        """Write a config register via the AHB config slave port."""
        await self.ahb_cfg.write(offset, data)

    async def read_credit_count(self) -> int:
        return await self.cfg_read(REG_CREDIT_COUNT)

    # ── FIFO Packet Write (inline AHB phases) ──────────────────────────

    async def write_packet(self, data, label: str = "") -> bool:
        pkt = FifoPacket(data=data)
        prefix = f"[{label}] " if label else ""
        dut = self.dut

        await self.ahb_fifo.write(0x0000, pkt.length)
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
            try:
                hit = int(dut.u_dut.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.write_complete.value)
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

    # ── FIFO Packet Read (inline AHB phases) ───────────────────────────

    async def read_packet(self, label: str = ""):
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

        pkt_len = int(dut.u_dut.u_tidelink_fifo.u_fifo_mem.packet_word_length_out.value)
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
            try:
                hit = int(dut.u_dut.u_tidelink_fifo.u_fifo_mem.read_complete.value)
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
        pkt = FifoPacket(data=data)
        if hit_fired:
            self.sw_credit_count += pkt.total_words
            self.log.info(f"{prefix}Read complete ({pkt.length} words). sw_credits={self.sw_credit_count}")
        return pkt, hit_fired

    # ── Returner Helpers ────────────────────────────────────────────────

    async def wait_returner_idle(self, timeout_cycles: int = 20):
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            if not int(self.dut.u_dut.u_tidelink_fifo.returner_busy.value):
                return
        raise TimeoutError("Returner still busy after timeout")

    def read_returner_memory(self, addr: int, num_bytes: int = 4) -> int:
        raw = self.ahb_slave.memory.read(addr, num_bytes)
        return int.from_bytes(raw, byteorder="little")


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset_and_credit_count_via_ahb(dut):
    """After reset, reading credit count via AHB config port returns MAX_CREDITS."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    hw_credits = await tb.read_credit_count()
    tb.log.info(f"Credit count after reset (via AHB): {hw_credits} (expected {MAX_CREDITS})")
    assert hw_credits == MAX_CREDITS, \
        f"Expected {MAX_CREDITS}, got {hw_credits}"


@cocotb.test()
async def test_02_pair_base_readback_via_ahb(dut):
    """Reading pair base address register via AHB config port returns default 0."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    readback = await tb.cfg_read(REG_PAIR_BASE)
    assert readback == 0, \
        f"Pair base: expected 0x00000000, got 0x{readback:08X}"


@cocotb.test()
async def test_03_pair_base_write_readback_via_ahb(dut):
    """Write a new pair base address via AHB, then read it back."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    new_base = 0x5000_2000
    await tb.cfg_write(REG_PAIR_BASE, new_base)
    await ClockCycles(dut.hclk, 2)

    readback = await tb.cfg_read(REG_PAIR_BASE)
    assert readback == new_base, \
        f"Pair base: expected 0x{new_base:08X}, got 0x{readback:08X}"


@cocotb.test()
async def test_04_status_register_via_ahb(dut):
    """Status register bit[0] (returner_busy) should be 0 when idle."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    status = await tb.cfg_read(REG_STATUS)
    assert (status & 1) == 0, f"returner_busy should be 0, status=0x{status:08X}"


@cocotb.test()
async def test_05_accumulator_write_add_read_clear_via_ahb(dut):
    """Released credits accumulator: W-add / R-clear behaviour over AHB."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    # Write two values — they should accumulate
    await tb.cfg_write(REG_RELEASED_ACC, 10)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_RELEASED_ACC, 25)
    await ClockCycles(dut.hclk, 2)

    # Read should return accumulated value and clear it
    acc_val = await tb.cfg_read(REG_RELEASED_ACC)
    tb.log.info(f"Released credits accumulator: {acc_val} (expected 35)")
    assert acc_val == 35, f"Expected 35, got {acc_val}"

    # Second read should return 0 (cleared on previous read)
    acc_val2 = await tb.cfg_read(REG_RELEASED_ACC)
    assert acc_val2 == 0, f"Expected 0 after clear, got {acc_val2}"


@cocotb.test()
async def test_06_doorbell_response_accumulator_via_ahb(dut):
    """Doorbell response accumulator: same W-add / R-clear over AHB."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    await tb.cfg_write(REG_DOORBELL_RESP_ACC, 100)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_DOORBELL_RESP_ACC, 200)
    await ClockCycles(dut.hclk, 2)

    acc_val = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    assert acc_val == 300, f"Expected 300, got {acc_val}"

    acc_val2 = await tb.cfg_read(REG_DOORBELL_RESP_ACC)
    assert acc_val2 == 0, f"Expected 0 after clear, got {acc_val2}"


@cocotb.test()
async def test_07_irq_from_accumulator_via_ahb(dut):
    """Writing to released credits accumulator via AHB should assert the IRQ."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    # IRQ should be low initially
    assert dut.released_credits_irq.value == 0, "IRQ should be low after reset"

    # Write a non-zero value to the accumulator
    await tb.cfg_write(REG_RELEASED_ACC, 5)
    await ClockCycles(dut.hclk, 2)

    assert dut.released_credits_irq.value == 1, "IRQ should be high after write"

    # Read (clears accumulator) should deassert IRQ
    _ = await tb.cfg_read(REG_RELEASED_ACC)
    await ClockCycles(dut.hclk, 2)

    assert dut.released_credits_irq.value == 0, "IRQ should be low after read-clear"


@cocotb.test()
async def test_08_doorbell_triggers_returner_via_ahb(dut):
    """Writing doorbell register via AHB config port triggers the returner
    to write total credit count to PAIR_DOORBELL_RESPONSE_ADDR."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    # Clear slave RAM at target
    tb.ahb_slave.memory.write(PAIR_DOORBELL_RESPONSE_ADDR, b'\x00\x00\x00\x00')

    # Trigger doorbell via AHB config port
    await tb.cfg_write(REG_DOORBELL, 1)
    await ClockCycles(dut.hclk, 2)
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    # Returner should have written total credit count to pair's doorbell response addr
    written = tb.read_returner_memory(PAIR_DOORBELL_RESPONSE_ADDR)
    tb.log.info(f"Returner wrote {written} to doorbell response (expected {MAX_CREDITS})")
    assert written == MAX_CREDITS, \
        f"Expected {MAX_CREDITS}, got {written}"


@cocotb.test()
async def test_09_write_read_return_flow_via_ahb(dut):
    """Full flow: write packet, read it back, verify returner sends correct
    credit delta — all register access via AHB config port."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_REL_THRESHOLD, 0)  # Immediate release mode

    # Verify initial credits via AHB
    hw_credits = await tb.read_credit_count()
    assert hw_credits == MAX_CREDITS

    # Write a packet
    pkt_data = [0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]
    hit = await tb.write_packet(pkt_data, label="WR")
    assert hit, "write_complete should fire"

    # Verify credits decreased
    hw_credits = await tb.read_credit_count()
    expected = MAX_CREDITS - (len(pkt_data) + 1)
    assert hw_credits == expected, f"Expected {expected}, got {hw_credits}"

    # Clear returner target
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    # Read packet back — triggers returner
    read_pkt, rhit = await tb.read_packet(label="RD")
    assert rhit, "read_complete should fire"
    for i, (exp, got) in enumerate(zip(pkt_data, read_pkt.data)):
        assert exp == got, f"Word {i}: expected 0x{exp:08X}, got 0x{got:08X}"

    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    # Verify returner sent correct delta
    delta = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    expected_delta = len(pkt_data) + 1
    assert delta == expected_delta, f"Expected delta {expected_delta}, got {delta}"

    # Verify credits restored
    hw_credits = await tb.read_credit_count()
    assert hw_credits == MAX_CREDITS

    tb.log.info("Full write-read-return flow verified via AHB config port")


@cocotb.test()
async def test_10_separate_accumulators_via_ahb(dut):
    """Channel 0 (delta → 0x020) and channel 1 (doorbell → 0x024) write to
    separate addresses. Verify via AHB config port."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_REL_THRESHOLD, 0)  # Immediate release mode

    pkt_data = [0xAA, 0xBB, 0xCC]
    expected_delta = len(pkt_data) + 1

    await tb.write_packet(pkt_data, label="SEP_WR")

    # Clear both targets
    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')
    tb.ahb_slave.memory.write(PAIR_DOORBELL_RESPONSE_ADDR, b'\x00\x00\x00\x00')

    # Read packet → channel 0 fires
    _, _ = await tb.read_packet(label="SEP_RD")
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    delta_020 = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    total_024 = tb.read_returner_memory(PAIR_DOORBELL_RESPONSE_ADDR)
    assert delta_020 == expected_delta, f"0x020: expected {expected_delta}, got {delta_020}"
    assert total_024 == 0, f"0x024 should be untouched, got {total_024}"

    # Trigger doorbell → channel 1 fires
    await tb.cfg_write(REG_DOORBELL, 1)
    await ClockCycles(dut.hclk, 2)
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    delta_020_after = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    total_024_after = tb.read_returner_memory(PAIR_DOORBELL_RESPONSE_ADDR)
    hw_credits = await tb.read_credit_count()

    assert delta_020_after == expected_delta, \
        f"0x020 should be unchanged: expected {expected_delta}, got {delta_020_after}"
    assert total_024_after == hw_credits, \
        f"0x024 should have credit count {hw_credits}, got {total_024_after}"

    tb.log.info("Separate accumulators verified via AHB config port")


@cocotb.test()
async def test_11_pair_credit_counter_via_ahb(dut):
    """Pair credit counter increments on released-credit writes, decrements
    on consume writes, and can be disabled — all via AHB config port."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    # Counter starts at 0, enabled by default
    ctr = await tb.cfg_read(REG_PAIR_CREDIT_COUNTER)
    assert ctr == 0, f"Counter should be 0 after reset, got {ctr}"

    en = await tb.cfg_read(REG_PAIR_CREDIT_ENABLE)
    assert (en & 1) == 1, f"Counter should be enabled after reset, got {en}"

    # Increment via released credits accumulator write
    await tb.cfg_write(REG_RELEASED_ACC, 10)
    await ClockCycles(dut.hclk, 2)

    ctr = await tb.cfg_read(REG_PAIR_CREDIT_COUNTER)
    assert ctr == 10, f"Counter should be 10, got {ctr}"

    # Decrement via consume register
    await tb.cfg_write(REG_PAIR_CREDIT_CONSUME, 3)
    await ClockCycles(dut.hclk, 2)

    ctr = await tb.cfg_read(REG_PAIR_CREDIT_COUNTER)
    assert ctr == 7, f"Counter should be 7, got {ctr}"

    # Disable counter
    await tb.cfg_write(REG_PAIR_CREDIT_ENABLE, 0)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_RELEASED_ACC, 50)
    await ClockCycles(dut.hclk, 2)

    ctr = await tb.cfg_read(REG_PAIR_CREDIT_COUNTER)
    assert ctr == 7, f"Counter should be frozen at 7, got {ctr}"

    # Re-enable and verify it resumes
    await tb.cfg_write(REG_PAIR_CREDIT_ENABLE, 1)
    await ClockCycles(dut.hclk, 2)
    await tb.cfg_write(REG_RELEASED_ACC, 5)
    await ClockCycles(dut.hclk, 2)

    ctr = await tb.cfg_read(REG_PAIR_CREDIT_COUNTER)
    assert ctr == 12, f"Counter should be 12, got {ctr}"

    tb.log.info("Pair credit counter verified via AHB config port")


@cocotb.test()
async def test_12_threshold_readback_via_ahb(dut):
    """Release threshold register readable and writable via AHB config port."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    val = await tb.cfg_read(REG_REL_THRESHOLD)
    assert val == 20, f"Default should be 20, got {val}"

    await tb.cfg_write(REG_REL_THRESHOLD, 42)
    val = await tb.cfg_read(REG_REL_THRESHOLD)
    assert val == 42, f"Expected 42 after write, got {val}"


@cocotb.test()
async def test_13_threshold_batching_via_ahb(dut):
    """With threshold=10, small reads accumulate and release as a batch
    via the AHB config port."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()
    await tb.cfg_write(REG_REL_THRESHOLD, 10)

    # Write 4 small packets (2 data words each → delta=3 per read)
    packets = [[0xAA00 + i, 0xBB00 + i] for i in range(4)]
    for i, data in enumerate(packets):
        hit = await tb.write_packet(data, label=f"BATCH_WR{i}")
        assert hit

    tb.ahb_slave.memory.write(PAIR_RELEASED_CREDITS_ADDR, b'\x00\x00\x00\x00')

    # Read 3 packets: acc = 3*3 = 9 < 10
    for i in range(3):
        _, rhit = await tb.read_packet(label=f"BATCH_RD{i}")
        assert rhit
        await ClockCycles(dut.hclk, 5)

    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    assert returner_data == 0, \
        f"Returner should not fire yet (acc=9 < 10), got {returner_data}"

    # 4th read: acc = 9 + 3 = 12 >= 10 → batched release
    _, rhit = await tb.read_packet(label="BATCH_RD3")
    assert rhit
    await tb.wait_returner_idle()
    await ClockCycles(dut.hclk, 2)

    returner_data = tb.read_returner_memory(PAIR_RELEASED_CREDITS_ADDR)
    assert returner_data == 12, \
        f"Expected batched delta=12, got {returner_data}"

    tb.log.info("Threshold batching verified via AHB config port")


@cocotb.test()
async def test_14_packet_committed_irq_via_ahb(dut):
    """packet_committed_irq asserts on write_complete, clears on read addr 0,
    verified at the AHB wrapper level."""
    tb = TidelinkAhbTB(dut)
    await tb.reset()

    # Verify deasserted after reset
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should be 0 after reset"

    # Write a packet — IRQ should assert
    hit = await tb.write_packet([0xDEAD, 0xBEEF], label="IRQ_AHB_WR")
    assert hit
    await RisingEdge(dut.hclk)
    assert int(dut.packet_committed_irq.value) == 1, \
        "packet_committed_irq should be 1 after write_complete"

    # Read the packet — first read from addr 0 clears IRQ
    pkt, rhit = await tb.read_packet(label="IRQ_AHB_RD")
    assert int(dut.packet_committed_irq.value) == 0, \
        "packet_committed_irq should be 0 after read from FIFO addr 0"

    # Write another packet — verify re-assertion
    hit2 = await tb.write_packet([0xCAFE, 0xBABE], label="IRQ_AHB_WR2")
    assert hit2
    await RisingEdge(dut.hclk)
    assert int(dut.packet_committed_irq.value) == 1, \
        "packet_committed_irq should re-assert on second write"

    tb.log.info("packet_committed_irq verified via AHB wrapper")
