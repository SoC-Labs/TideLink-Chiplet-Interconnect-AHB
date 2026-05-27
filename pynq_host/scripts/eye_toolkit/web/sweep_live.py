"""Async wrapper around eye_sweep.iter_sweep_global_phase().

The underlying generator is sync (sshpass + ssh + python3 + mmap on
the PYNQ — there is no async path). We bridge it to asyncio by
running each (write -> sleep -> read) step on the default executor,
so the FastAPI event loop is never blocked.
"""
from __future__ import annotations

import asyncio
import functools
from dataclasses import dataclass, field
from typing import AsyncIterator, Callable, Optional

from pynq_host.scripts.eye_toolkit import eye_sweep


@dataclass
class SweepRow:
    board: str
    phase: int
    lock_mask: int
    lock_count: int
    fault_mask: int
    cal_done: int
    fcsm_state: int
    cr_pkt_seen: int

    def to_dict(self) -> dict:
        return {
            "board": self.board,
            "phase": self.phase,
            "lock_mask": self.lock_mask,
            "lock_count": self.lock_count,
            "fault_mask": self.fault_mask,
            "cal_done": self.cal_done,
            "fcsm_state": self.fcsm_state,
            "cr_pkt_seen": self.cr_pkt_seen,
        }


@dataclass
class SweepConfig:
    board: str
    ip: str
    password: str = eye_sweep.DEFAULT_PASS
    settle_s: float = eye_sweep.PHASE_SETTLE_S
    read_fn: Optional[Callable[[int], int]] = None
    write_fn: Optional[Callable[[int, int, int, int], None]] = None


async def _async_sweep(cfg: SweepConfig) -> AsyncIterator[SweepRow]:
    loop = asyncio.get_running_loop()

    if cfg.read_fn is None:
        read_fn = functools.partial(eye_sweep.remote_read, cfg.ip,
                                    password=cfg.password)
    else:
        read_fn = cfg.read_fn
    if cfg.write_fn is None:
        write_fn = functools.partial(eye_sweep.remote_write_field, cfg.ip,
                                     password=cfg.password)
        # Adapt signature to (addr, shift, mask, value).
        def _write(a, sh, msk, v):
            return write_fn(a, sh, msk, v)
        wfn = _write
    else:
        wfn = cfg.write_fn

    # We pass sleep_fn=lambda _s: None and do the await sleep here in
    # asyncio land, so the loop body's blocking work (the ssh round
    # trips inside read_fn/write_fn) is the only thing we offload.
    def _sleep_noop(_s):
        return None

    gen = eye_sweep.iter_sweep_global_phase(
        cfg.ip, cfg.password, cfg.settle_s,
        sleep_fn=_sleep_noop, read_fn=read_fn, write_fn=wfn,
    )
    try:
        while True:
            # Drive the generator one step at a time on the executor so
            # the inevitable blocking ssh inside read_fn/write_fn
            # doesn't stall the event loop.
            row = await loop.run_in_executor(None, _next, gen)
            if row is _SENTINEL:
                return
            await asyncio.sleep(cfg.settle_s)
            yield SweepRow(
                board=cfg.board,
                phase=row["phase"],
                lock_mask=row["lock_mask"],
                lock_count=row["lock_count"],
                fault_mask=row["fault_mask"],
                cal_done=row["cal_done"],
                fcsm_state=row["fcsm_state"],
                cr_pkt_seen=row["cr_pkt_seen"],
            )
    finally:
        gen.close()


_SENTINEL = object()


def _next(gen):
    try:
        return next(gen)
    except StopIteration:
        return _SENTINEL


async def run_paired_sweep(configs: list[SweepConfig]
                           ) -> AsyncIterator[SweepRow]:
    """Run N sweeps in parallel, yielding rows from whichever board
    has one ready (asyncio.gather-of-iterators pattern). Rows are
    tagged with their board id so the consumer can route them."""
    queue: asyncio.Queue = asyncio.Queue()

    async def _pump(cfg: SweepConfig):
        try:
            async for row in _async_sweep(cfg):
                await queue.put(("row", row))
        except Exception as exc:
            await queue.put(("error", (cfg.board, exc)))
        finally:
            await queue.put(("done", cfg.board))

    tasks = [asyncio.create_task(_pump(c), name=f"sweep-{c.board}")
             for c in configs]
    done_boards = set()
    pending_errors: list[tuple[str, Exception]] = []
    try:
        while len(done_boards) < len(configs):
            kind, payload = await queue.get()
            if kind == "row":
                yield payload
            elif kind == "done":
                done_boards.add(payload)
            elif kind == "error":
                pending_errors.append(payload)
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
        for t in tasks:
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
    if pending_errors:
        raise RuntimeError(f"sweep errors: {pending_errors}")
