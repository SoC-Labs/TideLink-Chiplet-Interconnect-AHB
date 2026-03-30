#!/usr/bin/env python3
"""Generate a Markdown CI dashboard for the GitLab wiki.

Reads the same artifacts as generate_dashboard.py but outputs Markdown
suitable for committing to the project wiki.

Usage:
    python3 generate_wiki.py                  # writes to wiki/ directory
    python3 generate_wiki.py --output-dir /tmp/wiki
"""

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# parse_ppa lives alongside this script
sys.path.insert(0, str(Path(__file__).parent))

from generate_dashboard import (
    collect_lint_data,
    collect_regression_data,
    collect_uvm_data,
)
from parse_ppa import collect_ppa_data


def generate_markdown(regression, lint, ppa, meta, uvm=None):
    """Generate the full Markdown dashboard."""

    commit = meta.get("commit", "local")[:8]
    branch = meta.get("branch", "unknown")
    pipeline = meta.get("pipeline", "")
    project_url = meta.get("project_url", "")
    timestamp = meta.get("timestamp", "")

    # Aggregate stats
    reg_pass = sum(1 for r in regression if r["result"] == "PASS")
    reg_total = len(regression)
    total_tests = sum(r["junit"]["tests"] for r in regression if r["junit"])
    total_test_pass = sum(r["junit"]["passed"] for r in regression if r["junit"])
    total_test_fail = sum(
        r["junit"]["failures"] + r["junit"]["errors"]
        for r in regression
        if r["junit"]
    )

    lint_total_errors = sum(
        l["total_errors"] for l in lint if l["total_errors"] >= 0
    )
    lint_total_warnings = sum(
        l["total_warnings"] for l in lint if l["total_warnings"] >= 0
    )

    md = []
    md.append("# TideLink CI Dashboard")
    md.append("")

    # Meta info
    if pipeline and project_url:
        md.append(
            f"**Branch:** `{branch}` | "
            f"**Commit:** [`{commit}`]({project_url}/-/commit/{meta.get('commit', '')}) | "
            f"**Pipeline:** [#{pipeline}]({project_url}/-/pipelines/{pipeline}) | "
            f"**Updated:** {timestamp}"
        )
    else:
        md.append(
            f"**Branch:** `{branch}` | **Commit:** `{commit}` | **Updated:** {timestamp}"
        )
    md.append("")

    # ── Summary ──────────────────────────────────────────────────────────
    md.append("## Summary")
    md.append("")
    md.append("| Metric | Value |")
    md.append("|--------|-------|")
    md.append(f"| Environments Passing | {reg_pass}/{reg_total} |")
    md.append(f"| Tests Passing | {total_test_pass}/{total_tests} |")
    md.append(f"| Lint Errors | {lint_total_errors} |")
    md.append(f"| Lint Warnings | {lint_total_warnings} |")

    if uvm and uvm["junit"]:
        j = uvm["junit"]
        md.append(f"| UVM Tests Passing | {j['passed']}/{j['tests']} |")
    else:
        md.append("| UVM Tests Passing | N/A |")

    if ppa and ppa.get("available"):
        s = ppa["summary"]
        timing_status = "MET" if s["timing_met"] else "VIOLATED"
        md.append(f"| Total Area | {s['total_area_mm2']} mm^2 |")
        md.append(f"| Total Power | {s['total_power_mw']:.3f} mW |")
        md.append(f"| Target Frequency | {s['frequency_mhz']:.0f} MHz |")
        md.append(f"| Timing | {timing_status} (slack {s['critical_path_slack_ns']:.2f} ns) |")
    md.append("")

    # ── Regression Results ───────────────────────────────────────────────
    md.append("## Regression Results")
    md.append("")
    md.append("| Environment | Result | Tests | Passed | Failed |")
    md.append("|-------------|--------|-------|--------|--------|")

    for r in regression:
        result = r["result"]
        junit = r["junit"]
        if junit:
            md.append(
                f"| `{r['env']}` | {result} | {junit['tests']} | "
                f"{junit['passed']} | {junit['failures'] + junit['errors']} |"
            )
        else:
            md.append(f"| `{r['env']}` | {result} | - | - | - |")
    md.append("")

    # ── Lint Results ─────────────────────────────────────────────────────
    md.append("## Lint Results")
    md.append("")
    md.append("| Module | Errors | Warnings |")
    md.append("|--------|--------|----------|")

    for l in lint:
        errors = l["total_errors"] if l["total_errors"] >= 0 else "N/A"
        warnings = l["total_warnings"] if l["total_warnings"] >= 0 else "N/A"
        md.append(f"| `{l['module']}` | {errors} | {warnings} |")
    md.append("")

    # ── UVM Results ──────────────────────────────────────────────────────
    if uvm and uvm["junit"] and uvm["junit"]["tests"] > 0:
        j = uvm["junit"]
        md.append("## UVM Regression")
        md.append("")
        md.append(f"**{j['passed']}/{j['tests']}** tests passed")
        md.append("")
        md.append("| Test | Status | Time |")
        md.append("|------|--------|------|")
        for tc in j["test_cases"]:
            status = tc["status"].upper()
            time_s = f'{tc["time"]:.2f}s' if tc["time"] else "-"
            md.append(f"| `{tc['name']}` | {status} | {time_s} |")
        md.append("")

    # ── PPA Results ──────────────────────────────────────────────────────
    if ppa and ppa.get("available"):
        s = ppa["summary"]
        area = ppa["area"]
        power = ppa["power"]

        md.append("## Synthesis PPA")
        md.append("")

        # Area
        md.append("### Area")
        md.append("")
        total = s["total_area_um2"] if s["total_area_um2"] > 0 else 1
        md.append("| Component | Area (um^2) | % |")
        md.append("|-----------|-------------|---|")
        md.append(
            f"| Combinational | {area.get('combinational_area', 0):,.2f} | "
            f"{(area.get('combinational_area', 0) or 0) / total * 100:.1f}% |"
        )
        md.append(
            f"| Sequential | {area.get('noncombinational_area', 0):,.2f} | "
            f"{(area.get('noncombinational_area', 0) or 0) / total * 100:.1f}% |"
        )
        md.append(
            f"| Macro/Black Box | {area.get('macro_area', 0):,.2f} | "
            f"{(area.get('macro_area', 0) or 0) / total * 100:.1f}% |"
        )
        md.append(
            f"| **Total** | **{s['total_area_um2']:,.2f}** | **{s['total_area_mm2']} mm^2** |"
        )
        md.append("")

        # Power
        md.append("### Power")
        md.append("")
        md.append("| Component | Value |")
        md.append("|-----------|-------|")
        md.append(f"| Switching Power | {power.get('switching_power_mw', 0):.3f} mW |")
        md.append(f"| Internal Power | {power.get('internal_power_mw', 0):.3f} mW |")
        md.append(f"| Leakage Power | {s['leakage_power_uw']:.3f} uW |")
        md.append(f"| **Total Power** | **{s['total_power_mw']:.3f} mW** |")
        md.append(f"| Operating Voltage | {power.get('voltage', 'N/A')} V |")
        md.append("")

        # Timing
        md.append("### Timing")
        md.append("")
        timing_status = "MET" if s["timing_met"] else "VIOLATED"
        md.append("| Metric | Value |")
        md.append("|--------|-------|")
        md.append(
            f"| Clock Period | {s['clock_period_ns']} ns ({s['frequency_mhz']:.0f} MHz) |"
        )
        md.append(f"| Critical Path Slack | {s['critical_path_slack_ns']:.2f} ns ({timing_status}) |")
        md.append(f"| Levels of Logic | {s['levels_of_logic']} |")
        md.append(f"| Setup Violations | {s['setup_violating_paths']} |")
        md.append(f"| Hold Violations | {s['hold_violating_paths']} |")
        md.append("")

        # Design stats
        md.append("### Design Statistics")
        md.append("")
        md.append("| Metric | Count |")
        md.append("|--------|-------|")
        md.append(f"| Total Cells | {s['num_cells']:,} |")
        md.append(f"| Macros | {s['num_macros']} |")
        md.append(f"| Ports | {area.get('num_ports', 'N/A')} |")
        md.append(f"| Nets | {area.get('num_nets', 'N/A'):,} |")
        md.append("")

        # Critical paths
        if ppa.get("timing_paths"):
            md.append("### Critical Paths (Top 10)")
            md.append("")
            md.append("| # | Startpoint | Endpoint | Slack (ns) | Status |")
            md.append("|---|------------|----------|------------|--------|")
            for i, p in enumerate(ppa["timing_paths"], 1):
                slack_val = p.get("slack", 0)
                met = "MET" if p.get("slack_met", False) else "VIOLATED"
                md.append(
                    f"| {i} | `{p['startpoint']}` | `{p['endpoint']}` | "
                    f"{slack_val:.2f} | {met} |"
                )
            md.append("")

    # Footer
    md.append("---")
    md.append(f"*Auto-generated by TideLink CI — {timestamp}*")

    return "\n".join(md)


def main():
    cocotb_dir = os.environ.get("COCOTB_ARTIFACT_DIR", "cocotb")
    lint_dir = os.environ.get("LINT_ARTIFACT_DIR", ".")
    uvm_dir = os.environ.get("UVM_ARTIFACT_DIR", "uvm/tidelink")
    dc_rpt_dir = os.environ.get(
        "DC_REPORT_DIR", "syn/asic/design-compiler/tidelink_dc_reports"
    )
    output_dir = os.environ.get("WIKI_OUTPUT_DIR", "wiki")

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

    print(f"Collecting UVM data from: {uvm_dir}")
    uvm = collect_uvm_data(uvm_dir)

    print(f"Collecting PPA data from: {dc_rpt_dir}")
    ppa = collect_ppa_data(dc_rpt_dir)

    print("Generating wiki Markdown...")
    markdown = generate_markdown(regression, lint, ppa, meta, uvm=uvm)

    os.makedirs(output_dir, exist_ok=True)
    output_file = os.path.join(output_dir, "CI-Dashboard.md")
    Path(output_file).write_text(markdown)
    print(f"Wiki page written to: {output_file}")


if __name__ == "__main__":
    main()
