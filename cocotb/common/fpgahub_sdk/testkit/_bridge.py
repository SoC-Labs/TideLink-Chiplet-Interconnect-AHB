"""HAL Bridge — Shadow buffer + snapshot-diff replay for C driver testing.

Phase 7B (SDK.md §2.2). This is the canonical
``cocotb/common/hal_bridge.py`` (copy-pasted across ~10 sibling repos)
moved verbatim into ``fpgahub_sdk.testkit``. The shadow-buffer
pre-populate / snapshot / diff / replay algorithm is **unchanged** — it
is proven across the whole workspace. The *only* change is the
constructor seam: instead of two bare coroutine callables
(``ahb_read`` / ``ahb_write``) it accepts a :class:`RegBus`. A
backward-compatible legacy path is preserved so existing call-sites
migrate in one import line (the bare callables are wrapped in a trivial
internal adapter — see ``_CallableBus``).

Original module docstring (canonical source, preserved):

    Bridges a ctypes-loaded C bare-metal driver to a cocotb AHB/APB bus
    master. The C driver reads/writes a plain RAM shadow buffer; after
    each API call, changed registers are replayed as bus transactions
    into the RTL simulation.

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access licence.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright 2026, SoC Labs (www.soclabs.org)

Vendored copy — canonical source: ~/SoCLabs/fpgahub/src/fpgahub_sdk/testkit/_bridge.py
"""

import ctypes
import copy  # noqa: F401 — kept verbatim from canonical source

from .buses import RegBus


class _CallableBus:
    """Trivial internal :class:`RegBus` adapter over two bare coroutines.

    Backward-compat shim only (SDK.md §2.2 "one import line"). When a
    legacy call-site passes ``ahb_read=fn, ahb_write=fn`` the bridge
    wraps them here so the rest of the algorithm sees a uniform
    ``bus.read`` / ``bus.write``. Not part of the public surface.
    """

    def __init__(self, ahb_read, ahb_write):
        self._read = ahb_read
        self._write = ahb_write

    async def read(self, off: int) -> int:
        return await self._read(off)

    async def write(self, off: int, data: int) -> None:
        await self._write(off, data)

    async def reset(self) -> None:  # optional RegBus method — no-op
        return None


class HALBridge:
    """Shadow-buffer bridge between a C driver (.so) and a register bus.

    The C driver is compiled for host (x86_64) with HAL_TEST_MODE, so
    ``__IO`` is non-volatile.  ``phc_init(phc, base)`` receives the
    address of a ctypes buffer, and all subsequent ``phc->regs->REG``
    accesses hit that buffer.

    For each C API call the bridge:
    1. **Pre-populates** the shadow buffer by reading all readable
       registers from RTL via the bus master.
    2. **Snapshots** the buffer.
    3. **Calls** the C function (synchronous — modifies the buffer).
    4. **Diffs** buffer vs snapshot to find changed words.
    5. **Replays** changes as bus write transactions (staging regs first,
       trigger regs last).

    Args:
        bus:       A :class:`RegBus` — ``async read(off)->int`` /
                   ``async write(off,data)->None``. (Phase 7B seam.)
        ahb_read:  *Legacy* ``async (offset) -> int`` — read a 32-bit
                   register from RTL at the given byte offset. Pass this
                   together with ``ahb_write`` instead of ``bus`` for the
                   one-line migration path; they are wrapped internally.
        ahb_write: *Legacy* ``async (offset, data) -> None`` — write a
                   32-bit register to RTL.
        reg_size:  Total register space size in bytes (must be word-aligned).
        rw_offsets: List of byte offsets of R/W registers (pre-populated
                    and diffed).
        ro_offsets: List of byte offsets of read-only registers (pre-populated
                    only — never replayed).
        trigger_offsets: Subset of rw_offsets that contain self-clearing or
                         trigger fields (replayed last to preserve ordering).
    """

    def __init__(self, bus: RegBus = None, reg_size=None, rw_offsets=None,
                 ro_offsets=None, trigger_offsets=None,
                 *, ahb_read=None, ahb_write=None):
        # ── Constructor seam (the ONLY change vs canonical) ──────────
        # Either HALBridge(bus, reg_size=, rw_offsets=, ...) [Phase 7B]
        # or the legacy HALBridge(ahb_read=fn, ahb_write=fn, reg_size=,
        # ...) — the bare callables are wrapped in _CallableBus so the
        # algorithm below is byte-identical to the canonical source.
        if bus is None:
            if ahb_read is None or ahb_write is None:
                raise TypeError(
                    "HALBridge requires either a RegBus "
                    "(HALBridge(bus, reg_size=...)) or the legacy "
                    "ahb_read=/ahb_write= callable pair"
                )
            bus = _CallableBus(ahb_read, ahb_write)
        elif ahb_read is not None or ahb_write is not None:
            raise TypeError(
                "HALBridge: pass a RegBus OR ahb_read/ahb_write, not both"
            )
        self.bus = bus
        # Legacy attribute aliases — sibling tests/callers may still
        # reference .ahb_read / .ahb_write; keep them pointing at the
        # (possibly adapted) bus coroutines so nothing breaks.
        self.ahb_read = bus.read
        self.ahb_write = bus.write

        # Seam-owned arg validation: the verbatim algorithm below does
        # `reg_size // 4` / `sorted(rw_offsets)` unguarded, so a forgotten
        # kwarg would surface as an opaque NoneType TypeError deep in the
        # canonical block. Fail loud here with the same clarity as the
        # bus-seam errors above.
        if reg_size is None or rw_offsets is None or ro_offsets is None:
            raise TypeError(
                "HALBridge requires reg_size=, rw_offsets= and ro_offsets= "
                "(the register window size in bytes and the RW / RO byte "
                "offsets) — see the project's regs/<addrmap>_meta.py"
            )

        # ── Below here: VERBATIM from the canonical hal_bridge.py ────
        self.reg_size = reg_size
        self.n_words = reg_size // 4
        self.rw_offsets = sorted(rw_offsets)
        self.ro_offsets = sorted(ro_offsets)
        self.all_readable = sorted(set(rw_offsets) | set(ro_offsets))
        self.trigger_offsets = set(trigger_offsets or [])

        # Shadow buffer — C driver reads/writes this
        self.buf = (ctypes.c_uint32 * self.n_words)()
        ctypes.memset(self.buf, 0, ctypes.sizeof(self.buf))

    @property
    def base_addr(self):
        """Address of the shadow buffer (pass to C driver init)."""
        return ctypes.addressof(self.buf)

    # ── Internal helpers ────────────────────────────────────────────────

    def _snapshot(self):
        """Return a copy of the current shadow buffer as a list."""
        return list(self.buf)

    def _diff(self, snapshot):
        """Return list of (byte_offset, new_value) for changed words."""
        diffs = []
        for off in self.rw_offsets:
            idx = off // 4
            if idx < self.n_words and self.buf[idx] != snapshot[idx]:
                diffs.append((off, int(self.buf[idx])))
        return diffs

    # ── Public API ──────────────────────────────────────────────────────

    async def pre_populate(self):
        """Read all readable registers from RTL into the shadow buffer."""
        for off in self.all_readable:
            val = await self.ahb_read(off)
            idx = off // 4
            if idx < self.n_words:
                self.buf[idx] = val

    async def replay(self, diffs):
        """Write diffs to RTL: staging registers first, triggers last."""
        staging = [(off, val) for off, val in diffs
                   if off not in self.trigger_offsets]
        triggers = [(off, val) for off, val in diffs
                    if off in self.trigger_offsets]

        for off, val in staging:
            await self.ahb_write(off, val)

        for off, val in triggers:
            await self.ahb_write(off, val)

    async def call_and_replay(self, func, *args):
        """Pre-populate, snapshot, call C function, diff, replay.

        Use for C functions that only write registers (void return).
        """
        await self.pre_populate()
        snap = self._snapshot()
        func(*args)
        diffs = self._diff(snap)
        if diffs:
            await self.replay(diffs)

    async def call_and_read(self, func, *args):
        """Pre-populate, snapshot, call C function, diff, replay, return result.

        Use for C functions that return a value or fill an output struct.
        The C function's return value is passed through.
        """
        await self.pre_populate()
        snap = self._snapshot()
        result = func(*args)
        diffs = self._diff(snap)
        if diffs:
            await self.replay(diffs)
        return result

    async def read_only(self, func, *args):
        """Pre-populate, call C function, return result (no replay).

        Use for pure-read C functions (e.g. phc_read_capture) where the
        C code only reads the shadow buffer and writes to an output struct.
        """
        await self.pre_populate()
        return func(*args)
