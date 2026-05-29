"""FastAPI app exposing the live-lane-phase runner via HTTP + SSE."""
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
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from .deploy import DeployRunner
from .lease import LeaseClient, LeaseError, LeaseAuth
from .runner import Run, RunOptions, RunState
from .sweep_live import SweepConfig

STATIC_DIR = Path(__file__).parent / "static"

DEFAULT_STAGE_DIR = "/tmp/tidelink_deploy"
DEFAULT_MASTER_IP = "192.168.4.101"
DEFAULT_SLAVE_IP = "192.168.6.101"
DEFAULT_BOARD = "bridge1"


class StartRunRequest(BaseModel):
    stage_dir: str = DEFAULT_STAGE_DIR
    master_ip: str = DEFAULT_MASTER_IP
    slave_ip: str = DEFAULT_SLAVE_IP
    board: str = DEFAULT_BOARD
    skip_deploy: bool = False
    skip_converge: bool = False
    ttl_seconds: int = 1800


class AppState:
    def __init__(self):
        self.lease_client: Optional[LeaseClient] = None
        self.current_run: Optional[Run] = None
        self.run_history: dict[str, Run] = {}
        # The optional injection point lets tests stand up the app
        # without a real LeaseClient / DeployRunner / sweep configs.
        self.deploy_factory = None
        self.sweep_factory = None


def create_app(
    *,
    lease_client: Optional[LeaseClient] = None,
    deploy_factory=None,
    sweep_factory=None,
) -> FastAPI:
    app = FastAPI(title="TideLink live-lane-phase", version="1.0.0")
    state = AppState()
    state.lease_client = lease_client
    state.deploy_factory = deploy_factory
    state.sweep_factory = sweep_factory
    app.state.tideeye = state

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
        app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    @app.get("/")
    async def root():
        idx = STATIC_DIR / "index.html"
        if idx.is_file():
            return FileResponse(str(idx))
        return JSONResponse({"error": "static/index.html missing"}, status_code=500)

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
            raise HTTPException(409, "a run is already in flight; "
                                "abort it before starting a new one")
        if state.deploy_factory is not None:
            deploy_runner = state.deploy_factory(req)
        else:
            deploy_runner = DeployRunner(
                stage_dir=req.stage_dir,
                board_a_ip=req.master_ip,
                board_b_ip=req.slave_ip,
            )
        if state.sweep_factory is not None:
            sweep_configs = state.sweep_factory(req)
        else:
            sweep_configs = [
                SweepConfig(board="master", ip=req.master_ip),
                SweepConfig(board="slave", ip=req.slave_ip),
            ]
        opts = RunOptions(
            stage_dir=req.stage_dir,
            board=req.board,
            master_ip=req.master_ip,
            slave_ip=req.slave_ip,
            ttl_seconds=req.ttl_seconds,
            skip_deploy=req.skip_deploy,
            skip_converge=req.skip_converge,
        )
        run = Run(state.lease_client, deploy_runner, sweep_configs, opts)
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
                "error": run.error}

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


# Module-level app for `uvicorn pynq_host.scripts.eye_toolkit.web.app:app`
app = create_app()


def main():
    ap = argparse.ArgumentParser(
        description="TideLink live-lane-phase web server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8088)
    args = ap.parse_args()
    if args.host == "0.0.0.0":
        raise SystemExit(
            "refusing to bind 0.0.0.0 — the live-lane-phase server is "
            "loopback-only; reach it via `ssh -L 8088:localhost:8088`")
    import uvicorn
    uvicorn.run(
        "pynq_host.scripts.eye_toolkit.web.app:app",
        host=args.host, port=args.port, log_level="info",
    )


if __name__ == "__main__":
    main()
