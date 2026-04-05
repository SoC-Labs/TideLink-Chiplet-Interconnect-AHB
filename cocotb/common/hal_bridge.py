"""HAL Bridge — Shadow buffer + snapshot-diff replay for C driver testing.

Bridges a ctypes-loaded C bare-metal driver to a cocotb AHB/APB bus master.
The C driver reads/writes a plain RAM shadow buffer; after each API call,
changed registers are replayed as bus transactions into the RTL simulation.

Usage::

    from hal_bridge import HALBridge

    bridge = HALBridge(
        ahb_read=tb.read,
        ahb_write=tb.write,
        reg_size=0x0AC,
        rw_offsets=[0x000, 0x008, ...],
        ro_offsets=[0x004, 0x020, ...],
        trigger_offsets=[0x000, 0x03C],
    )

    # Initialise C driver with shadow buffer address
    lib.phc_init(byref(phc), bridge.base_addr)

    # Call C function and replay register writes to RTL
    await bridge.call_and_replay(lib.phc_set_time, byref(phc), 0, 42, 100000000)

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
licence.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright 2026, SoC Labs (www.soclabs.org)
"""

import ctypes
import copy


class HALBridge:
    """Shadow-buffer bridge between a C driver (.so) and cocotb bus master.

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
        ahb_read:  ``async (offset) -> int`` — read a 32-bit register
                   from RTL at the given byte offset.
        ahb_write: ``async (offset, data) -> None`` — write a 32-bit
                   register to RTL.
        reg_size:  Total register space size in bytes (must be word-aligned).
        rw_offsets: List of byte offsets of R/W registers (pre-populated
                    and diffed).
        ro_offsets: List of byte offsets of read-only registers (pre-populated
                    only — never replayed).
        trigger_offsets: Subset of rw_offsets that contain self-clearing or
                         trigger fields (replayed last to preserve ordering).
    """

    def __init__(self, ahb_read, ahb_write, reg_size, rw_offsets,
                 ro_offsets, trigger_offsets=None):
        self.ahb_read = ahb_read
        self.ahb_write = ahb_write
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
