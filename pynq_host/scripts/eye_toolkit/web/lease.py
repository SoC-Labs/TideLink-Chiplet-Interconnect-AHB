"""fpgahubd REST client wrapper for the live-eye web app.

`bridge1` was historically a board, was migrated to a *link* (see
fpgahub/src/fpgahub/migrate.py:239 and the /api/v1/links/{id}/lease
routes added in api/v1.py:3399 onwards). The wrapper here picks the
right endpoint at runtime: try the link path first, fall back to the
board path on 404. Board path is the historical alias and may still
exist for some deployments.

Auth: prefer the local unix socket at /run/fpgahub/fpgahub.sock (no
token required, filesystem perms gate access). Fall back to a Bearer
token (FPGAHUB_TOKEN env var) for remote / TLS deployments.
"""
from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass
from typing import Optional

import httpx
from pydantic import BaseModel

DEFAULT_SOCKET = "/run/fpgahub/fpgahub.sock"
DEFAULT_TCP_PORT = 7245
DEFAULT_TTL_S = 1800


class LeaseToken(BaseModel):
    board: str
    token: str
    holder: str
    user: str
    tier: str = "interactive"
    expires_at: Optional[str] = None
    scope: str = "link"


class QueueState(BaseModel):
    board: str
    holder: str
    user: str
    position: int
    tier: str = "interactive"
    queue: str = "interactive"


class LeaseHolderInfo(BaseModel):
    board: str
    state: str
    holder: Optional[str] = None
    user: Optional[str] = None
    expires_at: Optional[str] = None
    queue_length: int = 0
    scope: str = "link"


class LeaseError(RuntimeError):
    pass


@dataclass
class LeaseAuth:
    """How to reach fpgahubd. Exactly one of socket_path / (addr, token)
    is set."""
    socket_path: Optional[str] = None
    addr: Optional[str] = None
    token: Optional[str] = None


def resolve_auth() -> LeaseAuth:
    """Pick auth strategy at module load: unix socket if accessible,
    else Bearer token from env. Fails loudly if neither is workable."""
    if os.access(DEFAULT_SOCKET, os.W_OK):
        return LeaseAuth(socket_path=DEFAULT_SOCKET)
    tok = os.environ.get("FPGAHUB_TOKEN")
    if tok:
        addr = os.environ.get("FPGAHUB_ADDR", f"127.0.0.1:{DEFAULT_TCP_PORT}")
        return LeaseAuth(addr=addr, token=tok)
    raise LeaseError(
        f"no fpgahubd auth available: unix socket {DEFAULT_SOCKET!r} not "
        "writable and FPGAHUB_TOKEN env var not set. Either join group 'fpga' "
        "for socket access, or export FPGAHUB_TOKEN=<bearer> (and optionally "
        "FPGAHUB_ADDR=host:port)."
    )


def _build_client(auth: LeaseAuth, *, timeout: float = 30.0) -> httpx.AsyncClient:
    headers: dict[str, str] = {}
    if auth.token:
        headers["Authorization"] = f"Bearer {auth.token}"
    if auth.socket_path:
        transport = httpx.AsyncHTTPTransport(uds=auth.socket_path)
        return httpx.AsyncClient(
            transport=transport,
            base_url="http://fpgahub/api/v1",
            headers=headers,
            timeout=timeout,
        )
    if not auth.addr:
        raise LeaseError("LeaseAuth must specify socket_path or addr")
    scheme = "https" if ":443" in auth.addr or auth.addr.endswith(":443") else "http"
    return httpx.AsyncClient(
        base_url=f"{scheme}://{auth.addr}/api/v1",
        headers=headers,
        timeout=timeout,
    )


class LeaseClient:
    """Thin async client for fpgahubd lease endpoints.

    `board` here is the lease scope id — for `bridge1` this is currently
    a coordinated *link*, so the wrapper hits /links/{id}/lease first
    and falls back to /boards/{id}/lease only if the link route 404s.
    """

    def __init__(self, base_url: Optional[str] = None,
                 auth: Optional[LeaseAuth] = None,
                 *,
                 client: Optional[httpx.AsyncClient] = None,
                 holder: Optional[str] = None,
                 user: Optional[str] = None):
        self._auth = auth or (LeaseAuth() if client is not None else resolve_auth())
        self._owns_client = client is None
        if client is not None:
            self._http = client
        else:
            self._http = _build_client(self._auth)
        self.base_url = base_url
        self.holder = holder or os.environ.get("USER", "tideeye")
        self.user = user or self.holder
        self._scope_cache: dict[str, str] = {}
        self._hb_tasks: dict[str, asyncio.Task] = {}

    async def aclose(self) -> None:
        for t in list(self._hb_tasks.values()):
            t.cancel()
        for t in list(self._hb_tasks.values()):
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        self._hb_tasks.clear()
        if self._owns_client:
            await self._http.aclose()

    async def _scope_for(self, board: str) -> str:
        """Resolve whether `board` lives under /links/{id} or
        /boards/{id}. Cached after first probe."""
        if board in self._scope_cache:
            return self._scope_cache[board]
        r = await self._http.get(f"/links/{board}/lease")
        if r.status_code != 404:
            self._scope_cache[board] = "links"
            return "links"
        r = await self._http.get(f"/boards/{board}/lease")
        if r.status_code != 404:
            self._scope_cache[board] = "boards"
            return "boards"
        raise LeaseError(
            f"{board!r} is not a known fpgahub link or board (404 from both "
            "/links/{id}/lease and /boards/{id}/lease)"
        )

    async def acquire(self, board: str, ttl: int = DEFAULT_TTL_S):
        scope = await self._scope_for(board)
        body = {
            "holder": self.holder,
            "user": self.user,
            "ttl_seconds": ttl,
        }
        r = await self._http.post(f"/{scope}/{board}/lease", json=body)
        if r.status_code == 409:
            raise LeaseError(f"409 conflict acquiring {board}: {r.text}")
        if r.status_code != 200:
            raise LeaseError(f"acquire {board} HTTP {r.status_code}: {r.text}")
        data = r.json()
        kind = data.get("kind")
        if kind == "granted":
            return LeaseToken(
                board=data.get("board", board),
                token=data["token"],
                holder=self.holder,
                user=self.user,
                tier=data.get("tier", "interactive"),
                expires_at=(data.get("leases") or [{}])[0].get("expires_at"),
                scope=scope,
            )
        if kind == "queued":
            return QueueState(
                board=data.get("board", board),
                holder=data.get("holder", self.holder),
                user=data.get("user", self.user),
                position=int(data.get("position", 0)),
                tier=data.get("tier", "interactive"),
                queue=data.get("queue", "interactive"),
            )
        raise LeaseError(f"acquire {board}: unexpected response {data!r}")

    async def heartbeat(self, token: LeaseToken, ttl: int = DEFAULT_TTL_S) -> None:
        scope = token.scope or await self._scope_for(token.board)
        body = {"holder": token.holder, "token": token.token, "ttl_seconds": ttl}
        r = await self._http.post(
            f"/{scope}/{token.board}/lease/heartbeat", json=body)
        if r.status_code != 200:
            raise LeaseError(
                f"heartbeat {token.board} HTTP {r.status_code}: {r.text}")

    async def release(self, token: LeaseToken) -> None:
        scope = token.scope or await self._scope_for(token.board)
        body = {"holder": token.holder, "token": token.token}
        r = await self._http.request(
            "DELETE", f"/{scope}/{token.board}/lease", json=body)
        if r.status_code not in (200, 204):
            raise LeaseError(
                f"release {token.board} HTTP {r.status_code}: {r.text}")
        await self.stop_heartbeat(token)

    async def wait_for_grant(self, board: str, token: str,
                             timeout: float = 60.0) -> LeaseToken:
        scope = await self._scope_for(board)
        r = await self._http.get(
            f"/{scope}/{board}/lease/wait",
            params={"token": token, "timeout": timeout},
        )
        if r.status_code == 408:
            raise LeaseError(f"wait_for_grant {board} timed out after {timeout}s")
        if r.status_code != 200:
            raise LeaseError(
                f"wait_for_grant {board} HTTP {r.status_code}: {r.text}")
        data = r.json()
        leases = data.get("leases") or [{}]
        first = leases[0]
        return LeaseToken(
            board=board,
            token=data["token"],
            holder=first.get("holder", self.holder),
            user=first.get("user", self.user),
            tier=data.get("tier", "interactive"),
            expires_at=first.get("expires_at"),
            scope=scope,
        )

    async def current_holder(self, board: str) -> LeaseHolderInfo:
        scope = await self._scope_for(board)
        r = await self._http.get(f"/{scope}/{board}/lease")
        if r.status_code != 200:
            raise LeaseError(
                f"current_holder {board} HTTP {r.status_code}: {r.text}")
        data = r.json()
        members = data.get("members") or []
        first_held = next(
            (m for m in members if m.get("current") is not None), None)
        if first_held is None:
            return LeaseHolderInfo(
                board=data.get("board", board),
                state=data.get("state", "free"),
                holder=None,
                user=None,
                expires_at=None,
                queue_length=int(data.get("queue_length", 0)),
                scope=scope,
            )
        cur = first_held["current"]
        return LeaseHolderInfo(
            board=data.get("board", board),
            state=data.get("state", "held"),
            holder=cur.get("holder"),
            user=cur.get("user"),
            expires_at=cur.get("expires_at"),
            queue_length=int(data.get("queue_length", 0)),
            scope=scope,
        )

    def start_heartbeat(self, token: LeaseToken, ttl: int = DEFAULT_TTL_S,
                        on_failure=None) -> asyncio.Task:
        interval = max(ttl / 3.0, 1.0)

        async def _loop():
            try:
                while True:
                    await asyncio.sleep(interval)
                    try:
                        await self.heartbeat(token, ttl)
                    except Exception as exc:
                        if on_failure is not None:
                            try:
                                await on_failure(exc)
                            except Exception:
                                pass
                        return
            except asyncio.CancelledError:
                return

        task = asyncio.create_task(_loop(), name=f"lease-hb-{token.board}")
        self._hb_tasks[token.board] = task
        return task

    async def stop_heartbeat(self, token: LeaseToken) -> None:
        task = self._hb_tasks.pop(token.board, None)
        if task is None:
            return
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass
