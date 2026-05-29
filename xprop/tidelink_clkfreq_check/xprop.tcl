# VC Formal X-propagation script for tidelink_clkfreq_check
# Dual-clock window-based frequency ratio checker. Verifies no X-state
# can propagate to the local_clk-domain status outputs (freq_match,
# freq_mismatch_sticky, measured_once, *_window_count, measurement_valid)
# under valid edge inputs on either domain.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_clkfreq_check.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_clkfreq_check \
    -parameter WINDOW_BITS 16 \
    -parameter CNT_W 20 \
    -parameter SYNC_STAGES 2 \
    -parameter TOL_COUNTS 256

# ── Clocks and resets ───────────────────────────────────────────────────────
clock local_clk
clock link_clk
reset -expression {!local_rst_n}
reset -expression {!link_rst_n}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Both clocks toggle deterministically; reset and arm-enable resolve cleanly.
assume -name link_up_valid {link_up !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
