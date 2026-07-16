"""Persistent run store: SQLite index + flat NDJSON/CSV per run.

Layout (default root ``~/tidelink_throughput_runs/``):

    runs.sqlite3                 index (queryable run listing)
    <run_id>/
        run.json                 full record (§4.3 of the plan)
        samples_master.ndjson    one line per measurement window
        samples_slave.ndjson
        summary.json

SQLite gives a queryable index with zero pip deps; flat files keep raw
samples greppable/scp-able and immune to schema migrations.

FAIL-CLOSED: ``create_run()`` re-validates the provenance block and
raises ``ProvenanceError`` rather than create a record without valid
bitstream sha256s.

All operations are tiny synchronous sqlite3/file ops (microseconds) —
called directly from the async app without an executor.
"""
from __future__ import annotations

import csv
import io
import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Iterator, Optional

from .provenance import validate_provenance

_SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
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

SAMPLE_CSV_COLUMNS = [
    "t_ns", "win_s", "board", "dir", "words_tx", "words_rx", "pkts",
    "throughput_mbps", "offered_mbps", "fcsm", "cal_done", "credit_obs",
    "occupancy", "fe_rx_is_full", "a2l_replay_app_valid",
    "a2l_fc_replay_link_valid", "starve_pct",
]


def _utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def new_run_id() -> str:
    return time.strftime("%Y-%m-%dT%H-%M-%SZ", time.gmtime()) \
        + "-" + uuid.uuid4().hex[:6]


class RunStore:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(
            str(self.root / "runs.sqlite3"), check_same_thread=False)
        self._db.execute(_SCHEMA)
        self._db.commit()

    # ── creation (fail-closed) ────────────────────────────────────────

    def create_run(self, *, test: str, params: dict, boards: dict,
                   provenance: dict, lease: Optional[dict] = None,
                   gate_snapshot: Optional[dict] = None,
                   run_id: Optional[str] = None) -> dict:
        """Create the run record. Raises ProvenanceError when the
        provenance block lacks valid sha256s — no record is written."""
        prov = validate_provenance(provenance)
        rid = run_id or new_run_id()
        record = {
            "run_id": rid,
            "test": test,
            "params": params,
            "sweep_point": None,          # P1: sweeps
            "boards": boards,
            "lease": lease or {},
            "provenance": prov,
            "timestamps": {"created": _utc(), "started": None,
                           "finished": None},
            "state": "created",
            "gate_snapshot": gate_snapshot or {},
            "summary": None,
            "error": None,
            "artifacts": ["samples_master.ndjson", "samples_slave.ndjson",
                          "summary.json"],
        }
        rdir = self.root / rid
        rdir.mkdir(parents=True, exist_ok=False)
        self._write_record(record)
        with self._lock:
            self._db.execute(
                "INSERT INTO runs (run_id, test, label, sha_master,"
                " sha_slave, fifo_label, state, created, params_json)"
                " VALUES (?,?,?,?,?,?,?,?,?)",
                (rid, test, prov["master"].get("label", ""),
                 prov["master"]["sha256"], prov["slave"]["sha256"],
                 prov.get("fifo_label", "unknown"), "created",
                 record["timestamps"]["created"], json.dumps(params)))
            self._db.commit()
        return record

    # ── record IO ─────────────────────────────────────────────────────

    def _run_dir(self, run_id: str) -> Path:
        d = (self.root / run_id).resolve()
        if self.root.resolve() not in d.parents:
            raise KeyError("bad run_id %r" % run_id)
        return d

    def _write_record(self, record: dict) -> None:
        path = self.root / record["run_id"] / "run.json"
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(record, indent=2) + "\n")
        tmp.replace(path)

    def get_run(self, run_id: str) -> dict:
        path = self._run_dir(run_id) / "run.json"
        if not path.is_file():
            raise KeyError("no such run %r" % run_id)
        return json.loads(path.read_text())

    def set_state(self, run_id: str, state: str,
                  *, gate_snapshot: Optional[dict] = None,
                  provenance_update: Optional[dict] = None) -> dict:
        record = self.get_run(run_id)
        record["state"] = state
        if state == "running" and not record["timestamps"]["started"]:
            record["timestamps"]["started"] = _utc()
        if gate_snapshot is not None:
            record["gate_snapshot"] = gate_snapshot
        if provenance_update:
            record["provenance"].update(provenance_update)
        self._write_record(record)
        with self._lock:
            self._db.execute("UPDATE runs SET state=? WHERE run_id=?",
                             (state, run_id))
            self._db.commit()
        return record

    def finish_run(self, run_id: str, state: str,
                   summary: Optional[dict] = None,
                   error: Optional[str] = None) -> dict:
        assert state in ("done", "failed", "aborted")
        record = self.get_run(run_id)
        record["state"] = state
        record["summary"] = summary
        record["error"] = error
        record["timestamps"]["finished"] = _utc()
        self._write_record(record)
        if summary is not None:
            (self._run_dir(run_id) / "summary.json").write_text(
                json.dumps(summary, indent=2) + "\n")
        with self._lock:
            self._db.execute(
                "UPDATE runs SET state=?, finished=?, summary_json=?,"
                " error=? WHERE run_id=?",
                (state, record["timestamps"]["finished"],
                 json.dumps(summary) if summary is not None else None,
                 error, run_id))
            self._db.commit()
        return record

    # ── samples ───────────────────────────────────────────────────────

    def samples_path(self, run_id: str, board: str) -> Path:
        if board not in ("master", "slave"):
            raise KeyError("board must be master|slave")
        return self._run_dir(run_id) / ("samples_%s.ndjson" % board)

    def append_sample(self, run_id: str, board: str, sample: dict) -> None:
        with open(self.samples_path(run_id, board), "a") as fh:
            fh.write(json.dumps(sample, separators=(",", ":")) + "\n")

    def iter_samples(self, run_id: str) -> Iterator[dict]:
        for board in ("master", "slave"):
            path = self.samples_path(run_id, board)
            if not path.is_file():
                continue
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        yield json.loads(line)

    def samples_csv(self, run_id: str) -> str:
        buf = io.StringIO()
        w = csv.DictWriter(buf, fieldnames=SAMPLE_CSV_COLUMNS,
                           extrasaction="ignore")
        w.writeheader()
        for s in sorted(self.iter_samples(run_id),
                        key=lambda s: s.get("t_ns", 0)):
            w.writerow(s)
        return buf.getvalue()

    # ── index ─────────────────────────────────────────────────────────

    def list_runs(self, *, test: Optional[str] = None,
                  label: Optional[str] = None,
                  sha: Optional[str] = None,
                  since: Optional[str] = None,
                  limit: int = 200) -> list:
        q = ("SELECT run_id, test, label, sha_master, sha_slave,"
             " fifo_label, state, created, finished, params_json,"
             " summary_json, error FROM runs WHERE 1=1")
        args: list = []
        if test:
            q += " AND test=?"; args.append(test)
        if label:
            q += " AND label LIKE ?"; args.append("%" + label + "%")
        if sha:
            q += " AND (sha_master LIKE ? OR sha_slave LIKE ?)"
            args += [sha + "%", sha + "%"]
        if since:
            q += " AND created >= ?"; args.append(since)
        q += " ORDER BY created DESC LIMIT ?"; args.append(limit)
        with self._lock:
            rows = self._db.execute(q, args).fetchall()
        out = []
        for r in rows:
            out.append({
                "run_id": r[0], "test": r[1], "label": r[2],
                "sha_master": r[3], "sha_slave": r[4], "fifo_label": r[5],
                "state": r[6], "created": r[7], "finished": r[8],
                "params": json.loads(r[9]),
                "summary": json.loads(r[10]) if r[10] else None,
                "error": r[11],
            })
        return out

    def close(self) -> None:
        with self._lock:
            self._db.close()
