#!/usr/bin/env python3
"""Self-test for sv_anti_pattern_lint.py.

Builds synthetic SV fixtures that mirror the two real bugs that bit autoneg
on silicon (commits be5eed2 + 6a757e2), runs the linter against them, and
asserts that:

  - The "bad" fixtures produce the EXPECTED finding (and only that finding).
  - The "good" fixtures produce zero findings.

If a future refactor of the linter regresses against either bug class, this
test fails — closing the loop the user complained about ("cocotb didn't
catch the bug, we lost bench cycles").

Run with:
    python3 test_lint_selftest.py
or:
    make -C cocotb/lint selftest
"""

from __future__ import annotations

import os
import sys
import tempfile
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from sv_anti_pattern_lint import (  # noqa: E402
    CODE_CASE_NO_DEFAULT,
    CODE_COMB_NO_DEFAULT,
    scan_file,
    _strip_comments,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Bug class #2 — outer case (state_r) without default. Mirror of the
# tidelink_autoneg.sv bug fixed in submodule commit 6a757e2.
BAD_CASE_NO_DEFAULT_SV = textwrap.dedent("""
    module bad_case_no_default (
        input  logic        clk,
        input  logic        rstn,
        input  logic [1:0]  state_r,
        output logic [1:0]  state_nxt
    );
        localparam ST_IDLE = 2'd0;
        localparam ST_GO   = 2'd1;
        always_comb begin
            state_nxt = state_r;
            case (state_r)
                ST_IDLE: state_nxt = ST_GO;
                ST_GO:   state_nxt = ST_IDLE;
            endcase
        end
    endmodule
""").strip()

# Bug class #1 — latch from missing comb default. Mirror of the
# tidelink_autoneg.sv `txn_step_nxt` bug fixed in submodule commit be5eed2.
BAD_COMB_NO_DEFAULT_SV = textwrap.dedent("""
    module bad_comb_no_default (
        input  logic        clk,
        input  logic        rstn,
        input  logic [1:0]  state_r,
        input  logic [1:0]  txn_step_r,
        output logic [1:0]  txn_step_nxt
    );
        always_comb begin
            // BUG: no top-level `txn_step_nxt = txn_step_r;` default.
            // Vivado infers a latch (Synth 8-327).
            if (state_r == 2'd1) begin
                if (txn_step_r == 2'd0)
                    txn_step_nxt = 2'd1;
            end
        end
    endmodule
""").strip()

# Good fixture: case with default + comb with top-level default.
GOOD_FIXED_SV = textwrap.dedent("""
    module good_fixed (
        input  logic        clk,
        input  logic [1:0]  state_r,
        input  logic [1:0]  txn_step_r,
        output logic [1:0]  state_nxt,
        output logic [1:0]  txn_step_nxt
    );
        always_comb begin
            state_nxt    = state_r;
            txn_step_nxt = txn_step_r;
            case (state_r)
                2'd0: state_nxt = 2'd1;
                2'd1: state_nxt = 2'd2;
                default: state_nxt = 2'd0;
            endcase
            if (state_r == 2'd1) begin
                if (txn_step_r == 2'd0)
                    txn_step_nxt = 2'd1;
            end
        end
    endmodule
""").strip()

# Good fixture: case with no default but every arm + the if/else chain ends
# in `default:`/`else`, so the signal is covered.
GOOD_COVERED_BY_DEFAULT_ARM_SV = textwrap.dedent("""
    module good_covered_by_default_arm (
        input  logic [2:0] cnt,
        output logic [7:0] byte_out,
        output logic       last
    );
        always_comb begin
            case (cnt)
                3'd0: begin byte_out = 8'h10; last = 1'b0; end
                3'd1: begin byte_out = 8'h20; last = 1'b1; end
                default: begin byte_out = 8'h00; last = 1'b0; end
            endcase
        end
    endmodule
""").strip()

# Good fixture: comb with if/else-if/else chain that covers signal in every
# branch — synth sees this as a mux, not a latch.
GOOD_IF_ELSE_CHAIN_SV = textwrap.dedent("""
    module good_if_else_chain (
        input  logic [1:0] sel,
        output logic [7:0] val
    );
        always_comb begin
            if      (sel == 2'd0) val = 8'h11;
            else if (sel == 2'd1) val = 8'h22;
            else if (sel == 2'd2) val = 8'h33;
            else                  val = 8'h44;
        end
    endmodule
""").strip()

# Good fixture: for-loop assigning all bits of a vector (synth unrolls).
GOOD_FOR_LOOP_VECTOR_SV = textwrap.dedent("""
    module good_for_loop_vector (
        input  logic [7:0] lane_done,
        input  logic [7:0] lane_locked,
        output logic [7:0] lane_new_lock
    );
        always_comb begin
            for (int i = 0; i < 8; i++)
                lane_new_lock[i] = ~lane_done[i] & lane_locked[i];
        end
    endmodule
""").strip()


FIXTURES = [
    ("bad_case_no_default.sv",          BAD_CASE_NO_DEFAULT_SV,        {CODE_CASE_NO_DEFAULT}),
    ("bad_comb_no_default.sv",          BAD_COMB_NO_DEFAULT_SV,        {CODE_COMB_NO_DEFAULT}),
    ("good_fixed.sv",                   GOOD_FIXED_SV,                 set()),
    ("good_covered_by_default_arm.sv",  GOOD_COVERED_BY_DEFAULT_ARM_SV, set()),
    ("good_if_else_chain.sv",           GOOD_IF_ELSE_CHAIN_SV,         set()),
    ("good_for_loop_vector.sv",         GOOD_FOR_LOOP_VECTOR_SV,       set()),
]


def main() -> int:
    failures: list = []
    passes = 0
    with tempfile.TemporaryDirectory(prefix="tidelink_lint_selftest_") as td:
        for name, src, expected_codes in FIXTURES:
            path = Path(td) / name
            path.write_text(src)
            findings = scan_file(path)
            actual_codes = {f.code for f in findings}
            ok = actual_codes == expected_codes
            tag = "PASS" if ok else "FAIL"
            print(f"  [{tag}] {name}")
            if not ok:
                print(f"        expected {sorted(expected_codes) or 'no findings'}")
                print(f"        actual   {sorted(actual_codes) or 'no findings'}")
                for f in findings:
                    print(f"          - {f}")
                failures.append(name)
            else:
                passes += 1

    print("----------------------------------------")
    print(f"  selftest: {passes}/{len(FIXTURES)} pass")
    if failures:
        print(f"  failures: {failures}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
