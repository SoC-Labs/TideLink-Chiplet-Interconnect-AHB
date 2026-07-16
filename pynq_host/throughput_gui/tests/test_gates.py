"""regmap decode, criterion-A/B gate, jam-signature matrix, mutex."""
from __future__ import annotations

import pytest

from pynq_host.throughput_gui import regmap
from pynq_host.throughput_gui.gates import (
    ExperimentMutex, MutexHeld, sample_excursion,
)


def _ls(locked=0, cal=1, fcsm=4, a2l_app=0, a2l_lnk=0, fe_full=0, cr=0):
    return (locked | (cal << 16) | (fcsm << 17) | (a2l_app << 20)
            | (cr << 23) | (a2l_lnk << 30) | (fe_full << 31))


# ── decode (authoritative tlchar packing: fcsm THREE bits [19:17]) ───────

def test_decode_lane_status():
    # v33 milestone fingerprint: cal_done=1, fcsm=4, nothing else
    d = regmap.decode_lane_status(_ls(fcsm=4))
    assert d["cal_done"] == 1 and d["fcsm"] == 4
    assert d["fe_rx_is_full"] == 0 and d["lock_count"] == 0
    # fcsm must NOT swallow bit 20 (the stale 4-bit RDL decode bug)
    d = regmap.decode_lane_status(_ls(fcsm=5, a2l_app=1))
    assert d["fcsm"] == 5
    assert d["a2l_replay_app_valid"] == 1
    d = regmap.decode_lane_status(_ls(locked=0xFF, fe_full=1))
    assert d["lock_count"] == 8 and d["fe_rx_is_full"] == 1


def test_decode_obs_fc_credit():
    d = regmap.decode_obs_fc_credit(0xFC00071F)
    assert d["fc_obs_live"] == 1
    assert d["fe_rx_credit_max"] == 0x1F
    assert d["fe_rx_ptr"] == 0x07
    assert regmap.decode_obs_fc_credit(0)["fc_obs_live"] == 0


# ── criterion A/B (port of tt_verify_link_up) ────────────────────────────

def _dec(**kw):
    return regmap.decode_lane_status(_ls(**kw))


def test_criterion_a():
    v = regmap.verify_link_up(_dec(locked=0xFF, fcsm=0),
                              _dec(locked=0xFF, fcsm=0))
    assert v.ok and v.criterion == "A"


def test_criterion_b_post_m12():
    # data-mode: lane_locked=0 is EXPECTED, FCSM 4/5 + cal_done both
    v = regmap.verify_link_up(_dec(fcsm=4), _dec(fcsm=5))
    assert v.ok and v.criterion == "B"
    assert v.snapshot["m_fcsm"] == 4 and v.snapshot["s_fcsm"] == 5


def test_gate_fails_closed():
    # cal_done missing on one side
    v = regmap.verify_link_up(_dec(fcsm=4), _dec(cal=0, fcsm=4))
    assert not v.ok and v.criterion is None
    # FCSM out of {4,5}
    v = regmap.verify_link_up(_dec(fcsm=4), _dec(fcsm=1))
    assert not v.ok
    # 8/8 lanes but cal_done=0 is NOT criterion A
    v = regmap.verify_link_up(_dec(locked=0xFF, cal=0, fcsm=4),
                              _dec(locked=0xFF, cal=0, fcsm=4))
    assert not v.ok


# ── jam-signature matrix (port of unjam_fc_node.sh) ──────────────────────

def test_jam_classic():
    d = _dec(fcsm=5, a2l_lnk=1, fe_full=0)
    assert regmap.classify_jam(d) == regmap.JAM_CLASSIC


def test_jam_held_replay():
    d = _dec(fcsm=4, a2l_app=1, fe_full=1)
    assert regmap.classify_jam(d) == regmap.JAM_HELD_REPLAY


def test_jam_negative_cases():
    assert regmap.classify_jam(_dec(fcsm=4)) is None
    assert regmap.classify_jam(_dec(fcsm=5)) is None
    # fe_full=1 disqualifies CLASSIC
    assert regmap.classify_jam(_dec(fcsm=5, a2l_lnk=1, fe_full=1)) is None
    # fcsm=5 disqualifies HELD-REPLAY
    assert regmap.classify_jam(_dec(fcsm=5, a2l_app=1, fe_full=1)) is None


def test_sample_excursion():
    healthy = {"board": "master", "fcsm": 4}
    assert sample_excursion(healthy) is None
    assert sample_excursion({"board": "master", "fcsm": 5}) is None
    jam = {"board": "master", "fcsm": 5, "a2l_fc_replay_link_valid": 1,
           "fe_rx_is_full": 0}
    assert "CLASSIC" in sample_excursion(jam)
    exc = {"board": "slave", "fcsm": 1}
    assert "link_excursion" in sample_excursion(exc)
    # samples without observer fields are not classified
    assert sample_excursion({"board": "x"}) is None


# ── single-experiment mutex ───────────────────────────────────────────────

def test_mutex_exclusive(tmp_path):
    path = tmp_path / "hw.lock"
    m1 = ExperimentMutex(path)
    m2 = ExperimentMutex(path)
    m1.acquire("test-one")
    # re-acquire on the same object is refused
    with pytest.raises(MutexHeld):
        m1.acquire()
    # a second open file description (e.g. the stress GUI) is refused too
    with pytest.raises(MutexHeld):
        m2.acquire()
    m1.release()
    m2.acquire("test-two")
    m2.release()
    assert not m2.held


def test_mutex_cross_process(tmp_path):
    """The flock must hold against a different PROCESS (flock is
    per-open-file-description, so this needs a real subprocess)."""
    import subprocess, sys, textwrap
    path = tmp_path / "hw.lock"
    m = ExperimentMutex(path)
    m.acquire("pytest")
    code = textwrap.dedent("""
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit(42)     # correctly refused
        sys.exit(0)          # BAD: lock was not held
    """)
    rc = subprocess.run([sys.executable, "-c", code, str(path)]).returncode
    m.release()
    assert rc == 42
