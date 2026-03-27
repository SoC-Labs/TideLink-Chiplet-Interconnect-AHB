#!/usr/bin/env python3
"""Generate a static HTML dashboard from CI lint, regression, and synthesis artifacts."""

import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

from parse_ppa import collect_ppa_data, generate_ppa_html


def parse_junit_xml(xml_path):
    """Parse a cocotb JUnit XML results file."""
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        # Handle both <testsuites> and <testsuite> as root
        if root.tag == "testsuites":
            suites = root.findall("testsuite")
        else:
            suites = [root]

        tests = 0
        failures = 0
        errors = 0
        skipped = 0
        test_cases = []

        for suite in suites:
            tests += int(suite.get("tests", 0))
            failures += int(suite.get("failures", 0))
            errors += int(suite.get("errors", 0))
            skipped += int(suite.get("skipped", suite.get("skip", 0)))

            for tc in suite.findall("testcase"):
                name = tc.get("name", "unknown")
                classname = tc.get("classname", "")
                time_s = float(tc.get("time", 0))
                status = "pass"
                message = ""
                if tc.find("failure") is not None:
                    status = "fail"
                    message = tc.find("failure").get("message", "")
                elif tc.find("error") is not None:
                    status = "error"
                    message = tc.find("error").get("message", "")
                elif tc.find("skipped") is not None:
                    status = "skip"
                test_cases.append({
                    "name": name,
                    "classname": classname,
                    "time": time_s,
                    "status": status,
                    "message": message,
                })

        return {
            "tests": tests,
            "failures": failures,
            "errors": errors,
            "skipped": skipped,
            "passed": tests - failures - errors - skipped,
            "test_cases": test_cases,
        }
    except Exception as e:
        return {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "passed": 0,
                "test_cases": [], "parse_error": str(e)}


def parse_result_file(result_path):
    """Read a .result file (PASS or FAIL)."""
    try:
        return Path(result_path).read_text().strip()
    except Exception:
        return "UNKNOWN"


def parse_lint_log(log_path):
    """Parse a HAL lint log for errors and warnings."""
    errors = []
    warnings = []
    total_errors = 0
    total_warnings = 0

    try:
        text = Path(log_path).read_text(errors="replace")

        for line in text.splitlines():
            if "*E" in line:
                errors.append(line.strip())
            elif "*W" in line:
                # Exclude xmelab noise
                if "xmelab" not in line:
                    warnings.append(line.strip())

        # Try to extract summary counts
        for line in text.splitlines():
            m = re.search(r"Total errors\s*[:=]\s*(\d+)", line, re.IGNORECASE)
            if m:
                total_errors = int(m.group(1))
            m = re.search(r"Total warnings\s*[:=]\s*(\d+)", line, re.IGNORECASE)
            if m:
                total_warnings = int(m.group(1))

        # Fall back to counted lines if summary not found
        if total_errors == 0 and errors:
            total_errors = len(errors)
        if total_warnings == 0 and warnings:
            total_warnings = len(warnings)

    except Exception as e:
        errors.append(f"(could not parse log: {e})")

    # Warning breakdown by category
    categories = {}
    for w in warnings:
        m = re.search(r"\*W,([A-Z]+)", w)
        if m:
            cat = m.group(1)
            categories[cat] = categories.get(cat, 0) + 1

    return {
        "total_errors": total_errors,
        "total_warnings": total_warnings,
        "errors": errors,
        "warnings": warnings,
        "warning_categories": categories,
    }


def collect_regression_data(cocotb_dir):
    """Collect regression results from cocotb artifact directory."""
    envs = [
        "tidelink_fifo", "tidelink_returner", "tidelink_apb_regs",
        "tidelink", "tidelink_ahb", "tidelink_py_pair",
    ]
    results = []
    for env in envs:
        env_dir = Path(cocotb_dir) / env
        result = parse_result_file(env_dir / ".result")

        junit_path = env_dir / "results.xml"
        junit = parse_junit_xml(junit_path) if junit_path.exists() else None

        results.append({"env": env, "result": result, "junit": junit})
    return results


def collect_lint_data(lint_dir):
    """Collect lint results from HAL log artifacts."""
    modules = [
        "tidelink_fifo_ctrl", "tidelink_returner", "tidelink_apb_regs",
    ]
    results = []
    for mod in modules:
        log_path = Path(lint_dir) / f"{mod}_hal.log"
        if log_path.exists():
            data = parse_lint_log(log_path)
            data["module"] = mod
            results.append(data)
        else:
            results.append({
                "module": mod,
                "total_errors": -1,
                "total_warnings": -1,
                "errors": [],
                "warnings": [],
                "warning_categories": {},
            })
    return results


def status_badge(status):
    """Return CSS class for a status."""
    if status in ("PASS", "pass"):
        return "badge-pass"
    elif status in ("FAIL", "fail", "error"):
        return "badge-fail"
    elif status in ("skip",):
        return "badge-skip"
    return "badge-unknown"


def generate_html(regression, lint, meta, ppa=None):
    """Generate the full HTML dashboard."""

    # Aggregate stats
    reg_pass = sum(1 for r in regression if r["result"] == "PASS")
    reg_fail = sum(1 for r in regression if r["result"] == "FAIL")
    reg_total = len(regression)

    total_tests = sum(r["junit"]["tests"] for r in regression if r["junit"])
    total_test_pass = sum(r["junit"]["passed"] for r in regression if r["junit"])
    total_test_fail = sum(r["junit"]["failures"] + r["junit"]["errors"]
                         for r in regression if r["junit"])

    lint_total_errors = sum(l["total_errors"] for l in lint if l["total_errors"] >= 0)
    lint_total_warnings = sum(l["total_warnings"] for l in lint if l["total_warnings"] >= 0)
    lint_modules_clean = sum(1 for l in lint if l["total_errors"] == 0 and l["total_warnings"] == 0)

    # Aggregate warning categories across all modules
    all_categories = {}
    for l in lint:
        for cat, count in l.get("warning_categories", {}).items():
            all_categories[cat] = all_categories.get(cat, 0) + count

    # Overall status
    overall_ok = reg_fail == 0 and lint_total_errors == 0

    # --- Regression detail rows ---
    reg_rows = ""
    for r in regression:
        env = r["env"]
        result = r["result"]
        badge = status_badge(result)
        j = r["junit"]
        if j and j["tests"] > 0:
            test_info = f'{j["passed"]}/{j["tests"]} passed'
            if j["failures"] + j["errors"] > 0:
                test_info += f', {j["failures"] + j["errors"]} failed'
        elif j and "parse_error" in j:
            test_info = f'<span class="text-muted">parse error</span>'
        else:
            test_info = '<span class="text-muted">no results.xml</span>'

        # Expandable test case details
        tc_details = ""
        if j and j["test_cases"]:
            tc_rows = ""
            for tc in j["test_cases"]:
                tc_badge = status_badge(tc["status"])
                tc_name = tc["name"]
                tc_time = f'{tc["time"]:.2f}s' if tc["time"] else ""
                tc_msg = f'<div class="tc-message">{tc["message"]}</div>' if tc["message"] else ""
                tc_rows += f"""
                <tr>
                    <td><span class="badge {tc_badge}">{tc["status"].upper()}</span></td>
                    <td>{tc_name}{tc_msg}</td>
                    <td class="text-right">{tc_time}</td>
                </tr>"""
            tc_details = f"""
            <tr class="detail-row" id="detail-{env}">
                <td colspan="3">
                    <table class="tc-table">
                        <thead><tr><th>Status</th><th>Test</th><th>Time</th></tr></thead>
                        <tbody>{tc_rows}</tbody>
                    </table>
                </td>
            </tr>"""

        toggle = f'onclick="toggleDetail(\'{env}\')"' if j and j["test_cases"] else ""
        cursor = "cursor-pointer" if j and j["test_cases"] else ""

        reg_rows += f"""
            <tr class="{cursor}" {toggle}>
                <td><code>{env}</code></td>
                <td><span class="badge {badge}">{result}</span></td>
                <td>{test_info}</td>
            </tr>{tc_details}"""

    # --- Lint detail rows ---
    lint_rows = ""
    for l in lint:
        mod = l["module"]
        if l["total_errors"] < 0:
            lint_rows += f"""
            <tr>
                <td><code>{mod}</code></td>
                <td colspan="3"><span class="text-muted">log not found</span></td>
            </tr>"""
            continue

        err_count = l["total_errors"]
        warn_count = l["total_warnings"]
        err_badge = "badge-pass" if err_count == 0 else "badge-fail"
        warn_badge = "badge-pass" if warn_count == 0 else "badge-warn"

        # Warning categories breakdown
        cat_str = ""
        if l["warning_categories"]:
            parts = [f"{cat}: {c}" for cat, c in
                     sorted(l["warning_categories"].items(), key=lambda x: -x[1])]
            cat_str = ", ".join(parts)

        # Expandable details
        detail_items = ""
        if l["errors"]:
            detail_items += '<div class="lint-section"><strong>Errors:</strong><ul>'
            for e in l["errors"][:20]:
                detail_items += f"<li><code>{e}</code></li>"
            if len(l["errors"]) > 20:
                detail_items += f'<li class="text-muted">... and {len(l["errors"])-20} more</li>'
            detail_items += "</ul></div>"
        if l["warnings"]:
            detail_items += '<div class="lint-section"><strong>Warnings:</strong><ul>'
            for w in l["warnings"][:30]:
                detail_items += f"<li><code>{w}</code></li>"
            if len(l["warnings"]) > 30:
                detail_items += f'<li class="text-muted">... and {len(l["warnings"])-30} more</li>'
            detail_items += "</ul></div>"

        toggle = f'onclick="toggleDetail(\'lint-{mod}\')"' if detail_items else ""
        cursor = "cursor-pointer" if detail_items else ""

        lint_rows += f"""
            <tr class="{cursor}" {toggle}>
                <td><code>{mod}</code></td>
                <td><span class="badge {err_badge}">{err_count}</span></td>
                <td><span class="badge {warn_badge}">{warn_count}</span></td>
                <td class="text-muted">{cat_str}</td>
            </tr>"""
        if detail_items:
            lint_rows += f"""
            <tr class="detail-row" id="detail-lint-{mod}">
                <td colspan="4">{detail_items}</td>
            </tr>"""

    # --- Warning category summary ---
    cat_summary = ""
    if all_categories:
        cat_rows = ""
        for cat, count in sorted(all_categories.items(), key=lambda x: -x[1]):
            cat_rows += f"<tr><td><code>{cat}</code></td><td>{count}</td></tr>"
        cat_summary = f"""
        <div class="card">
            <h3>Warning Categories (All Modules)</h3>
            <table>
                <thead><tr><th>Category</th><th>Count</th></tr></thead>
                <tbody>{cat_rows}</tbody>
            </table>
        </div>"""

    # --- Build page ---
    overall_class = "status-pass" if overall_ok else "status-fail"
    overall_text = "ALL CLEAR" if overall_ok else "ISSUES DETECTED"

    commit = meta.get("commit", "unknown")
    branch = meta.get("branch", "unknown")
    pipeline = meta.get("pipeline", "")
    project_url = meta.get("project_url", "")
    timestamp = meta.get("timestamp", datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))

    # PPA section
    ppa_section = generate_ppa_html(ppa) if ppa and ppa.get("available") else ""

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TideLink CI Dashboard</title>
<style>
:root {{
    --bg: #0d1117;
    --surface: #161b22;
    --border: #30363d;
    --text: #e6edf3;
    --text-muted: #8b949e;
    --green: #3fb950;
    --red: #f85149;
    --yellow: #d29922;
    --blue: #58a6ff;
}}
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
    padding: 2rem;
    max-width: 1100px;
    margin: 0 auto;
}}
h1 {{ font-size: 1.6rem; margin-bottom: 0.3rem; }}
h2 {{ font-size: 1.3rem; margin-bottom: 1rem; color: var(--blue); }}
h3 {{ font-size: 1.1rem; margin-bottom: 0.8rem; }}
.header {{
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 2rem;
    flex-wrap: wrap;
    gap: 1rem;
}}
.header-left {{ flex: 1; }}
.meta {{ color: var(--text-muted); font-size: 0.85rem; }}
.meta a {{ color: var(--blue); text-decoration: none; }}
.meta a:hover {{ text-decoration: underline; }}
.overall {{
    padding: 0.6rem 1.4rem;
    border-radius: 8px;
    font-weight: 600;
    font-size: 1rem;
    letter-spacing: 0.5px;
}}
.status-pass {{ background: rgba(63,185,80,0.15); color: var(--green); border: 1px solid var(--green); }}
.status-fail {{ background: rgba(248,81,73,0.15); color: var(--red); border: 1px solid var(--red); }}

.summary-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 1rem;
    margin-bottom: 2rem;
}}
.summary-card {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 1.2rem;
    text-align: center;
}}
.summary-card .value {{
    font-size: 2rem;
    font-weight: 700;
}}
.summary-card .label {{
    font-size: 0.8rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}}
.val-green {{ color: var(--green); }}
.val-red {{ color: var(--red); }}
.val-yellow {{ color: var(--yellow); }}
.val-blue {{ color: var(--blue); }}

.card {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 1.5rem;
    margin-bottom: 1.5rem;
}}
.summary-row {{
    display: flex;
    gap: 1.5rem;
    margin-bottom: 1.5rem;
    flex-wrap: wrap;
}}
.summary-box {{
    flex: 1;
    min-width: 120px;
    text-align: center;
    padding: 1rem;
    background: rgba(0,0,0,0.2);
    border-radius: 6px;
    border: 1px solid var(--border);
}}
.summary-value {{
    font-size: 1.8rem;
    font-weight: 700;
    color: var(--text);
}}
.summary-label {{
    font-size: 0.75rem;
    color: var(--text-muted);
    margin-top: 0.3rem;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}}
table {{
    width: 100%;
    border-collapse: collapse;
}}
th, td {{
    text-align: left;
    padding: 0.6rem 0.8rem;
    border-bottom: 1px solid var(--border);
}}
th {{
    color: var(--text-muted);
    font-size: 0.8rem;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    font-weight: 600;
}}
tr:last-child td {{ border-bottom: none; }}
.text-right {{ text-align: right; }}
.text-muted {{ color: var(--text-muted); }}

.badge {{
    display: inline-block;
    padding: 0.15rem 0.6rem;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.3px;
}}
.badge-pass {{ background: rgba(63,185,80,0.15); color: var(--green); }}
.badge-fail {{ background: rgba(248,81,73,0.15); color: var(--red); }}
.badge-warn {{ background: rgba(210,153,34,0.15); color: var(--yellow); }}
.badge-skip {{ background: rgba(139,148,158,0.15); color: var(--text-muted); }}
.badge-unknown {{ background: rgba(139,148,158,0.15); color: var(--text-muted); }}

.cursor-pointer {{ cursor: pointer; }}
.cursor-pointer:hover {{ background: rgba(88,166,255,0.05); }}
.detail-row {{ display: none; }}
.detail-row td {{ padding: 0.8rem 1.2rem; background: rgba(0,0,0,0.2); }}
.detail-row.open {{ display: table-row; }}

.tc-table {{ margin: 0; }}
.tc-table th {{ font-size: 0.7rem; }}
.tc-table td {{ font-size: 0.85rem; padding: 0.3rem 0.6rem; }}
.tc-message {{ font-size: 0.75rem; color: var(--red); margin-top: 0.2rem; }}

.lint-section {{ margin-bottom: 0.8rem; }}
.lint-section ul {{ margin: 0.3rem 0 0 1.5rem; }}
.lint-section li {{ font-size: 0.8rem; margin-bottom: 0.15rem; }}
.lint-section code {{ font-size: 0.75rem; word-break: break-all; }}

.footer {{
    margin-top: 3rem;
    padding-top: 1rem;
    border-top: 1px solid var(--border);
    color: var(--text-muted);
    font-size: 0.75rem;
    text-align: center;
}}
</style>
</head>
<body>

<div class="header">
    <div class="header-left">
        <h1>TideLink CI Dashboard</h1>
        <div class="meta">
            Branch: <strong>{branch}</strong> &middot;
            Commit: <a href="{project_url}/-/commit/{commit}"><code>{commit[:8]}</code></a> &middot;
            Pipeline: <a href="{project_url}/-/pipelines/{pipeline}">#{pipeline}</a> &middot;
            {timestamp}
        </div>
    </div>
    <div class="overall {overall_class}">{overall_text}</div>
</div>

<div class="summary-grid">
    <div class="summary-card">
        <div class="value {'val-green' if reg_fail == 0 else 'val-red'}">{reg_pass}/{reg_total}</div>
        <div class="label">Environments Passing</div>
    </div>
    <div class="summary-card">
        <div class="value {'val-green' if total_test_fail == 0 else 'val-red'}">{total_test_pass}/{total_tests}</div>
        <div class="label">Tests Passing</div>
    </div>
    <div class="summary-card">
        <div class="value {'val-green' if lint_total_errors == 0 else 'val-red'}">{lint_total_errors}</div>
        <div class="label">Lint Errors</div>
    </div>
    <div class="summary-card">
        <div class="value {'val-green' if lint_total_warnings == 0 else 'val-yellow'}">{lint_total_warnings}</div>
        <div class="label">Lint Warnings</div>
    </div>
</div>

<h2>Regression Results</h2>
<div class="card">
    <table>
        <thead>
            <tr><th>Environment</th><th>Status</th><th>Tests</th></tr>
        </thead>
        <tbody>
            {reg_rows}
        </tbody>
    </table>
</div>

<h2>Lint Results</h2>
<div class="card">
    <table>
        <thead>
            <tr><th>Module</th><th>Errors</th><th>Warnings</th><th>Categories</th></tr>
        </thead>
        <tbody>
            {lint_rows}
        </tbody>
    </table>
</div>

{cat_summary}

{ppa_section}

<div class="footer">
    Generated by TideLink CI &middot; {timestamp}
</div>

<script>
function toggleDetail(id) {{
    const row = document.getElementById('detail-' + id);
    if (row) row.classList.toggle('open');
}}
</script>

</body>
</html>"""
    return html


def main():
    # Paths — these match the CI artifact layout
    # Can be overridden via environment variables
    cocotb_dir = os.environ.get("COCOTB_ARTIFACT_DIR", "cocotb")
    lint_dir = os.environ.get("LINT_ARTIFACT_DIR", ".")
    dc_rpt_dir = os.environ.get("DC_REPORT_DIR", "syn/asic/design-compiler/tidelink_dc_reports")
    output_dir = os.environ.get("OUTPUT_DIR", "public")
    output_file = os.path.join(output_dir, "index.html")

    # CI metadata from GitLab environment variables
    meta = {
        "commit": os.environ.get("CI_COMMIT_SHA", "local"),
        "branch": os.environ.get("CI_COMMIT_REF_NAME", "unknown"),
        "pipeline": os.environ.get("CI_PIPELINE_ID", ""),
        "project_url": os.environ.get("CI_PROJECT_URL", ""),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
    }

    print(f"Collecting regression data from: {cocotb_dir}")
    regression = collect_regression_data(cocotb_dir)

    print(f"Collecting lint data from: {lint_dir}")
    lint = collect_lint_data(lint_dir)

    print(f"Collecting PPA data from: {dc_rpt_dir}")
    ppa = collect_ppa_data(dc_rpt_dir)

    print("Generating dashboard HTML...")
    html = generate_html(regression, lint, meta, ppa=ppa)

    os.makedirs(output_dir, exist_ok=True)
    Path(output_file).write_text(html)
    print(f"Dashboard written to: {output_file}")

    # Print summary
    reg_pass = sum(1 for r in regression if r["result"] == "PASS")
    reg_total = len(regression)
    lint_errors = sum(l["total_errors"] for l in lint if l["total_errors"] >= 0)
    lint_warnings = sum(l["total_warnings"] for l in lint if l["total_warnings"] >= 0)
    print(f"  Regression: {reg_pass}/{reg_total} environments passing")
    print(f"  Lint: {lint_errors} errors, {lint_warnings} warnings")
    if ppa.get("available"):
        s = ppa["summary"]
        print(f"  PPA: {s['total_area_mm2']} mm^2, {s['total_power_mw']:.3f} mW, "
              f"{s['frequency_mhz']:.0f} MHz, timing {'MET' if s['timing_met'] else 'VIOLATED'}")
    else:
        print(f"  PPA: No synthesis reports found")


if __name__ == "__main__":
    main()
