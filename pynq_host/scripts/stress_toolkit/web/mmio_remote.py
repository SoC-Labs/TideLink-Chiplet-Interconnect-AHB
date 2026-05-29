"""Async SSH-driven /dev/mem accessor — Python port of the
``remote_w`` / ``remote_r`` helpers in
``pynq_host/scripts/_ptp_common.sh``.

Why: the stress_toolkit runs *off-board* on mapstone-dev, not on the
PYNQ board itself. The bash bringup scripts SSH into each board and
exec a small Python snippet that mmaps /dev/mem; we do the same here
but async so the runner can fan-out to two boards concurrently.

Each board needs sshpass + sudo + python3 (already present on the
SoCLabs Pynq-Z2 image).

This module is **net-touching** — it does not have unit tests against
real hardware. Unit tests use ``FakeMmio`` (an in-memory dict) that
implements the same read/write interface; the runner takes the
interface, not a concrete subclass, so the tests substitute it.
"""
from __future__ import annotations

import asyncio
import os
import shlex
from dataclasses import dataclass
from typing import Awaitable, Callable, Optional, Protocol


SSH_COMMON_ARGS = (
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=8",
)


class MmioError(RuntimeError):
    pass


class MmioInterface(Protocol):
    """The minimal interface the runner needs."""

    async def read(self, addr: int) -> int: ...
    async def write(self, addr: int, val: int) -> None: ...
    async def aclose(self) -> None: ...


# ── Real SSH-backed implementation ────────────────────────────────────────

_PY_TEMPLATE_RD = (
    "import mmap,struct,os;"
    "P=4096;fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC);"
    "a={addr};b=a&~(P-1);o=a-b;"
    "m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
    "mmap.PROT_READ|mmap.PROT_WRITE,offset=b);"
    "print(struct.unpack_from('<I',m,o)[0])"
)

_PY_TEMPLATE_WR = (
    "import mmap,struct,os;"
    "P=4096;fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC);"
    "a={addr};b=a&~(P-1);o=a-b;"
    "m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
    "mmap.PROT_READ|mmap.PROT_WRITE,offset=b);"
    "struct.pack_into('<I',m,o,{val})"
)


@dataclass
class RemoteMmioConfig:
    ip: str
    user: str = "xilinx"
    password_env: str = "TIDELINK_BOARD_PASS"
    password_default: str = "xilinx"
    sudo: bool = True
    ssh_path: str = "/usr/bin/sshpass"


class RemoteMmio:
    """SSH-backed remote /dev/mem accessor.

    Each ``read()`` / ``write()`` call spawns one SSH process —
    expensive but matches the existing bash scripts' behaviour and
    keeps the implementation trivial.

    For long bursts of accesses (e.g. AHB packet stress) callers
    should batch via ``read_many`` / ``write_many`` which exec a
    single Python script over a single SSH invocation.
    """

    def __init__(self, cfg: RemoteMmioConfig):
        self.cfg = cfg
        self._password = os.environ.get(
            cfg.password_env, cfg.password_default)

    def _ssh_argv(self, py_script: str) -> list[str]:
        if self.cfg.sudo:
            inner = f"echo {shlex.quote(self._password)} | sudo -S python3 -c {shlex.quote(py_script)}"
        else:
            inner = f"python3 -c {shlex.quote(py_script)}"
        return [
            self.cfg.ssh_path, "-p", self._password, "ssh",
            *SSH_COMMON_ARGS,
            f"{self.cfg.user}@{self.cfg.ip}", inner,
        ]

    async def _exec(self, py_script: str, *, timeout: float = 8.0) -> str:
        argv = self._ssh_argv(py_script)
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise MmioError(f"{self.cfg.ip}: ssh timeout after {timeout}s")
        if proc.returncode != 0:
            raise MmioError(
                f"{self.cfg.ip}: ssh exit {proc.returncode}: "
                f"{stderr.decode(errors='replace')[:200]}")
        return stdout.decode(errors="replace").strip()

    async def read(self, addr: int) -> int:
        out = await self._exec(_PY_TEMPLATE_RD.format(addr=addr))
        try:
            return int(out.splitlines()[-1])
        except (ValueError, IndexError) as exc:
            raise MmioError(
                f"{self.cfg.ip}: read 0x{addr:x}: parse {out!r}: {exc}") from exc

    async def write(self, addr: int, val: int) -> None:
        await self._exec(_PY_TEMPLATE_WR.format(addr=addr, val=int(val)))

    async def read_many(self, addrs: list[int]) -> list[int]:
        """Batch reads in one SSH invocation. Returns one int per addr."""
        if not addrs:
            return []
        lines = "; ".join(
            f"a={a}; b=a&~(P-1); o=a-b; "
            f"m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
            f"mmap.PROT_READ|mmap.PROT_WRITE,offset=b); "
            f"print(struct.unpack_from('<I',m,o)[0])"
            for a in addrs
        )
        script = (
            "import mmap,struct,os;"
            "P=4096;fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC);"
            + lines
        )
        out = await self._exec(script)
        try:
            return [int(s) for s in out.split()]
        except ValueError as exc:
            raise MmioError(
                f"{self.cfg.ip}: read_many parse {out!r}: {exc}") from exc

    async def write_many(self, pairs: list[tuple[int, int]]) -> None:
        if not pairs:
            return
        lines = "; ".join(
            f"a={a}; b=a&~(P-1); o=a-b; "
            f"m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
            f"mmap.PROT_READ|mmap.PROT_WRITE,offset=b); "
            f"struct.pack_into('<I',m,o,{int(v)})"
            for a, v in pairs
        )
        script = (
            "import mmap,struct,os;"
            "P=4096;fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC);"
            + lines
        )
        await self._exec(script)

    async def aclose(self) -> None:
        return None


# ── Test double ───────────────────────────────────────────────────────────

class FakeMmio:
    """In-memory MMIO substitute for pytest.

    Backing dict is keyed by absolute address. ``write()`` and
    ``read()`` accept arbitrary ints; reads default to 0 if the address
    has never been written. Optional ``read_hook`` and ``write_hook``
    callables let tests model side-effects (e.g. RELEASED_ACC clears on
    read).
    """

    def __init__(self,
                 *,
                 read_hook: Optional[Callable[[int, dict], int]] = None,
                 write_hook: Optional[Callable[[int, int, dict], None]] = None):
        self.store: dict[int, int] = {}
        self.reads: list[int] = []
        self.writes: list[tuple[int, int]] = []
        self.read_hook = read_hook
        self.write_hook = write_hook

    async def read(self, addr: int) -> int:
        self.reads.append(addr)
        if self.read_hook is not None:
            return int(self.read_hook(addr, self.store)) & 0xFFFFFFFF
        return self.store.get(addr, 0) & 0xFFFFFFFF

    async def write(self, addr: int, val: int) -> None:
        self.writes.append((addr, val))
        if self.write_hook is not None:
            self.write_hook(addr, val, self.store)
            return
        self.store[addr] = val & 0xFFFFFFFF

    async def read_many(self, addrs: list[int]) -> list[int]:
        return [await self.read(a) for a in addrs]

    async def write_many(self, pairs: list[tuple[int, int]]) -> None:
        for a, v in pairs:
            await self.write(a, v)

    async def aclose(self) -> None:
        return None
