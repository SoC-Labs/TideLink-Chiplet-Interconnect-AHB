"""Run store: creation, fail-closed provenance, samples, index, CSV."""
from __future__ import annotations

import json

import pytest

from pynq_host.throughput_gui.provenance import ProvenanceError
from pynq_host.throughput_gui.store import RunStore, SAMPLE_CSV_COLUMNS

BOARDS = {"master": "192.168.4.101", "slave": "192.168.6.101",
          "pair": "bridge1"}


def _mk(store, prov, **kw):
    return store.create_run(test="throughput_m2s",
                            params={"burst_words": 16, "duration_s": 2.0},
                            boards=BOARDS, provenance=prov, **kw)


def test_create_and_get(store, valid_provenance):
    rec = _mk(store, valid_provenance)
    rid = rec["run_id"]
    got = store.get_run(rid)
    assert got["test"] == "throughput_m2s"
    assert got["state"] == "created"
    assert got["provenance"]["master"]["sha256"] \
        == valid_provenance["master"]["sha256"]
    assert got["boards"]["pair"] == "bridge1"
    # run dir + run.json on disk
    assert (store.root / rid / "run.json").is_file()


def test_fail_closed_no_provenance(store):
    """THE provenance gate: no manifest sha -> NO run record, ever."""
    with pytest.raises(ProvenanceError):
        _mk(store, None)
    with pytest.raises(ProvenanceError):
        _mk(store, {})
    assert store.list_runs() == []
    # nothing on disk either
    assert not [p for p in store.root.iterdir()
                if p.name != "runs.sqlite3"]


def test_fail_closed_bad_sha(store, valid_provenance):
    bad = json.loads(json.dumps(valid_provenance))
    bad["slave"]["sha256"] = "not-a-sha"
    with pytest.raises(ProvenanceError):
        _mk(store, bad)
    bad["slave"]["sha256"] = ""
    with pytest.raises(ProvenanceError):
        _mk(store, bad)
    assert store.list_runs() == []


def test_state_transitions_and_finish(store, valid_provenance):
    rid = _mk(store, valid_provenance)["run_id"]
    store.set_state(rid, "proofing")
    store.set_state(rid, "running")
    rec = store.get_run(rid)
    assert rec["state"] == "running"
    assert rec["timestamps"]["started"] is not None
    rec = store.finish_run(rid, "done",
                           summary={"throughput_mbps_mean": 3.14})
    assert rec["state"] == "done"
    assert rec["timestamps"]["finished"] is not None
    assert json.loads(
        (store.root / rid / "summary.json").read_text()
    )["throughput_mbps_mean"] == 3.14
    idx = store.list_runs()[0]
    assert idx["state"] == "done"
    assert idx["summary"]["throughput_mbps_mean"] == 3.14


def test_samples_roundtrip_and_csv(store, valid_provenance):
    rid = _mk(store, valid_provenance)["run_id"]
    store.append_sample(rid, "master",
                        {"t_ns": 1000, "board": "master", "dir": "m2s",
                         "throughput_mbps": 4.2, "fcsm": 4})
    store.append_sample(rid, "slave",
                        {"t_ns": 1500, "board": "slave", "dir": "m2s",
                         "throughput_mbps": 4.1, "fcsm": 4})
    samples = list(store.iter_samples(rid))
    assert len(samples) == 2
    csv_text = store.samples_csv(rid)
    lines = csv_text.strip().splitlines()
    assert lines[0] == ",".join(SAMPLE_CSV_COLUMNS)
    assert len(lines) == 3
    # sorted by t_ns: master (1000) before slave (1500)
    assert "master" in lines[1] and "slave" in lines[2]


def test_index_filters(store, valid_provenance):
    rid = _mk(store, valid_provenance)["run_id"]
    sha8 = valid_provenance["master"]["sha256"][:8]
    assert store.list_runs(test="throughput_m2s")[0]["run_id"] == rid
    assert store.list_runs(test="nope") == []
    assert store.list_runs(sha=sha8)[0]["run_id"] == rid
    assert store.list_runs(sha="ffffffff") == []
    assert store.list_runs()[0]["fifo_label"] == "fake01k"


def test_bad_run_id_rejected(store):
    with pytest.raises(KeyError):
        store.get_run("../../etc/passwd")
