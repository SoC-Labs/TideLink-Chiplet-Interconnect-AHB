#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - cocotb AHBLiteMaster Shim for PYNQ MMIO
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Adapter that lets existing cocotb test suites run on a real PYNQ-Z2 board
# without modification. Reproduces the subset of the cocotbext.ahb.AHBLiteMaster
# API used by TideLink tests:
#
#   await master.write(addr, val)
#   await master.read(addr, nbytes)  ->  [{'data': '0xXXXXXXXX'}]
#
# Both methods are async so existing `await` call sites work unchanged.
#
# Provides:
#   MmioAhbShim  — wraps pynq.MMIO (or BareMMIO) with the AHBLiteMaster API
#   HwDut        — no-op stub for the cocotb `dut` object
#   HwTB         — TB stub wired to TidelinkOverlay apertures; used by Wave C3
#
# AHB slave mapping (from tidelink_design.tcl):
#   config_apb_master  -> overlay.apb      (0x4403_0000, 32 KB)
#   tx_ahb_master      -> overlay.ahb_tx   (0x4400_0000, 64 KB)
#   fifo_ahb_master    -> overlay.ahb_fifo (0x4401_0000, 64 KB)
#   ptp_ahb_master     -> overlay.ahb_ptp  (0x4402_0000,  4 KB)
#-----------------------------------------------------------------------------

import asyncio
import logging
import time


POLL_TIMEOUT_S = 5.0


class MmioAhbShim:
    """Drop-in replacement for cocotbext.ahb.AHBLiteMaster.

    Wraps a pynq.MMIO (or BareMMIO) instance. All accesses are 32-bit aligned.
    The cocotb ``nbytes`` argument is honoured for sub-word reads by masking;
    all TideLink register accesses are 32-bit wide.

    Deviations from AHBLiteMaster:
    - No burst support; every call is a single word transaction.
    - ``write()`` ignores ``size`` / ``pip`` kwargs (not used in TideLink tests).
    - Return value of ``read()`` is a list with one dict; AHBLiteMaster returns
      a list with one entry per beat — TideLink tests only send single-beat
      transactions so the shapes match.
    """

    def __init__(self, mmio):
        self._mmio = mmio

    async def write(self, addr, value, **_kwargs):
        if isinstance(value, (bytes, bytearray)):
            value = int.from_bytes(value, 'little')
        word_addr = addr & ~0x3
        self._mmio.write(word_addr, value & 0xFFFFFFFF)

    async def read(self, addr, nbytes=4, **_kwargs):
        word_addr = addr & ~0x3
        byte_off  = addr & 0x3
        word = self._mmio.read(word_addr)
        if nbytes < 4:
            mask = (1 << (nbytes * 8)) - 1
            word = (word >> (byte_off * 8)) & mask
        return [{'data': f'0x{word:08x}'}]


class _DummyDutSignal:
    """Stand-in for a cocotb DUT signal.

    Tests that drive ``dut.HRESETn.setimmediatevalue(0)`` or read
    ``dut.some_signal.value`` get a no-op on real hardware — resets are
    managed by ``HwTB.cycle_reset()`` and status is read via registers.
    """

    def __init__(self, name='dummy'):
        self._name = name
        self.value = 0

    def setimmediatevalue(self, v):
        self.value = v

    def __int__(self):
        return int(self.value)


class HwDut:
    """Stand-in for the cocotb ``dut`` object.

    Any attribute access returns a ``_DummyDutSignal`` so existing test code
    that pokes DUT signals (HCLK, HRESETn, etc.) compiles and runs without
    modification.
    """

    def __init__(self):
        self._signals = {}

    def __getattr__(self, name):
        sig = self._signals.get(name)
        if sig is None:
            sig = _DummyDutSignal(name)
            self._signals[name] = sig
        return sig


class HwTB:
    """Hardware-side replacement for the cocotb TB class.

    Exposes the same public interface as the TideLink cocotb TB so that Wave C3
    bridge tests can swap ``import`` lines and reuse the existing test bodies:

        tb.dut
        tb.log
        tb.config_apb_master   ->  MmioAhbShim(overlay.apb)
        tb.tx_ahb_master       ->  MmioAhbShim(overlay.ahb_tx)
        tb.fifo_ahb_master     ->  MmioAhbShim(overlay.ahb_fifo)
        tb.ptp_ahb_master      ->  MmioAhbShim(overlay.ahb_ptp)
        await tb.cycle_reset()

    Parameters
    ----------
    overlay : TidelinkOverlay or TidelinkBareOverlay
        Live overlay instance with MMIO apertures already open.
    log : logging.Logger or None
        Logger to attach. Defaults to ``logging.getLogger("hw.tidelink.tb")``.
    """

    def __init__(self, overlay, log=None):
        self.dut  = HwDut()
        self.log  = log or logging.getLogger("hw.tidelink.tb")
        self.config_apb_master = MmioAhbShim(overlay.apb)
        self.tx_ahb_master     = MmioAhbShim(overlay.ahb_tx)
        self.fifo_ahb_master   = MmioAhbShim(overlay.ahb_fifo)
        self.ptp_ahb_master    = MmioAhbShim(overlay.ahb_ptp)
        self._overlay = overlay

    async def cycle_reset(self):
        """Software-reset the TideLink controller.

        Writes EN=0, FLUSH=1 to APB CTRL (0x01C). Hardware self-clears FLUSH
        after one clock. A 1 ms sleep allows CDC synchronisers to settle.
        """
        self._overlay.reset_controller()
        await asyncio.sleep(0.001)


# ---------------------------------------------------------------------------
# Poll / wait helpers for Wave C3 bridge tests
# ---------------------------------------------------------------------------

async def poll_busy_clear(dut, tb, timeout=None):
    """Poll APB STATUS[0] (returner_busy) until clear.

    The ``dut`` argument is accepted for signature compatibility but unused.
    """
    deadline = time.monotonic() + (POLL_TIMEOUT_S if timeout is None
                                   else timeout * 1e-6)
    while time.monotonic() < deadline:
        data = await tb.config_apb_master.read(0x010, 4)
        if not (int(data[0]['data'], 16) & 1):
            return
        await asyncio.sleep(0)
    raise AssertionError("TideLink returner_busy did not clear within timeout")


async def wait_for_irq(dut, tb, irq_reg_off=0x020, timeout=None):
    """Wait for a non-zero value in ``irq_reg_off`` (default: released credits acc).

    Polls the APB register at ``irq_reg_off`` until it is non-zero, then reads
    and returns the value (which clears the accumulator on read per the RTL).
    """
    deadline = time.monotonic() + (POLL_TIMEOUT_S if timeout is None
                                   else timeout * 1e-6)
    while time.monotonic() < deadline:
        data = await tb.config_apb_master.read(irq_reg_off, 4)
        val = int(data[0]['data'], 16)
        if val:
            return val
        await asyncio.sleep(0)
    raise AssertionError(
        f"TideLink IRQ register 0x{irq_reg_off:03x} did not assert within timeout")
