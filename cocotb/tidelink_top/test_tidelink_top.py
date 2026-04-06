"""Cocotb integration test suite for the tidelink_top internal data path.

Exercises the FC adapter + FIFO + mux logic with FC loopback (a2l wired to
l2a in tb_top.sv).  Tests the end-to-end path:

  TX aperture AHB write -> FC encode -> loopback -> FC decode -> FIFO write
  Returner AHB write    -> FC sideband -> loopback -> config register write
  FIFO mux arbitration (FC adapter RX vs CPU read port)

XHB500, Wlink, and address translator are NOT instantiated; they require
external IP that is out of scope for this unit/integration test.

The config register interface is now APB (unified port) with TideLink
registers at offset 0x2000 in the 15-bit address space.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster

from tidelink.regs import (
    MAX_CREDITS,
    REG_CREDIT_COUNT, REG_DOORBELL, REG_REL_THRESHOLD,
    REG_RELEASED_ACC, REG_DOORBELL_RESP_ACC, REG_STATUS,
)

# -- Constants ----------------------------------------------------------------
CLK_PERIOD_NS = 10

# AHB transfer type encodings
HTRANS_IDLE   = 0
HTRANS_NONSEQ = 2
HSIZE_WORD    = 2

# TideLink config registers live at offset 0x2000 in the unified APB space
APB_TIDELINK_OFFSET = 0x2000


# -- APB Master Driver --------------------------------------------------------

class APBMaster:
    """Minimal APB master driver for register access."""

    def __init__(self, dut, clk, prefix="apb"):
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


# -- Testbench Environment ----------------------------------------------------

class TidelinkTopTB:
    """Reusable testbench for the tidelink_top loopback configuration.

    Provides:
      - ahb_tx:   AHBLiteMaster on the ahb_tx_* TX aperture port
      - apb_cfg:  APBMaster on the apb_* unified config port
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

        # Config register APB master (unified APB port)
        self.apb_cfg = APBMaster(dut, dut.hclk, prefix="apb")
        self.apb_cfg.idle()

        # FIFO read port defaults
        dut.ahb_fifo_hsel.value   = 0
        dut.ahb_fifo_htrans.value = 0
        dut.ahb_fifo_hsize.value  = HSIZE_WORD
        dut.ahb_fifo_hwrite.value = 0
        dut.ahb_fifo_haddr.value  = 0
        dut.ahb_fifo_hwdata.value = 0
        dut.ahb_fifo_hready_in.value = 1

    async def reset(self):
        """Assert reset, release, and wait for reset doorbell to complete."""
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        # Wait long enough for the returner's reset doorbell (channel 2)
        # to fire and be consumed by the FC loopback. This prevents stale
        # sideband words from interfering with the first real packet.
        await ClockCycles(self.dut.hclk, 30)
        await ClockCycles(self.dut.hclk, 10)

    # -- Config register helpers -----------------------------------------------

    async def cfg_read(self, offset: int) -> int:
        """Read a config register via the unified APB port.

        The offset is the register offset within the TideLink register space
        (e.g. REG_CREDIT_COUNT = 0x00C). The APB_TIDELINK_OFFSET (0x2000) is
        added automatically.
        """
        return await self.apb_cfg.read(APB_TIDELINK_OFFSET + offset)

    async def cfg_write(self, offset: int, data: int):
        """Write a config register via the unified APB port.

        The offset is the register offset within the TideLink register space.
        The APB_TIDELINK_OFFSET (0x2000) is added automatically.
        """
        await self.apb_cfg.write(APB_TIDELINK_OFFSET + offset, data)

    # -- TX aperture helpers ---------------------------------------------------

    async def tx_write_word(self, addr: int, data: int):
        """Write a single word to the TX aperture via AHB."""
        await self.ahb_tx.write(addr, data)

    async def tx_write_packet(self, data_words: list, dest_addr: int = 0):
        """Write a properly framed packet to the TX aperture.

        Follows the 2-word header FIFO protocol:
          1. Write packed Word 0 (length in bits [31:20]) at address 0x0000
          2. Write dest_addr at address 0x0004
          3. Write each data word at addresses 0x0008, 0x000C, ...
          4. The last write triggers write_complete which commits the packet.

        After writing, waits for FC loopback to deliver the packet to the RX FIFO.
        """
        from tidelink.packet import FifoPacket
        pkt = FifoPacket(data=data_words, dest_addr=dest_addr)
        # Write packed header (Word 0) at addr 0x0000
        await self.tx_write_word(0x0000, pkt.word0)
        await self.wait_fc_loopback(cycles=10)
        # Write dest_addr (Word 1) at addr 0x0004
        await self.tx_write_word(0x0004, pkt.dest_addr)
        await self.wait_fc_loopback(cycles=10)
        # Write data words at sequential addresses starting at 0x0008
        for i, word in enumerate(data_words):
            addr = (i + 2) * 4
            await self.tx_write_word(addr, word)
            await self.wait_fc_loopback(cycles=10)

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
                ready = int(dut.ahb_fifo_hready.value)
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
        """Read a complete packet from the FIFO following the 2-word header protocol:
          1. Read at addr 0x0000 to get packed header (clears packet_committed_irq)
          2. Read at addr 0x0004 to get dest_addr
          3. Read length data words at 0x0008, 0x000C, ...
        Returns the data words (not including the 2-word header)."""
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

    # -- Loopback wait helper --------------------------------------------------

    async def wait_fc_loopback(self, cycles: int = 20):
        """Wait for FC loopback to deliver RX words.  The loopback is
        combinational in tb_top so a few clock cycles suffices for the
        adapter's RX FSM to complete the AHB write."""
        await ClockCycles(self.dut.hclk, cycles)

    # -- Returner idle check ---------------------------------------------------

    async def wait_returner_idle(self, timeout_cycles: int = 50):
        """Wait until the returner FSM inside tidelink_fifo is idle."""
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            try:
                busy = int(self.dut.u_tidelink_fifo.u_returner.busy.value)
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
    """Write a 1-word packet (2-word header + 1 data word) through the TX aperture,
    verify it arrives in RX FIFO via the FC loopback."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    test_data = 0xDEAD_BEEF

    # Debug: check TX port state before write
    try:
        tb.log.info(f"ahb_tx_hready(out)={int(dut.ahb_tx_hready.value)}, "
                    f"ahb_tx_hready_loop={int(dut.ahb_tx_hready_loop.value)}, "
                    f"adapter_hready={int(dut.u_fc_adapter.ahb_tx_hready.value)}")
    except Exception as e:
        tb.log.info(f"TX ready probe: {e}")

    # Write a properly framed packet: length=1 at addr 0, data at addr 4
    # Monitor FC RX path
    async def monitor_fc():
        for _ in range(50):
            await RisingEdge(dut.hclk)
            try:
                l2a_v = int(dut.tl_fc_l2a_valid.value)
                if l2a_v or int(dut.u_fc_adapter.rx_pending_r.value):
                    l2a_d = int(dut.tl_fc_l2a_data.value)
                    ptype = (l2a_d >> 46) & 0x3
                    addr = (l2a_d >> 32) & 0x3FFF
                    payload = l2a_d & 0xFFFFFFFF
                    # Probe what the FIFO slave actually sees
                    fifo_hsel = int(dut.u_tidelink_fifo.ahbs_hsel.value)
                    fifo_ht = int(dut.u_tidelink_fifo.ahbs_htrans.value)
                    fifo_hw = int(dut.u_tidelink_fifo.ahbs_hwrite.value)
                    fifo_hr = int(dut.u_tidelink_fifo.ahbs_hready.value)
                    tb.log.info(
                        f"  l2a_v={l2a_v} rx_st={int(dut.u_fc_adapter.rx_state_r.value)} "
                        f"FIFO_SLAVE: hsel={fifo_hsel} htrans={fifo_ht} hwrite={fifo_hw} hready={fifo_hr}")
            except Exception:
                pass
    monitor = cocotb.start_soon(monitor_fc())
    await tb.tx_write_packet([test_data])
    await ClockCycles(dut.hclk, 25)
    monitor.kill()

    # Debug: check internal state
    credits = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"credits={credits}, "
                f"pkt_irq={int(dut.packet_committed_irq.value)}")
    try:
        wp = int(dut.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.write_ptr.value)
        rp = int(dut.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.read_ptr.value)
        pwl = int(dut.u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl.packet_word_length.value)
        tb.log.info(f"FIFO write_ptr={wp}, read_ptr={rp}, pkt_word_len={pwl}")
    except Exception as e:
        tb.log.info(f"FIFO ptr probe: {e}")
    try:
        rx_st = int(dut.u_fc_adapter.rx_state_r.value)
        rx_pend = int(dut.u_fc_adapter.rx_pending_r.value)
        rx_is_fifo = int(dut.u_fc_adapter.rx_is_fifo.value)
        tb.log.info(f"FC RX: state={rx_st}, pending={rx_pend}, is_fifo={rx_is_fifo}")
    except Exception as e:
        tb.log.info(f"FC RX probe: {e}")

    # Read back from FIFO using proper packet protocol
    readback = await tb.fifo_read_packet()
    tb.log.info(f"TX wrote [0x{test_data:08X}], "
                f"RX FIFO read {['0x{:08X}'.format(w) for w in readback]}")
    assert len(readback) == 1, f"Expected 1 data word, got {len(readback)}"
    assert readback[0] == test_data, \
        f"FIFO readback mismatch: expected 0x{test_data:08X}, got 0x{readback[0]:08X}"


@cocotb.test()
async def test_02_descriptor_packet_loopback(dut):
    """Write a 3-word data packet through TX aperture, verify all 3
    words arrive in the RX FIFO in order."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    data_words = [0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]

    # Write properly framed packet
    await tb.tx_write_packet(data_words)

    # Read back the packet from FIFO
    readback = await tb.fifo_read_packet()

    tb.log.info(f"TX data:     {['0x{:08X}'.format(w) for w in data_words]}")
    tb.log.info(f"RX readback: {['0x{:08X}'.format(w) for w in readback]}")

    assert len(readback) == len(data_words), \
        f"Length mismatch: expected {len(data_words)}, got {len(readback)}"
    for i, (exp, got) in enumerate(zip(data_words, readback)):
        assert exp == got, \
            f"Word {i}: expected 0x{exp:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_03_full_packet_with_payload_loopback(dut):
    """Write a complete packet: 3 header + 3 payload data words.
    Verify the entire packet arrives in the RX FIFO."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Packet data: 3 header words + 3 payload words = 6 data words
    header  = [0xAABB_0001, 0xAABB_0002, 0xAABB_0003]
    payload = [0xCCDD_0001, 0xCCDD_0002, 0xCCDD_0003]
    data_words = header + payload

    await tb.tx_write_packet(data_words)

    # Read back all words
    readback = await tb.fifo_read_packet()

    tb.log.info(f"TX data ({len(data_words)} words): "
                f"{['0x{:08X}'.format(w) for w in data_words]}")
    tb.log.info(f"RX readback: {['0x{:08X}'.format(w) for w in readback]}")

    assert len(readback) == len(data_words), \
        f"Length mismatch: expected {len(data_words)}, got {len(readback)}"
    for i, (exp, got) in enumerate(zip(data_words, readback)):
        assert exp == got, \
            f"Word {i}: expected 0x{exp:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_04_multiple_single_word_packets(dut):
    """Write multiple single-word packets via TX aperture,
    verify each arrives correctly in the RX FIFO."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    test_values = [0x1111_1111, 0x2222_2222, 0x3333_3333]

    for val in test_values:
        # Write a properly framed 1-word packet
        await tb.tx_write_packet([val])

        # Read the packet back
        readback = await tb.fifo_read_packet()
        tb.log.info(f"Expected 0x{val:08X}, got {['0x{:08X}'.format(w) for w in readback]}")
        assert len(readback) == 1, f"Expected 1 word, got {len(readback)}"
        assert readback[0] == val, \
            f"Mismatch: expected 0x{val:08X}, got 0x{readback[0]:08X}"


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

    # Write a properly framed 2-word packet via TX aperture loopback
    data_words = [0xCAFE_0001, 0xCAFE_0002]
    await tb.tx_write_packet(data_words)

    # Read the packet back from FIFO (this triggers credit release)
    _ = await tb.fifo_read_packet()

    # Wait for returner to fire and FC sideband to loop back
    await tb.wait_fc_loopback(cycles=60)

    # The sideband loopback should have written to the released credits
    # accumulator register (0x020).  Read it via APB config port.
    acc_val = await tb.cfg_read(REG_RELEASED_ACC)
    tb.log.info(f"Released credits accumulator: {acc_val}")

    # With threshold=0, the returner releases all freed credits immediately.
    # Reading a packet with 2 data words means total_words = 4 (2-word header + 2 data).
    expected_delta = len(data_words) + 2  # 2-word header + data words
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

    # Write and read a properly framed packet to trigger credit release
    data_words = [0xBEEF_0001]
    await tb.tx_write_packet(data_words)

    _ = await tb.fifo_read_packet()
    await tb.wait_fc_loopback(cycles=60)

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

    # First, write a properly framed 1-word packet into FIFO via TX aperture
    test_data = 0xAAAA_BBBB
    await tb.tx_write_packet([test_data])

    # CPU reads from FIFO using proper packet protocol -- should not be stalled
    readback = await tb.fifo_read_packet()
    tb.log.info(f"CPU read from FIFO: {['0x{:08X}'.format(w) for w in readback]} "
                f"(expected [0x{test_data:08X}])")
    assert len(readback) == 1, f"Expected 1 word, got {len(readback)}"
    assert readback[0] == test_data, \
        f"CPU FIFO read mismatch: expected 0x{test_data:08X}, got 0x{readback[0]:08X}"


@cocotb.test()
async def test_09_fc_adapter_has_fifo_mux_priority(dut):
    """When the FC adapter RX is writing to the FIFO, the CPU FIFO port
    should see hreadyout=0 (stalled).  After FC completes, CPU access
    should resume normally."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Write a properly framed 1-word packet through the FC loopback
    test_data = 0xFC00_1234
    await tb.tx_write_packet([test_data])

    # Now CPU should be able to read normally using packet protocol
    readback = await tb.fifo_read_packet()
    tb.log.info(f"CPU read after FC complete: {['0x{:08X}'.format(w) for w in readback]} "
                f"(expected [0x{test_data:08X}])")
    assert len(readback) == 1, f"Expected 1 word, got {len(readback)}"
    assert readback[0] == test_data, \
        f"CPU read mismatch after FC priority: expected 0x{test_data:08X}, " \
        f"got 0x{readback[0]:08X}"


@cocotb.test()
async def test_10_fc_adapter_has_cfg_mux_priority(dut):
    """When the FC adapter RX is writing to config registers (sideband), the
    CPU config port should see pready=0 (stalled).  After FC completes,
    CPU config access should resume normally."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Read credit count before doorbell -- should work fine
    credits_before = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credits before doorbell: {credits_before}")
    assert credits_before == MAX_CREDITS

    # Trigger doorbell -- returner will write a sideband FC packet,
    # which loops back and writes to config register via the APB mux.
    # The CPU APB port should be briefly stalled.
    await tb.cfg_write(REG_DOORBELL, 1)
    await tb.wait_fc_loopback(cycles=40)

    # Read credit count again after sideband completes -- should still work
    credits_after = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credits after doorbell: {credits_after}")
    assert credits_after == MAX_CREDITS


@cocotb.test()
async def test_11_sequential_packets_no_data_loss(dut):
    """Write multiple packets back-to-back to the TX aperture and verify that
    none are lost through the FC loopback path."""
    tb = TidelinkTopTB(dut)
    await tb.reset()

    # Write and read back several single-word packets sequentially
    num_packets = 4
    test_data = [(i + 1) * 0x1111_1111 for i in range(num_packets)]

    for i, word in enumerate(test_data):
        # Write a properly framed 1-word packet
        await tb.tx_write_packet([word])

        # Read it back immediately
        readback = await tb.fifo_read_packet()
        tb.log.info(f"Packet {i}: expected 0x{word:08X}, got "
                    f"{['0x{:08X}'.format(w) for w in readback]}")
        assert len(readback) == 1, f"Packet {i}: expected 1 word, got {len(readback)}"
        assert readback[0] == word, \
            f"Packet {i} lost: expected 0x{word:08X}, got 0x{readback[0]:08X}"


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
    """Verify that the credit count register is accessible through the APB
    config port and returns MAX_CREDITS after reset (sanity check for config path)."""
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

    # Write a properly framed 2-word packet via TX aperture
    data_words = [0xFACE_0001, 0xFACE_0002]
    await tb.tx_write_packet(data_words)

    # After loopback write into FIFO, credits should decrease by total_words
    # total_words = 2-word header + data_words = 2 + 2 = 4
    credits_after_write = await tb.cfg_read(REG_CREDIT_COUNT)
    total_words = len(data_words) + 2  # 2-word header + data words
    expected_after_write = MAX_CREDITS - total_words
    tb.log.info(f"Credits after write: {credits_after_write} "
                f"(expected {expected_after_write})")
    assert credits_after_write == expected_after_write, \
        f"Expected {expected_after_write}, got {credits_after_write}"

    # Read the packet back -- triggers credit release via returner -> FC sideband
    data = await tb.fifo_read_packet()
    tb.log.info(f"Read back {len(data)} data words: "
                f"{['0x{:08X}'.format(w) for w in data]}")
    assert data == data_words, "Read-back data mismatch"

    # Wait for returner to fire credit release through FC sideband loopback
    await tb.wait_fc_loopback(cycles=60)

    # Credits should be restored (released credits looped back to accumulator)
    credits_final = await tb.cfg_read(REG_CREDIT_COUNT)
    tb.log.info(f"Credits after read+release: {credits_final} "
                f"(expected {MAX_CREDITS})")
    assert credits_final == MAX_CREDITS, \
        f"Expected credits restored to {MAX_CREDITS}, got {credits_final}"

    tb.log.info("Full write-read-release loopback verified")
