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

SCHEMA EVOLUTION: ``_SCHEMA`` is the original (v1) table. Every column
added since lives in ``_NEW_COLUMNS`` and is applied by ``_migrate()``
(``PRAGMA table_info`` -> ``ALTER TABLE ADD COLUMN`` only when missing),
which runs on EVERY open — fresh databases and databases written by the
pre-comparison build take the identical code path, so the migration is
exercised continuously rather than only on the one upgrade nobody
tests. Rows that predate the new columns are backfilled from their
on-disk ``run.json`` by ``_backfill()``.
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

# Columns added after v1. ALTER TABLE ADD COLUMN can never carry a NOT
# NULL constraint without a default, so these are all nullable and the
# backfill normalises NULL -> "" ("known-unknown", never retried).
_NEW_COLUMNS = (
    ("artefact_version", "TEXT"),
    ("source_commit", "TEXT"),
    ("rtl_tag", "TEXT"),
    ("params_key", "TEXT"),
)

_INDEXES = (
    ("idx_runs_test", "test"),
    ("idx_runs_version", "artefact_version"),
    ("idx_runs_params_key", "params_key"),
    ("idx_runs_rtl_tag", "rtl_tag"),
)

SAMPLE_CSV_COLUMNS = [
    "t_ns", "win_s", "board", "dir", "words_tx", "words_rx", "pkts",
    "throughput_mbps", "offered_mbps", "fcsm", "cal_done", "credit_obs",
    "occupancy", "fe_rx_is_full", "a2l_replay_app_valid",
    "a2l_fc_replay_link_valid", "starve_pct",
]

# ── comparison fingerprint ───────────────────────────────────────────
#
# params_key answers exactly one question: "are these two runs even
# comparable?". It therefore covers ONLY the params that change the
# measured rate. duration_s and win_s change how long we look and how
# finely we slice, not how fast the link goes — including them would
# split otherwise-comparable runs into singleton groups and make every
# comparison look confounded.
#
# This project has already lost a week to a rate ladder whose points
# did not share their parameters, so the fingerprint is deliberately a
# single shared definition rather than something each caller rolls.
PARAMS_KEY_FIELDS = ("burst_words", "rate_pps", "rel_threshold")
PARAMS_KEY_EXCLUDED = ("duration_s", "win_s")

_PARAMS_KEY_TYPES = {
    "burst_words": "int",
    "rate_pps": "float",
    "rel_threshold": "int",
}


def _canon(key: str, value) -> str:
    """Canonical text for one fingerprint field, so 16 / "16" / 16.0
    all fingerprint identically."""
    kind = _PARAMS_KEY_TYPES.get(key)
    try:
        if kind == "int":
            return repr(int(round(float(value))))
        if kind == "float":
            return repr(float(value))
    except (TypeError, ValueError):
        pass
    return str(value)


def params_key(params: Optional[dict]) -> str:
    """Stable comparison fingerprint: sorted ``k=v`` pairs joined by
    ``;`` over PARAMS_KEY_FIELDS only.

    >>> params_key({"rate_pps": 0, "burst_words": 16, "duration_s": 10.0})
    'burst_words=16;rate_pps=0.0'
    """
    if not isinstance(params, dict):
        return ""
    parts = []
    for key in sorted(PARAMS_KEY_FIELDS):
        if key in params and params[key] is not None:
            parts.append("%s=%s" % (key, _canon(key, params[key])))
    return ";".join(parts)


def parse_params_key(key: Optional[str]) -> dict:
    """Inverse of :func:`params_key` (text values) — lets callers say
    *which* parameter differs, not merely that something did."""
    out: dict = {}
    for chunk in (key or "").split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        name, _, val = chunk.partition("=")
        out[name.strip()] = val.strip()
    return out


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
        self.migrated_columns = self._migrate()
        self._backfill()

    # ── schema migration (idempotent, runs on every open) ─────────────

    def _columns(self) -> set:
        return {row[1]
                for row in self._db.execute("PRAGMA table_info(runs)")}

    def _migrate(self) -> list:
        """Add any missing post-v1 column. Safe to run repeatedly and
        safe against a second process racing us to the same ALTER."""
        have = self._columns()
        added = []
        for name, decl in _NEW_COLUMNS:
            if name in have:
                continue
            try:
                self._db.execute(
                    "ALTER TABLE runs ADD COLUMN %s %s" % (name, decl))
            except sqlite3.OperationalError as exc:
                if "duplicate column" not in str(exc).lower():
                    raise
                continue
            added.append(name)
        for idx, col in _INDEXES:
            self._db.execute(
                "CREATE INDEX IF NOT EXISTS %s ON runs(%s)" % (idx, col))
        self._db.commit()
        return added

    def _backfill(self) -> int:
        """Populate the post-v1 columns for rows written before they
        existed, from each run's on-disk ``run.json``.

        Best-effort by construction: a run whose directory has been
        deleted still keeps its index row, it just fingerprints from
        params_json (which lives in the DB) and records "" for the
        provenance fields. Writing "" rather than leaving NULL is what
        makes this terminate — the row is never rescanned."""
        rows = self._db.execute(
            "SELECT run_id, params_json FROM runs WHERE"
            " artefact_version IS NULL OR source_commit IS NULL"
            " OR rtl_tag IS NULL OR params_key IS NULL").fetchall()
        for rid, params_json in rows:
            version = commit = tag = pkey = ""
            try:
                rec = json.loads(
                    (self.root / rid / "run.json").read_text())
            except (OSError, ValueError):
                rec = None
            if isinstance(rec, dict):
                prov = rec.get("provenance") or {}
                version = str(prov.get("artefact_version") or "")
                commit = str((prov.get("master") or {}).get("source_commit")
                             or (prov.get("slave") or {}).get("source_commit")
                             or "")
                tag = str(rec.get("rtl_tag") or "")
                pkey = params_key(rec.get("params"))
            if not pkey and params_json:
                try:
                    pkey = params_key(json.loads(params_json))
                except ValueError:
                    pkey = ""
            self._db.execute(
                "UPDATE runs SET"
                " artefact_version=COALESCE(artefact_version,?),"
                " source_commit=COALESCE(source_commit,?),"
                " rtl_tag=COALESCE(rtl_tag,?),"
                " params_key=COALESCE(params_key,?)"
                " WHERE run_id=?", (version, commit, tag, pkey, rid))
        if rows:
            self._db.commit()
        return len(rows)

    # ── creation (fail-closed) ────────────────────────────────────────

    def create_run(self, *, test: str, params: dict, boards: dict,
                   provenance: dict, lease: Optional[dict] = None,
                   gate_snapshot: Optional[dict] = None,
                   run_id: Optional[str] = None,
                   rtl_tag: Optional[str] = None) -> dict:
        """Create the run record. Raises ProvenanceError when the
        provenance block lacks valid sha256s — no record is written.

        ``rtl_tag`` is free text (typically a git tag such as
        ``v39-credit-fix``) recorded and indexed alongside the artefact
        version so comparisons can be addressed by either."""
        prov = validate_provenance(provenance)
        rid = run_id or new_run_id()
        pkey = params_key(params)
        version = str(prov.get("artefact_version") or "")
        commit = str(prov["master"].get("source_commit")
                     or prov["slave"].get("source_commit") or "")
        record = {
            "run_id": rid,
            "test": test,
            "params": params,
            "params_key": pkey,
            "rtl_tag": rtl_tag or "",
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
                " sha_slave, fifo_label, state, created, params_json,"
                " artefact_version, source_commit, rtl_tag, params_key)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (rid, test, prov["master"].get("label", ""),
                 prov["master"]["sha256"], prov["slave"]["sha256"],
                 prov.get("fifo_label", "unknown"), "created",
                 record["timestamps"]["created"], json.dumps(params),
                 version, commit, rtl_tag or "", pkey))
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
                  version: Optional[str] = None,
                  params_key: Optional[str] = None,
                  rtl_tag: Optional[str] = None,
                  state: Optional[str] = None,
                  limit: int = 200) -> list:
        """Index listing, newest first.

        ``version`` matches ``artefact_version`` exactly (it is an
        identity, not a search); ``params_key`` likewise — a fuzzy match
        on a comparison fingerprint would defeat its purpose."""
        q = ("SELECT run_id, test, label, sha_master, sha_slave,"
             " fifo_label, state, created, finished, params_json,"
             " summary_json, error, artefact_version, source_commit,"
             " rtl_tag, params_key FROM runs WHERE 1=1")
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
        if version:
            q += " AND artefact_version=?"; args.append(version)
        if params_key:
            q += " AND params_key=?"; args.append(params_key)
        if rtl_tag:
            q += " AND rtl_tag=?"; args.append(rtl_tag)
        if state:
            q += " AND state=?"; args.append(state)
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
                "artefact_version": r[12] or "",
                "source_commit": r[13] or "",
                "rtl_tag": r[14] or "",
                "params_key": r[15] or "",
            })
        return out

    def close(self) -> None:
        with self._lock:
            self._db.close()
