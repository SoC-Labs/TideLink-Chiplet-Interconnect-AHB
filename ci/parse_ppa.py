#!/usr/bin/env python3
"""Parse Design Compiler PPA (Performance, Power, Area) reports.

Extracts key metrics from DC report files and returns structured data
suitable for dashboard integration or standalone JSON output.

Usage (standalone):
    python3 parse_ppa.py /path/to/tidelink_dc_reports

Usage (as module):
    from parse_ppa import collect_ppa_data
    ppa = collect_ppa_data("syn/asic/design-compiler/tidelink_dc_reports")
"""

import json
import re
import sys
from pathlib import Path


def parse_area_report(rpt_path):
    """Parse area.rpt and extract area metrics."""
    text = Path(rpt_path).read_text()
    result = {}

    patterns = {
        "combinational_area": r"Combinational area:\s+([\d.]+)",
        "buf_inv_area": r"Buf/Inv area:\s+([\d.]+)",
        "noncombinational_area": r"Noncombinational area:\s+([\d.]+)",
        "macro_area": r"Macro/Black Box area:\s+([\d.]+)",
        "net_area": r"Net Interconnect area:\s+([\d.]+)",
        "total_area": r"Total cell area:\s+([\d.]+)",
    }

    for key, pattern in patterns.items():
        m = re.search(pattern, text)
        result[key] = float(m.group(1)) if m else None

    # Cell counts
    count_patterns = {
        "num_ports": r"Number of ports:\s+(\d+)",
        "num_nets": r"Number of nets:\s+(\d+)",
        "num_cells": r"Number of cells:\s+(\d+)",
        "num_combinational": r"Number of combinational cells:\s+(\d+)",
        "num_sequential": r"Number of sequential cells:\s+(\d+)",
        "num_macros": r"Number of macros/black boxes:\s+(\d+)",
        "num_buf_inv": r"Number of buf/inv:\s+(\d+)",
    }

    for key, pattern in count_patterns.items():
        m = re.search(pattern, text)
        result[key] = int(m.group(1)) if m else None

    return result


def parse_power_report(rpt_path):
    """Parse power.rpt and extract power metrics."""
    text = Path(rpt_path).read_text()
    result = {}

    # Extract units
    m = re.search(r"Dynamic Power Units = (\S+)", text)
    result["dynamic_unit"] = m.group(1) if m else "mW"

    m = re.search(r"Leakage Power Units = (\S+)", text)
    result["leakage_unit"] = m.group(1) if m else "uW"

    m = re.search(r"Global Operating Voltage = ([\d.]+)", text)
    result["voltage"] = float(m.group(1)) if m else None

    # Parse the hierarchy table — top-level row is the first data row
    # Format: name  switch_power  int_power  leak_power  total_power  %
    lines = text.split("\n")
    in_table = False
    past_header = False
    for line in lines:
        if "Switch   Int      Leak     Total" in line:
            in_table = True
            continue
        if in_table and "---" in line:
            past_header = True
            continue
        if in_table and past_header and line.strip():
            parts = line.split()
            try:
                result["switching_power_mw"] = float(parts[-5])
                result["internal_power_mw"] = float(parts[-4])
                result["leakage_power_uw"] = float(parts[-3])
                result["total_power_mw"] = float(parts[-2])
                break
            except (ValueError, IndexError):
                continue

    return result


def parse_timing_report(rpt_path):
    """Parse timing.rpt and extract critical path information."""
    text = Path(rpt_path).read_text()
    paths = []

    # Split into individual path reports (use findall for Python 3.6 compat)
    path_blocks = re.findall(r"\s+Startpoint:.*?(?=\s+Startpoint:|\Z)", text, re.DOTALL)

    for block in path_blocks:
        if "Startpoint:" not in block:
            continue

        path = {}
        m = re.search(r"Startpoint:\s+(\S+)", block)
        path["startpoint"] = m.group(1) if m else "unknown"

        m = re.search(r"Endpoint:\s+(\S+)", block)
        path["endpoint"] = m.group(1) if m else "unknown"

        m = re.search(r"data arrival time\s+([\d.]+)", block)
        path["arrival_time"] = float(m.group(1)) if m else None

        m = re.search(r"slack \((\w+)\)\s+([-\d.]+)", block)
        if m:
            path["slack_met"] = m.group(1) == "MET"
            path["slack"] = float(m.group(2))

        paths.append(path)

    return paths


def parse_qor_report(rpt_path):
    """Parse qor.rpt and extract QoR metrics."""
    text = Path(rpt_path).read_text()
    result = {}

    patterns = {
        "levels_of_logic": r"Levels of Logic:\s+([\d.]+)",
        "critical_path_length": r"Critical Path Length:\s+([\d.]+)",
        "critical_path_slack": r"Critical Path Slack:\s+([-\d.]+)",
        "critical_path_clk_period": r"Critical Path Clk Period:\s+([\d.]+)",
        "total_negative_slack": r"Total Negative Slack:\s+([-\d.]+)",
        "num_violating_paths": r"No. of Violating Paths:\s+([\d.]+)",
        "worst_hold_violation": r"Worst Hold Violation:\s+([-\d.]+)",
        "total_hold_violation": r"Total Hold Violation:\s+([-\d.]+)",
        "num_hold_violations": r"No. of Hold Violations:\s+([\d.]+)",
    }

    for key, pattern in patterns.items():
        m = re.search(pattern, text)
        result[key] = float(m.group(1)) if m else None

    # WNS/TNS summary lines
    m = re.search(r"Design\s+WNS:\s+([\d.]+)\s+TNS:\s+([\d.]+)\s+Number of Violating Paths:\s+(\d+)", text)
    if m:
        result["wns"] = float(m.group(1))
        result["tns"] = float(m.group(2))
        result["setup_violating_paths"] = int(m.group(3))

    m = re.search(r"Design \(Hold\)\s+WNS:\s+([\d.]+)\s+TNS:\s+([\d.]+)\s+Number of Violating Paths:\s+(\d+)", text)
    if m:
        result["hold_wns"] = float(m.group(1))
        result["hold_tns"] = float(m.group(2))
        result["hold_violating_paths"] = int(m.group(3))

    # Compile time
    m = re.search(r"Overall Compile Wall Clock Time:\s+([\d.]+)", text)
    result["compile_time_s"] = float(m.group(1)) if m else None

    return result


def collect_ppa_data(rpt_dir):
    """Collect all PPA data from a DC reports directory.

    Returns a dict with keys: area, power, timing, qor, summary.
    """
    rpt_dir = Path(rpt_dir)
    data = {"available": False}

    if not rpt_dir.is_dir():
        return data

    area_path = rpt_dir / "area.rpt"
    power_path = rpt_dir / "power.rpt"
    timing_path = rpt_dir / "timing.rpt"
    qor_path = rpt_dir / "qor.rpt"

    if not all(p.exists() for p in [area_path, power_path, qor_path]):
        return data

    data["available"] = True
    data["area"] = parse_area_report(area_path)
    data["power"] = parse_power_report(power_path)
    data["qor"] = parse_qor_report(qor_path)

    if timing_path.exists():
        paths = parse_timing_report(timing_path)
        data["timing_paths"] = paths[:10]  # Top 10 only
    else:
        data["timing_paths"] = []

    # Build a human-readable summary
    area = data["area"]
    power = data["power"]
    qor = data["qor"]

    total_area_um2 = area.get("total_area", 0) or 0
    total_area_mm2 = total_area_um2 / 1e6

    clk_period = qor.get("critical_path_clk_period", 0) or 0
    freq_mhz = (1000.0 / clk_period) if clk_period > 0 else 0

    slack = qor.get("critical_path_slack")
    timing_met = slack is not None and slack >= 0

    data["summary"] = {
        "total_area_um2": total_area_um2,
        "total_area_mm2": round(total_area_mm2, 4),
        "macro_area_um2": area.get("macro_area", 0) or 0,
        "logic_area_um2": round((area.get("combinational_area", 0) or 0) +
                                (area.get("noncombinational_area", 0) or 0), 2),
        "total_power_mw": power.get("total_power_mw", 0) or 0,
        "leakage_power_uw": power.get("leakage_power_uw", 0) or 0,
        "clock_period_ns": clk_period,
        "frequency_mhz": round(freq_mhz, 1),
        "critical_path_slack_ns": slack,
        "timing_met": timing_met,
        "num_cells": area.get("num_cells", 0) or 0,
        "num_macros": area.get("num_macros", 0) or 0,
        "levels_of_logic": int(qor.get("levels_of_logic", 0) or 0),
        "setup_violating_paths": int(qor.get("num_violating_paths", 0) or 0),
        "hold_violating_paths": int(qor.get("num_hold_violations", 0) or 0),
    }

    return data


def generate_ppa_html(ppa):
    """Generate an HTML section for PPA results."""
    if not ppa.get("available"):
        return '<div class="card"><h2>Synthesis PPA</h2><p>No synthesis reports found.</p></div>'

    s = ppa["summary"]
    area = ppa["area"]
    power = ppa["power"]

    timing_class = "badge-pass" if s["timing_met"] else "badge-fail"
    timing_label = "MET" if s["timing_met"] else "VIOLATED"

    # Area breakdown percentages
    total = s["total_area_um2"] if s["total_area_um2"] > 0 else 1
    macro_pct = s["macro_area_um2"] / total * 100
    logic_pct = s["logic_area_um2"] / total * 100

    html = f"""
<div class="card">
  <h2>Synthesis PPA</h2>

  <div class="summary-row">
    <div class="summary-box">
      <div class="summary-value">{s['total_area_mm2']}</div>
      <div class="summary-label">Area (mm&sup2;)</div>
    </div>
    <div class="summary-box">
      <div class="summary-value">{s['total_power_mw']:.3f}</div>
      <div class="summary-label">Power (mW)</div>
    </div>
    <div class="summary-box">
      <div class="summary-value">{s['frequency_mhz']:.0f}</div>
      <div class="summary-label">Freq (MHz)</div>
    </div>
    <div class="summary-box">
      <div class="summary-value"><span class="{timing_class}">{timing_label}</span></div>
      <div class="summary-label">Timing (slack {s['critical_path_slack_ns']:.2f} ns)</div>
    </div>
  </div>

  <h3>Area Breakdown</h3>
  <table>
    <tr><th>Component</th><th>Area (&mu;m&sup2;)</th><th>%</th></tr>
    <tr><td>Combinational</td><td>{area.get('combinational_area', 0):,.2f}</td><td>{(area.get('combinational_area', 0) or 0) / total * 100:.1f}%</td></tr>
    <tr><td>Sequential</td><td>{area.get('noncombinational_area', 0):,.2f}</td><td>{(area.get('noncombinational_area', 0) or 0) / total * 100:.1f}%</td></tr>
    <tr><td>Macro/Black Box</td><td>{area.get('macro_area', 0):,.2f}</td><td>{macro_pct:.1f}%</td></tr>
    <tr><td><strong>Total</strong></td><td><strong>{s['total_area_um2']:,.2f}</strong></td><td><strong>{s['total_area_mm2']} mm&sup2;</strong></td></tr>
  </table>

  <h3>Power Breakdown</h3>
  <table>
    <tr><th>Component</th><th>Value</th></tr>
    <tr><td>Switching Power</td><td>{power.get('switching_power_mw', 0):.3f} mW</td></tr>
    <tr><td>Internal Power</td><td>{power.get('internal_power_mw', 0):.3f} mW</td></tr>
    <tr><td>Leakage Power</td><td>{s['leakage_power_uw']:.3f} &mu;W</td></tr>
    <tr><td><strong>Total Power</strong></td><td><strong>{s['total_power_mw']:.3f} mW</strong></td></tr>
    <tr><td>Operating Voltage</td><td>{power.get('voltage', 'N/A')} V</td></tr>
  </table>

  <h3>Timing</h3>
  <table>
    <tr><th>Metric</th><th>Value</th></tr>
    <tr><td>Clock Period</td><td>{s['clock_period_ns']} ns ({s['frequency_mhz']:.0f} MHz)</td></tr>
    <tr><td>Critical Path Slack</td><td><span class="{timing_class}">{s['critical_path_slack_ns']:.2f} ns</span></td></tr>
    <tr><td>Levels of Logic</td><td>{s['levels_of_logic']}</td></tr>
    <tr><td>Setup Violations</td><td>{s['setup_violating_paths']}</td></tr>
    <tr><td>Hold Violations</td><td>{s['hold_violating_paths']}</td></tr>
  </table>

  <h3>Design Statistics</h3>
  <table>
    <tr><th>Metric</th><th>Count</th></tr>
    <tr><td>Total Cells</td><td>{s['num_cells']:,}</td></tr>
    <tr><td>Macros</td><td>{s['num_macros']}</td></tr>
    <tr><td>Ports</td><td>{area.get('num_ports', 'N/A')}</td></tr>
    <tr><td>Nets</td><td>{area.get('num_nets', 'N/A'):,}</td></tr>
  </table>"""

    # Top timing paths
    if ppa.get("timing_paths"):
        html += """
  <h3>Critical Paths (Top 10)</h3>
  <table>
    <tr><th>#</th><th>Startpoint</th><th>Endpoint</th><th>Slack (ns)</th><th>Status</th></tr>"""
        for i, p in enumerate(ppa["timing_paths"], 1):
            slack_val = p.get("slack", 0)
            met = p.get("slack_met", False)
            cls = "badge-pass" if met else "badge-fail"
            label = "MET" if met else "VIOLATED"
            html += f"""
    <tr>
      <td>{i}</td>
      <td><code>{p['startpoint']}</code></td>
      <td><code>{p['endpoint']}</code></td>
      <td>{slack_val:.2f}</td>
      <td><span class="{cls}">{label}</span></td>
    </tr>"""
        html += "\n  </table>"

    html += "\n</div>"
    return html


def main():
    """Standalone: parse DC reports and print JSON summary."""
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <dc_reports_dir>", file=sys.stderr)
        sys.exit(1)

    rpt_dir = sys.argv[1]
    data = collect_ppa_data(rpt_dir)

    if not data.get("available"):
        print(f"ERROR: No DC reports found in {rpt_dir}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(data, indent=2))

    # Print human-readable summary
    s = data["summary"]
    print("\n--- PPA Summary ---", file=sys.stderr)
    print(f"  Area:   {s['total_area_mm2']} mm^2 ({s['num_cells']} cells, {s['num_macros']} macros)", file=sys.stderr)
    print(f"  Power:  {s['total_power_mw']:.3f} mW ({s['leakage_power_uw']:.1f} uW leakage)", file=sys.stderr)
    print(f"  Freq:   {s['frequency_mhz']:.0f} MHz (period {s['clock_period_ns']} ns)", file=sys.stderr)
    print(f"  Timing: {'MET' if s['timing_met'] else 'VIOLATED'} (slack {s['critical_path_slack_ns']:.2f} ns)", file=sys.stderr)


if __name__ == "__main__":
    main()
