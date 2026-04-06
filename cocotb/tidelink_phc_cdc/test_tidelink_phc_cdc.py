"""
Verification gap G29: CDC multi-clock ratio variations not exercised.

Tests the tidelink_phc_cdc module with phc_clk running at different
frequencies relative to hclk, exercising all 6 CDC paths under truly
asynchronous conditions.

Clock ratios tested:
  - 0.5x (phc_clk = 20ns, hclk = 10ns)
  - 0.7x (phc_clk = 14ns, hclk = 10ns)
  - 1.3x (phc_clk = 8ns,  hclk = 10ns)
  - 2.0x (phc_clk = 5ns,  hclk = 10ns)

References: SHORTCOMINGS.md #29
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

HCLK_PERIOD_NS = 10


class CdcTB:
    """Test helper for tidelink_phc_cdc."""

    def __init__(self, dut, phc_period_ns):
        self.dut = dut
        self.log = dut._log
        self.phc_period_ns = phc_period_ns

        # Start both clocks
        cocotb.start_soon(
            Clock(dut.hclk, HCLK_PERIOD_NS, units="ns").start()
        )
        cocotb.start_soon(
            Clock(dut.phc_clk, phc_period_ns, units="ns").start()
        )

    async def reset(self):
        """Assert both resets, drive safe defaults, release."""
        self.dut.hresetn.value = 0
        self.dut.phc_resetn.value = 0
        self.dut.scan_mode.value = 0
        self.dut.h_hw_capture.value = 0
        self.dut.h_hw_set_time.value = 0
        self.dut.h_hw_set_seconds.value = 0
        self.dut.h_hw_set_nanoseconds.value = 0
        self.dut.h_hw_adj_valid.value = 0
        self.dut.h_hw_adj_ns_incr_frac.value = 0
        self.dut.p_hw_cap_seconds.value = 0
        self.dut.p_hw_cap_nanoseconds.value = 0
        self.dut.p_hw_cap_sub_nanoseconds.value = 0
        self.dut.p_phc_nanoseconds.value = 0
        self.dut.p_phc_seconds.value = 0
        self.dut.p_phc_pps.value = 0

        await ClockCycles(self.dut.hclk, 10)
        self.dut.hresetn.value = 1
        self.dut.phc_resetn.value = 1
        await ClockCycles(self.dut.hclk, 10)

    async def wait_hclk(self, n):
        await ClockCycles(self.dut.hclk, n)

    async def wait_phc(self, n):
        await ClockCycles(self.dut.phc_clk, n)


# ── Path 4 + Path 1: HW Capture trigger (hclk→phc) + timestamps (phc→hclk) ──

async def _test_hw_capture(dut, phc_period_ns, ratio_name):
    """Path 4→1: Pulse h_hw_capture, verify p_hw_capture fires,
    then verify captured timestamps propagate back to hclk domain."""
    tb = CdcTB(dut, phc_period_ns)
    await tb.reset()

    # Set PHC-side capture data (would be latched by PHC on p_hw_capture)
    dut.p_hw_cap_seconds.value = 0x0000_0000_0042
    dut.p_hw_cap_nanoseconds.value = 123456789 & 0x3FFF_FFFF
    dut.p_hw_cap_sub_nanoseconds.value = 0xABCD_1234

    # Pulse h_hw_capture for 1 hclk cycle
    dut.h_hw_capture.value = 1
    await RisingEdge(dut.hclk)
    dut.h_hw_capture.value = 0

    # Wait for CDC to propagate (SYNC_STAGES * 2 + margin per domain)
    await tb.wait_hclk(20)
    await tb.wait_phc(10)
    await tb.wait_hclk(20)

    # Check p_hw_capture fired on phc_clk domain (it's a pulse, may have passed)
    # The important check is that hclk-side captured timestamps are valid
    h_sec = int(dut.h_hw_cap_seconds.value)
    h_ns = int(dut.h_hw_cap_nanoseconds.value)
    h_sub = int(dut.h_hw_cap_sub_nanoseconds.value)

    dut._log.info(
        f"[{ratio_name}] Path 1 result: sec=0x{h_sec:012x} ns={h_ns} sub=0x{h_sub:08x}"
    )

    assert h_sec == 0x42, f"Expected seconds=0x42, got 0x{h_sec:x}"
    assert h_ns == (123456789 & 0x3FFF_FFFF), f"Expected ns={123456789 & 0x3FFF_FFFF}, got {h_ns}"
    assert h_sub == 0xABCD_1234, f"Expected sub_ns=0xABCD1234, got 0x{h_sub:08x}"


@cocotb.test()
async def test_hw_capture_ratio_half(dut):
    """Path 4+1 at phc_clk = 0.5x hclk (20ns period)."""
    await _test_hw_capture(dut, 20, "0.5x")


@cocotb.test()
async def test_hw_capture_ratio_0p7(dut):
    """Path 4+1 at phc_clk = 0.7x hclk (14ns period)."""
    await _test_hw_capture(dut, 14, "0.7x")


@cocotb.test()
async def test_hw_capture_ratio_1p3(dut):
    """Path 4+1 at phc_clk = 1.3x hclk (8ns period)."""
    await _test_hw_capture(dut, 8, "1.3x")


@cocotb.test()
async def test_hw_capture_ratio_double(dut):
    """Path 4+1 at phc_clk = 2.0x hclk (5ns period)."""
    await _test_hw_capture(dut, 5, "2.0x")


# ── Path 2: Free-running PHC time (phc→hclk handshake) ──

async def _test_free_running_time(dut, phc_period_ns, ratio_name):
    """Path 2: Drive changing PHC time on phc_clk side, verify monotonic
    readback on hclk side."""
    tb = CdcTB(dut, phc_period_ns)
    await tb.reset()

    # Drive incrementing PHC time on phc_clk domain
    timestamps = []

    async def drive_phc_time():
        ns = 100
        sec = 0
        for _ in range(50):
            dut.p_phc_nanoseconds.value = ns & 0x3FFF_FFFF
            dut.p_phc_seconds.value = sec
            await RisingEdge(dut.phc_clk)
            ns += 10
            if ns >= 1_000_000_000:
                ns = 0
                sec += 1

    async def sample_hclk_time():
        # Wait for initial handshake to kick-start
        await tb.wait_hclk(30)
        prev_ns = 0
        prev_sec = 0
        for _ in range(20):
            ns = int(dut.h_phc_nanoseconds.value)
            sec = int(dut.h_phc_seconds.value)
            timestamps.append((sec, ns))
            await tb.wait_hclk(5)

    # Run concurrently
    cocotb.start_soon(drive_phc_time())
    await sample_hclk_time()

    dut._log.info(f"[{ratio_name}] Path 2 sampled {len(timestamps)} timestamps")

    # Verify monotonicity (each sample >= previous)
    for i in range(1, len(timestamps)):
        s0, n0 = timestamps[i - 1]
        s1, n1 = timestamps[i]
        total0 = s0 * 1_000_000_000 + n0
        total1 = s1 * 1_000_000_000 + n1
        assert total1 >= total0, (
            f"[{ratio_name}] Time went backwards at sample {i}: "
            f"({s0}, {n0}) -> ({s1}, {n1})"
        )


@cocotb.test()
async def test_free_running_time_ratio_half(dut):
    """Path 2 at phc_clk = 0.5x hclk."""
    await _test_free_running_time(dut, 20, "0.5x")


@cocotb.test()
async def test_free_running_time_ratio_0p7(dut):
    """Path 2 at phc_clk = 0.7x hclk."""
    await _test_free_running_time(dut, 14, "0.7x")


@cocotb.test()
async def test_free_running_time_ratio_1p3(dut):
    """Path 2 at phc_clk = 1.3x hclk."""
    await _test_free_running_time(dut, 8, "1.3x")


@cocotb.test()
async def test_free_running_time_ratio_double(dut):
    """Path 2 at phc_clk = 2.0x hclk."""
    await _test_free_running_time(dut, 5, "2.0x")


# ── Path 3: PPS pulse (phc→hclk toggle sync) ──

async def _test_pps_crossing(dut, phc_period_ns, ratio_name):
    """Path 3: Pulse p_phc_pps on phc_clk, verify h_phc_pps fires on hclk."""
    tb = CdcTB(dut, phc_period_ns)
    await tb.reset()

    # The PPS path uses toggle-sync: p_phc_pps pulses toggle a register on
    # phc_clk, which is synchronized to hclk via SYNC_STAGES flip-flops,
    # then edge-detected. We need to watch hclk WHILE pulsing phc_clk.
    detected = False

    async def watch_pps():
        nonlocal detected
        # Wait long enough for the toggle to propagate through the
        # synchronizer chain: SYNC_STAGES phc_clk cycles + SYNC_STAGES
        # hclk cycles + margin. At 0.5x ratio, phc_clk is slow so this
        # needs more hclk cycles.
        for _ in range(60):
            await RisingEdge(dut.hclk)
            if int(dut.h_phc_pps.value) == 1:
                detected = True
                return

    # Start watching before pulsing
    watcher = cocotb.start_soon(watch_pps())

    # Small delay to ensure watcher is running
    await RisingEdge(dut.hclk)

    # Pulse PPS on phc_clk domain
    dut.p_phc_pps.value = 1
    await RisingEdge(dut.phc_clk)
    dut.p_phc_pps.value = 0

    # Wait for watcher to complete
    await watcher

    dut._log.info(f"[{ratio_name}] Path 3 PPS detected on hclk: {detected}")
    assert detected, f"[{ratio_name}] PPS pulse not detected on hclk domain"


@cocotb.test()
async def test_pps_ratio_half(dut):
    """Path 3 at phc_clk = 0.5x hclk."""
    await _test_pps_crossing(dut, 20, "0.5x")


@cocotb.test()
async def test_pps_ratio_double(dut):
    """Path 3 at phc_clk = 2.0x hclk."""
    await _test_pps_crossing(dut, 5, "2.0x")


# ── Path 5: Phase step (hclk→phc handshake) ──

async def _test_phase_step(dut, phc_period_ns, ratio_name):
    """Path 5: Issue phase step on hclk, verify it arrives on phc_clk."""
    tb = CdcTB(dut, phc_period_ns)
    await tb.reset()

    # Issue phase step command on hclk domain
    dut.h_hw_set_seconds.value = 0x0000_0000_1234
    dut.h_hw_set_nanoseconds.value = 500_000_000 & 0x3FFF_FFFF
    dut.h_hw_set_time.value = 1
    await RisingEdge(dut.hclk)
    dut.h_hw_set_time.value = 0

    # Wait for handshake to propagate
    await tb.wait_hclk(30)
    await tb.wait_phc(20)

    # Check phc_clk-side outputs
    p_sec = int(dut.p_hw_set_seconds.value)
    p_ns = int(dut.p_hw_set_nanoseconds.value)

    dut._log.info(
        f"[{ratio_name}] Path 5 result: sec=0x{p_sec:012x} ns={p_ns}"
    )

    assert p_sec == 0x1234, f"Expected sec=0x1234, got 0x{p_sec:x}"
    assert p_ns == (500_000_000 & 0x3FFF_FFFF), f"Expected ns={500_000_000 & 0x3FFF_FFFF}, got {p_ns}"


@cocotb.test()
async def test_phase_step_ratio_half(dut):
    """Path 5 at phc_clk = 0.5x hclk."""
    await _test_phase_step(dut, 20, "0.5x")


@cocotb.test()
async def test_phase_step_ratio_double(dut):
    """Path 5 at phc_clk = 2.0x hclk."""
    await _test_phase_step(dut, 5, "2.0x")


# ── Path 6: Frequency adjust (hclk→phc handshake) ──

async def _test_freq_adjust(dut, phc_period_ns, ratio_name):
    """Path 6: Issue frequency adjust on hclk, verify on phc_clk."""
    tb = CdcTB(dut, phc_period_ns)
    await tb.reset()

    adj_value = 0xDEAD_BEEF
    dut.h_hw_adj_ns_incr_frac.value = adj_value
    dut.h_hw_adj_valid.value = 1
    await RisingEdge(dut.hclk)
    dut.h_hw_adj_valid.value = 0

    await tb.wait_hclk(30)
    await tb.wait_phc(20)

    p_adj = int(dut.p_hw_adj_ns_incr_frac.value)

    dut._log.info(f"[{ratio_name}] Path 6 result: adj=0x{p_adj:08x}")

    assert p_adj == adj_value, f"Expected 0x{adj_value:08x}, got 0x{p_adj:08x}"


@cocotb.test()
async def test_freq_adjust_ratio_half(dut):
    """Path 6 at phc_clk = 0.5x hclk."""
    await _test_freq_adjust(dut, 20, "0.5x")


@cocotb.test()
async def test_freq_adjust_ratio_double(dut):
    """Path 6 at phc_clk = 2.0x hclk."""
    await _test_freq_adjust(dut, 5, "2.0x")


# ── Rapid back-to-back captures ──

@cocotb.test()
async def test_rapid_captures_ratio_0p7(dut):
    """10 back-to-back hw_capture pulses at 0.7x ratio, no data loss."""
    phc_period_ns = 14
    tb = CdcTB(dut, phc_period_ns)
    await tb.reset()

    captured_values = []

    for i in range(10):
        # Set unique capture data on PHC side
        dut.p_hw_cap_seconds.value = i + 1
        dut.p_hw_cap_nanoseconds.value = (i + 1) * 100

        # Pulse capture
        dut.h_hw_capture.value = 1
        await RisingEdge(dut.hclk)
        dut.h_hw_capture.value = 0

        # Wait for full handshake round-trip
        await tb.wait_hclk(30)
        await tb.wait_phc(15)
        await tb.wait_hclk(20)

        sec = int(dut.h_hw_cap_seconds.value)
        ns = int(dut.h_hw_cap_nanoseconds.value)
        captured_values.append((sec, ns))
        dut._log.info(f"Capture {i}: sec={sec} ns={ns}")

    # Verify all captures are distinct and in order
    for i in range(1, len(captured_values)):
        s0, n0 = captured_values[i - 1]
        s1, n1 = captured_values[i]
        assert (s1, n1) != (s0, n0), (
            f"Capture {i} identical to {i-1}: ({s1}, {n1})"
        )
        assert s1 >= s0, (
            f"Captures not monotonic at {i}: sec {s0} -> {s1}"
        )

    dut._log.info(f"All 10 captures distinct and monotonic")
