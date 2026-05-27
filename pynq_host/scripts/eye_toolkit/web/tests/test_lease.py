"""Tests for lease.LeaseClient against a mocked fpgahubd."""
from __future__ import annotations

import asyncio

import pytest

from pynq_host.scripts.eye_toolkit.web import lease as lease_mod


async def test_acquire_granted(lease_client):
    tok = await lease_client.acquire("bridge1", ttl=300)
    assert isinstance(tok, lease_mod.LeaseToken)
    assert tok.board == "bridge1"
    assert tok.token.startswith("tok-")
    assert tok.holder == "testh"
    assert tok.scope == "pairs"


async def test_acquire_queued_when_held(lease_client, fake_lease_state):
    # First acquire takes the lease.
    first = await lease_client.acquire("bridge1")
    assert isinstance(first, lease_mod.LeaseToken)
    # Simulate a second different holder asking — flip identity, ask
    # again on the same MockTransport-backed client.
    lease_client.holder = "other-user"
    lease_client.user = "other-user"
    second = await lease_client.acquire("bridge1")
    assert isinstance(second, lease_mod.QueueState)
    assert second.position == 1


async def test_heartbeat_then_release(lease_client, fake_lease_state):
    tok = await lease_client.acquire("bridge1")
    await lease_client.heartbeat(tok, ttl=60)
    await lease_client.release(tok)
    assert fake_lease_state["current"] is None


async def test_current_holder_reflects_state(lease_client, fake_lease_state):
    info = await lease_client.current_holder("bridge1")
    assert info.state == "free"
    assert info.holder is None

    tok = await lease_client.acquire("bridge1")
    info2 = await lease_client.current_holder("bridge1")
    assert info2.state == "held"
    assert info2.holder == "testh"
    await lease_client.release(tok)


async def test_wait_for_grant_returns_held(lease_client):
    tok = await lease_client.acquire("bridge1")
    granted = await lease_client.wait_for_grant("bridge1", tok.token, timeout=1.0)
    assert granted.token == tok.token


async def test_wait_for_grant_times_out_for_unknown_token(lease_client):
    await lease_client.acquire("bridge1")
    with pytest.raises(lease_mod.LeaseError):
        await lease_client.wait_for_grant("bridge1", "tok-bogus", timeout=0.5)


async def test_unknown_board_raises(lease_client):
    with pytest.raises(lease_mod.LeaseError):
        await lease_client.acquire("not-a-real-board")


async def test_heartbeat_task_runs_and_cancels(lease_client, fake_lease_state):
    tok = await lease_client.acquire("bridge1")
    # ttl=3 -> interval = max(1.0, 1.0) == 1.0s ; we want the heartbeat
    # to actually fire at least once during the test without the test
    # itself being slow. The default interval floor is 1.0s.
    calls = []

    orig = lease_client.heartbeat

    async def _spy(token, ttl=None):
        calls.append(token.token)
        await orig(token, ttl=ttl or 3)

    lease_client.heartbeat = _spy  # type: ignore[assignment]
    task = lease_client.start_heartbeat(tok, ttl=3)
    await asyncio.sleep(1.3)
    await lease_client.stop_heartbeat(tok)
    assert task.cancelled() or task.done()
    assert calls, "expected at least one heartbeat tick"


def test_resolve_auth_missing_raises(monkeypatch, tmp_path):
    monkeypatch.setattr(lease_mod, "DEFAULT_SOCKET", str(tmp_path / "nope.sock"))
    monkeypatch.delenv("FPGAHUB_TOKEN", raising=False)
    with pytest.raises(lease_mod.LeaseError):
        lease_mod.resolve_auth()


def test_resolve_auth_token_path(monkeypatch, tmp_path):
    monkeypatch.setattr(lease_mod, "DEFAULT_SOCKET", str(tmp_path / "nope.sock"))
    monkeypatch.setenv("FPGAHUB_TOKEN", "secret")
    monkeypatch.setenv("FPGAHUB_ADDR", "127.0.0.1:7245")
    auth = lease_mod.resolve_auth()
    assert auth.token == "secret"
    assert auth.addr == "127.0.0.1:7245"
