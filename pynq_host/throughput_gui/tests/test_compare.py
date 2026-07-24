"""Cross-version comparison: schema migration, params_key fingerprint,
the comparison maths, and — the point of the feature — every warning
that stops a confounded comparison being read as a result.

Offline: no hardware, no network, no agents. Runs are synthesised
straight into a real RunStore so the production store/migration code is
what is under test.
"""
from __future__ import annotations

import itertools
import json
import sqlite3

import httpx
import pytest
from fastapi import FastAPI

from pynq_host.throughput_gui import compare
from pynq_host.throughput_gui.store import (
    RunStore, params_key, parse_params_key,
)

# The v1 table exactly as it shipped, for the migration test.
OLD_SCHEMA = """
CREATE TABLE runs (
    run_id      TEXT PRIMARY KEY,
    test        TEXT NOT NULL,
    label       TEXT NOT NULL,
    sha_master  TEXT NOT NULL,
    sha_slave   TEXT NOT NULL,
    fifo_label  TEXT NOT NULL,
    state       TEXT NOT NULL,
    created     TEXT NOT NULL,
    finished    TEXT,
    params_json TEXT NOT NULL,
    summary_json TEXT,
    error       TEXT
);
"""
OLD_COLUMNS = ("run_id", "test", "label", "sha_master", "sha_slave",
               "fifo_label", "state", "created", "finished", "params_json",
               "summary_json", "error")

SHA_A = "a" * 64
SHA_B = "b" * 64
BOARDS = {"master": "192.168.4.101", "slave": "192.168.6.101",
          "pair": "bridge1"}
BASE_PARAMS = {"burst_words": 16, "rate_pps": 0.0, "duration_s": 10.0,
               "win_s": 0.5}

_seq = itertools.count(1)


def _prov(version, *, commit="abc1234", fifo="01k"):
    label = "%s-synthetic-fifo%s" % (version, fifo)
    return {
        "artefact_version": version,
        "master": {"sha256": SHA_A, "label": label,
                   "source_commit": commit},
        "slave": {"sha256": SHA_B, "label": label,
                  "source_commit": commit},
        "fifo_label": fifo,
    }


def _add(store, version, values, *, params=None, fifo="01k",
         commit="abc1234", errors=0, state="done", created=None,
         test="throughput_m2s", rtl_tag=None, metric_key=None):
    """Create + finish ``len(values)`` runs of ``version`` whose summary
    metric takes each value. Returns the run_ids."""
    ids = []
    for val in values:
        rid = "run-%04d-%s" % (next(_seq), version)
        store.create_run(test=test, params=dict(params or BASE_PARAMS),
                         boards=BOARDS,
                         provenance=_prov(version, commit=commit, fifo=fifo),
                         run_id=rid, rtl_tag=rtl_tag)
        summary = {
            "throughput_mbps_mean": val,
            "throughput_mbps_p5": val * 0.9,
            "throughput_mbps_p95": val * 1.1,
            "packets": 100, "errors": errors,
            "rx_throughput_mbps_mean": val,
            "rx_drained_words": 1000,
        }
        if metric_key:
            summary[metric_key] = val
        store.finish_run(rid, state, summary=summary)
        if created:
            # The index stamps `created` at 1 s resolution, so every run
            # made by one test shares a second. Backdate explicitly when
            # a test needs a real chronological order (baseline picking).
            store._db.execute("UPDATE runs SET created=? WHERE run_id=?",
                              (created, rid))
            store._db.commit()
        ids.append(rid)
    return ids


@pytest.fixture
def cstore(tmp_path):
    return RunStore(tmp_path / "cmp_runs")


# ── 1. migration ─────────────────────────────────────────────────────

def _legacy_db(root, *, with_record=True):
    root.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(root / "runs.sqlite3"))
    db.execute(OLD_SCHEMA)
    db.execute(
        "INSERT INTO runs (%s) VALUES (%s)"
        % (", ".join(OLD_COLUMNS), ",".join("?" * len(OLD_COLUMNS))),
        ("legacy-1", "throughput_m2s", "v38-old-fifo01k", SHA_A, SHA_B,
         "01k", "done", "2026-06-01T10:00:00Z", "2026-06-01T10:01:00Z",
         json.dumps({"burst_words": 16, "rate_pps": 0.0,
                     "duration_s": 10.0, "win_s": 0.5}),
         json.dumps({"throughput_mbps_mean": 4.0, "errors": 0}), None))
    db.commit()
    db.close()
    if with_record:
        rdir = root / "legacy-1"
        rdir.mkdir()
        (rdir / "run.json").write_text(json.dumps({
            "run_id": "legacy-1", "test": "throughput_m2s",
            "params": {"burst_words": 16, "rate_pps": 0.0,
                       "duration_s": 10.0, "win_s": 0.5},
            "rtl_tag": "v38.0-freeze",
            "provenance": _prov("v38", commit="deadbee"),
            "state": "done",
        }))


def test_migration_adds_columns_and_backfills(tmp_path):
    """A pre-comparison DB must open, keep its row, and gain the new
    columns backfilled from run.json."""
    root = tmp_path / "legacy"
    _legacy_db(root)

    store = RunStore(root)
    assert sorted(store.migrated_columns) == [
        "artefact_version", "params_key", "rtl_tag", "source_commit"]
    cols = {r[1] for r in store._db.execute("PRAGMA table_info(runs)")}
    assert {"artefact_version", "source_commit", "rtl_tag",
            "params_key"} <= cols

    rows = store.list_runs()
    assert len(rows) == 1, "the pre-existing row must survive"
    row = rows[0]
    assert row["run_id"] == "legacy-1"
    assert row["summary"]["throughput_mbps_mean"] == 4.0
    assert row["created"] == "2026-06-01T10:00:00Z"
    # backfilled from run.json
    assert row["artefact_version"] == "v38"
    assert row["source_commit"] == "deadbee"
    assert row["rtl_tag"] == "v38.0-freeze"
    assert row["params_key"] == "burst_words=16;rate_pps=0.0"
    # and the new filters can now find it
    assert store.list_runs(version="v38")[0]["run_id"] == "legacy-1"
    assert store.list_runs(version="v39") == []
    assert store.list_runs(
        params_key="burst_words=16;rate_pps=0.0")[0]["run_id"] == "legacy-1"
    store.close()


def test_migration_is_idempotent(tmp_path):
    root = tmp_path / "legacy2"
    _legacy_db(root)
    first = RunStore(root)
    assert first.migrated_columns          # did work the first time
    first.close()
    for _ in range(3):
        again = RunStore(root)
        assert again.migrated_columns == []      # nothing left to add
        rows = again.list_runs()
        assert len(rows) == 1
        assert rows[0]["artefact_version"] == "v38"
        assert rows[0]["rtl_tag"] == "v38.0-freeze"
        again.close()


def test_migration_without_run_json_still_fingerprints(tmp_path):
    """run.json gone (dir pruned): the row keeps working, params_key is
    recovered from the indexed params, provenance fields go empty."""
    root = tmp_path / "legacy3"
    _legacy_db(root, with_record=False)
    store = RunStore(root)
    row = store.list_runs()[0]
    assert row["params_key"] == "burst_words=16;rate_pps=0.0"
    assert row["artefact_version"] == ""
    assert row["source_commit"] == ""
    store.close()
    # and it is not rescanned forever: values stay put on reopen
    assert RunStore(root).list_runs()[0]["params_key"] \
        == "burst_words=16;rate_pps=0.0"


# ── 2. params_key ────────────────────────────────────────────────────

def test_params_key_is_order_independent():
    a = params_key({"burst_words": 16, "rate_pps": 0.0,
                    "rel_threshold": 0})
    b = params_key({"rel_threshold": 0, "rate_pps": 0.0,
                    "burst_words": 16})
    assert a == b == "burst_words=16;rate_pps=0.0;rel_threshold=0"


def test_params_key_excludes_duration_and_window():
    short = params_key({"burst_words": 16, "rate_pps": 0.0,
                        "duration_s": 2.0, "win_s": 0.2})
    long = params_key({"burst_words": 16, "rate_pps": 0.0,
                       "duration_s": 600.0, "win_s": 10.0})
    assert short == long == "burst_words=16;rate_pps=0.0"


def test_params_key_canonicalises_types():
    """16, "16" and 16.0 are the same experiment."""
    keys = {params_key({"burst_words": v, "rate_pps": 0})
            for v in (16, "16", 16.0)}
    assert keys == {"burst_words=16;rate_pps=0.0"}
    assert params_key({"burst_words": 16, "rate_pps": 0}) \
        == params_key({"burst_words": 16, "rate_pps": 0.0})


def test_params_key_distinguishes_what_matters():
    base = params_key({"burst_words": 16, "rate_pps": 0.0})
    assert params_key({"burst_words": 32, "rate_pps": 0.0}) != base
    assert params_key({"burst_words": 16, "rate_pps": 100.0}) != base
    # rel_threshold present vs absent is NOT the same knowledge
    assert params_key({"burst_words": 16, "rate_pps": 0.0,
                       "rel_threshold": 0}) != base
    assert params_key({}) == ""
    assert params_key(None) == ""


def test_parse_params_key_roundtrip():
    key = params_key({"burst_words": 16, "rate_pps": 0.0,
                      "rel_threshold": 20})
    assert parse_params_key(key) == {"burst_words": "16",
                                     "rate_pps": "0.0",
                                     "rel_threshold": "20"}
    assert parse_params_key("") == {}
    assert parse_params_key(None) == {}


def test_create_run_records_version_tag_and_key(cstore):
    rec = cstore.create_run(
        test="throughput_m2s", params=dict(BASE_PARAMS), boards=BOARDS,
        provenance=_prov("v39", commit="feedface"), rtl_tag="v39-credit-fix")
    assert rec["rtl_tag"] == "v39-credit-fix"
    assert rec["params_key"] == "burst_words=16;rate_pps=0.0"
    row = cstore.list_runs(version="v39")[0]
    assert row["run_id"] == rec["run_id"]
    assert row["source_commit"] == "feedface"
    assert row["rtl_tag"] == "v39-credit-fix"
    assert cstore.list_runs(rtl_tag="v39-credit-fix")[0]["run_id"] \
        == rec["run_id"]
    assert cstore.list_runs(state="created")[0]["run_id"] == rec["run_id"]
    assert cstore.list_runs(state="done") == []


# ── 3. comparison maths ──────────────────────────────────────────────

def test_compare_maths_and_baseline(cstore):
    _add(cstore, "v38", [4.0, 4.2, 3.8], created="2026-06-01T10:00:00Z")
    _add(cstore, "v39", [5.0, 5.2, 4.8], commit="feedface",
         created="2026-07-01T10:00:00Z")

    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    assert out["test"] == "throughput_m2s"
    assert out["metric"] == "throughput_mbps_mean"
    assert out["params_key"] == "burst_words=16;rate_pps=0.0"
    assert out["included_states"] == ["done"]
    assert out["baseline"] == "v38"              # oldest in the selection
    assert [g["version"] for g in out["groups"]] == ["v38", "v39"]

    base, cand = out["groups"]
    assert base["n"] == 3 and cand["n"] == 3
    assert base["mean"] == 4.0 and cand["mean"] == 5.0
    assert base["median"] == 4.0
    assert base["p5"] == pytest.approx(3.82)
    assert base["p95"] == pytest.approx(4.18)
    assert base["stdev"] == pytest.approx(0.163299, abs=1e-5)
    assert base["delta_vs_baseline_pct"] is None
    assert cand["delta_vs_baseline_pct"] == pytest.approx(25.0)
    assert cand["source_commit"] == "feedface"
    assert len(cand["runs"]) == 3
    assert all(r.startswith("run-") for r in cand["runs"])


def test_baseline_is_oldest_not_alphabetical(cstore):
    """Version names carry no ordering — the baseline is chronological."""
    _add(cstore, "zulu", [4.0, 4.1, 3.9], created="2026-01-01T00:00:00Z")
    _add(cstore, "alpha", [5.0, 5.1, 4.9], created="2026-05-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    assert out["baseline"] == "zulu"
    assert [g["version"] for g in out["groups"]] == ["zulu", "alpha"]
    assert out["groups"][1]["delta_vs_baseline_pct"] == pytest.approx(25.0)


def test_explicit_baseline_and_version_selection(cstore):
    _add(cstore, "v37", [2.0, 2.1, 1.9], created="2026-05-01T00:00:00Z")
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1, 4.9], created="2026-07-01T00:00:00Z")

    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=["v38", "v39"], params_key=None)
    assert [g["version"] for g in out["groups"]] == ["v38", "v39"]
    assert out["baseline"] == "v38"

    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=["v37", "v38", "v39"],
                                   params_key=None, baseline="v39")
    assert out["baseline"] == "v39"
    by = {g["version"]: g for g in out["groups"]}
    assert by["v39"]["delta_vs_baseline_pct"] is None
    assert by["v37"]["delta_vs_baseline_pct"] == pytest.approx(-60.0)

    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=["v38", "v99"], params_key=None,
                                   baseline="v42")
    assert [g["version"] for g in out["groups"]] == ["v38"]
    assert any("v99" in w and "no done runs" in w for w in out["warnings"])
    assert any("baseline v42" in w for w in out["warnings"])


def test_only_done_runs_are_included(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1, 4.9], created="2026-07-01T00:00:00Z")
    # a failed run with an absurd number that would wreck the mean
    _add(cstore, "v39", [900.0], state="failed",
         created="2026-07-01T00:00:00Z")
    _add(cstore, "v39", [900.0], state="aborted",
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    by = {g["version"]: g for g in out["groups"]}
    assert by["v39"]["n"] == 3
    assert by["v39"]["mean"] == pytest.approx(5.0)
    assert out["included_states"] == ["done"]


def test_other_tests_and_params_key_filter_do_not_leak(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v38", [99.0], test="throughput_s2m",
         created="2026-06-01T00:00:00Z")
    fast = dict(BASE_PARAMS, burst_words=64)
    _add(cstore, "v38", [50.0, 51.0, 49.0], params=fast,
         created="2026-06-01T00:00:00Z")

    out = compare.compare_versions(
        cstore, test="throughput_m2s", versions=None,
        params_key="burst_words=64;rate_pps=0.0")
    assert out["groups"][0]["n"] == 3
    assert out["groups"][0]["mean"] == pytest.approx(50.0)
    assert out["params_key"] == "burst_words=64;rate_pps=0.0"

    empty = compare.compare_versions(cstore, test="throughput_m2s",
                                     versions=None,
                                     params_key="burst_words=999")
    assert empty["groups"] == []
    assert empty["baseline"] is None
    assert any("nothing to compare" in w for w in empty["warnings"])


def test_unknown_metric_rejected(cstore):
    with pytest.raises(ValueError):
        compare.compare_versions(cstore, test="throughput_m2s",
                                 versions=None, params_key=None,
                                 metric="master")


def test_alternate_metric(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [8.0, 8.1, 7.9], created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None,
                                   metric="rx_throughput_mbps_mean")
    assert out["metric"] == "rx_throughput_mbps_mean"
    assert out["groups"][1]["mean"] == pytest.approx(8.0)


# ── 4. warnings — the load-bearing part ──────────────────────────────

def test_clean_comparison_emits_no_warnings(cstore):
    _add(cstore, "v38", [4.0, 4.2, 3.8], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.2, 4.8], commit="feedface",
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    assert out["warnings"] == []
    assert out["groups"][1]["delta_exceeds_spread"] is True


def test_warn_when_a_group_mixes_params_key(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1], created="2026-07-01T00:00:00Z")
    _add(cstore, "v39", [9.0], params=dict(BASE_PARAMS, burst_words=64),
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    mixed = [w for w in out["warnings"]
             if w.startswith("version v39: runs mix params_key")]
    assert mixed, out["warnings"]
    assert "burst_words" in mixed[0]
    assert "CONFOUNDED" in mixed[0]
    by = {g["version"]: g for g in out["groups"]}
    assert by["v39"]["params_key"] is None       # no single fingerprint
    assert len(by["v39"]["params_keys"]) == 2


def test_warn_when_groups_do_not_share_params_key(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [9.0, 9.1, 8.9],
         params=dict(BASE_PARAMS, burst_words=64),
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    cross = [w for w in out["warnings"]
             if "do not share one params_key" in w]
    assert cross, out["warnings"]
    assert "burst_words" in cross[0] and "CONFOUNDED" in cross[0]
    assert out["params_key"] is None
    # each group on its own is internally consistent -> no within warning
    assert not [w for w in out["warnings"] if "runs mix params_key" in w]


def test_warn_when_n_below_three(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1], created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    small = [w for w in out["warnings"] if "n=2" in w]
    assert small, out["warnings"]
    assert "not enough samples to claim an improvement" in small[0]
    assert "version v39" in small[0]
    assert not [w for w in out["warnings"] if "version v38 has only" in w]


def test_warn_when_fifo_label_differs(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], fifo="01k",
         created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1, 4.9], fifo="04k",
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    fifo = [w for w in out["warnings"] if "fifo_label" in w]
    assert fifo, out["warnings"]
    assert "01k" in fifo[0] and "04k" in fifo[0]
    assert "CONFOUNDED" in fifo[0]


def test_warn_when_a_group_mixes_fifo_label(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1], fifo="01k",
         created="2026-07-01T00:00:00Z")
    _add(cstore, "v39", [5.2], fifo="04k", created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    assert any(w.startswith("version v39: runs mix fifo_label")
               for w in out["warnings"]), out["warnings"]


def test_warn_when_runs_recorded_errors(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1], created="2026-07-01T00:00:00Z")
    _add(cstore, "v39", [5.2], errors=7, created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    errs = [w for w in out["warnings"] if "nonzero errors" in w]
    assert errs, out["warnings"]
    assert "version v39" in errs[0] and "1 of 3" in errs[0]
    assert "total 7" in errs[0]
    by = {g["version"]: g for g in out["groups"]}
    assert by["v39"]["errors"] == 7 and by["v39"]["error_runs"] == 1
    assert by["v38"]["errors"] == 0


def test_warn_when_rel_threshold_is_inherited(cstore):
    """rel_threshold=-1 means "whatever the image had" — two versions can
    share a params_key and still have run at different thresholds."""
    inherit = dict(BASE_PARAMS, rel_threshold=-1)
    _add(cstore, "v38", [4.0, 4.1, 3.9], params=inherit,
         created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [8.0, 8.1, 7.9], params=inherit,
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    assert out["params_key"] == "burst_words=16;rate_pps=0.0;rel_threshold=-1"
    warn = [w for w in out["warnings"] if "rel_threshold=-1" in w]
    assert warn, out["warnings"]
    assert "v38" in warn[0] and "v39" in warn[0]

    # pinning it silences the warning
    pinned = dict(BASE_PARAMS, rel_threshold=0)
    other = RunStore(cstore.root.parent / "pinned")
    _add(other, "v38", [4.0, 4.1, 3.9], params=pinned,
         created="2026-06-01T00:00:00Z")
    _add(other, "v39", [8.0, 8.1, 7.9], params=pinned,
         created="2026-07-01T00:00:00Z")
    assert compare.compare_versions(other, test="throughput_m2s",
                                    versions=None,
                                    params_key=None)["warnings"] == []


def test_warn_when_version_spans_two_commits(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1], commit="aaa1111",
         created="2026-07-01T00:00:00Z")
    _add(cstore, "v39", [5.2], commit="bbb2222",
         created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    assert any("spans 2 source_commits" in w for w in out["warnings"]), \
        out["warnings"]


def test_warn_when_metric_missing_from_summary(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    ids = _add(cstore, "v39", [5.0, 5.1, 4.9],
               created="2026-07-01T00:00:00Z")
    cstore.finish_run(ids[0], "done", summary={"errors": 0})   # no metric
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    by = {g["version"]: g for g in out["groups"]}
    assert by["v39"]["n"] == 2 and by["v39"]["runs_total"] == 3
    assert any("have no throughput_mbps_mean" in w for w in out["warnings"])


# ── 5. delta vs spread ───────────────────────────────────────────────

def test_small_delta_inside_wide_bands_is_not_a_result(cstore):
    _add(cstore, "v38", [3.0, 4.0, 5.0], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [3.06, 4.08, 5.10], created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    cand = out["groups"][1]
    assert cand["delta_vs_baseline_pct"] == pytest.approx(2.0)
    assert cand["delta_exceeds_spread"] is False
    assert any("not distinguishable from noise" in w
               for w in out["warnings"]), out["warnings"]


def test_large_delta_outside_bands_is_a_result(cstore):
    _add(cstore, "v38", [3.0, 4.0, 5.0], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [8.0, 9.0, 10.0], created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    cand = out["groups"][1]
    assert cand["delta_vs_baseline_pct"] == pytest.approx(125.0)
    assert cand["delta_exceeds_spread"] is True
    assert not [w for w in out["warnings"] if "noise" in w]


def test_unknown_spread_never_reads_as_improved(cstore):
    """n=1: the spread is unknown, so the delta is NOT cleared."""
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [40.0], created="2026-07-01T00:00:00Z")
    out = compare.compare_versions(cstore, test="throughput_m2s",
                                   versions=None, params_key=None)
    cand = out["groups"][1]
    assert cand["delta_vs_baseline_pct"] > 800
    assert cand["delta_exceeds_spread"] is False
    assert any("spread unknown, NOT cleared" in w for w in out["warnings"])


def test_percentile_helper():
    assert compare.percentile([], 50) is None
    assert compare.percentile([7.0], 5) == 7.0
    assert compare.percentile([1.0, 2.0, 3.0], 50) == 2.0
    assert compare.percentile([1.0, 2.0, 3.0], 0) == 1.0
    assert compare.percentile([1.0, 2.0, 3.0], 100) == 3.0


# ── 6. HTTP surface ──────────────────────────────────────────────────

class _StubState:
    """Stand-in for AppState — the router only reaches .store."""

    def __init__(self, store):
        self.store = store


def _api(store):
    app = FastAPI()
    app.include_router(compare.build_router(lambda: _StubState(store)))
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                             base_url="http://test")


async def test_api_versions_shape(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], rtl_tag="v38.0",
         created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.1, 4.9], commit="feedface",
         rtl_tag="v39-credit-fix", created="2026-07-01T00:00:00Z")
    async with _api(cstore) as c:
        r = await c.get("/api/versions")
        assert r.status_code == 200
        body = r.json()
        assert [v["artefact_version"] for v in body] == ["v39", "v38"]
        for v in body:
            assert set(v) >= {"artefact_version", "source_commit",
                              "rtl_tag", "runs", "first", "last"}
        assert body[0]["runs"] == 3
        assert body[0]["source_commit"] == "feedface"
        assert body[0]["rtl_tag"] == "v39-credit-fix"
        assert body[0]["first"] == "2026-07-01T00:00:00Z"


async def test_api_compare_shape(cstore):
    _add(cstore, "v38", [4.0, 4.2, 3.8], created="2026-06-01T00:00:00Z")
    _add(cstore, "v39", [5.0, 5.2, 4.8], created="2026-07-01T00:00:00Z")
    async with _api(cstore) as c:
        r = await c.get("/api/compare",
                        params={"test": "throughput_m2s",
                                "versions": "v38,v39"})
        assert r.status_code == 200
        body = r.json()
        assert set(body) >= {"test", "metric", "params_key", "baseline",
                             "groups", "warnings", "included_states"}
        assert body["baseline"] == "v38"
        assert body["included_states"] == ["done"]
        assert body["warnings"] == []
        assert [g["version"] for g in body["groups"]] == ["v38", "v39"]
        for g in body["groups"]:
            assert set(g) >= {"version", "rtl_tag", "source_commit", "n",
                              "mean", "median", "p5", "p95", "stdev",
                              "runs", "delta_vs_baseline_pct",
                              "delta_exceeds_spread"}
        assert body["groups"][1]["delta_vs_baseline_pct"] == 25.0


async def test_api_compare_defaults_and_errors(cstore):
    _add(cstore, "v38", [4.0, 4.1, 3.9], created="2026-06-01T00:00:00Z")
    async with _api(cstore) as c:
        # no query args at all -> default test, still a valid envelope
        body = (await c.get("/api/compare")).json()
        assert body["test"] == "throughput_m2s"
        assert body["baseline"] == "v38"

        r = await c.get("/api/compare", params={"metric": "nope"})
        assert r.status_code == 400
        assert "unknown metric" in r.json()["detail"]

        body = (await c.get("/api/compare",
                            params={"test": "not_a_test"})).json()
        assert body["groups"] == [] and body["baseline"] is None
        assert any("nothing to compare" in w for w in body["warnings"])
