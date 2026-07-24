"""Link-monitor agent (--cmd monitor / --cmd setthr) against the --fake
backend, through real local subprocesses — the same code path the server
drives over SSH, minus the SSH.

The load-bearing test here is `test_mon_rd_*`: the monitor's promise is
"zero reads outside MONITOR_WHITELIST", and on this APB a stray read is
either a read-clear that corrupts the credit protocol or an
uninterruptible PS hang needing a power-cycle. That promise is only worth
anything if it is asserted in code and checked in CI, so these tests poke
at the accessor directly and also record every bus access a whole monitor
run makes.
"""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from pynq_host.throughput_gui import regmap

AGENT_PATH = (Path(__file__).resolve().parent.parent
              / "agent" / "tl_perf_agent.py")


def _load_agent():
    """Import the board agent by path.

    It is deliberately NOT a package member: production `cat`s this one
    file onto a plain PYNQ image and runs it standalone, so it must never
    grow an intra-repo import.
    """
    spec = importlib.util.spec_from_file_location("tl_perf_agent",
                                                  str(AGENT_PATH))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tl_agent = _load_agent()


# ── helpers ──────────────────────────────────────────────────────────────

def _env(link_dir, role="master", extra=None):
    env = dict(os.environ)
    env["TIDELINK_FAKE_LINK_DIR"] = str(link_dir)
    env["TIDELINK_FAKE_ROLE"] = role
    env.update(extra or {})
    return env


def _ndjson(blob):
    out = []
    for line in blob.decode(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{"):
            out.append(json.loads(line))
    return out


def _run_agent(link_dir, args, *, role="master", extra_env=None,
               timeout=60):
    proc = subprocess.run(
        [sys.executable, str(AGENT_PATH), "--fake"] + args,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=_env(link_dir, role, extra_env), timeout=timeout)
    return proc, _ndjson(proc.stdout)


def _of(events, ev):
    return [e for e in events if e.get("ev") == ev]


class _BoomMem(object):
    """Any bus access at all is a test failure — proves _mon_rd rejects
    BEFORE it touches the bus, not after."""

    def rd(self, addr):
        raise AssertionError("bus was touched at 0x%08x" % addr)

    def wr(self, addr, val):
        raise AssertionError("bus was written at 0x%08x" % addr)


class _RecordingMem(tl_agent._FakeMem):
    """Fake die that logs every address it is asked to touch."""

    def __init__(self):
        tl_agent._FakeMem.__init__(self)
        self.reads = []
        self.writes = []

    def rd(self, addr):
        self.reads.append(addr)
        return tl_agent._FakeMem.rd(self, addr)

    def wr(self, addr, val):
        self.writes.append(addr)
        return tl_agent._FakeMem.wr(self, addr, val)


@pytest.fixture
def agent_signals():
    """cmd_monitor installs SIGTERM/SIGINT handlers; restore pytest's own
    afterwards so a later Ctrl-C still raises KeyboardInterrupt."""
    saved = {s: signal.getsignal(s)
             for s in (signal.SIGTERM, signal.SIGINT)}
    tl_agent._STOP["flag"] = False
    yield
    for sig, handler in saved.items():
        signal.signal(sig, handler)
    tl_agent._STOP["flag"] = False


@pytest.fixture
def fake_mem(link_dir, monkeypatch):
    monkeypatch.setenv("TIDELINK_FAKE_LINK_DIR", str(link_dir))
    monkeypatch.setenv("TIDELINK_FAKE_ROLE", "master")
    return tl_agent._FakeMem()


# ── whitelist enforcement (the deliverable) ──────────────────────────────

def test_agent_whitelists_are_the_host_twin():
    """The board agent is stdlib-only and cannot import regmap, so the
    whitelist is DUPLICATED. Duplication only stays honest if something
    fails loudly when the two drift."""
    assert tl_agent.MONITOR_WHITELIST == regmap.MONITOR_WHITELIST
    assert tl_agent.MONITOR_OFFSETS == regmap.MONITOR_OFFSETS
    assert tl_agent.PERF_WHITELIST == regmap.PERF_WHITELIST
    assert tl_agent.PERF_OFFSETS == regmap.PERF_OFFSETS
    assert tl_agent.FORBIDDEN_OFFSETS == regmap.FORBIDDEN_OFFSETS
    assert tl_agent.PERF_CTRL_OFF == regmap.PERF_CTRL_OFF
    assert tl_agent.PERF_ID_EXPECT == regmap.PERF_ID_EXPECT
    assert tl_agent.REL_THRESHOLD_POR == regmap.REL_THRESHOLD_POR
    assert tl_agent.WLINK_CRC_ERR_ADDR == regmap.WLINK_CRC_ERR_ADDR


def test_mon_rd_refuses_non_whitelisted_offset():
    for off in (0x000, 0x004, 0x014, 0x02C, 0x0A0, 0x104, 0x1FC):
        assert off not in tl_agent.MONITOR_OFFSETS
        assert off not in tl_agent.FORBIDDEN_OFFSETS   # other branch
        with pytest.raises(ValueError, match="not on the monitor whitelist"):
            tl_agent._mon_rd(_BoomMem(), off)


def test_mon_rd_refuses_every_forbidden_offset():
    """Forbidden wins over ANY allow set a caller passes — 0x1AC/0x1B0/
    0x1B4 hard-hang the PS and 0x020/0x024 are read-clear."""
    everything = frozenset(range(0x000, 0x200, 4))
    for off in sorted(regmap.FORBIDDEN_OFFSETS):
        with pytest.raises(ValueError, match="forbidden"):
            tl_agent._mon_rd(_BoomMem(), off)
        with pytest.raises(ValueError, match="forbidden"):
            tl_agent._mon_rd(_BoomMem(), off, everything)


def test_mon_rd_accepts_every_whitelisted_offset(fake_mem):
    for off, _key in tl_agent.MONITOR_WHITELIST:
        assert isinstance(tl_agent._mon_rd(fake_mem, off), int)


def test_mon_rd_gates_the_perf_block_behind_its_own_allow_set(fake_mem):
    """Perf offsets are NOT reachable through the default monitor allow
    set — --perf has to opt in explicitly."""
    with pytest.raises(ValueError, match="whitelist"):
        tl_agent._mon_rd(fake_mem, 0x0E8)
    assert isinstance(
        tl_agent._mon_rd(fake_mem, 0x0E8, tl_agent.PERF_ACCESS_OFFSETS), int)


def test_monitor_run_touches_nothing_but_the_whitelist(link_dir, monkeypatch,
                                                       agent_signals):
    """Whole-run proof: every address a monitor loop touches, recorded.

    Covers what a subprocess test cannot see — that AHB_TX and the
    pop-on-read RX FIFO aperture are never touched, and that a monitor
    without --perf issues no writes at all.
    """
    monkeypatch.setenv("TIDELINK_FAKE_LINK_DIR", str(link_dir))
    monkeypatch.setenv("TIDELINK_FAKE_ROLE", "master")
    mem = _RecordingMem()
    monkeypatch.setattr(tl_agent, "_emit", lambda obj: None)
    tl_agent.cmd_monitor(mem, 20, 0.3)

    allowed = set(tl_agent.PAIR_BASE + off
                  for off in tl_agent.MONITOR_OFFSETS)
    assert set(mem.reads) <= allowed
    assert mem.writes == []
    assert tl_agent.TX_BASE not in mem.reads
    assert tl_agent.RXF_BASE not in mem.reads


def test_monitor_with_perf_and_crc_stays_inside_its_declared_surface(
        link_dir, monkeypatch, agent_signals):
    monkeypatch.setenv("TIDELINK_FAKE_LINK_DIR", str(link_dir))
    monkeypatch.setenv("TIDELINK_FAKE_ROLE", "master")
    mem = _RecordingMem()
    monkeypatch.setattr(tl_agent, "_emit", lambda obj: None)
    tl_agent.cmd_monitor(mem, 20, 0.4, want_perf=True, want_crc=True,
                         perf_window_s=0.1)

    allowed = set(tl_agent.PAIR_BASE + off
                  for off in (tl_agent.MONITOR_OFFSETS
                              | tl_agent.PERF_ACCESS_OFFSETS))
    allowed.add(tl_agent.WLINK_CRC_ERR_ADDR)
    assert set(mem.reads) <= allowed
    # PERF_CTRL is the ONLY thing the monitor ever writes
    assert set(mem.writes) == {tl_agent.PAIR_BASE + tl_agent.PERF_CTRL_OFF}


# ── monitor stream shape ─────────────────────────────────────────────────

def test_monitor_stream_shape(link_dir):
    proc, events = _run_agent(link_dir, ["--cmd", "monitor",
                                         "--args", "60", "0.8"])
    assert proc.returncode == 0, proc.stderr
    mons = _of(events, "mon")
    done = _of(events, "done")
    assert len(mons) >= 5
    assert len(done) == 1

    keys = set(key for _off, key in tl_agent.MONITOR_WHITELIST)
    for i, ev in enumerate(mons):
        assert ev["seq"] == i
        assert set(ev["r"]) == keys              # no crc without --crc
        assert all(isinstance(v, int) for v in ev["r"].values())

    times = [ev["t"] for ev in mons]
    assert times == sorted(times) and len(set(times)) == len(times)

    summary = done[0]["summary"]
    assert summary["samples"] == len(mons)
    assert summary["errors"] == 0
    assert 0.8 <= summary["elapsed_s"] <= 1.4


def test_monitor_pacing_is_anchored_not_accumulated(link_dir):
    """Deadlines come from the start anchor, so sample k lands near
    t0 + k*period. Sleeping `period` after each poll would drift by the
    poll cost every time and quietly bias every derived rate."""
    period_s = 0.05
    _proc, events = _run_agent(link_dir,
                               ["--cmd", "monitor", "--args", "50", "1.0"])
    times = [ev["t"] for ev in _of(events, "mon")]
    assert len(times) >= 10
    t0 = times[0]
    drift = [abs((t - t0) - i * period_s) for i, t in enumerate(times)]
    assert max(drift) < 5 * period_s, "pacing drifted: %r" % drift[-5:]


def test_monitor_crc_flag_adds_exactly_one_key(link_dir):
    _proc, events = _run_agent(
        link_dir, ["--cmd", "monitor", "--args", "50", "0.3", "--crc"],
        extra_env={"TIDELINK_FAKE_CRC_ERRS": "7"})
    mons = _of(events, "mon")
    assert mons
    assert all(ev["r"]["crc"] == 7 for ev in mons)
    dec = regmap.decode_monitor(mons[-1]["r"])
    assert dec["crc_errors"] == 7


# ── decode round-trip ────────────────────────────────────────────────────

def test_decode_monitor_round_trip_on_a_healthy_fake(link_dir):
    _proc, events = _run_agent(link_dir,
                               ["--cmd", "monitor", "--args", "50", "0.4"])
    mons = _of(events, "mon")
    assert mons
    dec = regmap.decode_monitor(mons[-1]["r"])

    assert dec["fcsm"] == 4                      # LINK_IDLE
    assert dec["cal_done"] == 1
    assert dec["cal_state"] == tl_agent.CAL_STATE_DONE
    assert dec["credit_count"] == regmap.MAX_CREDITS
    assert dec["occupancy"] == 0
    assert dec["credit_frac"] == 1.0
    assert dec["overrun"] == 0 and dec["underrun"] == 0
    assert dec["master_error"] == 0
    assert dec["ctrl_lock"] == 0                 # threshold is writable
    assert dec["mask_hs_match"] == 1 and dec["gate_open"] == 1
    assert dec["epoch_anchored"] == 1
    assert dec["sync_obs_v2"] == 1 and dec["sync_det_v2"] == 1
    assert dec["fc_obs_live"] == 1
    assert dec["sync_detected"] > 0              # creeping up

    verdict = regmap.health(dec)
    assert verdict["link_up"] is True
    assert verdict["criterion"] == "B"
    assert verdict["jam"] is None
    assert verdict["reasons"] == []


def test_sync_detected_advances_across_the_run(link_dir):
    _proc, events = _run_agent(link_dir,
                               ["--cmd", "monitor", "--args", "50", "0.8"])
    mons = _of(events, "mon")
    first = regmap.decode_monitor(mons[0]["r"])["sync_detected"]
    last = regmap.decode_monitor(mons[-1]["r"])["sync_detected"]
    assert last > first


def test_injected_overrun_is_sticky_and_surfaces_in_health(link_dir):
    _proc, events = _run_agent(
        link_dir, ["--cmd", "monitor", "--args", "50", "0.9"],
        extra_env={"TIDELINK_FAKE_OVERRUN_AT_S": "0.3"})
    decoded = [regmap.decode_monitor(ev["r"]) for ev in _of(events, "mon")]
    flags = [d["overrun"] for d in decoded]
    assert flags[0] == 0 and flags[-1] == 1
    # STICKY in HW: once set it must never fall back to 0
    first_set = flags.index(1)
    assert all(f == 1 for f in flags[first_set:])
    assert any("STICKY overrun" in r
               for r in regmap.health(decoded[-1])["reasons"])


# ── stop paths ───────────────────────────────────────────────────────────

def _spawn_open_ended(link_dir, extra_args=()):
    return subprocess.Popen(
        [sys.executable, str(AGENT_PATH), "--fake",
         "--cmd", "monitor", "--args", "50", "0"] + list(extra_args),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=_env(link_dir))


def _await_first_mon(proc, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if line.strip().startswith(b"{"):
            return json.loads(line)
    raise AssertionError("agent never emitted a mon line")


def test_open_ended_monitor_stops_on_sigterm_and_still_summarises(link_dir):
    """A killed poll loop that never summarises is indistinguishable from
    a wedged board, so SIGTERM must end the loop CLEANLY."""
    proc = _spawn_open_ended(link_dir)
    try:
        _await_first_mon(proc)
        proc.send_signal(signal.SIGTERM)
        rest, _err = proc.communicate(timeout=20)
    finally:
        if proc.poll() is None:
            proc.kill()
    events = _ndjson(rest)
    assert proc.returncode == 0
    done = _of(events, "done")
    assert len(done) == 1
    assert done[0]["summary"]["samples"] >= 1
    assert done[0]["summary"]["errors"] == 0


def test_open_ended_monitor_stops_when_stdin_closes(link_dir):
    proc = _spawn_open_ended(link_dir)
    try:
        _await_first_mon(proc)
        proc.stdin.close()
        rest = proc.stdout.read()          # EOF once the agent exits
        proc.wait(timeout=20)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.stdout.close()
        proc.stderr.close()
    assert proc.returncode == 0
    assert len(_of(_ndjson(rest), "done")) == 1


def test_finite_run_is_not_killed_by_a_closed_stdin(link_dir):
    """A finite duration must survive `< /dev/null` — stdin is only a stop
    channel for the open-ended case."""
    proc = subprocess.run(
        [sys.executable, str(AGENT_PATH), "--fake",
         "--cmd", "monitor", "--args", "50", "0.5"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=_env(link_dir), timeout=30)
    events = _ndjson(proc.stdout)
    assert len(_of(events, "mon")) >= 5
    assert _of(events, "done")[0]["summary"]["elapsed_s"] >= 0.5


# ── setthr ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("value", [0, 1, 20, 4095])
def test_setthr_accepts_in_range(link_dir, value):
    proc, events = _run_agent(link_dir,
                              ["--cmd", "setthr", "--args", str(value)])
    assert proc.returncode == 0
    rec = events[-1]
    assert rec["wrote"] == value
    assert rec["rel_threshold"] == value
    assert rec["por"] == regmap.REL_THRESHOLD_POR == 20
    assert rec["locked"] == 0 and rec["ctrl_lock"] == 0


@pytest.mark.parametrize("value", [-1, 4096, 99999])
def test_setthr_refuses_out_of_range(link_dir, value):
    proc, events = _run_agent(link_dir,
                              ["--cmd", "setthr", "--args", str(value)])
    assert proc.returncode != 0
    assert "out of range" in events[-1]["error"]


def test_setthr_reports_a_locked_register_instead_of_the_stale_value(
        link_dir):
    """CTRL.LOCK blocks the write SILENTLY — no pslverr. Returning the
    stale readback as if it had landed would let the UI show a threshold
    the hardware never took."""
    proc, events = _run_agent(
        link_dir, ["--cmd", "setthr", "--args", "0"],
        extra_env={"TIDELINK_FAKE_CTRL_LOCK": "1"})
    assert proc.returncode == 0
    rec = events[-1]
    assert rec["wrote"] == 0
    assert rec["ctrl_lock"] == 1
    assert rec["locked"] == 1
    assert rec["rel_threshold"] == regmap.REL_THRESHOLD_POR


# ── perf windows (phase B) ───────────────────────────────────────────────

def _zero_perf_baseline():
    """Counters as they stand immediately after PERF_CTRL clear.

    Each emitted window STARTS with a clear, so a record is already a
    delta over win_s — it is diffed against zero, never against the
    previous record (see _perf_tick / window_mode)."""
    raw = dict((key, 0) for _off, key in tl_agent.PERF_WHITELIST)
    raw["0fc"] = regmap.PERF_ID_EXPECT
    return regmap.decode_perf(raw)


def test_perf_windows_are_live_and_frozen_by_default(link_dir):
    proc, events = _run_agent(
        link_dir, ["--cmd", "monitor", "--args", "50", "1.0",
                   "--perf", "--perf-window", "0.25"])
    assert proc.returncode == 0
    ids = _of(events, "perf_id")
    perfs = _of(events, "perf")
    assert len(ids) == 1, "perf_id must be emitted exactly once, on window 1"
    assert ids[0]["block_present"] == 1
    assert ids[0]["perf_ctrl_writable"] == 1
    assert len(perfs) >= 2

    for win in perfs:
        assert win["window_mode"] == "cleared"
        dec = regmap.decode_perf(win["r"])
        assert dec["perf_vintage"] == "post-fix"
        assert dec["perf_block_present"] == 1
        # read ONLY while frozen — an unfrozen read is not a window
        assert dec["perf_frozen"] == 1
        assert dec["sample_count"] > 0

    zero = _zero_perf_baseline()
    for win in perfs[:2]:
        got = regmap.perf_window(zero, regmap.decode_perf(win["r"]))
        assert got, "live counters must yield a window"
        assert 0.0 <= got["utilisation"] <= 1.0
        assert 0.0 <= got["tx_stall_frac"] <= 1.0
        assert got["d_rx_words"] > 0
    # the modeled anchor: 16 link-busy cycles of a 96-cycle per-word cost
    util = regmap.perf_window(zero,
                              regmap.decode_perf(perfs[0]["r"]))["utilisation"]
    assert 0.10 < util < 0.25


def test_perf_on_a_golden_image_reads_no_data_not_zero_utilisation(link_dir):
    """TIDELINK_FAKE_PERF_DEAD models the deployed golden Z2 bitstream:
    pre-region-fix, so PERF_CTRL is unwritable and the whole block reads
    one region low (PERF_ID at 0x0DC, 0x0FC reads 0 like a dead bus).
    That must surface as "no data" — reporting 0% utilisation would be a
    fabricated measurement."""
    proc, events = _run_agent(
        link_dir, ["--cmd", "monitor", "--args", "50", "0.9",
                   "--perf", "--perf-window", "0.25"],
        extra_env={"TIDELINK_FAKE_PERF_DEAD": "1"})
    assert proc.returncode == 0
    probe = _of(events, "perf_id")[0]
    assert probe["block_present"] == 0          # 0x0FC reads 0 pre-fix
    assert probe["perf_ctrl_writable"] == 0     # the only sound liveness test

    perfs = _of(events, "perf")
    assert perfs
    zero = _zero_perf_baseline()
    for win in perfs:
        dec = regmap.decode_perf(win["r"])
        # the shifted PERF_ID is what actually identifies the vintage
        assert dec["perf_vintage"] == "pre-fix"
        got = regmap.perf_window(zero, dec)
        assert got == {}
        assert "utilisation" not in got


def test_monitor_without_perf_emits_no_perf_records(link_dir):
    _proc, events = _run_agent(link_dir,
                               ["--cmd", "monitor", "--args", "50", "0.3"])
    assert _of(events, "perf") == []
    assert _of(events, "perf_id") == []
