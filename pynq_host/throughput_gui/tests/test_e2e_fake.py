"""Smoke: boot the REAL server process in --fake mode (uvicorn over a
loopback TCP port) and complete one canned run end-to-end via HTTP —
the same path a browser takes through the ssh -L tunnel."""
from __future__ import annotations

import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[3]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def fake_server(tmp_path):
    port = _free_port()
    proc = subprocess.Popen(
        [sys.executable, "-m", "pynq_host.throughput_gui.app",
         "--fake", "--port", str(port),
         "--store-dir", str(tmp_path / "runs"),
         "--lock-file", str(tmp_path / "hw.lock")],
        cwd=str(PROJECT_ROOT),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    try:
        deadline = time.time() + 30
        last = None
        while time.time() < deadline:
            if proc.poll() is not None:
                out = proc.stdout.read().decode(errors="replace")
                raise AssertionError("server died at boot:\n" + out)
            try:
                if httpx.get(base + "/healthz",
                             timeout=1.0).status_code == 200:
                    break
            except httpx.HTTPError as exc:
                last = exc
                time.sleep(0.2)
        else:
            raise AssertionError(f"server never became healthy: {last}")
        yield base
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_fake_mode_canned_run_over_http(fake_server):
    base = fake_server
    h = httpx.get(base + "/healthz").json()
    assert h["fake"] is True
    assert h["default_artefact_version"] == "v0-fake"

    # SPA + vendored plotly served
    assert httpx.get(base + "/").status_code == 200
    assert httpx.get(
        base + "/static/vendor/plotly.min.js").status_code == 200

    # link is "up" (criterion B) on the fake wire
    st = httpx.get(base + "/api/link/status", timeout=30).json()
    assert st["ok"] is True and st["criterion"] == "B"

    # one canned M->S throughput run
    r = httpx.post(base + "/api/runs", json={
        "test": "throughput_m2s",
        "params": {"burst_words": 16, "duration_s": 2.0, "win_s": 0.25},
    }, timeout=60)
    assert r.status_code == 201, r.text
    run_id = r.json()["run_id"]

    deadline = time.time() + 60
    while time.time() < deadline:
        s = httpx.get(base + f"/api/runs/{run_id}/state").json()
        if s["state"] in ("done", "failed", "aborted"):
            break
        time.sleep(0.25)
    assert s["state"] == "done", s
    assert s["summary"]["throughput_mbps_mean"] > 0

    rec = httpx.get(base + f"/api/runs/{run_id}").json()
    assert rec["provenance"]["master"]["sha256"]
    assert rec["provenance"]["verified_on_board"] is True

    csv = httpx.get(base + f"/api/runs/{run_id}/samples.csv").text
    assert len(csv.splitlines()) > 5
