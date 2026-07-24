"""Link-monitor server (monitor.py) against a stub board agent.

Everything here is offline. Two backends are exercised:

  * ``StubMonitorChannel`` — a _BaseChannel whose ``_argv`` points at a
    tiny in-file NDJSON agent. It speaks the frozen ``--cmd monitor``
    protocol and can be told to die, to latch a sticky overrun, or to
    report a FORBIDDEN register — the failure modes the real agent
    cannot be asked to produce on demand. It also RECORDS every argv the
    session issues, which is how "the monitor never reads outside
    MONITOR_OFFSETS" is asserted.

  * the real ``LocalAgentChannel`` + ``tl_perf_agent.py --fake``, in one
    integration test that SKIPS while the agent has no monitor role
    (Agent A owns that file).
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import httpx
import pytest
from asgi_lifespan import LifespanManager

from pynq_host.throughput_gui import monitor, regmap
from pynq_host.throughput_gui.agent_channel import (
    AGENT_PATH,
    LocalAgentChannel,
    _BaseChannel,
)
from pynq_host.throughput_gui.app import create_app
from pynq_host.throughput_gui.lease import FakeLeaseClient

# ── a stub board agent: the frozen --cmd monitor NDJSON shape ────────────
#
# argv: <board> --cmd monitor [--crc] [--perf] --args <period_ms> <dur_s>
# env knobs: STUB_UNSUPPORTED / STUB_DIE_AFTER / STUB_OVERRUN_AT /
#            STUB_BAD_KEY
STUB_AGENT = r'''
import json, os, sys, time

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

argv = sys.argv[1:]
board, rest = argv[0], argv[1:]

if os.environ.get("STUB_UNSUPPORTED") == "1":
    emit({"error": "unknown cmd monitor"})
    sys.exit(1)
if "--cmd" not in rest or rest[rest.index("--cmd") + 1] != "monitor":
    emit({"error": "unknown cmd"})
    sys.exit(1)

args = rest[rest.index("--args") + 1:] if "--args" in rest else []
period_s = (float(args[0]) if args else 200.0) / 1000.0
duration_s = float(args[1]) if len(args) > 1 else 60.0
want_crc = "--crc" in rest          # argparse switches, as the real agent
want_perf = "--perf" in rest

die_after = int(os.environ.get("STUB_DIE_AFTER", "0"))
overrun_at = int(os.environ.get("STUB_OVERRUN_AT", "0"))
bad_key = os.environ.get("STUB_BAD_KEY") == "1"
# per-poll CRC values (last one repeats) — models a TORN sample
crc_seq = [int(v) for v in
           os.environ.get("STUB_CRC", "0").replace(" ", "").split(",")]
# "cleared" (agent clears each window) or "cumulative"
perf_mode = os.environ.get("STUB_PERF_MODE", "cleared")

seq = 0
end = time.monotonic() + duration_s
while time.monotonic() < end:
    seq += 1
    status = (1 << 1) if (overrun_at and seq == overrun_at) else 0
    r = {
        "008": 0,
        "00c": 4096 - (seq % 5) * 4,
        "010": status,
        "018": 3,
        "028": 1000 + seq * 3,
        "100": 0,
        "108": (1 << 16) | (4 << 17),          # cal_done=1, fcsm=4
        "114": (100 + seq) << 16,              # sync_detected
        "11c": 0x50410100,
        "140": 0,
        "194": (1 << 19) | (1 << 20),          # mask_hs_match + gate_open
        "198": (1 << 20) | 0x3,
        "19c": (0xFC << 24) | (0x07 << 8) | 0x1F,
    }
    if want_crc:
        r["crc"] = crc_seq[min(seq - 1, len(crc_seq) - 1)]
    if bad_key:
        r["020"] = 0xDEAD                      # FORBIDDEN read-clear reg
    emit({"ev": "mon", "seq": seq, "t": time.monotonic(), "r": r})
    if want_perf:
        # 100 SAMPLE, 50 LINK_BUSY, 2 TX_STALL per window => 50% / 2%.
        # "cleared": counters are zeroed each window, so every record is
        # ALREADY a delta. "cumulative": free-running, must be differenced.
        n = 1 if perf_mode == "cleared" else seq
        pev = {"ev": "perf", "t": time.monotonic(), "win_s": 0.05, "r": {
            "0ac": 1 << 3, "0c8": n, "0cc": n,
            "0d0": n * 16, "0d4": n * 16,
            "0d8": n * 2, "0dc": n,
            "0e0": n * 50, "0e4": n, "0e8": n * 100,
            "0ec": 0, "0f0": 0, "0f4": 0, "0f8": 0, "0fc": 0x50460100}}
        if perf_mode == "cleared":
            pev["window_mode"] = "cleared"
        emit(pev)
    if die_after and seq >= die_after:
        sys.exit(7)                            # death, with NO "done"
    time.sleep(period_s)

emit({"ev": "done",
      "summary": {"samples": seq, "elapsed_s": duration_s, "errors": 0}})
'''


class StubMonitorChannel(_BaseChannel):
    """_BaseChannel over the stub agent above (records every argv)."""

    def __init__(self, board: str, **knobs):
        super().__init__()
        self.board = board
        self.knobs = {k: str(v) for k, v in knobs.items()}
        self.argv_log: list = []

    def _argv(self, agent_args: list) -> list:
        self.argv_log.append(list(agent_args))
        return [sys.executable, "-c", STUB_AGENT, self.board] + agent_args

    def _env(self) -> dict:
        env = dict(os.environ)
        env.update(self.knobs)
        return env


def stub_factory(master_knobs=None, slave_knobs=None):
    """channel_factory returning a recording stub pair."""
    made = {}

    def factory(master_ip, slave_ip):
        m = StubMonitorChannel("master", **(master_knobs or {}))
        s = StubMonitorChannel("slave", **(slave_knobs or {}))
        made["master"], made["slave"] = m, s
        return m, s, (lambda: None)

    factory.made = made          # type: ignore[attr-defined]
    return factory


# ── harness ──────────────────────────────────────────────────────────────

def make_app(app_cfg, factory):
    app = create_app(app_cfg, lease_client=FakeLeaseClient(),
                     channel_factory=factory)
    app.include_router(
        monitor.build_router(lambda: app.state.tlthroughput))
    return app


async def _client(app):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                             base_url="http://test")


async def _wait(client, pred, timeout_s=6.0, step=0.05):
    """Poll /api/monitor/state until pred(snapshot)."""
    for _ in range(int(timeout_s / step)):
        snap = (await client.get("/api/monitor/state")).json()
        if pred(snap):
            return snap
        await asyncio.sleep(step)
    raise AssertionError("condition never held; last=%s"
                         % json.dumps(snap)[:800])


def _both_streaming(snap):
    dies = snap.get("dies", {})
    return (len(dies) == 2
            and all(d.get("dec", {}).get("fcsm") is not None
                    for d in dies.values()))


class SseClient:
    """Minimal SSE reader that drives the ASGI app directly.

    httpx's ASGITransport buffers the WHOLE response before returning it
    (httpx/_transports/asgi.py: ``await self.app(...)`` then
    ``assert response_complete.is_set()``), so it can only read a stream
    that ENDS. A live monitor stream never ends, so these tests speak
    ASGI directly — which also exercises the real disconnect path."""

    def __init__(self, app, path="/api/monitor/events"):
        self.app = app
        self.path = path
        self.status = None
        self._chunks: asyncio.Queue = asyncio.Queue()
        self._disconnect = asyncio.Event()
        self._request_sent = False
        self._task = None
        self._buf = ""
        self._kind = None
        self._data: list = []

    async def __aenter__(self):
        scope = {
            "type": "http", "asgi": {"version": "3.0",
                                     "spec_version": "2.1"},
            "http_version": "1.1", "method": "GET", "scheme": "http",
            "path": self.path, "raw_path": self.path.encode(),
            "query_string": b"", "root_path": "",
            "headers": [(b"host", b"test"),
                        (b"accept", b"text/event-stream")],
            "client": ("127.0.0.1", 12345), "server": ("test", 80),
        }

        async def receive():
            if not self._request_sent:
                self._request_sent = True
                return {"type": "http.request", "body": b"",
                        "more_body": False}
            await self._disconnect.wait()
            return {"type": "http.disconnect"}

        async def send(msg):
            if msg["type"] == "http.response.start":
                await self._chunks.put(("start", msg))
            elif msg["type"] == "http.response.body":
                body = msg.get("body", b"")
                if body:
                    await self._chunks.put(("body", body))
                if not msg.get("more_body", False):
                    await self._chunks.put(("end", None))

        self._task = asyncio.create_task(self.app(scope, receive, send))
        kind, msg = await asyncio.wait_for(self._chunks.get(), 5.0)
        assert kind == "start", kind
        self.status = msg["status"]
        return self

    async def __aexit__(self, *exc):
        self._disconnect.set()
        if self._task is not None:
            try:
                await asyncio.wait_for(asyncio.shield(self._task), 5.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                self._task.cancel()
            except Exception:
                pass

    def _parse(self):
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            line = line.rstrip("\r")
            if line == "":
                if self._data or self._kind:
                    ev = (self._kind or "message", "\n".join(self._data))
                    self._kind, self._data = None, []
                    return ev
                continue
            if line.startswith("event:"):
                self._kind = line[len("event:"):].strip()
            elif line.startswith("data:"):
                self._data.append(line[len("data:"):].lstrip())
        return None

    async def next_event(self, timeout=6.0):
        while True:
            ev = self._parse()
            if ev is not None:
                return ev
            kind, payload = await asyncio.wait_for(self._chunks.get(),
                                                   timeout)
            if kind == "end":
                return None
            self._buf += payload.decode()

    async def collect_mon(self, want_dies, timeout_s=10.0, max_events=200):
        """Read until every die in want_dies has sent a ``mon`` event."""
        seen: dict = {}

        async def _run():
            for _ in range(max_events):
                ev = await self.next_event()
                if ev is None:
                    break
                kind, data = ev
                if kind == "mon":
                    payload = json.loads(data)
                    seen[payload["die"]] = payload
                    if set(seen) >= set(want_dies):
                        return

        await asyncio.wait_for(_run(), timeout=timeout_s)
        return seen


# ── tests ────────────────────────────────────────────────────────────────

async def test_start_state_stop(app_cfg):
    app = make_app(app_cfg, stub_factory())
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.post("/api/monitor/start", json={"period_ms": 50})
            assert r.status_code == 201, r.text
            body = r.json()
            assert body["state"] == "running"
            assert sorted(body["dies"]) == ["master", "slave"]
            assert body["leased"] is False        # --fake runs leaseless

            snap = await _wait(c, _both_streaming)
            for name in ("master", "slave"):
                die = snap["dies"][name]
                assert die["state"] == "streaming"
                assert die["dec"]["fcsm"] == 4
                assert die["dec"]["cal_done"] == 1
                assert die["dec"]["credit_count"] > 0
                assert die["health"]["link_up"] is True
                assert die["health"]["criterion"] == "B"
                assert die["raw"]["108"].startswith("0x")
            # pair view is aligned by receipt order, never by clock
            assert snap["pair"]["criterion"] == "B"
            assert "receipt order" in snap["pair"]["aligned_by"]

            assert (await c.post("/api/monitor/stop")).json() == {
                "state": "stopped"}
            assert (await c.get("/api/monitor/state")).json()["state"] \
                == "idle"


async def test_sse_delivers_mon_for_both_dies(app_cfg):
    app = make_app(app_cfg, stub_factory())
    async with LifespanManager(app):
        async with await _client(app) as c:
            assert (await c.post("/api/monitor/start",
                                 json={"period_ms": 50})).status_code == 201
            async with SseClient(app) as sse:
                assert sse.status == 200
                # a joining browser is primed with the current snapshot
                kind, data = await sse.next_event()
                assert kind == "status"
                assert json.loads(data)["state"] == "running"
                seen = await sse.collect_mon(("master", "slave"))
            assert set(seen) == {"master", "slave"}
            for name, payload in seen.items():
                assert payload["dec"]["fcsm"] == 4
                assert payload["dec"]["cal_done"] == 1
                assert payload["health"]["link_up"] is True
                assert payload["derived"]["credit_frac"] > 0
                # rate keys always present (None until 2 polls of THIS die)
                assert "pair_credit_rate" in payload["derived"]
                assert "sync_rate" in payload["derived"]
                assert payload["raw"]["00c"].startswith("0x")
            await c.post("/api/monitor/stop")


async def test_derived_rates_from_consecutive_polls(app_cfg):
    """pair_credit_rate/sync_rate come from ONE die's own deltas."""
    app = make_app(app_cfg, stub_factory())
    async with LifespanManager(app):
        async with await _client(app) as c:
            await c.post("/api/monitor/start", json={"period_ms": 50})
            def _rated(s):
                dies = s.get("dies", {})
                return _both_streaming(s) and all(
                    d["derived"].get("pair_credit_rate") is not None
                    for d in dies.values())

            snap = await _wait(c, _rated)
            for die in snap["dies"].values():
                # stub adds +3 pair credits per 50 ms poll -> ~60/s
                assert 20.0 < die["derived"]["pair_credit_rate"] < 200.0
                # +1 sync_detected per poll -> ~20/s
                assert 5.0 < die["derived"]["sync_rate"] < 60.0
                assert die["derived"]["dt"] > 0
            await c.post("/api/monitor/stop")


async def test_double_start_409_and_stop_when_idle_is_noop(app_cfg):
    app = make_app(app_cfg, stub_factory())
    async with LifespanManager(app):
        async with await _client(app) as c:
            # stop before any start: 200 no-op, never an error
            r = await c.post("/api/monitor/stop")
            assert r.status_code == 200 and r.json()["state"] == "stopped"

            assert (await c.post("/api/monitor/start",
                                 json={"period_ms": 50})).status_code == 201
            r2 = await c.post("/api/monitor/start", json={"period_ms": 50})
            assert r2.status_code == 409
            assert "already running" in r2.json()["detail"]

            assert (await c.post("/api/monitor/stop")).status_code == 200
            # stopping twice is still a no-op
            assert (await c.post("/api/monitor/stop")).status_code == 200
            # and a fresh session is admissible afterwards
            assert (await c.post("/api/monitor/start",
                                 json={"period_ms": 50})).status_code == 201
            await c.post("/api/monitor/stop")


async def test_sse_fanout_two_subscribers(app_cfg):
    app = make_app(app_cfg, stub_factory())
    async with LifespanManager(app):
        async with await _client(app) as c:
            assert (await c.post("/api/monitor/start",
                                 json={"period_ms": 50})).status_code == 201
            sess = monitor.get_session(app.state.tlthroughput)
            async with SseClient(app) as s1, SseClient(app) as s2:
                assert len(sess._subs) == 2
                a, b = await asyncio.gather(
                    s1.collect_mon(("master", "slave")),
                    s2.collect_mon(("master", "slave")))
            assert set(a) == {"master", "slave"}
            assert set(b) == {"master", "slave"}
            # every subscriber gets its own queue: neither starved
            assert a["master"]["dec"]["fcsm"] == b["master"]["dec"]["fcsm"]
            assert sess.snapshot()["dropped_events"] == 0
            await c.post("/api/monitor/stop")
            # both subscriber queues cleaned up on disconnect
            assert sess._subs == []


async def test_dead_die_goes_stale_other_keeps_streaming(app_cfg):
    """One board's agent dies repeatedly; the other must not notice."""
    app = make_app(app_cfg, stub_factory(master_knobs={"STUB_DIE_AFTER": 2}))
    async with LifespanManager(app):
        async with await _client(app) as c:
            assert (await c.post("/api/monitor/start",
                                 json={"period_ms": 30})).status_code == 201
            snap = await _wait(
                c, lambda s: s["dies"]["master"]["state"] in ("stale",
                                                              "failed"),
                timeout_s=8.0)
            assert snap["dies"]["master"]["errors"] >= 1
            slave_polls = snap["dies"]["slave"]["polls"]
            assert slave_polls > 0

            # master exhausts its restart budget -> failed, and the SLAVE
            # keeps streaming right through it
            snap = await _wait(
                c, lambda s: s["dies"]["master"]["state"] == "failed",
                timeout_s=10.0)
            assert snap["dies"]["master"]["restarts"] == monitor.MAX_RESTARTS
            assert snap["dies"]["slave"]["state"] == "streaming"
            assert snap["dies"]["slave"]["polls"] > slave_polls
            # one dead board must NOT fail the session
            assert snap["state"] == "running"
            assert snap["pair"]["stale"] == ["master"]
            await c.post("/api/monitor/stop")


async def test_sticky_fault_latch_survives_clean_polls(app_cfg):
    """overrun is sticky in HW; the UI must not lose it between polls."""
    app = make_app(app_cfg,
                   stub_factory(master_knobs={"STUB_OVERRUN_AT": 2}))
    async with LifespanManager(app):
        async with await _client(app) as c:
            await c.post("/api/monitor/start", json={"period_ms": 30})
            # wait until the overrun poll has been seen AND a later clean
            # poll has overwritten dec.overrun back to 0
            snap = await _wait(
                c, lambda s: (s["dies"]["master"]["sticky"]["overrun_seen"]
                              and s["dies"]["master"]["dec"].get("overrun")
                              == 0
                              and s["dies"]["master"]["polls"] >= 4),
                timeout_s=8.0)
            m = snap["dies"]["master"]
            assert m["sticky"]["overrun_seen"] is True
            assert m["derived"]["overrun_seen"] is True
            assert m["derived"]["underrun_seen"] is False
            assert m["derived"]["master_error_seen"] is False
            # the peer die saw nothing and must stay clean
            assert snap["dies"]["slave"]["sticky"]["overrun_seen"] is False
            await c.post("/api/monitor/stop")


async def test_never_reads_outside_the_whitelist(app_cfg):
    """Whitelist containment, from three angles."""
    factory = stub_factory(master_knobs={"STUB_BAD_KEY": 1})
    app = make_app(app_cfg, factory)
    async with LifespanManager(app):
        async with await _client(app) as c:
            await c.post("/api/monitor/start", json={"period_ms": 30})
            sess = monitor.get_session(app.state.tlthroughput)

            # 1. the closed set of offsets the session can ever cause
            assert sess.requested_offsets <= regmap.MONITOR_OFFSETS
            assert sess.requested_offsets.isdisjoint(regmap.FORBIDDEN_OFFSETS)

            snap = await _wait(c, _both_streaming)

            # 2. the argv actually issued names no address at all — it
            #    only ever asks for the agent's whitelist-driven loop
            for ch in factory.made.values():           # type: ignore
                assert ch.argv_log, "no agent invocation recorded"
                for args in ch.argv_log:
                    assert args[0] == "--cmd" and args[1] == "monitor"
                    i = args.index("--args")
                    assert all(a in ("--crc", "--perf") for a in args[2:i])
                    assert all("0x" not in a for a in args)
                    for a in args[i + 1:]:
                        float(a)      # period/duration only, no offsets

            # 3. a poll carrying a FORBIDDEN register is dropped, counted,
            #    and never rendered
            m = snap["dies"]["master"]
            assert "020" not in m["raw"]
            assert all(k in {kk for _, kk in regmap.MONITOR_WHITELIST}
                       or k == "crc" for k in m["raw"])
            assert m["errors"] >= 1
            await c.post("/api/monitor/stop")


@pytest.mark.parametrize("mode", ["cleared", "cumulative"])
async def test_perf_windows_are_scored_by_window_mode(app_cfg, mode):
    """Phase-B: a CLEARED window is already a delta.

    Differencing two cleared records gives ~0, perf_window() returns {},
    and a perfectly healthy block renders as "no perf data" — an
    instrument bug wearing a DUT finding's clothes. Both protocols must
    yield the same fractions.
    """
    knobs = {"STUB_PERF_MODE": mode}
    app = make_app(app_cfg, stub_factory(master_knobs=knobs,
                                         slave_knobs=knobs))
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.post("/api/monitor/start",
                             json={"period_ms": 40, "perf": True})
            assert r.status_code == 201 and r.json()["perf"] is True
            sess = monitor.get_session(app.state.tlthroughput)
            assert regmap.PERF_OFFSETS <= sess.requested_offsets
            assert sess.requested_offsets.isdisjoint(regmap.FORBIDDEN_OFFSETS)

            snap = await _wait(
                c, lambda s: all(d.get("perf_window")
                                 for d in s.get("dies", {}).values()))
            for die in snap["dies"].values():
                assert die["perf"]["perf_block_present"] == 1
                assert die["perf_window_mode"] == mode
                assert die["perf_window"]["d_sample"] == 100
                assert die["perf_window"]["utilisation"] == 0.5
                assert die["perf_window"]["tx_stall_frac"] == 0.02
            await c.post("/api/monitor/stop")


async def test_torn_crc_sample_needs_a_second_witness(app_cfg):
    """CRC is unsynchronised across clock domains: a single sample can be
    TORN, so the published value only moves on two agreeing polls."""
    knobs = {"STUB_CRC": "0,0,0,9999,0,0,7,7,7,7"}
    app = make_app(app_cfg, stub_factory(master_knobs=knobs))
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.post("/api/monitor/start",
                             json={"period_ms": 30, "crc": True})
            assert r.status_code == 201 and r.json()["crc"] is True
            saw_torn = False
            async with SseClient(app) as sse:
                for _ in range(200):
                    ev = await sse.next_event()
                    if ev is None:
                        break
                    kind, data = ev
                    if kind != "mon":
                        continue
                    p = json.loads(data)
                    if p["die"] != "master":
                        continue
                    dec = p["dec"]
                    # the spike is NEVER published as the CRC count
                    assert dec["crc_errors"] != 9999
                    if dec.get("crc_errors_raw") == 9999:
                        saw_torn = True
                        assert dec["crc_errors"] == 0    # last agreed held
                        assert dec["crc_unconfirmed"] == 1
                    if dec["crc_errors"] == 7:           # confirmed rise
                        assert dec["crc_unconfirmed"] == 0
                        break
                else:
                    pytest.fail("confirmed CRC rise never arrived")
            assert saw_torn, "stub never delivered the torn sample"
            await c.post("/api/monitor/stop")


async def test_events_404_without_session_and_bad_period_400(app_cfg):
    app = make_app(app_cfg, stub_factory())
    async with LifespanManager(app):
        async with await _client(app) as c:
            r = await c.get("/api/monitor/events")
            assert r.status_code == 404
            r = await c.post("/api/monitor/start", json={"period_ms": 0})
            assert r.status_code == 400
            r = await c.post("/api/monitor/start", json={"period_ms": 999999})
            assert r.status_code == 400
            # a sub-second backstop would relaunch the agent in a loop
            r = await c.post("/api/monitor/start",
                             json={"period_ms": 50, "duration_s": 0})
            assert r.status_code == 400
            assert (await c.get("/api/monitor/state")).json()["state"] \
                == "idle"


async def test_unsupported_agent_fails_dies_not_the_server(app_cfg):
    """An old agent with no monitor role: dies fail, nothing hangs."""
    app = make_app(app_cfg, stub_factory(
        master_knobs={"STUB_UNSUPPORTED": 1},
        slave_knobs={"STUB_UNSUPPORTED": 1}))
    async with LifespanManager(app):
        async with await _client(app) as c:
            assert (await c.post("/api/monitor/start",
                                 json={"period_ms": 30})).status_code == 201
            snap = await _wait(
                c, lambda s: s["state"] == "failed", timeout_s=10.0)
            assert all(d["state"] == "failed"
                       for d in snap["dies"].values())
            assert "monitor" in snap["dies"]["master"]["reason"]
            await c.post("/api/monitor/stop")


async def test_shutdown_stops_session_and_closes_channels(app_cfg):
    factory = stub_factory()
    app = make_app(app_cfg, factory)
    async with LifespanManager(app):
        async with await _client(app) as c:
            await c.post("/api/monitor/start", json={"period_ms": 50})
            await _wait(c, _both_streaming)
            state = app.state.tlthroughput
            sess = monitor.get_session(state)
            await monitor.shutdown(state)          # app.py shutdown hook
            assert sess.state == "stopped"
            assert monitor.get_session(state) is None
            for ch in factory.made.values():       # type: ignore
                assert ch._proc is None            # processes reaped


# ── integration with the REAL agent (skips until Agent A lands it) ───────

def _agent_supports_monitor(tmp_path) -> bool:
    env = dict(os.environ,
               TIDELINK_FAKE_LINK_DIR=str(tmp_path),
               TIDELINK_FAKE_ROLE="master")
    try:
        out = subprocess.run(
            [sys.executable, str(AGENT_PATH), "--fake",
             "--cmd", "monitor", "--args", "50", "0.4"],
            capture_output=True, timeout=20, env=env).stdout.decode()
    except Exception:
        return False
    return any('"ev":"mon"' in ln.replace(" ", "") for ln in out.splitlines())


async def test_real_local_agent_monitor_stream(tmp_path):
    """End-to-end over LocalAgentChannel + tl_perf_agent.py --fake."""
    if not _agent_supports_monitor(tmp_path):
        pytest.skip("tl_perf_agent.py has no --cmd monitor yet (Agent A)")
    wire = tmp_path / "wire"
    wire.mkdir(exist_ok=True)
    sess = monitor.MonitorSession(
        {"master": LocalAgentChannel("master", wire),
         "slave": LocalAgentChannel("slave", wire)},
        period_ms=50, duration_s=10.0, crc=True)
    await sess.start()
    try:
        for _ in range(120):
            snap = sess.snapshot()
            # crc_errors is None until two polls agree (tearing filter),
            # so this also proves --crc reached the agent.
            if all(d["dec"].get("fcsm") is not None
                   and d["dec"].get("crc_errors") is not None
                   for d in snap["dies"].values()):
                break
            await asyncio.sleep(0.05)
        else:
            pytest.fail("no decoded poll from the real agent: %s"
                        % json.dumps(sess.snapshot())[:600])
        for die in sess.snapshot()["dies"].values():
            assert die["dec"]["cal_done"] == 1
            assert die["dec"]["fcsm"] in regmap.FCSM_HEALTHY
            assert set(die["raw"]) <= {k for _, k in
                                       regmap.MONITOR_WHITELIST} | {"crc"}
            # crc=True must actually reach the agent: tl_perf_agent takes
            # --crc as a SWITCH, and an --args token would be swallowed
            # silently by its nargs="*" (regression guard).
            assert die["dec"]["crc_errors_raw"] is not None
            assert die["dec"]["crc_errors"] is not None
            assert die["dec"]["crc_unconfirmed"] == 0
    finally:
        await sess.stop()


async def test_real_agent_sticky_overrun_reaches_the_latch(tmp_path):
    """TIDELINK_FAKE_OVERRUN_AT_S -> STATUS[1] -> decode -> latch."""
    if not _agent_supports_monitor(tmp_path):
        pytest.skip("tl_perf_agent.py has no --cmd monitor yet (Agent A)")
    wire = tmp_path / "wire_ov"
    wire.mkdir(exist_ok=True)
    sess = monitor.MonitorSession(
        {"master": LocalAgentChannel(
            "master", wire,
            extra_env={"TIDELINK_FAKE_OVERRUN_AT_S": "0.2"}),
         "slave": LocalAgentChannel("slave", wire)},
        period_ms=50, duration_s=10.0)
    await sess.start()
    try:
        for _ in range(120):
            snap = sess.snapshot()
            if snap["dies"]["master"]["sticky"]["overrun_seen"]:
                break
            await asyncio.sleep(0.05)
        else:
            pytest.fail("sticky overrun never surfaced: %s"
                        % json.dumps(sess.snapshot()["dies"]["master"])[:600])
        m = sess.snapshot()["dies"]["master"]
        assert m["dec"]["overrun"] == 1
        assert m["derived"]["overrun_seen"] is True
        assert any("overrun" in r for r in m["health"]["reasons"])
        assert m["health"]["link_up"] is True      # sticky != link down
        # the peer die is untouched — faults are per-die
        assert sess.snapshot()["dies"]["slave"]["sticky"][
            "overrun_seen"] is False
    finally:
        await sess.stop()
