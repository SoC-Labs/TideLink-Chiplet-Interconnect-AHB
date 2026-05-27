"""TestClient-driven happy-path SSE consumption."""
from __future__ import annotations

import asyncio
import json
import time

import httpx
import pytest
from asgi_lifespan import LifespanManager

from pynq_host.scripts.eye_toolkit.web import (
    app as app_mod,
    deploy as deploy_mod,
    lease as lease_mod,
)
from pynq_host.scripts.eye_toolkit.web.sweep_live import SweepConfig


def _stub_sweep_factory(_req):
    state = {"phy": 0}

    def rd(a):
        return state["phy"] if a == 0x44030000 else 0x00ff

    def wr(a, sh, msk, v):
        if a == 0x44030000:
            state["phy"] = (v << sh) & (msk << sh)

    return [
        SweepConfig(board="master", ip="10.0.0.1", settle_s=0.0,
                    read_fn=rd, write_fn=wr),
        SweepConfig(board="slave", ip="10.0.0.2", settle_s=0.0,
                    read_fn=rd, write_fn=wr),
    ]


async def _make_app(lease_client, fake_deploy_script, fake_converge_script,
                    staged_dir):
    def deploy_factory(req):
        return deploy_mod.DeployRunner(
            stage_dir=staged_dir,
            board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
            deploy_script=fake_deploy_script,
            converge_script=fake_converge_script,
        )

    app = app_mod.create_app(
        lease_client=lease_client,
        deploy_factory=deploy_factory,
        sweep_factory=_stub_sweep_factory,
    )
    return app


async def test_happy_path_sse(lease_client, staged_bitstream_dir,
                              fake_deploy_script, fake_converge_script):
    app = await _make_app(lease_client, fake_deploy_script,
                          fake_converge_script, staged_bitstream_dir)
    async with LifespanManager(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport,
                                     base_url="http://test") as client:
            health = await client.get("/healthz")
            assert health.status_code == 200
            assert health.json()["ok"] is True

            r = await client.post("/api/runs", json={
                "stage_dir": str(staged_bitstream_dir),
                "master_ip": "10.0.0.1",
                "slave_ip": "10.0.0.2",
                "board": "bridge1",
                "skip_deploy": False,
                "skip_converge": False,
            })
            assert r.status_code == 200, r.text
            run_id = r.json()["run_id"]

            # Drain SSE stream.
            kinds = []
            sweep_rows = 0
            async with client.stream("GET",
                                     f"/api/runs/{run_id}/events") as resp:
                assert resp.status_code == 200
                event_type = None
                deadline = time.time() + 10.0
                async for raw in resp.aiter_lines():
                    if time.time() > deadline:
                        break
                    if not raw:
                        event_type = None
                        continue
                    if raw.startswith("event: "):
                        event_type = raw[len("event: "):].strip()
                    elif raw.startswith("data: "):
                        kinds.append(event_type or "message")
                        if event_type == "sweep_row":
                            sweep_rows += 1
                        if event_type == "closed":
                            break
        assert "lease_acquired" in kinds
        assert "closed" in kinds
        assert sweep_rows == 32


async def test_409_when_run_in_flight(lease_client, staged_bitstream_dir,
                                      fake_deploy_script,
                                      fake_converge_script, tmp_path):
    # Slow deploy so the first run is still running when the second
    # request comes in.
    slow = tmp_path / "slow_deploy.sh"
    slow.write_text("#!/bin/bash\nsleep 5\necho '==== L done (sha256=aa) ===='\n")
    slow.chmod(0o755)

    def deploy_factory(req):
        return deploy_mod.DeployRunner(
            stage_dir=staged_bitstream_dir,
            board_a_ip="10.0.0.1", board_b_ip="10.0.0.2",
            deploy_script=slow,
            converge_script=fake_converge_script,
        )

    app = app_mod.create_app(
        lease_client=lease_client,
        deploy_factory=deploy_factory,
        sweep_factory=_stub_sweep_factory,
    )
    async with LifespanManager(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport,
                                     base_url="http://test") as client:
            r1 = await client.post("/api/runs", json={
                "stage_dir": str(staged_bitstream_dir),
                "master_ip": "10.0.0.1", "slave_ip": "10.0.0.2",
                "board": "bridge1",
            })
            assert r1.status_code == 200
            await asyncio.sleep(0.2)
            r2 = await client.post("/api/runs", json={
                "stage_dir": str(staged_bitstream_dir),
                "master_ip": "10.0.0.1", "slave_ip": "10.0.0.2",
                "board": "bridge1",
            })
            assert r2.status_code == 409, r2.text
            # Clean up: abort run 1.
            run_id = r1.json()["run_id"]
            await client.post(f"/api/runs/{run_id}/abort")


async def test_run_state_endpoint(lease_client, staged_bitstream_dir,
                                  fake_deploy_script,
                                  fake_converge_script):
    app = await _make_app(lease_client, fake_deploy_script,
                          fake_converge_script, staged_bitstream_dir)
    async with LifespanManager(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport,
                                     base_url="http://test") as client:
            r = await client.post("/api/runs", json={
                "stage_dir": str(staged_bitstream_dir),
                "master_ip": "10.0.0.1", "slave_ip": "10.0.0.2",
                "board": "bridge1",
                "skip_deploy": True, "skip_converge": True,
            })
            run_id = r.json()["run_id"]
            # Wait for run to finish.
            for _ in range(50):
                s = await client.get(f"/api/runs/{run_id}/state")
                if s.json()["state"] in ("done", "failed", "aborted"):
                    break
                await asyncio.sleep(0.1)
            assert s.json()["state"] == "done"

            # Unknown run id -> 404.
            r2 = await client.get("/api/runs/bogus/state")
            assert r2.status_code == 404


async def test_get_lease_endpoint(lease_client, staged_bitstream_dir,
                                  fake_deploy_script, fake_converge_script):
    app = await _make_app(lease_client, fake_deploy_script,
                          fake_converge_script, staged_bitstream_dir)
    async with LifespanManager(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport,
                                     base_url="http://test") as client:
            r = await client.get("/api/lease?board=bridge1")
            assert r.status_code == 200
            body = r.json()
            assert body["board"] == "bridge1"
            assert body["state"] == "free"


def test_cli_refuses_0_0_0_0(monkeypatch):
    import sys
    monkeypatch.setattr(sys, "argv",
                        ["app", "--host", "0.0.0.0"])
    with pytest.raises(SystemExit) as exc:
        app_mod.main()
    assert "loopback" in str(exc.value)
