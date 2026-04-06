"""Cocotb driver-in-the-loop tests for TideLink perf via compiled C driver.

Placeholder -- requires a compiled libtidelink_perf_driver.so that exposes
perf register access functions. Follow the pattern in cocotb/tidelink_ahb/
(HALBridge + shadow buffer + snapshot-diff replay).

Requires: make driver-so  (builds libtidelink_perf_driver.so in this directory)

Usage:
    make MODULE=test_perf_cdriver
"""

import ctypes
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# ── Load C Driver (if available) ──────────────────────────────────────────

_so_path = os.path.join(os.path.dirname(__file__), 'libtidelink_perf_driver.so')
_driver_available = os.path.isfile(_so_path)

if _driver_available:
    lib = ctypes.CDLL(_so_path)
else:
    lib = None


# ── Testbench Environment ────────────────────────────────────────────────

class PerfCDriverTB:
    """Testbench helper for C driver-in-the-loop perf tests."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log
        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

    async def reset(self):
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 10)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 10)


# ══════════════════════════════════════════════════════════════════════════
# Placeholder Tests
# ══════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_cdriver_perf_01_driver_loads(dut):
    """CDRIVER-PERF-01: Verify the C driver shared library loads."""
    tb = PerfCDriverTB(dut)
    await tb.reset()

    if not _driver_available:
        tb.log.warning(
            f"C driver not found at {_so_path} -- "
            "run 'make driver-so' to build it. Skipping."
        )
        return

    tb.log.info("C driver loaded successfully")


@cocotb.test()
async def test_cdriver_perf_02_read_perf_id(dut):
    """CDRIVER-PERF-02: Read PERF_ID register via C driver."""
    tb = PerfCDriverTB(dut)
    await tb.reset()

    if not _driver_available:
        tb.log.warning("C driver not available -- skipping")
        return

    # TODO: Call C driver perf_read_id() and verify 0x50460100
    tb.log.info("Placeholder -- implement when C driver is available")
