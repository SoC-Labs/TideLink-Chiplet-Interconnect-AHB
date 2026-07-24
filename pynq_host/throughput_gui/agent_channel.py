"""Agent transport: push tl_perf_agent.py to a board + drive its
NDJSON/GO-barrier protocol over a persistent pipe.

Two implementations behind one interface:

  * ``LocalAgentChannel`` — DEV MODE. Spawns the agent as a local
    subprocess with ``--fake`` and a shared spool dir, so the entire
    server stack (gates, delivery proof, orchestrator, SSE) exercises
    the REAL protocol with zero hardware.

  * ``SshAgentChannel`` — production. Stages the agent afresh per run
    (cat-over-ssh to /tmp/tl_perf_agent.py — staged-file pattern per
    unjam_fc_node.sh; inline python through double-ssh quoting mangles)
    and runs it under ``sudo python3`` on a persistent SSH channel.
    NOT exercised by the test suite (no board network from CI hosts).

Protocol (see tl_perf_agent.py):
  one-shot:  run --cmd X, parse the single JSON line.
  run:       start --cfg-json, await {"ev":"ready"}, send_go(),
             then iterate events until {"ev":"done"} / EOF.
"""
from __future__ import annotations

import asyncio
import json
import os
import shlex
import sys
import time
from pathlib import Path
from typing import AsyncIterator, Optional

AGENT_PATH = Path(__file__).parent / "agent" / "tl_perf_agent.py"

SSH_COMMON_ARGS = (
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
)


def _ssh_args() -> tuple:
    """SSH_COMMON_ARGS plus an optional jump host.

    The boards sit on private 192.168.x networks that only the lab host
    can route to, so a dev box reaches them through it
    (``TIDELINK_BOARD_SSH_JUMP=mapstone-dev``). Unset on the lab host
    itself, where the boards are directly reachable."""
    jump = os.environ.get("TIDELINK_BOARD_SSH_JUMP", "").strip()
    if not jump:
        return SSH_COMMON_ARGS
    return SSH_COMMON_ARGS + ("-o", "ProxyJump=%s" % jump)


class AgentError(RuntimeError):
    pass


class _BaseChannel:
    """Shared pipe-driving logic. Subclasses provide _argv()/_env()."""

    board: str = "?"

    def __init__(self):
        self._proc: Optional[asyncio.subprocess.Process] = None

    def _argv(self, agent_args: list) -> list:
        raise NotImplementedError

    def _env(self) -> dict:
        return dict(os.environ)

    async def stage(self) -> None:
        """Push the agent to the target (no-op for local channels)."""
        return None

    async def start_run(self, cfg: dict, *, ready_timeout: float = 30.0
                        ) -> None:
        """Launch the agent in run mode and wait for {"ev":"ready"}."""
        argv = self._argv(["--cfg-json", json.dumps(cfg)])
        self._proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=self._env())
        try:
            ev = await asyncio.wait_for(self._readline(),
                                        timeout=ready_timeout)
        except asyncio.TimeoutError:
            await self.close()
            raise AgentError("%s: agent never reported ready" % self.board)
        if ev.get("ev") != "ready":
            await self.close()
            raise AgentError("%s: expected ready, got %r" % (self.board, ev))

    async def send_go(self, deadline_epoch: Optional[float] = None) -> None:
        if self._proc is None or self._proc.stdin is None:
            raise AgentError("%s: channel not started" % self.board)
        line = "GO %f\n" % (deadline_epoch or (time.time() + 3600))
        self._proc.stdin.write(line.encode())
        await self._proc.stdin.drain()

    async def _readline(self) -> dict:
        assert self._proc is not None and self._proc.stdout is not None
        while True:
            raw = await self._proc.stdout.readline()
            if not raw:
                raise AgentError("%s: agent pipe closed" % self.board)
            raw = raw.strip()
            if not raw:
                continue
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                # sudo noise / banners — skip non-JSON lines
                continue

    async def events(self) -> AsyncIterator[dict]:
        """Yield agent events until done/EOF."""
        while True:
            try:
                ev = await self._readline()
            except AgentError:
                return
            yield ev
            if ev.get("ev") == "done":
                return

    async def oneshot(self, cmd: str, *args, timeout: float = 30.0) -> dict:
        """Run one gate/proof command (probe|send4|catch) to completion."""
        argv = self._argv(["--cmd", cmd]
                          + (["--args"] + [str(a) for a in args]
                             if args else []))
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=self._env())
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            # The hung-probe case IS the BUS-ERROR jam class —
            # surface it distinctly so the caller can classify.
            raise AgentError(
                "%s: %s timed out after %.0fs (BUS-ERROR class?)"
                % (self.board, cmd, timeout))
        for raw in reversed(stdout.decode(errors="replace").splitlines()):
            raw = raw.strip()
            if raw.startswith("{"):
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    continue
        raise AgentError(
            "%s: %s produced no JSON (rc=%s, stderr=%r)"
            % (self.board, cmd, proc.returncode,
               stderr.decode(errors="replace")[:200]))

    async def close(self) -> None:
        if self._proc is None:
            return
        if self._proc.returncode is None:
            try:
                self._proc.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(self._proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            pass
        self._proc = None


# ── DEV MODE ──────────────────────────────────────────────────────────────

class LocalAgentChannel(_BaseChannel):
    """Run the agent locally with --fake (no hardware, no network)."""

    def __init__(self, board: str, link_dir: Path, *,
                 cap_wps: float = 150000.0,
                 extra_env: Optional[dict] = None):
        super().__init__()
        self.board = board                       # "master" | "slave"
        self.link_dir = Path(link_dir)
        self.cap_wps = cap_wps
        self.extra_env = dict(extra_env or {})

    def _argv(self, agent_args: list) -> list:
        return [sys.executable, str(AGENT_PATH), "--fake"] + agent_args

    def _env(self) -> dict:
        env = dict(os.environ)
        env.update({
            "TIDELINK_FAKE_LINK_DIR": str(self.link_dir),
            "TIDELINK_FAKE_ROLE": self.board,
            "TIDELINK_FAKE_CAP_WPS": str(self.cap_wps),
        })
        env.update(self.extra_env)
        return env


# ── Production (board over SSH) ──────────────────────────────────────────

class SshAgentChannel(_BaseChannel):
    """Stage + run the agent on a PYNQ over sshpass/ssh.

    Per-run staging (no resident daemon): boards are reflashed/rebooted
    constantly during bring-up; a fresh copy avoids version skew.
    """

    REMOTE_PATH = "/tmp/tl_perf_agent.py"

    def __init__(self, board: str, ip: str, *,
                 user: str = "xilinx",
                 password_env: str = "TIDELINK_BOARD_PASS",
                 password_default: str = "xilinx"):
        super().__init__()
        self.board = board
        self.ip = ip
        self.user = user
        self._password = os.environ.get(password_env, password_default)
        self._staged = False

    async def stage(self) -> None:
        """cat-over-ssh the agent source to the board (quoting-robust)."""
        argv = ["sshpass", "-p", self._password, "ssh", *_ssh_args(),
                "%s@%s" % (self.user, self.ip),
                "cat > %s" % self.REMOTE_PATH]
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE)
        _, stderr = await asyncio.wait_for(
            proc.communicate(AGENT_PATH.read_bytes()), timeout=30)
        if proc.returncode != 0:
            raise AgentError("%s: agent staging failed: %s"
                             % (self.board,
                                stderr.decode(errors="replace")[:200]))
        self._staged = True

    def _remote_cmd(self, agent_args: list) -> str:
        # Propagate the GP1-split base overrides to the board-side agent.
        env_fwd = " ".join(
            "%s=%s" % (k, shlex.quote(os.environ[k]))
            for k in ("TIDELINK_TX_BASE", "TIDELINK_RXFIFO_BASE")
            if k in os.environ)
        inner = "%s python3 %s %s" % (
            env_fwd, self.REMOTE_PATH,
            " ".join(shlex.quote(a) for a in agent_args))
        return "echo %s | sudo -S %s" % (shlex.quote(self._password), inner)

    def _argv(self, agent_args: list) -> list:
        if not self._staged:
            raise AgentError("%s: stage() must run before use" % self.board)
        return ["sshpass", "-p", self._password, "ssh", *_ssh_args(),
                "%s@%s" % (self.user, self.ip),
                self._remote_cmd(agent_args)]
