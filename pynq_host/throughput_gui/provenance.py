"""Bitstream provenance gate — MANDATORY and FAIL-CLOSED.

At run start the orchestrator must produce a provenance block from the
staged manifests written by ``pynq_host/scripts/make_bitstream_manifest.sh``
(staged as ``~/tidelink_artefacts/<ver>/tidelink.bin.manifest.json`` +
``tidelink-flip.bin.manifest.json`` on mapstone-dev — see
docs/BOARD_DEPLOY_RUNBOOK.md). If any manifest is missing or its sha256
is malformed, ``ProvenanceError`` is raised and NO run record may be
created — a mismatched/unmanifested bitstream can never pollute the
SRAM-sweep family graphs.

Manifest schema (make_bitstream_manifest.sh):
  sha256, source_commit, build_host, build_date, target,
  expected_lock_min, label

``fifo_label`` is parsed from the label by convention
``vNN-<desc>[-fifoLABEL]`` — never from a free-text GUI field.

P0 note: the on-board ``verify_deployed.sh`` + PHYID runtime
cross-checks are represented by the injectable ``board_verifier``
callable in app.py (real mode shells out; --fake mode returns True).
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Optional

MASTER_MANIFEST = "tidelink.bin.manifest.json"
SLAVE_MANIFEST = "tidelink-flip.bin.manifest.json"

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_FIFO_RE = re.compile(r"-fifo([A-Za-z0-9_]+)$")


class ProvenanceError(RuntimeError):
    """Raised when the provenance gate fails — the run must NOT start."""


def parse_fifo_label(label: str) -> Optional[str]:
    """``vNN-<desc>-fifoLABEL`` -> ``LABEL`` (None when absent)."""
    m = _FIFO_RE.search(label or "")
    return m.group(1) if m else None


def _load_manifest(path: Path) -> dict:
    if not path.is_file():
        raise ProvenanceError(
            "manifest missing: %s — provenance gate is fail-closed; "
            "stage the bitstream with make_bitstream_manifest.sh" % path)
    try:
        man = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        raise ProvenanceError("manifest unreadable: %s: %s" % (path, exc))
    sha = str(man.get("sha256", ""))
    if not _SHA256_RE.match(sha):
        raise ProvenanceError(
            "manifest %s has no valid sha256 (got %r) — refusing to run"
            % (path, sha))
    return man


def load_provenance(artefact_root: Path, version: str) -> dict:
    """Build the run-record provenance block (§4.3 of the plan) from the
    staged manifests for ``<artefact_root>/<version>/``. Fail-closed."""
    vdir = Path(artefact_root) / version
    if not vdir.is_dir():
        raise ProvenanceError(
            "artefact version dir missing: %s — nothing staged" % vdir)
    master = _load_manifest(vdir / MASTER_MANIFEST)
    slave = _load_manifest(vdir / SLAVE_MANIFEST)
    fifo = parse_fifo_label(master.get("label", "")) or "unknown"
    return {
        "artefact_version": version,
        "master": {
            "sha256": master["sha256"],
            "label": master.get("label", ""),
            "source_commit": master.get("source_commit", "-"),
            "target": master.get("target", ""),
            "build_date": master.get("build_date", ""),
            "expected_lock_min": master.get("expected_lock_min", 0),
        },
        "slave": {
            "sha256": slave["sha256"],
            "label": slave.get("label", ""),
            "source_commit": slave.get("source_commit", "-"),
            "target": slave.get("target", ""),
            "build_date": slave.get("build_date", ""),
            "expected_lock_min": slave.get("expected_lock_min", 0),
        },
        "fifo_label": fifo,
        # Filled in by the orchestrator's board_verifier (verify_deployed
        # + PHYID cross-check on real HW; True in --fake mode).
        "verified_on_board": False,
        "phy_id_master": None,
        "phy_id_slave": None,
    }


def validate_provenance(prov: Optional[dict]) -> dict:
    """Second, independent fail-closed check at the run-store boundary —
    the store refuses to create a run record without valid sha256s even
    if a caller bypassed load_provenance()."""
    if not isinstance(prov, dict):
        raise ProvenanceError("no provenance block — refusing to record run")
    for side in ("master", "slave"):
        sha = str(((prov.get(side) or {}).get("sha256")) or "")
        if not _SHA256_RE.match(sha):
            raise ProvenanceError(
                "provenance %s.sha256 invalid (%r) — refusing to record run"
                % (side, sha))
    return prov


# ── DEV MODE: synthesize a manifested artefact dir for --fake runs ───────

def make_fake_artefacts(artefact_root: Path,
                        version: str = "v0-fake",
                        fifo_label: str = "fake01k") -> Path:
    """Write a pair of fake .bin files + REAL (schema-true) manifests so
    the --fake stack exercises the genuine provenance code path. The
    sha256s are honestly computed over the fake bins."""
    vdir = Path(artefact_root) / version
    vdir.mkdir(parents=True, exist_ok=True)
    for binname, manname, target in (
            ("tidelink.bin", MASTER_MANIFEST, "pynq-z2-pair-all"),
            ("tidelink-flip.bin", SLAVE_MANIFEST, "pynq-z2-pair-flip-all")):
        binpath = vdir / binname
        if not binpath.exists():
            binpath.write_bytes(
                b"TIDELINK-FAKE-BITSTREAM %s %s\n"
                % (version.encode(), binname.encode()))
        sha = hashlib.sha256(binpath.read_bytes()).hexdigest()
        (vdir / manname).write_text(json.dumps({
            "sha256": sha,
            "source_commit": "fake0000",
            "build_host": "fake-mode",
            "build_date": "1970-01-01T00:00:00Z",
            "target": target,
            "expected_lock_min": 8,
            "label": "%s-synthetic-fifo%s" % (version, fifo_label),
        }, indent=2) + "\n")
    return vdir
