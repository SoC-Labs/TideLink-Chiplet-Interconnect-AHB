#!/usr/bin/env python3
"""Parse UVM simulation logs and produce a JUnit XML results file.

Scans a directory of UVM test logs (one per test) for pass/fail status and
UVM error/fatal counts, then writes a JUnit XML file compatible with GitLab
CI's test report integration.

Usage:
    python3 uvm_results_to_junit.py <log_dir> <output_xml>

Each .log file in <log_dir> is treated as one test case.  The test is
considered PASSED when the log contains "TEST PASSED" and has zero
UVM_ERROR + UVM_FATAL counts.  Otherwise it is marked FAILED.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_uvm_log(log_path):
    """Parse a single UVM simulation log and return a result dict."""
    text = Path(log_path).read_text(errors="replace")

    # Extract test name from +UVM_TESTNAME in the log or fall back to filename
    m = re.search(r"\+UVM_TESTNAME=(\S+)", text)
    test_name = m.group(1) if m else log_path.stem

    # Look for pass/fail banner
    passed = "TEST PASSED" in text
    failed = "TEST FAILED" in text

    # Extract UVM severity counts
    uvm_errors = 0
    uvm_fatals = 0
    m = re.search(r"UVM_ERROR\s*:\s*(\d+)", text)
    if m:
        uvm_errors = int(m.group(1))
    m = re.search(r"UVM_FATAL\s*:\s*(\d+)", text)
    if m:
        uvm_fatals = int(m.group(1))

    # Extract simulation time
    sim_time = 0.0
    m = re.search(r"CPU Time:\s*([\d.]+)\s*seconds", text)
    if m:
        sim_time = float(m.group(1))

    # Collect error messages for failure details
    error_lines = []
    for line in text.splitlines():
        if "UVM_ERROR" in line and "uvm_report_server" not in line and "UVM_ERROR :" not in line:
            error_lines.append(line.strip())
        if "UVM_FATAL" in line and "uvm_report_server" not in line and "UVM_FATAL :" not in line:
            error_lines.append(line.strip())

    is_pass = passed and (uvm_errors == 0) and (uvm_fatals == 0) and not failed

    return {
        "name": test_name,
        "passed": is_pass,
        "time": sim_time,
        "uvm_errors": uvm_errors,
        "uvm_fatals": uvm_fatals,
        "error_lines": error_lines[-20:],  # Keep last 20 error lines
    }


def generate_junit_xml(results, suite_name="tidelink_uvm"):
    """Generate a JUnit XML ElementTree from a list of result dicts."""
    total = len(results)
    failures = sum(1 for r in results if not r["passed"])

    testsuites = ET.Element("testsuites")
    testsuite = ET.SubElement(testsuites, "testsuite",
                              name=suite_name,
                              tests=str(total),
                              failures=str(failures),
                              errors="0",
                              skipped="0")

    for r in results:
        tc = ET.SubElement(testsuite, "testcase",
                           name=r["name"],
                           classname=suite_name,
                           time=f"{r['time']:.3f}")
        if not r["passed"]:
            msg = f"UVM_ERROR={r['uvm_errors']} UVM_FATAL={r['uvm_fatals']}"
            failure = ET.SubElement(tc, "failure", message=msg, type="UVM")
            failure.text = "\n".join(r["error_lines"]) if r["error_lines"] else msg

    return testsuites


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <log_dir> <output_xml>", file=sys.stderr)
        sys.exit(2)

    log_dir = Path(sys.argv[1])
    output_xml = Path(sys.argv[2])

    if not log_dir.is_dir():
        print(f"ERROR: {log_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    log_files = sorted(log_dir.glob("*.log"))
    # Filter out VCS internal logs (compile, coverage, debug)
    skip_names = {"compile.log", "cm.log", "tr_db.log", "unifiedInference.log"}
    log_files = [f for f in log_files if f.name not in skip_names]

    if not log_files:
        print(f"WARNING: No .log files found in {log_dir}", file=sys.stderr)
        # Write an empty test suite
        results = []
    else:
        results = [parse_uvm_log(f) for f in log_files]

    # Print summary to stderr
    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    failed = total - passed
    print(f"UVM Results: {passed}/{total} passed, {failed} failed", file=sys.stderr)
    for r in results:
        status = "PASS" if r["passed"] else "FAIL"
        print(f"  {status}  {r['name']}  (E={r['uvm_errors']} F={r['uvm_fatals']})", file=sys.stderr)

    # Write JUnit XML
    root = generate_junit_xml(results)
    output_xml.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(root)
    tree.write(str(output_xml), encoding="unicode", xml_declaration=True)
    print(f"Wrote {output_xml}", file=sys.stderr)

    # Exit with failure count so CI can detect test failures
    sys.exit(min(failed, 125))


if __name__ == "__main__":
    main()
