"""Live, read-only link monitor over BOTH dies of the PYNQ-Z2 pair.

One long-lived board agent per die (``tl_perf_agent.py --cmd monitor``),
streaming NDJSON polls of the ``regmap.MONITOR_WHITELIST`` registers;
the server decodes every poll with ``regmap`` and fans the result out to
any number of browsers over SSE.

    POST /api/monitor/start   201 -> starts both dies
    POST /api/monitor/stop    200 -> idempotent no-op when already stopped
    GET  /api/monitor/state   polling fallback (same data as SSE)
    GET  /api/monitor/events  SSE: mon | perf | status | ping


WHY THE MONITOR DOES **NOT** TAKE THE EXPERIMENT MUTEX
------------------------------------------------------
``gates.ExperimentMutex`` is a cross-toolkit ``flock`` meaning "one
EXPERIMENT at a time" — it exists so the eye (:8088) / stress (:8089)
GUIs and the CLI scripts cannot drive the hardware simultaneously. The
monitor is not an experiment:

  * it only READS, and only registers on ``regmap.MONITOR_WHITELIST``,
    every one of which is RO with no read side effect (the read-clear
    and PS-hanging offsets live in ``regmap.FORBIDDEN_OFFSETS`` and are
    rejected here as well as in the agent);
  * it writes nothing — no AHB_TX, no CTRL, no RELEASE_THRESHOLD;
  * it is meant to stay up ACROSS runs. That is the entire point: you
    watch credit, sticky faults and FCSM while a soak is running.

If the monitor took the mutex, the mutex would be permanently held and
``POST /api/runs`` could never be admitted again (409 forever) — the
monitor would make the toolkit useless. So: the monitor keeps polling
while a run holds the mutex, and never touches the mutex itself.

The **lease** is different and IS taken: an fpgahub lease means "this
board is mine", and a poll loop over SSH genuinely occupies the board.
Against real boards the lease must be GRANTED (a QUEUED lease is a 412 —
never poll over someone else's session). In ``--fake`` (``cfg.fake``)
there is no board, so the monitor runs leaseless.

PER-DIE INDEPENDENCE
--------------------
The two dies are two separate boards with two separate PS's. A die whose
agent dies is marked ``"stale"`` and auto-restarted at most
``MAX_RESTARTS`` times; after that it is marked ``"failed"`` — and the
OTHER die keeps streaming throughout. The session as a whole only goes
``failed`` when EVERY die has failed.

CLOCKS
------
The boards are NOT NTP-synced (measured ~34 h apart). Every ``t`` in
this module is the *emitting die's own* ``time.monotonic()`` and is only
ever differenced against an earlier ``t`` FROM THE SAME DIE. Dies are
aligned to each other by server receipt order (``rx_seq``) only — see
``_derive()`` and ``snapshot()``.

DECODING
--------
No bit-slicing here. Every field comes from ``regmap.decode_monitor``,
``regmap.health``, ``regmap.decode_perf`` and ``regmap.perf_window`` /
``regmap.perf_window_cleared``. The only numbers this module computes
are per-die *rates* over that die's own consecutive polls, the
sticky-fault latch, and the CRC two-agreeing-samples filter.

Two decoding hazards are handled here because only the server can:

  * **perf windows** — the agent CLEARS the counters at the start of
    every window, so each record is already a delta. Differencing two of
    them would read a healthy block as dead (see ``_on_perf``).
  * **CRC counter** — unsynchronised across clock domains, so a single
    sample can be torn (see ``_confirm_crc``). And a flat 0 is NOT proof
    of a clean link: the register also reads 0 with the FC node disabled
    or in reset.
"""
from __future__ import annotations

import asyncio
import json
import time
from typing import Callable, Dict, List, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from . import lease as lease_mod
from . import regmap
from .agent_channel import AgentError, _BaseChannel

# ── tunables ─────────────────────────────────────────────────────────────
DEFAULT_PERIOD_MS = 200
PERIOD_MS_MIN = 20
PERIOD_MS_MAX = 60_000
#: Finite backstop handed to the agent so a crashed/killed server can
#: never leave a poll loop running on a board forever. A clean expiry is
#: NOT a failure — the die loop simply relaunches (and that relaunch does
#: not consume the restart budget). The agent's open-ended mode
#: (duration<=0, stopped by closing stdin) is deliberately NOT used: over
#: SshAgentChannel the agent's stdin is the ``echo <pass> | sudo -S``
#: pipe, so "close stdin to stop" is not a channel we own.
DEFAULT_BACKSTOP_S = 900.0
#: Floor on the backstop: a clean expiry relaunches the agent, so a tiny
#: duration would turn the poll loop into a fork bomb.
MIN_BACKSTOP_S = 5.0
MAX_BACKSTOP_S = 86_400.0
MAX_RESTARTS = 3
RESTART_BACKOFF_S = 0.25
SUBSCRIBER_QUEUE_MAX = 256
KEEPALIVE_S = 15.0
#: How long to wait for a launched agent to prove it is streaming.
START_TIMEOUT_S = 20.0

# key -> PAIR_BASE-relative offset, straight off the frozen whitelists.
_MON_KEY_OFF: Dict[str, int] = {k: off for off, k in regmap.MONITOR_WHITELIST}
_PERF_KEY_OFF: Dict[str, int] = {k: off for off, k in regmap.PERF_WHITELIST}
CRC_KEY = "crc"          # absolute WLINK_CRC_ERR_ADDR, not a PAIR offset


class MonitorUnsupported(RuntimeError):
    """The board agent has no monitor role (old agent staged)."""


# ── agent stream driver ──────────────────────────────────────────────────

class _AgentMonitorStream:
    """Drive one channel's long-lived ``--cmd monitor`` NDJSON stream.

    ``_BaseChannel`` offers ``oneshot()`` (runs to completion, buffers all
    stdout — useless for a stream) and ``start_run()`` (hardwired to
    ``--cfg-json`` + the GO barrier). Neither expresses "launch a
    long-lived ``--cmd`` and iterate its lines", so this class composes
    the pieces the channel already exposes — ``_argv()``, ``_env()``,
    ``_readline()``, ``events()``, ``close()`` — rather than editing
    ``agent_channel.py`` (owned by the integrator). The launched process
    is parked on ``channel._proc`` exactly where ``start_run()`` parks
    its own, so ``channel.close()`` still reaps it.

    Two protocol shapes are tried, preferring the contract's one:
      1. ``--cmd monitor --args <period_ms> <duration_s> [crc] [perf]``
      2. ``--cfg-json {"role":"monitor",...}`` + GO barrier  (fallback,
         in case the agent lands the monitor as a run role instead)
    An agent supporting neither raises MonitorUnsupported.
    """

    def __init__(self, channel: _BaseChannel, *, period_ms: int,
                 duration_s: float, perf: bool = False, crc: bool = False,
                 start_timeout_s: float = START_TIMEOUT_S):
        self.ch = channel
        self.period_ms = int(period_ms)
        self.duration_s = float(duration_s)
        self.perf = bool(perf)
        self.crc = bool(crc)
        self.start_timeout_s = float(start_timeout_s)
        self.mode: Optional[str] = None      # "cmd" | "cfg"
        self.saw_done = False
        #: True when the agent refused --crc/--perf and we fell back to a
        #: plain stream. NEVER silent: the die reports it, because "the
        #: gauge is blank" and "the gauge was never enabled" look
        #: identical on screen and only one of them is a hardware finding.
        self.degraded: Optional[str] = None
        self._pending: List[dict] = []

    # — argv shapes —

    def _flags(self) -> List[str]:
        # tl_perf_agent.py takes these as argparse switches, NOT as
        # trailing --args tokens (--args is nargs="*" and would swallow
        # them silently, leaving crc/perf quietly disabled).
        flags = []
        if self.crc:
            flags.append("--crc")
        if self.perf:
            flags.append("--perf")
        return flags

    def _cmd_args(self, with_flags: bool) -> List[str]:
        # Flags go BEFORE --args so the nargs="*" list cannot absorb them.
        args = ["--cmd", "monitor"]
        if with_flags:
            args += self._flags()
        return args + ["--args", str(self.period_ms), str(self.duration_s)]

    def _cfg(self) -> dict:
        return {"role": "monitor", "period_ms": self.period_ms,
                "duration_s": self.duration_s,
                "perf": self.perf, "crc": self.crc}

    # — launch —

    async def start(self) -> None:
        """Launch the stream, leaving the first event buffered."""
        attempts: List[List[str]] = [self._cmd_args(True)]
        if self._flags():
            # An agent that predates the flag tokens must still give us a
            # plain monitor stream rather than nothing.
            attempts.append(self._cmd_args(False))
        last: Optional[Exception] = None
        for n, args in enumerate(attempts):
            try:
                await self._start_cmd(args)
                self.mode = "cmd"
                if n:
                    self.degraded = (
                        "agent rejected %s — streaming WITHOUT them (%s)"
                        % (" ".join(self._flags()), last))
                return
            except MonitorUnsupported as exc:
                last = exc
                await self._kill()
        try:
            await self._start_cfg()
            self.mode = "cfg"
            return
        except MonitorUnsupported as exc:
            last = exc
        await self._kill()
        raise last if last is not None else MonitorUnsupported(
            "%s: agent has no monitor role" % self.ch.board)

    async def _start_cmd(self, args: List[str]) -> None:
        argv = self.ch._argv(args)
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=self.ch._env())
        # Park it where start_run() parks its process so the channel's own
        # close() reaps it (and _readline()/events() just work).
        self.ch._proc = proc
        try:
            ev = await asyncio.wait_for(self.ch._readline(),
                                        timeout=self.start_timeout_s)
        except asyncio.TimeoutError:
            raise MonitorUnsupported(
                "%s: agent produced no monitor output in %.0fs"
                % (self.ch.board, self.start_timeout_s))
        except AgentError as exc:
            raise MonitorUnsupported("%s: %s" % (self.ch.board, exc))
        if "error" in ev or ev.get("ev") in ("aborted", "error"):
            raise MonitorUnsupported(
                "%s: agent rejected --cmd monitor (%r)" % (self.ch.board, ev))
        self._pending.append(ev)

    async def _start_cfg(self) -> None:
        # Pure public surface: start_run() + send_go().
        try:
            await self.ch.start_run(self._cfg(),
                                    ready_timeout=self.start_timeout_s)
            await self.ch.send_go(time.time() + self.duration_s + 60.0)
        except AgentError as exc:
            raise MonitorUnsupported(
                "%s: no monitor run role either (%s)" % (self.ch.board, exc))

    async def _kill(self) -> None:
        try:
            await self.ch.close()
        except Exception:
            pass

    # — consume —

    async def events(self):
        """Yield agent events until the stream ends (done / EOF)."""
        while self._pending:
            ev = self._pending.pop(0)
            if ev.get("ev") == "done":
                self.saw_done = True
            yield ev
            if self.saw_done:
                return
        async for ev in self.ch.events():
            if ev.get("ev") == "done":
                self.saw_done = True
            yield ev
            if self.saw_done:
                return


# ── per-die bookkeeping ──────────────────────────────────────────────────

class _Die:
    """Everything the server knows about ONE die.

    ``t``/``prev_t`` are that die's own ``time.monotonic()``; they are
    NEVER compared with the other die's (different board, unsynced
    clock ~34 h off). ``rx_seq`` is the server-side receipt order, which
    is the only legitimate way to align the two dies.
    """

    __slots__ = ("name", "state", "reason", "seq", "t", "raw", "dec",
                 "derived", "health", "sticky", "errors", "restarts",
                 "rx_seq", "rx_t", "perf", "perf_window", "perf_window_mode",
                 "_prev_t", "_prev_dec", "polls", "crc_agreed",
                 "_crc_pending")

    def __init__(self, name: str):
        self.name = name
        self.state = "starting"     # starting|streaming|stale|failed|stopped
        self.reason: Optional[str] = None
        self.seq: Optional[int] = None
        self.t: Optional[float] = None
        self.raw: dict = {}
        self.dec: dict = {}
        self.derived: dict = {}
        self.health: dict = {}
        self.sticky = {"overrun_seen": False, "underrun_seen": False,
                       "master_error_seen": False}
        self.errors = 0
        self.restarts = 0
        self.polls = 0
        self.rx_seq: Optional[int] = None
        self.rx_t: Optional[float] = None
        self.perf: dict = {}
        self.perf_window: dict = {}
        self.perf_window_mode: Optional[str] = None
        #: Last CRC value confirmed by two consecutive agreeing polls, and
        #: the unconfirmed candidate waiting for its second witness.
        self.crc_agreed: Optional[int] = None
        self._crc_pending: Optional[int] = None
        self._prev_t: Optional[float] = None
        self._prev_dec: Optional[dict] = None

    def to_dict(self) -> dict:
        return {
            "die": self.name, "state": self.state, "reason": self.reason,
            "seq": self.seq, "t": self.t, "rx_seq": self.rx_seq,
            "rx_t": self.rx_t, "raw": self.raw, "dec": self.dec,
            "derived": self.derived, "health": self.health,
            "sticky": dict(self.sticky), "errors": self.errors,
            "restarts": self.restarts, "polls": self.polls,
            "perf": self.perf, "perf_window": self.perf_window,
            "perf_window_mode": self.perf_window_mode,
        }


# ── session ──────────────────────────────────────────────────────────────

class MonitorSession:
    """One live monitor over N dies (normally master + slave)."""

    def __init__(self, channels: dict, *, period_ms: int = DEFAULT_PERIOD_MS,
                 perf: bool = False, crc: bool = False,
                 duration_s: float = DEFAULT_BACKSTOP_S,
                 max_restarts: int = MAX_RESTARTS,
                 restart_backoff_s: float = RESTART_BACKOFF_S,
                 start_timeout_s: float = START_TIMEOUT_S,
                 on_stopped: Optional[Callable] = None):
        self.channels = dict(channels)
        self.period_ms = int(period_ms)
        self.perf = bool(perf)
        self.crc = bool(crc)
        # Always finite (never the agent's open-ended duration<=0 mode) and
        # never so short that a clean expiry becomes a relaunch storm.
        self.duration_s = min(MAX_BACKSTOP_S,
                              max(MIN_BACKSTOP_S, float(duration_s)))
        self.max_restarts = int(max_restarts)
        self.restart_backoff_s = float(restart_backoff_s)
        self.start_timeout_s = float(start_timeout_s)
        self.on_stopped = on_stopped

        self.state = "idle"
        self.started_at: Optional[float] = None
        self.dies: Dict[str, _Die] = {n: _Die(n) for n in self.channels}
        self._subs: List[asyncio.Queue] = []
        self._tasks: Dict[str, asyncio.Task] = {}
        self._stopping = False
        self._rx_seq = 0
        self._dropped = 0

    # — the offsets this session can ever cause to be read —

    @property
    def requested_offsets(self) -> frozenset:
        """PAIR_BASE-relative offsets this session's protocol covers.

        The monitor never names an address on the wire — the agent is
        whitelist-driven — so this is the closed set of offsets a poll
        can contain, and it is what the tests assert on."""
        offs = set(regmap.MONITOR_OFFSETS)
        if self.perf:
            offs |= set(regmap.PERF_OFFSETS)
        return frozenset(offs)

    # — lifecycle —

    async def start(self) -> None:
        if self.state in ("starting", "running"):
            raise RuntimeError("monitor session already running")
        self._stopping = False
        self.state = "starting"
        self.started_at = time.time()
        # Sanity, not decoration: a whitelist that ever intersected the
        # forbidden set would hang the PS or corrupt the credit protocol.
        bad = self.requested_offsets & regmap.FORBIDDEN_OFFSETS
        if bad:
            self.state = "failed"
            raise RuntimeError("refusing to poll forbidden offsets: %s"
                               % sorted(hex(o) for o in bad))
        for name, ch in self.channels.items():
            self._tasks[name] = asyncio.create_task(
                self._die_loop(name, ch), name="tlmon-%s" % name)
        self.state = "running"
        self._publish("status", {"state": self.state,
                                 "dies": list(self.dies)})

    async def stop(self) -> None:
        if self.state in ("idle", "stopped"):
            self.state = "stopped"
            return
        self._stopping = True
        self.state = "stopping"
        for task in self._tasks.values():
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks.values(),
                                 return_exceptions=True)
        self._tasks.clear()
        # Channels are closed AFTER the readers are gone, never while a
        # reader is parked in _readline() on the pipe.
        for ch in self.channels.values():
            try:
                await ch.close()
            except Exception:
                pass
        for die in self.dies.values():
            if die.state not in ("failed",):
                die.state = "stopped"
        self.state = "stopped"
        self._publish("status", {"state": self.state})
        if self.on_stopped is not None:
            try:
                res = self.on_stopped()
                if asyncio.iscoroutine(res):
                    await res
            except Exception:
                pass

    # — fan-out —

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=SUBSCRIBER_QUEUE_MAX)
        self._subs.append(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        try:
            self._subs.remove(q)
        except ValueError:
            pass

    def _publish(self, kind: str, payload: dict) -> None:
        """Drop-OLDEST fan-out: a browser that stops reading must never
        stall the poll loop or grow the server without bound."""
        item = (kind, payload)
        for q in list(self._subs):
            try:
                q.put_nowait(item)
            except asyncio.QueueFull:
                try:
                    q.get_nowait()
                    self._dropped += 1
                except asyncio.QueueEmpty:      # pragma: no cover
                    pass
                try:
                    q.put_nowait(item)
                except asyncio.QueueFull:       # pragma: no cover
                    pass

    # — snapshot —

    def snapshot(self) -> dict:
        return {
            "state": self.state,
            "dies": {n: d.to_dict() for n, d in self.dies.items()},
            "pair": self._pair(),
            "started_at": self.started_at,
            "errors": sum(d.errors for d in self.dies.values()),
            "period_ms": self.period_ms,
            "perf": self.perf,
            "crc": self.crc,
            "subscribers": len(self._subs),
            "dropped_events": self._dropped,
        }

    def _pair(self) -> dict:
        """Cross-die view.

        The two dies' polls are NOT simultaneous and their timestamps are
        not comparable — this pairs the latest snapshot of each die by
        receipt order and says so."""
        m = self.dies.get("master")
        s = self.dies.get("slave")
        out: dict = {
            "aligned_by": "receipt order (boards are not clock-synced)",
            "criterion": None, "link_up": False, "reason": None,
            "stale": [n for n, d in self.dies.items()
                      if d.state in ("stale", "failed")],
        }
        if m is None or s is None:
            return out
        out["master_state"] = m.state
        out["slave_state"] = s.state
        if not m.dec or not s.dec:
            out["reason"] = "waiting for first poll from both dies"
            return out
        if "fcsm" not in m.dec or "fcsm" not in s.dec:
            out["reason"] = "no SWI_LANE_STATUS in the latest polls"
            return out
        verdict = regmap.verify_link_up(m.dec, s.dec)
        out["criterion"] = verdict.criterion
        out["link_up"] = bool(verdict.ok)
        out["reason"] = verdict.reason
        out["snapshot"] = verdict.snapshot
        return out

    # — die loop —

    async def _die_loop(self, name: str, ch: _BaseChannel) -> None:
        die = self.dies[name]
        while not self._stopping:
            stream = _AgentMonitorStream(
                ch, period_ms=self.period_ms, duration_s=self.duration_s,
                perf=self.perf, crc=self.crc,
                start_timeout_s=self.start_timeout_s)
            clean = False
            try:
                await stream.start()
                note = stream.degraded
                if stream.mode == "cfg":
                    note = "; ".join(filter(None, [
                        note, "agent has no --cmd monitor; using the "
                              "cfg-json monitor role"]))
                self._set_die_state(name, "streaming", note)
                async for ev in stream.events():
                    self._on_event(name, ev)
                clean = stream.saw_done
                reason = ("agent monitor window ended cleanly"
                          if clean else "agent stream ended unexpectedly")
            except asyncio.CancelledError:
                raise
            except MonitorUnsupported as exc:
                reason = str(exc)
            except Exception as exc:                       # noqa: BLE001
                reason = "%s: %r" % (name, exc)
            finally:
                try:
                    await ch.close()
                except Exception:
                    pass

            if self._stopping:
                return
            # A clean end-of-backstop is a renewal, not a failure: it must
            # not consume the restart budget.
            if clean:
                # Anchor for rates is per-die and per-process; a relaunch
                # gap would fabricate a rate, so drop the anchor.
                die._prev_t = None
                die._prev_dec = None
                continue
            die.errors += 1
            if die.restarts >= self.max_restarts:
                self._set_die_state(
                    name, "failed",
                    "%s (gave up after %d restarts)"
                    % (reason, die.restarts))
                self._maybe_fail_session()
                return
            die.restarts += 1
            die._prev_t = None
            die._prev_dec = None
            self._set_die_state(
                name, "stale",
                "%s — restart %d/%d" % (reason, die.restarts,
                                        self.max_restarts))
            try:
                await asyncio.sleep(self.restart_backoff_s)
            except asyncio.CancelledError:
                raise

    def _maybe_fail_session(self) -> None:
        # ONE dead board must never take the other down: the session only
        # fails when every die has failed.
        if self.dies and all(d.state == "failed" for d in self.dies.values()):
            self.state = "failed"
            self._publish("status", {"state": self.state})

    def _set_die_state(self, name: str, state: str,
                       reason: Optional[str]) -> None:
        die = self.dies[name]
        die.state = state
        die.reason = reason
        self._publish("status", {"state": self.state, "die": name,
                                 "die_state": state, "reason": reason})

    # — event handling —

    def _on_event(self, name: str, ev: dict) -> None:
        kind = ev.get("ev")
        if kind == "mon":
            self._on_mon(name, ev)
        elif kind == "perf":
            self._on_perf(name, ev)
        elif kind == "mon_err":
            self._die_error(name, "agent read error: %s" % ev.get("reason"))
        elif kind == "done":
            pass
        else:
            # Unknown event kinds are logged, never decoded blindly.
            self._publish("status", {
                "state": self.state, "die": name,
                "die_state": self.dies[name].state,
                "reason": "unhandled agent event %r" % kind})

    def _filter(self, name: str, raw: dict, allowed: Dict[str, int],
                allow_crc: bool) -> dict:
        """Keep only keys that map to a whitelisted offset.

        Belt-and-braces with the agent's own assertion: if a poll ever
        carried a non-whitelisted (or forbidden) key, the value came from
        a read this GUI must never have caused, so it is dropped and
        counted as an error rather than rendered."""
        clean: dict = {}
        for key, val in (raw or {}).items():
            off = allowed.get(key)
            if not (key == CRC_KEY and allow_crc) and (
                    off is None or off in regmap.FORBIDDEN_OFFSETS):
                self._die_error(
                    name, "agent reported NON-WHITELISTED register %r "
                          "— dropped" % key)
                continue
            try:
                # Protocol says plain ints; tolerate "0x..." rather than
                # letting one malformed field kill the whole stream.
                clean[key] = int(val, 0) if isinstance(val, str) else int(val)
            except (TypeError, ValueError):
                self._die_error(
                    name, "agent sent a non-numeric value for %r (%r)"
                          % (key, val))
        return clean

    def _die_error(self, name: str, reason: str) -> None:
        die = self.dies[name]
        die.errors += 1
        self._publish("status", {"state": self.state, "die": name,
                                 "die_state": die.state, "reason": reason})

    def _on_mon(self, name: str, ev: dict) -> None:
        die = self.dies[name]
        raw_ints = self._filter(name, ev.get("r") or {}, _MON_KEY_OFF,
                                allow_crc=True)
        dec = regmap.decode_monitor(raw_ints)
        self._confirm_crc(die, dec)
        t = ev.get("t")
        t = float(t) if isinstance(t, (int, float)) else None
        derived = self._derive(die, t, dec)

        self._rx_seq += 1
        die.polls += 1
        die.seq = ev.get("seq")
        die.t = t
        die.rx_seq = self._rx_seq
        die.rx_t = time.monotonic()
        die.raw = {k: "0x%08x" % (v & 0xFFFFFFFF)
                   for k, v in raw_ints.items()}
        die.dec = dec
        die.derived = derived
        die.health = regmap.health(dec)
        if die.state != "streaming":
            die.state = "streaming"
            die.reason = None

        self._publish("mon", {
            "die": name, "seq": die.seq, "t": die.t,
            "rx_seq": die.rx_seq, "raw": die.raw, "dec": dec,
            "derived": derived, "health": die.health,
            "sticky": dict(die.sticky),
        })

    @staticmethod
    def _confirm_crc(die: _Die, dec: dict) -> None:
        """Two-agreeing-samples rule for the Wlink CRC error counter.

        0x4403_1720 is muxed from the io_rx_clk domain onto the APB clock
        with NO synchroniser, so ANY single sample can be TORN — a
        spurious huge value is possible at any time. The published value
        therefore only moves when two consecutive polls agree on it;
        until then the last agreed value is held and the unconfirmed
        sample is exposed separately as ``crc_errors_raw``.

        The rule is symmetric (a fall needs a witness too): on an
        accumulating counter a drop is just as much evidence of tearing
        as a jump.

        ⚠ A flat 0 is NOT a clean bill of health. The register also reads
        0 when the FC node is disabled or held in reset, which is
        indistinguishable here from "no CRC errors"; only a link that is
        provably carrying traffic makes 0 meaningful.
        """
        raw = dec.get("crc_errors")
        if raw is None:
            return                       # CRC not sampled this poll
        if raw == die._crc_pending:
            die.crc_agreed = raw         # second witness — believe it
        die._crc_pending = raw
        dec["crc_errors_raw"] = raw
        dec["crc_errors"] = die.crc_agreed
        dec["crc_unconfirmed"] = 0 if raw == die.crc_agreed else 1

    def _derive(self, die: _Die, t: Optional[float], dec: dict) -> dict:
        """Per-die derived values.

        RATES ARE PER-DIE ONLY. ``t`` is this board's ``time.monotonic()``
        and dt is taken against this same board's previous poll — the
        peer's clock is ~34 h away and differencing across boards would
        produce garbage. Dies are aligned only by ``rx_seq``.
        """
        prev_t, prev = die._prev_t, die._prev_dec
        out: dict = {
            "credit_frac": dec.get("credit_frac"),
            "occupancy": dec.get("occupancy"),
            "pair_credit_rate": None,
            "sync_rate": None,
        }
        if prev is not None and prev_t is not None and t is not None:
            dt = t - prev_t
            if dt > 0:
                out["dt"] = round(dt, 6)
                cur_pc, prev_pc = dec.get("pair_credits"), prev.get(
                    "pair_credits")
                if cur_pc is not None and prev_pc is not None:
                    # Signed on purpose: credits are consumed as well as
                    # released, and a falling pair counter is the thing an
                    # operator most needs to see.
                    out["pair_credit_rate"] = round(
                        (cur_pc - prev_pc) / dt, 3)
                cur_sy, prev_sy = dec.get("sync_detected"), prev.get(
                    "sync_detected")
                if cur_sy is not None and prev_sy is not None:
                    d_sync = cur_sy - prev_sy
                    # SYNC_DET is a saturating up-counter; a negative delta
                    # means it wrapped/reset, which is "unknown", not 0.
                    out["sync_rate"] = (round(d_sync / dt, 3)
                                        if d_sync >= 0 else None)

        # Sticky-fault latch. These bits are STICKY IN HARDWARE (cleared
        # only by CTRL.FLUSH, which the monitor must never issue), so once
        # a poll has shown one the UI must keep showing it for the whole
        # session even though a later poll may read clean.
        for latch, bit in (("overrun_seen", "overrun"),
                           ("underrun_seen", "underrun"),
                           ("master_error_seen", "master_error")):
            if dec.get(bit):
                die.sticky[latch] = True
        out.update(die.sticky)

        if t is not None:
            die._prev_t = t
            die._prev_dec = dec
        return out

    def _on_perf(self, name: str, ev: dict) -> None:
        """Score one perf record.

        WHICH function scores it is not cosmetic. The agent's sampling
        protocol CLEARS the counters at the start of every window
        (PERF_CTRL=0x5) and freezes at the end (0x3), so each record is
        ALREADY a delta over win_s. Differencing two such records gives
        ~0, ``perf_window`` sees d_sample<=0 and returns {}, and a
        perfectly healthy block renders as "no perf data" — an instrument
        bug wearing a DUT finding's clothes. Records tagged
        ``window_mode="cleared"`` are therefore scored against a zero
        baseline; only genuinely free-running cumulative counters are
        differenced against the previous record.
        """
        die = self.dies[name]
        raw_ints = self._filter(name, ev.get("r") or {}, _PERF_KEY_OFF,
                                allow_crc=False)
        cur = regmap.decode_perf(raw_ints)
        mode = ev.get("window_mode")
        if mode == "cleared":
            window = regmap.perf_window_cleared(cur)
        else:                        # free-running cumulative counters
            mode = mode or "cumulative"
            window = regmap.perf_window(die.perf, cur)
        die.perf = cur
        die.perf_window = window
        die.perf_window_mode = mode
        self._publish("perf", {"die": name, "t": ev.get("t"),
                               "win_s": ev.get("win_s"),
                               "window_mode": mode,
                               "dec": cur, "window": window})


# ── HTTP surface ─────────────────────────────────────────────────────────

class MonitorStartRequest(BaseModel):
    period_ms: int = DEFAULT_PERIOD_MS
    perf: bool = False
    crc: bool = False
    master_ip: Optional[str] = None
    slave_ip: Optional[str] = None
    board: Optional[str] = None
    ttl_seconds: int = 1800
    duration_s: float = DEFAULT_BACKSTOP_S


def _idle_snapshot() -> dict:
    return {"state": "idle", "dies": {}, "pair": {}, "started_at": None,
            "errors": 0}


def get_session(state) -> Optional[MonitorSession]:
    return getattr(state, "monitor_session", None)


async def shutdown(state=None) -> None:
    """Stop the live session and close both channels.

    Wire into app.py's shutdown hook:
        await monitor.shutdown(app.state.tlthroughput)
    (``router.shutdown()`` is the zero-arg equivalent.)"""
    if state is None:
        return
    sess = get_session(state)
    if sess is None:
        return
    try:
        await sess.stop()
    finally:
        state.monitor_session = None


def build_router(get_state: Callable) -> APIRouter:
    """Router for the live link monitor.

    ``get_state`` is a zero-arg callable returning the app's AppState, so
    the router reaches ``cfg`` / ``channel_factory`` / ``lease_client``
    without importing app.py (which would be circular)."""
    router = APIRouter()

    @router.post("/api/monitor/start", status_code=201)
    async def monitor_start(req: MonitorStartRequest):
        state = get_state()
        cfg = state.cfg
        sess = get_session(state)
        if sess is not None and sess.state in ("starting", "running",
                                               "stopping"):
            raise HTTPException(409, "a monitor session is already running")
        if not (PERIOD_MS_MIN <= req.period_ms <= PERIOD_MS_MAX):
            raise HTTPException(
                400, "period_ms must be %d..%d" % (PERIOD_MS_MIN,
                                                   PERIOD_MS_MAX))
        if not (MIN_BACKSTOP_S <= req.duration_s <= MAX_BACKSTOP_S):
            raise HTTPException(
                400, "duration_s (agent backstop) must be %.0f..%.0f"
                     % (MIN_BACKSTOP_S, MAX_BACKSTOP_S))

        master_ip = req.master_ip or cfg.master_ip
        slave_ip = req.slave_ip or cfg.slave_ip
        board = req.board or cfg.board
        fake = bool(getattr(cfg, "fake", False))

        # LEASE (real boards only). A poll loop over SSH is board
        # occupancy; a QUEUED lease means someone else owns the board.
        # NOTE: deliberately NO ExperimentMutex — see the module docstring.
        token = None
        if not fake:
            client = state.lease_client
            if client is None:
                raise HTTPException(
                    412, "no lease client — refusing to poll a real board "
                         "without a lease")
            # ``board`` may name SEVERAL scopes ("pynq_z2_02_ps,
            # pynq_z2_01_ps") — the pair is two independent board-group
            # leases now that "bridge1" is gone. All-or-nothing.
            try:
                token = await lease_mod.acquire_all(
                    client, board, ttl=req.ttl_seconds)
            except lease_mod.QueuedError as exc:
                raise HTTPException(412, str(exc))

        try:
            master_ch, slave_ch, cleanup = state.channel_factory(
                master_ip, slave_ip)
        except BaseException:
            await lease_mod.release_all(state.lease_client, token)
            raise

        async def _release():
            cleanup()
            await lease_mod.release_all(state.lease_client, token)

        try:
            await master_ch.stage()
            await slave_ch.stage()
        except Exception as exc:                       # noqa: BLE001
            for ch in (master_ch, slave_ch):
                try:
                    await ch.close()
                except Exception:
                    pass
            await _release()
            raise HTTPException(412, "cannot stage the board agent: %s" % exc)

        sess = MonitorSession(
            {"master": master_ch, "slave": slave_ch},
            period_ms=req.period_ms, perf=req.perf, crc=req.crc,
            duration_s=req.duration_s, on_stopped=_release)
        state.monitor_session = sess
        try:
            await sess.start()
        except Exception as exc:                       # noqa: BLE001
            state.monitor_session = None
            for ch in (master_ch, slave_ch):
                try:
                    await ch.close()
                except Exception:
                    pass
            await _release()
            raise HTTPException(500, "monitor failed to start: %s" % exc)
        return {"state": sess.state, "period_ms": sess.period_ms,
                "dies": list(sess.dies), "perf": sess.perf, "crc": sess.crc,
                "leased": bool(token), "board": board}

    @router.post("/api/monitor/stop")
    async def monitor_stop():
        state = get_state()
        sess = get_session(state)
        if sess is None:
            return {"state": "stopped"}          # idempotent no-op
        await sess.stop()
        state.monitor_session = None
        return {"state": "stopped"}

    @router.get("/api/monitor/state")
    async def monitor_state():
        sess = get_session(get_state())
        return _idle_snapshot() if sess is None else sess.snapshot()

    @router.get("/api/monitor/events")
    async def monitor_events(request: Request):
        sess = get_session(get_state())
        if sess is None:
            raise HTTPException(404, "no monitor session — POST "
                                     "/api/monitor/start first")
        q = sess.subscribe()

        async def _gen():
            try:
                # Prime the new subscriber so a browser joining mid-session
                # renders immediately instead of after the first poll.
                yield {"event": "status",
                       "data": json.dumps(sess.snapshot())}
                while True:
                    if await request.is_disconnected():
                        return
                    try:
                        kind, payload = await asyncio.wait_for(
                            q.get(), timeout=KEEPALIVE_S)
                    except asyncio.TimeoutError:
                        yield {"event": "ping", "data": "keepalive"}
                        continue
                    yield {"event": kind, "data": json.dumps(payload)}
            finally:
                sess.unsubscribe(q)

        return EventSourceResponse(_gen(), ping=KEEPALIVE_S)

    async def _shutdown():
        await shutdown(get_state())

    router.shutdown = _shutdown          # type: ignore[attr-defined]
    return router
