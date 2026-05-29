"""FastAPI entry for the stress_toolkit web app.

Mirrors pynq_host.scripts.eye_toolkit.web.app in shape:

  GET  /                    SPA
  GET  /healthz
  GET  /api/lease
  POST /api/lease/release
  POST /api/runs            — body picks the test mode
  GET  /api/runs/{id}/state
  POST /api/runs/{id}/abort
  GET  /api/runs/{id}/events (SSE)
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from sse_starlette.sse import EventSourceResponse

from .deploy import DeployRunner
from .lease import LeaseClient, LeaseError
from .mmio_remote import RemoteMmio, RemoteMmioConfig
from .runner import Run, RunState, StressRunOptions
from .stress_modes import (
    AutoConfig, DoorbellStressConfig, FcsmMonitorConfig,
    PacketStressConfig, PhyHealthConfig, PtpConvergenceConfig,
)


STATIC_DIR = Path(__file__).parent / "static"

DEFAULT_STAGE_DIR = "/tmp/tidelink_deploy"
DEFAULT_MASTER_IP = "192.168.4.101"
DEFAULT_SLAVE_IP = "192.168.6.101"
DEFAULT_BOARD = "bridge1"


# ── Request bodies ───────────────────────────────────────────────────────

class PacketCfg(BaseModel):
    packet_size_words: int = 16
    packet_count: int = 100
    direction: str = "both"
    inter_packet_us: float = 0.0


class DoorbellCfg(BaseModel):
    doorbell_count: int = 100
    rate_hz: float = 100.0
    direction: str = "m2s"


class PtpCfg(BaseModel):
    duration_s: float = 60.0
    sample_period_s: float = 0.25
    offset_ok_ns: int = 500
    lock_hold_samples: int = 10
    master_initial_s: int = 100
    slave_initial_s: int = 200
    hw_sync_interval: int = 7_812_500


class PhyCfg(BaseModel):
    poll_period_s: float = 1.0
    duration_s: float = 0.0


class FcsmCfg(BaseModel):
    poll_period_s: float = 0.1
    duration_s: float = 0.0


class AutoCfg(BaseModel):
    duration_s: float = 300.0
    seed: int = 0


class StartRunRequest(BaseModel):
    mode: str = Field(..., description="packet|doorbell|ptp|phy|fcsm|auto")
    stage_dir: str = DEFAULT_STAGE_DIR
    master_ip: str = DEFAULT_MASTER_IP
    slave_ip: str = DEFAULT_SLAVE_IP
    board: str = DEFAULT_BOARD
    skip_deploy: bool = True
    skip_converge: bool = True
    ttl_seconds: int = 1800
    enable_phy_sentinel: bool = True
    packet: Optional[PacketCfg] = None
    doorbell: Optional[DoorbellCfg] = None
    ptp: Optional[PtpCfg] = None
    phy: Optional[PhyCfg] = None
    fcsm: Optional[FcsmCfg] = None
    auto: Optional[AutoCfg] = None


def _to_options(req: StartRunRequest) -> StressRunOptions:
    def _conv(model, dc):
        if model is None:
            return None
        return dc(**model.model_dump())
    return StressRunOptions(
        mode=req.mode,
        stage_dir=req.stage_dir,
        master_ip=req.master_ip,
        slave_ip=req.slave_ip,
        board=req.board,
        skip_deploy=req.skip_deploy,
        skip_converge=req.skip_converge,
        ttl_seconds=req.ttl_seconds,
        enable_phy_sentinel=req.enable_phy_sentinel,
        packet=_conv(req.packet, PacketStressConfig),
        doorbell=_conv(req.doorbell, DoorbellStressConfig),
        ptp=_conv(req.ptp, PtpConvergenceConfig),
        phy=_conv(req.phy, PhyHealthConfig),
        fcsm=_conv(req.fcsm, FcsmMonitorConfig),
        auto=_conv(req.auto, AutoConfig),
    )


# ── State container ──────────────────────────────────────────────────────

class AppState:
    def __init__(self):
        self.lease_client: Optional[LeaseClient] = None
        self.current_run: Optional[Run] = None
        self.run_history: dict[str, Run] = {}
        # Injection points for tests
        self.deploy_factory = None
        self.mmio_factory = None


def create_app(
    *,
    lease_client: Optional[LeaseClient] = None,
    deploy_factory=None,
    mmio_factory=None,
) -> FastAPI:
    app = FastAPI(title="TideLink stress_toolkit", version="1.0.0")
    state = AppState()
    state.lease_client = lease_client
    state.deploy_factory = deploy_factory
    state.mmio_factory = mmio_factory
    app.state.tidestress = state

    @app.on_event("startup")
    async def _startup():
        if state.lease_client is None:
            state.lease_client = LeaseClient()

    @app.on_event("shutdown")
    async def _shutdown():
        if state.current_run is not None:
            await state.current_run.cancel()
        if state.lease_client is not None:
            try:
                await state.lease_client.aclose()
            except Exception:
                pass

    if STATIC_DIR.is_dir():
        app.mount("/static",
                   StaticFiles(directory=str(STATIC_DIR)), name="static")

    @app.get("/")
    async def root():
        idx = STATIC_DIR / "index.html"
        if idx.is_file():
            return FileResponse(str(idx))
        return JSONResponse(
            {"error": "static/index.html missing"}, status_code=500)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True, "version": app.version}

    @app.get("/api/lease")
    async def get_lease(board: str = DEFAULT_BOARD):
        try:
            info = await state.lease_client.current_holder(board)
        except LeaseError as exc:
            raise HTTPException(503, str(exc))
        return info.model_dump()

    @app.post("/api/lease/release")
    async def release_lease():
        if (state.current_run is not None
                and state.current_run._lease_token is not None):
            try:
                await state.lease_client.release(
                    state.current_run._lease_token)
                state.current_run._lease_token = None
                return {"ok": True}
            except LeaseError as exc:
                raise HTTPException(500, str(exc))
        raise HTTPException(404, "no lease currently held by this server")

    @app.post("/api/runs")
    async def start_run(req: StartRunRequest):
        if (state.current_run is not None
                and state.current_run.state not in {
                    RunState.DONE, RunState.ABORTED, RunState.FAILED}):
            raise HTTPException(409, "a run is already in flight")

        if state.deploy_factory is not None:
            deploy_runner = state.deploy_factory(req)
        else:
            deploy_runner = DeployRunner(
                stage_dir=req.stage_dir,
                board_a_ip=req.master_ip,
                board_b_ip=req.slave_ip,
            )

        if state.mmio_factory is not None:
            master_factory, slave_factory = state.mmio_factory(req)
        else:
            def _mk_real(ip: str):
                return RemoteMmio(RemoteMmioConfig(ip=ip))
            master_factory = lambda: _mk_real(req.master_ip)
            slave_factory = lambda: _mk_real(req.slave_ip)

        opts = _to_options(req)
        run = Run(state.lease_client, deploy_runner,
                  master_factory, slave_factory, opts)
        state.current_run = run
        state.run_history[run.run_id] = run
        run.start()
        return {"run_id": run.run_id, "state": run.state.value}

    @app.get("/api/runs/{run_id}/state")
    async def get_run_state(run_id: str):
        run = state.run_history.get(run_id)
        if run is None:
            raise HTTPException(404, "no such run")
        return {"run_id": run.run_id, "state": run.state.value,
                "error": run.error, "mode": run.options.mode}

    @app.post("/api/runs/{run_id}/abort")
    async def abort_run(run_id: str):
        run = state.run_history.get(run_id)
        if run is None:
            raise HTTPException(404, "no such run")
        await run.cancel()
        return {"run_id": run.run_id, "state": run.state.value}

    @app.get("/api/runs/{run_id}/events")
    async def run_events(run_id: str, request: Request):
        run = state.run_history.get(run_id)
        if run is None:
            raise HTTPException(404, "no such run")

        async def _gen():
            keepalive_interval = 15.0
            while True:
                if await request.is_disconnected():
                    return
                try:
                    ev = await asyncio.wait_for(
                        run.events.get(), timeout=keepalive_interval)
                except asyncio.TimeoutError:
                    yield {"event": "ping", "data": "keepalive"}
                    continue
                payload = json.dumps(ev.to_dict())
                yield {"event": ev.kind, "data": payload}
                if ev.kind == "closed":
                    return

        return EventSourceResponse(_gen(), ping=15)

    return app


# Module-level app for uvicorn
app = create_app()


def main():
    ap = argparse.ArgumentParser(
        description="TideLink stress_toolkit web server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8089)
    args = ap.parse_args()
    if args.host == "0.0.0.0":
        raise SystemExit(
            "refusing to bind 0.0.0.0 — the stress server is loopback-only; "
            "reach it via `ssh -L 8089:localhost:8089`")
    import uvicorn
    uvicorn.run(
        "pynq_host.scripts.stress_toolkit.web.app:app",
        host=args.host, port=args.port, log_level="info",
    )


if __name__ == "__main__":
    main()
