"""API surface against the in-process ASGI app (fake backend)."""
from __future__ import annotations

import asyncio
import json

import httpx
import pytest
from asgi_lifespan import LifespanManager

from pynq_host.throughput_gui.app import AppConfig, create_app
from pynq_host.throughput_gui.lease import FakeLeaseClient
from .conftest import FAST_PARAMS


async def _client(app):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                             base_url="http://test")


async def _wait_terminal(client, run_id, timeout_s=30.0):
    for _ in range(int(timeout_s / 0.1)):
        s = (await client.get(f"/api/runs/{run_id}/state")).json()
        if s["state"] in ("done", "failed", "aborted"):
            return s
        await asyncio.sleep(0.1)
    raise AssertionError("run never reached a terminal state")


async def test_healthz_and_tests_registry(fake_app):
    async with LifespanManager(fake_app):
        async with await _client(fake_app) as c:
            h = (await c.get("/healthz")).json()
            assert h["ok"] is True and h["fake"] is True
            t = (await c.get("/api/tests")).json()
            assert "throughput_m2s" in t
            assert t["throughput_m2s"]["hazard"] == "ahb_tx"


async def test_link_status(fake_app):
    async with LifespanManager(fake_app):
        async with await _client(fake_app) as c:
            st = (await c.get("/api/link/status")).json()
            assert st["ok"] is True and st["criterion"] == "B"


async def test_run_end_to_end_with_provenance(fake_app, app_cfg):
    async with LifespanManager(fake_app):
        async with await _client(fake_app) as c:
            r = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": FAST_PARAMS})
            assert r.status_code == 201, r.text
            run_id = r.json()["run_id"]
            assert r.json()["criterion"] == "B"

            final = await _wait_terminal(c, run_id)
            assert final["state"] == "done", final
            assert final["summary"]["throughput_mbps_mean"] > 0

            # full record: provenance sha256s match the staged manifests
            rec = (await c.get(f"/api/runs/{run_id}")).json()
            man = json.loads(
                (app_cfg.artefact_root / "v0-fake"
                 / "tidelink.bin.manifest.json").read_text())
            assert rec["provenance"]["master"]["sha256"] == man["sha256"]
            assert rec["provenance"]["verified_on_board"] is True
            assert rec["provenance"]["fifo_label"] == "fake01k"
            assert rec["gate_snapshot"]["criterion"] == "B"

            # samples downloadable
            csv = (await c.get(f"/api/runs/{run_id}/samples.csv")).text
            assert csv.splitlines()[0].startswith("t_ns,")
            assert len(csv.splitlines()) > 4
            nd = (await c.get(f"/api/runs/{run_id}/samples.ndjson")).text
            assert json.loads(nd.splitlines()[0])["ev"] == "sample"

            # index lists it
            idx = (await c.get("/api/runs")).json()
            assert idx[0]["run_id"] == run_id
            assert idx[0]["state"] == "done"


async def test_409_when_run_in_flight(fake_app):
    async with LifespanManager(fake_app):
        async with await _client(fake_app) as c:
            slow = dict(FAST_PARAMS, duration_s=8.0)
            r1 = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": slow})
            assert r1.status_code == 201, r1.text
            r2 = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": FAST_PARAMS})
            assert r2.status_code == 409
            rid = r1.json()["run_id"]
            await c.post(f"/api/runs/{rid}/abort")
            final = await _wait_terminal(c, rid)
            assert final["state"] == "aborted"


async def test_412_when_provenance_missing(tmp_path):
    """Fail-closed end-to-end: healthy fake link, but nothing staged
    for the requested artefact version -> 412, no run record."""
    cfg = AppConfig(fake=True,
                    store_root=tmp_path / "runs",
                    artefact_root=tmp_path / "artefacts",
                    default_artefact_version="v0-fake",
                    lock_file=tmp_path / "hw.lock")
    app = create_app(cfg, lease_client=FakeLeaseClient())
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": FAST_PARAMS,
                "artefact_version": "v9-not-staged"})
            assert r.status_code == 412
            assert "v9-not-staged" in r.json()["detail"]
            assert (await c.get("/api/runs")).json() == []
            # and the mutex was released: a good run still admits
            r2 = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": FAST_PARAMS})
            assert r2.status_code == 201, r2.text
            await _wait_terminal(c, r2.json()["run_id"])


async def test_412_when_link_down(tmp_path, app_cfg):
    """Criterion-B gate refusal: ahb_tx hazard never admitted on a
    down link."""
    from pynq_host.throughput_gui.agent_channel import LocalAgentChannel

    def down_factory(master_ip, slave_ip):
        link = tmp_path / "downwire"
        link.mkdir(exist_ok=True)
        m = LocalAgentChannel("master", link,
                              extra_env={"TIDELINK_FAKE_LINK_DOWN": "1"})
        s = LocalAgentChannel("slave", link)
        return m, s, (lambda: None)

    app = create_app(app_cfg, lease_client=FakeLeaseClient(),
                     channel_factory=down_factory)
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": FAST_PARAMS})
            assert r.status_code == 412
            assert "link" in r.json()["detail"].lower()
            assert (await c.get("/api/runs")).json() == []


async def test_jam_autoabort_marks_run_failed(tmp_path, app_cfg):
    """Sentinel: CLASSIC jam signature mid-run -> auto-abort, FAILED."""
    from pynq_host.throughput_gui.agent_channel import LocalAgentChannel

    def jam_factory(master_ip, slave_ip):
        link = tmp_path / "jamwire"
        link.mkdir(exist_ok=True)
        m = LocalAgentChannel(
            "master", link,
            extra_env={"TIDELINK_FAKE_JAM_AT_S": "0.6"})
        s = LocalAgentChannel("slave", link)
        return m, s, (lambda: None)

    app = create_app(app_cfg, lease_client=FakeLeaseClient(),
                     channel_factory=jam_factory)
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.post("/api/runs", json={
                "test": "throughput_m2s",
                "params": dict(FAST_PARAMS, duration_s=5.0)})
            assert r.status_code == 201, r.text
            final = await _wait_terminal(c, r.json()["run_id"])
            assert final["state"] == "failed"
            assert "CLASSIC" in final["error"]


async def test_unknown_test_and_bad_params(fake_app):
    async with LifespanManager(fake_app):
        async with await _client(fake_app) as c:
            r = await c.post("/api/runs", json={"test": "nope"})
            assert r.status_code == 400
            r = await c.post("/api/runs", json={
                "test": "throughput_m2s",
                "params": {"burst_words": 100000}})
            assert r.status_code == 400
            r = await c.get("/api/runs/bogus/state")
            assert r.status_code == 404


async def test_sse_stream_carries_samples(fake_app):
    async with LifespanManager(fake_app):
        async with await _client(fake_app) as c:
            r = await c.post("/api/runs", json={
                "test": "throughput_m2s", "params": FAST_PARAMS})
            assert r.status_code == 201, r.text
            rid = r.json()["run_id"]
            kinds = []
            async with c.stream("GET", f"/api/runs/{rid}/events") as resp:
                assert resp.status_code == 200
                event_type = None
                async for raw in resp.aiter_lines():
                    if not raw:
                        event_type = None
                        continue
                    if raw.startswith("event: "):
                        event_type = raw[len("event: "):].strip()
                    elif raw.startswith("data: "):
                        kinds.append(event_type or "message")
                        if event_type == "closed":
                            break
            assert "delivery_proof" in kinds
            assert kinds.count("sample") >= 3
            assert "closed" in kinds
