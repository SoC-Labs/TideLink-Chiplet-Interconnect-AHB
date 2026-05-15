# gen_gate_tb.awk — derive a probe-free gate-level testbench from tb/top.sv
#
# The functional UVM testbench (clk/reset, SVT VIP interfaces, the two
# tidelink_top instantiations, WIRE_AHB macros, uvm_config_db + run_test)
# wires the DUT only through its ports. The phy-align / data-flow debug
# instrumentation reaches DUT internal hierarchy via cross-module
# references (u_tidelink_top_a.u_chiplet_controller.u_wlink...). The
# post-route FC netlist is flattened, so those XMRs cannot resolve
# (Error-[XMRE]) and break gate-level compile.
#
# ALGORITHM (single pass, provably balanced):
#   Walk the module body tracking begin/end nesting depth. A "top-level
#   construct" is the run of lines from a depth-0 statement start until
#   nesting returns to depth 0 (covers multi-line always/initial blocks,
#   multi-line continuous assigns, multi-line wire initialisers, etc.).
#   Buffer each construct; when it closes at depth 0, emit it verbatim
#   UNLESS its full text contains an XMR token AND it is not the UVM
#   bring-up construct (run_test / uvm_config_db are always kept).
#
#   begin/end are only counted as structural when they are whole words;
#   occurrences inside string literals (e.g. a $display format) are
#   excluded by blanking double-quoted spans before counting.
#
# Header lines (before `module test_top;`) and the closing `endmodule`
# are passed through untouched — XMRs only ever appear in the body.
#
# Downstream the Makefile asserts: zero residual u_tidelink_top_[ab].
# tokens AND run_test( still present.

BEGIN { xmr = "u_tidelink_top_[ab]\\."; inbody = 0; depth = 0; buffering = 0 }

function strip_strings(s,   out) {
    # Replace "..." spans with spaces so begin/end/; inside format
    # strings are not miscounted. Good enough for this codebase (no
    # escaped quotes inside the relevant format strings).
    out = s
    gsub(/"[^"]*"/, "", out)
    return out
}
function net_depth(s,   t, nb, ne) {
    t  = strip_strings(s)
    nb = gsub(/\<begin\>/, "begin", t)
    ne = gsub(/\<end\>/,   "end",   t)
    return nb - ne
}

# Pass header through until we enter the module body.
inbody == 0 {
    print
    if ($0 ~ /\<module[ \t]+test_top[ \t]*;/) inbody = 1
    next
}

# Inside the body. `endmodule` closes it — flush any open buffer first.
$0 ~ /^[ \t]*endmodule\>/ && buffering == 0 {
    print
    inbody = 2
    next
}

buffering == 0 {
    # Start of a new top-level construct.
    buf       = $0 "\n"
    has_xmr   = ($0 ~ xmr)
    keep      = ($0 ~ /run_test\(/ || $0 ~ /uvm_config_db/)
    depth     = net_depth($0)
    # Construct also closes on this same line if it is a depth-0
    # single statement terminated by ';' (wire/assign/one-liners) and
    # no net begin/end nesting was opened.
    if (depth <= 0 && ($0 ~ /;[ \t]*$/ || $0 ~ /\<end\>[ \t]*$/ || $0 ~ /[)] *;[ \t]*$/)) {
        if (!(has_xmr && !keep)) printf "%s", buf
        buf = ""
        next
    }
    if (depth <= 0 && $0 !~ /[;]/ && $0 !~ /\<begin\>/) {
        # e.g. a lone comment / blank / label line at depth 0 — emit
        # immediately unless it itself carried an XMR.
        if (!(has_xmr && !keep)) printf "%s", buf
        buf = ""
        next
    }
    buffering = 1
    next
}

# Continuing a buffered multi-line construct.
buffering == 1 {
    buf = buf $0 "\n"
    if ($0 ~ xmr)                                   has_xmr = 1
    if ($0 ~ /run_test\(/ || $0 ~ /uvm_config_db/)  keep    = 1
    depth += net_depth($0)
    if (depth <= 0) {
        if (!(has_xmr && !keep)) printf "%s", buf
        buf = ""
        buffering = 0
    }
    next
}
