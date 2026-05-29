# VC Formal X-propagation script for tidelink_rxclk_buf
# Verifies no X-state can propagate to clk_o under ASIC default
# (USE_CLKBUF=0) — pure passthrough mode. The USE_CLKBUF=1 arm
# instantiates a Xilinx BUFG and is outside ASIC sign-off scope.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_rxclk_buf.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
# USE_CLKBUF=0 is the ASIC default and selects the passthrough branch;
# the BUFG primitive is not elaborated.
elaborate -top tidelink_rxclk_buf \
    -parameter USE_CLKBUF 0

# ── No clock/reset ──────────────────────────────────────────────────────────
# In passthrough mode the module is a single wire assignment
# (clk_o = clk_i). No state, no clock domain.

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Input forwarded RX clock is assumed defined.
assume -name clk_i_valid {clk_i !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
