"""Shared pytest fixtures for the live-eye web tests."""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

import httpx
import pytest

THIS_DIR = Path(__file__).resolve().parent
PKG_DIR = THIS_DIR.parent
EYE_DIR = PKG_DIR.parent
PROJECT_ROOT = EYE_DIR.parent.parent.parent

if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


@pytest.fixture
def fixtures_dir() -> Path:
    return THIS_DIR / "fixtures"


@pytest.fixture
def fake_lease_state():
    """In-memory fpgahubd lease state machine used by MockTransport.

    Behaviour (sufficient for the v1 tests):
      - First POST /links/{id}/lease -> granted.
      - Second POST (different holder while held) -> queued, pos 1.
      - GET /links/{id}/lease returns the current holder + queue.
      - POST .../lease/heartbeat ack-only.
      - DELETE .../lease releases (and promotes the first queued).
      - GET .../lease/wait returns granted if token is current, else 408.
    """
    state = {
        "link": "bridge1",
        "current": None,
        "queue": [],
        "next_token": 1,
    }
    return state


@pytest.fixture
def mock_transport(fake_lease_state):
    state = fake_lease_state

    def _link_ok(link_id: str) -> bool:
        return link_id == state["link"]

    def _link_view():
        cur = state["current"]
        members = [{
            "board": state["link"],
            "current": None if cur is None else {
                "board": state["link"],
                "holder": cur["holder"],
                "user": cur["user"],
                "expires_at": "2030-01-01T00:00:00+00:00",
                "tier": "interactive",
            },
        }]
        if cur is None:
            link_state = "free"
        else:
            link_state = "held"
        return {
            "board": state["link"],
            "state": link_state,
            "description": None,
            "capabilities": [],
            "tags": [],
            "members": members,
            "queue": [
                {"board": state["link"], "holder": q["holder"],
                 "user": q["user"], "position": i + 1,
                 "tier": "interactive"}
                for i, q in enumerate(state["queue"])
            ],
            "queue_length": len(state["queue"]),
            "background_queue": [],
            "background_queue_length": 0,
            "current_tier": ("interactive" if cur else None),
        }

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        method = request.method
        if path.startswith("/api/v1/"):
            path = path[len("/api/v1"):]

        # /links/{id}/lease* and /boards/{id}/lease* — accept both;
        # /links is the modern alias, /boards is the legacy.
        for prefix in ("/links/", "/boards/"):
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix):]
            parts = rest.split("/")
            link_id, suffix = parts[0], "/".join(parts[1:])
            if not _link_ok(link_id):
                # The boards path also 404s for unknown ids; the lease
                # client uses the 404 to skip to the next scope.
                return httpx.Response(404, json={"detail": "not found"})

            if suffix == "lease" and method == "GET":
                return httpx.Response(200, json=_link_view())

            if suffix == "lease" and method == "POST":
                body = json.loads(request.content)
                if state["current"] is None:
                    tok = f"tok-{state['next_token']}"
                    state["next_token"] += 1
                    state["current"] = {
                        "holder": body["holder"],
                        "user": body["user"],
                        "token": tok,
                    }
                    return httpx.Response(200, json={
                        "kind": "granted",
                        "board": link_id,
                        "token": tok,
                        "tier": "interactive",
                        "requeue_on_revoke": False,
                        "leases": [{
                            "board": link_id,
                            "holder": body["holder"],
                            "user": body["user"],
                            "expires_at": "2030-01-01T00:00:00+00:00",
                            "tier": "interactive",
                        }],
                    })
                state["queue"].append({
                    "holder": body["holder"],
                    "user": body["user"],
                })
                return httpx.Response(200, json={
                    "kind": "queued",
                    "board": link_id,
                    "holder": body["holder"],
                    "user": body["user"],
                    "position": len(state["queue"]),
                    "tier": "interactive",
                    "queue": "interactive",
                })

            if suffix == "lease/heartbeat" and method == "POST":
                body = json.loads(request.content)
                cur = state["current"]
                if cur is None or cur["token"] != body["token"]:
                    return httpx.Response(403, json={"detail": "stale token"})
                return httpx.Response(200, json={
                    "board": link_id,
                    "leases": [{
                        "board": link_id,
                        "holder": cur["holder"],
                        "user": cur["user"],
                        "expires_at": "2030-01-01T01:00:00+00:00",
                        "tier": "interactive",
                    }],
                })

            if suffix == "lease" and method == "DELETE":
                body = json.loads(request.content)
                cur = state["current"]
                if cur is None or cur["token"] != body["token"]:
                    return httpx.Response(404, json={"detail": "no lease"})
                state["current"] = None
                if state["queue"]:
                    promoted = state["queue"].pop(0)
                    tok = f"tok-{state['next_token']}"
                    state["next_token"] += 1
                    state["current"] = {
                        "holder": promoted["holder"],
                        "user": promoted["user"],
                        "token": tok,
                    }
                return httpx.Response(200, json={
                    "board": link_id,
                    "released": [link_id],
                })

            if suffix == "lease/wait" and method == "GET":
                want = request.url.params.get("token")
                cur = state["current"]
                if cur and cur["token"] == want:
                    return httpx.Response(200, json={
                        "kind": "granted",
                        "token": cur["token"],
                        "tier": "interactive",
                        "leases": [{
                            "board": link_id,
                            "holder": cur["holder"],
                            "user": cur["user"],
                            "expires_at": "2030-01-01T00:00:00+00:00",
                            "tier": "interactive",
                        }],
                    })
                return httpx.Response(408, json={"detail": "timed out"})

        return httpx.Response(404, json={"detail": f"unmocked {method} {path}"})

    return httpx.MockTransport(handler)


@pytest.fixture
async def lease_client(mock_transport):
    from pynq_host.scripts.eye_toolkit.web import lease as lease_mod

    http = httpx.AsyncClient(
        transport=mock_transport,
        base_url="http://fpgahub/api/v1",
        timeout=5.0,
    )
    c = lease_mod.LeaseClient(client=http, holder="testh", user="testu")
    try:
        yield c
    finally:
        await c.aclose()


@pytest.fixture
def fake_deploy_script(fixtures_dir, tmp_path) -> Path:
    """Path to the canned deploy-emitting shell script used by deploy
    tests. Resolves at fixtures/fake_deploy.sh."""
    p = fixtures_dir / "fake_deploy.sh"
    assert p.exists(), p
    return p


@pytest.fixture
def fake_converge_script(fixtures_dir) -> Path:
    p = fixtures_dir / "fake_converge.sh"
    assert p.exists(), p
    return p


@pytest.fixture
def staged_bitstream_dir(tmp_path: Path) -> Path:
    d = tmp_path / "stage"
    d.mkdir()
    for binname, role, label in (("tidelink.bin", "die_a", "test-A"),
                                 ("tidelink-flip.bin", "die_b", "test-B")):
        (d / binname).write_bytes(b"\x00" * 32)
        (d / f"{binname}.manifest.json").write_text(json.dumps({
            "sha256": "deadbeef" * 8,
            "source_commit": "abcdef0",
            "build_host": "test",
            "build_date": "2026-05-27",
            "target": "pynq-z2-pair",
            "expected_lock_min": 16,
            "label": label,
        }))
    return d


def pytest_collection_modifyitems(config, items):
    # Apply pytest-asyncio "auto" mode without forcing users to install
    # the asyncio_mode = auto config — just decorate every coroutine
    # test function. Idempotent.
    for item in items:
        if isinstance(item, pytest.Function) and asyncio.iscoroutinefunction(item.function):
            item.add_marker(pytest.mark.asyncio)
