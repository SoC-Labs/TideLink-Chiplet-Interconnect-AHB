#!/usr/bin/env python3
"""Red/green control for check_excl_port_wired.py (TL-045).

WHY A CONTROL AT ALL
    TL-045's whole safety property hangs off one new input pin. The RTL cannot
    detect an integration that leaves it unconnected — an unconnected input
    reads 0, which is a perfectly legal "this is not an exclusive". So the only
    thing standing between a correct fix and a silently-reverted one is
    check_excl_port_wired.py, and a checker nobody has watched fail is not
    evidence. Every negative case below is asserted to be REPORTED, not merely
    to not crash.

WHAT THIS PINS
    1. a wired instantiation is clean                       (no false red)
    2. an UNWIRED instantiation is reported                  (the point)
    3. a POSITIONAL instantiation is reported                (unauditable)
    4. a COMMENTED-OUT connection does not count as wired    (the obvious cheat)
    5. a module DEFINITION is not counted as an instantiation
    6. a macro standing in for the parameter list — `tidelink_top `MASK_PARAMS
       u_dut (...)` — is still PARSED. This one is not hypothetical: the first
       version of the parser did not consume the macro, failed to find the '('
       that follows, and SKIPPED THE WHOLE INSTANTIATION. It reported the file
       clean without ever looking at it. That is fail-open, and it is exactly
       the failure this checker exists to prevent, one level up.
    7. an empty scan is COULD-NOT-EVALUATE (exit 2), never a pass. A file glob
       that rots must not report "all clear" forever.

Run: python3 scripts/ci/tests/test_check_excl_port_wired.py
"""

import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts" / "ci"))

from check_excl_port_wired import (  # noqa: E402
    find_instantiations, main, scan_text,
)

FAILURES = []


def expect(name, cond, detail=""):
    if cond:
        print(f"  [ok ] {name}")
    else:
        print(f"  [FAIL] {name} {detail}")
        FAILURES.append(name)


WIRED = """
module tb;
  tidelink_top #(.A(1)) u_dut (
    .hclk (clk), .ahb_sub_hsel (sel), .ahb_sub_hexcl (1'b0)
  );
endmodule
"""

UNWIRED = """
module tb;
  tidelink_top #(.A(1)) u_dut (
    .hclk (clk), .ahb_sub_hsel (sel), .ahb_sub_hready (1'b1)
  );
endmodule
"""

POSITIONAL = """
module tb;
  tidelink_top u_dut (clk, rstn, sel);
endmodule
"""

COMMENTED = """
module tb;
  tidelink_top u_dut (
    .hclk (clk)
    // .ahb_sub_hexcl (1'b0)   <- does not count
  );
endmodule
"""

BLOCK_COMMENTED = """
module tb;
  tidelink_top u_dut (
    .hclk (clk)
    /* .ahb_sub_hexcl (1'b0) */
  );
endmodule
"""

DEFINITION = """
module tidelink_top (input wire hclk, input wire ahb_sub_hexcl);
endmodule
"""

MACRO_PARAMS_UNWIRED = """
module tb;
  tidelink_top `MASK_PARAMS u_dut (
    .hclk (clk), .mask_hs_bypass_i (b)
  );
endmodule
"""

MACRO_PARAMS_WIRED = """
module tb;
  tidelink_top `MASK_PARAMS u_dut (
    .hclk (clk), .ahb_sub_hexcl (1'b0)
  );
endmodule
"""

TWO_INSTANCES_ONE_BAD = """
module tb;
  tidelink_top #(.A(1)) u_master ( .hclk (clk), .ahb_sub_hexcl (m_excl) );
  tidelink_top #(.A(1)) u_slave  ( .hclk (clk), .ahb_sub_hsel (1'b0) );
endmodule
"""

# A near-miss that must NOT satisfy the check: a similarly-named port.
LOOKALIKE_PORT = """
module tb;
  tidelink_top u_dut ( .hclk (clk), .ahb_sub_hexcl_unused (1'b0) );
endmodule
"""


def main_test():
    print("test_check_excl_port_wired:")

    expect("wired instantiation is clean",
           scan_text(WIRED, "tidelink_top") == [])

    bad = scan_text(UNWIRED, "tidelink_top")
    expect("UNWIRED instantiation is REPORTED", len(bad) == 1, bad)

    bad = scan_text(POSITIONAL, "tidelink_top")
    expect("POSITIONAL instantiation is REPORTED",
           len(bad) == 1 and "positional" in bad[0]["why"], bad)

    expect("line-COMMENTED connection does not count as wired",
           len(scan_text(COMMENTED, "tidelink_top")) == 1)
    expect("block-COMMENTED connection does not count as wired",
           len(scan_text(BLOCK_COMMENTED, "tidelink_top")) == 1)

    expect("module DEFINITION is not an instantiation",
           len(list(find_instantiations(DEFINITION, "tidelink_top"))) == 0)

    # THE FAIL-OPEN CASE. The parser must SEE this instantiation at all.
    seen = list(find_instantiations(MACRO_PARAMS_UNWIRED, "tidelink_top"))
    expect("macro-parameterised instantiation is PARSED (not skipped)",
           len(seen) == 1, seen)
    bad = scan_text(MACRO_PARAMS_UNWIRED, "tidelink_top")
    expect("macro-parameterised UNWIRED instantiation is REPORTED",
           len(bad) == 1, bad)
    expect("macro-parameterised WIRED instantiation is clean",
           scan_text(MACRO_PARAMS_WIRED, "tidelink_top") == [])

    bad = scan_text(TWO_INSTANCES_ONE_BAD, "tidelink_top")
    expect("one bad of two instances is reported, and only the bad one",
           len(bad) == 1 and bad[0]["inst"] == "u_slave", bad)

    bad = scan_text(LOOKALIKE_PORT, "tidelink_top")
    expect("a look-alike port name does not satisfy the check", len(bad) == 1,
           bad)

    # COULD-NOT-EVALUATE: an empty tree must exit 2, not 0.
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "unrelated.sv").write_text("module foo; endmodule\n")
        rc = main(["--root", d])
    expect("an empty scan is COULD-NOT-EVALUATE (exit 2), not a pass", rc == 2,
           f"rc={rc}")

    # And the live tree must currently be clean — this is the check the gate
    # actually runs, so if it is red the control says so rather than passing.
    rc = main(["--root", str(REPO)])
    expect("the live repo passes the check", rc == 0, f"rc={rc}")

    if FAILURES:
        print(f"FAIL: {len(FAILURES)} control(s) did not hold: {FAILURES}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main_test())
