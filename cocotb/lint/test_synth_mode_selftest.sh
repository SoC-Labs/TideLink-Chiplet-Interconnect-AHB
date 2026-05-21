#!/usr/bin/env bash
# =============================================================================
# Selftest for the synth-mode Verilator lint gate.
#
# Verilator (4.028) catches a different set of synth-equivalent defects than
# our existing sv_anti_pattern_lint.py (which catches Bug #1 latch + Bug #2
# case-no-default via SV-AST scan). Verilator covers the COMPLEMENTARY
# defect class: WIDTH/WIDTHCONCAT mismatches, BLKANDNBLK same-signal driver
# rules, MULTIDRIVEN, IMPLICIT nets, CASEINCOMPLETE, INFINITELOOP, UNOPTFLAT.
# These are the bug class that synth tools reject AT ELABORATION but cocotb
# happily simulates.
#
# Fixtures:
#   GOOD          — clean module, no issues → must lint clean (rc=0)
#   BAD_INCOMPLT  — incomplete case, no default → CASEINCOMPLETE (rc=1)
#   BAD_WIDTH     — port-width mismatch on assignment → WIDTH (rc=1)
#   BAD_BLKMIX    — same signal driven blocking + non-blocking → BLKANDNBLK (rc=1)
#
# If any fixture behaves wrong, the selftest fails. Each "BAD" pattern has
# been observed in our submodule history at least once during integration
# (BLKANDNBLK is the closest in-spirit to Bug #7's REVROP cross-process).
# =============================================================================
set -u

VERILATOR=${VERILATOR:-verilator}

if ! command -v "$VERILATOR" >/dev/null 2>&1 ; then
  echo "SKIP — Verilator not on PATH"
  exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# ---------- Fixtures ---------------------------------------------------

# GOOD
cat > "$TMP/good.sv" <<'EOF'
module good (
    input  logic clk,
    input  logic rst,
    input  logic [1:0] sel,
    output logic [1:0] out
);
    logic [1:0] state, nxt_state;
    always_comb begin
        nxt_state = state;
        case (sel)
            2'd0: nxt_state = 2'd1;
            2'd1: nxt_state = 2'd2;
            default: ;
        endcase
    end
    assign out = state;
    always_ff @(posedge clk or posedge rst)
        if (rst) state <= 2'd0;
        else     state <= nxt_state;
endmodule
EOF

# BAD_INCOMPLT: case statement missing arm AND no default — Verilator emits
# CASEINCOMPLETE. Mirrors Bug #2 (collapsed case from missing default), the
# same defect class as the autoneg state_r case fixed in submodule 6a757e2.
cat > "$TMP/bad_incomplt.sv" <<'EOF'
module bad_incomplt (
    input  logic        clk,
    input  logic        rst,
    input  logic [1:0]  sel,
    output logic [1:0]  out
);
    always_ff @(posedge clk or posedge rst) begin
        if (rst) out <= 2'd0;
        else begin
            case (sel)
                2'd0: out <= 2'd0;
                2'd1: out <= 2'd1;
                2'd2: out <= 2'd2;
                // BUG: no 2'd3 AND no default → synth-collapse risk
            endcase
        end
    end
endmodule
EOF

# BAD_WIDTH: 16-bit constant assigned to 8-bit signal → WIDTH warning.
# This is the bug class that produces silent constant-fold in synth.
cat > "$TMP/bad_width.sv" <<'EOF'
module bad_width (
    input  logic        clk,
    input  logic        rst,
    output logic [7:0]  out
);
    always_ff @(posedge clk or posedge rst)
        if (rst) out <= 8'd0;
        else     out <= 16'hdead;   // BUG: 16-bit RHS, 8-bit LHS
endmodule
EOF

# BAD_BLKMIX: same signal driven both blocking and non-blocking. Vivado
# synth rejects with [Synth 8-2898]; closest analog to Bug #7's REVROP
# cross-process blocking issue.
cat > "$TMP/bad_blkmix.sv" <<'EOF'
module bad_blkmix (
    input  logic clk,
    input  logic rst,
    output logic out
);
    logic q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) q <= 1'b0;
        else     q  = ~q;   // BUG: blocking + non-blocking same signal
    end
    assign out = q;
endmodule
EOF

LINT_FLAGS="--lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED +1800-2017ext+sv"

run_lint() {
    local file=$1
    local top=$2
    $VERILATOR $LINT_FLAGS --top-module $top "$file" 2>&1
}

fail=0

# GOOD must exit 0
out=$(run_lint "$TMP/good.sv" good)
rc=$?
if [ $rc -ne 0 ] ; then
    echo "FAIL: good.sv should lint clean but rc=$rc"
    echo "$out"
    fail=1
else
    echo "PASS good.sv exits 0 (no false-positives)"
fi

# BAD_INCOMPLT → CASEINCOMPLETE
out=$(run_lint "$TMP/bad_incomplt.sv" bad_incomplt)
rc=$?
if [ $rc -eq 0 ] ; then
    echo "FAIL: bad_incomplt.sv (Bug #2 class) should fail lint but rc=0"
    fail=1
elif ! echo "$out" | grep -qiE "CASEINCOMPLETE|CASEOVERLAP" ; then
    echo "FAIL: bad_incomplt.sv failed lint but didn't emit CASEINCOMPLETE"
    echo "$out"
    fail=1
else
    echo "PASS bad_incomplt.sv (Bug #2 class) caught — Verilator reports CASEINCOMPLETE"
fi

# BAD_WIDTH → WIDTH
out=$(run_lint "$TMP/bad_width.sv" bad_width)
rc=$?
if [ $rc -eq 0 ] ; then
    echo "FAIL: bad_width.sv (silent-truncate class) should fail lint but rc=0"
    fail=1
elif ! echo "$out" | grep -qiE "WIDTH" ; then
    echo "FAIL: bad_width.sv failed lint but didn't emit WIDTH"
    echo "$out"
    fail=1
else
    echo "PASS bad_width.sv (silent-truncate) caught — Verilator reports WIDTH"
fi

# BAD_BLKMIX → BLKANDNBLK
out=$(run_lint "$TMP/bad_blkmix.sv" bad_blkmix)
rc=$?
if [ $rc -eq 0 ] ; then
    echo "FAIL: bad_blkmix.sv (Bug #7-class blk/nonblk) should fail lint but rc=0"
    fail=1
elif ! echo "$out" | grep -qiE "BLKANDNBLK|BLKSEQ|MULTIDRIVEN" ; then
    echo "FAIL: bad_blkmix.sv failed lint but didn't emit BLKANDNBLK"
    echo "$out"
    fail=1
else
    echo "PASS bad_blkmix.sv (Bug #7 class) caught — Verilator reports BLKANDNBLK"
fi

if [ $fail -ne 0 ] ; then
    echo "FAIL — synth-mode selftest detected gate regressions"
    exit 1
fi
echo "OK — synth-mode selftest: 4/4 fixtures behaved as expected (gate would catch Bug #2 + width + Bug #7 in real RTL)"
echo "   Note: Verilator 4.028 has no LATCH warning — Bug #1 latch is covered"
echo "   by sv_anti_pattern_lint.py (see cocotb/lint/Makefile)."
exit 0
