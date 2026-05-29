# VC Formal X-propagation script for tidelink_fifo_ctrl
# Verifies that no X-state can propagate to outputs or internal registers
# from valid reset through normal operation.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_ctrl.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_fifo_ctrl \
    -parameter RAM_ADDR_W 14

# ── Clock and reset ─────────────────────────────────────────────────────────
clock hclk
reset -expression {!hresetn}

# ── X-propagation checks ───────────────────────────────────────────────────
# Check that after reset, no X can propagate to any output or register
# when inputs are driven to valid (non-X) values.
set_xprop_check -effort high

# Assume AHB inputs are well-formed after reset
assume -name ahb_htrans_valid    {htrans inside {2'b00, 2'b10}}
assume -name ahb_no_busy         {htrans != 2'b01}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
