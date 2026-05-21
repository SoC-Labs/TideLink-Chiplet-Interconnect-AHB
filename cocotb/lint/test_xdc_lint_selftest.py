#!/usr/bin/env python3
"""Selftest for xdc_lint.py — verifies that the linter actually catches
each of the Bug #6 anti-patterns we have shipped to silicon, AND does
NOT false-positive on clean XDC content.

The selftest is the regression gate: if anyone weakens the linter
patterns, this test will fail before the linter is silently degraded.

Usage:
    python3 test_xdc_lint_selftest.py

Exit 0 = PASS (linter catches all known bad fixtures and clears all
known good ones). Exit 1 = FAIL.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

THIS = Path(__file__).resolve().parent
LINTER = THIS / "xdc_lint.py"


# ---------- Fixtures ---------------------------------------------------

# A clean XDC: only set_property / create_clock / set_input_delay. No
# procedural Tcl. Must lint clean (exit 0).
GOOD_XDC = """
# Comment-only line, must be ignored
set_property PACKAGE_PIN H16 [get_ports pad_clk_tx]
set_property IOSTANDARD LVCMOS33 [get_ports pad_clk_tx]
create_clock -period 10.0 -name pad_clk_tx [get_ports pad_clk_tx]
set_input_delay -clock pad_clk_tx 1.0 [get_ports pad_rx]
"""

# Bug #6.a — procedural `if {...}` at column 0
BAD_PROCEDURAL = """
set _cells [get_cells -hier -filter {REF_NAME == IDELAYE2}]
if { [llength $_cells] > 0 } {
    set_property IDELAY_VALUE 16 $_cells
}
"""

# Bug #6.a — `catch { ... }` block (Vivado silently swallows nested errors)
BAD_CATCH = """
catch { set_property IOB TRUE [get_ports {pad_rx[*]}] }
"""

# Bug #6.a — nested procedural Tcl via `[file normalize [info script]]`
BAD_NESTED = """
set_property USED_IN_SYNTHESIS false [get_files [file normalize [info script]]]
"""

# Bug #6.b — multi-pin get_pins glob, NOT reduced by lindex 0,
# feeding a master-clock selector
BAD_MULTI_PIN = """
set hclk_pin [get_pins -hier -filter {NAME =~ "*/clk_wiz_0*/clk_out1"}]
create_generated_clock -name hclk -source [get_ports pad_clk] -divide_by 4 $hclk_pin
"""

# Multi-pin glob but GUARDED by lindex 0 — must NOT trip the linter
GOOD_MULTI_PIN_GUARDED = """
set hclk_pin [lindex [get_pins -hier -filter {NAME =~ "*/clk_wiz_0*/clk_out1"}] 0]
create_generated_clock -name hclk -source [get_ports pad_clk] -divide_by 4 $hclk_pin
"""

# Procedural Tcl inside a `#` comment — must NOT trip
GOOD_COMMENTED_PROC = """
# if { 1 == 1 } { puts hello }
# catch { error "nope" }
set_property PACKAGE_PIN K17 [get_ports pad_clk]
"""


def _run_linter(xdc_path: Path) -> tuple[int, str, str]:
    res = subprocess.run(
        [sys.executable, str(LINTER), str(xdc_path)],
        capture_output=True, text=True,
    )
    return res.returncode, res.stdout, res.stderr


def _write(tmp: Path, name: str, content: str) -> Path:
    p = tmp / name
    p.write_text(content)
    return p


def main() -> int:
    failures = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # GOOD: must exit 0 with no findings
        for name, content in [
            ("good_clean.xdc", GOOD_XDC),
            ("good_multi_guarded.xdc", GOOD_MULTI_PIN_GUARDED),
            ("good_commented.xdc", GOOD_COMMENTED_PROC),
        ]:
            p = _write(tmp, name, content)
            rc, out, _ = _run_linter(p)
            if rc != 0:
                failures.append(
                    f"FALSE POSITIVE: {name} should lint clean but didn't:\n"
                    f"  rc={rc}\n  stdout={out.strip()}"
                )

        # BAD: must exit 1 AND specific code must appear in output
        bad_cases = [
            ("bad_procedural.xdc", BAD_PROCEDURAL, "XDC_PROCEDURAL_TCL"),
            ("bad_catch.xdc", BAD_CATCH, "XDC_CATCH_BLOCK"),
            ("bad_nested.xdc", BAD_NESTED, "XDC_NESTED_PROC_TCL"),
            ("bad_multi_pin.xdc", BAD_MULTI_PIN, "XDC_MULTI_PIN_FILTER"),
        ]
        for name, content, expect_code in bad_cases:
            p = _write(tmp, name, content)
            rc, out, _ = _run_linter(p)
            if rc != 1:
                failures.append(
                    f"FALSE NEGATIVE: {name} should fail (rc=1) but rc={rc}\n"
                    f"  stdout={out.strip()}"
                )
                continue
            if expect_code not in out:
                failures.append(
                    f"WRONG CODE: {name} did not emit {expect_code}\n"
                    f"  stdout={out.strip()}"
                )

    if failures:
        print("FAIL — xdc_lint selftest detected regressions:")
        for f in failures:
            print(f)
        return 1
    print("OK — xdc_lint selftest: 7/7 fixtures behaved as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
