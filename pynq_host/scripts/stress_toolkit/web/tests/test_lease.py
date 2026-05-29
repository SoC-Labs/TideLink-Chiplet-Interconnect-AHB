"""Tests for the lease.LeaseClient re-export."""
from __future__ import annotations

import pytest

from pynq_host.scripts.stress_toolkit.web import lease as lease_mod


async def test_acquire_granted(lease_client):
    tok = await lease_client.acquire("bridge1", ttl=300)
    assert isinstance(tok, lease_mod.LeaseToken)
    assert tok.board == "bridge1"
    assert tok.token.startswith("tok-")


async def test_release(lease_client, fake_lease_state):
    tok = await lease_client.acquire("bridge1")
    await lease_client.release(tok)
    assert fake_lease_state["current"] is None


async def test_unknown_board_raises(lease_client):
    with pytest.raises(lease_mod.LeaseError):
        await lease_client.acquire("not-a-real-board")
