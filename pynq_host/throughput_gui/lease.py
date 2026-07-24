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


# ── fpgahubd reached over ssh (no Bearer token on disk) ─────────────────

class SshLeaseToken:
    """Granted lease from the CLI on the daemon host."""

    def __init__(self, board: str, token: str, holder: str,
                 user: str = "", expires_at: Optional[str] = None):
        self.board = board
        self.token = token
        self.holder = holder
        self.user = user
        self.expires_at = expires_at
        self.tier = "interactive"
        self.scope = "board"


class SshQueueState:
    def __init__(self, board: str, position: int, holder: str = ""):
        self.board = board
        self.position = position
        self.holder = holder
        self.user = ""
        self.tier = "interactive"
        self.queue = "interactive"


class SshLeaseClient:
    """fpgahub leases driven through ``ssh <host> fpgahub lease ...``.

    Why not the REST client: the fpgahubd that owns the Z2 boards runs on
    the lab host (mapstone-dev). The daemon reachable from this dev box
    has an empty board registry, and the boards themselves are only
    reachable from here through that same host as an ssh jump — so we
    already depend on the ssh path. Driving the CLI over it keeps the
    lease honest without minting and storing a long-lived Bearer token.

    SCOPE: leases live at the BOARD-GROUP level. A Pynq-Z2 is one board
    with two members (``pynq_z2_02`` = ``pynq_z2_02_ps`` +
    ``pynq_z2_02_pl``), and a per-member queue operation is refused with
    HTTP 409 ``board_required``. So this drives ``fpgahub board lease``
    with the GROUP name, stripping a trailing ``_ps``/``_pl`` if a caller
    passes a member. The historical single scope ``bridge1`` does not
    exist on the daemon at all — /pairs, /links and /chassis all 404.

    Parses the CLI's line format:
        acquire -> "granted token=<tok> expires=<iso> tier=<tier>"
                   or a "queued ... position=<n>" line
        release -> "released"   (needs BOTH --holder and --token)
        show    -> "not leased" | "held by <holder> (user <u>, expires <e>)"

    The GRANTED-vs-QUEUED distinction is the whole point: a queued lease
    is not a lease, and running on one means running over someone else's
    session.
    """

    def __init__(self, host: str = "mapstone-dev",
                 holder: Optional[str] = None,
                 ssh_args: Optional[list] = None):
        import os as _os
        import socket as _socket
        self.host = _os.environ.get("TIDELINK_FPGAHUB_HOST", host)
        self.holder = holder or ("tidelink-linkgui-%s" % _socket.gethostname())
        self.ssh_args = ssh_args or ["-o", "BatchMode=yes",
                                     "-o", "ConnectTimeout=10"]

    async def _run(self, args: list, timeout: float = 30.0) -> str:
        import asyncio as _asyncio
        import shlex as _shlex
        cmd = "fpgahub " + " ".join(_shlex.quote(a) for a in args)
        proc = await _asyncio.create_subprocess_exec(
            "ssh", *self.ssh_args, self.host, cmd,
            stdout=_asyncio.subprocess.PIPE,
            stderr=_asyncio.subprocess.PIPE)
        try:
            out, err = await _asyncio.wait_for(proc.communicate(),
                                               timeout=timeout)
        except _asyncio.TimeoutError:
            proc.kill()
            raise LeaseError("fpgahub %s timed out on %s"
                             % (args[1] if len(args) > 1 else args[0],
                                self.host))
        text = (out.decode(errors="replace") + "\n"
                + err.decode(errors="replace")).strip()
        if proc.returncode != 0:
            raise LeaseError("fpgahub %s failed on %s: %s"
                             % (" ".join(args), self.host, text[:300]))
        return text

    @staticmethod
    def group_of(board: str) -> str:
        """``pynq_z2_02_ps`` -> ``pynq_z2_02``; group names pass through."""
        for suffix in ("_ps", "_pl"):
            if board.endswith(suffix):
                return board[:-len(suffix)]
        return board

    async def acquire(self, board: str, ttl: int = 1800):
        board = self.group_of(board)
        text = await self._run(
            ["board", "lease", "acquire", board, "--holder", self.holder,
             "--ttl", str(int(ttl))])
        low = text.lower()
        if "granted" in low:
            fields = {}
            for tok in text.replace("\n", " ").split():
                if "=" in tok:
                    key, _, val = tok.partition("=")
                    fields[key] = val
            if not fields.get("token"):
                raise LeaseError(
                    "fpgahub reported granted but no token: %r" % text)
            return SshLeaseToken(board, fields["token"], self.holder,
                                 expires_at=fields.get("expires"))
        if "queued" in low or "position" in low:
            pos = 0
            for tok in text.replace("\n", " ").split():
                if tok.startswith("position="):
                    try:
                        pos = int(tok.split("=", 1)[1])
                    except ValueError:
                        pos = 0
            return SshQueueState(board, pos)
        raise LeaseError("unparsable fpgahub acquire output: %r" % text)

    async def release(self, token) -> None:
        await self._run(["board", "lease", "release",
                         self.group_of(token.board),
                         "--holder", token.holder, "--token", token.token])

    async def current_holder(self, board: str) -> dict:
        # `lease show` is per-member and works for either name; the group
        # form has no show subcommand, so probe a member.
        text = await self._run(["lease", "show", board])
        flat = " ".join(text.split())
        if flat.lower().startswith("not leased"):
            return {"board": board, "state": "free", "holder": None,
                    "queue_length": 0, "scope": "board"}
        holder = None
        if "held by " in flat:
            holder = flat.split("held by ", 1)[1].split(" ", 1)[0]
        return {"board": board, "state": "held", "holder": holder,
                "raw": flat, "queue_length": 0, "scope": "board"}

    async def aclose(self) -> None:
        return None


# ── Multi-scope helpers (the Z2 "pair" is two independent leases) ───────
#
# The historical single scope "bridge1" is gone, so a pair is leased as a
# LIST of scopes. Both the run path (app.py) and the monitor path
# (monitor.py) must acquire all-or-nothing, so the logic lives here once
# rather than being duplicated — the first copy of it drifted immediately
# and shipped a 404 on real hardware.

def board_list(board) -> list:
    """"a,b" -> ["a", "b"]; a list passes through; blanks dropped."""
    if isinstance(board, (list, tuple)):
        return [str(b).strip() for b in board if str(b).strip()]
    return [b.strip() for b in str(board or "").split(",") if b.strip()]


async def acquire_all(client, board, ttl: int = 1800) -> list:
    """Acquire EVERY scope, or none. Raises QueuedError on any queue.

    A QUEUED lease is not a lease: proceeding on one means running over
    somebody else's session, so a queue position anywhere aborts the whole
    acquisition and hands back what was already taken."""
    tokens: list = []
    for name in board_list(board):
        try:
            result = await client.acquire(name, ttl=ttl)
        except BaseException:
            await release_all(client, tokens)
            raise
        if hasattr(result, "position"):
            await release_all(client, tokens)
            raise QueuedError(name, result.position)
        tokens.append(result)
    return tokens


async def release_all(client, tokens) -> None:
    for tok in tokens or []:
        try:
            await client.release(tok)
        except Exception:
            pass


class QueuedError(RuntimeError):
    def __init__(self, board: str, position):
        self.board = board
        self.position = position
        super().__init__(
            "lease for %s is QUEUED at position %s, not granted — refusing "
            "to run over someone else's session" % (board, position))


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
