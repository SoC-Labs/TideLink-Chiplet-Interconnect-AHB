"""Lease access for the throughput GUI.

Real mode: re-export of ``pynq_host.scripts.eye_toolkit.web.lease``
(same single-source-of-truth trick stress_toolkit uses) — fpgahub REST
client with unix-socket auth + Bearer fallback and the critical
GRANTED-vs-QUEUED distinction (a queued lease deploys over someone
else's session).

Dev mode: ``FakeLeaseClient`` grants instantly so the --fake stack
needs no fpgahubd.
"""
from __future__ import annotations

from typing import Optional

try:  # real client — requires httpx/pydantic (present in the venv)
    from pynq_host.scripts.eye_toolkit.web.lease import (  # noqa: F401
        LeaseAuth,
        LeaseClient,
        LeaseError,
        LeaseHolderInfo,
        LeaseToken,
        QueueState,
        DEFAULT_SOCKET,
        DEFAULT_TCP_PORT,
        DEFAULT_TTL_S,
        resolve_auth,
    )
except Exception:  # pragma: no cover — minimal envs without the siblings
    LeaseClient = None  # type: ignore

    class LeaseError(RuntimeError):  # type: ignore
        pass


class FakeLeaseToken:
    board = "bridge1"
    token = "fake-token"
    holder = "throughput-gui-fake"
    user = "fake"
    expires_at: Optional[str] = None


class FakeLeaseClient:
    """Auto-granting lease stub for --fake mode and the pytest suite."""

    def __init__(self, board: str = "bridge1"):
        self.board = board
        self.acquired = 0
        self.released = 0

    async def acquire(self, board: str, ttl: int = 1800):
        self.acquired += 1
        tok = FakeLeaseToken()
        tok.board = board
        return tok

    async def release(self, token) -> None:
        self.released += 1

    async def current_holder(self, board: str) -> dict:
        return {"board": board, "state": "fake",
                "holder": "throughput-gui-fake", "queue_length": 0}

    async def aclose(self) -> None:
        return None
