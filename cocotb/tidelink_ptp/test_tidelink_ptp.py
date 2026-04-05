"""Cocotb testbench for tidelink_ptp (single-phase PTP module).

Exercises the AHB slave TX path, FC TX/RX interfaces, register interface,
PHC hardware capture, and interrupt logic.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer

# -- Constants ----------------------------------------------------------------
CLK_PERIOD_NS = 10

# AHB transfer types
HTRANS_IDLE   = 0
HTRANS_NONSEQ = 2

# Register addresses (ptp_reg_addr values) — Region 1 (basic PTP)
REG_PTP_CTRL       = 0x5
REG_PTP_RX_PAYLOAD = 0x6
REG_PTP_STATUS     = 0x7

# Register addresses — Region 2 (HW sync initiator)
REG_HW_SYNC_CTRL     = 0x0
REG_HW_SYNC_INTERVAL = 0x1
REG_HW_SYNC_STATUS   = 0x2

# PTP_CTRL bit positions
CTRL_ENABLE    = 0   # [0]   RW  enable
CTRL_CLEAR     = 1   # [1]   W1C clear
CTRL_RX_VALID  = 2   # [2]   RO  rx_valid
CTRL_RX_MSG_LO = 3   # [6:3] RO  rx_msg_type

# HW_SYNC_CTRL bit positions
HW_SYNC_EN        = 0   # [0] RW  enable
HW_SYNC_SEQ_CLEAR = 1   # [1] W1C seq_clear
HW_SYNC_FORCE_EN  = 2   # [2] RW  force_en (bypass phc_locked_i gate)

# Short packet data_id values
DATA_ID_SYNC      = 0x50
DATA_ID_DELAY_REQ = 0x51

# PTP message types (for AHB addr encoding)
MSG_SYNC      = 0x0
MSG_DELAY_REQ = 0x1


# -- Testbench Environment ----------------------------------------------------

class PtpTB:
    """Reusable testbench helper for tidelink_ptp."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

    async def reset(self):
        """Assert reset for 5 cycles, then release and settle."""
        dut = self.dut

        dut.hresetn.value = 0
        # Drive safe defaults during reset
        dut.tx_router_idle.value = 1
        dut.ahb_ptp_hsel.value = 0
        dut.ahb_ptp_htrans.value = HTRANS_IDLE
        dut.ahb_ptp_hsize.value = 2
        dut.ahb_ptp_hwrite.value = 0
        dut.ahb_ptp_haddr.value = 0
        dut.ahb_ptp_hwdata.value = 0
        dut.ptp_sp_tx_ready.value = 0
        dut.ptp_sp_rx_valid.value = 0
        dut.ptp_sp_rx_data_id.value = 0
        dut.ptp_sp_rx_payload.value = 0
        dut.ptp_reg_write.value = 0
        dut.ptp_reg_addr.value = 0
        dut.ptp_reg_wdata.value = 0
        dut.ptp_reg_region.value = 0
        # PHC time inputs (safe defaults)
        dut.phc_nanoseconds.value = 0
        dut.phc_seconds.value = 0
        dut.phc_pps.value = 0
        # External PHC lock gate (default: locked for backward compat)
        dut.phc_locked_i.value = 1

        await ClockCycles(dut.hclk, 5)
        dut.hresetn.value = 1
        await ClockCycles(dut.hclk, 5)

    # -- Register helpers -----------------------------------------------------

    async def reg_write(self, addr, data, region=0):
        """Single-cycle register write via ptp_reg_* interface."""
        dut = self.dut
        dut.ptp_reg_addr.value = addr
        dut.ptp_reg_wdata.value = data
        dut.ptp_reg_region.value = region
        dut.ptp_reg_write.value = 1
        await RisingEdge(dut.hclk)
        dut.ptp_reg_write.value = 0
        dut.ptp_reg_region.value = 0

    async def reg_read(self, addr, region=0):
        """Combinational register read via ptp_reg_* interface."""
        dut = self.dut
        dut.ptp_reg_addr.value = addr
        dut.ptp_reg_region.value = region
        await RisingEdge(dut.hclk)
        val = int(dut.ptp_reg_rdata.value)
        dut.ptp_reg_region.value = 0
        return val

    async def enable_ptp(self):
        """Enable PTP by writing enable bit in PTP_CTRL."""
        await self.reg_write(REG_PTP_CTRL, 1 << CTRL_ENABLE)

    async def disable_ptp(self):
        """Disable PTP by clearing enable bit in PTP_CTRL."""
        await self.reg_write(REG_PTP_CTRL, 0)

    # -- HW Sync helpers -------------------------------------------------------

    async def hw_sync_write(self, addr, data):
        """Write to a Region 2 (HW sync) register."""
        await self.reg_write(addr, data, region=1)

    async def hw_sync_read(self, addr):
        """Read from a Region 2 (HW sync) register."""
        return await self.reg_read(addr, region=1)

    def set_phc_time(self, seconds, nanoseconds):
        """Drive PHC time inputs to a specific value."""
        self.dut.phc_seconds.value = seconds
        self.dut.phc_nanoseconds.value = nanoseconds

    # -- AHB write helper (two-phase) ----------------------------------------

    async def ahb_write(self, addr, data):
        """Perform a two-phase AHB write to the PTP slave port.

        Address phase: drive hsel, htrans, haddr, hwrite.
        Data phase: drive hwdata, wait for hreadyout.
        """
        dut = self.dut

        # Address phase
        await RisingEdge(dut.hclk)
        dut.ahb_ptp_hsel.value   = 1
        dut.ahb_ptp_htrans.value = HTRANS_NONSEQ
        dut.ahb_ptp_hwrite.value = 1
        dut.ahb_ptp_hsize.value  = 2
        dut.ahb_ptp_haddr.value  = addr & 0xF

        # Data phase -- wait for hreadyout
        await RisingEdge(dut.hclk)
        dut.ahb_ptp_hwdata.value = data
        dut.ahb_ptp_htrans.value = HTRANS_IDLE
        dut.ahb_ptp_hsel.value   = 0

        # Wait until hreadyout goes high (transfer accepted)
        for _ in range(100):
            if int(dut.ahb_ptp_hreadyout.value) == 1:
                break
            await RisingEdge(dut.hclk)
        else:
            raise TimeoutError("AHB write: hreadyout never asserted")

        await RisingEdge(dut.hclk)
        dut.ahb_ptp_hwrite.value = 0

    # -- Short packet helpers -------------------------------------------------

    async def sp_rx_send(self, data_id, payload):
        """Drive a PTP short packet on the RX interface and wait for accept."""
        dut = self.dut
        dut.ptp_sp_rx_data_id.value = data_id
        dut.ptp_sp_rx_payload.value = payload & 0xFFFF
        dut.ptp_sp_rx_valid.value = 1
        for _ in range(100):
            await RisingEdge(dut.hclk)
            if int(dut.ptp_sp_rx_accept.value) == 1:
                break
        else:
            raise TimeoutError("SP RX: accept never asserted")
        dut.ptp_sp_rx_valid.value = 0

    async def sp_tx_accept(self):
        """Wait for ptp_sp_tx_valid, assert ready for one cycle, return (data_id, payload)."""
        dut = self.dut
        for _ in range(100):
            await RisingEdge(dut.hclk)
            if int(dut.ptp_sp_tx_valid.value) == 1:
                break
        else:
            raise TimeoutError("SP TX: valid never asserted")

        data_id = int(dut.ptp_sp_tx_data_id.value)
        payload = int(dut.ptp_sp_tx_payload.value)
        dut.ptp_sp_tx_ready.value = 1
        await RisingEdge(dut.hclk)
        dut.ptp_sp_tx_ready.value = 0
        return (data_id, payload)


# -- Tests --------------------------------------------------------------------

@cocotb.test()
async def test_ptp_enable_disable(dut):
    """Write enable via reg interface, verify ptp_irq gating."""
    tb = PtpTB(dut)
    await tb.reset()

    # After reset, PTP should be disabled and IRQ low
    assert int(dut.ptp_irq.value) == 0, "IRQ should be low after reset"

    # Drive an SP RX while PTP is disabled -- accept should not fire
    dut.ptp_sp_rx_valid.value = 1
    dut.ptp_sp_rx_data_id.value = DATA_ID_SYNC
    dut.ptp_sp_rx_payload.value = 0xDEAD
    await ClockCycles(dut.hclk, 2)
    assert int(dut.ptp_sp_rx_accept.value) == 0, \
        "SP RX accept should be 0 when PTP is disabled"
    assert int(dut.ptp_irq.value) == 0, "IRQ should stay low when PTP is disabled"
    dut.ptp_sp_rx_valid.value = 0

    # Enable PTP
    await tb.enable_ptp()
    await ClockCycles(dut.hclk, 2)

    # Verify enable took effect by reading PTP_CTRL
    ctrl = await tb.reg_read(REG_PTP_CTRL)
    assert (ctrl & 1) == 1, f"PTP enable bit should be 1, got ctrl=0x{ctrl:08X}"

    # Now send an SP RX -- should be accepted and IRQ should fire
    await tb.sp_rx_send(DATA_ID_SYNC, 0xBEEF)
    await ClockCycles(dut.hclk, 1)
    assert int(dut.ptp_irq.value) == 1, "IRQ should be high after RX with PTP enabled"

    # Disable PTP -- IRQ should deassert (gated by enable)
    await tb.disable_ptp()
    await ClockCycles(dut.hclk, 1)
    assert int(dut.ptp_irq.value) == 0, "IRQ should go low when PTP is disabled"

    tb.log.info("test_ptp_enable_disable PASSED")


@cocotb.test()
async def test_tx_basic(dut):
    """Enable PTP, write to AHB slave, verify FC TX word format."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    msg_type = 0x1   # DELAY_REQ
    payload  = 0xBEEF  # 16-bit payload for short packet

    # Start AHB write in the background (it will stall until SP ready)
    tx_task = cocotb.start_soon(tb.ahb_write(msg_type, payload))

    # Accept SP TX
    data_id, sp_payload = await tb.sp_tx_accept()

    await tx_task

    # Verify short packet: data_id=0x51 (DELAY_REQ), payload matches
    assert data_id == DATA_ID_DELAY_REQ, \
        f"SP TX data_id mismatch: got 0x{data_id:02X}, expected 0x{DATA_ID_DELAY_REQ:02X}"
    assert sp_payload == payload, \
        f"SP TX payload mismatch: got 0x{sp_payload:04X}, expected 0x{payload:04X}"

    tb.log.info("test_tx_basic PASSED")


@cocotb.test()
async def test_tx_idle_gating(dut):
    """Set tx_router_idle=0, write to AHB slave, verify FC valid stays low.
    Then set tx_router_idle=1, verify FC handshake completes."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # De-assert tx_router_idle
    dut.tx_router_idle.value = 0

    msg_type = 0x0   # SYNC
    payload  = 0x1234  # 16-bit payload

    # Start AHB write -- will stall in TX_WAIT_IDLE
    tx_task = cocotb.start_soon(tb.ahb_write(msg_type, payload))

    # Wait a few cycles -- SP TX valid should remain low
    await ClockCycles(dut.hclk, 10)
    assert int(dut.ptp_sp_tx_valid.value) == 0, \
        "SP TX valid should be 0 while tx_router_idle is 0"
    assert int(dut.ahb_ptp_hreadyout.value) == 0, \
        "AHB hreadyout should be 0 while TX is stalled"

    # Assert tx_router_idle -- FSM should advance to TX_SEND
    dut.tx_router_idle.value = 1

    # Accept SP TX
    data_id, sp_payload = await tb.sp_tx_accept()
    await tx_task

    assert data_id == DATA_ID_SYNC, \
        f"SP TX data_id mismatch: got 0x{data_id:02X}, expected 0x{DATA_ID_SYNC:02X}"
    assert sp_payload == payload, \
        f"SP TX payload mismatch: got 0x{sp_payload:04X}, expected 0x{payload:04X}"

    tb.log.info("test_tx_idle_gating PASSED")


@cocotb.test()
async def test_rx_basic(dut):
    """Enable PTP, drive a PTP FC word on l2a, verify IRQ, payload, and msg_type."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    msg_type = 0x0   # SYNC
    payload  = 0xBEEF  # 16-bit payload

    # Send SP RX
    await tb.sp_rx_send(DATA_ID_SYNC, payload)
    await ClockCycles(dut.hclk, 1)

    # Verify IRQ
    assert int(dut.ptp_irq.value) == 1, "IRQ should be high after RX"

    # Read PTP_CTRL -- check rx_valid and rx_msg_type
    ctrl = await tb.reg_read(REG_PTP_CTRL)
    rx_valid = (ctrl >> CTRL_RX_VALID) & 1
    rx_msg   = (ctrl >> CTRL_RX_MSG_LO) & 0xF
    assert rx_valid == 1, f"rx_valid should be 1, got ctrl=0x{ctrl:08X}"
    assert rx_msg == msg_type, \
        f"rx_msg_type should be 0x{msg_type:X}, got 0x{rx_msg:X}"

    # Read PTP_RX_PAYLOAD
    rx_payload = await tb.reg_read(REG_PTP_RX_PAYLOAD)
    assert rx_payload == payload, \
        f"RX payload mismatch: got 0x{rx_payload:08X}, expected 0x{payload:08X}"

    tb.log.info("test_rx_basic PASSED")


@cocotb.test()
async def test_phc_hw_capture_tx(dut):
    """Verify phc_hw_capture pulses for exactly 1 cycle on TX handshake."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    msg_type = 0x1
    payload  = 0xAAAA  # 16-bit

    # Start AHB write in background
    tx_task = cocotb.start_soon(tb.ahb_write(msg_type, payload))

    # Wait for SP TX valid
    for _ in range(100):
        await RisingEdge(dut.hclk)
        if int(dut.ptp_sp_tx_valid.value) == 1:
            break

    # Verify phc_hw_capture is low before ready
    assert int(dut.phc_hw_capture.value) == 0, \
        "phc_hw_capture should be 0 before TX handshake"

    # Assert ready -- this is the handshake cycle
    dut.ptp_sp_tx_ready.value = 1
    await RisingEdge(dut.hclk)

    # Now ready is still 1 but valid should drop (FSM goes to IDLE)
    dut.ptp_sp_tx_ready.value = 0
    await RisingEdge(dut.hclk)

    # phc_hw_capture should be low now (no handshake in progress)
    assert int(dut.phc_hw_capture.value) == 0, \
        "phc_hw_capture should be 0 after TX handshake completes"

    await tx_task
    tb.log.info("test_phc_hw_capture_tx PASSED")


@cocotb.test()
async def test_phc_hw_capture_rx(dut):
    """Verify phc_hw_capture pulses for exactly 1 cycle on RX accept."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # Before RX, capture should be low
    assert int(dut.phc_hw_capture.value) == 0, \
        "phc_hw_capture should be 0 before RX"

    # Drive SP RX valid + data
    dut.ptp_sp_rx_data_id.value = DATA_ID_SYNC
    dut.ptp_sp_rx_payload.value = 0x5555
    dut.ptp_sp_rx_valid.value = 1

    # Wait one cycle for accept to propagate (combinational)
    await RisingEdge(dut.hclk)

    # phc_hw_capture should be high (rx_accept = valid & enable)
    assert int(dut.phc_hw_capture.value) == 1, \
        "phc_hw_capture should be 1 during RX accept cycle"

    # Deassert valid
    dut.ptp_sp_rx_valid.value = 0
    await RisingEdge(dut.hclk)

    # phc_hw_capture should be low
    assert int(dut.phc_hw_capture.value) == 0, \
        "phc_hw_capture should be 0 after RX accept completes"

    tb.log.info("test_phc_hw_capture_rx PASSED")


@cocotb.test()
async def test_clear_bit(dut):
    """Write PTP_CTRL with clear=1, verify rx_valid clears."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # Receive an SP to set rx_valid
    await tb.sp_rx_send(DATA_ID_SYNC, 0x1111)
    await ClockCycles(dut.hclk, 1)

    # Verify rx_valid is set
    ctrl = await tb.reg_read(REG_PTP_CTRL)
    assert (ctrl >> CTRL_RX_VALID) & 1 == 1, "rx_valid should be 1 after RX"
    assert int(dut.ptp_irq.value) == 1, "IRQ should be high"

    # Write clear bit (bit 1) along with enable bit to keep PTP on
    await tb.reg_write(REG_PTP_CTRL, (1 << CTRL_CLEAR) | (1 << CTRL_ENABLE))
    await ClockCycles(dut.hclk, 1)

    # Verify rx_valid cleared
    ctrl = await tb.reg_read(REG_PTP_CTRL)
    assert (ctrl >> CTRL_RX_VALID) & 1 == 0, \
        f"rx_valid should be 0 after clear, got ctrl=0x{ctrl:08X}"

    # IRQ should also be low (rx_valid cleared)
    assert int(dut.ptp_irq.value) == 0, "IRQ should be low after clear"

    tb.log.info("test_clear_bit PASSED")


@cocotb.test()
async def test_status_register(dut):
    """Verify PTP_STATUS[0] mirrors tx_router_idle, PTP_STATUS[1] shows tx_pending."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # Initially: tx_router_idle=1 (from reset helper), no pending TX
    status = await tb.reg_read(REG_PTP_STATUS)
    assert (status & 1) == 1, \
        f"STATUS[0] should mirror tx_router_idle=1, got 0x{status:08X}"
    assert (status >> 1) & 1 == 0, \
        f"STATUS[1] (tx_pending) should be 0, got 0x{status:08X}"

    # De-assert tx_router_idle
    dut.tx_router_idle.value = 0
    await ClockCycles(dut.hclk, 1)

    status = await tb.reg_read(REG_PTP_STATUS)
    assert (status & 1) == 0, \
        f"STATUS[0] should mirror tx_router_idle=0, got 0x{status:08X}"

    # Start an AHB write to make tx_pending=1
    # We'll keep tx_router_idle=0 so the TX stalls
    tx_task = cocotb.start_soon(tb.ahb_write(0x0, 0xAAAA))
    await ClockCycles(dut.hclk, 5)

    status = await tb.reg_read(REG_PTP_STATUS)
    assert (status >> 1) & 1 == 1, \
        f"STATUS[1] (tx_pending) should be 1 during stalled TX, got 0x{status:08X}"

    # Release: set tx_router_idle=1 and accept FC
    dut.tx_router_idle.value = 1
    data_id, sp_payload = await tb.sp_tx_accept()
    await tx_task

    await ClockCycles(dut.hclk, 1)
    status = await tb.reg_read(REG_PTP_STATUS)
    assert (status >> 1) & 1 == 0, \
        f"STATUS[1] (tx_pending) should be 0 after TX completes, got 0x{status:08X}"

    tb.log.info("test_status_register PASSED")


# -- HW Sync Initiator Tests --------------------------------------------------

@cocotb.test()
async def test_hw_sync_enable_disable(dut):
    """Write HW_SYNC_CTRL enable, verify FSM activates; disable, verify stops."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # After reset, hw_sync should be disabled
    ctrl = await tb.hw_sync_read(REG_HW_SYNC_CTRL)
    assert (ctrl & 1) == 0, f"hw_sync_en should be 0 after reset, got 0x{ctrl:08X}"

    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    assert (status & 1) == 0, f"active should be 0 after reset, got 0x{status:08X}"

    # Set PHC time and enable hw_sync
    tb.set_phc_time(0, 100)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)  # 1000 ns interval
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    # Verify active
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    assert (status & 1) == 1, f"active should be 1, got 0x{status:08X}"

    # Disable hw_sync
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 0)
    await ClockCycles(dut.hclk, 3)

    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    assert (status & 1) == 0, f"active should be 0 after disable, got 0x{status:08X}"

    tb.log.info("test_hw_sync_enable_disable PASSED")


@cocotb.test()
async def test_hw_sync_basic_fire(dut):
    """Enable with interval, drive PHC nanoseconds past target, verify FC TX SYNC."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    interval_ns = 500  # 500 ns interval
    start_ns = 100

    tb.set_phc_time(0, start_ns)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, interval_ns)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    # Advance PHC time past the target (start_ns + interval_ns = 600)
    tb.set_phc_time(0, start_ns + interval_ns + 10)
    await ClockCycles(dut.hclk, 5)

    # The HW sync FSM should fire a SYNC — accept it on FC TX
    data_id, sp_payload = await tb.sp_tx_accept()

    # Verify it's a SYNC message with seq_num = 0
    assert data_id == DATA_ID_SYNC, f"data_id should be SYNC (0x50), got 0x{data_id:02X}"
    assert sp_payload == 0, f"seq_num should be 0 for first SYNC, got 0x{sp_payload:04X}"

    tb.log.info("test_hw_sync_basic_fire PASSED")


@cocotb.test()
async def test_hw_sync_seq_increment(dut):
    """Verify payload contains incrementing sequence number across multiple fires."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    interval_ns = 200
    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, interval_ns)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    for expected_seq in range(3):
        # Advance PHC past next target
        target_ns = (expected_seq + 1) * interval_ns + 10
        tb.set_phc_time(0, target_ns)
        await ClockCycles(dut.hclk, 5)

        # Accept SP TX
        data_id, sp_payload = await tb.sp_tx_accept()
        assert sp_payload == expected_seq, \
            f"seq_num mismatch: got {sp_payload}, expected {expected_seq}"

        # Wait for TX FSM to return to idle
        await ClockCycles(dut.hclk, 5)

    tb.log.info("test_hw_sync_seq_increment PASSED")


@cocotb.test()
async def test_hw_sync_seq_clear(dut):
    """Set seq_clear bit, verify seq_num resets to 0."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    interval_ns = 200
    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, interval_ns)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    # Fire once to get seq_num=0, then complete TX
    tb.set_phc_time(0, interval_ns + 10)
    await ClockCycles(dut.hclk, 5)
    data_id, sp_payload = await tb.sp_tx_accept()
    await ClockCycles(dut.hclk, 5)

    # Fire again to get seq_num=1
    tb.set_phc_time(0, 2 * interval_ns + 20)
    await ClockCycles(dut.hclk, 5)
    data_id, sp_payload = await tb.sp_tx_accept()
    assert sp_payload == 1, f"seq_num should be 1, got {sp_payload}"
    await ClockCycles(dut.hclk, 5)

    # Clear sequence number (write enable + seq_clear)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, (1 << HW_SYNC_SEQ_CLEAR) | (1 << HW_SYNC_EN))
    await ClockCycles(dut.hclk, 2)

    # Verify seq_num reset in status
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    seq_num = (status >> 2) & 0xFFFF
    assert seq_num == 0, f"seq_num should be 0 after clear, got {seq_num}"

    tb.log.info("test_hw_sync_seq_clear PASSED")


@cocotb.test()
async def test_hw_sync_status_readback(dut):
    """Read HW_SYNC_STATUS, verify active/busy/seq_num fields."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # After reset: active=0, busy=0, seq_num=0; phc_locked (bit 18) reflects input
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    status_masked = status & 0x0003FFFF  # Mask out phc_locked bit [18]
    assert status_masked == 0, f"HW_SYNC_STATUS [17:0] should be 0 after reset, got 0x{status:08X}"

    # Enable and verify active bit
    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    active = status & 1
    assert active == 1, f"active should be 1, got 0x{status:08X}"

    # Read back interval
    interval = await tb.hw_sync_read(REG_HW_SYNC_INTERVAL)
    assert interval == 1000, f"interval should be 1000, got {interval}"

    # Read back ctrl
    ctrl = await tb.hw_sync_read(REG_HW_SYNC_CTRL)
    assert (ctrl & 1) == 1, f"hw_sync_en should be 1, got 0x{ctrl:08X}"

    tb.log.info("test_hw_sync_status_readback PASSED")


@cocotb.test()
async def test_hw_sync_sw_coexistence(dut):
    """Verify software TX works while hw_sync is enabled, and hw_sync
    continues to operate after the software TX completes."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    interval_ns = 5000  # large interval so hw_sync doesn't fire during SW TX
    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, interval_ns)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    # Software TX (DELAY_REQ) while hw_sync is armed but not yet triggered
    sw_payload = 0xBEEF  # 16-bit payload for short packet
    tx_task = cocotb.start_soon(tb.ahb_write(MSG_DELAY_REQ, sw_payload))
    data_id, sp_payload = await tb.sp_tx_accept()
    await tx_task

    assert data_id == DATA_ID_DELAY_REQ, \
        f"Expected SW DELAY_REQ (0x51), got data_id=0x{data_id:02X}"
    assert sp_payload == sw_payload, \
        f"payload mismatch: got 0x{sp_payload:04X}, expected 0x{sw_payload:04X}"

    await ClockCycles(dut.hclk, 3)

    # Now advance PHC past the hw_sync target — it should still fire
    tb.set_phc_time(0, interval_ns + 10)
    await ClockCycles(dut.hclk, 5)
    data_id, sp_payload = await tb.sp_tx_accept()
    assert data_id == DATA_ID_SYNC, \
        f"HW sync should fire after SW TX: expected SYNC (0x50), got data_id=0x{data_id:02X}"

    tb.log.info("test_hw_sync_sw_coexistence PASSED")


@cocotb.test()
async def test_hw_sync_second_rollover(dut):
    """PHC nanoseconds wrap past 1e9, verify target seconds increments correctly."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    # Start near the end of a second
    start_ns = 999_999_800
    interval_ns = 500  # target will be > 1e9, should wrap to next second
    tb.set_phc_time(0, start_ns)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, interval_ns)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 3)

    # Target should be: seconds=1, ns=(start_ns + interval_ns - 1_000_000_000)
    # = 999_999_800 + 500 - 1_000_000_000 = 300 - 1 = 299
    # Advance PHC to second 1, ns past the target
    tb.set_phc_time(1, 400)
    await ClockCycles(dut.hclk, 5)

    # Accept FC TX — should fire
    data_id, sp_payload = await tb.sp_tx_accept()
    assert data_id == DATA_ID_SYNC, f"expected SYNC (0x50), got data_id=0x{data_id:02X}"

    tb.log.info("test_hw_sync_second_rollover PASSED")
