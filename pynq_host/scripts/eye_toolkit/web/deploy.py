"""Subprocess wrapper around deploy_pair.sh + bringup_pair_converge.sh.

We do NOT modify the underlying shell scripts (per the proposal). Instead
we run them as subprocesses, parse line-by-line for known markers
(DEPLOY-FAIL / DEPLOY-ABORT, "16/16 lanes locked", "==== done ====",
"RESULT: CONVERGED ...", per-iter lane-count lines), and re-emit typed
DeployEvent records the runner can fan out to SSE.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import signal
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncIterator, List, Optional


@dataclass
class StagedBitstream:
    stage_dir: Path
    primary_bin: Path
    flip_bin: Optional[Path]
    primary_manifest: dict
    flip_manifest: Optional[dict]

    @property
    def primary_label(self) -> str:
        return self.primary_manifest.get("label", "unverified")

    @property
    def primary_sha256(self) -> str:
        return self.primary_manifest.get("sha256", "")

    @property
    def commit(self) -> str:
        return self.primary_manifest.get("source_commit", "")


@dataclass
class DeployEvent:
    kind: str
    board: Optional[str] = None
    detail: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {"kind": self.kind, "board": self.board, **self.detail}


class DeployError(RuntimeError):
    pass


_DEPLOY_FAIL_RX = re.compile(r"DEPLOY-(?:FAIL|ABORT): (.+)$")
_DONE_RX = re.compile(r"^==== (\S+) done \(sha256=([0-9a-f]+).*\) ====")
_BRINGUP_RESULT_RX = re.compile(
    r"^RESULT: CONVERGED — full (\d+)/(\d+) bidirectional link at iteration (\d+)")
_BRINGUP_FAIL_RX = re.compile(
    r"^RESULT: NOT CONVERGED in (\d+) re-deploys")
_BEST_SEEN_RX = re.compile(r"^\s*Best seen: (\d+)/(\d+) at iteration (\d+)")
_ITER_RX = re.compile(
    r"^(\d+)\s*\|\s*\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s*\|"
    r"\s*\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s*\|\s*(\d+)\s*$"
)


def parse_manifest(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise DeployError(f"manifest {path}: {exc}") from exc


class DeployRunner:
    """Drives `deploy_pair.sh` (parallel per board) and then
    `bringup_pair_converge.sh`, yielding DeployEvents."""

    def __init__(
        self,
        stage_dir: str | Path,
        board_a_ip: str,
        board_b_ip: str,
        *,
        deploy_script: str | Path | None = None,
        converge_script: str | Path | None = None,
        env: Optional[dict] = None,
    ):
        self.stage_dir = Path(stage_dir)
        self.board_a_ip = board_a_ip
        self.board_b_ip = board_b_ip
        scripts_dir = Path(__file__).resolve().parents[2]
        self.deploy_script = Path(deploy_script) if deploy_script \
            else scripts_dir / "deploy_pair.sh"
        self.converge_script = Path(converge_script) if converge_script \
            else scripts_dir / "bringup_pair_converge.sh"
        self.env = env
        self._procs: List[asyncio.subprocess.Process] = []
        self._cancelled = asyncio.Event()

    def verify_stage(self) -> StagedBitstream:
        d = self.stage_dir
        if not d.is_dir():
            raise DeployError(
                f"stage dir {d} not found — stage tidelink.bin first")
        primary = d / "tidelink.bin"
        if not primary.is_file():
            raise DeployError(f"missing {primary}")
        primary_mf_path = d / "tidelink.bin.manifest.json"
        if not primary_mf_path.is_file():
            raise DeployError(
                f"missing manifest {primary_mf_path} — deploy_pair.sh "
                "will hard-abort an unverified deploy")
        primary_mf = parse_manifest(primary_mf_path)
        flip = d / "tidelink-flip.bin"
        flip_mf = None
        if flip.is_file():
            flip_mf_path = d / "tidelink-flip.bin.manifest.json"
            if not flip_mf_path.is_file():
                raise DeployError(f"missing manifest {flip_mf_path}")
            flip_mf = parse_manifest(flip_mf_path)
        else:
            flip = None
        return StagedBitstream(
            stage_dir=d,
            primary_bin=primary,
            flip_bin=flip,
            primary_manifest=primary_mf,
            flip_manifest=flip_mf,
        )

    async def _run_proc(self, argv: list[str], *, board: Optional[str],
                        env: Optional[dict] = None) -> AsyncIterator[str]:
        run_env = os.environ.copy()
        if self.env:
            run_env.update(self.env)
        if env:
            run_env.update(env)
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=run_env,
            start_new_session=True,
        )
        self._procs.append(proc)
        try:
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                yield line.decode(errors="replace").rstrip("\n")
            await proc.wait()
        finally:
            if proc in self._procs:
                self._procs.remove(proc)
        if proc.returncode and proc.returncode != 0:
            raise DeployError(
                f"{argv[0]} (board={board}) exit {proc.returncode}")

    async def _deploy_one(self, ip: str, role: str, board_label: str
                          ) -> AsyncIterator[DeployEvent]:
        argv = [
            "bash", str(self.deploy_script),
            ip, board_label, role, str(self.stage_dir),
        ]
        manifest = self.stage_dir / (
            "tidelink-flip.bin.manifest.json" if role == "die_b"
            else "tidelink.bin.manifest.json")
        if manifest.is_file():
            argv.extend(["--manifest", str(manifest)])
        yield DeployEvent("deploying", board=board_label,
                          detail={"ip": ip, "role": role})
        try:
            async for line in self._run_proc(argv, board=board_label):
                m = _DEPLOY_FAIL_RX.search(line)
                if m:
                    yield DeployEvent("deploy_failed", board=board_label,
                                      detail={"reason": m.group(1),
                                              "line": line})
                    continue
                m = _DONE_RX.match(line)
                if m:
                    yield DeployEvent("deployed", board=board_label,
                                      detail={"sha12": m.group(2)[:12]})
                    continue
                if "unreachable" in line.lower():
                    yield DeployEvent("unreachable", board=board_label,
                                      detail={"line": line})
        except DeployError as exc:
            yield DeployEvent("deploy_failed", board=board_label,
                              detail={"reason": str(exc)})

    async def _bringup(self) -> AsyncIterator[DeployEvent]:
        argv = ["bash", str(self.converge_script)]
        env = {
            "MASTER_IP": self.board_a_ip,
            "SLAVE_IP": self.board_b_ip,
            "ARTEFACTS": str(self.stage_dir),
            "DEPLOY_PAIR": str(self.deploy_script),
        }
        yield DeployEvent("bringup_started", detail={"master": self.board_a_ip,
                                                     "slave": self.board_b_ip})
        max_lanes = 16
        try:
            async for line in self._run_proc(argv, board=None, env=env):
                m = _BRINGUP_RESULT_RX.match(line)
                if m:
                    locked, total, it = (int(m.group(1)),
                                         int(m.group(2)),
                                         int(m.group(3)))
                    max_lanes = total
                    yield DeployEvent("lane_count", detail={
                        "count": locked, "max": total, "iteration": it})
                    yield DeployEvent("bringup_ok", detail={
                        "iteration": it, "count": locked, "max": total})
                    continue
                m = _BRINGUP_FAIL_RX.match(line)
                if m:
                    yield DeployEvent("bringup_failed", detail={
                        "max_retries": int(m.group(1))})
                    continue
                m = _BEST_SEEN_RX.match(line)
                if m:
                    yield DeployEvent("lane_count", detail={
                        "count": int(m.group(1)),
                        "max": int(m.group(2)),
                        "iteration": int(m.group(3)),
                        "best": True,
                    })
                    continue
                m = _ITER_RX.match(line)
                if m:
                    it, a, b, tot = (int(m.group(1)), int(m.group(2)),
                                     int(m.group(3)), int(m.group(4)))
                    yield DeployEvent("lane_count", detail={
                        "iteration": it, "a": a, "b": b,
                        "count": tot, "max": max_lanes})
                    continue
                if "unreachable" in line.lower():
                    yield DeployEvent("unreachable",
                                      detail={"line": line})
        except DeployError as exc:
            yield DeployEvent("bringup_failed", detail={"reason": str(exc)})

    async def deploy_both(self, *, skip_deploy: bool = False,
                          skip_converge: bool = False
                          ) -> AsyncIterator[DeployEvent]:
        if not skip_deploy:
            # Parallel die_a / die_b — exactly the bringup_pair_converge
            # pattern (re-rolls role_lock skew by issuing both deploys
            # within one SSH RTT of each other).
            async def _stream(role: str, ip: str, label: str):
                events = []
                async for ev in self._deploy_one(ip, role, label):
                    events.append(ev)
                return events

            a_task = asyncio.create_task(
                _stream("die_a", self.board_a_ip, "z2_die_a"))
            b_task = asyncio.create_task(
                _stream("die_b", self.board_b_ip, "z2_die_b"))
            try:
                a_events, b_events = await asyncio.gather(a_task, b_task)
            except asyncio.CancelledError:
                a_task.cancel()
                b_task.cancel()
                raise
            for ev in a_events + b_events:
                yield ev
        if not skip_converge:
            async for ev in self._bringup():
                yield ev

    async def cancel(self) -> None:
        self._cancelled.set()
        for proc in list(self._procs):
            if proc.returncode is not None:
                continue
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        await asyncio.sleep(0.2)
        for proc in list(self._procs):
            if proc.returncode is not None:
                continue
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
