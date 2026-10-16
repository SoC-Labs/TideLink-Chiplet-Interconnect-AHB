"""injector_ctl_cocotb.py - cocotb driver for the shared injector must-fail controls.

The decision logic (what counts as a held register, a live shot, an inert arm, an eaten shot) lives in
pynq_host/hw_regress/injector_controls.py and is the SAME code the KR260 board tool runs.  This module only
adds the async APB plumbing, so a simulation and a board run cannot drift apart on what "the injector
proved itself" means.  Use it in EVERY test that arms LINK_ERROR_INJECTION (APB 0x23C):

    from injector_ctl_cocotb import AsyncInjector, assert_no_ledger_errors
    inj = AsyncInjector(tb.apb(tx), clk=dut.hclk)
    await inj.arm(0xA1, byte=5, bit=0)         # raises AssertionError unless 0x23C read 0 and holds the arm
    ... send traffic ...
    await inj.disarm()

PYTHONPATH must contain cocotb/common (the benches' Makefiles add it); the library is found relative to
this file, so no environment variable is needed.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB = os.path.normpath(os.path.join(_HERE, "..", "..", "pynq_host", "hw_regress"))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)
import injector_controls as ic                                    # noqa: E402  (the one implementation)
from cocotb.triggers import ClockCycles                           # noqa: E402
from cocotb.utils import get_sim_time                             # noqa: E402

ControlError = ic.ControlError
ShotLedger = ic.ShotLedger
shot_errors = ic.shot_errors
ERRINJ_OFFSET = ic.ERRINJ_OFFSET


class AsyncInjector:
    """Async counterpart of injector_controls.Injector.

    apb: object with `async read(off)` / `async write(off, val)` (tb.apb(side)).
    clk: the clock signal `ClockCycles` waits on.   settle: hclk cycles after every injector write
    (the 0->1 enable edge is sampled through a 2-flop synchroniser in the TX link clock).
    unlock: optional `async fn(on: bool)` for a slave-die debug unlock (the sim tb has none)."""

    def __init__(self, apb, clk, offset=ERRINJ_OFFSET, settle=400, unlock=None, log=None, period_ps=20000, read_guess=12):
        ic.assert_injector_offset(offset)                        # C-REG-ADDR, before any write
        self.apb, self.clk, self.off, self.settle = apb, clk, offset, settle
        self.unlock, self.log = unlock, log or (lambda *_a: None)
        self.period_ps, self.read_guess = period_ps, read_guess      # hclk period (pair_v2_common CLK_PERIOD_NS=20)

    async def _unlock(self, on):
        if self.unlock is not None:
            await self.unlock(on)

    async def _wait(self):
        await ClockCycles(self.clk, self.settle)

    async def try_arm(self, did, byte, bit):
        """-> ic.ArmResult (OK / NOT_ZERO / NO_HOLD).  Relocks on failure."""
        await self._unlock(True)
        await self.apb.write(self.off, 0); await self._wait()
        z = await self.apb.read(self.off)
        if z != 0:
            await self._unlock(False)
            return ic.ArmResult("NOT_ZERO", None, [z])
        val = ic.arm_value(did, byte, bit)
        await self.apb.write(self.off, val); await self._wait()
        rb = await self.apb.read(self.off)
        r = ic.ArmResult("OK" if ic.hold_ok(val, [rb]) else "NO_HOLD", val, [rb])
        if not r.ok:
            await self._unlock(False)
        return r

    async def arm(self, did, byte, bit):
        """C-REG-HOLD as an assertion (messages unchanged from the pre-library tests)."""
        r = await self.try_arm(did, byte, bit)
        assert r.status != "NOT_ZERO", "0x23C does not read 0"
        assert r.ok, "0x23C readback 0x%08x != 0x%08x" % (r.seen[-1], r.value)
        return r

    async def _wait_and_read(self):
        """Wait `settle` hclk in TOTAL and read the register INSIDE that window, so the added readback does not
        shift the benches' traffic timing (pi_* position tests count packets from the arm; their results must
        not move because a check was added)."""
        t0 = get_sim_time("ps")
        await ClockCycles(self.clk, max(self.settle - self.read_guess, 0))
        v = await self.apb.read(self.off)
        used = int(round((get_sim_time("ps") - t0) / self.period_ps))
        if used < self.settle:
            await ClockCycles(self.clk, self.settle - used)
        return v

    async def clear(self):
        """Write 0 and prove 0x23C reads 0 (the register is a holding register: a stuck non-zero value or a
        dropped write is caught here, before anything is armed).  Timing-neutral."""
        await self._unlock(True)
        await self.apb.write(self.off, 0)
        assert (await self._wait_and_read()) == 0, "0x23C does not read 0"

    async def disarm(self):
        await self.apb.write(self.off, 0); await self._wait()
        await self._unlock(False)

    async def reads_zero(self):
        return (await self.apb.read(self.off)) == 0


async def arm_for_gate(inj, did, byte, bit):
    """Used by the pi_* position-gate tests: arm through the real register and prove it holds."""
    val = ic.arm_value(did, byte, bit)
    await inj.apb.write(inj.off, val)
    rb = await inj._wait_and_read()                      # timing-neutral readback
    assert ic.hold_ok(val, [rb]), "0x23C readback 0x%08x != 0x%08x" % (rb, val)


async def run_wrong_id_control(inj, drive, counters, did=0x7E, byte=5, bit=0):
    """C-INJ-INERT in simulation.  drive() -> number of control messages NOT delivered exactly (async);
    counters() -> comparable snapshot of the receiver CRC counter(s) (async).  Returns the error list
    (empty == the injector is selective) and asserts nothing itself."""
    c1 = await counters()
    r = await inj.try_arm(did, byte, bit)
    if not r.ok:
        return ["injector %s (wrong-DataID control cannot run)" % r.why()]
    try:
        bad = await drive()
    finally:
        await inj.disarm()
    c2 = await counters()
    return ic.wrong_id_errors(bad, c1 == c2, await inj.reads_zero())


def assert_no_ledger_errors(ledger, total_delta=None):
    """C-COUNT-EXPECT at the end of a multi-shot test."""
    errs = ledger.errors(total_delta=total_delta)
    assert not errs, "; ".join(errs)
