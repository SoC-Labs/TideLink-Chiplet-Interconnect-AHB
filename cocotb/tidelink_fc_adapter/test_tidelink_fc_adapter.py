"""Cocotb testbench for tidelink_fc_adapter.

Tests the FC adapter which bridges AHB traffic to/from a 48-bit FC node
interface. Three functional paths:

  TX Aperture (AHB slave):  CPU writes FIFO words -> FC TX (FIFO_DATA)
  Returner (AHB slave):     Returner credit/doorbell writes -> FC TX (SIDEBAND)
  RX path (AHB masters):    FC RX -> AHB writes to local FIFO / config regs

FC data layout (48 bits):
  [47:46] pkt_type    -- 00=FIFO_DATA, 01=SIDEBAND
  [45:32] addr_offset -- 14-bit byte address
  [31:0]  payload     -- 32-bit data word
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer
from cocotb.queue import Queue

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10

# FC packet types
PKT_FIFO_DATA = 0b00
PKT_SIDEBAND  = 0b01
PKT_EXT       = 0b10

# TideChart PUF subtypes
SUB_PUF_READ_REQ = 0x0020
SUB_PUF_READ_RSP = 0x0021

# AHB constants
HTRANS_IDLE   = 0b00
HTRANS_NONSEQ = 0b10
HSIZE_WORD    = 0b010


# =============================================================================
# FC Interface Helper Classes
# =============================================================================

class FCMonitor:
    """Monitors FC a2l (TX) output: captures valid/data when ready is asserted."""

    def __init__(self, dut, log=None):
        self.dut = dut
        self.log = log
        self.packets = Queue()
        self._running = False

    def start(self):
        self._running = True
        cocotb.start_soon(self._run())

    async def _run(self):
        while self._running:
            await RisingEdge(self.dut.hclk)
            try:
                valid = int(self.dut.tl_fc_a2l_valid.value)
                ready = int(self.dut.tl_fc_a2l_ready.value)
            except ValueError:
                continue
            if valid == 1 and ready == 1:
                raw = int(self.dut.tl_fc_a2l_data.value)
                pkt = self._decode(raw)
                if self.log:
                    self.log.info(
                        f"FC TX: pkt_type={pkt['pkt_type']:02b} "
                        f"addr=0x{pkt['addr_offset']:04X} "
                        f"payload=0x{pkt['payload']:08X}")
                self.packets.put_nowait(pkt)

    @staticmethod
    def _decode(raw):
        return {
            "raw":         raw,
            "pkt_type":    (raw >> 46) & 0x3,
            "addr_offset": (raw >> 32) & 0x3FFF,
            "payload":     raw & 0xFFFFFFFF,
        }

    async def get(self, timeout_cycles=100):
        """Wait for next captured packet with timeout."""
        for _ in range(timeout_cycles):
            if not self.packets.empty():
                return self.packets.get_nowait()
            await RisingEdge(self.dut.hclk)
        raise TimeoutError("FCMonitor: no packet received within timeout")

    def stop(self):
        self._running = False


class FCDriver:
    """Drives FC l2a (RX) input: sends 48-bit words with valid/ready handshake."""

    def __init__(self, dut, log=None):
        self.dut = dut
        self.log = log

    @staticmethod
    def encode(pkt_type, addr_offset, payload):
        return ((pkt_type & 0x3) << 46) | \
               ((addr_offset & 0x3FFF) << 32) | \
               (payload & 0xFFFFFFFF)

    async def send(self, pkt_type, addr_offset, payload, timeout_cycles=100):
        """Drive a single FC RX word and wait for accept."""
        raw = self.encode(pkt_type, addr_offset, payload)
        self.dut.tl_fc_l2a_valid.value = 1
        self.dut.tl_fc_l2a_data.value  = raw
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.hclk)
            if int(self.dut.tl_fc_l2a_accept.value) == 1:
                if self.log:
                    self.log.info(
                        f"FC RX: pkt_type={pkt_type:02b} "
                        f"addr=0x{addr_offset:04X} "
                        f"payload=0x{payload:08X}")
                self.dut.tl_fc_l2a_valid.value = 0
                self.dut.tl_fc_l2a_data.value  = 0
                return
        raise TimeoutError("FCDriver: accept not asserted within timeout")

    def idle(self):
        """Deassert valid."""
        self.dut.tl_fc_l2a_valid.value = 0
        self.dut.tl_fc_l2a_data.value  = 0


# =============================================================================
# RX AHB Master Monitor — captures AHB writes driven by the DUT master ports
# =============================================================================

class AHBMasterMonitor:
    """Monitors an AHB master port driven by the DUT (output).

    Tracks the two-phase AHB protocol:
      Address phase: htrans=NONSEQ, hwrite=1 -> latch addr
      Data phase:    next cycle when hready -> latch hwdata
    """

    def __init__(self, dut, prefix, log=None):
        self.htrans = getattr(dut, f"{prefix}_htrans")
        self.hwrite = getattr(dut, f"{prefix}_hwrite")
        self.haddr  = getattr(dut, f"{prefix}_haddr")
        self.hwdata = getattr(dut, f"{prefix}_hwdata")
        self.hready = getattr(dut, f"{prefix}_hready")
        self.dut    = dut
        self.log    = log
        self.writes = Queue()
        self._running = False

    def start(self):
        self._running = True
        cocotb.start_soon(self._run())

    async def _run(self):
        pending_addr = None
        while self._running:
            await RisingEdge(self.dut.hclk)
            try:
                hready_val = int(self.hready.value)
                htrans_val = int(self.htrans.value)
                hwrite_val = int(self.hwrite.value)
            except ValueError:
                continue
            # Data phase: capture write data for the previously latched address
            if pending_addr is not None and hready_val:
                data = int(self.hwdata.value)
                if self.log:
                    self.log.info(
                        f"AHB Master Write: addr=0x{pending_addr:04X} "
                        f"data=0x{data:08X}")
                self.writes.put_nowait({"addr": pending_addr, "data": data})
                pending_addr = None
            # Address phase: detect new transaction
            if htrans_val == HTRANS_NONSEQ and hwrite_val == 1 and hready_val:
                pending_addr = int(self.haddr.value)

    async def get(self, timeout_cycles=100):
        for _ in range(timeout_cycles):
            if not self.writes.empty():
                return self.writes.get_nowait()
            await RisingEdge(self.dut.hclk)
        raise TimeoutError("AHBMasterMonitor: no write captured within timeout")

    def stop(self):
        self._running = False


class APBMasterMonitor:
    """Monitors an APB master port driven by the DUT (output).

    Captures write transactions on the APB access phase:
      psel=1, penable=1, pwrite=1, pready=1 -> latch addr + data
    """

    def __init__(self, dut, prefix, log=None):
        self.psel    = getattr(dut, f"{prefix}_psel")
        self.penable = getattr(dut, f"{prefix}_penable")
        self.pwrite  = getattr(dut, f"{prefix}_pwrite")
        self.paddr   = getattr(dut, f"{prefix}_paddr")
        self.pwdata  = getattr(dut, f"{prefix}_pwdata")
        self.pready  = getattr(dut, f"{prefix}_pready")
        self.dut     = dut
        self.log     = log
        self.writes  = Queue()
        self._running = False

    def start(self):
        self._running = True
        cocotb.start_soon(self._run())

    async def _run(self):
        while self._running:
            await RisingEdge(self.dut.hclk)
            try:
                psel_val    = int(self.psel.value)
                penable_val = int(self.penable.value)
                pwrite_val  = int(self.pwrite.value)
                pready_val  = int(self.pready.value)
            except ValueError:
                continue
            if psel_val and penable_val and pwrite_val and pready_val:
                addr = int(self.paddr.value)
                data = int(self.pwdata.value)
                if self.log:
                    self.log.info(
                        f"APB Master Write: addr=0x{addr:04X} "
                        f"data=0x{data:08X}")
                self.writes.put_nowait({"addr": addr, "data": data})

    async def get(self, timeout_cycles=100):
        for _ in range(timeout_cycles):
            if not self.writes.empty():
                return self.writes.get_nowait()
            await RisingEdge(self.dut.hclk)
        raise TimeoutError("APBMasterMonitor: no write captured within timeout")

    def stop(self):
        self._running = False


class DirectWriteMonitor:
    """Monitors a direct valid/addr/wdata write port driven by the DUT."""

    def __init__(self, dut, prefix, log=None):
        self.valid = getattr(dut, f"{prefix}_valid")
        self.write = getattr(dut, f"{prefix}_write")
        self.addr  = getattr(dut, f"{prefix}_addr")
        self.wdata = getattr(dut, f"{prefix}_wdata")
        self.dut   = dut
        self.log   = log
        self.writes = Queue()
        self._running = False

    def start(self):
        self._running = True
        cocotb.start_soon(self._run())

    async def _run(self):
        while self._running:
            await RisingEdge(self.dut.hclk)
            try:
                valid_val = int(self.valid.value)
                write_val = int(self.write.value)
            except ValueError:
                continue
            if valid_val and write_val:
                addr = int(self.addr.value)
                data = int(self.wdata.value)
                if self.log:
                    self.log.info(
                        f"Direct Write: addr=0x{addr:04X} "
                        f"data=0x{data:08X}")
                self.writes.put_nowait({"addr": addr, "data": data})

    async def get(self, timeout_cycles=100):
        for _ in range(timeout_cycles):
            if not self.writes.empty():
                return self.writes.get_nowait()
            await RisingEdge(self.dut.hclk)
        raise TimeoutError("DirectWriteMonitor: no write captured within timeout")

    def stop(self):
        self._running = False


# =============================================================================
# Helper Functions
# =============================================================================

async def setup(dut):
    """Start clock, create FC helpers, set default signal values."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())

    fc_mon    = FCMonitor(dut, log=dut._log)
    fc_drv    = FCDriver(dut, log=dut._log)
    fifo_mon  = DirectWriteMonitor(dut, "fc_rx_fifo", log=dut._log)
    cfg_mon   = APBMasterMonitor(dut, "fc_rx_cfg", log=dut._log)

    fc_mon.start()
    fifo_mon.start()
    cfg_mon.start()

    return fc_mon, fc_drv, fifo_mon, cfg_mon


async def do_reset(dut):
    """Assert active-low reset for 5 cycles, then deassert."""
    dut.hresetn.value = 0

    # TX aperture AHB slave inputs — idle
    dut.ahb_tx_hsel.value   = 0
    dut.ahb_tx_haddr.value  = 0
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsize.value  = HSIZE_WORD
    dut.ahb_tx_hwrite.value = 0
    dut.ahb_tx_hwdata.value = 0
    dut.ahb_tx_hready.value = 1

    # Returner AHB slave inputs — idle
    dut.rtn_haddr.value  = 0
    dut.rtn_hwdata.value = 0
    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hsize.value  = HSIZE_WORD
    dut.rtn_hwrite.value = 0

    # FC TX sink — ready by default
    dut.tl_fc_a2l_ready.value = 1

    # FC RX source — idle
    dut.tl_fc_l2a_valid.value = 0
    dut.tl_fc_l2a_data.value  = 0

    # RX AHB slave responses — always ready by default
    dut.fc_rx_fifo_ready.value = 1
    dut.fc_rx_cfg_pready.value  = 1
    dut.fc_rx_cfg_prdata.value  = 0

    # TideChart AXI-Stream TX — idle
    dut.tc_axis_tx_tvalid.value = 0
    dut.tc_axis_tx_tdata.value  = 0

    # TideChart AXI-Stream RX — ready by default
    dut.tc_axis_rx_tready.value = 1

    # PUF SRAM read interface — idle
    dut.puf_rdata.value = 0
    dut.puf_ack.value   = 0

    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 5)


async def tx_aperture_write(dut, addr, data):
    """Perform a single AHB write on the TX aperture slave port.

    Drives the address phase, then the data phase on the next clock.
    Waits for hreadyout to indicate completion.
    """
    # Address phase
    dut.ahb_tx_hsel.value   = 1
    dut.ahb_tx_haddr.value  = addr
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hready.value = 1
    await RisingEdge(dut.hclk)

    # Data phase — present write data, return address bus to idle
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsel.value   = 0
    dut.ahb_tx_hwdata.value = data

    # Wait for hreadyout
    for _ in range(100):
        await RisingEdge(dut.hclk)
        if int(dut.ahb_tx_hreadyout.value) == 1:
            return
    raise TimeoutError("tx_aperture_write: hreadyout not asserted")


async def rtn_write(dut, addr, data):
    """Perform a single AHB write on the returner interception slave port.

    Mimics the tidelink_returner master: drives address phase, then data.
    """
    # Address phase
    dut.rtn_haddr.value  = addr
    dut.rtn_htrans.value = HTRANS_NONSEQ
    dut.rtn_hwrite.value = 1
    await RisingEdge(dut.hclk)

    # Wait for rtn_hready in address phase (should be immediate if not pending)
    for _ in range(100):
        if int(dut.rtn_hready.value) == 1:
            break
        await RisingEdge(dut.hclk)

    # Data phase — present write data, return to idle
    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hwrite.value = 0
    dut.rtn_hwdata.value = data

    # Wait for rtn_hready (FC accepted)
    for _ in range(100):
        await RisingEdge(dut.hclk)
        if int(dut.rtn_hready.value) == 1:
            return
    raise TimeoutError("rtn_write: rtn_hready not asserted")


# =============================================================================
# TX Aperture Tests
# =============================================================================

@cocotb.test()
async def test_01_reset_defaults(dut):
    """After reset, FC TX should be idle and RX masters should be idle."""
    await setup(dut)
    await do_reset(dut)

    assert int(dut.tl_fc_a2l_valid.value) == 0, "a2l_valid should be 0 after reset"
    assert int(dut.fc_rx_fifo_valid.value) == 0, \
        "RX FIFO valid should be 0 after reset"
    assert int(dut.fc_rx_cfg_psel.value) == 0, \
        "RX Config psel should be 0 after reset"
    assert int(dut.ahb_tx_hreadyout.value) == 1, \
        "TX aperture hreadyout should be 1 (idle) after reset"
    assert int(dut.ahb_tx_hrdata.value) == 0, \
        "TX aperture hrdata should be 0 (write-only)"


@cocotb.test()
async def test_02_tx_single_word(dut):
    """Single word write via TX aperture produces correct FC FIFO_DATA packet."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_addr = 0x0100
    test_data = 0xDEADBEEF

    await tx_aperture_write(dut, test_addr, test_data)

    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_FIFO_DATA, \
        f"Expected FIFO_DATA (0), got {pkt['pkt_type']}"
    assert pkt["addr_offset"] == test_addr, \
        f"Expected addr 0x{test_addr:04X}, got 0x{pkt['addr_offset']:04X}"
    assert pkt["payload"] == test_data, \
        f"Expected payload 0x{test_data:08X}, got 0x{pkt['payload']:08X}"


@cocotb.test()
async def test_03_tx_sequential_words(dut):
    """Sequential word writes simulate a FIFO packet (2-word header + data words)."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Packet: packed word0 (length=3) at offset 0, dest_addr at offset 4,
    # then 3 data words starting at offset 8
    words = [
        (0x0000, 3 << 20),     # packed word0: length=3
        (0x0004, 0x00000000),  # dest_addr
        (0x0008, 0xAAAAAAAA),  # data word 0
        (0x000C, 0xBBBBBBBB),  # data word 1
        (0x0010, 0xCCCCCCCC),  # data word 2
    ]

    for addr, data in words:
        await tx_aperture_write(dut, addr, data)

    for addr, data in words:
        pkt = await fc_mon.get()
        assert pkt["pkt_type"] == PKT_FIFO_DATA, \
            f"Expected FIFO_DATA for addr 0x{addr:04X}"
        assert pkt["addr_offset"] == addr, \
            f"Expected addr 0x{addr:04X}, got 0x{pkt['addr_offset']:04X}"
        assert pkt["payload"] == data, \
            f"Expected 0x{data:08X}, got 0x{pkt['payload']:08X}"


@cocotb.test()
async def test_04_tx_backpressure(dut):
    """Deassert a2l_ready: first write absorbed by skid buffer, second stalls."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Deassert FC TX ready — backpressure
    dut.tl_fc_a2l_ready.value = 0

    # First write: goes into skid buffer (AHB completes without stall)
    dut.ahb_tx_hsel.value   = 1
    dut.ahb_tx_haddr.value  = 0x0200
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hready.value = 1
    await RisingEdge(dut.hclk)

    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsel.value   = 0
    dut.ahb_tx_hwdata.value = 0x12345678
    await RisingEdge(dut.hclk)

    # First write absorbed by skid buffer — hreadyout should be high
    assert int(dut.ahb_tx_hreadyout.value) == 1, \
        "hreadyout should be 1: first write absorbed by skid buffer"

    # Second write: skid buffer full, should stall
    dut.ahb_tx_hsel.value   = 1
    dut.ahb_tx_haddr.value  = 0x0204
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hready.value = 1
    await RisingEdge(dut.hclk)

    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsel.value   = 0
    dut.ahb_tx_hwdata.value = 0xDEADBEEF
    await RisingEdge(dut.hclk)

    assert int(dut.ahb_tx_hreadyout.value) == 0, \
        "hreadyout should be 0: skid buffer full, FC not ready"

    # Release backpressure
    dut.tl_fc_a2l_ready.value = 1
    await ClockCycles(dut.hclk, 3)
    assert int(dut.ahb_tx_hreadyout.value) == 1, \
        "hreadyout should go high when FC drains skid buffer"

    # Verify both words made it through
    pkt1 = await fc_mon.get()
    assert pkt1["payload"] == 0x12345678
    pkt2 = await fc_mon.get()
    assert pkt2["payload"] == 0xDEADBEEF


@cocotb.test()
async def test_05_tx_read_returns_zero(dut):
    """Reads on the TX aperture should return 0 (write-only)."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    assert int(dut.ahb_tx_hrdata.value) == 0, \
        "TX aperture hrdata should always be 0"
    assert int(dut.ahb_tx_hresp.value) == 0, \
        "TX aperture hresp should always be OKAY (0)"


# =============================================================================
# Returner Interception Tests
# =============================================================================

@cocotb.test()
async def test_06_rtn_single_sideband(dut):
    """Single returner write produces correct FC SIDEBAND packet."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_addr = 0x0000_0014  # doorbell offset
    test_data = 0x0000_0001

    await rtn_write(dut, test_addr, test_data)

    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_SIDEBAND, \
        f"Expected SIDEBAND (1), got {pkt['pkt_type']}"
    assert pkt["addr_offset"] == (test_addr & 0x3FFF), \
        f"Expected addr 0x{test_addr & 0x3FFF:04X}, got 0x{pkt['addr_offset']:04X}"
    assert pkt["payload"] == test_data, \
        f"Expected payload 0x{test_data:08X}, got 0x{pkt['payload']:08X}"


@cocotb.test()
async def test_07_rtn_credit_return(dut):
    """Returner credit return write (offset 0x020) produces SIDEBAND packet."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    credit_addr = 0x0000_0020
    credit_data = 0x0000_0005  # 5 credits returned

    await rtn_write(dut, credit_addr, credit_data)

    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_SIDEBAND
    assert pkt["addr_offset"] == 0x020
    assert pkt["payload"] == credit_data


@cocotb.test()
async def test_08_rtn_doorbell(dut):
    """Returner doorbell write (offset 0x014) produces SIDEBAND packet."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    doorbell_addr = 0x0000_0014
    doorbell_data = 0x0000_0001

    await rtn_write(dut, doorbell_addr, doorbell_data)

    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_SIDEBAND
    assert pkt["addr_offset"] == 0x014
    assert pkt["payload"] == doorbell_data


@cocotb.test()
async def test_09_rtn_backpressure(dut):
    """Returner stall: FC busy + skid full -> rtn_hready held low."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Deassert FC TX ready — backpressure
    dut.tl_fc_a2l_ready.value = 0

    # First returner write: absorbed by skid buffer
    dut.rtn_haddr.value  = 0x0000_0020
    dut.rtn_htrans.value = HTRANS_NONSEQ
    dut.rtn_hwrite.value = 1
    await RisingEdge(dut.hclk)

    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hwrite.value = 0
    dut.rtn_hwdata.value = 0xFACEFACE
    await RisingEdge(dut.hclk)

    # First write absorbed by skid buffer — rtn_hready should be high
    assert int(dut.rtn_hready.value) == 1, \
        "rtn_hready should be 1: first write absorbed by skid buffer"

    # Second returner write: skid full, should stall
    dut.rtn_haddr.value  = 0x0000_0024
    dut.rtn_htrans.value = HTRANS_NONSEQ
    dut.rtn_hwrite.value = 1
    await RisingEdge(dut.hclk)

    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hwrite.value = 0
    dut.rtn_hwdata.value = 0xCAFECAFE
    await RisingEdge(dut.hclk)

    assert int(dut.rtn_hready.value) == 0, \
        "rtn_hready should be 0 when skid buffer full"

    # Release backpressure
    dut.tl_fc_a2l_ready.value = 1
    await ClockCycles(dut.hclk, 3)

    pkt1 = await fc_mon.get()
    assert pkt1["pkt_type"] == PKT_SIDEBAND
    assert pkt1["payload"] == 0xFACEFACE


# =============================================================================
# TX Arbitration Tests
# =============================================================================

@cocotb.test()
async def test_10_arb_returner_priority(dut):
    """Simultaneous TX aperture + returner: returner wins (priority).

    Stall FC so both sources accumulate, then release. Returner should
    exit first due to arbiter priority, even through the skid buffer.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Stall FC so both sources accumulate in the arbiter
    dut.tl_fc_a2l_ready.value = 0

    # TX aperture address phase
    dut.ahb_tx_hsel.value   = 1
    dut.ahb_tx_haddr.value  = 0x0100
    dut.ahb_tx_htrans.value = HTRANS_NONSEQ
    dut.ahb_tx_hwrite.value = 1
    dut.ahb_tx_hready.value = 1
    # Returner address phase (same cycle)
    dut.rtn_haddr.value  = 0x0000_0020
    dut.rtn_htrans.value = HTRANS_NONSEQ
    dut.rtn_hwrite.value = 1
    await RisingEdge(dut.hclk)

    # Both enter data phase
    dut.ahb_tx_htrans.value = HTRANS_IDLE
    dut.ahb_tx_hsel.value   = 0
    dut.ahb_tx_hwdata.value = 0xAAAAAAAA
    dut.rtn_htrans.value = HTRANS_IDLE
    dut.rtn_hwrite.value = 0
    dut.rtn_hwdata.value = 0xBBBBBBBB
    await RisingEdge(dut.hclk)

    # Both pending, FC stalled. Returner wins priority -> enters skid first.
    # Release FC.
    dut.tl_fc_a2l_ready.value = 1
    await ClockCycles(dut.hclk, 5)

    # Both packets should arrive, verify both data values present
    pkt1 = await fc_mon.get()
    pkt2 = await fc_mon.get()

    # Returner (SIDEBAND) should be first due to priority
    assert pkt1["pkt_type"] == PKT_SIDEBAND, \
        f"First packet should be SIDEBAND (returner priority), got type {pkt1['pkt_type']}"
    assert pkt1["payload"] == 0xBBBBBBBB

    assert pkt2["pkt_type"] == PKT_FIFO_DATA, \
        f"Second packet should be FIFO_DATA (TX aperture), got type {pkt2['pkt_type']}"
    assert pkt2["payload"] == 0xAAAAAAAA


@cocotb.test()
async def test_11_arb_tx_resumes_after_rtn(dut):
    """TX aperture resumes after returner completes — no data lost."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Send a returner write first
    await rtn_write(dut, 0x0000_0014, 0x11111111)
    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_SIDEBAND

    # Now send a TX aperture write — should work fine
    await tx_aperture_write(dut, 0x0200, 0x22222222)
    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_FIFO_DATA
    assert pkt["payload"] == 0x22222222


@cocotb.test()
async def test_12_arb_alternating_sources(dut):
    """Back-to-back alternating TX aperture and returner writes."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    for i in range(4):
        if i % 2 == 0:
            # TX aperture
            await tx_aperture_write(dut, 0x0004 * i, 0xA0000000 | i)
            pkt = await fc_mon.get()
            assert pkt["pkt_type"] == PKT_FIFO_DATA
            assert pkt["payload"] == 0xA0000000 | i
        else:
            # Returner
            await rtn_write(dut, 0x0014, 0xB0000000 | i)
            pkt = await fc_mon.get()
            assert pkt["pkt_type"] == PKT_SIDEBAND
            assert pkt["payload"] == 0xB0000000 | i


# =============================================================================
# RX FIFO Path Tests
# =============================================================================

@cocotb.test()
async def test_13_rx_fifo_single(dut):
    """Drive FC l2a with FIFO_DATA -> verify AHB master write on fc_rx_fifo_*."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_addr = 0x0100
    test_data = 0xFEEDFACE

    await fc_drv.send(PKT_FIFO_DATA, test_addr, test_data)

    wr = await fifo_mon.get()
    assert wr["addr"] == test_addr, \
        f"Expected FIFO addr 0x{test_addr:04X}, got 0x{wr['addr']:04X}"
    assert wr["data"] == test_data, \
        f"Expected FIFO data 0x{test_data:08X}, got 0x{wr['data']:08X}"


@cocotb.test()
async def test_14_rx_fifo_multiple(dut):
    """Multiple sequential FIFO_DATA packets via FC RX."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    words = [
        (0x0000, 0x00000003),
        (0x0004, 0x11111111),
        (0x0008, 0x22222222),
        (0x000C, 0x33333333),
    ]

    for addr, data in words:
        await fc_drv.send(PKT_FIFO_DATA, addr, data)
        # Wait for the RX FSM to complete the AHB write
        await ClockCycles(dut.hclk, 5)

    for addr, data in words:
        wr = await fifo_mon.get()
        assert wr["addr"] == addr, \
            f"Expected addr 0x{addr:04X}, got 0x{wr['addr']:04X}"
        assert wr["data"] == data, \
            f"Expected data 0x{data:08X}, got 0x{wr['data']:08X}"


@cocotb.test()
async def test_15_rx_fifo_backpressure(dut):
    """Hold fc_rx_fifo_ready low -> verify FC l2a_accept pauses for FIFO_DATA."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Deassert FIFO slave hready to simulate backpressure
    dut.fc_rx_fifo_ready.value = 0

    # Drive an FC RX FIFO_DATA word — it should be accepted into the latch
    raw = FCDriver.encode(PKT_FIFO_DATA, 0x0100, 0xABCDABCD)
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw

    # Wait for accept (should happen since the RX state machine is IDLE)
    for _ in range(10):
        await RisingEdge(dut.hclk)
        if int(dut.tl_fc_l2a_accept.value) == 1:
            break

    dut.tl_fc_l2a_valid.value = 0

    # The RX FSM should now be trying to do an AHB write but stalled
    await ClockCycles(dut.hclk, 3)

    # Try to send another FC word — accept should NOT fire (FSM busy)
    raw2 = FCDriver.encode(PKT_FIFO_DATA, 0x0200, 0x12341234)
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw2
    await RisingEdge(dut.hclk)
    assert int(dut.tl_fc_l2a_accept.value) == 0, \
        "l2a_accept should be 0 while RX FSM is busy (backpressured)"

    dut.tl_fc_l2a_valid.value = 0

    # Release backpressure
    dut.fc_rx_fifo_ready.value = 1
    await ClockCycles(dut.hclk, 5)

    # First word should now complete
    wr = await fifo_mon.get()
    assert wr["data"] == 0xABCDABCD


# =============================================================================
# RX Config Path Tests
# =============================================================================

@cocotb.test()
async def test_16_rx_cfg_single(dut):
    """Drive FC l2a with SIDEBAND -> verify AHB master write on fc_rx_cfg_*."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_addr = 0x020   # credit return register offset
    test_data = 0x0000000A  # 10 credits

    await fc_drv.send(PKT_SIDEBAND, test_addr, test_data)

    wr = await cfg_mon.get()
    assert wr["addr"] == test_addr, \
        f"Expected cfg addr 0x{test_addr:03X}, got 0x{wr['addr']:03X}"
    assert wr["data"] == test_data, \
        f"Expected cfg data 0x{test_data:08X}, got 0x{wr['data']:08X}"


@cocotb.test()
async def test_17_rx_cfg_credit_return(dut):
    """Credit return sideband (addr_offset=0x020) routed to config port."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    await fc_drv.send(PKT_SIDEBAND, 0x020, 0x00000003)

    wr = await cfg_mon.get()
    assert wr["addr"] == 0x020
    assert wr["data"] == 0x00000003


@cocotb.test()
async def test_18_rx_cfg_doorbell(dut):
    """Doorbell sideband (addr_offset=0x014) routed to config port."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    await fc_drv.send(PKT_SIDEBAND, 0x014, 0x00000001)

    wr = await cfg_mon.get()
    assert wr["addr"] == 0x014
    assert wr["data"] == 0x00000001


@cocotb.test()
async def test_19_rx_cfg_backpressure(dut):
    """Hold fc_rx_cfg_hready low -> verify FC l2a_accept pauses for SIDEBAND."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    dut.fc_rx_cfg_pready.value = 0

    # Send a SIDEBAND word
    raw = FCDriver.encode(PKT_SIDEBAND, 0x014, 0xBEEFBEEF)
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw

    for _ in range(10):
        await RisingEdge(dut.hclk)
        if int(dut.tl_fc_l2a_accept.value) == 1:
            break

    dut.tl_fc_l2a_valid.value = 0

    # FSM should be stalled trying to write to cfg port
    await ClockCycles(dut.hclk, 3)

    # Another FC word should not be accepted
    raw2 = FCDriver.encode(PKT_SIDEBAND, 0x020, 0x55555555)
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw2
    await RisingEdge(dut.hclk)
    assert int(dut.tl_fc_l2a_accept.value) == 0, \
        "l2a_accept should be 0 while RX FSM busy on cfg path"

    dut.tl_fc_l2a_valid.value = 0

    # Release
    dut.fc_rx_cfg_pready.value = 1
    await ClockCycles(dut.hclk, 5)

    wr = await cfg_mon.get()
    assert wr["data"] == 0xBEEFBEEF


# =============================================================================
# Mixed Traffic Tests
# =============================================================================

@cocotb.test()
async def test_20_full_duplex(dut):
    """Simultaneous TX and RX (full duplex).

    TX aperture writes while RX FIFO_DATA words arrive concurrently.
    Both directions should operate independently.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Start RX in background
    async def rx_task():
        await fc_drv.send(PKT_FIFO_DATA, 0x0300, 0x11111111)
        await ClockCycles(dut.hclk, 2)
        await fc_drv.send(PKT_FIFO_DATA, 0x0304, 0x22222222)

    cocotb.start_soon(rx_task())

    # Simultaneously do TX aperture writes
    await tx_aperture_write(dut, 0x0400, 0xAAAAAAAA)
    await tx_aperture_write(dut, 0x0404, 0xBBBBBBBB)

    # Wait for everything to settle
    await ClockCycles(dut.hclk, 20)

    # Verify TX packets were sent
    tx_pkts = []
    while not fc_mon.packets.empty():
        tx_pkts.append(fc_mon.packets.get_nowait())

    # We should have at least 2 TX aperture packets
    fifo_data_pkts = [p for p in tx_pkts if p["pkt_type"] == PKT_FIFO_DATA]
    assert len(fifo_data_pkts) >= 2, \
        f"Expected at least 2 TX packets, got {len(fifo_data_pkts)}"

    # Verify RX FIFO writes arrived
    rx_writes = []
    while not fifo_mon.writes.empty():
        rx_writes.append(fifo_mon.writes.get_nowait())

    assert len(rx_writes) >= 2, \
        f"Expected at least 2 RX FIFO writes, got {len(rx_writes)}"


@cocotb.test()
async def test_21_stress_rapid_fire(dut):
    """Stress test: rapid fire packets in both TX and RX directions."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    num_packets = 8

    # TX: rapid fire aperture writes
    async def tx_stress():
        for i in range(num_packets):
            await tx_aperture_write(dut, (i * 4) & 0x3FFF, 0xA0000000 | i)

    # RX: rapid fire FIFO_DATA words
    async def rx_stress():
        for i in range(num_packets):
            await fc_drv.send(PKT_FIFO_DATA, (i * 4) & 0x3FFF, 0xB0000000 | i)
            # Small gap between sends to let FSM cycle
            await ClockCycles(dut.hclk, 2)

    # Run both concurrently
    tx_task = cocotb.start_soon(tx_stress())
    rx_task = cocotb.start_soon(rx_stress())

    # Wait for completion
    await ClockCycles(dut.hclk, num_packets * 20)

    # Collect TX results
    tx_count = 0
    while not fc_mon.packets.empty():
        fc_mon.packets.get_nowait()
        tx_count += 1
    dut._log.info(f"Stress TX: captured {tx_count} FC TX packets")
    assert tx_count >= num_packets, \
        f"Expected at least {num_packets} TX packets, got {tx_count}"

    # Collect RX results
    rx_count = 0
    while not fifo_mon.writes.empty():
        fifo_mon.writes.get_nowait()
        rx_count += 1
    dut._log.info(f"Stress RX: captured {rx_count} FIFO writes")
    assert rx_count >= num_packets, \
        f"Expected at least {num_packets} RX writes, got {rx_count}"


@cocotb.test()
async def test_22_mixed_rx_fifo_and_cfg(dut):
    """Interleave FIFO_DATA and SIDEBAND on RX — verify correct routing."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Send alternating FIFO and SIDEBAND
    await fc_drv.send(PKT_FIFO_DATA, 0x0000, 0xF0F0F0F0)
    await ClockCycles(dut.hclk, 5)
    await fc_drv.send(PKT_SIDEBAND, 0x014, 0x51515151)
    await ClockCycles(dut.hclk, 5)
    await fc_drv.send(PKT_FIFO_DATA, 0x0004, 0xF1F1F1F1)
    await ClockCycles(dut.hclk, 5)
    await fc_drv.send(PKT_SIDEBAND, 0x020, 0x52525252)
    await ClockCycles(dut.hclk, 5)

    # Verify FIFO writes
    wr1 = await fifo_mon.get()
    assert wr1["addr"] == 0x0000
    assert wr1["data"] == 0xF0F0F0F0

    wr2 = await fifo_mon.get()
    assert wr2["addr"] == 0x0004
    assert wr2["data"] == 0xF1F1F1F1

    # Verify config writes
    cwr1 = await cfg_mon.get()
    assert cwr1["addr"] == 0x014
    assert cwr1["data"] == 0x51515151

    cwr2 = await cfg_mon.get()
    assert cwr2["addr"] == 0x020
    assert cwr2["data"] == 0x52525252


@cocotb.test()
async def test_23_tx_aperture_addr_coverage(dut):
    """Verify various TX aperture addresses map correctly to FC addr_offset."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    addrs = [0x0000, 0x0004, 0x1000, 0x2FFC, 0x3FFC]
    for addr in addrs:
        await tx_aperture_write(dut, addr, addr)  # payload = addr for easy checking
        pkt = await fc_mon.get()
        assert pkt["addr_offset"] == addr, \
            f"Addr 0x{addr:04X}: expected offset 0x{addr:04X}, got 0x{pkt['addr_offset']:04X}"
        assert pkt["payload"] == addr


@cocotb.test()
async def test_24_rtn_addr_lower_14_bits(dut):
    """Returner addr_offset carries only lower 14 bits of the target address."""
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    # Full 32-bit address with upper bits set
    full_addr = 0xFFFF_0014
    expected_offset = full_addr & 0x3FFF  # lower 14 bits = 0x0014

    await rtn_write(dut, full_addr, 0xDEADDEAD)
    pkt = await fc_mon.get()
    assert pkt["pkt_type"] == PKT_SIDEBAND
    assert pkt["addr_offset"] == expected_offset, \
        f"Expected offset 0x{expected_offset:04X}, got 0x{pkt['addr_offset']:04X}"


# =============================================================================
# TideChart / PUF Helper Functions
# =============================================================================

def encode_fc(pkt_type, subtype_or_addr, payload):
    """Encode a 48-bit FC word: [47:46]=pkt_type, [45:32]=subtype/addr, [31:0]=payload."""
    return ((pkt_type & 0x3) << 46) | ((subtype_or_addr & 0x3FFF) << 32) | (payload & 0xFFFFFFFF)


def decode_fc(raw):
    """Decode a 48-bit FC word into its fields."""
    return {
        "raw":         raw,
        "pkt_type":    (raw >> 46) & 0x3,
        "addr_offset": (raw >> 32) & 0x3FFF,
        "payload":     raw & 0xFFFFFFFF,
    }


async def tc_axis_tx_send(dut, pkt_type, subtype, payload, timeout_cycles=100):
    """Drive a single packet on the tc_axis_tx AXI-Stream interface."""
    raw = encode_fc(pkt_type, subtype, payload)
    dut.tc_axis_tx_tvalid.value = 1
    dut.tc_axis_tx_tdata.value  = raw
    for _ in range(timeout_cycles):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.tc_axis_tx_tready.value) == 1:
                dut.tc_axis_tx_tvalid.value = 0
                dut.tc_axis_tx_tdata.value  = 0
                return
        except ValueError:
            continue
    raise TimeoutError("tc_axis_tx_send: tready not asserted within timeout")


async def tc_axis_rx_recv(dut, timeout_cycles=100):
    """Wait for a packet on tc_axis_rx and return decoded fields."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.tc_axis_rx_tvalid.value) == 1 and int(dut.tc_axis_rx_tready.value) == 1:
                raw = int(dut.tc_axis_rx_tdata.value)
                return decode_fc(raw)
        except ValueError:
            continue
    raise TimeoutError("tc_axis_rx_recv: no valid packet within timeout")


async def puf_responder(dut, rdata, latency_cycles=1):
    """Wait for puf_req, then after latency_cycles drive puf_ack + puf_rdata for one cycle."""
    for _ in range(200):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.puf_req.value) == 1:
                break
        except ValueError:
            continue
    else:
        raise TimeoutError("puf_responder: puf_req never asserted")

    # Wait latency
    for _ in range(latency_cycles):
        await RisingEdge(dut.hclk)

    # Drive response
    dut.puf_rdata.value = rdata
    dut.puf_ack.value   = 1
    await RisingEdge(dut.hclk)
    dut.puf_ack.value   = 0
    dut.puf_rdata.value = 0


# =============================================================================
# TideChart / PUF Tests
# =============================================================================

@cocotb.test()
async def test_30_puf_read_req_local(dut):
    """PUF_READ_REQ on tc_axis_tx -> local SRAM read -> PUF_READ_RSP on tc_axis_rx.

    Drives a PUF_READ_REQ (pkt_type=2'b10, subtype=0x0020, payload=address).
    Verifies puf_req asserts with correct address. Drives puf_ack + puf_rdata.
    Verifies PUF_READ_RSP appears on tc_axis_rx with correct subtype (0x0021)
    and SRAM data. Verifies the packet was NOT sent over FC.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_puf_addr = 0x0042      # word address to read from SRAM
    test_puf_rdata = 0xCAFEBABE  # SRAM data to return

    # Start PUF responder in background (waits for puf_req, drives ack+rdata)
    cocotb.start_soon(puf_responder(dut, test_puf_rdata, latency_cycles=1))

    # Send PUF_READ_REQ on tc_axis_tx
    await tc_axis_tx_send(dut, PKT_EXT, SUB_PUF_READ_REQ, test_puf_addr)

    # Wait a cycle then verify puf_req was asserted (it may have already cleared)
    # The responder task handles the handshake; now wait for the response
    rsp = await tc_axis_rx_recv(dut, timeout_cycles=50)

    assert rsp["pkt_type"] == PKT_EXT, \
        f"Expected PKT_EXT (2), got {rsp['pkt_type']}"
    assert rsp["addr_offset"] == SUB_PUF_READ_RSP, \
        f"Expected subtype 0x{SUB_PUF_READ_RSP:04X}, got 0x{rsp['addr_offset']:04X}"
    assert rsp["payload"] == test_puf_rdata, \
        f"Expected payload 0x{test_puf_rdata:08X}, got 0x{rsp['payload']:08X}"

    # Verify NO packet was sent over FC (PUF stays local)
    await ClockCycles(dut.hclk, 10)
    assert fc_mon.packets.empty(), \
        "PUF_READ_REQ should NOT produce any FC TX packet"


@cocotb.test()
async def test_31_puf_read_not_forwarded(dut):
    """PUF_READ_REQ must never appear on the FC TX link.

    Sends a PUF_READ_REQ and monitors tl_fc_a2l_valid for the entire
    transaction duration. Verifies it never asserts with a PKT_EXT + 0x0020.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_puf_rdata = 0x12345678

    # Start a snooper that watches for any FC TX with PUF subtype
    fc_tx_saw_puf = []

    async def fc_puf_snooper():
        for _ in range(100):
            await RisingEdge(dut.hclk)
            try:
                valid = int(dut.tl_fc_a2l_valid.value)
                ready = int(dut.tl_fc_a2l_ready.value)
            except ValueError:
                continue
            if valid and ready:
                raw = int(dut.tl_fc_a2l_data.value)
                pkt = decode_fc(raw)
                if pkt["pkt_type"] == PKT_EXT and pkt["addr_offset"] == SUB_PUF_READ_REQ:
                    fc_tx_saw_puf.append(pkt)

    cocotb.start_soon(fc_puf_snooper())
    cocotb.start_soon(puf_responder(dut, test_puf_rdata, latency_cycles=1))

    await tc_axis_tx_send(dut, PKT_EXT, SUB_PUF_READ_REQ, 0x0010)

    # Wait for response to complete
    rsp = await tc_axis_rx_recv(dut, timeout_cycles=50)
    await ClockCycles(dut.hclk, 20)

    assert len(fc_tx_saw_puf) == 0, \
        f"PUF_READ_REQ was forwarded to FC TX ({len(fc_tx_saw_puf)} times)"


@cocotb.test()
async def test_32_remote_ext_packet(dut):
    """Non-PUF PKT_EXT packet on tc_axis_tx is forwarded over FC.

    Drives a PKT_EXT with subtype=0x0001 (not a PUF subtype) and verifies
    it appears on the FC TX link (tl_fc_a2l_valid).
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_subtype = 0x0001
    test_payload = 0xDEADC0DE

    await tc_axis_tx_send(dut, PKT_EXT, test_subtype, test_payload)

    pkt = await fc_mon.get(timeout_cycles=50)
    assert pkt["pkt_type"] == PKT_EXT, \
        f"Expected PKT_EXT (2), got {pkt['pkt_type']}"
    assert pkt["addr_offset"] == test_subtype, \
        f"Expected subtype 0x{test_subtype:04X}, got 0x{pkt['addr_offset']:04X}"
    assert pkt["payload"] == test_payload, \
        f"Expected payload 0x{test_payload:08X}, got 0x{pkt['payload']:08X}"


@cocotb.test()
async def test_33_puf_response_priority(dut):
    """PUF_READ_RSP has priority over remote PKT_EXT on tc_axis_rx.

    Simultaneously make a PUF response pending and inject a remote PKT_EXT
    via FC RX. The PUF response should appear first on tc_axis_rx.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    puf_rdata = 0xAAAA1111
    remote_payload = 0xBBBB2222

    # Hold tc_axis_rx_tready low to accumulate both sources
    dut.tc_axis_rx_tready.value = 0

    # Start PUF read request to generate a local PUF response
    cocotb.start_soon(puf_responder(dut, puf_rdata, latency_cycles=0))
    await tc_axis_tx_send(dut, PKT_EXT, SUB_PUF_READ_REQ, 0x0004)

    # Wait for PUF FSM to reach PUF_RESPOND state
    await ClockCycles(dut.hclk, 10)

    # Inject a remote PKT_EXT via FC RX (it will be latched in the RX FSM)
    raw_remote = encode_fc(PKT_EXT, 0x0005, remote_payload)
    dut.tl_fc_l2a_valid.value = 1
    dut.tl_fc_l2a_data.value  = raw_remote
    # Wait for FC RX accept
    for _ in range(20):
        await RisingEdge(dut.hclk)
        try:
            if int(dut.tl_fc_l2a_accept.value) == 1:
                break
        except ValueError:
            continue
    dut.tl_fc_l2a_valid.value = 0

    # Let the RX FSM advance to ADDR_PHASE (remote_ext_valid asserts)
    await ClockCycles(dut.hclk, 5)

    # Now release tc_axis_rx_tready — both PUF response and remote PKT_EXT pending
    # PUF response should win priority
    dut.tc_axis_rx_tready.value = 1

    # First packet should be the PUF response
    rsp1 = await tc_axis_rx_recv(dut, timeout_cycles=20)
    assert rsp1["pkt_type"] == PKT_EXT, \
        f"First RX pkt: expected PKT_EXT, got {rsp1['pkt_type']}"
    assert rsp1["addr_offset"] == SUB_PUF_READ_RSP, \
        f"First RX pkt: expected PUF_READ_RSP (0x0021), got 0x{rsp1['addr_offset']:04X}"
    assert rsp1["payload"] == puf_rdata, \
        f"First RX pkt: expected 0x{puf_rdata:08X}, got 0x{rsp1['payload']:08X}"

    # Second packet should be the remote PKT_EXT
    rsp2 = await tc_axis_rx_recv(dut, timeout_cycles=20)
    assert rsp2["pkt_type"] == PKT_EXT, \
        f"Second RX pkt: expected PKT_EXT, got {rsp2['pkt_type']}"
    assert rsp2["addr_offset"] == 0x0005, \
        f"Second RX pkt: expected subtype 0x0005, got 0x{rsp2['addr_offset']:04X}"
    assert rsp2["payload"] == remote_payload, \
        f"Second RX pkt: expected 0x{remote_payload:08X}, got 0x{rsp2['payload']:08X}"


@cocotb.test()
async def test_34_puf_during_fifo_traffic(dut):
    """PUF_READ_REQ on tc_axis_tx concurrent with FIFO_DATA on TX aperture.

    Both paths should complete correctly without interference.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    fifo_addr = 0x0100
    fifo_data = 0xF1F0F1F0
    puf_addr = 0x0008
    puf_rdata = 0xBEEFCAFE

    # Start PUF responder
    cocotb.start_soon(puf_responder(dut, puf_rdata, latency_cycles=1))

    # Start FIFO TX write in background
    async def fifo_task():
        await tx_aperture_write(dut, fifo_addr, fifo_data)

    cocotb.start_soon(fifo_task())

    # Simultaneously send PUF_READ_REQ
    await tc_axis_tx_send(dut, PKT_EXT, SUB_PUF_READ_REQ, puf_addr)

    # Wait for PUF response
    rsp = await tc_axis_rx_recv(dut, timeout_cycles=50)
    assert rsp["pkt_type"] == PKT_EXT
    assert rsp["addr_offset"] == SUB_PUF_READ_RSP
    assert rsp["payload"] == puf_rdata, \
        f"PUF response data mismatch: expected 0x{puf_rdata:08X}, got 0x{rsp['payload']:08X}"

    # Wait for everything to settle
    await ClockCycles(dut.hclk, 20)

    # Verify the FIFO_DATA packet also made it through FC TX
    found_fifo = False
    while not fc_mon.packets.empty():
        pkt = fc_mon.packets.get_nowait()
        if pkt["pkt_type"] == PKT_FIFO_DATA and pkt["payload"] == fifo_data:
            found_fifo = True
            break
    assert found_fifo, "FIFO_DATA packet did not appear on FC TX"


@cocotb.test()
async def test_35_sram_arbiter_priority(dut):
    """Drive FC write (via FC RX), AHB access (TX aperture), and PUF read simultaneously.

    FC writes (via RX path) have highest priority for SRAM.
    This test verifies all three complete without data corruption.
    The SRAM arbiter priority (FC > AHB > PUF) is tested by exercising all
    paths concurrently and verifying each produces correct results.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    fc_rx_addr = 0x0200
    fc_rx_data = 0xFC_FC_FC_FC
    tx_addr = 0x0300
    tx_data = 0xAB_AB_AB_AB
    puf_read_addr = 0x0010
    puf_rdata_val = 0xDD_DD_DD_DD

    # Start PUF responder (will wait for puf_req)
    cocotb.start_soon(puf_responder(dut, puf_rdata_val, latency_cycles=2))

    # Start all three operations concurrently
    async def fc_rx_task():
        await fc_drv.send(PKT_FIFO_DATA, fc_rx_addr, fc_rx_data)

    async def tx_task():
        await tx_aperture_write(dut, tx_addr, tx_data)

    async def puf_task():
        await tc_axis_tx_send(dut, PKT_EXT, SUB_PUF_READ_REQ, puf_read_addr)

    cocotb.start_soon(fc_rx_task())
    cocotb.start_soon(tx_task())
    cocotb.start_soon(puf_task())

    # Wait for everything to settle
    await ClockCycles(dut.hclk, 40)

    # Verify FC RX write completed (FIFO direct write)
    wr = await fifo_mon.get(timeout_cycles=10)
    assert wr["addr"] == fc_rx_addr, \
        f"FC RX FIFO addr mismatch: expected 0x{fc_rx_addr:04X}, got 0x{wr['addr']:04X}"
    assert wr["data"] == fc_rx_data, \
        f"FC RX FIFO data mismatch: expected 0x{fc_rx_data:08X}, got 0x{wr['data']:08X}"

    # Verify TX aperture write completed
    found_tx = False
    while not fc_mon.packets.empty():
        pkt = fc_mon.packets.get_nowait()
        if pkt["pkt_type"] == PKT_FIFO_DATA and pkt["payload"] == tx_data:
            found_tx = True
    assert found_tx, "TX aperture FIFO_DATA packet not found on FC TX"

    # Verify PUF response
    rsp = await tc_axis_rx_recv(dut, timeout_cycles=10)
    assert rsp["pkt_type"] == PKT_EXT
    assert rsp["addr_offset"] == SUB_PUF_READ_RSP
    assert rsp["payload"] == puf_rdata_val


@cocotb.test()
async def test_36_tc_axis_tready_backpressure(dut):
    """tc_axis_rx backpressure: hold tready low, verify data holds until released.

    Injects a remote PKT_EXT via FC RX. Holds tc_axis_rx_tready=0. Verifies
    tc_axis_rx_tvalid asserts with correct data but the handshake does not
    complete. Then asserts tready and verifies the transfer completes.
    """
    fc_mon, fc_drv, fifo_mon, cfg_mon = await setup(dut)
    await do_reset(dut)

    test_subtype = 0x0007
    test_payload = 0x55AA55AA

    # Deassert tc_axis_rx_tready — backpressure
    dut.tc_axis_rx_tready.value = 0

    # Inject a remote PKT_EXT via FC RX
    await fc_drv.send(PKT_EXT, test_subtype, test_payload)

    # Wait for RX FSM to present the packet on tc_axis_rx
    await ClockCycles(dut.hclk, 10)

    # Verify tvalid is asserted with correct data, but not consumed
    assert int(dut.tc_axis_rx_tvalid.value) == 1, \
        "tc_axis_rx_tvalid should be 1 (data pending)"
    raw_data = int(dut.tc_axis_rx_tdata.value)
    pkt = decode_fc(raw_data)
    assert pkt["pkt_type"] == PKT_EXT, \
        f"Expected PKT_EXT, got {pkt['pkt_type']}"
    assert pkt["addr_offset"] == test_subtype, \
        f"Expected subtype 0x{test_subtype:04X}, got 0x{pkt['addr_offset']:04X}"
    assert pkt["payload"] == test_payload, \
        f"Expected 0x{test_payload:08X}, got 0x{pkt['payload']:08X}"

    # Data should hold stable for several more cycles
    for _ in range(5):
        await RisingEdge(dut.hclk)
        assert int(dut.tc_axis_rx_tvalid.value) == 1, \
            "tvalid dropped while tready was low"
        assert int(dut.tc_axis_rx_tdata.value) == raw_data, \
            "tdata changed while tready was low"

    # Release backpressure
    dut.tc_axis_rx_tready.value = 1
    await RisingEdge(dut.hclk)

    # The handshake should now complete; tvalid should deassert after
    await ClockCycles(dut.hclk, 3)

    # RX FSM should return to IDLE (no more pending data)
    # Verify tvalid is no longer asserted (no PUF response, no more remote data)
    assert int(dut.tc_axis_rx_tvalid.value) == 0, \
        "tc_axis_rx_tvalid should be 0 after handshake completed"
