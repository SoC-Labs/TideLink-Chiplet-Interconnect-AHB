"""RegBus protocol + bus adapters (SDK.md §2.2).

``RegBus`` is the *entire* hardware abstraction for the test-porting
kit: a 32-bit word read, a 32-bit word write, and an optional reset.
Everything in a workspace cocotb C-driver test except this pair is
hardware-agnostic (SDK.md §2.1 "the seam, the key finding"), so
swapping the ``RegBus`` is what lets the same test body run in sim and
on real silicon.

Adapters (SDK.md §2.2 table):

* :class:`CocotbAhbBus` — wraps ``cocotbext.ahb`` ``AHBLiteMaster``
  from ``AHBBus.from_prefix`` (sim; unchanged behaviour). cocotb /
  cocotbext are the dev-host-only ``fpgahub-sdk[cocotb]`` extra and are
  **lazily imported inside __init__** so ``import fpgahub_sdk.testkit``
  succeeds on a stock PYNQ PS (and in this env) with cocotb absent.
* :class:`PynqMmioBus` — wraps ``pynq.MMIO(phys_base, span)`` on the
  PYNQ PS Linux side (Phase 7C, SDK.md §2.2 / §4). ``pynq`` is **not**
  installed in the dev/unit-test env (it only exists on the stock PYNQ
  image), so it is **lazily imported inside __init__** exactly like
  ``cocotbext`` is for :class:`CocotbAhbBus` — ``import
  fpgahub_sdk.testkit`` / ``.buses`` must still succeed here, and only
  instantiating ``PynqMmioBus`` without ``pynq`` raises a clear
  ``ImportError``.
* :class:`JtagAxiBus` — wraps a host-attached AXI-over-JTAG path via
  the Xilinx ``hw_server`` + ``xsdb``/``xsct`` toolchain (Phase 7E,
  SDK.md §2.2 / §5.2): the no-PS analogue of :class:`PynqMmioBus` for a
  standalone/MPS3 board with no Linux PS. The toolchain is **not** a
  pip dependency and there is no clean Python library, so the backend
  is **lazily resolved inside __init__** (an importable ``pyxsct``-like
  module if a project ships one, else an ``xsdb``/``xsct`` executable
  on ``PATH``) exactly like ``cocotbext`` / ``pynq`` are lazily
  imported for the other two adapters — ``import fpgahub_sdk.testkit``
  / ``.buses`` stays safe with the toolchain absent and only
  *instantiating* :class:`JtagAxiBus` without it raises a clear
  ``ImportError``.

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access licence.

Copyright 2026, SoC Labs (www.soclabs.org)

Vendored copy — canonical source: ~/SoCLabs/fpgahub/src/fpgahub_sdk/testkit/buses.py
"""

import shutil
try:
    from typing import Protocol, runtime_checkable
except ImportError:
    from typing_extensions import Protocol
    from typing import runtime_checkable


@runtime_checkable
class RegBus(Protocol):
    """The entire hardware abstraction (SDK.md §2.2).

    A word-addressed register bus. ``off`` is a byte offset; values are
    32-bit words. ``reset`` is **optional**: adapters may omit it
    entirely (``HALBridge`` never calls it), and callers that want a
    uniform surface can mix in :class:`RegBusBase` for a no-op default.
    """

    async def read(self, off: int) -> int:
        """Read the 32-bit word at byte offset ``off``."""
        ...

    async def write(self, off: int, data: int) -> None:
        """Write the 32-bit word ``data`` at byte offset ``off``."""
        ...

    async def reset(self) -> None:
        """Optional bus/DUT reset. Adapters may omit this entirely."""
        ...


class RegBusBase:
    """Optional convenience base giving :class:`RegBus`'s no-op ``reset``.

    Adapters are free to *not* inherit this and simply omit ``reset``
    (``HALBridge`` does not require it — SDK.md §2.2). It exists only so
    a caller that wants ``reset()`` to always be callable has a default.
    """

    async def reset(self) -> None:  # no-op default
        return None


# Message shared by the lazy-import guard and surfaced to the user when
# cocotb is missing. Kept as a module constant so the test can assert on
# a stable, actionable string.
_MISSING_COCOTB_MSG = (
    "CocotbAhbBus requires the optional 'cocotb' extra "
    "(cocotb + cocotbext.ahb). Install it with: "
    "pip install cocotb cocotbext-ahb  (dev-host only; not on the PYNQ PS)"
)


class CocotbAhbBus(RegBusBase):
    """:class:`RegBus` over ``cocotbext.ahb`` ``AHBLiteMaster`` (sim).

    Mirrors the construction in the canonical sibling test
    ``ptp-hardware-clock-ahb/cocotb/phc_ahb/test_phc_ahb_cdriver.py``::

        ahbs_bus = AHBBus.from_prefix(dut, "ahbs")
        self.ahb = AHBLiteMaster(ahbs_bus, dut.hclk, dut.hresetn,
                                 timeout=200)
        async def _ahb_read(off):
            resp = await self.ahb.read(off)
            return int(resp[0].get("data", "0x0"), 16)
        async def _ahb_write(off, data):
            await self.ahb.write(off, data)

    cocotb / cocotbext are imported **lazily inside __init__** (the
    ``[cocotb]`` extra is dev-host-only and absent on the PYNQ PS / in
    the unit-test env), so the class is importable everywhere and only
    instantiating it without cocotb raises a clear ``ImportError``.

    Args:
        dut: the cocotb DUT handle.
        prefix: AHB signal prefix for ``AHBBus.from_prefix`` (default
            ``"ahbs"`` — the workspace convention).
        clk_attr: DUT attribute name of the bus clock (default
            ``"hclk"``).
        resetn_attr: DUT attribute name of the active-low reset
            (default ``"hresetn"``).
        timeout: ``AHBLiteMaster`` timeout (default ``200``, matching
            the canonical sibling test).
    """

    def __init__(self, dut, prefix: str = "ahbs", clk_attr: str = "hclk",
                 resetn_attr: str = "hresetn", timeout: int = 200):
        try:
            from cocotbext.ahb import AHBBus, AHBLiteMaster
        except ImportError as exc:  # cocotb extra not installed
            raise ImportError(_MISSING_COCOTB_MSG) from exc

        self.dut = dut
        self._resetn_attr = resetn_attr
        self._clk_attr = clk_attr
        ahbs_bus = AHBBus.from_prefix(dut, prefix)
        self.ahb = AHBLiteMaster(
            ahbs_bus,
            getattr(dut, clk_attr),
            getattr(dut, resetn_attr),
            timeout=timeout,
        )

    async def read(self, off: int) -> int:
        # Identical shape to the canonical test's _ahb_read.
        resp = await self.ahb.read(off)
        return int(resp[0].get("data", "0x0"), 16)

    async def write(self, off: int, data: int) -> None:
        # Identical shape to the canonical test's _ahb_write.
        await self.ahb.write(off, data)


# Message shared by the lazy-import guard and surfaced to the user when
# pynq is missing.
_MISSING_PYNQ_MSG = "pip install pynq (PYNQ PS only)"


class PynqMmioBus(RegBusBase):
    """:class:`RegBus` over ``pynq.MMIO`` (the PYNQ PS, Linux side)."""

    def __init__(self, phys_base: int, span: int):
        try:
            import pynq  # noqa: F401
        except ImportError as exc:
            raise ImportError(_MISSING_PYNQ_MSG) from exc

        from pynq import MMIO

        self.phys_base = phys_base
        self.span = span
        self._mmio = MMIO(phys_base, span)

    async def read(self, off: int) -> int:
        return int(self._mmio.read(off))

    async def write(self, off: int, data: int) -> None:
        self._mmio.write(off, int(data) & 0xFFFFFFFF)


_MISSING_XSDB_MSG = (
    "JtagAxiBus needs Xilinx hw_server + xsdb/xsct on PATH "
    "(host-attached JTAG-AXI); see docs/SDK.md §2.2"
)

_XSDB_EXECUTABLES = ("xsdb", "xsct")


class JtagAxiBus(RegBusBase):
    """:class:`RegBus` over AXI-over-JTAG via Xilinx ``hw_server``/XSDB."""

    def __init__(self, axi_base: int, *, hw_server: str = "localhost:3121",
                 target: "str | None" = None, span: "int | None" = None):
        self.axi_base = int(axi_base)
        self.hw_server = hw_server
        self.target = target
        self.span = span

        self._pyxsct = None
        self._xsdb_exe = None
        try:
            import pyxsct  # type: ignore  # noqa: F401
        except ImportError:
            pyxsct = None  # type: ignore
        if pyxsct is not None and hasattr(pyxsct, "mrd") \
                and hasattr(pyxsct, "mwr"):
            self._pyxsct = pyxsct
            self._backend = "pyxsct"
            return

        for exe in _XSDB_EXECUTABLES:
            found = shutil.which(exe)
            if found:
                self._xsdb_exe = found
                self._backend = "xsdb"
                return

        raise ImportError(_MISSING_XSDB_MSG)

    def _preamble(self) -> str:
        lines = ["connect -url %s" % self.hw_server]
        if self.target is not None:
            lines.append(
                'targets -set -filter {name =~ "%s"}' % self.target
            )
        else:
            lines.append("targets -set")
        return "\n".join(lines)

    def _mrd_script(self, addr: int) -> str:
        return "%s\nmrd -force 0x%X\n" % (self._preamble(), addr)

    def _mwr_script(self, addr: int, data: int) -> str:
        return "%s\nmwr -force 0x%X 0x%X\n" % (
            self._preamble(), addr, data & 0xFFFFFFFF,
        )

    def _xsdb_cmd(self, script: str) -> str:
        import subprocess
        assert self._xsdb_exe is not None
        completed = subprocess.run(
            [self._xsdb_exe],
            input=script,
            capture_output=True,
            text=True,
            check=True,
        )
        return completed.stdout

    @staticmethod
    def _parse_mrd(stdout: str) -> int:
        import re
        pat = re.compile(r"^\s*[0-9A-Fa-f]+:\s+([0-9A-Fa-f]+)\s*$")
        for line in reversed(stdout.splitlines()):
            m = pat.match(line)
            if m:
                return int(m.group(1), 16) & 0xFFFFFFFF
        raise ValueError(
            "could not parse an mrd word from xsdb stdout: %r" % stdout
        )

    async def read(self, off: int) -> int:
        addr = self.axi_base + off
        if self._pyxsct is not None:
            return int(self._pyxsct.mrd(addr)) & 0xFFFFFFFF
        return self._parse_mrd(self._xsdb_cmd(self._mrd_script(addr)))

    async def write(self, off: int, data: int) -> None:
        addr = self.axi_base + off
        word = int(data) & 0xFFFFFFFF
        if self._pyxsct is not None:
            self._pyxsct.mwr(addr, word)
            return
        self._xsdb_cmd(self._mwr_script(addr, word))
