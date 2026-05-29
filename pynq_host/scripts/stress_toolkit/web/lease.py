"""Re-export of pynq_host.scripts.eye_toolkit.web.lease.

The two web tools share fpgahub lease semantics 1:1. Wrapping with a
re-export keeps imports symmetric (``from .lease import LeaseClient``
works in both packages) while keeping a single source of truth.
"""
from __future__ import annotations

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
