"""
tidelink_clkfreq_check — verifies the local-vs-link clock frequency cross-check.

The module guards against the "wrong bitstream / mismatched clk_wiz" class of
mistake: each side compares its own link-TX clock against the recovered remote
link-RX clock. Matched frequency => per-window edge counts agree within
tolerance; a ~2:1 build mismatch => freq_mismatch_sticky latches.

Cases:
  - matched           : both 25 ns  -> freq_match=1, sticky=0
  - mismatch_2to1     : link 12.5ns, local 25ns (link 2x faster) -> sticky=1
  - mismatch_1to2     : link 50ns,  local 25ns (link 2x slower) -> sticky=1
  - ppm_drift_in_tol  : link 25.05ns vs local 25ns -> stays matched
  - link_down_no_alarm: link_up=0 -> no measurement, sticky stays 0

DUT params (tb_top): WINDOW_BITS=8 (256-cycle window), TOL_COUNTS=8.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, with_timeout

LOCAL_PERIOD_NS = 25.0
WINDOW_CYCLES = 256          # 2^WINDOW_BITS for tb_top default
WINDOWS_TO_OBSERVE = 4       # let several windows complete


class ClkFreqTB:
    def __init__(self, dut, link_period_ns):
        self.dut = dut
        self.log = dut._log
        cocotb.start_soon(Clock(dut.local_clk, LOCAL_PERIOD_NS, units="ns").start())
        cocotb.start_soon(Clock(dut.link_clk, link_period_ns, units="ns").start())

    async def reset(self, link_up=1):
        self.dut.local_rst_n.value = 0
        self.dut.link_rst_n.value = 0
        self.dut.link_up.value = 0
        await ClockCycles(self.dut.local_clk, 5)
        self.dut.local_rst_n.value = 1
        self.dut.link_rst_n.value = 1
        await ClockCycles(self.dut.local_clk, 5)
        self.dut.link_up.value = link_up
        await ClockCycles(self.dut.local_clk, 2)

    async def wait_measurements(self, n):
        """Wait for n measurement_valid pulses (with a generous timeout)."""
        seen = 0
        async def _count():
            nonlocal seen
            while seen < n:
                await RisingEdge(self.dut.local_clk)
                if int(self.dut.measurement_valid.value) == 1:
                    seen += 1
        # each window is WINDOW_CYCLES local cycles; give plenty of slack
        await with_timeout(_count(), (n + 2) * WINDOW_CYCLES * LOCAL_PERIOD_NS * 2, "ns")


@cocotb.test()
async def test_matched_frequency(dut):
    """Both clocks 25 ns -> match, no mismatch."""
    tb = ClkFreqTB(dut, link_period_ns=25.0)
    await tb.reset(link_up=1)
    await tb.wait_measurements(WINDOWS_TO_OBSERVE)

    assert int(dut.measured_once.value) == 1, "should have completed >=1 window"
    assert int(dut.freq_mismatch_sticky.value) == 0, \
        "matched clocks must not raise mismatch"
    assert int(dut.freq_match.value) == 1, "matched clocks must report freq_match"

    lwc = int(dut.local_window_count.value)
    kwc = int(dut.link_window_count.value)
    dut._log.info(f"matched: local={lwc} link={kwc}")
    assert abs(lwc - kwc) <= 8, f"window counts diverge: local={lwc} link={kwc}"


@cocotb.test()
async def test_mismatch_2to1(dut):
    """Link 2x faster (12.5 ns vs 25 ns) -> mismatch latches."""
    tb = ClkFreqTB(dut, link_period_ns=12.5)
    await tb.reset(link_up=1)
    await tb.wait_measurements(2)

    assert int(dut.freq_mismatch_sticky.value) == 1, \
        "2:1 fast link must latch mismatch"
    lwc = int(dut.local_window_count.value)
    kwc = int(dut.link_window_count.value)
    dut._log.info(f"2to1: local={lwc} link={kwc}")
    assert kwc > lwc, f"fast link should count more edges: local={lwc} link={kwc}"


@cocotb.test()
async def test_mismatch_1to2(dut):
    """Link 2x slower (50 ns vs 25 ns) -> mismatch latches."""
    tb = ClkFreqTB(dut, link_period_ns=50.0)
    await tb.reset(link_up=1)
    await tb.wait_measurements(2)

    assert int(dut.freq_mismatch_sticky.value) == 1, \
        "1:2 slow link must latch mismatch"
    lwc = int(dut.local_window_count.value)
    kwc = int(dut.link_window_count.value)
    dut._log.info(f"1to2: local={lwc} link={kwc}")
    assert kwc < lwc, f"slow link should count fewer edges: local={lwc} link={kwc}"


@cocotb.test()
async def test_ppm_drift_within_tol(dut):
    """Small drift (25.05 ns vs 25 ns, ~2000 ppm) stays within tolerance."""
    tb = ClkFreqTB(dut, link_period_ns=25.05)
    await tb.reset(link_up=1)
    await tb.wait_measurements(WINDOWS_TO_OBSERVE)

    assert int(dut.freq_mismatch_sticky.value) == 0, \
        "small ppm drift must not trip mismatch"
    assert int(dut.freq_match.value) == 1, "small drift should still match"


@cocotb.test()
async def test_link_down_no_false_alarm(dut):
    """link_up=0 -> module never measures, never false-alarms."""
    tb = ClkFreqTB(dut, link_period_ns=12.5)  # mismatched, but link held down
    await tb.reset(link_up=0)
    await ClockCycles(dut.local_clk, WINDOW_CYCLES * 3)

    assert int(dut.measured_once.value) == 0, \
        "no measurement should complete while link_up=0"
    assert int(dut.freq_mismatch_sticky.value) == 0, \
        "no false mismatch while link is down"
