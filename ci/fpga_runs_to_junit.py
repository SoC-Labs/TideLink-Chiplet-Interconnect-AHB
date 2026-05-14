#!/usr/bin/env python3
"""Convert a fpgahub `actions run --json` artefact bundle into JUnit XML.

Consumes a directory written by `ci/fpga_run_pair.sh`:

    <log_dir>/run-1.json                  # parent RunStatus, attempt 1
    <log_dir>/run-2.json                  # ...                 attempt 2
    <log_dir>/run-N.json                  # final attempt
    <log_dir>/run.json                    # symlink/copy of the final attempt
    <log_dir>/steps/<run_id>.json         # one child RunStatus per composite
                                          # step of the *final* attempt only

Earlier attempts that ended `cancelled` with reason `revoked: …` are
preempts (an interactive caller took the chassis); the script then
re-queued and tried again. We surface those as informational testcases
(`<skipped type="preempted">`) so the GitLab UI shows the retry count
without colouring the job red. The final attempt's outcome decides the
verdict.

State → JUnit verdict map:

    ok                                    → passed
    failed                                → <failure>
    timeout                               → <failure type="timeout">
    rejected                              → <error type="rejected">
    cancelled (reason starts "revoked:")  → <skipped type="preempted">
    cancelled (other)                     → <skipped type="cancelled">
    unknown                               → <error>

For backwards compatibility (single-attempt v1 layout — `run.json`
without any `run-N.json` siblings) the converter falls through to the
old single-suite path.
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional


STATE_TO_VERDICT = {
    "ok":        ("passed",  None),
    "failed":    ("failure", "failure"),
    "timeout":   ("failure", "timeout"),
    "rejected":  ("error",   "rejected"),
    "cancelled": ("skipped", "cancelled"),  # may be overridden to "preempted" downstream
}


def _load(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _is_preempt(status: dict) -> bool:
    if status.get("state") != "cancelled":
        return False
    reason = (status.get("reason") or "").lower()
    return reason.startswith("revoked:") or "preempt" in reason


def _testcase(parent_action: str, status: dict, name: Optional[str] = None) -> ET.Element:
    action_id = name or status.get("action_id") or "unknown"
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
    if state == "cancelled" and _is_preempt(status):
        kind = "preempted"
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


def _suite_for_attempt(parent: dict, attempt_n: int, total: int,
                       child_paths: list[Path]) -> ET.Element:
    parent_action = parent.get("action_id", "ci_pair_role_aware")
    parent_state  = parent.get("state", "unknown")
    parent_started  = parent.get("started_at") or 0.0
    parent_finished = parent.get("finished_at") or parent_started
    parent_duration = max(0.0, float(parent_finished) - float(parent_started))

    suite_name = f"fpga_pair.{parent_action}"
    if total > 1:
        suite_name += f".attempt{attempt_n}"
    suite = ET.Element("testsuite", {
        "name": suite_name,
        "time": f"{parent_duration:.3f}",
    })

    n_tests = n_fail = n_err = n_skip = 0

    if not child_paths:
        # No per-step JSONs available for this attempt — render the
        # composite itself as one testcase so verdict is still visible.
        # Common for revoked attempts (the script only snapshots steps
        # for the final attempt).
        suite.append(_testcase(parent_action, parent))
        n_tests = 1
        if parent_state in ("failed", "timeout"):
            n_fail = 1
        elif parent_state == "rejected" or parent_state not in STATE_TO_VERDICT:
            n_err = 1
        elif parent_state == "cancelled":
            n_skip = 1
    else:
        for child_path in child_paths:
            status = _load(child_path)
            if status is None:
                continue
            suite.append(_testcase(parent_action, status))
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


def build_suites(log_dir: Path) -> list[ET.Element]:
    # Discover per-attempt RunStatus files, ordered by attempt number.
    attempt_re = re.compile(r"^run-(\d+)\.json$")
    attempts: list[tuple[int, Path]] = []
    for path in log_dir.glob("run-*.json"):
        m = attempt_re.match(path.name)
        if m:
            attempts.append((int(m.group(1)), path))
    attempts.sort()

    if not attempts:
        # v1 / single-attempt fallback: one run.json, no per-attempt files.
        run_json = log_dir / "run.json"
        if not run_json.exists():
            err = ET.Element("testsuite",
                             {"name": "fpga_pair", "tests": "1", "errors": "1"})
            tc = ET.SubElement(err, "testcase",
                               {"classname": "fpga_pair", "name": "harness", "time": "0"})
            ET.SubElement(tc, "error", {
                "type": "no_run_json",
                "message": "ci/fpga_run_pair.sh did not produce run.json",
            })
            return [err]
        attempts = [(1, run_json)]

    final_attempt_n = attempts[-1][0]
    steps_dir = log_dir / "steps"
    final_step_paths = sorted(steps_dir.glob("*.json")) if steps_dir.exists() else []

    suites: list[ET.Element] = []
    for n, path in attempts:
        parent = _load(path)
        if parent is None:
            continue
        # Only the final attempt has per-step status snapshots; earlier
        # attempts get a one-line composite-level testcase.
        children = final_step_paths if n == final_attempt_n else []
        suites.append(_suite_for_attempt(parent, n, len(attempts), children))
    return suites


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: fpga_runs_to_junit.py <log_dir>", file=sys.stderr)
        return 2
    log_dir = Path(argv[1])
    root = ET.Element("testsuites")
    suites = build_suites(log_dir)
    # Top-level rollup so GitLab's job overview shows attempt count + revokes.
    n_attempts = len(suites) if suites and suites[0].get("name", "").startswith("fpga_pair.") else 1
    n_revokes = max(0, n_attempts - 1)
    root.set("name", f"fpga_pair (attempts={n_attempts}, preempts={n_revokes})")
    for s in suites:
        root.append(s)
    if hasattr(ET, "indent"):
        ET.indent(ET.ElementTree(root), space="  ")
    sys.stdout.write(ET.tostring(root, encoding="unicode", xml_declaration=True))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
