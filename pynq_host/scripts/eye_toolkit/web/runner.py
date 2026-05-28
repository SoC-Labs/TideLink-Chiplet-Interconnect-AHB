"""Per-session Run object — the state machine that owns one live-eye run.

A Run is one-shot: every "Run" click in the browser creates a new Run
with its own asyncio task; cancelling the previous run is the caller's
responsibility (app.py refuses 409 if a run is already in flight).

States:
  IDLE -> LEASE_ACQUIRING -> DEPLOYING -> CONVERGING -> SWEEPING
       -> DONE | ABORTED | FAILED

Events are pushed onto an asyncio.Queue; the SSE endpoint drains it.
"""
from __future__ import annotations

import asyncio
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional

from .deploy import DeployError, DeployRunner, StagedBitstream
from .lease import LeaseClient, LeaseError, LeaseToken, QueueState
from .sweep_live import SweepConfig, run_paired_sweep


class RunState(str, Enum):
    IDLE = "idle"
    LEASE_ACQUIRING = "lease_acquiring"
    LEASE_QUEUED = "lease_queued"
    DEPLOYING = "deploying"
    CONVERGING = "converging"
    SWEEPING = "sweeping"
    DONE = "done"
    ABORTED = "aborted"
    FAILED = "failed"


_TERMINAL = {RunState.DONE, RunState.ABORTED, RunState.FAILED}


@dataclass
class RunOptions:
    stage_dir: str
    board: str = "bridge1"
    master_board: str = "master"
    master_ip: str = "192.168.4.101"
    slave_board: str = "slave"
    slave_ip: str = "192.168.6.101"
    ttl_seconds: int = 1800
    skip_deploy: bool = False
    skip_converge: bool = False
    settle_s: float = 0.5


@dataclass
class RunEvent:
    kind: str
    state: str
    detail: dict = field(default_factory=dict)
    ts: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return {
            "kind": self.kind,
            "state": self.state,
            "ts": self.ts,
            **self.detail,
        }


class Run:
    def __init__(
        self,
        lease_client: LeaseClient,
        deploy_runner: DeployRunner,
        sweep_configs: list[SweepConfig],
        options: RunOptions,
        *,
        run_id: Optional[str] = None,
    ):
        self.run_id = run_id or uuid.uuid4().hex[:12]
        self._lease = lease_client
        self._deploy = deploy_runner
        self._sweep_configs = sweep_configs
        self.options = options
        self.state: RunState = RunState.IDLE
        self.events: asyncio.Queue[RunEvent] = asyncio.Queue()
        self._task: Optional[asyncio.Task] = None
        self._cancel = asyncio.Event()
        self._lease_token: Optional[LeaseToken] = None
        self.error: Optional[str] = None

    async def _emit(self, kind: str, **detail) -> None:
        ev = RunEvent(kind=kind, state=self.state.value, detail=detail)
        await self.events.put(ev)

    async def _set_state(self, st: RunState, **detail) -> None:
        self.state = st
        await self._emit("state", **detail)

    def start(self) -> asyncio.Task:
        if self._task is not None:
            return self._task
        self._task = asyncio.create_task(self._run(), name=f"run-{self.run_id}")
        return self._task

    async def cancel(self) -> None:
        if self.state in _TERMINAL:
            return
        self._cancel.set()
        try:
            await self._deploy.cancel()
        except Exception:
            pass
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass

    async def _run(self) -> None:
        try:
            await self._set_state(RunState.LEASE_ACQUIRING)
            result = await self._lease.acquire(self.options.board,
                                               ttl=self.options.ttl_seconds)
            if isinstance(result, QueueState):
                await self._set_state(RunState.LEASE_QUEUED,
                                      position=result.position)
                raise LeaseError(
                    f"queued at position {result.position}; abort or wait")
            self._lease_token = result
            await self._emit("lease_acquired",
                             holder=result.holder, token=result.token,
                             expires_at=result.expires_at)
            self._lease.start_heartbeat(result, ttl=self.options.ttl_seconds,
                                        on_failure=self._on_lease_failure)

            if not self.options.skip_deploy:
                await self._set_state(RunState.DEPLOYING)
                self._deploy.verify_stage()
                # Stream deploy + converge events through.
                async for ev in self._deploy.deploy_both(
                        skip_deploy=False,
                        skip_converge=self.options.skip_converge):
                    if self._cancel.is_set():
                        await self._set_state(RunState.ABORTED)
                        return
                    if ev.kind == "bringup_started":
                        await self._set_state(RunState.CONVERGING)
                    await self._emit("deploy", deploy_kind=ev.kind,
                                     board=ev.board, **ev.detail)
                    if ev.kind == "bringup_failed":
                        await self._fail("bringup did not converge")
                        return
            elif not self.options.skip_converge:
                # Skip deploy but still want converge.
                await self._set_state(RunState.CONVERGING)
                async for ev in self._deploy.deploy_both(
                        skip_deploy=True, skip_converge=False):
                    await self._emit("deploy", deploy_kind=ev.kind,
                                     board=ev.board, **ev.detail)
                    if ev.kind == "bringup_failed":
                        await self._fail("bringup did not converge")
                        return

            await self._set_state(RunState.SWEEPING)
            try:
                async for row in run_paired_sweep(self._sweep_configs):
                    if self._cancel.is_set():
                        await self._set_state(RunState.ABORTED)
                        return
                    await self._emit("sweep_row", **row.to_dict())
            except Exception as exc:
                await self._fail(f"sweep error: {exc}")
                return

            await self._set_state(RunState.DONE)
        except asyncio.CancelledError:
            await self._set_state(RunState.ABORTED)
            raise
        except (LeaseError, DeployError) as exc:
            await self._fail(str(exc))
        except Exception as exc:
            await self._fail(f"internal: {exc!r}")
        finally:
            await self._release_lease_quietly()
            # Sentinel for the SSE consumer.
            await self.events.put(RunEvent(kind="closed",
                                           state=self.state.value))

    async def _fail(self, reason: str) -> None:
        self.error = reason
        self.state = RunState.FAILED
        await self._emit("state", reason=reason)

    async def _on_lease_failure(self, exc: Exception) -> None:
        await self._emit("lease_lost", reason=str(exc))
        await self.cancel()

    async def _release_lease_quietly(self) -> None:
        tok = self._lease_token
        if tok is None:
            return
        try:
            await self._lease.release(tok)
        except Exception:
            pass
        self._lease_token = None
