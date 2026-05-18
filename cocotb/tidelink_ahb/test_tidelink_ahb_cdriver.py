"""Cocotb driver-in-the-loop tests for TideLink via compiled C driver.

Tests the actual compiled C TideLink driver (libtidelink_driver.so) against
the RTL simulation using the shadow buffer + snapshot-diff replay pattern.

Requires: make driver-so  (builds libtidelink_driver.so in this directory)

Usage:
    make MODULE=test_tidelink_ahb_cdriver
"""

import ctypes
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster, AHBLiteSlaveRAM

# HALBridge moved verbatim into the fpgahub SDK (Phase 7B) — byte-identical
# shadow-buffer/snapshot-diff replay algorithm, legacy ahb_read/ahb_write
# constructor preserved (see fpgahub_sdk.testkit). De-duplicated from the
# old copy-pasted cocotb/common/hal_bridge.py.
from fpgahub_sdk.testkit import HALBridge

# Add common directory to path (still needed for tidelink_regs_meta)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'common'))
import tidelink_regs_meta as meta

CLK_PERIOD_NS = 10

# ── Load C Driver ──────────────────────────────────────────────────────

_so_path = os.path.join(os.path.dirname(__file__), 'libtidelink_driver.so')
if not os.path.isfile(_so_path):
    raise FileNotFoundError(
        f"C driver shared library not found: {_so_path}\n"
        f"Run 'make driver-so' in cocotb/tidelink_ahb/ first."
    )
lib = ctypes.CDLL(_so_path)

# ── ctypes Struct Definitions ──────────────────────────────────────────


class TidelinkHandle(ctypes.Structure):
    """Mirrors tidelink_t: { TIDELINK_CFG_TypeDef *cfg; uint32_t *fifo; }"""
    _fields_ = [
        ("cfg", ctypes.c_void_p),
        ("fifo", ctypes.c_void_p),
    ]


# ── C Function Prototypes ──────────────────────────────────────────────

# Host-safe init (from tidelink_test_wrappers.c)
lib.tidelink_init_host.argtypes = [
    ctypes.POINTER(TidelinkHandle), ctypes.c_void_p, ctypes.c_void_p
]
lib.tidelink_init_host.restype = None

# tidelink.c functions
lib.tidelink_flush.argtypes = [ctypes.POINTER(TidelinkHandle)]
lib.tidelink_flush.restype = None

lib.tidelink_write_packet.argtypes = [
    ctypes.POINTER(TidelinkHandle), ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32
]
lib.tidelink_write_packet.restype = None

# Wrappers for inline functions
lib.tidelink_set_pair_base_wrap.argtypes = [
    ctypes.POINTER(TidelinkHandle), ctypes.c_uint32
]
lib.tidelink_set_pair_base_wrap.restype = None

lib.tidelink_get_pair_base_wrap.argtypes = [ctypes.POINTER(TidelinkHandle)]
lib.tidelink_get_pair_base_wrap.restype = ctypes.c_uint32

lib.tidelink_set_threshold_wrap.argtypes = [
    ctypes.POINTER(TidelinkHandle), ctypes.c_uint32
]
lib.tidelink_set_threshold_wrap.restype = None

lib.tidelink_get_status_wrap.argtypes = [ctypes.POINTER(TidelinkHandle)]
lib.tidelink_get_status_wrap.restype = ctypes.c_uint32

lib.tidelink_get_credit_count_wrap.argtypes = [ctypes.POINTER(TidelinkHandle)]
lib.tidelink_get_credit_count_wrap.restype = ctypes.c_uint32

lib.tidelink_doorbell_wrap.argtypes = [ctypes.POINTER(TidelinkHandle)]
lib.tidelink_doorbell_wrap.restype = None

lib.tidelink_set_pair_credit_en_wrap.argtypes = [
    ctypes.POINTER(TidelinkHandle), ctypes.c_uint32
]
lib.tidelink_set_pair_credit_en_wrap.restype = None


# ── Testbench Environment ──────────────────────────────────────────────

class TidelinkCDriverTB:
    """Testbench helper for C driver-in-the-loop TideLink tests."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        # Config register AHB master (via AHB-to-APB bridge)
        ahbc_bus = AHBBus.from_prefix(dut, "ahbc")
        self.ahb_cfg = AHBLiteMaster(
            ahbc_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # FIFO data AHB master
        ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
        self.ahb_fifo = AHBLiteMaster(
            ahbs_bus, dut.hclk, dut.hresetn, timeout=200
        )

        # Returner AHB slave RAM
        ahbm_bus = AHBBus.from_prefix(dut, "ahbm")
        self.ahb_slave = AHBLiteSlaveRAM(
            ahbm_bus, dut.hclk, dut.hresetn, mem_size=4096
        )

        # HAL bridge for config registers
        self.bridge = HALBridge(
            ahb_read=self._cfg_read,
            ahb_write=self._cfg_write,
            reg_size=meta.REG_SPACE_SIZE,
            rw_offsets=meta.RW_OFFSETS,
            ro_offsets=meta.RO_OFFSETS,
            trigger_offsets=meta.TRIGGER_OFFSETS,
        )

        # C driver handle
        self.tl = TidelinkHandle()
        # FIFO shadow buffer (16KB)
        self.fifo_buf = (ctypes.c_uint32 * 4096)()
        lib.tidelink_init_host(
            ctypes.byref(self.tl),
            self.bridge.base_addr,
            ctypes.addressof(self.fifo_buf),
        )

    async def _cfg_read(self, offset):
        resp = await self.ahb_cfg.read(offset)
        return int(resp[0].get("data", "0x0"), 16)

    async def _cfg_write(self, offset, data):
        await self.ahb_cfg.write(offset, data)

    async def reset(self):
        self.dut.hresetn.value = 0
        await ClockCycles(self.dut.hclk, 10)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 10)


# ══════════════════════════════════════════════════════════════════════════
# Tests
# ══════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_cdriver_01_credit_count_after_reset(dut):
    """CDRIVER-01: Read credit count via C driver after reset."""
    tb = TidelinkCDriverTB(dut)
    await tb.reset()

    await tb.bridge.pre_populate()
    credits = tb.bridge.buf[0x00C // 4]
    tb.log.info(f"Credit count after reset: {credits}")
    assert credits == 4096, f"Expected 4096 credits, got {credits}"


@cocotb.test()
async def test_cdriver_02_pair_base_readback(dut):
    """CDRIVER-02: Write pair base via C driver, read back via AHB."""
    tb = TidelinkCDriverTB(dut)
    await tb.reset()

    await tb.bridge.call_and_replay(
        lib.tidelink_set_pair_base_wrap, ctypes.byref(tb.tl), 0xDEAD0000
    )
    await ClockCycles(dut.hclk, 2)

    val = await tb._cfg_read(0x000)
    assert val == 0xDEAD0000, f"Expected 0xDEAD0000, got 0x{val:X}"


@cocotb.test()
async def test_cdriver_03_threshold_readback(dut):
    """CDRIVER-03: Write release threshold via C driver, verify default and new value."""
    tb = TidelinkCDriverTB(dut)
    await tb.reset()

    # Check default
    await tb.bridge.pre_populate()
    thresh = tb.bridge.buf[0x004 // 4]
    assert thresh == 20, f"Expected default threshold=20, got {thresh}"

    # Set new value
    await tb.bridge.call_and_replay(
        lib.tidelink_set_threshold_wrap, ctypes.byref(tb.tl), 100
    )
    await ClockCycles(dut.hclk, 2)

    val = await tb._cfg_read(0x004)
    assert val == 100, f"Expected threshold=100, got {val}"


@cocotb.test()
async def test_cdriver_04_status_register(dut):
    """CDRIVER-04: Read status register via C driver."""
    tb = TidelinkCDriverTB(dut)
    await tb.reset()

    await tb.bridge.pre_populate()
    status = tb.bridge.buf[0x010 // 4]
    tb.log.info(f"STATUS after reset: 0x{status:X}")
    # After reset, returner should not be busy, no errors
    assert (status & 0xF) == 0, f"Expected clean status, got 0x{status:X}"


@cocotb.test()
async def test_cdriver_05_pair_credit_enable(dut):
    """CDRIVER-05: Disable/enable pair credit counter via C driver."""
    tb = TidelinkCDriverTB(dut)
    await tb.reset()

    # Disable
    await tb.bridge.call_and_replay(
        lib.tidelink_set_pair_credit_en_wrap, ctypes.byref(tb.tl), 0
    )
    await ClockCycles(dut.hclk, 2)

    val = await tb._cfg_read(0x030)
    assert val == 0, f"Expected PAIR_CREDIT_EN=0, got {val}"

    # Re-enable
    await tb.bridge.call_and_replay(
        lib.tidelink_set_pair_credit_en_wrap, ctypes.byref(tb.tl), 1
    )
    await ClockCycles(dut.hclk, 2)

    val = await tb._cfg_read(0x030)
    assert val == 1, f"Expected PAIR_CREDIT_EN=1, got {val}"


@cocotb.test()
async def test_cdriver_06_flush(dut):
    """CDRIVER-06: Flush FIFO via C driver."""
    tb = TidelinkCDriverTB(dut)
    await tb.reset()

    # Flush writes CTRL=0 then CTRL=FLUSH_Msk (0x2)
    await tb.bridge.call_and_replay(
        lib.tidelink_flush, ctypes.byref(tb.tl)
    )
    await ClockCycles(dut.hclk, 5)

    # After flush, credits should be back to max
    val = await tb._cfg_read(0x00C)
    tb.log.info(f"Credits after flush: {val}")
    assert val == 4096, f"Expected 4096 credits after flush, got {val}"
