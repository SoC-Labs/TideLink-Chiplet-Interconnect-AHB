"""Provenance gate: manifest loading is fail-closed."""
from __future__ import annotations

import json

import pytest

from pynq_host.throughput_gui import provenance as P


def test_load_ok(artefacts):
    prov = P.load_provenance(artefacts, "v0-fake")
    assert len(prov["master"]["sha256"]) == 64
    assert len(prov["slave"]["sha256"]) == 64
    assert prov["artefact_version"] == "v0-fake"
    assert prov["fifo_label"] == "fake01k"     # parsed from the label
    assert prov["verified_on_board"] is False  # set only by the verifier


def test_missing_version_dir(artefacts):
    with pytest.raises(P.ProvenanceError, match="missing"):
        P.load_provenance(artefacts, "v99-does-not-exist")


def test_missing_flip_manifest(artefacts):
    (artefacts / "v0-fake" / P.SLAVE_MANIFEST).unlink()
    with pytest.raises(P.ProvenanceError, match="manifest missing"):
        P.load_provenance(artefacts, "v0-fake")


def test_bad_sha_rejected(artefacts):
    mpath = artefacts / "v0-fake" / P.MASTER_MANIFEST
    man = json.loads(mpath.read_text())
    man["sha256"] = "deadbeef"                 # too short
    mpath.write_text(json.dumps(man))
    with pytest.raises(P.ProvenanceError, match="sha256"):
        P.load_provenance(artefacts, "v0-fake")


def test_unparseable_manifest(artefacts):
    (artefacts / "v0-fake" / P.MASTER_MANIFEST).write_text("not json {")
    with pytest.raises(P.ProvenanceError, match="unreadable"):
        P.load_provenance(artefacts, "v0-fake")


def test_fifo_label_convention():
    assert P.parse_fifo_label("v37-word-pin-fix-fiforf_01k") == "rf_01k"
    assert P.parse_fifo_label("v37-word-pin-fix") is None
    assert P.parse_fifo_label("") is None


def test_validate_provenance_fail_closed():
    with pytest.raises(P.ProvenanceError):
        P.validate_provenance(None)
    with pytest.raises(P.ProvenanceError):
        P.validate_provenance({"master": {"sha256": "x" * 64}})
    ok = {"master": {"sha256": "a" * 64}, "slave": {"sha256": "b" * 64}}
    assert P.validate_provenance(ok) is ok
