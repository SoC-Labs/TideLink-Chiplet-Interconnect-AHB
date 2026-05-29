# VC Formal X-propagation script for tidelink_mul_iter
# Verifies that no X-state can propagate to busy/done/result from valid
# reset through a complete 32-cycle multiply under valid operand inputs.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_mul_iter.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
# Module has no parameters.
elaborate -top tidelink_mul_iter

# ── Clock and reset ─────────────────────────────────────────────────────────
clock clk
reset -expression {!resetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Servo (the sole consumer) drives start/operands to well-defined values
assume -name start_valid {start !== 1'bx}
assume -name a_valid     {(^a) !== 1'bx}
assume -name b_valid     {(^b) !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
