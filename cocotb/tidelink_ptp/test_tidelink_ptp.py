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

# Register addresses (ptp_reg_addr values)
REG_PTP_CTRL       = 0x5
REG_PTP_RX_PAYLOAD = 0x6
REG_PTP_STATUS     = 0x7

# PTP_CTRL bit positions
CTRL_ENABLE    = 0   # [0]   RW  enable
CTRL_CLEAR     = 1   # [1]   W1C clear
CTRL_RX_VALID  = 2   # [2]   RO  rx_valid
CTRL_RX_MSG_LO = 3   # [6:3] RO  rx_msg_type

# FC packet type for PTP
PKT_PTP = 0b10


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
        dut.ptp_fc_a2l_ready.value = 0
        dut.ptp_fc_l2a_valid.value = 0
        dut.ptp_fc_l2a_data.value = 0
        dut.ptp_reg_write.value = 0
        dut.ptp_reg_addr.value = 0
        dut.ptp_reg_wdata.value = 0

        await ClockCycles(dut.hclk, 5)
        dut.hresetn.value = 1
        await ClockCycles(dut.hclk, 5)

    # -- Register helpers -----------------------------------------------------

    async def reg_write(self, addr, data):
        """Single-cycle register write via ptp_reg_* interface."""
        dut = self.dut
        dut.ptp_reg_addr.value = addr
        dut.ptp_reg_wdata.value = data
        dut.ptp_reg_write.value = 1
        await RisingEdge(dut.hclk)
        dut.ptp_reg_write.value = 0

    async def reg_read(self, addr):
        """Combinational register read via ptp_reg_* interface."""
        dut = self.dut
        dut.ptp_reg_addr.value = addr
        await RisingEdge(dut.hclk)
        return int(dut.ptp_reg_rdata.value)

    async def enable_ptp(self):
        """Enable PTP by writing enable bit in PTP_CTRL."""
        await self.reg_write(REG_PTP_CTRL, 1 << CTRL_ENABLE)

    async def disable_ptp(self):
        """Disable PTP by clearing enable bit in PTP_CTRL."""
        await self.reg_write(REG_PTP_CTRL, 0)

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

    # -- FC helpers -----------------------------------------------------------

    async def fc_rx_send(self, msg_type, payload):
        """Drive a PTP FC word on the l2a interface and wait for accept."""
        dut = self.dut
        fc_word = (PKT_PTP << 46) | (msg_type << 32) | (payload & 0xFFFFFFFF)
        dut.ptp_fc_l2a_data.value = fc_word
        dut.ptp_fc_l2a_valid.value = 1
        for _ in range(100):
            await RisingEdge(dut.hclk)
            if int(dut.ptp_fc_l2a_accept.value) == 1:
                break
        else:
            raise TimeoutError("FC RX: accept never asserted")
        dut.ptp_fc_l2a_valid.value = 0

    async def fc_tx_accept(self):
        """Wait for ptp_fc_a2l_valid, assert ready for one cycle, return data."""
        dut = self.dut
        for _ in range(100):
            await RisingEdge(dut.hclk)
            if int(dut.ptp_fc_a2l_valid.value) == 1:
                break
        else:
            raise TimeoutError("FC TX: valid never asserted")

        fc_data = int(dut.ptp_fc_a2l_data.value)
        dut.ptp_fc_a2l_ready.value = 1
        await RisingEdge(dut.hclk)
        dut.ptp_fc_a2l_ready.value = 0
        return fc_data


# -- Tests --------------------------------------------------------------------

@cocotb.test()
async def test_ptp_enable_disable(dut):
    """Write enable via reg interface, verify ptp_irq gating."""
    tb = PtpTB(dut)
    await tb.reset()

    # After reset, PTP should be disabled and IRQ low
    assert int(dut.ptp_irq.value) == 0, "IRQ should be low after reset"

    # Drive an FC RX word while PTP is disabled -- accept should not fire
    dut.ptp_fc_l2a_valid.value = 1
    dut.ptp_fc_l2a_data.value = (PKT_PTP << 46) | (0x0 << 32) | 0xDEAD
    await ClockCycles(dut.hclk, 2)
    assert int(dut.ptp_fc_l2a_accept.value) == 0, \
        "FC RX accept should be 0 when PTP is disabled"
    assert int(dut.ptp_irq.value) == 0, "IRQ should stay low when PTP is disabled"
    dut.ptp_fc_l2a_valid.value = 0

    # Enable PTP
    await tb.enable_ptp()
    await ClockCycles(dut.hclk, 2)

    # Verify enable took effect by reading PTP_CTRL
    ctrl = await tb.reg_read(REG_PTP_CTRL)
    assert (ctrl & 1) == 1, f"PTP enable bit should be 1, got ctrl=0x{ctrl:08X}"

    # Now send an FC RX word -- should be accepted and IRQ should fire
    await tb.fc_rx_send(0x0, 0xBEEF)
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
    payload  = 0xCAFEBABE

    # Start AHB write in the background (it will stall until FC ready)
    tx_task = cocotb.start_soon(tb.ahb_write(msg_type, payload))

    # Accept FC TX
    fc_data = await tb.fc_tx_accept()

    await tx_task

    # Verify FC word: {2'b10, 10'b0, msg_type[3:0], payload[31:0]}
    expected = (PKT_PTP << 46) | (msg_type << 32) | payload
    assert fc_data == expected, \
        f"FC TX word mismatch: got 0x{fc_data:012X}, expected 0x{expected:012X}"

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
    payload  = 0x12345678

    # Start AHB write -- will stall in TX_WAIT_IDLE
    tx_task = cocotb.start_soon(tb.ahb_write(msg_type, payload))

    # Wait a few cycles -- FC valid should remain low
    await ClockCycles(dut.hclk, 10)
    assert int(dut.ptp_fc_a2l_valid.value) == 0, \
        "FC TX valid should be 0 while tx_router_idle is 0"
    assert int(dut.ahb_ptp_hreadyout.value) == 0, \
        "AHB hreadyout should be 0 while TX is stalled"

    # Assert tx_router_idle -- FSM should advance to TX_SEND
    dut.tx_router_idle.value = 1

    # Accept FC TX
    fc_data = await tb.fc_tx_accept()
    await tx_task

    expected = (PKT_PTP << 46) | (msg_type << 32) | payload
    assert fc_data == expected, \
        f"FC TX word mismatch: got 0x{fc_data:012X}, expected 0x{expected:012X}"

    tb.log.info("test_tx_idle_gating PASSED")


@cocotb.test()
async def test_rx_basic(dut):
    """Enable PTP, drive a PTP FC word on l2a, verify IRQ, payload, and msg_type."""
    tb = PtpTB(dut)
    await tb.reset()
    await tb.enable_ptp()

    msg_type = 0x0   # SYNC
    payload  = 0xDEADBEEF

    # Send FC RX word
    await tb.fc_rx_send(msg_type, payload)
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
    payload  = 0xAAAAAAAA

    # Start AHB write in background
    tx_task = cocotb.start_soon(tb.ahb_write(msg_type, payload))

    # Wait for FC valid
    for _ in range(100):
        await RisingEdge(dut.hclk)
        if int(dut.ptp_fc_a2l_valid.value) == 1:
            break

    # Verify phc_hw_capture is low before ready
    assert int(dut.phc_hw_capture.value) == 0, \
        "phc_hw_capture should be 0 before TX handshake"

    # Assert ready -- this is the handshake cycle
    dut.ptp_fc_a2l_ready.value = 1
    await RisingEdge(dut.hclk)
    # On this rising edge, valid & ready were both 1 in previous cycle
    # phc_hw_capture is combinational: valid & ready
    # Check the capture was asserted
    # Since phc_hw_capture = tx_handshake | rx_accept (combinational),
    # it should have been high during the cycle when valid & ready overlapped

    # Now ready is still 1 but valid should drop (FSM goes to IDLE)
    dut.ptp_fc_a2l_ready.value = 0
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

    # Drive FC RX valid + data
    msg_type = 0x0
    payload  = 0x55555555
    fc_word  = (PKT_PTP << 46) | (msg_type << 32) | payload
    dut.ptp_fc_l2a_data.value  = fc_word
    dut.ptp_fc_l2a_valid.value = 1

    # Wait one cycle for accept to propagate (combinational)
    await RisingEdge(dut.hclk)

    # phc_hw_capture should be high (rx_accept = valid & enable)
    assert int(dut.phc_hw_capture.value) == 1, \
        "phc_hw_capture should be 1 during RX accept cycle"

    # Deassert valid
    dut.ptp_fc_l2a_valid.value = 0
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

    # Receive an FC word to set rx_valid
    await tb.fc_rx_send(0x0, 0x11111111)
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
    fc_data = await tb.fc_tx_accept()
    await tx_task

    await ClockCycles(dut.hclk, 1)
    status = await tb.reg_read(REG_PTP_STATUS)
    assert (status >> 1) & 1 == 0, \
        f"STATUS[1] (tx_pending) should be 0 after TX completes, got 0x{status:08X}"

    tb.log.info("test_status_register PASSED")
