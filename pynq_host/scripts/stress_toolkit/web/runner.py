"""Per-session Run object for the stress_toolkit web app.

State machine:

    IDLE -> LEASE_ACQUIRING -> [DEPLOYING -> CONVERGING ->] RUNNING
         -> DONE | ABORTED | FAILED

Events on ``self.events`` flow to the SSE consumer. Unlike eye_toolkit
the "running" phase dispatches to one (or more, for AUTO mode) of the
six stress modes in stress_modes.py.

For each test mode the same lease/deploy/converge preamble is reused
(via the shared ``DeployRunner`` re-export from
``eye_toolkit/web/deploy.py``). The runner doesn't repeat the deploy
plumbing.
"""
from __future__ import annotations

import asyncio
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, AsyncIterator, Optional

from .deploy import DeployError, DeployRunner
from .lease import LeaseClient, LeaseError, LeaseToken, QueueState
from .mmio_remote import MmioInterface
from .stress_modes import (
    AutoConfig, DoorbellStressConfig, FcsmMonitorConfig,
    ModeContext, ModeEvent, PacketStressConfig, PhyHealthConfig,
    PtpConvergenceConfig, auto_mix, doorbell_stress, fcsm_monitor,
    packet_stress, phy_health_monitor, ptp_convergence,
)


class RunState(str, Enum):
    IDLE = "idle"
    LEASE_ACQUIRING = "lease_acquiring"
    LEASE_QUEUED = "lease_queued"
    DEPLOYING = "deploying"
    CONVERGING = "converging"
    RUNNING = "running"
    DONE = "done"
    ABORTED = "aborted"
    FAILED = "failed"


_TERMINAL = {RunState.DONE, RunState.ABORTED, RunState.FAILED}


# ── Per-mode configs are tagged unions in the request body. ───────────────

@dataclass
class StressRunOptions:
    mode: str                  # "packet"|"doorbell"|"ptp"|"phy"|"fcsm"|"auto"
    stage_dir: str
    master_ip: str
    slave_ip: str
    board: str = "bridge1"
    ttl_seconds: int = 1800
    skip_deploy: bool = True   # default: assume link is up
    skip_converge: bool = True
    # Per-mode configs — exactly one is used per run.
    packet: Optional[PacketStressConfig] = None
    doorbell: Optional[DoorbellStressConfig] = None
    ptp: Optional[PtpConvergenceConfig] = None
    phy: Optional[PhyHealthConfig] = None
    fcsm: Optional[FcsmMonitorConfig] = None
    auto: Optional[AutoConfig] = None
    # Whether to run the PHY-health background sentinel for THIS run.
    enable_phy_sentinel: bool = True


@dataclass
class RunEvent:
    kind: str
    state: str
    detail: dict = field(default_factory=dict)
    ts: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return {"kind": self.kind, "state": self.state,
                "ts": self.ts, **self.detail}


class Run:
    """One stress run. Created per /api/runs POST."""

    def __init__(
        self,
        lease_client: LeaseClient,
        deploy_runner: Optional[DeployRunner],
        mmio_master_factory,
        mmio_slave_factory,
        options: StressRunOptions,
        *,
        run_id: Optional[str] = None,
    ):
        self.run_id = run_id or uuid.uuid4().hex[:12]
        self._lease = lease_client
        self._deploy = deploy_runner
        self._mmio_master_factory = mmio_master_factory
        self._mmio_slave_factory = mmio_slave_factory
        self.options = options
        self.state: RunState = RunState.IDLE
        self.events: asyncio.Queue[RunEvent] = asyncio.Queue()
        self._task: Optional[asyncio.Task] = None
        self._cancel = asyncio.Event()
        self._health_alarm = asyncio.Event()
        self._lease_token: Optional[LeaseToken] = None
        self.error: Optional[str] = None
        self._sentinel_task: Optional[asyncio.Task] = None

    async def _emit(self, kind: str, **detail) -> None:
        await self.events.put(RunEvent(kind=kind, state=self.state.value,
                                       detail=detail))

    async def _set_state(self, st: RunState, **detail) -> None:
        self.state = st
        await self._emit("state", **detail)

    def start(self) -> asyncio.Task:
        if self._task is not None:
            return self._task
        self._task = asyncio.create_task(self._run(),
                                          name=f"stressrun-{self.run_id}")
        return self._task

    async def cancel(self) -> None:
        if self.state in _TERMINAL:
            return
        self._cancel.set()
        if self._deploy is not None:
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
        if self._sentinel_task is not None:
            self._sentinel_task.cancel()
            try:
                await self._sentinel_task
            except (asyncio.CancelledError, Exception):
                pass

    async def _run(self) -> None:
        try:
            await self._acquire_lease()
            if self.state == RunState.FAILED:
                return
            await self._maybe_deploy_and_converge()
            if self.state == RunState.FAILED:
                return
            await self._run_mode()
            if self.state not in _TERMINAL:
                await self._set_state(RunState.DONE)
        except asyncio.CancelledError:
            await self._set_state(RunState.ABORTED)
            raise
        except (LeaseError, DeployError) as exc:
            await self._fail(str(exc))
        except Exception as exc:  # noqa: BLE001
            await self._fail(f"internal: {exc!r}")
        finally:
            await self._release_lease_quietly()
            if self._sentinel_task is not None:
                self._sentinel_task.cancel()
            await self.events.put(RunEvent(
                kind="closed", state=self.state.value))

    async def _acquire_lease(self) -> None:
        await self._set_state(RunState.LEASE_ACQUIRING)
        result = await self._lease.acquire(self.options.board,
                                            ttl=self.options.ttl_seconds)
        if isinstance(result, QueueState):
            await self._set_state(RunState.LEASE_QUEUED,
                                   position=result.position)
            await self._fail(
                f"queued at position {result.position}; abort or wait")
            return
        self._lease_token = result
        await self._emit("lease_acquired", holder=result.holder,
                          token=result.token,
                          expires_at=result.expires_at)
        self._lease.start_heartbeat(result, ttl=self.options.ttl_seconds,
                                     on_failure=self._on_lease_failure)

    async def _maybe_deploy_and_converge(self) -> None:
        if self._deploy is None:
            return
        if self.options.skip_deploy and self.options.skip_converge:
            return
        if not self.options.skip_deploy:
            await self._set_state(RunState.DEPLOYING)
            self._deploy.verify_stage()
        async for ev in self._deploy.deploy_both(
                skip_deploy=self.options.skip_deploy,
                skip_converge=self.options.skip_converge):
            if self._cancel.is_set():
                await self._set_state(RunState.ABORTED)
                return
            if ev.kind == "bringup_started":
                await self._set_state(RunState.CONVERGING)
            await self._emit("deploy",
                              deploy_kind=ev.kind, board=ev.board,
                              **ev.detail)
            if ev.kind == "bringup_failed":
                await self._fail("bringup did not converge")
                return

    async def _run_mode(self) -> None:
        await self._set_state(RunState.RUNNING, mode=self.options.mode)
        master = self._mmio_master_factory()
        slave = self._mmio_slave_factory()
        ctx = ModeContext(master=master, slave=slave,
                          cancel=self._cancel,
                          health_alarm=self._health_alarm)
        try:
            # Spin up the PHY-health sentinel in parallel for AHB /
            # doorbell / PTP / auto runs (not for the phy/fcsm modes
            # themselves — those *are* the sentinel).
            if (self.options.enable_phy_sentinel
                    and self.options.mode in ("packet", "doorbell",
                                              "ptp", "auto")):
                self._sentinel_task = asyncio.create_task(
                    self._phy_sentinel_loop(ctx),
                    name=f"phy-sentinel-{self.run_id}")

            stream = self._dispatch_mode(ctx)
            async for ev in stream:
                if self._cancel.is_set():
                    await self._set_state(RunState.ABORTED)
                    return
                await self._emit(ev.kind, **ev.detail)
        finally:
            await master.aclose()
            await slave.aclose()

    def _dispatch_mode(self, ctx: ModeContext) -> AsyncIterator[ModeEvent]:
        m = self.options.mode
        if m == "packet":
            return packet_stress(ctx,
                                  self.options.packet or PacketStressConfig())
        if m == "doorbell":
            return doorbell_stress(ctx,
                                    self.options.doorbell
                                    or DoorbellStressConfig())
        if m == "ptp":
            return ptp_convergence(ctx,
                                    self.options.ptp
                                    or PtpConvergenceConfig())
        if m == "phy":
            return phy_health_monitor(ctx,
                                       self.options.phy
                                       or PhyHealthConfig())
        if m == "fcsm":
            return fcsm_monitor(ctx,
                                 self.options.fcsm or FcsmMonitorConfig())
        if m == "auto":
            return auto_mix(ctx, self.options.auto or AutoConfig())
        raise ValueError(f"unknown stress mode {m!r}")

    async def _phy_sentinel_loop(self, ctx: ModeContext) -> None:
        """Background PHY-health monitor for non-phy-mode runs.

        Sets ``ctx.health_alarm`` when an anomaly fires; the main mode
        generators poll ``ctx.aborted`` (which checks the alarm) and
        exit cleanly."""
        try:
            async for ev in phy_health_monitor(
                    ctx, PhyHealthConfig(poll_period_s=1.0)):
                if self._cancel.is_set():
                    return
                # Surface health samples + anomalies to the SSE stream.
                await self._emit("phy_sentinel",
                                  sentinel_kind=ev.kind, **ev.detail)
        except asyncio.CancelledError:
            return
        except Exception as exc:  # noqa: BLE001
            await self._emit("phy_sentinel_error", reason=repr(exc))

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
