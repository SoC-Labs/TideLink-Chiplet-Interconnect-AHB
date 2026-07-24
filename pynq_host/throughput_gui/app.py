"""FastAPI entry for the TideLink throughput GUI (127.0.0.1:8090).

Mirrors the sibling apps in shape (eye_toolkit :8088, stress_toolkit
:8089). P0 endpoint surface (plan §4.2 subset):

  GET  /                            SPA
  GET  /healthz
  GET  /api/tests                   registry (drives the UI form)
  GET  /api/link/status             live criterion-A/B snapshot
  GET  /api/lease
  POST /api/runs                    409 mutex | 412 lease/provenance/gate
  GET  /api/runs                    run index (filterable)
  GET  /api/runs/{id}               full record
  GET  /api/runs/{id}/state         polling fallback
  GET  /api/runs/{id}/events        SSE
  GET  /api/runs/{id}/samples.csv   raw data download
  GET  /api/runs/{id}/samples.ndjson
  POST /api/runs/{id}/abort

DEV MODE: ``--fake`` swaps the SSH agent channels for local --fake
agent subprocesses, auto-grants the lease, synthesizes a manifested
artefact dir (REAL provenance code path, honest sha256s), and accepts
a True board verifier. Everything else — gates, delivery proof, FSM,
store, SSE — is the production code.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import subprocess
import tempfile
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from . import compare, gates, monitor, provenance, tests_registry
from .agent_channel import LocalAgentChannel, SshAgentChannel
from .lease import FakeLeaseClient
from .orchestrator import RunState, ThroughputRun
from .store import RunStore

STATIC_DIR = Path(__file__).parent / "static"
SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"

DEFAULT_PORT = 8090
# fpgahub registry (mapstone-dev daemon, /api/v1/boards):
#   192.168.4.101 = pynq_z2_02_ps  (die_a, "master")
#   192.168.2.101 = pynq_z2_01_ps  (die_b, "slave")
#
# The pair is z2_02 + z2_01, NOT z2_02 + z2_03. Older docs (including
# docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md §2) say z2_03 and this file used
# to default to 192.168.6.101 accordingly; the golden-image recovery of
# 2026-07-24 recorded die_b as z2_01, confirmed by David 2026-07-24.
# Overridable per request (master_ip/slave_ip) for a different pairing.
DEFAULT_MASTER_IP = "192.168.4.101"
DEFAULT_SLAVE_IP = "192.168.2.101"

# The Z2 pair used to be leasable as the single scope "bridge1", which was
# migrated from a board to a link. Neither exists on the current daemon —
# /pairs, /links and /chassis all 404 and /api/v1/boards lists the two PS
# boards individually — so the lease scope is now a LIST and every scope in
# it must be GRANTED before we touch either board. Override with
# TIDELINK_LEASE_BOARDS (comma-separated) when the topology changes again.
# Member names (``lease show`` is per-member); SshLeaseClient maps each to
# its board GROUP for acquire/release, which is where leases actually live.
DEFAULT_BOARDS = os.environ.get(
    "TIDELINK_LEASE_BOARDS", "pynq_z2_02_ps,pynq_z2_01_ps")
DEFAULT_BOARD = DEFAULT_BOARDS          # back-compat alias (str, may be CSV)


def _board_list(board: str) -> list:
    """"a,b" -> ["a", "b"]; a bare name stays a one-element list."""
    return [b.strip() for b in str(board or "").split(",") if b.strip()]


@dataclass
class AppConfig:
    fake: bool = False
    store_root: Path = field(
        default_factory=lambda: Path(os.environ.get(
            "TIDELINK_THROUGHPUT_STORE",
            str(Path.home() / "tidelink_throughput_runs"))))
    artefact_root: Path = field(
        default_factory=lambda: Path(os.environ.get(
            "TIDELINK_THROUGHPUT_ARTEFACTS",
            str(Path.home() / "tidelink_artefacts"))))
    default_artefact_version: str = os.environ.get(
        "TIDELINK_THROUGHPUT_VERSION", "")
    lock_file: Optional[Path] = None
    master_ip: str = DEFAULT_MASTER_IP
    slave_ip: str = DEFAULT_SLAVE_IP
    board: str = DEFAULT_BOARD
    fake_cap_wps: float = 150000.0


FAKE_VERSION = "v0-fake"


class StartRunRequest(BaseModel):
    test: str = "throughput_m2s"
    params: dict = {}
    artefact_version: Optional[str] = None
    master_ip: Optional[str] = None
    slave_ip: Optional[str] = None
    board: Optional[str] = None
    ttl_seconds: int = 1800


class AppState:
    def __init__(self, cfg: AppConfig):
        self.cfg = cfg
        self.store = RunStore(cfg.store_root)
        self.mutex = gates.ExperimentMutex(cfg.lock_file)
        self.lease_client = None
        self.current_run: Optional[ThroughputRun] = None
        self.run_objects: dict = {}
        # injection points for tests
        self.channel_factory = None
        self.board_verifier = None


def _default_channel_factory(state: AppState):
    cfg = state.cfg

    def factory(master_ip: str, slave_ip: str):
        if cfg.fake:
            link_dir = Path(tempfile.mkdtemp(prefix="tlfake-wire-"))
            m = LocalAgentChannel("master", link_dir,
                                  cap_wps=cfg.fake_cap_wps)
            s = LocalAgentChannel("slave", link_dir,
                                  cap_wps=cfg.fake_cap_wps)
            cleanup = lambda: shutil.rmtree(link_dir, ignore_errors=True)
            return m, s, cleanup
        m = SshAgentChannel("master", master_ip)
        s = SshAgentChannel("slave", slave_ip)
        return m, s, (lambda: None)

    return factory


def _default_board_verifier(state: AppState):
    cfg = state.cfg

    def verify(version: str, master_ip: str, slave_ip: str) -> bool:
        if cfg.fake:
            return True
        vdir = cfg.artefact_root / version
        script = SCRIPTS_DIR / "verify_deployed.sh"
        rc = subprocess.run(
            [str(script), "--master", master_ip, "--slave", slave_ip,
             "--artefacts", str(vdir),
             "--manifest", str(vdir / provenance.MASTER_MANIFEST),
             "--manifest-flip", str(vdir / provenance.SLAVE_MANIFEST)],
            capture_output=True, timeout=120).returncode
        return rc == 0

    return verify


def create_app(cfg: Optional[AppConfig] = None, *,
               lease_client=None,
               channel_factory=None,
               board_verifier=None) -> FastAPI:
    cfg = cfg or AppConfig()
    if cfg.fake and not os.environ.get("TIDELINK_THROUGHPUT_ARTEFACTS") \
            and cfg.artefact_root == Path.home() / "tidelink_artefacts":
        # NEVER write synthetic manifests into the real artefact store.
        cfg.artefact_root = cfg.store_root / "fake_artefacts"
    app = FastAPI(title="TideLink throughput GUI", version="0.1.0-p0")
    state = AppState(cfg)
    state.lease_client = lease_client
    state.channel_factory = channel_factory or _default_channel_factory(state)
    state.board_verifier = board_verifier or _default_board_verifier(state)
    app.state.tlthroughput = state

    if cfg.fake:
        # Synthesize a manifested artefact tree so --fake exercises the
        # REAL fail-closed provenance path with honest sha256s.
        provenance.make_fake_artefacts(cfg.artefact_root, FAKE_VERSION)
        if not cfg.default_artefact_version:
            cfg.default_artefact_version = FAKE_VERSION

    @app.on_event("startup")
    async def _startup():
        if state.lease_client is None:
            if cfg.fake:
                state.lease_client = FakeLeaseClient(cfg.board)
            elif os.environ.get("TIDELINK_FPGAHUB_HOST"):
                # The daemon that owns the boards is on another host and
                # we already reach the boards through it as an ssh jump —
                # drive its CLI rather than keep a Bearer token on disk.
                from .lease import SshLeaseClient
                state.lease_client = SshLeaseClient()
            else:
                from .lease import LeaseClient
                state.lease_client = LeaseClient()

    @app.on_event("shutdown")
    async def _shutdown():
        try:
            await monitor.shutdown(state)
        except Exception:
            pass
        if state.current_run is not None:
            await state.current_run.cancel()
        try:
            await state.lease_client.aclose()
        except Exception:
            pass
        state.store.close()

    # Link Monitor (read-only dual-die polling) and the cross-version
    # comparison surface. Both take the AppState lazily so they see the
    # same channel factory / lease client / store the runs use.
    app.include_router(monitor.build_router(lambda: state))
    app.include_router(compare.build_router(lambda: state))

    if STATIC_DIR.is_dir():
        app.mount("/static", StaticFiles(directory=str(STATIC_DIR)),
                  name="static")

    @app.get("/")
    async def root():
        idx = STATIC_DIR / "index.html"
        if idx.is_file():
            return FileResponse(str(idx))
        return JSONResponse({"error": "static/index.html missing"},
                            status_code=500)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True, "version": app.version, "fake": cfg.fake,
                "default_artefact_version": cfg.default_artefact_version}

    @app.get("/api/tests")
    async def api_tests():
        return tests_registry.REGISTRY

    @app.get("/api/lease")
    async def api_lease(board: str = DEFAULT_BOARD):
        out = []
        for name in _board_list(board) or [DEFAULT_BOARD]:
            info = await state.lease_client.current_holder(name)
            out.append(info if isinstance(info, dict) else info.model_dump())
        # One scope still answers with a bare object so existing callers
        # (and the P0 UI) keep working; a real pair answers with a list.
        return out[0] if len(out) == 1 else out

    async def _acquire_all(board: str, ttl: int) -> list:
        """Acquire EVERY lease scope for the pair, or none at all.

        A QUEUED lease is not a lease — running on it deploys over someone
        else's session — so a queue position anywhere aborts the whole
        acquisition and releases what we already took."""
        tokens: list = []
        for name in _board_list(board) or [DEFAULT_BOARD]:
            try:
                result = await state.lease_client.acquire(name, ttl=ttl)
            except BaseException:
                await _release_all(tokens)
                raise
            if hasattr(result, "position"):       # QueueState
                await _release_all(tokens)
                raise HTTPException(
                    412, "lease for %s is QUEUED at position %s, not "
                         "granted — refusing to run over someone else's "
                         "session" % (name, result.position))
            tokens.append(result)
        return tokens

    async def _release_all(tokens) -> None:
        for tok in tokens or []:
            try:
                await state.lease_client.release(tok)
            except Exception:
                pass

    @app.get("/api/link/status")
    async def link_status():
        master_ch, slave_ch, cleanup = state.channel_factory(
            cfg.master_ip, cfg.slave_ip)
        try:
            await master_ch.stage()
            await slave_ch.stage()
            verdict = await gates.link_gate(master_ch, slave_ch)
            return {"ok": verdict.ok, "criterion": verdict.criterion,
                    "reason": verdict.reason, "snapshot": verdict.snapshot}
        except gates.GateError as exc:
            return {"ok": False, "criterion": None, "reason": str(exc),
                    "snapshot": {}}
        finally:
            await master_ch.close()
            await slave_ch.close()
            cleanup()

    # ── runs ──────────────────────────────────────────────────────────

    @app.post("/api/runs", status_code=201)
    async def start_run(req: StartRunRequest):
        # 0. registry + params
        try:
            test = tests_registry.get_test(req.test)
            params = tests_registry.validate_params(req.test, req.params)
        except tests_registry.ParamError as exc:
            raise HTTPException(400, str(exc))

        # in-flight slot
        if (state.current_run is not None
                and state.current_run.state not in
                {RunState.DONE, RunState.ABORTED, RunState.FAILED}):
            raise HTTPException(409, "a run is already in flight")

        master_ip = req.master_ip or cfg.master_ip
        slave_ip = req.slave_ip or cfg.slave_ip
        board = req.board or cfg.board
        version = req.artefact_version or cfg.default_artefact_version
        if not version:
            raise HTTPException(
                412, "no artefact_version given and no default staged — "
                     "provenance is mandatory")

        # 1. cross-toolkit single-experiment mutex
        try:
            state.mutex.acquire("throughput_gui")
        except gates.MutexHeld as exc:
            raise HTTPException(409, str(exc))

        master_ch = slave_ch = None
        cleanup = lambda: None
        lease_tokens: list = []
        try:
            # 2. every lease scope must be GRANTED, not queued
            lease_tokens = await _acquire_all(board, req.ttl_seconds)
            lease_token = lease_tokens[0] if lease_tokens else None

            # 3. provenance manifests (fail-closed)
            try:
                prov = provenance.load_provenance(cfg.artefact_root,
                                                  version)
            except provenance.ProvenanceError as exc:
                raise HTTPException(412, str(exc))

            # 3b. on-board image verification (verify_deployed.sh)
            verified = await asyncio.to_thread(
                state.board_verifier, version, master_ip, slave_ip)
            if not verified:
                raise HTTPException(
                    412, "verify_deployed: image on board does not match "
                         "the staged %s manifests — refusing to run"
                         % version)
            prov["verified_on_board"] = True

            # 4. criterion-A/B link gate (live probes)
            master_ch, slave_ch, cleanup = state.channel_factory(
                master_ip, slave_ip)
            await master_ch.stage()
            await slave_ch.stage()
            try:
                verdict = await gates.link_gate(master_ch, slave_ch)
            except gates.GateError as exc:
                raise HTTPException(412, str(exc))
            if not verdict.ok:
                raise HTTPException(412, "link gate: %s" % verdict.reason)
            prov["phy_id_master"] = verdict.snapshot.get("m_phy_id")
            prov["phy_id_slave"] = verdict.snapshot.get("s_phy_id")

            # admitted — create the record (store re-validates provenance)
            record = state.store.create_run(
                test=req.test, params=params,
                boards={"master": master_ip, "slave": slave_ip,
                        "pair": board},
                provenance=prov,
                lease={"holder": getattr(lease_token, "holder", None),
                       "token_id": getattr(lease_token, "token", None),
                       "scopes": _board_list(board),
                       "scope": "link"},
                gate_snapshot=verdict.snapshot)
        except BaseException:
            state.mutex.release()
            if master_ch is not None:
                await master_ch.close()
            if slave_ch is not None:
                await slave_ch.close()
            cleanup()
            await _release_all(lease_tokens)
            raise

        run_id = record["run_id"]
        lease_refs = list(lease_tokens)

        def _on_finished(rid=run_id, cu=cleanup, toks=lease_refs):
            cu()
            if toks:
                asyncio.ensure_future(_release_all(toks))

        run = ThroughputRun(
            run_id, state.store, master_ch, slave_ch, params,
            mutex=state.mutex, on_finished=_on_finished)
        state.current_run = run
        state.run_objects[run_id] = run
        run.start()
        return {"run_id": run_id, "state": run.state.value,
                "criterion": verdict.criterion, "test": req.test}

    @app.get("/api/runs")
    async def list_runs(test: Optional[str] = None,
                        label: Optional[str] = None,
                        sha: Optional[str] = None,
                        since: Optional[str] = None):
        return state.store.list_runs(test=test, label=label, sha=sha,
                                     since=since)

    def _get_record(run_id: str) -> dict:
        try:
            return state.store.get_run(run_id)
        except KeyError:
            raise HTTPException(404, "no such run")

    @app.get("/api/runs/{run_id}")
    async def get_run(run_id: str):
        return _get_record(run_id)

    @app.get("/api/runs/{run_id}/state")
    async def get_run_state(run_id: str):
        rec = _get_record(run_id)
        return {"run_id": run_id, "state": rec["state"],
                "error": rec.get("error"), "summary": rec.get("summary")}

    @app.post("/api/runs/{run_id}/abort")
    async def abort_run(run_id: str):
        run = state.run_objects.get(run_id)
        if run is None:
            raise HTTPException(404, "no such (live) run")
        await run.cancel()
        return {"run_id": run_id, "state": run.state.value}

    @app.get("/api/runs/{run_id}/samples.csv")
    async def samples_csv(run_id: str):
        _get_record(run_id)
        return PlainTextResponse(
            state.store.samples_csv(run_id), media_type="text/csv",
            headers={"Content-Disposition":
                     "attachment; filename=%s.csv" % run_id})

    @app.get("/api/runs/{run_id}/samples.ndjson")
    async def samples_ndjson(run_id: str):
        _get_record(run_id)
        lines = [json.dumps(s, separators=(",", ":"))
                 for s in state.store.iter_samples(run_id)]
        return PlainTextResponse(
            "\n".join(lines) + ("\n" if lines else ""),
            media_type="application/x-ndjson")

    @app.get("/api/runs/{run_id}/events")
    async def run_events(run_id: str, request: Request):
        run = state.run_objects.get(run_id)
        if run is None:
            raise HTTPException(404, "no such (live) run — use "
                                     "/api/runs/{id} for finished runs")

        async def _gen():
            keepalive = 15.0
            while True:
                if await request.is_disconnected():
                    return
                try:
                    ev = await asyncio.wait_for(run.events.get(),
                                                timeout=keepalive)
                except asyncio.TimeoutError:
                    yield {"event": "ping", "data": "keepalive"}
                    continue
                yield {"event": ev.kind, "data": json.dumps(ev.to_dict())}
                if ev.kind == "closed":
                    return

        return EventSourceResponse(_gen(), ping=15)

    return app


# Module-level ASGI app for uvicorn / the systemd unit (real mode by
# default; set TIDELINK_THROUGHPUT_FAKE=1 for a fake server). Lazy so
# importing this module (e.g. from pytest) has no filesystem side
# effects — the store/artefact dirs are only touched once served.
class _LazyApp:
    def __init__(self):
        self._app: Optional[FastAPI] = None

    async def __call__(self, scope, receive, send):
        if self._app is None:
            self._app = create_app(AppConfig(
                fake=os.environ.get("TIDELINK_THROUGHPUT_FAKE") == "1"))
        await self._app(scope, receive, send)


app = _LazyApp()


def main():
    ap = argparse.ArgumentParser(
        description="TideLink throughput-characterization web server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--fake", action="store_true",
                    help="DEV MODE: local fake agents, no boards/lease")
    ap.add_argument("--store-dir", default=None)
    ap.add_argument("--artefact-dir", default=None)
    ap.add_argument("--artefact-version", default=None)
    ap.add_argument("--lock-file", default=None)
    args = ap.parse_args()
    if args.host == "0.0.0.0":
        raise SystemExit(
            "refusing to bind 0.0.0.0 — the throughput server is "
            "loopback-only; reach it via `ssh -L 8090:localhost:8090`")

    cfg = AppConfig(fake=args.fake)
    if args.store_dir:
        cfg.store_root = Path(args.store_dir)
    if args.artefact_dir:
        cfg.artefact_root = Path(args.artefact_dir)
    elif args.fake and not os.environ.get("TIDELINK_THROUGHPUT_ARTEFACTS"):
        cfg.artefact_root = cfg.store_root / "fake_artefacts"
    if args.artefact_version:
        cfg.default_artefact_version = args.artefact_version
    if args.lock_file:
        cfg.lock_file = Path(args.lock_file)

    import uvicorn
    uvicorn.run(create_app(cfg), host=args.host, port=args.port,
                log_level="info")


if __name__ == "__main__":
    main()
