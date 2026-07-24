"""Run FSM for one throughput experiment (adapted from
stress_toolkit/web/runner.py's Run, with the store + agent channels +
P0 interlocks wired in).

    created -> proofing -> running -> finalizing -> done
                       \\-> failed / aborted

Sequencing of the interlocks (plan §6):

  POST /api/runs (app.py, synchronous — failures are 409/412 and NO
  run record is created):
    1. single-experiment mutex (409)
    2. lease GRANTED-not-queued        (412)   [fake mode: auto-grant]
    3. provenance manifests, fail-closed (412)
    4. criterion-A/B link gate via live probes (412)
  then the record is created and this FSM takes over:
    5. delivery proof — one verified 4-word M->S packet BEFORE any
       sustained AHB_TX traffic (failure -> run FAILED, no traffic sent)
    6. measurement with the jam-signature sentinel on every sample
       (CLASSIC / HELD-REPLAY / FCSM excursion -> auto-abort, FAILED)
    7. hard wall-clock watchdog (duration + grace)

Events on ``self.events`` flow to the SSE consumer; samples are
simultaneously persisted to the run store NDJSON files.
"""
from __future__ import annotations

import asyncio
import time
from enum import Enum
from typing import Callable, Optional

from . import gates
from .agent_channel import AgentError, _BaseChannel
from .store import RunStore


class RunState(str, Enum):
    CREATED = "created"
    PROOFING = "proofing"
    RUNNING = "running"
    DONE = "done"
    ABORTED = "aborted"
    FAILED = "failed"


_TERMINAL = {RunState.DONE, RunState.ABORTED, RunState.FAILED}

WATCHDOG_GRACE_S = 30.0


class RunEvent:
    __slots__ = ("kind", "state", "ts", "detail")

    def __init__(self, kind: str, state: str, **detail):
        self.kind = kind
        self.state = state
        self.ts = time.time()
        self.detail = detail

    def to_dict(self) -> dict:
        return {"kind": self.kind, "state": self.state, "ts": self.ts,
                **self.detail}


class ThroughputRun:
    """One admitted throughput run (record already created in the store
    by app.py after the synchronous gates passed)."""

    def __init__(
        self,
        run_id: str,
        store: RunStore,
        master_ch: _BaseChannel,
        slave_ch: _BaseChannel,
        params: dict,
        *,
        mutex: Optional[gates.ExperimentMutex] = None,
        on_finished: Optional[Callable[[], None]] = None,
        skip_delivery_proof: bool = False,
    ):
        self.run_id = run_id
        self.store = store
        self.master_ch = master_ch
        self.slave_ch = slave_ch
        self.params = params
        self.mutex = mutex
        self.on_finished = on_finished
        self.skip_delivery_proof = skip_delivery_proof
        self.state = RunState.CREATED
        self.error: Optional[str] = None
        self.events: asyncio.Queue = asyncio.Queue()
        self._task: Optional[asyncio.Task] = None
        self._summaries: dict = {}
        self._rel_threshold: Optional[dict] = None

    # ── lifecycle ─────────────────────────────────────────────────────

    def start(self) -> asyncio.Task:
        if self._task is None:
            self._task = asyncio.create_task(
                self._run(), name="tput-run-%s" % self.run_id)
        return self._task

    async def cancel(self) -> None:
        if self.state in _TERMINAL:
            return
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass
        if self.state not in _TERMINAL:
            # The task was cancelled before its coroutine ever started
            # executing — its except/finally handlers never ran, so
            # finalize + clean up here instead.
            await self._finish(RunState.ABORTED)
            await self._cleanup()

    async def _emit(self, kind: str, **detail) -> None:
        await self.events.put(RunEvent(kind, self.state.value, **detail))

    async def _set_state(self, st: RunState, **detail) -> None:
        self.state = st
        if st not in _TERMINAL:
            self.store.set_state(self.run_id, st.value)
        await self._emit("state", **detail)

    # ── main body ─────────────────────────────────────────────────────

    async def _run(self) -> None:
        try:
            duration = float(self.params.get("duration_s", 10.0))
            watchdog = duration + WATCHDOG_GRACE_S
            await asyncio.wait_for(self._run_inner(), timeout=watchdog)
            if self.state not in _TERMINAL:
                await self._finish(RunState.DONE)
        except asyncio.TimeoutError:
            await self._fail("watchdog: run exceeded %.0fs wall clock"
                             % (float(self.params.get("duration_s", 10.0))
                                + WATCHDOG_GRACE_S))
        except asyncio.CancelledError:
            await self._finish(RunState.ABORTED)
            raise
        except gates.GateError as exc:
            await self._fail(str(exc))
        except AgentError as exc:
            await self._fail("agent: %s" % exc)
        except Exception as exc:  # noqa: BLE001
            await self._fail("internal: %r" % exc)
        finally:
            await self._cleanup()

    async def _apply_rel_threshold(self) -> None:
        """Apply RELEASE_THRESHOLD (0x004) to the DRAINING die.

        The threshold governs when that die's returner fires a
        release-credits packet, so it belongs on the side whose RX FIFO
        is being filled — the slave in an M->S run. Its RTL POR is 20,
        which means small drains free fewer than 20 credits and return
        NOTHING, and the sender starves. ``rel_threshold=-1`` leaves the
        deployed image alone.

        A locked CTRL.LOCK blocks the write; we surface that as a warning
        with the readback rather than failing the run, but the readback is
        recorded so a comparison can never silently attribute a rate to a
        threshold that was never applied.
        """
        want = int(self.params.get("rel_threshold", -1))
        if want < 0:
            return
        try:
            res = await self.slave_ch.oneshot("setthr", want)
        except AgentError as exc:
            await self._emit("log", level="warning",
                             msg="rel_threshold: agent refused (%s) — "
                                 "running with the image's own value" % exc)
            return
        self._rel_threshold = res
        got = res.get("rel_threshold")
        if res.get("locked") or got != want:
            await self._emit(
                "log", level="warning",
                msg="rel_threshold: wrote %d but read back %s%s — the "
                    "measurement does NOT reflect the requested threshold"
                    % (want, got, " (CTRL.LOCK set)" if res.get("locked")
                       else ""))
        await self._emit("rel_threshold", **res)

    async def _run_inner(self) -> None:
        # 4b. load-generator setup (before any traffic).
        await self._apply_rel_threshold()

        # 5. delivery proof — gate before any sustained AHB_TX traffic.
        await self._set_state(RunState.PROOFING)
        if self.skip_delivery_proof:
            await self._emit("log", msg="delivery proof SKIPPED by request")
        else:
            detail, warnings = await gates.delivery_proof(
                self.master_ch, self.slave_ch)
            for w in warnings:
                await self._emit("log", level="warning", msg=w)
            await self._emit("delivery_proof", **detail)

        # 6. measurement: slave drains first, master streams; GO both.
        await self._set_state(RunState.RUNNING)
        slave_cfg = {"role": "drain",
                     "duration_s": float(self.params["duration_s"])
                     + 2.0,                      # drain outlives stream
                     "win_s": float(self.params.get("win_s", 0.5))}
        master_cfg = {"role": "stream",
                      "burst_words": int(self.params.get("burst_words", 16)),
                      "duration_s": float(self.params["duration_s"]),
                      "win_s": float(self.params.get("win_s", 0.5)),
                      "rate_pps": float(self.params.get("rate_pps", 0.0))}
        await self.slave_ch.start_run(slave_cfg)
        await self.master_ch.start_run(master_cfg)
        deadline = time.time() + float(self.params["duration_s"]) + 10.0
        await self.slave_ch.send_go(deadline)
        await self.master_ch.send_go(deadline)

        async def _consume(ch: _BaseChannel, board: str) -> None:
            async for ev in ch.events():
                kind = ev.get("ev")
                if kind == "sample":
                    self.store.append_sample(self.run_id, board, ev)
                    reason = gates.sample_excursion(ev)
                    if reason is not None:
                        raise gates.GateError(reason)
                    await self._emit("sample", **ev)
                elif kind == "done":
                    self._summaries[board] = ev.get("summary", {})
                    await self._emit("agent_done", board=board,
                                     summary=ev.get("summary"))
                else:
                    await self._emit("agent_event", board=board, **ev)

        tasks = [
            asyncio.create_task(_consume(self.master_ch, "master")),
            asyncio.create_task(_consume(self.slave_ch, "slave")),
        ]
        try:
            done, _pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_EXCEPTION)
            for t in done:
                if t.exception() is not None:
                    # jam-signature / excursion auto-abort: stop the
                    # peer immediately rather than let it run out.
                    raise t.exception()
        finally:
            for t in tasks:
                if not t.done():
                    t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    # ── teardown / terminal states ────────────────────────────────────

    def _summary(self) -> dict:
        m = self._summaries.get("master", {})
        s = self._summaries.get("slave", {})
        return {
            "throughput_mbps_mean": m.get("throughput_mbps_mean"),
            "throughput_mbps_p5": m.get("throughput_mbps_p5"),
            "throughput_mbps_p95": m.get("throughput_mbps_p95"),
            "packets": m.get("packets"),
            "errors": m.get("errors", 0),
            "rx_throughput_mbps_mean": s.get("throughput_mbps_mean"),
            "rx_drained_words": s.get("drained_words"),
            # What the load generator was ACTUALLY configured to, as read
            # back from the die — a cross-version comparison is only
            # meaningful if the compared runs shared this.
            "burst_words": self.params.get("burst_words"),
            "rate_pps": self.params.get("rate_pps"),
            "rel_threshold_requested": self.params.get("rel_threshold", -1),
            "rel_threshold_applied": (
                self._rel_threshold.get("rel_threshold")
                if self._rel_threshold else None),
            "master": m, "slave": s,
        }

    async def _finish(self, st: RunState) -> None:
        self.state = st
        summary = self._summary() if st == RunState.DONE else None
        self.store.finish_run(self.run_id, st.value, summary=summary,
                              error=self.error)
        await self._emit("state", summary=summary, error=self.error)

    async def _fail(self, reason: str) -> None:
        self.error = reason
        await self._finish(RunState.FAILED)

    async def _cleanup(self) -> None:
        for ch in (self.master_ch, self.slave_ch):
            try:
                await ch.close()
            except Exception:
                pass
        if self.mutex is not None:
            try:
                self.mutex.release()
            except Exception:
                pass
        if self.on_finished is not None:
            try:
                self.on_finished()
            except Exception:
                pass
        await self.events.put(RunEvent("closed", self.state.value))
