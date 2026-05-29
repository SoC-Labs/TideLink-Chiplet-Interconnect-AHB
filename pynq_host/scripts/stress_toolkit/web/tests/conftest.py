"""Shared pytest fixtures for the stress_toolkit web tests.

Re-uses the lease MockTransport pattern from
``pynq_host.scripts.eye_toolkit.web.tests.conftest`` — instead of
duplicating the implementation we import the lease_client / mock_transport
fixtures via pytest fixture discovery (conftest is auto-loaded per
package, so we just shim it).
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path
from typing import Iterator

import httpx
import pytest

THIS_DIR = Path(__file__).resolve().parent
WEB_DIR = THIS_DIR.parent
STRESS_DIR = WEB_DIR.parent
PROJECT_ROOT = STRESS_DIR.parent.parent.parent

if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


# ── Lease state machine — same shape as eye_toolkit's. ───────────────────

@pytest.fixture
def fake_lease_state():
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
        link_state = "free" if cur is None else "held"
        return {
            "board": state["link"], "state": link_state,
            "description": None, "capabilities": [], "tags": [],
            "members": members,
            "queue": [],
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
        for prefix in ("/pairs/", "/chassis/", "/boards/", "/links/"):
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix):]
            parts = rest.split("/")
            link_id, suffix = parts[0], "/".join(parts[1:])
            if link_id != state["link"]:
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
                        "kind": "granted", "board": link_id, "token": tok,
                        "tier": "interactive", "requeue_on_revoke": False,
                        "leases": [{
                            "board": link_id, "holder": body["holder"],
                            "user": body["user"],
                            "expires_at": "2030-01-01T00:00:00+00:00",
                            "tier": "interactive",
                        }],
                    })
                state["queue"].append({
                    "holder": body["holder"], "user": body["user"]})
                return httpx.Response(200, json={
                    "kind": "queued", "board": link_id,
                    "holder": body["holder"], "user": body["user"],
                    "position": len(state["queue"]),
                    "tier": "interactive", "queue": "interactive",
                })
            if suffix == "lease/heartbeat" and method == "POST":
                body = json.loads(request.content)
                cur = state["current"]
                if cur is None or cur["token"] != body["token"]:
                    return httpx.Response(403, json={"detail": "stale"})
                return httpx.Response(200, json={
                    "board": link_id,
                    "leases": [{
                        "board": link_id,
                        "holder": cur["holder"], "user": cur["user"],
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
                return httpx.Response(200, json={
                    "board": link_id, "released": [link_id]})
        return httpx.Response(404, json={"detail": f"unmocked {method} {path}"})

    return httpx.MockTransport(handler)


@pytest.fixture
async def lease_client(mock_transport):
    from pynq_host.scripts.stress_toolkit.web import lease as lease_mod

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


# ── Pair of FakeMmio: master / slave with shared state ────────────────────

@pytest.fixture
def pair_state() -> dict:
    """Shared backing store for the master/slave FakeMmio pair."""
    return {"master": {}, "slave": {}}


def pytest_collection_modifyitems(config, items):
    for item in items:
        if isinstance(item, pytest.Function) and asyncio.iscoroutinefunction(item.function):
            item.add_marker(pytest.mark.asyncio)
