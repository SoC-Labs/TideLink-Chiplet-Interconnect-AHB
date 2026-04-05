"""Cocotb tests for tidelink_ptp lock gate (PHC_LOCK_GATE_EN=1).

These tests exercise the HW sync initiator lock gate that is optimised away
when PHC_LOCK_GATE_EN=0 (default). They require tb_top_gated.sv which
instantiates tidelink_ptp with PHC_LOCK_GATE_EN=1.

Test IDs correspond to the verification plan:
  LG-01: test_gate_blocks_arm
  LG-02: test_gate_allows_arm_when_locked
  LG-03: test_enable_before_lock
  LG-04: test_force_enable_overrides_gate
  LG-05: test_lock_drop_while_armed
  LG-06: test_status_phc_locked_bit
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# -- Constants ----------------------------------------------------------------
CLK_PERIOD_NS = 10

HTRANS_IDLE   = 0
HTRANS_NONSEQ = 2

# Register addresses — Region 2 (HW sync initiator)
REG_HW_SYNC_CTRL     = 0x0
REG_HW_SYNC_INTERVAL = 0x1
REG_HW_SYNC_STATUS   = 0x2

# HW_SYNC_CTRL bit positions
HW_SYNC_EN        = 0
HW_SYNC_SEQ_CLEAR = 1
HW_SYNC_FORCE_EN  = 2

# Short packet data_id
DATA_ID_SYNC = 0x50


# -- Testbench Environment ----------------------------------------------------

class GatedPtpTB:
    """Reusable testbench helper for tidelink_ptp with PHC_LOCK_GATE_EN=1."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log
        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

    async def reset(self, phc_locked=0):
        """Assert reset with phc_locked_i driven to specified value."""
        dut = self.dut
        dut.hresetn.value = 0
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
        dut.phc_nanoseconds.value = 0
        dut.phc_seconds.value = 0
        dut.phc_pps.value = 0
        dut.phc_locked_i.value = phc_locked
        await ClockCycles(dut.hclk, 5)
        dut.hresetn.value = 1
        await ClockCycles(dut.hclk, 5)

    async def reg_write(self, addr, data, region=0):
        dut = self.dut
        dut.ptp_reg_addr.value = addr
        dut.ptp_reg_wdata.value = data
        dut.ptp_reg_region.value = region
        dut.ptp_reg_write.value = 1
        await RisingEdge(dut.hclk)
        dut.ptp_reg_write.value = 0
        await RisingEdge(dut.hclk)

    async def reg_read(self, addr, region=0):
        dut = self.dut
        dut.ptp_reg_addr.value = addr
        dut.ptp_reg_region.value = region
        dut.ptp_reg_write.value = 0
        await RisingEdge(dut.hclk)
        return int(dut.ptp_reg_rdata.value)

    async def hw_sync_write(self, addr, data):
        await self.reg_write(addr, data, region=1)

    async def hw_sync_read(self, addr):
        return await self.reg_read(addr, region=1)

    async def enable_ptp(self):
        await self.reg_write(0x5, 0x3, region=0)  # enable + clear
        await self.reg_write(0x5, 0x1, region=0)  # enable only

    def set_phc_time(self, seconds, nanoseconds):
        self.dut.phc_nanoseconds.value = nanoseconds
        self.dut.phc_seconds.value = seconds

    async def wait_for_sync_tx(self, timeout_cycles=200):
        """Wait for a SYNC to appear on FC TX, return True if seen."""
        dut = self.dut
        dut.ptp_sp_tx_ready.value = 1
        for _ in range(timeout_cycles):
            await RisingEdge(dut.hclk)
            if dut.ptp_sp_tx_valid.value == 1:
                dut.ptp_sp_tx_ready.value = 0
                return True
        dut.ptp_sp_tx_ready.value = 0
        return False


# -- Tests --------------------------------------------------------------------

@cocotb.test()
async def test_gate_blocks_arm(dut):
    """LG-01: With phc_locked_i=0, HW sync enable does not arm FSM."""
    tb = GatedPtpTB(dut)
    await tb.reset(phc_locked=0)
    await tb.enable_ptp()

    # Set interval and enable HW sync
    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 5)

    # Advance PHC time well past the interval
    tb.set_phc_time(0, 50000)
    await ClockCycles(dut.hclk, 10)

    # Check: no SYNC should have fired
    fired = await tb.wait_for_sync_tx(timeout_cycles=50)
    assert not fired, "SYNC fired despite phc_locked_i=0"

    # Verify FSM status: active (enable is set) but not busy
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    active = status & 1
    busy = (status >> 1) & 1
    assert active == 1, f"Expected active=1, got status=0x{status:08X}"
    assert busy == 0, f"Expected busy=0, got status=0x{status:08X}"

    tb.log.info("test_gate_blocks_arm PASSED")


@cocotb.test()
async def test_gate_allows_arm_when_locked(dut):
    """LG-02: With phc_locked_i=1, HW sync arms and fires normally."""
    tb = GatedPtpTB(dut)
    await tb.reset(phc_locked=1)
    await tb.enable_ptp()

    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 5)

    # Advance PHC time past interval
    tb.set_phc_time(0, 5000)
    await ClockCycles(dut.hclk, 5)

    # Should fire a SYNC
    fired = await tb.wait_for_sync_tx(timeout_cycles=50)
    assert fired, "SYNC did not fire with phc_locked_i=1"

    # Wait for HW sync FSM to complete WAIT_TX and increment seq_num
    await ClockCycles(dut.hclk, 10)

    # Verify seq_num incremented
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    seq_num = (status >> 2) & 0xFFFF
    assert seq_num >= 1, f"Expected seq_num>=1 after fire, got {seq_num}"

    tb.log.info("test_gate_allows_arm_when_locked PASSED")


@cocotb.test()
async def test_enable_before_lock(dut):
    """LG-03: Enable HW sync first, then assert phc_locked_i — arms on rising edge."""
    tb = GatedPtpTB(dut)
    await tb.reset(phc_locked=0)
    await tb.enable_ptp()

    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)

    # Enable HW sync while locked is still low
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 10)

    # Verify no arming yet
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    busy = (status >> 1) & 1
    assert busy == 0, "FSM should not be busy before lock asserts"

    # Now assert phc_locked_i — should trigger gate_rising and arm
    dut.phc_locked_i.value = 1
    await ClockCycles(dut.hclk, 5)

    # Advance PHC time past interval to trigger fire
    tb.set_phc_time(0, 5000)
    await ClockCycles(dut.hclk, 5)

    fired = await tb.wait_for_sync_tx(timeout_cycles=50)
    assert fired, "SYNC did not fire after phc_locked_i rising edge"

    tb.log.info("test_enable_before_lock PASSED")


@cocotb.test()
async def test_force_enable_overrides_gate(dut):
    """LG-04: hw_sync_force_en=1 bypasses phc_locked_i gate."""
    tb = GatedPtpTB(dut)
    await tb.reset(phc_locked=0)
    await tb.enable_ptp()

    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)

    # Enable HW sync with force_en — should arm despite phc_locked_i=0
    ctrl = (1 << HW_SYNC_EN) | (1 << HW_SYNC_FORCE_EN)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, ctrl)
    await ClockCycles(dut.hclk, 5)

    # Advance PHC time past interval
    tb.set_phc_time(0, 5000)
    await ClockCycles(dut.hclk, 5)

    fired = await tb.wait_for_sync_tx(timeout_cycles=50)
    assert fired, "SYNC did not fire with force_en=1 despite phc_locked_i=0"

    # Verify HW_SYNC_CTRL readback includes force_en bit
    ctrl_rb = await tb.hw_sync_read(REG_HW_SYNC_CTRL)
    assert (ctrl_rb >> HW_SYNC_FORCE_EN) & 1 == 1, \
        f"force_en not set in readback: 0x{ctrl_rb:08X}"

    tb.log.info("test_force_enable_overrides_gate PASSED")


@cocotb.test()
async def test_lock_drop_while_armed(dut):
    """LG-05: Lock drop after arming does not disrupt running FSM."""
    tb = GatedPtpTB(dut)
    await tb.reset(phc_locked=1)
    await tb.enable_ptp()

    tb.set_phc_time(0, 0)
    await tb.hw_sync_write(REG_HW_SYNC_INTERVAL, 1000)
    await tb.hw_sync_write(REG_HW_SYNC_CTRL, 1 << HW_SYNC_EN)
    await ClockCycles(dut.hclk, 5)

    # Deassert phc_locked_i while FSM is ARMED
    dut.phc_locked_i.value = 0
    await ClockCycles(dut.hclk, 5)

    # Advance PHC time past interval — should still fire (gate only blocks IDLE→ARMED)
    tb.set_phc_time(0, 5000)
    await ClockCycles(dut.hclk, 5)

    fired = await tb.wait_for_sync_tx(timeout_cycles=50)
    assert fired, "SYNC should still fire after lock drop (gate only blocks arming)"

    tb.log.info("test_lock_drop_while_armed PASSED")


@cocotb.test()
async def test_status_phc_locked_bit(dut):
    """LG-06: HW_SYNC_STATUS[18] tracks phc_locked_i in real time."""
    tb = GatedPtpTB(dut)
    await tb.reset(phc_locked=0)

    # phc_locked_i=0 → bit 18 should be 0
    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    locked_bit = (status >> 18) & 1
    assert locked_bit == 0, f"Expected phc_locked=0, got status=0x{status:08X}"

    # Assert phc_locked_i=1
    dut.phc_locked_i.value = 1
    await ClockCycles(dut.hclk, 2)

    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    locked_bit = (status >> 18) & 1
    assert locked_bit == 1, f"Expected phc_locked=1, got status=0x{status:08X}"

    # Deassert
    dut.phc_locked_i.value = 0
    await ClockCycles(dut.hclk, 2)

    status = await tb.hw_sync_read(REG_HW_SYNC_STATUS)
    locked_bit = (status >> 18) & 1
    assert locked_bit == 0, f"Expected phc_locked=0 after deassert, got status=0x{status:08X}"

    tb.log.info("test_status_phc_locked_bit PASSED")
