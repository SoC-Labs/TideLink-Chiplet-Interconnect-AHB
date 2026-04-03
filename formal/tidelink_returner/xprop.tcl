# VC Formal X-propagation script for tidelink_returner
# Verifies that no X-state can propagate to AHB master outputs or internal
# state from valid reset through normal operation.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/fifo/tidelink_returner.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_returner \
    -parameter SYS_ADDR_W 32 \
    -parameter SYS_DATA_W 32

# ── Clock and reset ─────────────────────────────────────────────────────────
clock hclk
reset -expression {!hresetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Assume AHB slave responds with valid hready (no X on hready after reset)
assume -name hready_valid {hready !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
