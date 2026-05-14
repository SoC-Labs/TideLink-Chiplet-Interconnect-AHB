#!/usr/bin/env python3
"""Convert a fpgahub `actions run --json` artefact bundle into JUnit XML.

Consumes a directory written by `ci/fpga_run_pair.sh`:

    <log_dir>/run.json              # parent RunStatus (the composite)
    <log_dir>/steps/<run_id>.json   # one child RunStatus per composite step

Emits a single JUnit document on stdout. The composite parent becomes the
testsuite; each child becomes a <testcase>. fpgahub's RunStatus.state
maps to JUnit verdicts as:

    ok          → passed
    failed      → <failure>
    timeout     → <failure type="timeout">
    rejected    → <error type="rejected">
    cancelled   → <skipped> (e.g. lease lost — re-runnable)
    anything else → <error>

The composite's own tail (and any per-step tails) are surfaced as
<system-out> so the GitLab job test view shows the failure context.
"""

from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


STATE_TO_VERDICT = {
    "ok":        ("passed",  None),
    "failed":    ("failure", "failure"),
    "timeout":   ("failure", "timeout"),
    "rejected":  ("error",   "rejected"),
    "cancelled": ("skipped", "cancelled"),
}


def _load(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _testcase(parent_action: str, status: dict, source_path: Path) -> ET.Element:
    action_id = status.get("action_id") or source_path.stem
    state = status.get("state", "unknown")
    started = status.get("started_at") or 0.0
    finished = status.get("finished_at") or started
    duration = max(0.0, float(finished) - float(started))
    tc = ET.Element("testcase", {
        "classname": f"fpga_pair.{parent_action}",
        "name":      action_id,
        "time":      f"{duration:.3f}",
    })
    verdict, kind = STATE_TO_VERDICT.get(state, ("error", "unknown"))
    if verdict != "passed":
        tag = "skipped" if verdict == "skipped" else verdict
        attrs: dict[str, str] = {}
        if kind:
            attrs["type"] = kind
        reason = status.get("reason")
        if reason:
            attrs["message"] = reason
        ET.SubElement(tc, tag, attrs)
    tail = status.get("tail") or []
    if tail:
        out = ET.SubElement(tc, "system-out")
        out.text = "\n".join(tail)
    return tc


def build_suite(log_dir: Path) -> ET.Element:
    parent = _load(log_dir / "run.json")
    if parent is None:
        # No parent — emit a single error testcase so the pipeline UI
        # makes the failure visible rather than silently skipping.
        suite = ET.Element("testsuite", {"name": "fpga_pair", "tests": "1", "errors": "1"})
        tc = ET.SubElement(suite, "testcase", {
            "classname": "fpga_pair", "name": "harness", "time": "0",
        })
        ET.SubElement(tc, "error", {"type": "no_run_json",
                                    "message": "ci/fpga_run_pair.sh did not produce run.json"})
        return suite

    parent_action = parent.get("action_id", "ci_pair_role_aware")
    parent_state = parent.get("state", "unknown")
    parent_started = parent.get("started_at") or 0.0
    parent_finished = parent.get("finished_at") or parent_started
    parent_duration = max(0.0, float(parent_finished) - float(parent_started))

    children = sorted((log_dir / "steps").glob("*.json")) if (log_dir / "steps").exists() else []

    suite = ET.Element("testsuite", {"name": f"fpga_pair.{parent_action}",
                                     "time": f"{parent_duration:.3f}"})

    if not children:
        # No per-step JSONs (e.g. composite never expanded). Render the
        # composite itself as one testcase so verdict is still visible.
        suite.append(_testcase(parent_action, parent, log_dir / "run.json"))
        n_tests = 1
        n_fail = 1 if parent_state in ("failed", "timeout") else 0
        n_err = 1 if parent_state in ("rejected",) else 0
        n_skip = 1 if parent_state == "cancelled" else 0
    else:
        n_tests = n_fail = n_err = n_skip = 0
        for child_path in children:
            status = _load(child_path)
            if status is None:
                continue
            tc = _testcase(parent_action, status, child_path)
            suite.append(tc)
            n_tests += 1
            state = status.get("state", "unknown")
            if state in ("failed", "timeout"):
                n_fail += 1
            elif state == "rejected" or state not in STATE_TO_VERDICT:
                n_err += 1
            elif state == "cancelled":
                n_skip += 1

    suite.set("tests",    str(n_tests))
    suite.set("failures", str(n_fail))
    suite.set("errors",   str(n_err))
    suite.set("skipped",  str(n_skip))
    return suite


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: fpga_runs_to_junit.py <log_dir>", file=sys.stderr)
        return 2
    log_dir = Path(argv[1])
    suite = build_suite(log_dir)
    root = ET.Element("testsuites")
    root.append(suite)
    if hasattr(ET, "indent"):
        ET.indent(ET.ElementTree(root), space="  ")
    sys.stdout.write(ET.tostring(root, encoding="unicode", xml_declaration=True))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
