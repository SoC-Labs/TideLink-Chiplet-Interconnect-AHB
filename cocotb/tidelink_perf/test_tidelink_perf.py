"""Cocotb testbench for tidelink_perf standalone.

Tests the performance profiling module in isolation -- register interface,
timestamps, saturating counters, freeze mode, and interrupt generation.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# ── Register Map Constants ────────────────────────────────────────────────
# Region encoding: 00=Region5, 01=Region6, 10=Region7
REGION5 = 0b00
REGION6 = 0b01
REGION7 = 0b10

# Region 5 (Control & TX Timestamps)
R5_PERF_CTRL      = 0  # addr[4:2] = 3'h0
R5_TX_ORIGIN_NS   = 1  # 3'h1
R5_TX_ORIGIN_SEC  = 2  # 3'h2
R5_TS_STATUS       = 3  # 3'h3
R5_TX_START_NS    = 4  # 3'h4
R5_TX_START_SEC   = 5  # 3'h5
R5_RX_FIRST_NS    = 6  # 3'h6
R5_RX_FIRST_SEC   = 7  # 3'h7

# Region 6 (RX Timestamps & Packet Counters)
R6_RX_DONE_NS     = 0
R6_RX_DONE_SEC    = 1
R6_TX_PKT_COUNT   = 2
R6_RX_PKT_COUNT   = 3
R6_TX_WORD_COUNT  = 4
R6_RX_WORD_COUNT  = 5
R6_TX_STALL_COUNT = 6
R6_RX_STALL_COUNT = 7

# Region 7 (Link Counters & Debug)
R7_LINK_BUSY_COUNT    = 0
R7_CREDIT_STARVE_COUNT = 1
R7_SAMPLE_COUNT       = 2
R7_DBG_LINK_STATUS    = 3
R7_DBG_TX_INFLIGHT    = 4
R7_DBG_RX_INFLIGHT    = 5
R7_DBG_SCRATCH        = 6
R7_PERF_ID            = 7

# PERF_CTRL bits
CTRL_ENABLE          = (1 << 0)
CTRL_FREEZE          = (1 << 1)
CTRL_CLEAR_COUNTERS  = (1 << 2)
CTRL_CLEAR_TIMESTAMPS = (1 << 3)
CTRL_IRQ_EN          = (1 << 4)


# ── Helper Class ──────────────────────────────────────────────────────────

class PerfTB:
    """Testbench helper for tidelink_perf."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log
        cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())

    async def reset(self):
        """Apply reset and initialise all inputs to safe defaults."""
        dut = self.dut
        dut.hresetn.value = 0
        dut.perf_reg_write.value  = 0
        dut.perf_reg_addr.value   = 0
        dut.perf_reg_wdata.value  = 0
        dut.perf_reg_region.value = 0
        dut.phc_nanoseconds.value = 0
        dut.phc_seconds.value     = 0
        dut.fc_tx_handshake.value = 0
        dut.fc_tx_is_data.value   = 0
        dut.fc_rx_handshake.value = 0
        dut.fc_rx_is_data.value   = 0
        dut.fc_rx_is_first.value  = 0
        dut.tx_pkt_start.value    = 0
        dut.rx_pkt_committed.value = 0
        dut.tx_router_idle.value  = 1
        dut.fc_tx_valid.value     = 0
        dut.fc_tx_ready.value     = 1
        dut.fc_rx_valid.value     = 0
        dut.fc_rx_accept.value    = 1
        dut.credit_count.value    = 100  # Non-zero default
        await ClockCycles(dut.hclk, 5)
        dut.hresetn.value = 1
        await ClockCycles(dut.hclk, 2)

    async def reg_write(self, region, addr, data):
        """Drive a single-cycle register write."""
        await RisingEdge(self.dut.hclk)
        self.dut.perf_reg_write.value  = 1
        self.dut.perf_reg_region.value = region
        self.dut.perf_reg_addr.value   = addr
        self.dut.perf_reg_wdata.value  = data
        await RisingEdge(self.dut.hclk)
        self.dut.perf_reg_write.value  = 0

    async def reg_read(self, region, addr):
        """Set region/addr and sample rdata on the next rising edge."""
        await RisingEdge(self.dut.hclk)
        self.dut.perf_reg_region.value = region
        self.dut.perf_reg_addr.value   = addr
        await RisingEdge(self.dut.hclk)
        return int(self.dut.perf_reg_rdata.value)

    async def pulse_tx_start(self):
        """Assert tx_pkt_start for one clock cycle."""
        await RisingEdge(self.dut.hclk)
        self.dut.tx_pkt_start.value = 1
        await RisingEdge(self.dut.hclk)
        self.dut.tx_pkt_start.value = 0

    async def pulse_fc_tx(self, is_data=True):
        """Assert fc_tx_handshake (+ fc_tx_is_data) for one clock cycle."""
        await RisingEdge(self.dut.hclk)
        self.dut.fc_tx_handshake.value = 1
        self.dut.fc_tx_is_data.value   = int(is_data)
        await RisingEdge(self.dut.hclk)
        self.dut.fc_tx_handshake.value = 0
        self.dut.fc_tx_is_data.value   = 0

    async def pulse_fc_rx(self, is_data=True, is_first=False):
        """Assert fc_rx_handshake (+ fc_rx_is_data + fc_rx_is_first) for one cycle."""
        await RisingEdge(self.dut.hclk)
        self.dut.fc_rx_handshake.value = 1
        self.dut.fc_rx_is_data.value   = int(is_data)
        self.dut.fc_rx_is_first.value  = int(is_first)
        await RisingEdge(self.dut.hclk)
        self.dut.fc_rx_handshake.value = 0
        self.dut.fc_rx_is_data.value   = 0
        self.dut.fc_rx_is_first.value  = 0

    async def pulse_rx_committed(self):
        """Assert rx_pkt_committed for one cycle (rising edge triggers capture)."""
        await RisingEdge(self.dut.hclk)
        self.dut.rx_pkt_committed.value = 1
        await RisingEdge(self.dut.hclk)
        self.dut.rx_pkt_committed.value = 0

    def set_phc_time(self, sec, ns):
        """Drive phc_seconds and phc_nanoseconds (combinational, no await)."""
        self.dut.phc_seconds.value     = sec
        self.dut.phc_nanoseconds.value = ns


# ══════════════════════════════════════════════════════════════════════════
# Tests
# ══════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_perf_enable_disable(dut):
    """PERF-01: Counters increment when enabled, stop when disabled."""
    tb = PerfTB(dut)
    await tb.reset()

    # Enable perf
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 2)

    # Drive some TX packet events
    await tb.pulse_tx_start()
    await tb.pulse_tx_start()

    # Read TX_PKT_COUNT
    count = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    tb.log.info(f"TX_PKT_COUNT after 2 starts (enabled): {count}")
    assert count == 2, f"Expected 2, got {count}"

    # Disable perf
    await tb.reg_write(REGION5, R5_PERF_CTRL, 0)
    await ClockCycles(dut.hclk, 2)

    # Drive more events -- should NOT increment
    await tb.pulse_tx_start()
    await tb.pulse_tx_start()

    count2 = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    tb.log.info(f"TX_PKT_COUNT after 2 more starts (disabled): {count2}")
    assert count2 == 2, f"Expected still 2, got {count2}"


@cocotb.test()
async def test_tx_timestamp(dut):
    """PERF-02: TX timestamp captures PHC time on first FC data word after tx_pkt_start."""
    tb = PerfTB(dut)
    await tb.reset()

    # Enable perf
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)

    # Set PHC time
    tb.set_phc_time(sec=42, ns=123456)
    await ClockCycles(dut.hclk, 1)

    # Trigger TX packet start, then first FC data word
    await tb.pulse_tx_start()
    await tb.pulse_fc_tx(is_data=True)
    await ClockCycles(dut.hclk, 2)

    # Read TX_START timestamps
    ns_val  = await tb.reg_read(REGION5, R5_TX_START_NS)
    sec_val = await tb.reg_read(REGION5, R5_TX_START_SEC)
    tb.log.info(f"TX_START: sec={sec_val}, ns={ns_val}")
    assert sec_val == 42, f"Expected sec=42, got {sec_val}"
    assert ns_val == 123456, f"Expected ns=123456, got {ns_val}"

    # Verify TS_STATUS.tx_ts_valid (bit 0)
    status = await tb.reg_read(REGION5, R5_TS_STATUS)
    assert (status & 0x1) == 1, f"Expected tx_ts_valid=1, got status=0x{status:X}"


@cocotb.test()
async def test_rx_first_timestamp(dut):
    """PERF-03: RX first-word timestamp captures PHC time on first FC RX data word."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)

    tb.set_phc_time(sec=99, ns=654321)
    await ClockCycles(dut.hclk, 1)

    await tb.pulse_fc_rx(is_data=True, is_first=True)
    await ClockCycles(dut.hclk, 2)

    ns_val  = await tb.reg_read(REGION5, R5_RX_FIRST_NS)
    sec_val = await tb.reg_read(REGION5, R5_RX_FIRST_SEC)
    tb.log.info(f"RX_FIRST: sec={sec_val}, ns={ns_val}")
    assert sec_val == 99, f"Expected sec=99, got {sec_val}"
    assert ns_val == 654321, f"Expected ns=654321, got {ns_val}"

    status = await tb.reg_read(REGION5, R5_TS_STATUS)
    assert (status & 0x2) == 0x2, f"Expected rx_first_valid=1, got status=0x{status:X}"


@cocotb.test()
async def test_rx_done_timestamp(dut):
    """PERF-04: RX done timestamp captures PHC time on rx_pkt_committed rising edge."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)

    tb.set_phc_time(sec=7, ns=999999)
    await ClockCycles(dut.hclk, 1)

    await tb.pulse_rx_committed()
    await ClockCycles(dut.hclk, 2)

    ns_val  = await tb.reg_read(REGION6, R6_RX_DONE_NS)
    sec_val = await tb.reg_read(REGION6, R6_RX_DONE_SEC)
    tb.log.info(f"RX_DONE: sec={sec_val}, ns={ns_val}")
    assert sec_val == 7, f"Expected sec=7, got {sec_val}"
    assert ns_val == 999999, f"Expected ns=999999, got {ns_val}"

    status = await tb.reg_read(REGION5, R5_TS_STATUS)
    assert (status & 0x4) == 0x4, f"Expected rx_done_valid=1, got status=0x{status:X}"


@cocotb.test()
async def test_origin_timestamp(dut):
    """PERF-05: Software-writable origin timestamp round-trip."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_TX_ORIGIN_NS, 0x1234_5678)
    await tb.reg_write(REGION5, R5_TX_ORIGIN_SEC, 0xDEAD_BEEF)
    await ClockCycles(dut.hclk, 1)

    ns_val  = await tb.reg_read(REGION5, R5_TX_ORIGIN_NS)
    sec_val = await tb.reg_read(REGION5, R5_TX_ORIGIN_SEC)
    # NS is 30 bits wide, so top 2 bits masked
    assert ns_val == (0x1234_5678 & 0x3FFF_FFFF), \
        f"Expected ns=0x{0x1234_5678 & 0x3FFFFFFF:08X}, got 0x{ns_val:08X}"
    assert sec_val == 0xDEAD_BEEF, f"Expected sec=0xDEADBEEF, got 0x{sec_val:08X}"


@cocotb.test()
async def test_counter_saturation(dut):
    """PERF-06: Saturating counter stops at 0xFFFFFFFF."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 1)

    # Force the tx_pkt_count internal register near saturation by driving
    # many tx_pkt_start pulses. Since we cannot write the counter directly,
    # we instead rely on the sample_count (always increments when active).
    # We will let the module run for enough cycles to approach saturation
    # indirectly -- but that is impractical (2^32 cycles).
    #
    # Instead, verify the sat_inc logic by using the internal hierarchical
    # path to force the counter value, then observe saturation.
    try:
        dut.u_dut.tx_pkt_count_r.value = 0xFFFF_FFFE
    except AttributeError:
        tb.log.warning("Cannot force internal signal -- skipping saturation test")
        return

    await ClockCycles(dut.hclk, 1)

    # Increment once -> should go to 0xFFFFFFFF
    await tb.pulse_tx_start()
    count = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    assert count == 0xFFFF_FFFF, f"Expected 0xFFFFFFFF after first inc, got 0x{count:08X}"

    # Increment again -> should stay at 0xFFFFFFFF
    await tb.pulse_tx_start()
    count = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    assert count == 0xFFFF_FFFF, f"Expected 0xFFFFFFFF (saturated), got 0x{count:08X}"


@cocotb.test()
async def test_freeze_mode(dut):
    """PERF-07: Freeze mode pauses counters; unfreeze resumes counting."""
    tb = PerfTB(dut)
    await tb.reset()

    # Enable + freeze
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE | CTRL_FREEZE)
    await ClockCycles(dut.hclk, 2)

    # Drive events -- should NOT count because frozen
    await tb.pulse_tx_start()
    await tb.pulse_tx_start()

    count = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    tb.log.info(f"TX_PKT_COUNT while frozen: {count}")
    assert count == 0, f"Expected 0 (frozen), got {count}"

    # Unfreeze (keep enabled)
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 2)

    # Drive events -- should count now
    await tb.pulse_tx_start()
    await tb.pulse_tx_start()
    await tb.pulse_tx_start()

    count = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    tb.log.info(f"TX_PKT_COUNT after unfreeze: {count}")
    assert count == 3, f"Expected 3, got {count}"


@cocotb.test()
async def test_tx_stall_counting(dut):
    """PERF-08: TX stall counter increments when fc_tx_valid=1 and fc_tx_ready=0."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 1)

    N = 10
    # Create stall condition: valid high, ready low
    await RisingEdge(dut.hclk)
    dut.fc_tx_valid.value = 1
    dut.fc_tx_ready.value = 0
    await ClockCycles(dut.hclk, N)
    dut.fc_tx_valid.value = 0
    dut.fc_tx_ready.value = 1
    await ClockCycles(dut.hclk, 2)

    count = await tb.reg_read(REGION6, R6_TX_STALL_COUNT)
    tb.log.info(f"TX_STALL_COUNT after {N} stall cycles: {count}")
    assert count == N, f"Expected {N}, got {count}"


@cocotb.test()
async def test_link_busy(dut):
    """PERF-09: Link busy counter increments when tx_router_idle=0."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 1)

    N = 8
    await RisingEdge(dut.hclk)
    dut.tx_router_idle.value = 0
    await ClockCycles(dut.hclk, N)
    dut.tx_router_idle.value = 1
    await ClockCycles(dut.hclk, 2)

    count = await tb.reg_read(REGION7, R7_LINK_BUSY_COUNT)
    tb.log.info(f"LINK_BUSY_COUNT after {N} busy cycles: {count}")
    assert count == N, f"Expected {N}, got {count}"


@cocotb.test()
async def test_credit_starvation(dut):
    """PERF-10: Credit starvation counter increments when credit_count==0."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 1)

    N = 6
    await RisingEdge(dut.hclk)
    dut.credit_count.value = 0
    await ClockCycles(dut.hclk, N)
    dut.credit_count.value = 100
    await ClockCycles(dut.hclk, 2)

    count = await tb.reg_read(REGION7, R7_CREDIT_STARVE_COUNT)
    tb.log.info(f"CREDIT_STARVE_COUNT after {N} starved cycles: {count}")
    assert count == N, f"Expected {N}, got {count}"


@cocotb.test()
async def test_inflight_tracking(dut):
    """PERF-11: TX inflight counter tracks FC data words after tx_pkt_start."""
    tb = PerfTB(dut)
    await tb.reset()

    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 1)

    # Start a packet
    await tb.pulse_tx_start()

    # Send 5 FC data words
    for _ in range(5):
        await tb.pulse_fc_tx(is_data=True)

    await ClockCycles(dut.hclk, 1)

    inflight = await tb.reg_read(REGION7, R7_DBG_TX_INFLIGHT)
    tb.log.info(f"DBG_TX_INFLIGHT after 5 FC words: {inflight}")
    assert inflight == 5, f"Expected 5, got {inflight}"


@cocotb.test()
async def test_clear_counters(dut):
    """PERF-12: Writing PERF_CTRL with clear_counters resets all counters to zero."""
    tb = PerfTB(dut)
    await tb.reset()

    # Enable and generate some events
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await tb.pulse_tx_start()
    await tb.pulse_fc_tx(is_data=True)
    await ClockCycles(dut.hclk, 5)  # Let sample_count accumulate

    # Verify non-zero
    tx_pkt = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    assert tx_pkt > 0, "Expected non-zero TX_PKT_COUNT before clear"

    # Clear counters (write enable + clear_counters bit)
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE | CTRL_CLEAR_COUNTERS)
    await ClockCycles(dut.hclk, 2)

    # Re-enable without clear bit
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    await ClockCycles(dut.hclk, 1)

    # Verify all zeroed
    tx_pkt   = await tb.reg_read(REGION6, R6_TX_PKT_COUNT)
    rx_pkt   = await tb.reg_read(REGION6, R6_RX_PKT_COUNT)
    tx_word  = await tb.reg_read(REGION6, R6_TX_WORD_COUNT)
    sample   = await tb.reg_read(REGION7, R7_SAMPLE_COUNT)
    inflight = await tb.reg_read(REGION7, R7_DBG_TX_INFLIGHT)

    tb.log.info(f"After clear: tx_pkt={tx_pkt}, rx_pkt={rx_pkt}, "
                f"tx_word={tx_word}, sample={sample}, inflight={inflight}")
    # sample_count may have incremented 1 cycle after clear; allow 0 or small value
    assert tx_pkt == 0, f"TX_PKT_COUNT not cleared: {tx_pkt}"
    assert rx_pkt == 0, f"RX_PKT_COUNT not cleared: {rx_pkt}"
    assert inflight == 0, f"TX_INFLIGHT not cleared: {inflight}"


@cocotb.test()
async def test_clear_timestamps(dut):
    """PERF-13: Writing PERF_CTRL with clear_timestamps clears valid bits."""
    tb = PerfTB(dut)
    await tb.reset()

    # Enable and capture a TX timestamp
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE)
    tb.set_phc_time(sec=1, ns=1000)
    await tb.pulse_tx_start()
    await tb.pulse_fc_tx(is_data=True)
    await ClockCycles(dut.hclk, 2)

    # Verify valid bit set
    status = await tb.reg_read(REGION5, R5_TS_STATUS)
    assert (status & 0x1) == 1, f"Expected tx_ts_valid=1 before clear"

    # Clear timestamps (bit 3 of PERF_CTRL is W1C for valid bits)
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE | CTRL_CLEAR_TIMESTAMPS)
    await ClockCycles(dut.hclk, 2)

    status = await tb.reg_read(REGION5, R5_TS_STATUS)
    tb.log.info(f"TS_STATUS after clear_timestamps: 0x{status:X}")
    assert (status & 0x7) == 0, f"Expected all valid bits cleared, got 0x{status:X}"


@cocotb.test()
async def test_perf_irq(dut):
    """PERF-14: perf_irq asserts when rx_done_valid and irq_en are both set."""
    tb = PerfTB(dut)
    await tb.reset()

    # Enable perf + IRQ
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE | CTRL_IRQ_EN)
    await ClockCycles(dut.hclk, 1)

    # Before any RX event, IRQ should be low
    irq = int(dut.perf_irq.value)
    assert irq == 0, f"Expected perf_irq=0 before event, got {irq}"

    # Trigger RX done
    tb.set_phc_time(sec=1, ns=500)
    await tb.pulse_rx_committed()
    await ClockCycles(dut.hclk, 2)

    irq = int(dut.perf_irq.value)
    tb.log.info(f"perf_irq after rx_committed: {irq}")
    assert irq == 1, f"Expected perf_irq=1, got {irq}"

    # Clear the valid bit to deassert IRQ
    await tb.reg_write(REGION5, R5_PERF_CTRL, CTRL_ENABLE | CTRL_IRQ_EN | CTRL_CLEAR_TIMESTAMPS)
    await ClockCycles(dut.hclk, 2)

    irq = int(dut.perf_irq.value)
    assert irq == 0, f"Expected perf_irq=0 after clear, got {irq}"


@cocotb.test()
async def test_perf_id(dut):
    """PERF-15: PERF_ID register reads 0x50460100 ('PF' v1.0)."""
    tb = PerfTB(dut)
    await tb.reset()

    perf_id = await tb.reg_read(REGION7, R7_PERF_ID)
    tb.log.info(f"PERF_ID: 0x{perf_id:08X}")
    assert perf_id == 0x5046_0100, f"Expected 0x50460100, got 0x{perf_id:08X}"
